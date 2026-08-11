.PHONY: help generate buf-generate sqlc-generate dev dev-infra dev-infra-stop dev-infra-reset api \
	migration-create migration-up migration-down migration-status \
	go-build go-test go-fmt ci ci-buf ci-go ios-generate \
	railway-secrets railway-deploy railway-logs railway-check

BLUE := \033[34m
GREEN := \033[32m
RESET := \033[0m

BACKEND := apps/backend
MIGRATIONS_DIR := $(BACKEND)/deployments/migrations
COMPOSE := docker compose -f $(BACKEND)/deployments/compose.yml

# Read straight out of the committed dev env file so `make migration-up` and the
# server can never disagree about which database they mean.
DEV_DATABASE_URL := $(shell grep -E '^DATABASE_URL=' $(BACKEND)/.env.development | cut -d= -f2-)

help:
	@printf '$(BLUE)make dev$(RESET)              start Postgres, run the API\n'
	@printf '$(BLUE)make generate$(RESET)         regenerate protobuf (Go + Swift) and sqlc\n'
	@printf '$(BLUE)make migration-create$(RESET) name=add_widgets\n'
	@printf '$(BLUE)make ci$(RESET)               lint and test everything\n'

# ---------------------------------------------------------------------------
# Codegen
# ---------------------------------------------------------------------------

generate: buf-generate sqlc-generate

# One command writes both the Go types and the Swift types. That is the whole
# argument for the protobuf IDL: hand-written Codable structs drifting against
# hand-written Go structs is the bug the schema exists to prevent, and it only
# holds if regenerating both is a single step nobody can half-do.
buf-generate:
	@printf '$(BLUE)[buf]$(RESET) generate\n'
	@buf generate

sqlc-generate:
	@printf '$(BLUE)[sqlc]$(RESET) generate\n'
	@cd $(BACKEND) && sqlc generate

# ---------------------------------------------------------------------------
# Local development
# ---------------------------------------------------------------------------

dev: dev-infra api

# Just Postgres. Verification goes to the real Prelude API in every
# environment; the dev skip button works in-process off DEV_BYPASS_PHONE_NUMBERS,
# so there is nothing local to stand in for it.
dev-infra:
	@printf '$(BLUE)[docker]$(RESET) postgres up\n'
	@$(COMPOSE) up -d --wait --remove-orphans db
	@printf '$(GREEN)postgres :5432$(RESET)\n'

dev-infra-stop:
	@$(COMPOSE) down

# Drops the volume. The server migrates on boot, so this is the whole reset.
dev-infra-reset:
	@$(COMPOSE) down -v
	@$(MAKE) dev-infra

api:
	@printf '$(BLUE)[api]$(RESET) starting\n'
	@cd $(BACKEND) && go run ./cmd/api

# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------
#
# The server runs `goose up` itself at boot, so these are for authoring and for
# rolling back — not part of the deploy path.

migration-create:
	@if [ -z "$(name)" ]; then \
		printf 'usage: make migration-create name=add_widgets_table\n' >&2; \
		exit 1; \
	fi
	@printf '$(BLUE)[goose]$(RESET) create %s\n' "$(name)"
	@file=$$(goose -s -dir $(MIGRATIONS_DIR) create "$(name)" sql 2>&1 | awk '/Created new file:/ {print $$NF}'); \
	if [ -z "$$file" ]; then printf 'failed to create migration\n' >&2; exit 1; fi; \
	printf '%s\n\n%s\n' '-- +goose Up' '-- +goose Down' > "$$file"; \
	printf '$(GREEN)%s$(RESET)\n' "$$file"

migration-up:
	@goose -dir $(MIGRATIONS_DIR) postgres "$(DEV_DATABASE_URL)" up

migration-down:
	@goose -dir $(MIGRATIONS_DIR) postgres "$(DEV_DATABASE_URL)" down

migration-status:
	@goose -dir $(MIGRATIONS_DIR) postgres "$(DEV_DATABASE_URL)" status

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

go-build:
	@cd $(BACKEND) && go build ./...

go-test:
	@cd $(BACKEND) && go test ./...

go-fmt:
	@cd $(BACKEND) && gofmt -w .

ci: ci-buf ci-go

# The breaking check is non-fatal for now. The client is a shipped app, so a
# wire-incompatible schema change breaks installs that are already out there —
# but until `protos/` exists on main there is no baseline to compare against, and
# buf reports that absence as a failure. Make it fatal once main carries the
# schema and a released build depends on it.
ci-buf:
	@printf '$(BLUE)[buf]$(RESET) lint\n'
	@buf lint
	@printf '$(BLUE)[buf]$(RESET) breaking (against main; skipped if main has no schema yet)\n'
	@buf breaking --against '.git#branch=main' 2>/dev/null || \
		printf '$(BLUE)[buf]$(RESET) no baseline on main — skipped\n'

ci-go:
	@printf '$(BLUE)[go]$(RESET) vet\n'
	@cd $(BACKEND) && go vet ./...
	@printf '$(BLUE)[go]$(RESET) test\n'
	@cd $(BACKEND) && go test ./...
	@printf '$(BLUE)[go]$(RESET) gofmt\n'
	@cd $(BACKEND) && test -z "$$(gofmt -l .)" || (gofmt -l . && exit 1)

ios-generate:
	@cd apps/ios && xcodegen generate

# ---------------------------------------------------------------------------
# Railway
# ---------------------------------------------------------------------------
#
# These wrap the CLI; they do not create anything. The project, the service and
# the Postgres plugin are made once in the dashboard, and two service settings
# have to be set by hand — see the header of apps/backend/railway.toml for why
# the config-file path is not optional.

railway-check:
	@command -v railway >/dev/null || { \
		printf '$(BLUE)[railway]$(RESET) CLI not installed: brew install railway\n' >&2; \
		exit 1; \
	}
	@printf '$(BLUE)[railway]$(RESET) '
	@railway whoami

# Prints the two secrets to paste into the service variables.
#
# Not piped straight into `railway variables` on purpose: these are the keys to
# every session, and rotating them signs everybody out, so setting them should be
# a thing you did rather than a thing that happened. They differ because the
# server refuses to boot if they match.
railway-secrets:
	@printf '$(BLUE)[railway]$(RESET) paste these into the service variables\n\n'
	@printf 'JWT_SECRET=%s\n' "$$(openssl rand -hex 32)"
	@printf 'REFRESH_TOKEN_HMAC_KEY=%s\n' "$$(openssl rand -hex 32)"
	@printf '\nDATABASE_URL comes from the Postgres plugin. Also set:\n'
	@printf '  ENV=production\n'
	@printf '  PRELUDE_API_KEY\n'

# Deploys the working tree, which is the point — use it for a first deploy or a
# hotfix, and let the GitHub integration handle everything else.
railway-deploy: railway-check
	@printf '$(BLUE)[railway]$(RESET) deploying $(BACKEND)\n'
	@cd $(BACKEND) && railway up

railway-logs: railway-check
	@cd $(BACKEND) && railway logs
