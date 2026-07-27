# Project Rules for Claude Code

This is the **platform deployment** repo for the book-recommendation platform: **Docker Compose**
for the single-host / local environment and **kustomize + Kubernetes** for a cluster, bundling
**Postgres + Redis** alongside the four app images. It contains **no application code** — the
deliverable is a set of manifests, and every app image is built from a sibling repo
(`../book-recommendation-{accounts,agent,service,ui}`). This repo is the only place that knows how
the five pieces are wired together, which makes it the place where a wrong port, a missing
environment variable, or a leaked secret does the most damage. The rules below mirror the sibling
repos so all projects hold one standard.

## Architecture invariants (do not silently change these)

- **Direct calls, no reverse proxy.** The browser calls **accounts** and the **service (BFF)** by
  absolute URL; both are CORS-enabled for the UI origin. nginx in the ui image serves the SPA only.
- **The service (BFF) is the auth boundary.** The browser must **never** be able to reach the
  **agent**: the agent trusts the identity injected into its run context and has no auth of its
  own. The agent's `:2024` port mapping in compose is a **dev-only** debugging convenience — it must
  not exist in any exposed deployment, and it is why `DEBUG_BIND` exists.
- **accounts is the token issuer** (holds the RS256 **private** key) and the **single writer** of
  the family/child tables. The service gets the **public key only**. Never mount the private key
  into the service, the agent, or the ui.
- **One Postgres, three logical homes**: the `accounts` schema and the `book_agent` schema (both in
  database `book`), plus a dedicated `langgraph` database that LangGraph Server self-migrates.
  Redis is for LangGraph Server only.
- The k8s manifests were first written for a **same-origin (nginx-proxy)** model; compose is the
  fully-wired reference. See the "Kubernetes note" in `README.md` before trusting a k8s manifest as
  the source of truth for wiring.

## Secrets

**Nothing secret may ever enter git.** This repo handles RS256 keypairs, LLM API keys, a LangGraph
license, the service-to-service token, and the database password.

- `.gitignore` blocks `.env`, `.env.*` (except `.env.example`), `keys/`, and `*.pem`. Treat that as
  a convenience, **not** the control: it only protects paths someone already thought of. The real
  backstop is **gitleaks**, which runs in pre-commit and as its own CI job, and scans content rather
  than filenames.
- **`.env.example` is documentation, not a value store.** Real secrets are blank there
  (`ANTHROPIC_API_KEY=`). Placeholders that look like credentials (`ACCOUNTS_SERVICE_TOKEN=dev-…`)
  are dev-only defaults and must never be used anywhere reachable. Never "helpfully" fill in a real
  value while testing.
- **Never commit a rendered manifest.** `kubectl kustomize`, `docker compose config`, and
  `kubectl create secret --dry-run=client -o yaml` all print resolved values — including secrets.
  Their output is for reading, never for adding to the repo. `make config` prints your real `.env`:
  do not paste its output anywhere.
- **k8s Secrets are not encrypted**, only base64-encoded. `make k8s-keys` / `make k8s-secrets`
  create them from local files at apply time, which is why those files are gitignored and why no
  Secret manifest lives in `k8s/`. Do not add one.
- When a value must be shown in a doc or a commit message, show its **name and shape**, never its
  value.

## Change-coupling rules (the failure mode unique to this repo)

A single piece of configuration is usually pinned in several files at once. Changing one and not the
others produces a stack that starts and then misbehaves — which is far worse than one that fails to
start. **When you touch any of the following, update every listed location in the same change:**

- **A port** → `docker-compose.yml` (both sides of the mapping), the matching `k8s/*.yaml`
  Service/Deployment, `CORS_ORIGINS` / `UI_PORT` in `.env.example`, this repo's `README.md`
  architecture block, and the affected app repo's own README.
- **An environment variable** → `docker-compose.yml`, `k8s/configmap-app.yaml` (or the Secret
  wiring), `.env.example` (with a comment saying what it does and whether it is required), and the
  consuming app's own settings module.
- **A required (`${VAR:?}`) compose variable** → also the `compose_check` target in the `Makefile`,
  which injects dummies for exactly those variables so `make check` passes on a fresh clone. Adding
  a third `:?` variable without telling that target makes CI fail for an uninteresting reason.
- **A database credential or DSN** → compose reads `POSTGRES_*` from `.env`; k8s has them **and the
  embedded DSNs** in `configmap-app.yaml`. Both the values and every DSN that inlines them must move
  together.
- **A base-image tag** → `docker-compose.yml` and `k8s/*.yaml` pin the same images independently
  (postgres, redis). Dependabot will open a PR per file (see `.github/dependabot.yml`); apply them
  together, because a skew between the two is a bug.

## Build & verification

The Makefile `CHECKS` section is the single source of truth for verification. Nothing restates
those commands: GitHub Actions (`.github/workflows/ci.yml`) runs `make ci` verbatim, and the
pre-commit hooks (`.pre-commit-config.yaml`) run `make check` on commit and `make ci` on push. So
local and CI cannot drift.

After every manifest change, run the gate and make sure it is green before treating the work as
done. Do NOT report a task as complete while any check fails.

```bash
make check   # render + validate docker-compose.yml and the kustomize overlay — offline, no cluster
make ci      # what GitHub Actions runs verbatim; identical to check (this repo has no code)
```

There is nothing to lint, type-check or unit-test here, so `ci` validates the **manifests
themselves**. Both checks are pure renders: they parse every file, resolve every variable and patch
reference, and fail on a typo'd key, an unresolvable `${VAR}`, or a kustomization pointing at a file
that no longer exists.

Two traps worth knowing before you "fix" a check:

- **`kubectl apply -k --dry-run=client` does NOT work offline.** Despite the name it still contacts
  the API server for the OpenAPI schema and dies with `failed to download openapi: connection
  refused` where no cluster is reachable. `k8s_check` uses `kubectl kustomize` (a pure local render)
  for that reason; schema-aware validation lives in `make k8s-diff`, which is honest about needing a
  cluster and is kept out of `ci`.
- **`compose_check` must not read your real `.env`.** It feeds `.env.example` plus dummy values for
  the two required secrets. A local `.env` full of real values would make the check pass for the
  wrong reason and hide a variable that was never documented in `.env.example`.

`make ci` does **not** build images: the compose build contexts point at the sibling repos, which do
not exist when this repo is checked out alone, and each app repo's own CI already builds its own
image. There is also no `audit.yml` here — no dependency manifest to scan; base-image tags are
watched by Dependabot instead.

Install the local hooks once with `pre-commit install` (pre-commit comes from `pipx`/`brew` — see
`.pre-commit-config.yaml`). Focused subsets: `make compose_check`, `make k8s_check`.
