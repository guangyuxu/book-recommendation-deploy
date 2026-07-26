# book-recommendation-deploy

Deployment for the book-recommendation platform — **Docker Compose** (single host / local) and
**Kubernetes** (cluster). Bundles Postgres + Redis alongside the four apps.

## Architecture

```
browser ──> ui (nginx :8080, serves the SPA only)
   │
   ├── http://localhost:8001 ──> accounts   IdP + family/child CRUD, RS256 issuer   (container :8000)
   └── http://localhost:8000 ──> service    BFF: verifies token, proxies chat (SSE) (container :8000)
                                    └──> agent  LangGraph Server (:2024, incl. A2A)
accounts, agent  ──> postgres (accounts schema, book_agent schema, langgraph db)
agent            ──> redis      (LangGraph Server queue/checkpointer)
```

- **Direct calls, no reverse proxy.** The browser calls accounts and the service by absolute URL;
  both are CORS-enabled for the UI origin. The single access token (issued by accounts, verified by
  the service) works on both. The **service (BFF) is the auth boundary** — the browser never talks
  to the agent directly (the agent trusts injected identity and has no auth of its own).
- **Ports**: accounts container `:8000` → host `:8001`; service `:8000` → host `:8000`; agent
  `:2024` → host `:2024` (LangGraph's conventional port; A2A is served on the same port at
  `/a2a/{assistant_id}/.well-known/agent-card.json`); ui host `:8080`.
- **RS256 keys** are generated once into a shared volume/secret: accounts gets the private+public
  PEM (it signs), the service gets only the public PEM (it verifies).
- **Databases**: one Postgres holds the `accounts` schema, the `book_agent` schema (both in db
  `book`), and a dedicated `langgraph` database for the LangGraph Server (which self-migrates).

> **Kubernetes note:** the k8s manifests were first written for a same-origin (nginx-proxy) model.
> With the direct model, build the UI image with `VITE_API_BASE_URL` / `VITE_CHAT_BASE_URL` pointing
> at your cluster's externally-reachable accounts/service URLs, and expose those services (ingress
> or LoadBalancer). The compose stack is the fully-wired reference.

## Prerequisites

Sibling repos must sit next to this one (build contexts point at them):
`../book-recommendation-{accounts,agent,service,ui}`.

You also need LLM credentials and a LangGraph Server license — see `.env.example`.

## Docker Compose

```bash
cp .env.example .env          # fill in ANTHROPIC_API_KEY, a LangGraph license/LangSmith key, etc.
make up                       # build + start everything (detached)
open http://localhost:8080    # sign up, then chat
make logs                     # follow logs
make down                     # stop (keep data);  make clean = also wipe volumes+keys
```

Startup order is enforced via healthchecks + `depends_on`: postgres/redis become healthy → `keygen`
+ the `*-init` one-shots run → accounts/agent/service come up → ui.

## Kubernetes

Build the four app images and make them available to the cluster (e.g. `minikube image load
book-recommendation-accounts:latest`, …), then:

```bash
kubectl apply -f k8s/namespace.yaml
make k8s-keys                 # generate RS256 keypair -> `jwt-keys` Secret
make k8s-secrets              # LLM keys + ACCOUNTS_SERVICE_TOKEN from .env -> `app-secrets` Secret
make k8s-apply                # kustomize apply: config, postgres, redis, apps, ingress
```

Add `book-rec.local` to `/etc/hosts` (pointing at the ingress IP), or port-forward the ui Service:
`kubectl -n book-rec port-forward svc/ui 8080:80`.

Schema/table creation runs as init containers on the accounts and agent Deployments (idempotent);
the LangGraph Server self-migrates the `langgraph` database on startup.

## Configuration notes

- **DB credentials**: the bundle uses `book/book` by default. Compose reads them from `.env`
  (`POSTGRES_*`); k8s reads them from `configmap-app.yaml` (change both the `POSTGRES_*` values and
  the embedded DSNs together, or move the DSNs into a Secret).
- **TLS / production hardening**: set `REFRESH_COOKIE_SECURE=true` once TLS terminates at the
  ingress; add a `tls:` block to `k8s/ingress.yaml`; scope `app-secrets` per-service for least
  privilege; remove the exposed Postgres port in compose.
- **LangGraph license**: the agent uses the licensed `langchain/langgraph-api` base image; provide
  `LANGGRAPH_CLOUD_LICENSE_KEY` or a suitably-entitled `LANGSMITH_API_KEY`.

## Layout

```
docker-compose.yml            # full stack (compose)
postgres/initdb/01-init.sql   # first-init: langgraph db + accounts/book_agent schemas
.env.example                  # secrets + bundle config
Makefile                      # up/down/logs + k8s-keys/k8s-secrets/k8s-apply
k8s/                          # namespace, config, postgres, redis, apps, ingress, kustomization
```
