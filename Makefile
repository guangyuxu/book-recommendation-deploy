# ─────────────────────────────────────────────────────────────────────────────────────
# VERIFICATION MAP — this Makefile is the single source of truth. ci.yml and
# .pre-commit-config.yaml only CALL these targets (never restate commands), so no drift.
#
#   ci    = check                       ← GitHub Actions (verbatim) + pre-push hook
#   check = compose_check + k8s_check   ← everyday local + pre-commit hook
#
#           compose_check .. docker compose config -q  (renders + validates the merged compose file)
#           k8s_check ...... kubectl kustomize k8s     (renders the full kustomize overlay)
#
#   THIS REPO HAS NO CODE. There is nothing to lint, type-check or unit-test: the deliverable is a
#   set of MANIFESTS, so `ci` validates the manifests themselves. Both checks are pure renders --
#   they parse every file, resolve every variable and patch reference, and fail on a typo'd key, an
#   unresolvable ${VAR}, or a kustomization pointing at a file that no longer exists. That is the
#   strongest guarantee obtainable without a live cluster (see the note on k8s_check).
#
#   `ci` is an ALIAS for `check`, not a superset (in the sibling repos `ci` adds coverage on top).
#   Nothing here is slow or online, so there is no cheaper subset worth splitting out -- but both
#   names exist so `make ci` means the same thing in all five repos.
#
#   DELIBERATELY *NOT* IN THE GATE:
#     - `build` / `up`: the compose build contexts point at the SIBLING repos
#       (../book-recommendation-*), which do not exist when this repo is checked out alone. Each app
#       repo's own ci.yml already has a `docker` job that builds its own image; checking out four
#       repos here would cost minutes to learn nothing new.
#     - `k8s-diff`: needs a live cluster (see the note on that target).
#     - Anything reading a real `.env`: `check` must pass on a fresh clone -- see compose_check.
# ─────────────────────────────────────────────────────────────────────────────────────

.PHONY: all \
	compose_check k8s_check \
	check ci \
	up up-fg down clean logs config build ps \
	k8s-keys k8s-secrets k8s-apply k8s-delete k8s-diff \
	help

# Default target executed when no arguments are given to make.
all: help

COMPOSE := docker compose
K8S_DIR := k8s
NAMESPACE := book-rec

######################
# CHECKS
######################
# Single source of truth for verification. Nothing else restates these commands:
#   - GitHub Actions (.github/workflows/ci.yml) runs `make ci` verbatim.
#   - pre-commit (.pre-commit-config.yaml) runs `make check` on commit and `make ci` on push.
# So local == CI by construction. Both targets are offline and need no cluster.

# -- atomic checks: each is the ONE definition of that check --

# Validates docker-compose.yml WITHOUT a real .env -- which is what makes it meaningful in CI and on
# a fresh clone. Two details, both load-bearing:
#   1. --env-file .env.example, NOT the repo's own .env: a local .env full of real values makes this
#      pass for the wrong reason, hiding a variable nobody ever added to .env.example.
#   2. ANTHROPIC_API_KEY and ACCOUNTS_SERVICE_TOKEN are declared `${VAR:?}` (required) in the
#      compose file, and compose treats an EMPTY value as missing. ANTHROPIC_API_KEY is
#      intentionally blank in .env.example (it is a real secret), so a dummy is injected here.
#      Those are the only two required variables today; if a third `:?` is ever added, it must be
#      added here too or this target starts failing for an uninteresting reason.
compose_check:           ## render + validate docker-compose.yml against .env.example (no real .env, no cluster)
	ANTHROPIC_API_KEY=ci ACCOUNTS_SERVICE_TOKEN=ci \
		$(COMPOSE) --env-file .env.example config -q

# `kubectl kustomize` renders LOCALLY and is the only offline way to validate these manifests.
# NOTE: `kubectl apply -k --dry-run=client` is NOT usable here despite its name -- it still calls the
# API server to download the OpenAPI schema, so it dies with "failed to download openapi:
# connection refused" wherever no cluster is reachable (i.e. in CI). Schema-aware validation lives
# in `k8s-diff`, which is honest about needing a cluster. The render output is discarded: the point
# is that it renders at all.
k8s_check:               ## render the kustomize overlay locally (offline; catches bad refs/keys)
	kubectl kustomize $(K8S_DIR) > /dev/null

