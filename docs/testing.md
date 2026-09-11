# Testing

What is tested, how, and what testing actually found. Every number here was produced by a run recorded
in `test-results/`, not estimated.

```bash
make test              # forge test + every TypeScript suite
make test-contracts    # forge test (unit + fuzz + invariant)
make test-deep         # FOUNDRY_PROFILE=deep: 20k fuzz runs, 1024 invariant runs x depth 150
make gas               # FOUNDRY_PROFILE=gas: isolated gas benchmarks
make test-ts           # shared + indexer + backend (+ real-Anvil e2e)
make e2e-ui            # puppeteer click-through of the running app
```

---

## 1. Summary

| Layer | Framework | Tests | What it covers |
|---|---|---|---|
| Solidity unit | Foundry | **195** | every entry point, every revert path, every parameter bound |
| Solidity fuzz | Foundry | **6** dedicated + **14** embedded in unit suites | rounding round trips, deviation symmetry, decimal normalisation, liquidation health and bonus bounds, accepted risk parameters |
| Solidity invariant | Foundry | **10 properties** | 153,600 calls per campaign (1.54M in the deep profile) |
| Gas benchmarks | Foundry (`isolate`) | **12 scenarios** | [gas-report.md](gas-report.md) |
| Mainnet fork | Foundry | **2** (skipped without `MAINNET_RPC_URL`) | real Chainlink feeds through the real `OracleManager` |
| Shared logic (TS) | vitest | **27** | ray/wad maths, risk classification, market and account findings |
| Indexer (TS) | vitest | **14** | decoding, exactly-once, confirmations, reorgs, snapshot cleanup, NOTIFY, listener leaks |
| Backend (TS) | vitest | **10** | OpenAPI contract, risk monitor, and 4 end-to-end tests against a real Anvil |
| Frontend (TS) | vitest | **11** | formatting, risk colours, error decoding, API client |
| UI click-through | puppeteer + real Chrome | **7 steps** | the whole stack through the browser |

`forge test` (default profile): **211 passed, 0 failed, 1 skipped** in 174 s. The skip is the fork suite
without an RPC URL. The gas benchmarks run under their own profile so a normal run cannot overwrite the
isolated snapshot.

TypeScript: **62 passed, 0 failed** across four packages.

## 2. Solidity unit suites

