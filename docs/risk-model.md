# Risk model

How an account is valued, when it may borrow or withdraw, when it becomes liquidatable, and how the
off-chain monitor classifies it. On-chain logic lives in
[`RiskEngine.sol`](../contracts/logic/RiskEngine.sol). The off-chain classification is in
[`shared/src/risk.ts`](../shared/src/risk.ts), which the monitor, the API and the dashboard all
import, so one threshold table serves all three.

---

## 1. Account valuation

For every reserve flagged in the account's bitmap:

```
collateralValue_i = supplyBalance_i × price_i / 10^decimals_i        rounded down
debtValue_i       = debtBalance_i   × price_i / 10^decimals_i        rounded up

totalCollateral   = Σ collateralValue_i                  (only reserves enabled as collateral)
borrowCapacity    = Σ collateralValue_i × LTV_i
liquidationValue  = Σ collateralValue_i × LT_i
totalDebt         = Σ debtValue_i

healthFactor      = liquidationValue / totalDebt         (1e18 = 1.00; ∞ when totalDebt = 0)
```

Prices are 18-decimal USD per whole token from `OracleManager.getPrice`, which reverts on any unhealthy
price ([oracles.md](oracles.md)). Nothing user-supplied is ever used as a price.

**Rounding is conservative in both directions.** Collateral is rounded down and debt is rounded up, so a
position is never valued healthier than it is. LTV and LT weights are accumulated as `value × bps` and
divided once at the end, so there is one rounding step per account, not one per reserve.

**Only exposed reserves are priced.** The per-user bitmap has two bits per reserve (borrowing,
collateral). Valuation walks it and stops when the remaining bitmap is zero. This gives two properties:

- Gas is proportional to the number of markets the user actually uses, not to the number of listed
  markets. The listing cap is 32 reserves, which bounds the worst case.
- **Market isolation.** An account with no WBTC exposure never reads the WBTC oracle. A broken WBTC
  feed halts borrows and liquidations only for accounts that hold WBTC as collateral or debt. This is
  tested by `test_oraclePause_isolatedToExposedAccounts` and `test_accountsHealth_neverRevertsOnOneBadAccount`.

## 2. LTV versus liquidation threshold

| | LTV | Liquidation threshold (LT) |
|---|---|---|
| Question it answers | how much may this account **borrow**? | when may this account be **liquidated**? |
| Used by | `borrow`, collateral `withdraw`, `setUseReserveAsCollateral(false)` | `liquidate` |
| Check | `totalDebt ≤ borrowCapacity` | `healthFactor < 1` |

`PoolConfigurator` enforces `LTV < LT` for every collateral asset. Because the borrow check is
`debt ≤ Σ value × LTV` and `LTV < LT`, any action that passes it leaves the account at
`HF ≥ LT / LTV > 1`. **No user action can open or leave a position at the liquidation edge.** Only a
price move, interest accrual or a governance parameter change can bring an account to HF < 1. That is
the invariant `invariant_healthyStaysHealthyWithoutRiskChange`.

The withdraw check uses LTV like Compound, not "HF ≥ 1" like Aave. With the Aave rule, a user could
withdraw down to HF 1.0001, and one block of interest would make them liquidatable. The stricter rule
costs nothing for honest users and removes that edge.

### When each check runs

| Action | Reads prices? | Check |
|---|---|---|
| `supply`, `repay` | never | none. They only lower risk, so they also work during an oracle outage |
| `withdraw` from a non-collateral reserve, or by an account with no debt | never | liquidity only (`amount ≤ cash`) |
| `withdraw` collateral with debt outstanding | yes | `debt ≤ capacity` on the **post-withdraw** state |
| `borrow` | yes | `debt ≤ capacity` on the **post-borrow** state |
| `setUseReserveAsCollateral(false)` with debt | yes | `debt ≤ capacity` on the **post-toggle** state |
| `liquidate` | yes | `HF < 1` |

Every check runs on post-action state (effects, then the check, then the token transfer). A check can't
be sidestepped by the order in which balances are updated. A failed check reverts the whole action.

## 3. Derived quantities

These are what the UI and API show. They come from `PoolLens`, which calls the same code paths the pool
uses.

| Quantity | Formula | Notes |
|---|---|---|
| **Max borrow** of asset `a` | `(borrowCapacity − totalDebt) × 10^dec_a / price_a` | also capped by the reserve's cash and remaining borrow cap. 0 if frozen, paused, borrowing disabled, or `a`'s price is unavailable |
| **Max withdraw** of asset `a` | `min(balance, cash)` if no risk check applies; otherwise `(borrowCapacity − totalDebt) / (price_a × LTV_a)` | mirrors the pool exactly: debt-free or non-collateral withdrawals are never price-dependent, and a collateral withdrawal with debt returns 0 while an exposed oracle is down |
| **Liquidatable** | `HF < 1` and not in the post-unpause grace window | |
| **Max liquidation** | `debt × closeFactor` (50%, or 100% when HF < 0.95 or a leg is under $2,000) | then capped by the collateral available; see [liquidations.md](liquidations.md) |
| **Liquidation bonus** | the *collateral* reserve's bonus: 5% WETH, 6.5% WBTC, 4.5% USDC | |
| **Distance to liquidation** | `1 − 1 / HF` | the collateral price drop that brings HF to 1, assuming debt is priced constant. The API returns it and Portfolio shows it under the health factor |
| **Liquidation price** (single collateral) | `price / HF` | follows from the distance above |

