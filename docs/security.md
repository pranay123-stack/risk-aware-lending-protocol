# Security

This is the security review of record: what the protocol protects against, how, **why each protection
exists** (and why nothing heavier was added), and which test proves it. The threat catalogue (actors,
assets, attack trees) is in [threat-model.md](threat-model.md). Oracle-specific defences are in
[oracles.md](oracles.md), and liquidation abuse in [liquidations.md](liquidations.md#abuse-cases-considered).

> **Status.** A portfolio project. It has had no external audit. It is designed, tested and documented as
> if it were going to have one. Everything runs with mock tokens and mock or testnet oracles. Never
> deploy it with real funds.

---

## 1. Security properties

| # | Property | Enforced by | Proven by |
|---|---|---|---|
| P1 | Every reserve can always pay its liabilities from `cash + debt + deficit` | index accounting, rounding policy, bad-debt write-off | `invariant_reserveSolvency` |
| P2 | The internal ledger never diverges from token balances | internal `cash`, CEI | `invariant_cashMatchesTokenBalance` |
| P3 | No user action can create or leave a position under its LTV capacity | post-state checks on borrow, withdraw and collateral toggle | `invariant_borrowNeverExceedsCapacity`, `invariant_healthyStaysHealthyWithoutRiskChange` |
| P4 | Liquidation never destroys value and never touches a healthy account | eligibility checks, capped seizure | `invariant_liquidationCannotCreateInsolvency` |
| P5 | No debt without collateral survives a transaction | same-transaction write-off | `invariant_noUncollateralizedDebt` |
| P6 | Interest indexes never decrease | growth factors ≥ 1, deficit instead of index cuts | `invariant_indexesNeverDecrease` |
| P7 | Totals equal the sum of balances; bitmap agrees with balances | single write path per balance | `invariant_scaledBalancesSumToTotals` |
| P8 | Withdrawals never exceed available liquidity | `amount ≤ cash` check | `invariant_withdrawRespectsLiquidity` |
| P9 | The vault never promises more than it holds | ERC-4626 with virtual-share offset | `invariant_vaultBacked` |
| P10 | No round trip extracts value through rounding | protocol-favouring rounding everywhere | `test/fuzz/RoundingFuzz.t.sol` (6 fuzz tests) |
| P11 | Risk-increasing admin actions are delayed; risk-reducing ones are instant | role split, timelock | `test/unit/Governance.t.sol` (21 tests) |

## 2. Protections, one by one

Each row answers three questions: what could go wrong, what stops it, and why that is the right weight
of protection.

### Reentrancy

- **Threat.** A token with transfer hooks (ERC-777 style, or a malicious listed token) re-enters the
  pool mid-action and observes or changes half-updated state. Read-only reentrancy also matters: an
  external protocol reading pool views during the callback sees inconsistent balances.
- **Protection.** Two layers. Every state-changing entry point follows checks-effects-interactions:
  all accounting is written before any token moves, and risk checks run on post-state. On top of that,
  every entry point carries OpenZeppelin's **`ReentrancyGuardTransient`**, one lock shared by supply,
  withdraw, borrow, repay, liquidate, collateral toggle and deficit cover. That shared lock blocks
  *cross-function* reentrancy, which per-function guards miss.
- **Why both.** CEI alone is correct today, but one future refactor away from broken. The lock makes the
  property structural. The transient (EIP-1153) variant gives the same guarantee for about 1.9k gas less
  per call than the classic storage guard, measured in [gas-report.md](gas-report.md).
- **Proof.** `test_reentrancyFromTokenHook_isBlocked` lists a token whose `transfer` hook re-enters the
  pool; the inner call reverts with `ReentrancyGuardReentrantCall`.

### Access control

- **Threat.** Anyone calling a privileged setter: listing a fake asset, changing an oracle, lowering an
  LT.
- **Protection.** One role registry, `ACLManager`, built on OpenZeppelin `AccessControl`. The pool's
  setters accept only the `PoolConfigurator` contract (`CONFIGURATOR` role). The configurator accepts
  only `POOL_ADMIN` (the timelock) or, for risk-reducing actions, `EMERGENCY_ADMIN` (the guardian).
  After deployment, the deployer hands every admin role to the timelock and renounces its own
  (`ProtocolDeployer.handOverToTimelock`).
- **Why this shape.** A single registry means one place to audit who can do what. Routing every setter
  through the configurator means validation can't be bypassed by calling the pool directly. See
  [Admin](#admin) for why the admin itself is constrained.
- **Proof.** `test_revert_strangerCannotConfigure`, `test_revert_poolSettersOnlyConfigurator`,
  `test_revert_guardianCannotChangeRiskParameters`, `test_handOver_removesDeployerPowers`,
  `test_revert_onlyDefaultAdminGrantsRoles`.

### Integer overflow and precision

- **Threat.** Silent wraparound, or truncation that compounds into mispriced interest.
- **Protection.** Solidity 0.8 checked arithmetic everywhere. `unchecked` appears only on loop
  counters and in the round-up helpers (`p / d + (p % d == 0 ? 0 : 1)`, which cannot overflow). Every
  narrowing cast of a computed value goes through OpenZeppelin `SafeCast`. The only raw casts are the
  constant `RAY`, `block.timestamp` to `uint40` (overflows in the year 36812), reserve ids bounded by
  32, the grace deadline (period ≤ 4 h) and oracle answers already checked to be in `(0, 2¹²⁸]`. The
  non-obvious ones are annotated in the source. Inputs are bounded where products
  form: oracle answers ≤ 2¹²⁸, token decimals ≤ 24, feed decimals ≤ 36, and total borrow rate ≤ 1000%
  APR, so `uint128` ray indexes cannot overflow in centuries. `Math.mulDiv` computes liquidation
  seizure without intermediate overflow.
- **Precision.** Rays (1e27) for indexes and rates, wads (1e18) for prices and health factor. Interest
  compounding uses a Taylor series on `x = r·Δt` in ray. The widespread binomial form truncated the cubic
  term and under-charged borrowers. That was a real bug found here, bug #1 in
  [testing.md](testing.md#bugs-found).
- **Proof.** `test_answerAbove2to128_isRejectedNotOverflowed`, `test_compoundedInterest_closeToContinuousCompounding`,
  `MathLibraries.t.sol` (11 tests), and fuzzed math in `RoundingFuzz.t.sol`.

### Oracle manipulation

Covered in full in [oracles.md](oracles.md). In short: no spot or DEX prices; heartbeat, bounds,
incomplete-round, future-timestamp and invalid-answer checks; an optional independent secondary feed
with a deviation check; a guardian pause per asset; and fail-closed behaviour that never liquidates on a
bad price while leaving supply, repay and debt-free withdrawals working.

### Flash-loan attacks

- **Threat.** Borrowed capital, repaid within one transaction, used to move a price, a utilization
  figure or a share price that the protocol then acts on.
- **Protection.** The protocol has no flash-loan feature itself (out of scope for v1), but it must still
  be safe against flash loans taken elsewhere:
  - prices come only from push-based aggregators, which a flash loan cannot move;
  - `cash` is internal, so flash-borrowed tokens sent to the pool change nothing;
  - interest is charged on elapsed time. A utilization spike inside one transaction accrues zero
    interest (`Δt = 0`) and moves no balance (`test_sameBlockUtilizationSpike_movesNoBalances`);
  - the vault's share price can't be inflated profitably (next item).
- **If flash loans are added later**, they need: a fee that accrues to suppliers; the reentrancy lock held
  across the callback, with a re-check that `cash` is restored; exclusion from the `cash`-based rate
  update until repayment; and new invariants for "cash after ≥ cash before + fee".

### Donation and inflation attacks

- **Threat.** Sending tokens directly to the pool or vault to move an exchange rate. This is the
  empty-market pattern behind the Hundred Finance and Radiant exploits, and the classic ERC-4626
  first-depositor attack.
- **Protection.** The pool never uses `balanceOf` for accounting: `cash` is updated only by the pool's
  own actions, so donations are invisible to indexes, rates and valuation. The vault uses OpenZeppelin's
  virtual-shares offset (`_decimalsOffset = 6`), which makes a donation attack cost about 10⁶ times what
  it can steal. Supplies that would mint zero scaled balance revert (`AmountTooSmall`), so no deposit is
  ever silently credited with nothing.
- **Proof.** `test_directDonation_doesNotAffectAccounting`, the vault inflation test in
  `LendingVault.t.sol`, `test_dustDepositRejected_protectsExistingHolders`, and
  `invariant_cashMatchesTokenBalance`.

### Rounding

- **Threat.** Many tiny operations each rounded in the user's favour, draining a reserve wei by wei.
  This is the "precision loss" class seen in several 2023 lending exploits.
- **Protection.** A single documented policy: every rounding favours the protocol. Mint rounds down,
  burn rounds up. Debt rounds up, collateral rounds down. Borrow index rounds up, liquidity index rounds
  down. The policy table is in [architecture.md](architecture.md) ("Rounding policy").
- **Proof.** `RoundingFuzz.t.sol`: supply/withdraw and borrow/repay round trips at fuzzed amounts and
  times never return more than was put in. `invariant_reserveSolvency` holds over random sequences with
  a 10-wei tolerance for rounding dust in the *views* (each view rounds independently). The dust is
  bounded, and the stored accounting itself never loses a wei (`invariant_cashMatchesTokenBalance` is
  exact).

### Liquidation abuse

See [liquidations.md](liquidations.md#abuse-cases-considered): healthy-account liquidation, over-close,
dust griefing, bonus farming, post-unpause sniping, price mismatch between valuation and seizure, and
pulling payment from someone else's allowance. Each is blocked, and each has a test.

### Insolvent withdrawals

- **Threat.** Withdrawing collateral that backs debt, or withdrawing more than the reserve holds.
- **Protection.** Collateral withdrawals by indebted accounts must leave `debt ≤ LTV capacity` on the
  post-withdraw state. That is stricter than "HF ≥ 1", so no withdrawal can park a position at the
  liquidation edge. Every withdrawal is bounded by `cash`. A full withdrawal burns exactly the scaled
  balance, so there's no rounding remainder to exploit.
- **Proof.** `SupplyWithdraw.t.sol` (29 tests), `invariant_withdrawRespectsLiquidity`,
  `invariant_healthyStaysHealthyWithoutRiskChange`.

### Unauthorized or dangerous parameter changes

- **Threat.** Even an *authorized* admin can set parameters that hurt users: an LT under current
  positions, `LT × (1 + bonus) ≥ 1`, a 5,000% rate curve, a fake oracle.
- **Protection.** The timelock delays every such change (users can exit during the delay), and the
  configurator **validates** every change against hard bounds that even the timelock can't bypass:
  `LTV < LT ≤ 95%`, `LT × (1 + bonus) < 100%`, `0 < bonus ≤ 20%`, reserve factor ≤ 50%, rate ceiling
  1000%, heartbeat ≤ 2 days, deviation ≤ 20%, grace period ≤ 4 h. A reserve factor or rate model change
  accrues first, so it never applies retroactively. Decimals can never change after listing. A reserve
  can only be deactivated when empty.
- **Proof.** `test_revert_riskParameterInvariants`, `testFuzz_acceptedParamsSatisfyLiquidationSafety`,
  `test_timelock_parameterChangeRequiresDelay`, `test_revert_decimalsCannotChange`,
  `test_deactivateOnlyEmptyReserve`, `test_revert_gracePeriodAboveMax`, `test_revert_invalidConfigs`.

### Denial of service

| Vector | Mitigation |
|---|---|
| unbounded loops over reserves | at most 32 reserves; valuation walks a bitmap and stops early; worst-case valuation gas is measured (`test_accountValuationGasBoundedAtMaxReserves`) |
| unbounded loops over users | none on-chain. The pool never iterates users; batching over users happens only in off-chain `PoolLens` views |
| one broken oracle freezing everyone | market isolation: only exposed accounts are priced ([risk-model.md](risk-model.md#1-account-valuation)) |
| one bad account breaking a monitoring batch | `PoolLens.getAccountsHealth` wraps each account in try/catch |
| liquidations impossible at 100% utilization | `receiveSupply` liquidations need no cash |
| supply cap reached, blocking repayment or exit | caps apply only to new exposure; repay, withdraw and liquidate are never capped |
| a reverting feed | `try/catch` around every feed read, with fallback to the other source |

### Griefing

| Vector | Mitigation |
|---|---|
| supply *on behalf of* a victim to add oracle exposure they didn't choose (bricking their borrows during that asset's outage) | only the owner's own first supply auto-enables collateral; supplying on behalf of someone never does |
| leaving dust positions that nobody will liquidate | $2,000 full-close rule, $1,000 dust rule, same-transaction bad-debt write-off |
| dust collateral in a second reserve to dodge write-off | the dust is itself liquidatable, and seizing it triggers the write-off (`test_dustCollateralDoesNotShieldBadDebtForever`) |
| repaying 1 wei of someone's debt to spam events | harmless: repay is permissionless by design and only lowers debt; 0-scaled repays revert |
| front-running the first vault depositor | virtual-share offset |

<a id="emergency-controls"></a>

### Emergency controls

| Control | Who | Blocks | Still allowed |
|---|---|---|---|
| **Pool pause** | guardian, instant | supply, withdraw, borrow, collateral toggles, liquidation | **repay** |
| **Reserve pause** | guardian, instant | every action touching that reserve, including liquidations using it | repay |
| **Reserve freeze** | guardian freezes instantly; only the timelock unfreezes | new exposure: supply, borrow, enabling collateral | withdraw, repay, liquidate, disabling collateral: an orderly wind-down |
| **Oracle asset pause** | guardian, instant | every price read for that asset, so price-dependent actions of **exposed** accounts only | everything that needs no price |
| **Liquidation grace period** | automatic on pool unpause (300 s local, 30 min default, max 4 h) | liquidations | everything else, so borrowers can repay interest accrued during the pause |

The full action matrix is in the header of [`ValidationLogic.sol`](../contracts/logic/ValidationLogic.sol)
and is tested by `test_poolPause_matrix`, `test_reservePause_isolatesOneMarket`,
`test_freeze_allowsExitsButNoNewExposure`, `test_oraclePause_isolatedToExposedAccounts` and
`test_unpause_opensLiquidationGracePeriod`.

**Why repay is never blocked.** Interest keeps accruing during a pause. A borrower who cannot repay
during a pause can come out of it liquidatable through no fault of their own.

**Emergency withdrawal: considered and rejected as a bypass.** A common request is an "emergency
withdraw" that ignores health checks during a crisis. For a lending pool that means letting borrowers
walk away with collateral while their debt stays behind, which moves the crisis onto suppliers. The
design instead makes the normal exit paths as resilient as possible:
- debt-free suppliers and vault holders can withdraw **without any oracle**, so an oracle incident
  never traps lenders;
- repay works during every pause, and freeze keeps every exit open;
- per-market pause and oracle pause isolate one failing market instead of stopping all of them;
- the only way to exit while paused is to have no debt, and that is intended.

A true "shutdown and settle" mode (fixing final prices and paying out pro-rata) would be the right
last-resort tool for a production system. It is listed under future work.

<a id="admin"></a>

## 3. Admin: why unrestricted admin access is dangerous

An admin with unrestricted, instant power over a lending pool has **custody of every user's funds**,
whatever the UI says. With the setters this protocol has, a single unrestricted key could:

1. **list a worthless token** it controls, with a 95% LT and its own oracle, supply a billion units, and
   borrow every other reserve empty;
2. **point an asset's oracle** at a feed it controls and liquidate every borrower at a fake price;
3. **lower an LT** under existing positions and liquidate them itself, collecting the bonus;
4. **swap a rate model** to 1000% APR, making every borrower liquidatable within days;
5. **withdraw the treasury buffer** right before a known bad-debt event;
6. **pause and freeze** the protocol indefinitely while doing any of the above.

It doesn't take a malicious team. Compromised keys are among the largest loss categories in the
industry. Approximate, well-documented examples: the Ronin bridge (2022, about $600M, 5 of 9 validator
keys), the Harmony Horizon bridge (2022, about $100M, a 2-of-5 multisig), Multichain (2023, keys held
by one person) and Radiant Capital (2024, about $50M, signer devices compromised to sign a malicious
ownership transfer of the lending pool contracts). In every case the protocol's code worked as written.
The admin path was the vulnerability.

### How this protocol constrains its admin

| Layer | What it does |
|---|---|
| **Role split** | `EMERGENCY_ADMIN` (guardian) can only reduce risk: pause, freeze, oracle pause. It cannot list, unfreeze, change parameters or move funds (`test_revert_guardianCannotChangeRiskParameters`). `POOL_ADMIN` holds risk-increasing powers |
| **Timelock** | `POOL_ADMIN` and `DEFAULT_ADMIN_ROLE` are held by an OpenZeppelin `TimelockController`. Every risk-increasing change is a public, queued operation that executes only after the delay (60 s locally for the demo, **1 day** by default elsewhere). Users see it coming and can exit. The guardian can pause if a queued operation is malicious. The Admin page and `GET /governance/timelock` decode every queued call, so users can read exactly what will change |
| **Hard bounds** | even the timelock cannot set parameters outside the validated ranges ([section 2](#unauthorized-or-dangerous-parameter-changes)) |
| **No upgradeability** | contracts are not proxies. Admin powers are exactly the setters listed, and there is no "replace the code" path. A new version means a new deployment users migrate to voluntarily |
| **No arbitrary transfers** | no function moves user balances. `withdrawReserves` can only take the treasury's own accrued claim, and only up to available cash |
| **Handover verified** | `Deploy.s.sol` asserts on-chain that the timelock holds `POOL_ADMIN` and `DEFAULT_ADMIN`, that the deployer holds neither, and that the timelock administers itself, then prints the role holders. A deployment that doesn't end in that state fails. `test_handOver_removesDeployerPowers` covers the same in the unit suite |

**Residual trust.** The timelock proposer (a multisig in production, the deployer locally) can still
schedule anything within the bounds. The protection is visibility plus delay. It is not prevention.
Production would add a multisig proposer with hardware-backed signers, a longer delay for listings and
oracle changes, and an independent guardian that can cancel queued operations.

## 4. Libraries used, and why each one

The brief asked not to add security libraries blindly. Each dependency below was chosen for a specific
threat, and nothing else is imported.

| Library (OpenZeppelin 5.4) | Used for | Why not hand-written, or why not more |
|---|---|---|
| `SafeERC20` | every token transfer | handles tokens that return no bool (USDT-style) and tokens that return false instead of reverting |
| `ReentrancyGuardTransient` | one shared lock on all pool entry points | see above; the transient variant is cheaper for the same guarantee |
| `AccessControl` (in `ACLManager`) | role registry | audited, and it emits standard `RoleGranted`/`RoleRevoked` events that the indexer and any explorer understand |
| `TimelockController` | governance delay | audited and standard; every admin change becomes an indexable, decodable proposal. A custom timelock would be new attack surface for no benefit |
| `SafeCast` | narrowing casts to `uint128` and other widths | overflow on a cast is silent without it |
| `Math.mulDiv` | liquidation seizure maths | full-precision `a·b/c` with explicit rounding direction, no intermediate overflow |
| `ERC4626` | the lender vault | the virtual-shares defence against inflation attacks is built in |

**Deliberately not used.** `Pausable` (the pause matrix is per action and per reserve, which the
single-flag mixin can't express); upgradeable proxies (see above); `Ownable` anywhere in the protocol
(roles are the only authority, and mock tokens and feeds are outside the protocol).

## 5. Static analysis

**Slither** (`make slither`: production contracts only, with mocks, tests, scripts and dependencies
filtered out) on the final code: **64 results: 0 High, 14 Medium, 43 Low, 7 Informational.** Every
Medium is triaged below. Reproduce with `make slither`; the full output lands in
`test-results/slither-final.txt` (git-ignored).

| Detector (count) | Where | Verdict |
|---|---|---|
| `divide-before-multiply` (2) | `RiskEngine`: `value = balance × price / unit`, then `value × LTV` | intentional. Value truncates by < 1e-18 USD before weighting, and in the protocol's favour (collateral rounds down). Weighting happens in bps with one division at the end |
| `incorrect-equality` (5) | `last == block.timestamp`, `dt == 0`, `totalScaledDebt == 0` in accrual | these are "already accrued this block" and "no debt" short-circuits, not balance comparisons an attacker can steer. The slow path gives the same result |
| `uninitialized-local` (4) | `liquidityRate`, `secondaryDecimals`, `price`, the liquidation vars struct | zero is the intended default (no debt means rate 0; no secondary means 0 decimals; `price` is set in the `try` branch, and the `catch` branch returns) |
| `unused-return` (3) | `getBorrowRate(1,1)` probe in the configurator; `latestRoundData` unused fields; `POOL.withdraw` in the vault | the probe only checks that the model doesn't revert. `roundId`, `startedAt` and `answeredInRound` are deliberately unused (Chainlink deprecated `answeredInRound` checks). The vault never passes `type(uint256).max`, so the pool returns exactly `assets` |
| `calls-loop` (27, Low) | `PoolLens` views | off-chain read helpers, bounded by 32 reserves, try/catch where one failure must not break the batch |
| `reentrancy-events` (9, Low) | configurator setters emit after calling the pool; vault emits after `pool.withdraw` | the callee is the protocol's own pool, and the setters are admin-only. The vault follows OpenZeppelin's own ordering |
| `timestamp` (7, Low) | interest accrual, staleness, grace period | inherent. Validator timestamp drift of a few seconds is immaterial next to 1 h heartbeats and per-second interest |
| `cyclomatic-complexity` (1, Info) | `executeLiquidation` | accepted. It is the most-tested function in the codebase |
| `naming-convention` (6, Info) | `SCREAMING_CASE` immutables (`POOL`, `ACL`) | deliberate; matches forge-lint's convention for immutables |

One real finding was fixed during development. An earlier Slither run reported
**`arbitrary-send-erc20` (High)** on `transferFrom(params.liquidator, …)` inside the DELEGATECALLed
`LiquidationLogic`. It was not exploitable, because the pool always set `liquidator = msg.sender` and
Solidity blocks direct CALLs into state-changing library functions. It was fixed structurally anyway:
the parameter was removed and the library uses `msg.sender`, so the unsafe shape can't come back.

**forge lint** runs clean on production code. The rules excluded in `foundry.toml` (`[lint]`) are
style rules that conflict with the codebase's conventions (screaming-case immutables, mixed-case
variables); tests are excluded from lint. Each remaining safe cast or shift carries an inline
justification.

## 6. Bugs found during development

Found before shipping: an interest under-charge (by a unit test against `e^x`), a solvency-view bug
(by the invariant suite), a contract-size overflow (by the EIP-170 limit), an unsafe-looking transfer
shape (by Slither) and a `PoolLens` max-withdraw mismatch during oracle outages (while writing these
docs). There were also two bugs in the invariant handler and a set of off-chain bugs that only running
the full stack exposed. The full list, with how each was found and the regression test that pins it, is
in [testing.md](testing.md#bugs-found).

<a id="known-limitations-and-future-work"></a>

## 7. Known limitations and future work

| Item | Status |
|---|---|
| External audit | not done: portfolio project |
| Formal verification of the solvency invariant | not done; the invariant suite is the substitute |
| Flash loans | not implemented; the requirements to add them safely are listed above |
| L2 sequencer-uptime check | not needed on Anvil or Sepolia; required before any rollup deployment |
| Insurance / safety module to back deficits | not implemented; deficit is explicit and coverable by anyone ([liquidations.md](liquidations.md#bad-debt)) |
| Shutdown-and-settle mode | not implemented; pause, freeze and oracle pause cover containment |
| Isolation mode / efficiency mode (per-asset debt ceilings, correlated-asset LTVs) | not implemented; caps approximate the former |
| Supply-cap race | a supply cap can be filled by a front-runner; it bounds exposure, not fairness |
| Timelock proposer locally | the deployer EOA (Anvil key #0) for the demo; a multisig in production |
| Governance token / on-chain voting | out of scope; the timelock is the governance interface |
| Upgradeability | none by design; migration is the upgrade path |

## 8. Pre-deployment checklist (for any public deployment)

1. Use a **fresh deployer key** generated on a clean machine and funded only with testnet ETH.
   `Deploy.s.sol` refuses Anvil's public key on any chain except 31337.
2. Set `GUARDIAN` and `TIMELOCK_PROPOSER` to addresses you control that are **not** the deployer.
3. Keep the timelock delay at 1 day or more.
4. Verify each Chainlink feed address against Chainlink's official directory, and match the heartbeats
   in `MarketConfig` to the feeds' real heartbeats.
5. After deployment, confirm on-chain that the deployer holds no role: `hasRole` for `DEFAULT_ADMIN`,
   `POOL_ADMIN` and `EMERGENCY_ADMIN`.
6. Run `forge test`, `make slither` and the fork test against the target network's feeds.
7. Keep the token contracts as mocks. This protocol must never custody real assets.
