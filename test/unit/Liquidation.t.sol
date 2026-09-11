// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILendingPool} from "../../contracts/interfaces/ILendingPool.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {LiquidationLogic} from "../../contracts/logic/LiquidationLogic.sol";
import {PoolLens} from "../../contracts/periphery/PoolLens.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice The brief's scenario and every liquidation edge case in docs/liquidations.md.
///         Bob: 10 WETH collateral ($25,000 at $2,500), 15,000 USDC debt, HF 1.375.
contract LiquidationTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _openBobPosition();
    }

    // ================================================================== the brief's scenario

    /// @dev ETH $2,500 -> $1,800: HF = 18,000 * 0.825 / 15,000 = 0.99. Close factor 50%.
    ///      Liquidator repays 7,500 USDC and receives 7,500 * 1.05 / 1,800 = 4.375 WETH.
    function test_scenario_partialLiquidationRestoresSolvency() public {
        _setWethPrice(1800e8);
        assertEq(_hf(bob), 0.99e18);

        (uint256 repaid, uint256 seized) = _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);

        assertEq(repaid, 7500e6, "close factor caps repayment at 50%");
        assertEq(seized, 4.375e18, "debt value + 5% bonus in collateral");
        assertEq(weth.balanceOf(liquidator), 4.375e18);
        assertEq(pool.supplyBalanceOf(address(weth), bob), 5.625e18);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 7500e6);

        // 5.625 * 1,800 * 0.825 / 7,500 = 1.11375: the account is healthy again
        assertEq(_hf(bob), 1.11375e18);
        // liquidator's gross profit: 4.375 * 1,800 - 7,500 = $375 (the 5% bonus on repaid value)
        assertEq(weth.balanceOf(liquidator) * 1800 / 1e18 - 7500, 375);
    }

    function test_liquidation_emitsEvent() public {
        _setWethPrice(1800e8);
        deal(address(usdc), liquidator, 7500e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 7500e6);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ILendingPool.LiquidationCall(
            address(weth), address(usdc), bob, liquidator, 7500e6, 4.375e18, false
        );
        pool.liquidate(address(weth), address(usdc), bob, 7500e6, false);
        vm.stopPrank();
    }

    function test_revert_liquidateHealthyPosition() public {
        _setWethPrice(2000e8); // HF = 20,000 * .825 / 15,000 = 1.1
        deal(address(usdc), liquidator, 1000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(Errors.HealthyPosition.selector);
        pool.liquidate(address(weth), address(usdc), bob, 1000e6, false);
        vm.stopPrank();
    }

    /// @dev HF of exactly 1.0 is not liquidatable: the boundary is strict.
    function test_revert_liquidateAtExactlyHealthFactorOne() public {
        // HF = 10 * P * 0.825 / 15,000 = 1  =>  P = 1818.1818...: pick a clean case instead
        _supply(carol, weth, 10e18);
        _borrow(carol, usdc, 16_500e6); // 25,000*0.825 = 20,625 = 1.25x
        _setWethPrice(2000e8); // 20,000 * 0.825 = 16,500 -> HF exactly 1.0
        assertEq(_hf(carol), 1e18);
        deal(address(usdc), liquidator, 1000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(Errors.HealthyPosition.selector);
        pool.liquidate(address(weth), address(usdc), carol, 1000e6, false);
        vm.stopPrank();
    }

    // ================================================================== close factor

    function test_closeFactor_isHundredPercentBelowHf095() public {
        _setWethPrice(1650e8); // HF = 16,500 * .825 / 15,000 = 0.9075
        (uint256 repaid, uint256 seized) = _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);
        assertEq(repaid, 15_000e6);
        assertApproxEqAbs(seized, 9.545454545454545454e18, 1); // 15,000 * 1.05 / 1,650
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
        assertEq(pool.getUserConfiguration(bob) & 0x5555, 0);
    }

    function test_closeFactor_isHundredPercentForSmallPositions() public {
        _supply(carol, weth, 1e18); // $2,500
        _borrow(carol, usdc, 1500e6);
        _setWethPrice(1800e8); // HF = 1,800 * .825 / 1,500 = 0.99 (above 0.95) but debt < $2,000
        (uint256 repaid,) = _liquidate(liquidator, weth, usdc, carol, type(uint128).max, false);
        assertEq(repaid, 1500e6);
    }

    function test_liquidatorMayRepayLessThanMax() public {
        _setWethPrice(1800e8);
        (uint256 repaid, uint256 seized) = _liquidate(liquidator, weth, usdc, bob, 3000e6, false);
        assertEq(repaid, 3000e6);
        assertEq(seized, 1.75e18);
    }

    // ================================================================== dust rule

    /// @dev A partial liquidation whose leftovers stay above $1,000 on both legs is allowed.
    function test_partialLiquidation_allowedWhenLeftoversAboveMinimum() public {
        _supply(carol, weth, 2e18); // $5,000
        _borrow(carol, usdc, 2200e6); // HF = 5,000*.825/2,200 = 1.875
        _setWethPrice(1300e8); // HF = 2,600*.825/2,200 = 0.975: 50% CF? debt $2,200 >= $2,000 and coll $2,600
        // max 50% = 1,100: leftover $1,100 >= $1,000 fine. Repaying 1,500 is capped to 1,100.
        // Repay 1,050 instead: leftover debt 1,150 OK, leftover collateral 2,600 - 1,102.5 = 1,497.5 OK
        _liquidate(liquidator, weth, usdc, carol, 1050e6, false);
        // Now carol: debt 1,150, HF still < 1? 1,497.5 * .825 / 1,150 = 1.074 -> healthy again.
        assertGt(_hf(carol), 1e18);
    }

    function test_revert_dustRule() public {
        _supply(carol, weth, 1.5e18); // $3,750
        _borrow(carol, usdc, 2500e6);
        _setWethPrice(1900e8); // coll $2,850, HF = 2,850*.825/2,500 = 0.9405 -> CF 100%
        // repaying 1,700 leaves $800 of debt: dust
        deal(address(usdc), liquidator, 1700e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1700e6);
        vm.expectRevert(Errors.MustNotLeaveDust.selector);
        pool.liquidate(address(weth), address(usdc), carol, 1700e6, false);
        vm.stopPrank();
        // closing the full position is always allowed
        (uint256 repaid,) = _liquidate(liquidator, weth, usdc, carol, type(uint128).max, false);
        assertEq(repaid, 2500e6);
    }

    // ================================================================== collateral-limited

    /// @dev Collateral worth less than debt x (1 + bonus): seize all of it and repay only what it
    ///      covers. The remainder is bad debt (see BadDebt.t.sol).
    function test_collateralCapped_repaysOnlyWhatCollateralCovers() public {
        _setWethPrice(1400e8); // coll $14,000 < debt $15,000
        (uint256 repaid, uint256 seized) = _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);
        assertEq(seized, 10e18);
        // 10 * 1,400 / 1.05 = 13,333.333334 (rounded up against the liquidator)
        assertEq(repaid, 13_333_333_334);
    }

    // ================================================================== receiveSupply

    function test_receiveSupply_creditsPositionInsteadOfUnderlying() public {
        _setWethPrice(1800e8);
        (, uint256 seized) = _liquidate(liquidator, weth, usdc, bob, 7500e6, true);
        assertEq(weth.balanceOf(liquidator), 0);
        assertEq(pool.supplyBalanceOf(address(weth), liquidator), seized);
        assertTrue(pool.isUsingAsCollateral(address(weth), liquidator));
        // total supply unchanged: the position moved, nothing was withdrawn
        assertEq(pool.totalSupplied(address(weth)), 10e18);
    }

    /// @dev When the collateral reserve is 100% utilized there is no cash to pay the liquidator.
    ///      receiveSupply keeps liquidations possible exactly when they matter most.
    function test_receiveSupply_worksWhenCollateralReserveIsIlliquid() public {
        // carol borrows all the WETH liquidity (bob's 10 WETH is the only WETH supplied)
        _supply(carol, usdc, 1_000_000e6);
        _borrow(carol, weth, 10e18);
        assertEq(_reserve(weth).cash, 0);

        _setWethPrice(1800e8);
        deal(address(usdc), liquidator, 7500e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 7500e6);
        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        pool.liquidate(address(weth), address(usdc), bob, 7500e6, false);
        (uint256 repaid,) = pool.liquidate(address(weth), address(usdc), bob, 7500e6, true);
        vm.stopPrank();
        assertEq(repaid, 7500e6);
    }

    // ================================================================== same asset & self

    function test_sameAssetLiquidation() public {
        _supply(carol, weth, 10e18);
        _supply(carol, usdc, 5000e6); // USDC collateral too
        _borrow(carol, usdc, 22_000e6); // capacity 20,000 + 3,850
        _setWethPrice(1700e8); // coll: 17,000*.825 + 5,000*.8 = 18,025 vs 22,000 -> HF 0.819
        uint256 cashBefore = _reserve(usdc).cash;
        (uint256 repaid, uint256 seized) = _liquidate(liquidator, usdc, usdc, carol, 2000e6, false);
        assertEq(repaid, 2000e6);
        assertEq(seized, 2090e6); // + 4.5% USDC bonus
        assertEq(_reserve(usdc).cash, cashBefore + 2000e6 - 2090e6);
    }

    function test_selfLiquidation_isNeutral() public {
        _setWethPrice(1800e8);
        uint256 wethBefore = pool.supplyBalanceOf(address(weth), bob);
        (uint256 repaid, uint256 seized) = _liquidate(bob, weth, usdc, bob, 7500e6, true);
        // bob paid 7,500 USDC and his own position kept the seized collateral
        assertEq(pool.supplyBalanceOf(address(weth), bob), wethBefore);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 15_000e6 - repaid);
        assertGt(seized, 0);
    }

    // ================================================================== interest-driven

    /// @dev No price change at all: accrued interest alone pushes HF below 1.
    function test_interestAloneCanMakePositionLiquidatable() public {
        _supply(carol, weth, 10e18);
        _borrow(carol, usdc, 20_000e6); // HF 1.03125
        // drive USDC utilization near 100% so the rate is ~66%
        _supply(bob, wbtc, 100e8);
        _borrow(bob, usdc, 64_000e6);
        uint256 hf0 = _hf(carol);
        _warpAndRefresh(30 days);
        assertLt(_hf(carol), hf0);
        assertLt(_hf(carol), 1e18);
        (uint256 repaid,) = _liquidate(liquidator, weth, usdc, carol, type(uint128).max, false);
        assertGt(repaid, 0);
    }

    // ================================================================== guards

    function test_revert_collateralNotEnabledByBorrower() public {
        _setWethPrice(1800e8);
        deal(address(usdc), liquidator, 1000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(Errors.CollateralNotEnabledByUser.selector);
        pool.liquidate(address(wbtc), address(usdc), bob, 1000e6, false);
        vm.stopPrank();
    }

    function test_revert_noDebtInReserve() public {
        _setWethPrice(1800e8);
        deal(address(wbtc), liquidator, 1e8);
        vm.startPrank(liquidator);
        wbtc.approve(address(pool), 1e8);
        vm.expectRevert(Errors.NoDebt.selector);
        pool.liquidate(address(weth), address(wbtc), bob, 1e8, false);
        vm.stopPrank();
    }

    function test_revert_zeroDebtToCover() public {
        vm.prank(liquidator);
        vm.expectRevert(Errors.ZeroAmount.selector);
        pool.liquidate(address(weth), address(usdc), bob, 0, false);
    }

    /// @dev Never liquidate on a price the protocol cannot trust.
    function test_revert_liquidationWhenOracleDeviates() public {
        vm.startPrank(admin);
        wethFeed.setAnswer(1800e8);
        wethFeed2.setAnswer(2500e18); // sources disagree by 39%
        vm.stopPrank();
        deal(address(usdc), liquidator, 1000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OraclePriceDeviation.selector, address(weth), 1800e18, 2500e18)
        );
        pool.liquidate(address(weth), address(usdc), bob, 1000e6, false);
        vm.stopPrank();
    }

    function test_liquidationAllowedOnFrozenReserves() public {
        _setWethPrice(1800e8);
        vm.startPrank(guardian);
        configurator.setReserveFrozen(address(weth), true);
        configurator.setReserveFrozen(address(usdc), true);
        vm.stopPrank();
        (uint256 repaid,) = _liquidate(liquidator, weth, usdc, bob, 1000e6, false);
        assertEq(repaid, 1000e6);
    }

    // ================================================================== preview parity & HF improvement

    function test_lensPreviewMatchesExecution() public {
        _setWethPrice(1750e8);
        PoolLens.LiquidationPreview memory p =
            lens.previewLiquidation(bob, address(weth), address(usdc), type(uint128).max);
        assertTrue(p.liquidatable);
        (uint256 repaid, uint256 seized) = _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);
        assertEq(p.debtRepaid, repaid);
        assertEq(p.collateralSeized, seized);
    }

    function test_lensPreviewReportsDust() public {
        _supply(carol, weth, 1.5e18);
        _borrow(carol, usdc, 2500e6);
        _setWethPrice(1900e8);
        PoolLens.LiquidationPreview memory p =
            lens.previewLiquidation(carol, address(weth), address(usdc), 1700e6);
        assertFalse(p.liquidatable);
        assertEq(uint8(p.status), uint8(LiquidationLogic.AmountsStatus.LEAVES_DUST));
    }

    /// @dev While collateral/debt > 1 + bonus, every liquidation strictly improves the health
    ///      factor; this is what the configurator's LT * (1 + bonus) < 1 rule guarantees exists.
    function testFuzz_liquidationImprovesHealthWhileCollateralized(uint256 price, uint256 amount) public {
        // HF < 1 needs P < 1,818.18; C/D > 1.05 needs P > 1,575
        price = bound(price, 1576, 1818);
        _setWethPrice(price * 1e8);
        uint256 hfBefore = _hf(bob);
        amount = bound(amount, 1000e6, 15_000e6);
        try this.liquidateExternal(amount) {
            if (pool.debtBalanceOf(address(usdc), bob) > 0) assertGt(_hf(bob), hfBefore);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), Errors.MustNotLeaveDust.selector);
        }
    }

    function liquidateExternal(uint256 amount) external {
        _liquidate(liquidator, weth, usdc, bob, amount, false);
    }

    /// @dev A liquidation never leaves the borrower owing more debt value than before, and the
    ///      liquidator never receives more than repaid value x (1 + bonus).
    function testFuzz_liquidationBoundsBonus(uint256 price, uint256 amount) public {
        price = bound(price, 1000, 1818);
        _setWethPrice(price * 1e8);
        amount = bound(amount, 1e6, 20_000e6);
        try this.liquidateExternalReturning(amount) returns (uint256 repaid, uint256 seized) {
            uint256 seizedValue = seized * price / 1e12; // 6-dec USD, like `repaid`
            assertLe(seizedValue, repaid * 10_500 / 10_000 + 1);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), Errors.MustNotLeaveDust.selector);
        }
    }

    function liquidateExternalReturning(uint256 amount) external returns (uint256, uint256) {
        return _liquidate(liquidator, weth, usdc, bob, amount, false);
    }
}