Suggested "max" amounts are reduced by 1 ppm. The pool rounds debt up and collateral down, so an exactly
computed maximum can revert by a wei. The haircut guarantees a Max button always produces an executable
transaction. `test_maxBorrowIsExecutable` and `test_maxWithdrawIsExecutable` execute the suggested
amount, and then fail on anything larger.

## 4. Parameter validation

Enforced on-chain by `PoolConfigurator._validateRiskParams` for every listing and every change:

| Rule | Why |
|---|---|
| `LTV < LT` | borrowing to the maximum must leave a buffer before liquidation |
| `LT ≤ 95%` | no asset is trusted to hold more than 95% of its value |
| `LT × (1 + bonus) < 100%` | otherwise liquidation *lowers* the borrower's health ([proof](liquidations.md#why-lt--1--bonus--1)) |
| `0 < bonus ≤ 20%` whenever `LT > 0` | liquidators must be paid to act; a larger bonus overpays them and eats into the margin above |
| `LT = 0 ⇒ LTV = 0, bonus = 0` | a non-collateral asset grants no borrowing power |
| `reserveFactor ≤ 50%` | suppliers keep at least half of the interest |
| token `decimals ∈ [1, 24]` | bounds `amount × price` products |
| rate model: has code, answers `getBorrowRate` | a typo'd address cannot price a market |
| `base + slope1 + slope2 ≤ 1000%` (IRM constructor) | bounds index growth, prevents fat-finger liquidation spirals |

Lowering an LT can make existing positions liquidatable immediately. That is why every risk parameter
change goes through the timelock ([security.md](security.md#admin)) and users get the delay to react.

## 5. Off-chain risk levels

The monitor sweeps every indexed account through `PoolLens.getAccountsHealth`. That is one batched call
with a try/catch per account, so one account behind a broken oracle never hides the others. Each account
is classified:

| Level | Condition | Meaning |
|---|---|---|
| **SAFE** | no debt, or HF ≥ 1.5 | collateral can fall by ≥ 33% before liquidation |
| **WARNING** | 1.2 ≤ HF < 1.5 | a 17–33% collateral drop from liquidation |
| **DANGER** | 1.0 ≤ HF < 1.2 | less than a 17% drop from liquidation |
| **LIQUIDATABLE** | HF < 1.0 | anyone may liquidate now |
| **UNKNOWN** | valuation reverted | an exposed oracle is down. The account can't be valued, and can't be liquidated either |

UNKNOWN is a deliberate fifth level. Reporting such an account as SAFE (no data) or LIQUIDATABLE
(worst case) would both be wrong. The honest answer is "cannot be priced right now", and that is also the
on-chain truth: every price-dependent action for it reverts.

### Findings raised

| Kind | Severity | Trigger |
|---|---|---|
| `LIQUIDATABLE` | critical | HF < 1 |
| `NEAR_LIQUIDATION` | warning | DANGER level |
| `UNPRICEABLE_ACCOUNT` | warning | UNKNOWN level |
| `POTENTIAL_BAD_DEBT` | critical | priced collateral < debt: liquidating the whole position can't repay it |
| `LARGE_BORROW` | info | debt ≥ $100k, or ≥ 20% of all protocol borrows (concentration) |
| `HIGH_UTILIZATION` | warning ≥ 90%, critical ≥ 97% | withdrawals and collateral payouts may lack cash |
| `ABNORMAL_UTILIZATION` | warning | utilization moved ≥ 15 points between two sweeps |
| `LOW_LIQUIDITY` | critical | cash < 5% of supplied |
| `ORACLE_DEGRADED` | warning | running on one source (`OK_PRIMARY_ONLY` / `OK_FALLBACK`) |
| `ORACLE_UNAVAILABLE` | critical | `STALE`, `DEVIATION`, `PAUSED`, `UNAVAILABLE`, … |
| `ORACLE_STALE_SOON` | warning | price age ≥ 80% of the heartbeat |
| `BAD_DEBT` | critical | the reserve carries a deficit |

Alerts are reconciled, not appended. A partial unique index on open `(kind, subject)` means a condition
that persists for a hundred sweeps is one alert. It resolves automatically when the condition clears,
and a new alert opens if it recurs. Alerts are pushed to the dashboard over WebSocket as they open.

## 6. Worked example

Bob holds 10 WETH and owes 15,000 USDC (see [economics.md](economics.md#9-worked-example-the-demo-scenario)).

| ETH price | Collateral | Capacity (80%) | Liquidation value (82.5%) | HF | Level | Max extra borrow |
|---|---|---|---|---|---|---|
| $2,500 | $25,000 | $20,000 | $20,625 | 1.375 | WARNING | 5,000 USDC |
| $2,200 | $22,000 | $17,600 | $18,150 | 1.210 | WARNING | 2,600 USDC |
| $2,000 | $20,000 | $16,000 | $16,500 | 1.100 | DANGER | 1,000 USDC |
| $1,818.18 | $18,182 | $14,545 | $15,000 | 1.000 | DANGER | 0 |
| $1,800 | $18,000 | $14,400 | $14,850 | 0.990 | LIQUIDATABLE | 0 |

At $2,500 his distance to liquidation is `1 − 1/1.375 = 27.3%`, and his liquidation price is
`2,500 / 1.375 = $1,818.18`.
