# Liquidations

Liquidation is how a lending protocol stays solvent without a central party. When a position's health
factor falls below 1, **anyone** may repay part of its debt and receive the borrower's collateral at a
discount. The discount (the liquidation bonus) pays for the liquidator's gas, price risk and capital.

Implementation: [`contracts/logic/LiquidationLogic.sol`](../contracts/logic/LiquidationLogic.sol).
Tests: [`test/unit/Liquidation.t.sol`](../test/unit/Liquidation.t.sol) (24),
[`test/unit/BadDebt.t.sol`](../test/unit/BadDebt.t.sol) (7), and the targeted-liquidation actions of
the invariant handler ([testing.md](testing.md)).

---

## The call

```solidity
function liquidate(
    address collateralAsset,   // what the liquidator receives
    address debtAsset,         // what the liquidator repays
    address borrower,
    uint256 debtToCover,       // the most the liquidator is willing to repay; type(uint256).max = "as much as allowed"
    bool    receiveSupply      // take the collateral as a pool supply position instead of tokens
) external returns (uint256 debtRepaid, uint256 collateralSeized);
```

Permissionless. The liquidator must have approved `debtAsset` to the pool. Funds are only ever pulled
from `msg.sender`. The library has no "liquidator" parameter that could be pointed at someone else's
allowance (see [security.md](security.md), Slither finding #1).

## Eligibility

A liquidation reverts unless **all** of these hold:

| Condition | Error |
|---|---|
| `debtToCover > 0` | `ZeroAmount` |
| pool not paused | `PoolPaused` |
| not within the post-unpause grace window | `LiquidationGracePeriod` |
| both reserves active and not paused (**frozen is fine**: frozen markets wind down) | `ReserveNotActive` / `ReservePaused` |
| borrower owes `debtAsset` | `NoDebt` |
| borrower has `collateralAsset` enabled as collateral | `CollateralNotEnabledByUser` |
| every price the borrower is exposed to is valid | `OracleAssetPaused` / `OraclePriceDeviation` / `OraclePriceUnavailable` |
| `healthFactor < 1` (strictly; HF exactly 1.0 is healthy) | `HealthyPosition` |
| the dust rule is satisfied (below) | `MustNotLeaveDust` |

Both reserves are accrued before the health check, so interest alone can make a position liquidatable
(`test_interestAloneCanMakePositionLiquidatable`), and a liquidator can't use stale indexes.

## Amounts

```
closeFactor      = 100%  if HF < 0.95, or debt value < $2,000, or collateral value < $2,000
                 =  50%  otherwise

debtRepaid       = min(debtToCover, borrowerDebt × closeFactor)

collateralSeized = debtRepaid × P_debt / P_coll × (1 + bonus)          decimals-adjusted, rounded down
```

If the borrower does not hold that much collateral, the liquidator takes all of it and repays only what
it covers at the bonus price (rounded **up**, against the liquidator):

```
collateralSeized = borrowerCollateral
debtRepaid       = collateralSeized × P_coll / P_debt / (1 + bonus)
```

The bonus is the **collateral** reserve's (5% WETH, 6.5% WBTC, 4.5% USDC). Riskier collateral pays a
bigger bonus. The liquidator's gross profit is `debtRepaid × bonus` in USD terms.

### Close factor

A 50% close factor limits how much of a position one liquidation can take, so a borrower who is only
slightly under water loses the bonus on half the debt, not all of it. Two cases need 100%:

- **Deeply unhealthy positions (HF < 0.95).** Below a certain HF, partial liquidations make the position
  *worse* ([next section](#why-lt--1--bonus--1)). The protocol must allow closing it in one call.
- **Small positions (either leg < $2,000).** Liquidating half of a $300 position costs more gas than the
  bonus pays. Nobody would do it, and the position would sit until it became bad debt.

### The dust rule

A partial liquidation (one that neither repays all the debt nor seizes all the collateral) may not leave
**less than $1,000** of debt or of collateral. Otherwise a liquidator could take the profitable part and
leave a tiny, unprofitable remainder that becomes bad debt. When the rule would be violated, the call
reverts with `MustNotLeaveDust`, and the liquidator has to take the whole position instead
(`type(uint256).max`).

### Rounding

| Quantity | Direction | Who it disadvantages |
|---|---|---|
| collateral seized | down | liquidator |
| debt repaid when collateral is capped | up | liquidator |
| borrower's burned scaled debt (partial) | down | borrower keeps ≤ 1 wei more debt |
| borrower's burned scaled collateral (partial) | up | borrower loses ≤ 1 wei more collateral |

The fuzz test `testFuzz_liquidationBoundsBonus` checks that seized value never exceeds
`debtRepaid × (1 + bonus)` across fuzzed ETH prices ($1,000–$1,818, including bad-debt territory) and
repayment amounts.

<a id="why-lt--1--bonus--1"></a>

## Why LT × (1 + bonus) < 1

Take one collateral asset with value `C` and threshold `LT`, and debt `D`. Then `HF = C·LT / D`. A
liquidation repays `Δ` of debt value and seizes `Δ(1 + b)` of collateral value:

```
HF_after = (C − Δ(1+b))·LT / (D − Δ)

HF_after > HF_before   ⇔   (C − Δ(1+b)) / (D − Δ) > C / D
                       ⇔   C > D(1 + b)
                       ⇔   HF_before > LT × (1 + b)
```

So a liquidation **improves** the position if and only if `HF > LT × (1 + bonus)`. It is only ever
allowed when `HF < 1`. The band where liquidations help, `LT(1+b) < HF < 1`, is therefore non-empty
only if `LT × (1 + bonus) < 1`. If a market violated that, every liquidation would push the borrower
deeper under water and hasten bad debt. `PoolConfigurator` rejects any such parameters, and
`testFuzz_acceptedParamsSatisfyLiquidationSafety` checks it for every accepted combination.

For the demo markets `LT(1+b)` is 0.866 (WETH), 0.831 (WBTC) and 0.836 (USDC). All are below the
**0.95** full-close threshold. Above `LT(1+b)`, every liquidation, partial or full, improves health.
`testFuzz_liquidationImprovesHealthWhileCollateralized` fuzzes ETH between $1,576 and $1,818 (HF from 0.87 to just
under 1) with any repayment amount. Below 0.95 the liquidator may close the position entirely, which also
covers the zone below `LT(1+b)` where partial liquidations would hurt.

> Governance guideline: keep `LT × (1 + bonus) < 0.95` for new listings. The configurator enforces only
> `< 1`. In a market with `LT(1+b)` between 0.95 and 1, a 50% liquidation of a position with HF in
> `[0.95, LT(1+b))` lowers its health (to `2·HF − LT(1+b)`). Repeated liquidations still drive it below
> 0.95, where it can be closed, but more bonus is paid out along the way than necessary.

## Options

**`receiveSupply = true`.** The liquidator receives the seized collateral as a supply position in the
pool (scaled balance moved from borrower to liquidator) instead of tokens. This keeps liquidations
possible when the collateral reserve has **no cash** (100% utilization), which is exactly the stressed
state where they matter most (`test_receiveSupply_worksWhenCollateralReserveIsIlliquid`). The
liquidator's new position is enabled as collateral automatically if it is their first in that reserve.

**Same-asset liquidation.** Debt and collateral in the same asset (for example, borrowed USDC against
USDC collateral) is supported. The repayment is credited to cash before the payout, so it works even
when the reserve's cash is low (`test_sameAssetLiquidation`).

**Self-liquidation** is allowed and economically neutral. The borrower pays the bonus to themselves
(`test_selfLiquidation_isNeutral`). It is a legitimate way to deleverage at the oracle price.

## Execution order

```mermaid
sequenceDiagram
    participant L as Liquidator
    participant P as LendingPool
    participant LL as LiquidationLogic (DELEGATECALL)
    participant O as OracleManager
    L->>P: liquidate(coll, debt, borrower, amount, receiveSupply)
    P->>P: nonReentrant · not paused · grace period over
    P->>LL: executeLiquidation(...)
    LL->>LL: validate both reserves, accrue both
    LL->>O: value the borrower (one validated price per exposed asset)
    O-->>LL: prices (captured and reused below)
    LL->>LL: HF < 1? close factor, amounts, dust rule
    LL->>LL: burn borrower debt; move or burn borrower collateral
    alt borrower has no collateral left and still owes debt
        LL->>LL: write off all remaining debt: treasury first, then deficit
    end
    LL->>LL: update rates of every touched reserve (once each)
    LL->>L: transferFrom(liquidator → pool, debtRepaid)
    LL->>L: transfer(pool → liquidator, collateralSeized) unless receiveSupply
    LL-->>P: emit LiquidationCall
```

All state changes happen before any token moves (checks-effects-interactions), under the pool's
reentrancy lock. The prices used to compute the amounts are the ones captured while valuing the
account. The oracle is read once per asset per transaction, which saves about 13.7k gas and removes any
chance of valuing with one price and seizing with another ([gas-report.md](gas-report.md)).

`LiquidationLogic` is an external library reached by `DELEGATECALL`. It runs on the pool's storage and
emits from the pool's address. That keeps `LendingPool` at 18.2 KB, under the 24 KB EIP-170 limit, at a
cost of about 2.6k gas per liquidation. The amount maths is a separate `pure` function that `PoolLens`
also calls, so previews and execution cannot drift apart (`test_lensPreviewMatchesExecution`).

## Worked example (the demo)

Bob: 10 WETH collateral, 15,000 USDC debt. ETH falls from $2,500 to $1,800.

| | Value |
|---|---|
| Collateral value | 10 × $1,800 = $18,000 |
| HF | 18,000 × 0.825 / 15,000 = **0.99** → liquidatable |
| Close factor | 50% (HF ≥ 0.95, both legs ≥ $2,000) |
| Debt repaid | min(∞, 15,000 × 50%) = **7,500 USDC** |
| Collateral seized | 7,500 × $1 / $1,800 × 1.05 = **4.375 WETH** ($7,875) |
| Liquidator profit | $7,875 − $7,500 = **$375** (5% of the repayment), before gas |
| Dust rule | leftover debt $7,500 ≥ $1,000, leftover collateral $10,125 ≥ $1,000 → OK |
| Bob after | 5.625 WETH ($10,125) vs 7,500 USDC → HF **1.114** |

The liquidation improved Bob's HF from 0.99 to 1.114 and left him with a healthy position. That is
the purpose of a partial liquidation.

Had ETH gapped to **$1,400** instead (collateral $14,000 < debt $15,000):

| | Value |
|---|---|
| HF | 14,000 × 0.825 / 15,000 = 0.77 → close factor 100% |
| Collateral needed for 15,000 USDC at a 5% bonus | 15,000 / 1,400 × 1.05 = 11.25 WETH > 10 WETH held |
| Capped | seize all **10 WETH**, repay 10 × 1,400 / 1.05 = **13,333.33 USDC** |
| Remaining | 1,666.67 USDC of debt, zero collateral → **bad debt**, written off in the same transaction |

(`test_badDebt_recognizedWhenCollateralExhausted`.)

## For liquidators

- `GET /liquidations/candidates` lists at-risk accounts from the latest monitor sweep, re-checks each
  one live, and returns the most profitable (collateral, debt) pair with the preview.
- `GET /liquidations/preview?borrower=…&collateral=…&debt=…&amount=…` runs the pool's own maths through
  `PoolLens.previewLiquidation`: close factor, repay, seize, USD values, and a `LEAVES_DUST` status
  when a partial amount would revert.
- The **Liquidations** page of the app does both and executes with the connected wallet. It simulates
  the transaction first and decodes any revert into a readable reason.
- Liquidations are a race. The first valid transaction wins, and later ones revert (`HealthyPosition`
  or `NoDebt`) at the cost of gas only. There are no flash loans in v1, so the liquidator needs the debt
  asset up front. An external flash loan or a swap can supply it atomically.

## Abuse cases considered

| Attempt | Outcome |
|---|---|
| liquidate a healthy account, or one at exactly HF = 1 | reverts `HealthyPosition` |
| liquidate more than the close factor | capped silently to the close factor |
| take the profitable half, leave dust that nobody will liquidate | reverts `MustNotLeaveDust` |
| keep liquidating to farm the bonus | each partial liquidation above `LT(1+b)` raises HF; once HF ≥ 1, further calls revert |
| push the price to trigger liquidations | see [oracles.md](oracles.md): push feeds only, cross-source deviation, bounds, staleness |
| liquidate right after an emergency unpause, before borrowers can react | blocked by the grace period |
| liquidate using a different price than the one that made the account unhealthy | impossible: one captured price per asset per transaction |
| pull the debt payment from someone else's allowance | impossible: always `msg.sender` |
| re-enter during the token transfer | all effects are done, and the transient lock rejects re-entry (`test_reentrancyFromTokenHook_isBlocked`) |

<a id="bad-debt"></a>

## Bad debt

Bad debt exists when a borrower's collateral is worth less than their debt, so even seizing everything
cannot repay it. It happens when prices gap faster than liquidators can act: a crash between blocks, an
oracle outage during a move, or a congested network. No lending protocol can promise it never happens.
What it can promise is how it is **recognised, absorbed and reported**.

### Recognition

The pool recognises bad debt at the only moment it becomes certain: when a liquidation leaves the
borrower with **no collateral enabled anywhere** while debt remains. In that same transaction,
`_writeOffBadDebt`:

1. burns the borrower's remaining scaled debt in **every** reserve they owe (`test_badDebt_writtenOffAcrossAllDebtReserves`);
2. absorbs each loss from that reserve's treasury buffer (`accruedToTreasury`, the accumulated
   reserve-factor income) first (`test_badDebt_absorbedByTreasuryFirst`);
3. records any remainder as `reserve.deficit`;
4. emits `BadDebtRecognized(asset, borrower, debt, coveredByTreasury, addedToDeficit)` per reserve;
5. clears the borrower's account completely.

Without step 1, the unrecoverable debt would stay on the books and keep **accruing interest**: a zombie
liability, counted as an asset, that inflates utilization, the supply rate and the reported solvency.

A borrower can't dodge the write-off by keeping a sliver of collateral in another reserve. The sliver is
itself liquidatable, and seizing it triggers the write-off (`test_dustCollateralDoesNotShieldBadDebtForever`).

### Who bears the loss

```
loss ─► treasury buffer of that reserve ─► reserve.deficit (suppliers' exposure) ─► coverDeficit() by anyone
```

The solvency invariant becomes `cash + totalDebt + deficit ≥ supplier + treasury claims`, where
`deficit` is an explicit, recognised hole. Indexes **never decrease**. The loss is not silently spread
across suppliers by cutting the liquidity index.

What that means for suppliers in the affected reserve while a deficit is uncovered: their balances still
show the full claim, but the reserve can pay out only `cash`. If the deficit is never covered, **the last
suppliers to withdraw bear it**. The first withdrawers are paid in full
(`test_uncoveredDeficit_isBorneByLastWithdrawer`). That is bank-run dynamics, and it is why a deficit is
surfaced loudly everywhere:

- the `BAD_DEBT` critical alert from the risk monitor, pushed over WebSocket;
- "Unrecovered bad debt" on each market's detail page, the dashboard and the Analytics page, and `deficit` in `GET /markets`;
- `deficitUsd` in `GET /protocol/tvl`;
- the `bad_debt_events` table and the per-borrower `BadDebtRecognized` events.

`coverDeficit(asset, amount)` is **permissionless**. The treasury, an insurance fund or any benefactor
can recapitalise the reserve. The payment becomes cash, the deficit shrinks by the same amount, and full
backing is restored (`test_coverDeficit_restoresFullBacking`).

### Alternatives considered

| Approach | Pros | Cons | Verdict |
|---|---|---|---|
| **Leave the debt on the books** | nothing to build | zombie debt accrues interest forever, inflates rates and reported solvency, and hides the loss | rejected |
| **Socialise immediately** (cut the liquidity index) | fair: every supplier takes a pro-rata haircut, so there is no race to exit | breaks index monotonicity, a core invariant every integrator (including the ERC-4626 vault) relies on; a single liquidation silently changes everyone's balance | rejected for v1 |
| **Explicit deficit plus permissionless cover** (chosen) | loss is visible, attributable and bounded; indexes stay monotonic; the treasury buffer absorbs small losses automatically | uncovered deficits create first-come-first-served exit dynamics | chosen, with loud monitoring |
| **Staked insurance module** (e.g. a slashable safety module) | a pre-funded first-loss layer beyond the treasury | needs a token, staking and slashing governance: far beyond this scope | future work |
| **Backstop auction** (sell protocol equity to cover) | recapitalises without a pre-funded pool | needs a governance token and an auction mechanism | future work |

Aave v3.3 introduced a similar mechanism: per-reserve deficit tracking, with coverage handled by a
separate module. The difference here is that the treasury buffer is burned automatically first. A production deployment would
pair it with a funded insurance module and a governance process that commits to covering deficits
within a defined time, which removes the race to exit.

### Invariants that cover it

- `invariant_reserveSolvency`: `cash + debt + deficit ≥ liabilities`, always.
- `invariant_liquidationCannotCreateInsolvency`: the per-reserve surplus never falls across a
  liquidation, bad-debt ones included.
- `invariant_noUncollateralizedDebt`: after any sequence of actions, no account's bitmap shows debt
  without collateral. Write-off leaves no zombie debt behind.
- `invariant_indexesNeverDecrease`.

In the standard invariant campaign the handler produced hundreds of liquidations and a handful of
bad-debt write-offs per 256 runs, and every invariant held after each call. The exact figures are in
[testing.md](testing.md).
