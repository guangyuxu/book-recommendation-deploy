# Deploy helpers for the book-recommendation platform (Docker Compose + Kubernetes).
.DEFAULT_GOAL := help

COMPOSE := docker compose
K8S_DIR := k8s
NAMESPACE := book-rec

# ---------------------------------------------------------------- Docker Compose
.PHONY: up
up: ## Build and start the full stack (postgres+redis+accounts+agent+service+ui)
	$(COMPOSE) up --build -d
	@echo "UI: http://localhost:$${UI_PORT:-8080}"

.PHONY: up-fg
up-fg: ## Same as up, but in the foreground (stream logs)
	$(COMPOSE) up --build

.PHONY: down
down: ## Stop the stack (keep volumes)
	$(COMPOSE) down

.PHONY: clean
clean: ## Stop and DELETE volumes (postgres data + generated keys)
	$(COMPOSE) down -v

.PHONY: logs
logs: ## Follow logs for all services
	$(COMPOSE) logs -f

.PHONY: config
config: ## Validate and render the merged compose config
	$(COMPOSE) config

.PHONY: build
build: ## Build all images without starting
	$(COMPOSE) build

.PHONY: ps
ps: ## Show service status
	$(COMPOSE) ps

# ---------------------------------------------------------------- Kubernetes
.PHONY: k8s-keys
k8s-keys: ## Generate an RS256 keypair and load it as the `jwt-keys` Secret (run once)
	@mkdir -p keys
	@test -f keys/private.pem || ( \
		openssl genpkey -algorithm RSA -out keys/private.pem -pkeyopt rsa_keygen_bits:2048 && \
		openssl rsa -in keys/private.pem -pubout -out keys/public.pem && \
		chmod 600 keys/private.pem )
	kubectl -n $(NAMESPACE) create secret generic jwt-keys \
		--from-file=private.pem=keys/private.pem \
		--from-file=public.pem=keys/public.pem \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: k8s-secrets
k8s-secrets: ## Create the app-secrets Secret from your .env (LLM keys, service token, db password)
	kubectl -n $(NAMESPACE) create secret generic app-secrets \
		--from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: k8s-apply
k8s-apply: ## Apply all manifests (namespace, stores, apps, ingress) via kustomize
	kubectl apply -k $(K8S_DIR)

.PHONY: k8s-delete
k8s-delete: ## Delete everything in the namespace
	kubectl delete -k $(K8S_DIR) || true

.PHONY: k8s-validate
k8s-validate: ## Client-side validate the manifests
	kubectl apply -k $(K8S_DIR) --dry-run=client

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
