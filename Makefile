# onebox — the human interface. Every target is a thin wrapper around deploy.sh (host
# operations) or tests/run.sh (static checks). See `make help`.
#
#   sudo make bootstrap          first run on a fresh host
#   sudo make <component>        converge one component (edge, gitlab, k3s, …)
#   sudo make check [TAGS=a,b]   dry run with diff
#   make test                    static checks (no host needed)

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV ?=
ifneq ($(ENV),)
export ONEBOX_ENV := $(ENV)
endif

COMPONENTS := common operators storage tailscale edge datastores openbao casdoor gitlab \
              gitlab-runner k3s k3s-gateway external-secrets argocd argo-rollouts

DEPLOY := ./deploy.sh

# TAGS is only honoured by `check`. Anywhere else make would silently ignore it and
# converge the whole host, so refuse instead.
define no_tags
	@if [ -n "$(TAGS)" ]; then \
	  echo "TAGS= only works with 'make check'; to converge one component run: make <component>" >&2; \
	  exit 1; \
	fi
endef

# Writing secrets.yml as root would leave it root-owned and uneditable for its owner.
define no_root
	@if [ "$$(id -u)" = 0 ]; then \
	  echo "run this target without sudo (it rewrites your secrets.yml)" >&2; \
	  exit 1; \
	fi
endef

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  Components (make <name>): $(COMPONENTS)"
	@echo "  Environment: ENV=<name> (inventories/<name>), auto-picked when there is only one."

# ── Environments and secrets ───────────────────────────────────────────────────────

.PHONY: init
init: ## Create inventories/$(ENV) from the example (ENV=<name>)
	$(no_root)
	@test -n "$(ENV)" || { echo "usage: make init ENV=<name>" >&2; exit 1; }
	@test ! -e inventories/$(ENV) || { echo "inventories/$(ENV) already exists" >&2; exit 1; }
	cp -r inventories/example inventories/$(ENV)
	install -m 600 secrets.example.yml inventories/$(ENV)/group_vars/onebox/secrets.yml
	sed -i 's/^onebox_env: .*/onebox_env: $(ENV)/' inventories/$(ENV)/group_vars/onebox/main.yml
	@echo "Edit inventories/$(ENV)/group_vars/onebox/main.yml, then fill secrets with make secrets-gen / secrets-set."

SECRETS_FILE = inventories/$$($(DEPLOY) env)/group_vars/onebox/secrets.yml

.PHONY: secrets-gen secrets-set secrets-show secrets-missing
secrets-gen: ## Generate a random value for KEY (KEY=<name> [LENGTH=32])
	$(no_root)
	@python3 scripts/secrets.py gen "$(SECRETS_FILE)" "$(KEY)" "$(or $(LENGTH),32)"
secrets-set: ## Paste a value for KEY without echo or shell history (KEY=<name>)
	$(no_root)
	@python3 scripts/secrets.py set "$(SECRETS_FILE)" "$(KEY)"
secrets-show: ## Print the value of KEY (KEY=<name>)
	@python3 scripts/secrets.py show "$(SECRETS_FILE)" "$(KEY)"
secrets-missing: ## List keys that still hold a CHANGE-ME placeholder
	@python3 scripts/secrets.py missing "$(SECRETS_FILE)"

# ── Host operations ────────────────────────────────────────────────────────────────

.PHONY: bootstrap apply check status
bootstrap: ## Install ansible-core and converge everything (fresh host, as root)
	$(no_tags)
	$(DEPLOY) bootstrap
apply: ## Converge every enabled component
	$(no_tags)
	$(DEPLOY) apply
check: ## Dry run with diff (optionally TAGS=a,b)
	$(DEPLOY) check $(if $(TAGS),--tags $(TAGS))
status: ## Show the state of the enabled components
	$(no_tags)
	$(DEPLOY) status

.PHONY: $(COMPONENTS)
$(COMPONENTS):
	$(no_tags)
	$(DEPLOY) apply --tags $@

# ── Development ────────────────────────────────────────────────────────────────────

.PHONY: tools test lint render
tools: ## Install the pinned check tools into .tools/
	tests/tools.sh
test: ## Run every static check (lint, syntax, render, validators)
	tests/run.sh all
lint: ## Linters only (shellcheck, yamllint, ansible-lint)
	tests/run.sh lint
render: ## Render every template into .render/ for inspection
	tests/run.sh render