# -- composites --
check: compose_check k8s_check  ## everyday gate after a manifest change: render compose + kustomize (offline)
ci: check                       ## gate CI runs verbatim; same as `check` -- this repo has no code to test

######################
# DOCKER COMPOSE
######################

up:                   ## Build and start the full stack (postgres+redis+accounts+agent+service+ui)
	$(COMPOSE) up --build -d
	@echo "UI: http://localhost:$${UI_PORT:-8080}"

up-fg:                ## Same as up, but in the foreground (stream logs)
	$(COMPOSE) up --build

down:                 ## Stop the stack (keep volumes)
	$(COMPOSE) down

clean:                ## Stop and DELETE volumes (postgres data + generated keys)
	$(COMPOSE) down -v

logs:                 ## Follow logs for all services
	$(COMPOSE) logs -f

# The debugging counterpart to compose_check: uses your real .env and PRINTS the result, where
# compose_check uses .env.example and stays quiet.
config:               ## Validate and print the merged compose config (uses your .env)
	$(COMPOSE) config

build:                ## Build all images without starting (needs the sibling repos checked out)
	$(COMPOSE) build

ps:                   ## Show service status
	$(COMPOSE) ps

######################
# KUBERNETES
######################

k8s-keys:             ## Generate an RS256 keypair and load it as the `jwt-keys` Secret (run once)
	@mkdir -p keys
	@test -f keys/private.pem || ( \
		openssl genpkey -algorithm RSA -out keys/private.pem -pkeyopt rsa_keygen_bits:2048 && \
		openssl rsa -in keys/private.pem -pubout -out keys/public.pem && \
		chmod 600 keys/private.pem )
	kubectl -n $(NAMESPACE) create secret generic jwt-keys \
		--from-file=private.pem=keys/private.pem \
		--from-file=public.pem=keys/public.pem \
		--dry-run=client -o yaml | kubectl apply -f -

k8s-secrets:          ## Create the app-secrets Secret from your .env (LLM keys, service token, db password)
	kubectl -n $(NAMESPACE) create secret generic app-secrets \
		--from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -

k8s-apply:            ## Apply all manifests (namespace, stores, apps, ingress) via kustomize
	kubectl apply -k $(K8S_DIR)

k8s-delete:           ## Delete everything in the namespace
	kubectl delete -k $(K8S_DIR) || true

# NEEDS A LIVE CLUSTER -- this is the check `k8s_check` cannot be. It validates the manifests against
# the cluster's real API schema (so a wrong apiVersion or an unknown field is caught) and shows what
# an apply would change. Kept out of `ci` for exactly that reason. Replaces the old `k8s-validate`,
# which claimed to be client-side but silently required a cluster too.
k8s-diff:             ## Server-side diff/validate against the CURRENT cluster (needs a kubectl context)
	kubectl diff -k $(K8S_DIR)

######################
# HELP
######################

help:
	@echo '--- checks (local == CI; see .github/workflows/ci.yml) ---'
	@echo 'check                        - everyday gate after a manifest change: compose + kustomize render (offline)'
	@echo 'ci                           - faithful GitHub CI mirror; same as check (this repo has no code)'
	@echo 'compose_check                - render/validate docker-compose.yml against .env.example'
	@echo 'k8s_check                    - render the kustomize overlay locally (offline)'
	@echo ''
	@echo '--- docker compose (single host / local) ---'
	@echo 'up                           - build + start the full stack, detached'
	@echo 'up-fg                        - same as up, in the foreground (stream logs)'
	@echo 'down                         - stop the stack (keep volumes)'
	@echo 'clean                        - stop and DELETE volumes (postgres data + generated keys)'
	@echo 'logs                         - follow logs for all services'
	@echo 'config                       - print the merged compose config (uses your .env)'
	@echo 'build                        - build all images without starting (needs the sibling repos)'
	@echo 'ps                           - show service status'
	@echo ''
	@echo '--- kubernetes ---'
	@echo 'k8s-keys                     - generate an RS256 keypair -> the jwt-keys Secret (once)'
	@echo 'k8s-secrets                  - create app-secrets from your .env'
	@echo 'k8s-apply                    - kustomize apply: config, stores, apps, ingress'
	@echo 'k8s-delete                   - delete everything in the namespace'
	@echo 'k8s-diff                     - server-side diff vs the current cluster (needs a cluster)'
