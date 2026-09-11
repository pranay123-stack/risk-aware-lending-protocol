# API

REST + WebSocket service over the indexed history and live chain state. The machine-readable contract is
[`backend/openapi.yaml`](../backend/openapi.yaml), served at `/openapi.json` with Swagger UI at
**`/docs`**. A contract test fails the build if a route and the spec disagree in either direction, so the
spec cannot rot.

Base URL locally: `http://localhost:4400`.

---

## 1. Design

**Live state comes from the chain; history comes from Postgres.** Balances, health factors, rates and
prices are read through `PoolLens` (batched, with a 2-second cache). They are never recomputed from
indexed events, which would drift silently. The database holds what a chain read cannot answer: events,
liquidation history, rate and index snapshots, price history, risk snapshots and timelock operations.

**Read-only.** Every route is `GET`. The service holds no key that can move funds or change parameters.
Transactions are signed by the user's wallet in the browser.

**Amounts are never floats.** Every token amount is returned as an object:

```json
{ "raw": "6750000000", "amount": 6750, "usd": 6750 }
```

`raw` is the exact integer in token units, and is what a client should use for arithmetic or to build a
transaction. `amount` and `usd` are convenience numbers for display. The same rule holds in the database:
amounts are stored as exact integers, with a regression test that no `uint256` ever passes through a
float.

**Errors** are a typed envelope with a stable machine-readable code:

```json
{ "error": { "code": "INVALID_ADDRESS", "message": "address must be a 20-byte hex address" } }
```

`400` for invalid input, `404` for an unknown account or market, `503` when the chain RPC or database is
unavailable. Chain failures are never dressed up as empty results.

## 2. Endpoints

### System

| Route | Returns |
|---|---|
| `GET /health` | `status`, database and chain reachability, `chainHead`, `indexedBlock`, `indexerLagBlocks` |
| `GET /config` | chain id and every deployed contract address |
| `GET /events?limit&name` | recent decoded protocol events (`name` filters by event, e.g. `LiquidationCall`) |

```json
{ "status": "ok", "database": "ok", "chainHead": 67, "indexedBlock": 67, "indexerLagBlocks": 0, "chain": "ok" }
```

### Markets

| Route | Returns |
|---|---|
| `GET /markets` | every listed market, live |
| `GET /markets/{asset}` | one market plus its rate curve and rate history (`asset` is the token address) |

Each market carries price and price status, supplied/borrowed/available/treasury/deficit amounts,
utilization, supply and borrow APR **and** APY, the full risk configuration, the interest-rate model
parameters, and the current indexes:

```json
{
  "asset": "0x8A79...C318", "symbol": "WETH", "decimals": 18,
  "price": { "usd": 1260, "raw": "1260000000000000000000", "status": "OK" },
  "totalSupplied": { "raw": "100000000000000000000", "amount": 100, "usd": 126000 },
  "availableLiquidity": { "raw": "100000000000000000000", "amount": 100, "usd": 126000 },
  "deficit": { "raw": "0", "amount": 0, "usd": 0 },
  "utilization": 0, "supplyApr": 0, "borrowApr": 0, "borrowApy": 0,
  "config": { "ltv": 0.8, "liquidationThreshold": 0.825, "liquidationBonus": 0.05,
              "reserveFactor": 0.15, "supplyCap": "100000", "borrowCap": "80000",
              "active": true, "frozen": false, "paused": false,
              "borrowingEnabled": true, "collateralEnabled": true },
  "interestRateModel": { "baseRate": 0, "slope1": 0.04, "slope2": 0.8, "optimalUtilization": 0.8 },
  "indexes": { "liquidity": "1000000000000000000000000000", "borrow": "1000000000000000000000000000" }
}
```

### Accounts

| Route | Returns |
|---|---|
| `GET /accounts/{address}` | health and non-empty positions |
| `GET /accounts/{address}/positions` | a position in every market: balances, wallet balance, **allowance to the pool**, max borrow, max withdraw |
| `GET /accounts/{address}/health-factor` | health factor, risk level, distance to liquidation |
| `GET /accounts/{address}/history?limit&offset` | that account's protocol events |

```json
{
  "address": "0x3C44...93BC", "blockNumber": 67, "priced": true,
  "healthFactor": null,
  "healthFactorRaw": "115792089237316195423570985008687907853269984665640564039457584007913129639935",
  "riskLevel": "SAFE", "distanceToLiquidation": null
}
```

Three conventions matter here:

- `healthFactor` is `null` when the account has no debt (infinite), with the raw `uint256` sentinel kept
  in `healthFactorRaw`. Clients never have to special-case a magic float.
