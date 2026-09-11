// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingPool} from "../../contracts/core/LendingPool.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {LendingVault} from "../../contracts/periphery/LendingVault.sol";
import {PoolLens} from "../../contracts/periphery/PoolLens.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Stateful fuzzing actor. Every action is a realistic user operation with bounded inputs.
///         Ghost variables record violations that can only be observed *during* a call (e.g.
///         "this borrow left debt above capacity"), so the invariant functions can assert on them.
contract LendingHandler is Test {
    uint256 internal constant HF_ONE = 1e18;

    LendingPool public immutable pool;
    PoolLens public immutable lens;
    LendingVault public immutable vault;
    MockERC20[3] public tokens; //       WETH, WBTC, USDC
    MockAggregator[3] public feeds; //   primary feed per token
    MockAggregator public wethSecondary;
    uint256[3] internal unitsCap; //     per-call amount ceiling in token units
    uint256[3] internal minPrice8; //    stay inside the oracle's sanity bounds
    uint256[3] internal maxPrice8;

    address[] public actors;

    // ------------------------------------------------------------------ ghosts
    uint256 public ghost_borrowCapacityViolations;
    uint256 public ghost_withdrawBeyondCash;
    uint256 public ghost_healthyBecameLiquidatable;
    uint256 public ghost_indexDecreases;
    uint256 public ghost_liquidationSurplusLoss;
    uint256 public ghost_liquidationOfHealthy;
    uint256 public ghost_liquidations;
    uint256 public ghost_badDebtEvents;
    mapping(bytes32 => uint256) public calls;

    uint256[3] internal lastLiquidityIndex;
    uint256[3] internal lastBorrowIndex;

    constructor(
        LendingPool pool_,
        PoolLens lens_,
        LendingVault vault_,
        MockERC20[3] memory tokens_,
        MockAggregator[3] memory feeds_,
        MockAggregator wethSecondary_
    ) {
        pool = pool_;
        lens = lens_;
        vault = vault_;
        tokens = tokens_;
        feeds = feeds_;
        wethSecondary = wethSecondary_;
        unitsCap = [uint256(200e18), 10e8, 2_000_000e6];
        minPrice8 = [uint256(150e8), 1500e8, 0.9e8];
        maxPrice8 = [uint256(900_000e8), 9_000_000e8, 1.1e8];
        for (uint256 i; i < 5; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        for (uint256 i; i < 3; ++i) {
            lastLiquidityIndex[i] = 1e27;
            lastBorrowIndex[i] = 1e27;
        }
    }

    // ================================================================== modifiers

    /// @dev Wraps actions that change neither prices nor time. No account that was healthy
    ///      before may be liquidatable after: only price moves and accrued interest can do that.
    modifier noRiskChange() {
        uint256[] memory before = _healthFactors();
        _;
        uint256[] memory afterHf = _healthFactors();
        for (uint256 i; i < actors.length; ++i) {
            if (before[i] >= HF_ONE && afterHf[i] < HF_ONE) ghost_healthyBecameLiquidatable++;
        }
        _checkIndexes();
    }

    // ================================================================== actions

    function supply(uint256 actorSeed, uint256 assetSeed, uint256 amount) external noRiskChange {
        (address actor, uint256 a) = (_actor(actorSeed), assetSeed % 3);
        amount = bound(amount, 1, unitsCap[a]);
        MockERC20 t = tokens[a];
        deal(address(t), actor, t.balanceOf(actor) + amount);
        vm.startPrank(actor);
        t.approve(address(pool), amount);
        try pool.supply(address(t), amount, actor) {
            calls["supply"]++;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 assetSeed, uint256 amount, bool max) external noRiskChange {
        (address actor, uint256 a) = (_actor(actorSeed), assetSeed % 3);
        address asset = address(tokens[a]);
        uint256 balance = pool.supplyBalanceOf(asset, actor);
        if (balance == 0) return;
        amount = max ? type(uint256).max : bound(amount, 1, balance);
        uint256 cashBefore = pool.getReserveData(asset).cash;
        vm.prank(actor);
        try pool.withdraw(asset, amount, actor) returns (uint256 out) {
            calls["withdraw"]++;
            if (out > cashBefore) ghost_withdrawBeyondCash++;
        } catch {}
    }

    /// @dev Borrows 50%..110% of the lens maximum: positions run close to the edge (so price moves
    ///      produce liquidations), and over-limit borrows exercise the rejection path. Any accepted
    ///      borrow must leave debt within LTV capacity.
    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount) external noRiskChange {
        (address actor, uint256 a) = (_actor(actorSeed), assetSeed % 3);
        address asset = address(tokens[a]);
        uint256 maxBorrow = lens.getMaxBorrow(actor, asset);
        if (maxBorrow == 0) return;
        amount = bound(amount, maxBorrow / 2 + 1, maxBorrow + maxBorrow / 10 + 1);
        vm.prank(actor);
        try pool.borrow(asset, amount) {
            calls["borrow"]++;
            DataTypes.AccountData memory d = pool.getUserAccountData(actor);
            if (d.totalDebtValue > d.borrowCapacityValue) ghost_borrowCapacityViolations++;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 payerSeed, uint256 assetSeed, uint256 amount)
        external
        noRiskChange
    {
        (address actor, uint256 a) = (_actor(actorSeed), assetSeed % 3);
        address payer = _actor(payerSeed);
        address asset = address(tokens[a]);
        uint256 debt = pool.debtBalanceOf(asset, actor);
        if (debt == 0) return;
        amount = bound(amount, 1, debt + debt / 10 + 1);
        deal(asset, payer, tokens[a].balanceOf(payer) + amount);
        vm.startPrank(payer);
        tokens[a].approve(address(pool), amount);
        try pool.repay(asset, amount, actor) {
            calls["repay"]++;
        } catch {}
        vm.stopPrank();
    }

    function setCollateral(uint256 actorSeed, uint256 assetSeed, bool enabled) external noRiskChange {
        (address actor, uint256 a) = (_actor(actorSeed), assetSeed % 3);
        vm.prank(actor);
        try pool.setUseReserveAsCollateral(address(tokens[a]), enabled) {
            calls["setCollateral"]++;
        } catch {}
    }

    struct LiquidationCall {
        address liquidator;
        address borrower;
        uint256 collateralIdx;
        uint256 debtIdx;
        uint256 amount;
        bool receiveSupply;
    }

    /// @dev Liquidations must never lower any reserve's surplus (cash + debt + deficit - liabilities):
    ///      a liquidation moves value around, it cannot destroy it. Targets an actually unhealthy
    ///      account and legs it actually holds; random targeting would almost never hit one.
    ///      Healthy targets are still attempted 1 time in 8 to exercise the rejection path.
    function liquidate(
        uint256 liquidatorSeed,
        uint256 borrowerSeed,
        uint256 collSeed,
        uint256 debtSeed,
        uint256 amount,
        bool receiveSupply
    ) external noRiskChange {
        address borrower = _actor(borrowerSeed);
        if (liquidatorSeed % 8 != 0) {
            (bool found, address target) = _findUnhealthy(borrowerSeed);
            if (!found) return;
            borrower = target;
        }
        (bool hasLegs, uint256 c, uint256 d) = _pickLegs(borrower, collSeed, debtSeed);
        if (!hasLegs) return;
        _liquidate(
            LiquidationCall({
                liquidator: _actor(liquidatorSeed),
                borrower: borrower,
                collateralIdx: c,
                debtIdx: d,
                amount: amount,
                receiveSupply: receiveSupply
            })
        );
    }

    function _findUnhealthy(uint256 seed) internal view returns (bool, address) {
        uint256 n = actors.length;
        seed %= n; // reduce first: raw fuzz seeds near 2^256 would overflow `seed + k`
        for (uint256 k; k < n; ++k) {
            address a = actors[(seed + k) % n];
            if (_hf(a) < HF_ONE) return (true, a);
        }
        return (false, address(0));
    }

    function _pickLegs(address borrower, uint256 collSeed, uint256 debtSeed)
        internal
        view
        returns (bool, uint256 c, uint256 d)
    {
        bool okC;
        bool okD;
        (collSeed, debtSeed) = (collSeed % 3, debtSeed % 3);
        for (uint256 k; k < 3; ++k) {
            uint256 ci = (collSeed + k) % 3;
            if (!okC && pool.isUsingAsCollateral(address(tokens[ci]), borrower)) (okC, c) = (true, ci);
            uint256 di = (debtSeed + k) % 3;
            if (!okD && pool.debtBalanceOf(address(tokens[di]), borrower) != 0) (okD, d) = (true, di);
        }
        return (okC && okD, c, d);
    }

    function _liquidate(LiquidationCall memory lc) internal {
        MockERC20 debtToken = tokens[lc.debtIdx];
        uint256 debt = pool.debtBalanceOf(address(debtToken), lc.borrower);
        if (debt == 0) return;
        // Mostly "max" (the common bot strategy), sometimes partial to exercise close factor and dust rules.
        lc.amount = lc.amount % 3 == 0 ? type(uint128).max : bound(lc.amount, 1, debt);

        uint256 hfBefore = _hf(lc.borrower);
        int256[3] memory surplusBefore = _surpluses();
        uint256[3] memory deficitBefore = _deficits();

        uint256 funding = lc.amount > debt ? debt : lc.amount;
        deal(address(debtToken), lc.liquidator, debtToken.balanceOf(lc.liquidator) + funding);
        vm.startPrank(lc.liquidator);
        debtToken.approve(address(pool), funding);
        try pool.liquidate(
            address(tokens[lc.collateralIdx]), address(debtToken), lc.borrower, lc.amount, lc.receiveSupply
        ) {
            calls["liquidate"]++;
            ghost_liquidations++;
            if (lc.receiveSupply) calls["liquidateReceiveSupply"]++;
            if (lc.collateralIdx == lc.debtIdx) calls["liquidateSameAsset"]++;
            if (hfBefore >= HF_ONE) ghost_liquidationOfHealthy++;
            _recordLiquidationEffects(surplusBefore, deficitBefore);
        } catch {
            calls["liquidateReverted"]++;
        }
        vm.stopPrank();
    }

    function _recordLiquidationEffects(int256[3] memory surplusBefore, uint256[3] memory deficitBefore)
        internal
    {
        int256[3] memory surplusAfter = _surpluses();
        uint256[3] memory deficitAfter = _deficits();
        for (uint256 i; i < 3; ++i) {
            if (surplusAfter[i] + 3 < surplusBefore[i]) ghost_liquidationSurplusLoss++;
            if (deficitAfter[i] > deficitBefore[i]) ghost_badDebtEvents++;
        }
    }

    function coverDeficit(uint256 payerSeed, uint256 assetSeed, uint256 amount) external noRiskChange {
        uint256 a = assetSeed % 3;
        address asset = address(tokens[a]);
        uint256 deficit = pool.getReserveData(asset).deficit;
        if (deficit == 0) return;
        address payer = _actor(payerSeed);
        amount = bound(amount, 1, deficit);
        deal(asset, payer, tokens[a].balanceOf(payer) + amount);
        vm.startPrank(payer);
        tokens[a].approve(address(pool), amount);
        pool.coverDeficit(asset, amount);
        vm.stopPrank();
        calls["coverDeficit"]++;
    }

    function vaultDeposit(uint256 actorSeed, uint256 amount) external noRiskChange {
        address actor = _actor(actorSeed);
        amount = bound(amount, 2, 1_000_000e6);
        deal(address(tokens[2]), actor, tokens[2].balanceOf(actor) + amount);
        vm.startPrank(actor);
        tokens[2].approve(address(vault), amount);
        try vault.deposit(amount, actor) {
            calls["vaultDeposit"]++;
        } catch {}
        vm.stopPrank();
    }

    function vaultRedeem(uint256 actorSeed, uint256 shares) external noRiskChange {
        address actor = _actor(actorSeed);
        uint256 maxShares = vault.maxRedeem(actor);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);
        vm.prank(actor);
        try vault.redeem(shares, actor, actor) {
            calls["vaultRedeem"]++;
        } catch {}
    }

    // ------------------------------------------------------------------ risk-changing actions

    /// @dev Moves one price by -30%..+25%, clamped to the oracle's sanity bounds. WETH's secondary
    ///      feed moves in lock-step so the deviation breaker does not trip.
    function movePrice(uint256 assetSeed, uint256 moveBps) external {
        uint256 a = assetSeed % 3;
        moveBps = bound(moveBps, 7000, 12_500);
        if (a == 2) moveBps = bound(moveBps, 9800, 10_200); // stablecoin wobbles
        uint256 price = uint256(feeds[a].latestAnswer()) * moveBps / 10_000;
        if (price < minPrice8[a]) price = minPrice8[a];
        if (price > maxPrice8[a]) price = maxPrice8[a];
        feeds[a].setAnswer(int256(price));
        if (a == 0) wethSecondary.setAnswer(int256(price) * 1e10);
        calls["movePrice"]++;
        _checkIndexes();
    }

    /// @dev Gap-down crash of a volatile asset (-40%..-70% in one update). Liquidators cannot act
    ///      between the old and new price, so this is how collateral ends up worth less than debt:
    ///      it drives the bad-debt write-off and deficit paths.
    function crash(uint256 assetSeed, uint256 keepBps) external {
        uint256 a = assetSeed % 2; // WETH or WBTC
        keepBps = bound(keepBps, 3000, 6000);
        uint256 price = uint256(feeds[a].latestAnswer()) * keepBps / 10_000;
        if (price < minPrice8[a]) price = minPrice8[a];
        feeds[a].setAnswer(int256(price));
        if (a == 0) wethSecondary.setAnswer(int256(price) * 1e10);
        calls["crash"]++;
        _checkIndexes();
    }

    /// @dev Advance time (interest accrues) and refresh every feed so nothing goes stale.
    function warp(uint256 dt) external {
        dt = bound(dt, 1 minutes, 60 days);
        vm.warp(block.timestamp + dt);
        for (uint256 i; i < 3; ++i) {
            feeds[i].poke();
        }
        wethSecondary.poke();
        calls["warp"]++;
        _checkIndexes();
    }

    // ================================================================== seeding

    /// @notice Give every actor liquidity in every market and open leveraged positions for three of
    ///         them, so the campaign starts from a live market instead of an empty one.
    function seedMarkets() external {
        uint256[3] memory amounts = [uint256(50e18), 2e8, 200_000e6];
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 a; a < 3; ++a) {
                deal(address(tokens[a]), actors[i], amounts[a]);
                vm.startPrank(actors[i]);
                tokens[a].approve(address(pool), amounts[a]);
                pool.supply(address(tokens[a]), amounts[a], actors[i]);
                vm.stopPrank();
            }
        }
        // actors 0..2 borrow ~90% of capacity in USDC, WETH and WBTC respectively
        for (uint256 i; i < 3; ++i) {
            address asset = address(tokens[(i + 2) % 3]);
            uint256 maxBorrow = lens.getMaxBorrow(actors[i], asset);
            vm.prank(actors[i]);
            pool.borrow(asset, maxBorrow * 9 / 10);
        }
    }

    // ================================================================== helpers

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _hf(address user) internal view returns (uint256) {
        try pool.getUserAccountData(user) returns (DataTypes.AccountData memory d) {
            return d.healthFactor;
        } catch {
            return type(uint256).max; // unpriceable: not asserted on (handler keeps oracles healthy)
        }
    }

    function _healthFactors() internal view returns (uint256[] memory hfs) {
        hfs = new uint256[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            hfs[i] = _hf(actors[i]);
        }
    }

    function _surpluses() internal view returns (int256[3] memory s) {
        for (uint256 i; i < 3; ++i) {
            address asset = address(tokens[i]);
            DataTypes.ReserveData memory r = pool.getReserveData(asset);
            s[i] = int256(uint256(r.cash) + pool.totalBorrowed(asset) + r.deficit)
                - int256(pool.totalSupplied(asset));
        }
    }

    function _deficits() internal view returns (uint256[3] memory out) {
        for (uint256 i; i < 3; ++i) {
            out[i] = pool.getReserveData(address(tokens[i])).deficit;
        }
    }

    function _checkIndexes() internal {
        for (uint256 i; i < 3; ++i) {
            address asset = address(tokens[i]);
            uint256 li = pool.getReserveNormalizedIncome(asset);
            uint256 bi = pool.getReserveNormalizedDebt(asset);
            if (li < lastLiquidityIndex[i] || bi < lastBorrowIndex[i]) ghost_indexDecreases++;
            lastLiquidityIndex[i] = li;
            lastBorrowIndex[i] = bi;
        }
    }
}
