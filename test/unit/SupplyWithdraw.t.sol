// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILendingPool} from "../../contracts/interfaces/ILendingPool.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

contract SupplyWithdrawTest is BaseTest {
    // ================================================================== supply

    function test_supply_movesFundsAndCreditsBalance() public {
        _supply(alice, usdc, 1000e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
        assertEq(pool.supplyBalanceOf(address(usdc), alice), 1000e6);
        assertEq(pool.totalSupplied(address(usdc)), 1000e6);
        DataTypes.ReserveData memory r = _reserve(usdc);
        assertEq(r.cash, 1000e6);
        assertEq(r.totalScaledSupply, 1000e6); // index is still exactly 1 ray
    }

    function test_supply_emitsEvents() public {
        deal(address(usdc), alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.ReserveUsedAsCollateral(address(usdc), alice, true);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ILendingPool.Supply(address(usdc), alice, alice, 1000e6);
        pool.supply(address(usdc), 1000e6, alice);
        vm.stopPrank();
    }

    function test_supply_autoEnablesCollateralOnFirstOwnSupply() public {
        _supply(alice, weth, 1e18);
        assertTrue(pool.isUsingAsCollateral(address(weth), alice));
    }

    /// @dev Griefing defence: nobody can add oracle exposure to someone else's account.
    function test_supplyOnBehalf_doesNotEnableCollateralForBeneficiary() public {
        deal(address(wbtc), carol, 1e8);
        vm.startPrank(carol);
        wbtc.approve(address(pool), 1e8);
        pool.supply(address(wbtc), 1e8, alice);
        vm.stopPrank();

        assertEq(pool.supplyBalanceOf(address(wbtc), alice), 1e8);
        assertFalse(pool.isUsingAsCollateral(address(wbtc), alice));
        assertEq(pool.getUserConfiguration(alice), 0);
    }

    function test_supply_respectsUserChoiceAfterDisablingCollateral() public {
        _supply(alice, weth, 1e18);
        vm.prank(alice);
        pool.setUseReserveAsCollateral(address(weth), false);
        _supply(alice, weth, 1e18); // not the first supply: stays disabled
        assertFalse(pool.isUsingAsCollateral(address(weth), alice));
    }

    function test_revert_supplyZero() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        pool.supply(address(usdc), 0, alice);
    }

    function test_revert_supplyUnlistedAsset() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ReserveNotActive.selector);
        pool.supply(makeAddr("random"), 1, alice);
    }

    function test_revert_supplyToZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        pool.supply(address(usdc), 1, address(0));
    }

    function test_revert_supplyWhenFrozen() public {
        vm.prank(guardian);
        configurator.setReserveFrozen(address(usdc), true);
        deal(address(usdc), alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(Errors.ReserveFrozen.selector);
        pool.supply(address(usdc), 1e6, alice);
    }

    function test_revert_supplyWhenReservePaused() public {
        vm.prank(guardian);
        configurator.setReservePaused(address(usdc), true);
        vm.prank(alice);
        vm.expectRevert(Errors.ReservePaused.selector);
        pool.supply(address(usdc), 1e6, alice);
    }

    function test_revert_supplyWhenPoolPaused() public {
        vm.prank(guardian);
        configurator.setPoolPaused(true);
        vm.prank(alice);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.supply(address(usdc), 1e6, alice);
    }

    function test_revert_supplyCapExceeded() public {
        vm.prank(admin);
        configurator.setCaps(address(wbtc), 10, 5);
        _supply(alice, wbtc, 10e8); // exactly at the cap
        deal(address(wbtc), bob, 1);
        vm.startPrank(bob);
        wbtc.approve(address(pool), 1);
        vm.expectRevert(Errors.SupplyCapExceeded.selector);
        pool.supply(address(wbtc), 1, bob);
        vm.stopPrank();
    }

    /// @dev Once the index exceeds 1, a 1-wei deposit would mint zero scaled units: refuse it
    ///      instead of silently taking the user's funds.
    function test_revert_supplyRoundingToZeroShares() public {
        _openBobPosition();
        _warpAndRefresh(365 days);
        _supply(carol, usdc, 1e6); // accrues: index > 1 now
        deal(address(usdc), carol, 1);
        vm.startPrank(carol);
        usdc.approve(address(pool), 1);
        vm.expectRevert(Errors.AmountTooSmall.selector);
        pool.supply(address(usdc), 1, carol);
        vm.stopPrank();
    }

    // ================================================================== withdraw

    function test_withdraw_partialAndMax() public {
        _supply(alice, usdc, 1000e6);
        assertEq(_withdraw(alice, usdc, 400e6), 400e6);
        assertEq(pool.supplyBalanceOf(address(usdc), alice), 600e6);
        assertTrue(pool.isUsingAsCollateral(address(usdc), alice));

        assertEq(_withdraw(alice, usdc, type(uint256).max), 600e6);
        assertEq(pool.supplyBalanceOf(address(usdc), alice), 0);
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertFalse(pool.isUsingAsCollateral(address(usdc), alice)); // bit cleared at zero
        assertEq(_reserve(usdc).totalScaledSupply, 0);
    }

    function test_withdraw_toAnotherAddress() public {
        _supply(alice, usdc, 1000e6);
        vm.prank(alice);
        pool.withdraw(address(usdc), 1000e6, carol);
        assertEq(usdc.balanceOf(carol), 1000e6);
    }

    function test_revert_withdrawMoreThanBalance() public {
        _supply(alice, usdc, 1000e6);
        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        pool.withdraw(address(usdc), 1000e6 + 1, alice);
    }

    function test_revert_withdrawWithNoSupply() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NoSupply.selector);
        pool.withdraw(address(usdc), type(uint256).max, alice);
    }

    /// @dev Liquidity constraint: suppliers cannot withdraw cash that is lent out.
    function test_revert_withdrawBeyondAvailableLiquidity() public {
        _openBobPosition(); // alice 100k USDC supplied, bob borrowed 15k
        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        pool.withdraw(address(usdc), 85_000e6 + 1, alice);
        // exactly the available cash works
        assertEq(_withdraw(alice, usdc, 85_000e6), 85_000e6);
        assertEq(_reserve(usdc).cash, 0);
    }

    function test_revert_withdrawCollateralBreakingBorrowCapacity() public {
        _openBobPosition(); // 10 WETH ($25k, capacity $20k), 15k debt
        // Capacity after withdrawing X WETH: (10 - X) * 2500 * 0.8 >= 15000  =>  X <= 2.5
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.withdraw(address(weth), 2.5e18 + 1e12, bob);
        _withdraw(bob, weth, 2.49e18);
    }

    function test_withdraw_nonCollateralWhileIndebted() public {
        _openBobPosition();
        _supply(bob, wbtc, 1e8);
        vm.prank(bob);
        pool.setUseReserveAsCollateral(address(wbtc), false);
        // Not collateral, so it never affects the health factor: always withdrawable
        assertEq(_withdraw(bob, wbtc, type(uint256).max), 1e8);
    }

    function test_withdraw_allowedWhenFrozen() public {
        _supply(alice, usdc, 1000e6);
        vm.prank(guardian);
        configurator.setReserveFrozen(address(usdc), true);
        assertEq(_withdraw(alice, usdc, type(uint256).max), 1000e6);
    }

    function test_revert_withdrawWhenPaused() public {
        _supply(alice, usdc, 1000e6);
        vm.prank(guardian);
        configurator.setPoolPaused(true);
        vm.prank(alice);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.withdraw(address(usdc), 1, alice);
    }

    /// @dev Emergency property: lenders without debt never need a price, so an oracle outage on
    ///      their asset cannot trap their funds.
    function test_withdraw_debtFreeLenderUnaffectedByOracleOutage() public {
        _supply(alice, weth, 5e18);
        vm.startPrank(admin);
        wethFeed.setReverting(true);
        wethFeed2.setReverting(true);
        vm.stopPrank();
        assertEq(_withdraw(alice, weth, type(uint256).max), 5e18);
    }

    function test_revert_indebtedCollateralWithdrawDuringOracleOutage() public {
        _openBobPosition();
        vm.startPrank(admin);
        wethFeed.setReverting(true);
        wethFeed2.setReverting(true);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, address(weth)));
        pool.withdraw(address(weth), 1e18, bob);
    }

    // ================================================================== collateral toggle

    function test_disableCollateral_blockedWhenNeededForDebt() public {
        _openBobPosition();
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.setUseReserveAsCollateral(address(weth), false);
    }

    function test_disableCollateral_allowedWhenOtherCollateralCovers() public {
        _openBobPosition();
        _supply(bob, wbtc, 1e8); // $60k more collateral
        vm.prank(bob);
        pool.setUseReserveAsCollateral(address(weth), false);
        assertFalse(pool.isUsingAsCollateral(address(weth), bob));
    }

    function test_revert_enableCollateralWithoutSupply() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NoSupply.selector);
        pool.setUseReserveAsCollateral(address(weth), true);
    }

    function test_revert_enableCollateralOnNonCollateralReserve() public {
        _supply(alice, usdc, 1000e6);
        vm.prank(alice);
        pool.setUseReserveAsCollateral(address(usdc), false);
        vm.prank(admin);
        configurator.setCollateralEnabled(address(usdc), false);
        vm.prank(alice);
        vm.expectRevert(Errors.CollateralNotEnabledForReserve.selector);
        pool.setUseReserveAsCollateral(address(usdc), true);
    }

    function test_setCollateral_isIdempotent() public {
        _supply(alice, weth, 1e18);
        uint256 before = pool.getUserConfiguration(alice);
        vm.prank(alice);
        pool.setUseReserveAsCollateral(address(weth), true);
        assertEq(pool.getUserConfiguration(alice), before);
    }
}
