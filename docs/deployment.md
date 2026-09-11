# Deployment and operations

Three ways to run the project, in order of how much you need installed: Docker Compose (everything),
the one-command contract demo (Foundry only), or the native stack (Foundry + Node + Postgres).

> **This is a demo protocol.** It deploys mock tokens and, by default, mock price feeds. Locally it uses
> Anvil's publicly known test keys, which is safe precisely because they control nothing. Never fund
> them anywhere real, and never point this at real assets.

---

## 1. Prerequisites

| | Version used | Needed for |
|---|---|---|
| [Foundry](https://book.getfoundry.sh/getting-started/installation) | forge 1.5.x (Solidity 0.8.28) | contracts, tests, deploy, demo |
| Node.js | 20.x | indexer, API, monitor, frontend |
| pnpm | 10.x | workspace install |
| Docker + Compose | any recent | the full stack, or just Postgres |

```bash
git clone --recurse-submodules https://github.com/pranay123-stack/risk-aware-lending-protocol
cd risk-aware-lending-protocol

# if you cloned without --recurse-submodules:
git submodule update --init --recursive   # forge-std, openzeppelin-contracts

pnpm install             # workspace; .npmrc sets ignore-scripts=true
```

`ignore-scripts=true` is deliberate: no dependency runs install-time scripts on your machine.

<a id="demo"></a>

## 2. The fastest path: the contract demo (Foundry only)

```bash
scripts/demo.sh
```

One command, no database, no Node. It covers the brief's 12 steps end to end:

| Steps | What happens |
|---|---|
| 1 | start Anvil (chain 31337) if one isn't already running |
| 2–5 | deploy the protocol, mock tokens and mock oracles; list WETH/WBTC/USDC; deploy the ERC-4626 vaults; hand every admin role to the timelock |
| 6–7 | mint test tokens to Alice, Bob, Carol and a liquidator |
| 8 | Alice supplies 250,000 USDC + 100 WETH (and 10,000 USDC through the vault); Bob posts 10 WETH; Carol posts 5 WBTC |
| 9 | Bob borrows 15,000 USDC (HF 1.375); Carol borrows 150,000 USDC (HF 1.56) |
| 10 | ETH/USD falls $2,500 → $1,800 on **both** feeds, so the deviation check still passes; Bob's HF → 0.99 |
| 11 | a liquidator repays 7,500 USDC (50% close factor) and receives 4.375 WETH (+5% bonus) |
| 12 | final state, read back **from the chain**, not from the script's simulation |

The script refuses to run against anything that isn't a fresh local chain 31337, so it can never touch a
real network. Set `ANVIL_PORT` to use a different port, `DEPLOYMENT_OUT` to write the deployment
elsewhere.

Read-only state dump at any time:

```bash
forge script script/ShowState.s.sol --rpc-url http://127.0.0.1:8545
```

## 3. The full stack with Docker Compose

```bash
docker compose up --build
# open http://localhost:3400
```

That brings up, in dependency order: **anvil** → **deployer** (deploys and runs the demo scenario) →
**postgres** → **indexer**, **api**, **monitor** → **frontend**.

| Service | Host port | Notes |
|---|---|---|
| anvil | 8545 | auto-mining; chain state persisted to a volume every 10 s, so a restart keeps the protocol |
| postgres | 5475 | `lending` / `lending` / `lending` |
| api | 4400 | REST + WebSocket, Swagger UI at `/docs` |
| frontend | 3400 | Next.js standalone build |
| indexer, monitor | – | no ports |

Everything binds to `127.0.0.1` only. Ports are configurable through `.env`
(`ANVIL_PORT`, `PG_PORT`, `API_PORT`, `FRONTEND_PORT`); CORS follows `FRONTEND_PORT` automatically.
`RUN_DEMO=false` deploys without running the scenario.

The deployer is **idempotent**: if it finds a deployment file matching the running chain, it skips
straight to serving. It runs as your user (`HOST_UID`/`HOST_GID`) so nothing root-owned lands in the repo.

```bash
make up        # docker compose up -d --build
make logs      # follow
make down      # stop
make reset     # stop and delete the volumes (fresh chain and database)
```

## 4. The native stack (for development)

```bash
# 1. chain + protocol + demo data
scripts/demo.sh                                    # leaves Anvil running on :8545

# 2. build the TypeScript packages and start the database
make build                                         # forge build + typed ABIs + all TS packages
make db                                            # Postgres 16 container on :5475 (lending + lending_test)
pnpm db:migrate                                    # apply migrations

# 3. services (separate terminals)
pnpm --filter @lending/indexer dev                 # or: pnpm indexer   (built output)
pnpm --filter @lending/backend dev:api             # or: pnpm api
pnpm --filter @lending/backend dev:monitor         # or: pnpm monitor
pnpm --filter @lending/frontend dev                # http://localhost:3400
```

No `.env` is needed for the defaults. Copy `.env.example` to `.env` only to change ports or target a
testnet.

| Variable | Default | Used by |
|---|---|---|
| `RPC_URL` | `http://127.0.0.1:8545` | all services |
| `DATABASE_URL` | `postgres://lending:lending@127.0.0.1:5475/lending` | indexer, API, monitor |
| `DEPLOYMENT_FILE` | `../deployments/31337.json` | all services |
| `CONFIRMATIONS` | 0 on chain 31337, 3 elsewhere | indexer |
| `POLL_INTERVAL_MS`, `BATCH_SIZE`, `REORG_WINDOW` | 1000, 500, 128 | indexer |
| `API_PORT`, `API_HOST`, `CORS_ORIGINS` | 4400, 0.0.0.0, localhost:3400 | API |
| `CHAIN_CACHE_MS` | 2000 | API |
| `MONITOR_INTERVAL_MS` | 10000 | monitor |
| `PRICE_KEEPER_ENABLED` | true on 31337 | monitor |
| `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_RPC_URL`, `NEXT_PUBLIC_DEV_WALLETS` | localhost:4400, localhost:8545, true | frontend (build time) |

### Deployment artefact

`Deploy.s.sol` writes `deployments/<chainId>.json`: chain id, start block, every contract address, the
markets with their token/feed/IRM/vault addresses, and the guardian, proposer and timelock. Every
service reads it, so nothing hard-codes an address. Changing the deployment resets the indexer's
chain-derived tables automatically (it keys its cursor on chain id + pool address).

## 5. Operating the stack

| Task | Command |
|---|---|
| Health, lag, dependency status | `curl localhost:4400/health` |
| Follow live events | `websocat ws://localhost:4400/ws` (or the app's activity feed) |
| Re-index from scratch | stop the indexer, `DELETE FROM blocks;`, restart: it replays from `startBlock` |
| Chain restarted / re-deployed | nothing to do: the indexer detects a different deployment or a reset chain and re-indexes |
| Apply a parameter change | Admin page → propose → wait out the timelock (60 s locally) → execute |
| Emergency pause | Admin page → Emergency controls (guardian account) |

The indexer self-heals in the three cases that matter: a **reorg** (rolls back to the common ancestor and
re-indexes), a **restarted chain** (detects the hash mismatch and re-indexes from the start block), and a
**crash mid-batch** (the batch and cursor commit in one transaction, so it simply replays). All three are
covered by tests ([testing.md](testing.md#5-off-chain-tests)).

<a id="optional-public-testnet"></a>

## 6. Optional: a public testnet

Nothing in this project needs a public deployment, and the frontend is wired for the local chain only
(`wagmi.ts` lists just the Foundry chain, and the dev-wallet connectors only work against an unlocked
Anvil node). Pointing the UI at a testnet means adding that chain to `wagmi.ts` and setting
`NEXT_PUBLIC_DEV_WALLETS=false` so only real wallets appear.

If you deploy contracts to a testnet anyway:

```bash
export DEPLOYER_PRIVATE_KEY=0x...        # a FRESH key, created for this, funded from a faucet only
export TIMELOCK_PROPOSER=0x...           # not the deployer
export GUARDIAN=0x...                    # not the deployer
export TIMELOCK_DELAY=86400              # 1 day minimum
export FEEDS_MODE=chainlink              # or leave unset for mock feeds
export ETH_USD_FEED=0x... BTC_USD_FEED=0x... USDC_USD_FEED=0x...

forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --broadcast --verify
```

Safety properties built into the script:

- it **refuses** to run with Anvil's public key on any chain other than 31337;
- it **asserts on-chain** after deployment that the timelock holds `POOL_ADMIN` and `DEFAULT_ADMIN`, that
  the deployer holds neither, that the timelock administers itself, and that the delay is what you asked
  for. A deployment that doesn't end in that state fails loudly;
- the timelock delay defaults to 1 day off-chain-31337, and the liquidation grace period to 30 minutes.

Before you do it, work through the checklist in
[security.md](security.md#8-pre-deployment-checklist-for-any-public-deployment). In particular: take
feed addresses from Chainlink's official directory, and check each feed's real heartbeat against the
values in `MarketConfig.sol`, or the market will read `STALE` between updates. Tokens stay mocks; this
protocol must never custody real assets.

## 7. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `demo.sh` refuses to start | an Anvil with history is already running on that port. Stop it, or pass `ANVIL_PORT` / `RPC_URL` for a fresh one |
| API returns 503 | Anvil or Postgres is not reachable. `curl localhost:4400/health` names which one |
| Health factors show "unknown" | a mock feed went stale. Start the monitor (it runs the price keeper), or re-post a price from the Admin page |
| Frontend shows stale numbers after a transaction | 2-second chain-read cache plus the 15-second poll; the WebSocket push usually beats both |
| Everything is empty after restarting Anvil | the chain reset, so the protocol is gone. Re-run `scripts/demo.sh` (Docker persists chain state instead) |
| `pnpm install` warns about ignored build scripts | intentional (`ignore-scripts=true`) |
