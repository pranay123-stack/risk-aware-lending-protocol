# Gas report

Every number below was measured, not estimated. Benchmarks live in
[`test/gas/GasBenchmarks.t.sol`](../test/gas/GasBenchmarks.t.sol), results in
[`snapshots/GasBenchmarks.json`](../snapshots/GasBenchmarks.json). Regenerate with:

```bash
make gas            # = FOUNDRY_PROFILE=gas forge test
```

---

## 1. Methodology

- **Isolated transactions.** The `gas` profile sets `isolate = true`, so every top-level call runs as its
  own transaction. Cold and warm storage access (EIP-2929) is therefore priced as on mainnet, not as one
  giant warm test transaction. A plain `forge test` would under-report every number, which is why the
  default profile excludes `test/gas/*` and only the `gas` profile runs it.
- **Full transaction cost.** Figures are `gasUsed` as a receipt would report it: the 21,000 base cost,
  calldata and execution. As a calibration, an empty external call measures 21,161 under the same setup.
- **A live market, not an empty one.** `setUp` supplies liquidity to every reserve, opens an unrelated
  borrow and advances time by a day. Rates are non-zero and indexes have moved, so every action pays
  for real accrual and rate updates, not the empty-market fast path.
- **Production settings.** Solidity 0.8.28, `evm_version = cancun` (needed for transient storage),
  optimizer enabled with 1,000 runs, `bytecode_hash = none`.

## 2. Results

| Operation | Gas | Notes |
|---|---|---|
| `supply` (first, enables collateral) | **125,234** | fresh user position, collateral bit set, rates updated |
| `supply` (subsequent) | **83,602** | |
| `withdraw` (no debt, no oracle read) | **83,137** | debt-free exits read no price |
| `withdraw` (collateral, with debt: LTV check) | **160,711** | values the account: 2 reserves, 3 feeds (WETH has two sources) |
| `borrow` (first) | **189,570** | sets the borrowing bit, values the account |
| `borrow` (subsequent) | **169,395** | |
| `repay` (partial) | **92,699** | no oracle read |
| `repay` (full) | **93,311** | clears the borrowing bit |
| `setUseReserveAsCollateral(false)` (no debt) | **34,549** | no oracle read |
| `liquidate` (50% close factor, receive tokens) | **244,199** | valuation, 2 reserves accrued, 2 rate updates, 2 transfers |
| `liquidate` (`receiveSupply`) | **251,802** | credits a new supply position instead of a transfer |
| `liquidate` (collateral exhausted, bad-debt write-off) | **263,357** | plus the write-off loop and treasury absorption |

**Sanity check against a real chain.** On the demo Anvil chain, Bob's `borrow` used 210,030 gas and
Carol's 181,908, as reported in the receipts. Bob's is higher than the benchmark because it was the first
borrow ever in the USDC reserve, which turns its rate slot from zero to non-zero (a 20,000-gas `SSTORE`
instead of 2,900). The demo liquidation used 229,971. The benchmarks are in the same range, and the
differences are explained by zero-to-non-zero storage writes that depend on chain state.

### Where the gas goes

A price read is the single largest variable cost. A warm `OracleManager.getPrice` costs about **8.3k**
for WETH (two feeds plus the deviation check) and about **5.8k** for single-feed assets. That is why:

- supply, repay, debt-free withdraw and collateral toggles (with no debt) never read a price;
- valuation prices only the reserves in the user's bitmap ([risk-model.md](risk-model.md#1-account-valuation));
- liquidation reads each price once (optimisation 1 below).

## 3. Optimisations, with measured effect

| # | Change | Before | After | Δ |
|---|---|---|---|---|
| 1 | **Capture prices during valuation** and reuse them for the liquidation amounts, instead of calling the oracle again | liquidate 257,860 · bad-debt 277,018 · receiveSupply 265,463 | 244,199 · 263,357 · 251,802 | **−13.7k (−5.3%)** per liquidation; +402 on borrow and collateral-withdraw (shared valuation loop) |
| 2 | **`ReentrancyGuardTransient`** (EIP-1153) instead of the storage-based `ReentrancyGuard` | | | **−1,897 to −1,923** per guarded call (A/B measured on the same suite) |
| 3 | **Packed reserve storage.** 7 slots per reserve, grouped by what is written together (indexes, rates, totals, cash + treasury) | | | one `SSTORE` per slot per action, not one per field |
| 4 | **Bitmap account walk** (2 bits per reserve, stops when the remaining bitmap is zero) | | | valuation cost scales with markets *used*, not markets *listed*; worst case at the 32-reserve cap is bounded and tested |
| 5 | **Pool pause flag, oracle address, grace window and reserve count in one slot** | | | one `SLOAD` of global state per action |
| 6 | **Internal `cash` counter** instead of `balanceOf(pool)` | | | saves an external `CALL` per rate update, *and* makes the pool donation-proof |
| 7 | **Modifiers wrapped in internal functions** (configurator, oracle, pool) | PoolConfigurator 11,170 B | 9,144 B | −2,026 B of bytecode; no runtime effect |

**Trade-off accepted: `LiquidationLogic` as an external library.** `LendingPool` reached 23,986 bytes,
590 bytes under the EIP-170 limit, with no room for fixes. `LiquidationLogic.executeLiquidation` became
an `external` library function reached by `DELEGATECALL`. That costs about 2.6k gas per liquidation (one
extra call frame and argument copying) and bought 5.9 KB of headroom. It is the same split Aave v3 uses,
and it doesn't affect any other user action.

## 4. Contract sizes

EIP-170 limit: 24,576 bytes of runtime code.

| Contract | Runtime (bytes) | Headroom |
|---|---|---|
| `LendingPool` | 18,169 | 6,407 |
| `PoolLens` | 13,763 | 10,813 |
| `LiquidationLogic` (library) | 9,362 | 15,214 |
| `PoolConfigurator` | 9,144 | 15,432 |
| `LendingVault` | 7,461 | 17,115 |
| `TimelockController` (OpenZeppelin) | 7,101 | 17,475 |
| `OracleManager` | 6,119 | 18,457 |
| `ACLManager` | 1,723 | 22,853 |
| `KinkedInterestRateModel` | 1,182 | 23,394 |

## 5. What was deliberately *not* optimised

| Idea | Why not |
|---|---|
| `unchecked` arithmetic in accounting paths | a few hundred gas is not worth losing overflow protection on balances |
| Skipping the reentrancy lock because CEI already holds | the transient lock costs a few hundred gas per call (one `TLOAD`, two `TSTORE`s); it makes the property structural ([security.md](security.md#reentrancy)) |
| Caching prices across transactions (a stored "last price") | adds an `SSTORE` to every action and a staleness problem ([oracles.md](oracles.md#why-there-is-no-stored-last-good-price-breaker)) |
| Assembly for index maths | the rounding direction must stay auditable; `WadRayMath` is 50 lines of plain Solidity |
| Dropping the secondary WETH feed | the second source is the manipulation defence for the dominant collateral; about 2.5k gas per valuation is its price |
| `via_ir` | not needed: stack-depth limits were solved by refactoring into structs, which keeps the legacy pipeline's faster compiles and simpler source-level debugging |
