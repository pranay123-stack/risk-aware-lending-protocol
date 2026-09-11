# Economics

How money moves through the protocol: who pays interest, who earns it, and how the protocol keeps
enough liquidity for withdrawals and liquidations. Every formula here is the one the contracts
execute. File and line references point at the implementation.

---

## 1. Balance sheet of a reserve

Each listed asset (WETH, WBTC, USDC) is an independent **reserve** with its own balance sheet:

```
Assets                                   Liabilities
------------------------------------     --------------------------------------------
cash        tokens held by the pool      supplier claims    Σ scaledSupply × liquidityIndex
totalDebt   Σ scaledDebt × borrowIndex   treasury claim     accruedToTreasury × liquidityIndex
deficit     recognised bad debt (a hole,
            tracked so it is never hidden)
```

The protocol is solvent per reserve when

```
cash + totalDebt + deficit ≥ supplier claims + treasury claim
```

This is `invariant_reserveSolvency` in the invariant suite ([testing.md](testing.md)). `deficit` is on
the asset side because it is an **explicit, recognised shortfall**. A reserve with a non-zero deficit is
still solvent in the accounting sense, but it is under-backed, and the dashboard, the API and the risk
monitor all report it. See [liquidations.md](liquidations.md#bad-debt).

`cash` is an internal counter, not `token.balanceOf(pool)`. Tokens sent to the pool by mistake (or as
an attack) are not assets of any reserve and cannot change a rate, an index or a share price.

## 2. Utilization

```
U = totalDebt / (cash + totalDebt)
```

`KinkedInterestRateModel.utilization` ([source](../contracts/interest/KinkedInterestRateModel.sol)).
`U` is the fraction of the reserve's lendable funds currently lent out. At `U = 100%` the pool holds no
cash, so no supplier can withdraw and no liquidator can receive this asset as collateral (the
`receiveSupply` option exists for exactly that case).

## 3. The kinked interest rate model

```
U ≤ U*:   borrowRate = base + slope1 × U / U*
U > U*:   borrowRate = base + slope1 + slope2 × (U − U*) / (1 − U*)
```

Rates at selected utilizations for all three markets are tabulated in [section 5](#rates-at-selected-utilizations).
Each market's detail page in the app draws its curve with the current utilization and the kink marked.

**Why a kink.** Below the kink (`U*`) the curve is gentle, so borrowing is cheap and idle capital gets
used. Above it the rate rises steeply. That does two things at once. Borrowers are pushed to repay, and
suppliers are paid a lot to deposit. Both restore a cash buffer. The buffer matters for safety as well
as convenience: a liquidation that pays out collateral needs that collateral's reserve to hold cash, and
a supplier who wants to exit needs cash in their reserve.

**Why the parameters are immutable.** A rate model is a contract with four `immutable` values. To
change the curve, governance deploys a new model and swaps it in through the timelock
(`PoolConfigurator.setInterestRateModel`). The pool accrues interest at the old rate right before the
swap ([`LendingPool.setInterestRateModel`](../contracts/core/LendingPool.sol)), so no elapsed time is
ever priced retroactively. The ceiling `base + slope1 + slope2 ≤ 1000% APR` (`MAX_BORROW_RATE`)
bounds index growth so the `uint128` indexes cannot overflow in any realistic horizon. It also rules out
a fat-fingered curve that would liquidate every borrower within hours.

The IRM tests cover the brief's five required points (0%, normal, optimal, above optimal, maximum),
plus continuity at the kink, monotonicity (fuzz) and constructor validation. See
[`test/unit/InterestRateModel.t.sol`](../test/unit/InterestRateModel.t.sol).

## 4. Supply rate, and why it is not the textbook formula

The textbook supply rate is `borrowRate × U × (1 − reserveFactor)`. The pool computes a more general
form instead ([`ReserveLogic.updateRates`](../contracts/logic/ReserveLogic.sol)):

```
supplyRate = borrowRate × (1 − reserveFactor) × min(totalDebt / supplyLiabilities, 1)
```

where `supplyLiabilities = (Σ scaledSupply + accruedToTreasury) × liquidityIndex`.

Without a deficit, `supplyLiabilities = cash + totalDebt` and the two formulas are identical. They
differ once bad debt exists. The textbook formula would then keep paying interest on supply that is no
longer backed by anything, and the hole would grow with time. The general form pays suppliers exactly
the non-reserve-factor share of what borrowers are actually charged, never more. The `min(…, 1)` cap
covers the opposite corner. Without it, if nearly every supplier withdrew while debt remained, the few
remaining suppliers would receive an unbounded rate on leftover surplus.

### Compounding: borrowers compound, suppliers accrue linearly

| Index | Growth between two interactions | Rounding |
|---|---|---|
| `borrowIndex` | `1 + x + x²/2 + x³/6` with `x = borrowRate × Δt / year` (3-term Taylor series of `e^x`) | up |
| `liquidityIndex` | `1 + supplyRate × Δt / year` (linear) | down |

Borrowers therefore pay slightly more than the stated APR (APY), and suppliers earn slightly less than
compounding would give. The difference stays in the reserve and is why the solvency surplus only ever
grows between interactions. The Taylor series is evaluated on `x` in ray precision. The common
"binomial" implementation computes `rate³ / year³` as an integer first and truncates the cubic term.
This was a real bug found during development (bug #1 in [testing.md](testing.md#bugs-found)).

Interest is **accrued lazily**. No keeper and no per-block update exist. Each state-changing action
first moves the touched reserve's indexes to `block.timestamp` at the *previous* rates, then changes
balances, then prices the next interval from the new utilization. Views extrapolate the indexes to "now"
without writing, so balances shown in the UI are exact to the second.

## 5. Demo parameters

These are the parameters `script/Deploy.s.sol` deploys and every test runs against. They live in one
place, [`script/lib/MarketConfig.sol`](../script/lib/MarketConfig.sol), so tests always exercise what
actually ships.

| | WETH | WBTC | USDC |
|---|---|---|---|
| Mock price | $2,500 | $60,000 | $1.00 |
| Token decimals / feed decimals | 18 / 8 | 8 / 8 | 6 / 8 |
| Heartbeat | 1 h | 1 h | 24 h |
| Secondary feed | yes (18-dec), max deviation 3% | no | no |
| Sanity bounds | $100 – $1,000,000 | $1,000 – $10,000,000 | $0.50 – $2.00 |
| LTV | 80% | 73% | 77% |
| Liquidation threshold (LT) | 82.5% | 78% | 80% |
| Liquidation bonus | 5% | 6.5% | 4.5% |
| Reserve factor | 15% | 20% | 10% |
| Supply / borrow cap | 100,000 / 80,000 WETH | 5,000 / 2,500 WBTC | 100M / 90M USDC |
| IRM base / slope1 / slope2 | 0 / 4% / 80% | 0 / 4% / 300% | 0 / 6% / 60% |
| Kink `U*` | 80% | 45% | 90% |

### Rates at selected utilizations

Supply APR assumes no deficit (`supply = borrow × U × (1 − RF)`).

| U | WETH borrow | WETH supply | WBTC borrow | WBTC supply | USDC borrow | USDC supply |
|---|---|---|---|---|---|---|
| 0% | 0% | 0% | 0% | 0% | 0% | 0% |
| 45% | 2.25% | 0.86% | **4.00%** (kink) | 1.44% | 3.00% | 1.22% |
| 80% | **4.00%** (kink) | 2.72% | 194.9% | 124.7% | 5.33% | 3.84% |
| 90% | 44.0% | 33.7% | 249.5% | 179.6% | **6.00%** (kink) | 4.86% |
| 100% | 84.0% | 71.4% | 304.0% | 243.2% | 66.0% | 59.4% |

### Rationale

- **WETH** is deep-liquidity collateral, the main collateral asset in the demo. The 80% / 82.5% LTV / LT
  pair is close to what large production markets use for ETH. Its moderate kink at 80% keeps it
  borrowable. It is also the only asset with a **second, independent feed**. It is the dominant
  collateral, so a single manipulated or broken source would do the most damage there.
- **WBTC** is modelled as volatile collateral with **thinner liquidity**. Its lower LTV and larger bonus
  (6.5%) pay liquidators enough to act when on-chain depth is scarce. An early, very steep kink (45%,
  slope2 300%) makes it expensive to drain the WBTC borrow side, and draining a collateral asset's
  liquidity is how a short squeeze on liquidators starts.
- **USDC** is the main borrow asset. Stablecoin borrow demand is price-sensitive, so utilization is
  allowed to run hot (kink 90%, low slope1). It is not priced at a hard-coded $1. It has a real feed with
  wide sanity bounds, because a depeg must be *priced*, not hidden. Its 24-hour heartbeat matches how
  stablecoin feeds are typically configured (deviation-triggered, with a long heartbeat).

### Safety margins implied by the parameters

| | WETH | WBTC | USDC |
|---|---|---|---|
| HF right after borrowing to the max (`LT / LTV`) | 1.031 | 1.068 | 1.039 |
| Collateral drop from max borrow to liquidation (`1 − LTV/LT`) | 3.0% | 6.4% | 3.75% |
| `LT × (1 + bonus)`, must be < 100% | 86.6% | 83.1% | 83.6% |

The last row is enforced on-chain by `PoolConfigurator._validateRiskParams`. Below an HF of
`LT × (1 + bonus)`, seizing collateral at a bonus *lowers* the borrower's health factor. The derivation,
and why the 100% close factor kicks in at HF 0.95, is in
[liquidations.md](liquidations.md#why-lt--1--bonus--1).

## 6. Reserve factor and the treasury

A reserve factor `RF` of each reserve's borrow interest goes to the protocol. It is not transferred
anywhere. It is minted as a **scaled supply position owned by the treasury** (`accruedToTreasury`)
during accrual:

```
interestAccrued    = totalScaledDebt × (newBorrowIndex − oldBorrowIndex)
accruedToTreasury += interestAccrued × RF / newLiquidityIndex
```

Holding it as a scaled supply position means it earns supply interest like any other deposit, and
removing it needs no special rounding path. It also serves as the reserve's **first-loss buffer**. When
a liquidation leaves bad debt, the treasury's claim on that reserve is burned first, and only the
remainder becomes `deficit` (suppliers' exposure). Withdrawing the treasury
(`PoolConfigurator.withdrawReserves`) is therefore a timelocked governance action.

The views `totalSupplied()` and `treasuryBalance()` include the treasury share accrued since the last
interaction (`ReserveLogic.treasuryScaledNow`). Omitting it would count borrower interest up to now as an
asset while leaving out the treasury's share of it as a liability, so the views would overstate solvency
between interactions. The invariant suite found exactly that bug (bug #4 in
[testing.md](testing.md#bugs-found)).

## 7. Caps

Caps are in whole tokens (`uint64`) and are checked on post-action totals:

- **Supply cap** counts supplier plus treasury liabilities. It bounds the protocol's exposure to one
  asset, which matters most if that asset's price or contract later misbehaves. It also bounds how much
  of an illiquid asset can be posted as collateral and then dumped on liquidation.
- **Borrow cap** bounds total debt in an asset. It limits an attacker who borrows an asset in order to
  manipulate its external price, and it limits how far a long-tail borrow side can be drained.

Neither cap ever blocks repayment, withdrawal or liquidation. Only new exposure is capped.

## 8. ERC-4626 vault

`LendingVault` ([source](../contracts/periphery/LendingVault.sol)) is a passive-lender wrapper. Deposits
are supplied to the pool, shares are transferable ERC-20s, and the vault never borrows. Its share
price is `totalAssets / totalSupply`, where `totalAssets` is the vault's pool supply balance including
interest up to now. The local deployment creates WETH and USDC vaults.

- **Inflation attack.** Anyone can donate to the vault by calling `pool.supply(asset, x, vault)`, which
  raises `totalAssets` without minting shares. The vault uses OpenZeppelin's virtual-shares offset
  (`_decimalsOffset() = 6`), which makes that attack cost roughly 10⁶ times what it could steal. The
  unit test runs the attack and checks the victim's loss is bounded.
- **Liquidity-aware limits.** `maxWithdraw` and `maxRedeem` are capped by the pool's cash, and
  `maxDeposit` by the supply cap and pause state. That is required by ERC-4626 and what integrators rely
  on.
- **No oracle dependency.** The vault's position has no debt, so a vault withdrawal never reads a
  price. The vault stays redeemable during an oracle outage.

## 9. Worked example: the demo scenario

The 12-step demo ([deployment.md](deployment.md#demo)) runs this exact path.

1. **Alice** supplies 250,000 USDC and 100 WETH, and deposits another 10,000 USDC through the
   ERC-4626 vault. **Bob** supplies 10 WETH at $2,500, which is $25,000 of collateral. **Carol** supplies
   5 WBTC ($300,000).
2. Bob borrows 15,000 USDC. Borrow capacity is `25,000 × 80% = $20,000`, so the borrow is allowed.
   `HF = 25,000 × 82.5% / 15,000 = 1.375`. Carol borrows 150,000 USDC:
   `HF = 300,000 × 78% / 150,000 = 1.56`.
3. USDC utilization is now `165,000 / 260,000 = 63.5%`: borrow APR `6% × 63.5/90 = 4.23%`, supply APR
   `4.23% × 63.5% × 90% = 2.42%`. Rates are re-priced at every action.
4. ETH falls to $1,800 on both feeds, so the deviation check passes. Collateral is now $18,000 and
   `HF = 18,000 × 82.5% / 15,000 = 0.99`. Bob is liquidatable.
5. A liquidator repays 7,500 USDC. That is 50% of the debt, because HF ≥ 0.95 and the position is
   larger than $2,000. They receive `7,500 / 1,800 × 1.05 = 4.375 WETH`, worth $7,875: a $375 (5%)
   bonus.
6. Bob keeps 5.625 WETH ($10,125) against 7,500 USDC of debt. `HF = 10,125 × 82.5% / 7,500 = 1.114`.
   The liquidation improved his health, as the `LT × (1 + bonus) < 1` rule guarantees in this HF range.
