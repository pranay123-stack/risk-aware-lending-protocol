# Risk-Aware Lending Protocol: common tasks. `make help` lists them.
SHELL := /bin/bash
.DEFAULT_GOAL := help
PG_TEST_CONTAINER := lending-pg

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

install: ## submodules + node dependencies (lifecycle scripts disabled via .npmrc)
	git submodule update --init --recursive
	pnpm install

build: ## contracts, typed ABIs, TypeScript services, frontend
	forge build
	pnpm abis
	pnpm build:all

# ------------------------------------------------------------------ contracts
test-contracts: ## unit + fuzz + invariant tests (fork test skips without MAINNET_RPC_URL)
	forge test

test-deep: ## deep invariant campaign (1024 runs x depth 150)
	FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'

gas: ## isolated gas benchmarks -> snapshots/GasBenchmarks.json
	FOUNDRY_PROFILE=gas forge test

slither: ## static analysis of production contracts
	slither . --filter-paths "lib/|test/|script/|contracts/mocks/" --exclude-dependencies

fmt: ## format Solidity
	forge fmt

lint: ## forge lint (production contracts)
	forge lint

# ------------------------------------------------------------------ off-chain
db: ## start a Postgres for native runs and TS tests (port 5475, DBs lending + lending_test)
	@docker ps -a --format '{{.Names}}' | grep -qx $(PG_TEST_CONTAINER) || docker run -d --name $(PG_TEST_CONTAINER) -e POSTGRES_USER=lending -e POSTGRES_PASSWORD=lending -e POSTGRES_DB=lending -p 127.0.0.1:5475:5432 postgres:16-alpine
	@docker start $(PG_TEST_CONTAINER) >/dev/null
	@sleep 3; docker exec $(PG_TEST_CONTAINER) psql -U lending -d lending -tc "SELECT 1 FROM pg_database WHERE datname='lending_test'" | grep -q 1 || docker exec $(PG_TEST_CONTAINER) psql -U lending -d lending -c "CREATE DATABASE lending_test"

test-ts: ## shared + indexer + backend (incl. real-Anvil e2e) + frontend unit tests; needs `make db`
	pnpm --filter @lending/shared build
	pnpm -r --filter=!@lending/e2e test

test: test-contracts test-ts ## everything

# ------------------------------------------------------------------ run
demo: ## the brief's 12-step scenario on a fresh Anvil (Foundry only)
	scripts/demo.sh

up: ## full stack in Docker: http://localhost:3400
	HOST_UID=$$(id -u) HOST_GID=$$(id -g) docker compose up --build -d
	@echo "frontend http://localhost:3400  ·  API http://localhost:4400/docs  ·  RPC http://localhost:8545"

down: ## stop the stack (keeps chain + database volumes)
	docker compose down

reset: ## stop the stack and wipe chain + database volumes
	docker compose down -v
	rm -f deployments/31337.json

logs: ## follow service logs
	docker compose logs -f indexer api monitor

e2e-ui: ## browser click-through against a running stack in its demo state (needs Chrome)
	cd e2e && node ui-flow.mjs

.PHONY: help install build test-contracts test-deep gas slither fmt lint db test-ts test demo up down reset logs e2e-ui