- `priced: false` means an oracle the account is exposed to is unavailable. The account then classifies as
  `UNKNOWN`, not as safe or liquidatable ([risk-model.md](risk-model.md#5-off-chain-risk-levels)).
- `maxBorrow` and `maxWithdraw` already include the 1 ppm haircut, so a "Max" button always produces an
  executable transaction.

### Protocol

| Route | Returns |
|---|---|
| `GET /protocol/tvl` | supplied, borrowed, available, treasury, **deficit**, and a per-market breakdown |
| `GET /protocol/utilization` | aggregate and per-market utilization |
| `GET /protocol/borrow-rate` · `GET /protocol/supply-rate` | APR and APY per market |
| `GET /protocol/status` | pause state, liquidation grace window, timelock delay |

```json
{ "tvlUsd": 686000.35, "totalBorrowedUsd": 150000.35, "availableLiquidityUsd": 534750,
  "treasuryUsd": 0.03, "deficitUsd": 1249.999466, "utilization": 0.2187,
  "markets": [ { "symbol": "WETH", "suppliedUsd": 126000, "borrowedUsd": 0 } ] }
```

### Liquidations

| Route | Parameters | Returns |
|---|---|---|
| `GET /liquidations` | `limit`, `offset`, `borrower`, `liquidator` | executed liquidations, valued **at the prices of their own block**, with the liquidator's profit |
| `GET /liquidations/preview` | `borrower`, `collateral`, `debt` (required), `amount` | the pool's own maths: close factor, repay, seize, USD values, and a `LEAVES_DUST` status when a partial amount would revert |
| `GET /liquidations/candidates` | `limit` | at-risk accounts from the last sweep, re-checked live, each with its most profitable liquidation |

```json
{
  "txHash": "0x3ed7...98e3", "blockNumber": 64, "blockTime": "2026-09-11T17:52:21.000Z",
  "borrower": "0x3c44...93bc", "liquidator": "0x15d3...6a65", "receiveSupply": false,
  "debt": { "symbol": "USDC", "raw": "6750000000", "amount": 6750, "usd": 6750 },
  "collateral": { "symbol": "WETH", "raw": "5625000000000000000", "amount": 5.625, "usd": 7087.5 },
  "liquidatorProfitUsd": 337.5
}
```

Historical liquidations are valued at the price recorded for their block, not today's price. Valuing a
year-old liquidation at today's ETH price would invent a profit or loss that nobody experienced.

### Risk

| Route | Parameters | Returns |
|---|---|---|
| `GET /risk/summary` | | accounts and debt per risk level, potential bad debt, insolvent accounts, open alert counts |
| `GET /risk/accounts` | `level`, `limit` | indebted accounts from the latest sweep, riskiest first |
| `GET /risk/alerts` | `status` (`open`/`resolved`/`all`), `limit` | monitor alerts |
| `GET /risk/markets` | | live market findings: utilization, liquidity, oracle health, bad debt |

```json
{ "lastSweep": "2026-09-11T18:24:36.715Z", "lastSweepBlock": 67,
  "levels": { "SAFE": { "accounts": 5, "debtUsd": 150000.35, "collateralUsd": 686000.31 },
              "WARNING": { "accounts": 0 }, "DANGER": { "accounts": 0 },
              "LIQUIDATABLE": { "accounts": 0 }, "UNKNOWN": { "accounts": 0 } },
  "potentialBadDebtUsd": 0, "insolventAccounts": 0,
  "openAlerts": { "info": 1, "critical": 1 } }
```

### Oracles, governance, analytics

| Route | Parameters | Returns |
|---|---|---|
| `GET /oracle/prices` | | resolved price plus **per-feed** status, age and heartbeat for every asset |
| `GET /oracle/history` | `asset` | indexed feed updates |
| `GET /governance/timelock` | | timelocked operations with **decoded** calls, status and ETA |
| `GET /analytics` | `hours` (1–720) | totals plus TVL, utilization, rate and activity history |

`/oracle/prices` reports each feed separately, so a degraded state (`OK_PRIMARY_ONLY`, `OK_FALLBACK`) is
visible before it becomes an outage. `/governance/timelock` decodes each queued call into a readable
function and arguments, so a pending parameter change can be read without an explorer.

## 3. WebSocket

`GET /ws` upgrades to a WebSocket. On connect the server sends:

```json
{ "type": "hello", "channels": ["lending_events", "risk_alerts"] }
```

Then it pushes two message kinds:

| Channel | Sent when | Payload |
|---|---|---|
| `lending_events` | the indexer commits a batch containing events | `fromBlock`, `toBlock`, per-event-name counts, up to 10 liquidations |
| `lending_events` | a reorg is rolled back | `{ "type": "reorg", "rolledBackTo": "...", "depth": n }` |
| `risk_alerts` | the monitor opens or resolves an alert | the alert rows that changed |

The transport is Postgres `LISTEN`/`NOTIFY`: the indexer and monitor publish inside their own
transactions, so a message is only ever sent for **committed** data, and the API relays it without
knowing how it was produced. If the listener connection drops it reconnects on its own.

## 4. Risk monitor

A separate process (`backend/dist/monitor.js`) that sweeps every known account and market on an interval
(`MONITOR_INTERVAL_MS`, default 10 s):

1. read all markets and all indexed accounts through `PoolLens` (batched, try/catch per account);
2. classify each account `SAFE / WARNING / DANGER / LIQUIDATABLE / UNKNOWN` and evaluate market findings;
3. write risk snapshots (health factors stored exactly, `NULL` for debt-free accounts);
4. **reconcile** alerts: a partial unique index on open `(kind, subject)` means a condition that persists
   for a hundred sweeps is one alert, resolved automatically when it clears;
5. `pg_notify` the changes, which the API relays to WebSocket clients.

Locally it also runs the **MockPriceKeeper**, which re-posts unchanged mock feed answers before they go
stale ([oracles.md](oracles.md#7-local-and-testnet-feeds)). It refuses to run on any chain but 31337.

## 5. Client notes

- Pagination: `limit` (1–500, default 50) and `offset` where listed. `/liquidations` also returns
  `total` for the current filter.
- Addresses are accepted in any case and compared case-insensitively; stored values are lowercase.
- CORS is an allowlist (`CORS_ORIGINS`), and only `GET` is allowed.
- There is **no rate limiting**. A public deployment needs a reverse proxy in front
  ([threat-model.md](threat-model.md), T37).
- Chain reads are cached for 2 seconds, so a freshly mined transaction can take that long to show up.
  The app waits for the transaction receipt and then invalidates its queries; anything still stale
  converges on the next WebSocket push or the 15-second poll.