| Suite | Tests | Focus |
|---|---|---|
| `SupplyWithdraw.t.sol` | 29 | supply/withdraw paths, caps, dust, auto-collateral rules, liquidity limits, full-balance exits |
| `OracleManager.t.sol` | 24 | every feed failure mode, fallback, deviation, bounds, decimals, circuit breaker ([oracles.md](oracles.md#8-test-coverage)) |
| `Liquidation.t.sol` | 24 | close factor, dust rule, capped seizure, `receiveSupply`, same-asset, self-liquidation, preview parity |
| `BorrowRepay.t.sol` | 23 | borrow capacity, caps, partial and full repay, borrowing-bit lifecycle, repay while paused |
| `Governance.t.sol` | 21 | role split, timelock delay, parameter validation, handover, listing rules |
| `Interest.t.sol` | 11 | accrual, index monotonicity, treasury accrual, rate updates after every action |
| `InterestRateModel.t.sol` | 11 | 0%, normal, optimal, above optimal, 100% utilization; kink continuity; constructor bounds |
| `MathLibraries.t.sol` | 11 | ray/wad rounding directions, linear vs compounded interest, bitmap independence |
| `LendingVault.t.sol` | 11 | ERC-4626 behaviour, inflation attack, liquidity-aware limits, redemption during an oracle outage |
| `PoolLens.t.sol` | 12 | batched views, executable max amounts, preview parity, resilience to a broken oracle |
| `BadDebt.t.sol` | 7 | recognition, treasury absorption, multi-reserve write-off, deficit cover, last-withdrawer exposure |
| `Emergency.t.sol` | 7 | pause matrix, freeze wind-down, oracle pause isolation, post-unpause grace period |
| `Security.t.sol` | 4 | reentrancy via a token hook, donation immunity, same-block utilization spike, valuation gas at 32 reserves |

## 3. Fuzz testing

Default profile: 1,000 runs per property. `FOUNDRY_PROFILE=deep`: 20,000.

`test/fuzz/RoundingFuzz.t.sol` (6 properties) is the anti-value-extraction suite:

| Property | Meaning |
|---|---|
| `testFuzz_supplyWithdrawRoundTripNeverProfits` | supply then withdraw never returns more than was put in |
| `testFuzz_borrowRepayRoundTripCostsAtLeastPrincipal` | borrow then repay always costs at least the principal |
| `testFuzz_splitDepositsNeverBeatSingleDeposit` | splitting a deposit into pieces never mints more claim |
| `testFuzz_partialWithdrawalsNeverBeatFullWithdrawal` | many small exits never extract more than one big exit |
| `testFuzz_partialRepaysNeverForgiveDebt` | many small repayments never clear more debt than their sum |
| `testFuzz_irregularAccrualStaysSolvent` | any irregular pattern of interactions over time leaves the reserve solvent |

Embedded fuzz properties live next to the behaviour they check: liquidation health improvement and bonus
bounds, oracle decimal normalisation and deviation symmetry, accepted risk-parameter safety, vault
deposit/redeem profitability, and compounded-vs-linear interest.

## 4. Invariants

Ten properties, checked after every call of every randomised sequence.

| Invariant | Brief's requirement it satisfies |
|---|---|
| `invariant_reserveSolvency` | assets ≥ liabilities (`cash + debt + deficit ≥ supplier + treasury claims`) |
| `invariant_cashMatchesTokenBalance` | the internal ledger equals the token ledger |
| `invariant_healthyStaysHealthyWithoutRiskChange` | a healthy position never becomes liquidatable without a price, risk or debt change |
| `invariant_liquidationCannotCreateInsolvency` | liquidation never destroys value, and never touches a healthy account |
| `invariant_borrowNeverExceedsCapacity` | borrows stay within capacity |
| `invariant_withdrawRespectsLiquidity` | withdrawals respect available liquidity |
| `invariant_indexesNeverDecrease` | indexes are monotonic |
| `invariant_scaledBalancesSumToTotals` | totals equal the sum of parts; debt is never negative or unflagged |
| `invariant_noUncollateralizedDebt` | no account carries debt with no collateral |
| `invariant_vaultBacked` | the ERC-4626 vault never promises more than it holds |

### Handler design

Random calls into a protocol mostly bounce off validation. A handler that reverts 90% of the time proves
nothing, so [`LendingHandler.sol`](../test/invariant/LendingHandler.sol) is built to reach interesting
states:

- **Bounded actors and inputs.** A fixed actor set, amounts bounded to plausible ranges, and reserve
  indexes taken modulo the reserve count, so calls are valid by construction.
- **Seeded markets.** `setUp` lists all three markets with liquidity and open positions, so the campaign
  starts from a live protocol rather than an empty one.
- **Targeted liquidation.** The liquidate action searches for an actually unhealthy account instead of
  picking at random, and funds the liquidator. Random targeting produced **zero** liquidations in an
  early campaign.
- **A `crash` action.** Moves a price sharply in one step, which is what actually creates liquidatable
  positions and bad debt.
- **19 weighted selectors**, so common actions dominate and rare ones still occur.
- **Ghost variables** record what happened between calls (liquidation surplus changes, healthy accounts
  liquidated, index decreases, capacity violations, withdrawals beyond cash, bad-debt events), because
  some properties are about *transitions*, not states.
- **`fail_on_revert = true`.** An unexpected revert fails the campaign. Every legitimate revert
  (liquidating an account that turned healthy, say) is caught explicitly and counted.

### Campaign coverage

`afterInvariant` writes per-run counters to a CSV when `INVARIANT_STATS=1`, so a campaign can be audited
for what it actually exercised rather than assumed to be thorough.

| | Standard (`forge test`) | Deep (`FOUNDRY_PROFILE=deep`) |
|---|---|---|
| Runs x depth per invariant | 256 x 60 | 1,024 x 150 |
| Handler calls per invariant | 15,360 | 153,600 |
| Handler calls, all 10 invariants | 153,600 | **1,536,000** |
| Wall-clock | 174 s | 1,966 s |
| Supplies / borrows / repays | 23,014 / 18,004 / 5,756 | 237,144 / 179,836 / 80,554 |
| Withdrawals | 4,099 | 40,304 |
| Vault deposits | 7,980 | 80,030 |
| Price moves / crashes / warps | 16,950 / 8,010 / 7,840 | 162,410 / 81,960 / 80,610 |
| **Liquidations executed** | **5,632** | **46,290** |
| of which `receiveSupply` / same-asset | 2,782 / 1,979 | 24,697 / 16,766 |
| Liquidation attempts correctly rejected | 3,646 | 37,387 |
| **Bad-debt write-offs** | **138** | **1,874** |
| Deficit covers | 68 | 1,897 |
| Runs reaching at least one liquidation | 82% | 92% |
| Failures | **0** | **0** |

Raw data is written to `test-results/` (git-ignored, regenerate with `INVARIANT_STATS=1 forge test` or
`FOUNDRY_PROFILE=deep INVARIANT_STATS=1 forge test --match-path 'test/invariant/*'`):
`invariant-stats-standard.csv`, `invariant-stats-deep.csv`, `deep-invariants.log`.

### Coverage

`forge coverage` over the unit and fuzz suites (invariant runs excluded, and tests, scripts, mocks and
dependencies filtered out):

| | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| **Total** | **96.94%** (919/948) | 94.83% (1138/1200) | 77.27% (153/198) | 95.14% (137/144) |
| `LendingPool` | 96.56% | 94.72% | 77.78% | 94.44% |
| `LiquidationLogic` | 98.43% | 96.73% | 84.00% | 100% |
| `OracleManager` | 95.92% | 94.70% | 84.62% | 92.86% |
| `RiskEngine`, `ReserveLogic`, `ValidationLogic`, `KinkedInterestRateModel` | 100% | 83–100% | 68–100% | 100% |
| `PoolLens` | 96.83% | 94.67% | 52.63% | 100% |
| `LendingVault` | 100% | 96.61% | 60.00% | 100% |

Uncovered branches are mostly defensive: unreachable-by-construction fallbacks (the captured-price
fallback in liquidation), `PoolLens` display paths for states the unit fixtures don't build, and
`ACLManager`'s inherited OpenZeppelin surface, which is exercised through the roles the protocol
actually uses rather than directly. Coverage is a floor, not the goal: the invariant campaign is what
covers the state space between the lines.

## 5. Off-chain tests

**Indexer (14).** Decoding into raw and typed tables; exact `uint256` storage (never through a float);
idempotent replay of a committed batch; confirmation depth; multi-batch catch-up; price-feed events
attributed to their market and role; timelock operations from schedule to execution; `NOTIFY` on commit;
rollback of a shallow reorg to the common ancestor; recovery from a **reset chain** (a restarted Anvil);
discarding a batch whose logs belong to a block replaced mid-batch; wiping chain-derived data when the
deployment changes; dropping risk and market snapshots that describe rolled-back blocks; and a
regression test that the idle loop does not leak abort listeners.

**Backend (10).** An OpenAPI contract test that fails if a route and the spec disagree in either
direction; error-envelope shape; risk-monitor snapshots, alert reconciliation and `risk_alerts`
publishing; exact health-factor storage with `NULL` for debt-free accounts. The four e2e tests run
against a **real Anvil** (port 8547, separate from the dev chain): deploy, demo, index, serve; monitor,
preview and execute a bad-debt liquidation and book the deficit; detect and roll back a real reorg using
`evm_snapshot`/`evm_revert`; and track a timelocked risk change from pending to executed.

**UI click-through (`e2e/ui-flow.mjs`).** Drives the real app in Chrome: connect as Bob via the local dev
wallet, borrow 500 USDC, simulate an oracle outage from the Admin page, confirm the borrow is refused
*before signing* with a plain-language reason, restore the feed and crash ETH 30%, liquidate Bob as the
Liquidator, and check the analytics and risk pages render with data. It fails on any console error.

<a id="bugs-found"></a>

## 6. Bugs found

The point of the suite is what it caught. Each entry lists how it was found and the test that pins it.

### Protocol bugs

**1. Compound interest truncated its cubic term.** *(found by a unit test against `e^x`)*
The common binomial implementation computes `rate³ / year³` in integer arithmetic. At 10% APR that term
truncates from 31.88 to 31 wei, and borrowers are under-charged by ~4.6e-6 relative per year. Fixed by
forming `x = rate·Δt / year` first, then `1 + x + x²/2 + x³/6` in ray.
Pinned by `test_compoundedInterest_closeToContinuousCompounding`.

**2. `totalSupplied()` omitted pending treasury accrual.** *(found by `invariant_liquidationCannotCreateInsolvency`, shrunk to 8 calls)*
`totalBorrowed()` projected interest to *now*, but `totalSupplied()` used the stored `accruedToTreasury`.
Between interactions, liabilities were understated by `reserveFactor × pending interest`, so every
solvency and TVL view overstated health. Reproduced by a same-asset `receiveSupply` liquidation on WBTC
after a 60-day warp: the reserve's surplus dropped by exactly the pending treasury amount (26,869,795
units). Fixed with `ReserveLogic.treasuryScaledNow()` plus a private helper shared by `accrue()` and the
views, so they cannot drift apart again.
Pinned by `test_totalSuppliedView_includesPendingTreasuryAccrual`.

**3. `LendingPool` exceeded the contract size limit.** *(found by the EIP-170 check)*
23,986 bytes: 590 bytes of headroom, with fixes still to come. `LiquidationLogic.executeLiquidation`
became an external library reached by `DELEGATECALL`. The pool is now 18,169 bytes.
See [gas-report.md](gas-report.md#3-optimisations-with-measured-effect).

**4. `arbitrary-send-erc20` on the liquidation transfer.** *(found by Slither, High)*
`transferFrom(params.liquidator, …)` inside a DELEGATECALLed library. Not exploitable (the pool always
passed `msg.sender`, and Solidity blocks direct calls into state-changing external library functions),
but fixed structurally: the parameter was removed and the library uses `msg.sender`, so the shape can't
come back.

**5. `PoolLens` max-withdraw disagreed with the pool during an oracle outage.** *(found while writing [risk-model.md](risk-model.md))*
Two mismatches. For an **indebted** account with an exposed oracle down, the lens reported collateral as
withdrawable, but the pool reverts. For a **debt-free** account, `getUserPositions` reported 0 while the
pool allows the withdrawal, because it reads no price. Also, LTV-0 collateral was reported fully
withdrawable even when the account was already over capacity. Rewritten to mirror the pool's exact
condition.
Pinned by `test_maxWithdraw_matchesPoolDuringOracleOutage` and `test_maxWithdraw_ltvZeroCollateral`.

**6. A 1-wei ERC-4626 deposit reverts once the index exceeds 1.** *(design confirmation, found by vault fuzzing)*
Not a bug: the pool rejects a supply that would mint zero scaled balance. Without it the vault would
mint shares for a deposit that credits nothing. Pinned so it can't change silently by
`test_dustDepositRejected_protectsExistingHolders`.

### Test-infrastructure bugs

**7. The invariant campaign performed zero liquidations.** Random liquidation targeting almost never hits
an unhealthy account. Fixed with seeded markets, targeted liquidation and a `crash` action, which took
the campaign to thousands of liquidations and hundreds of bad-debt events.

**8. `(seed + k) % n` overflowed on raw fuzz seeds**, causing 66 silent handler reverts. Only visible
because `fail_on_revert = true` turns a quiet revert into a failure.

### Bugs only running the whole stack exposed

**9. Keeper staleness measured against a stale clock.** On an idle auto-mining Anvil the head block can be
hours old, so a feed looked fresh against head time while the *next* transaction, mined at wall-clock
time, would see a stale price and revert. Fixed with `effectiveNow = max(head timestamp, wall clock)`,
used by the keeper, the stale-soon rule and the oracle API.

**10–15. Six UI bugs found by the click-through** (all fixed):
account queries kept the previous account's data across a wallet switch; the wallet menu fired
disconnect and connect without awaiting, so re-selecting could end disconnected; the oracle lab computed
scenario prices from a failed feed's (correctly `null`) price and posted 0; borrowing against an asset
whose oracle was down gave no warning until simulation; an unpriceable account displayed "HF ∞ → 0.00";
and rate history was drawn with monotone smoothing, inventing slopes between what are piecewise-constant
rates (now `stepAfter`).

**16–19. Four more UI and formatting issues:** the admin proposal form didn't re-seed when the selected
market changed; a 0% APY was coloured as if it were good; the activity feed was flooded by price
updates; and the `LARGE_BORROW` alert message formatted its number unreadably.

**20–23. Four Docker/infra bugs:** `UID` is a read-only bash variable (renamed to `HOST_UID`/`HOST_GID`);
the API healthcheck used `localhost`, which Alpine resolves to `::1` while the API listens on IPv4;
the indexer's idle sleep leaked an abort listener per poll (`MaxListenersExceededWarning`), now
regression-tested; and CORS was hard-coded to port 3400 instead of following `FRONTEND_PORT`.

**24. Monitor snapshots survived a chain reset.** `risk_snapshots` and `market_snapshots` are
chain-derived but written by the monitor, so they carry a block number rather than a foreign key to
`blocks` (the monitor reads the head before the indexer has stored it). Nothing deleted them on a
rollback, so after restarting Anvil the risk API reported a "latest sweep" at block 70 while the chain
head was 54 — data describing a chain that no longer existed. The indexer now drops them above the
rollback point, and entirely when the deployment changes.
Pinned by `drops monitor snapshots that describe rolled-back blocks`.

**25. Liquidation candidates included accounts with no debt.** `/liquidations/candidates` starts from the
monitor's last sweep, which can be an interval old, and re-checks each account live. An account whose
debt had just been repaid or liquidated away still appeared, rendering a "$0.00 / $0.00 · 0.0% collateral
drop away" row in the liquidator's opportunity table. Accounts with no debt are now dropped from the list.

**26. `pnpm db:migrate` demanded `DATABASE_URL`** while every other service defaulted to the local
Postgres, so the documented native-setup flow failed on a clean machine. All four now share one
`DEFAULT_DATABASE_URL` constant.

## 7. What is not tested

- No external audit, and no formal verification of the solvency invariant.
- Fee-on-transfer, rebasing and blocklisting tokens are out of scope; listing them would need per-token
  handling ([threat-model.md](threat-model.md#6-out-of-scope)).
- The fork test only reads real feeds. There is no fork test of a full liquidation against mainnet state.
- The frontend has unit tests plus one scripted click-through, not a component-level test suite.
