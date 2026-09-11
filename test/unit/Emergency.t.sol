// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../contracts/libraries/Errors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice The emergency action matrix documented in ValidationLogic and docs/security.md.
contract EmergencyTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _openBobPosition();
        _supply(carol, wbtc, 1e8);
        vm.prank(admin);
        configurator.setLiquidationGracePeriod(1 hours);
    }

    // ================================================================== global pause

    function test_poolPause_matrix() public {
        vm.prank(guardian);
        configurator.setPoolPaused(true);
        assertTrue(pool.paused());

        deal(address(usdc), alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.supply(address(usdc), 1e6, alice);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.withdraw(address(usdc), 1e6, alice);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.setUseReserveAsCollateral(address(usdc), false);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.borrow(address(usdc), 1e6);

        vm.prank(liquidator);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.liquidate(address(weth), address(usdc), bob, 1e6, false);

        // ...but repay always works
        _repay(bob, usdc, 1000e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 14_000e6);
    }

    /// @dev After an unpause, liquidations wait out the grace window: borrowers get time to repay
    ///      interest that accrued, or react to prices that moved, while they could not act.
    function test_unpause_opensLiquidationGracePeriod() public {
        vm.prank(guardian);
        configurator.setPoolPaused(true);
        _setWethPrice(1800e8); // bob becomes liquidatable during the pause
        vm.prank(guardian);
        configurator.setPoolPaused(false);
        assertEq(pool.liquidationGraceUntil(), block.timestamp + 1 hours);

        deal(address(usdc), liquidator, 1000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(Errors.LiquidationGracePeriod.selector);
        pool.liquidate(address(weth), address(usdc), bob, 1000e6, false);
        vm.stopPrank();

        _warpAndRefresh(1 hours);
        _setWethPrice(1800e8);
        (uint256 repaid,) = _liquidate(liquidator, weth, usdc, bob, 1000e6, false);
        assertEq(repaid, 1000e6);
    }

    // ================================================================== reserve pause (market isolation)

    /// @dev Pausing one market halts it without touching the others.
    function test_reservePause_isolatesOneMarket() public {
        vm.prank(guardian);
        configurator.setReservePaused(address(wbtc), true);

        vm.prank(carol);
        vm.expectRevert(Errors.ReservePaused.selector);
        pool.withdraw(address(wbtc), 1, carol);

        // other markets keep working
        _supply(alice, usdc, 1000e6);
        _borrow(bob, usdc, 100e6);
        _withdraw(alice, usdc, 500e6);
    }

    function test_reservePause_blocksLiquidationsTouchingIt() public {
        _setWethPrice(1800e8);
        vm.prank(guardian);
        configurator.setReservePaused(address(weth), true);
        deal(address(usdc), liquidator, 1000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(Errors.ReservePaused.selector);
        pool.liquidate(address(weth), address(usdc), bob, 1000e6, false);
        vm.stopPrank();
    }

    // ================================================================== freeze (wind-down)

    function test_freeze_allowsExitsButNoNewExposure() public {
        vm.prank(guardian);
        configurator.setReserveFrozen(address(usdc), true);

        vm.prank(bob);
        vm.expectRevert(Errors.ReserveFrozen.selector);
        pool.borrow(address(usdc), 1e6);

        _repay(bob, usdc, 5000e6); //                   repay works
        _withdraw(alice, usdc, 10_000e6); //             withdraw works
        vm.prank(alice);
        pool.setUseReserveAsCollateral(address(usdc), false); // disabling works
        vm.prank(alice);
        vm.expectRevert(Errors.ReserveFrozen.selector);
        pool.setUseReserveAsCollateral(address(usdc), true); // enabling does not
    }

    // ================================================================== oracle circuit breaker

    /// @dev Guardian pauses the WBTC oracle. Only accounts exposed to WBTC are affected.
    function test_oraclePause_isolatedToExposedAccounts() public {
        vm.prank(guardian);
        oracle.setAssetPaused(address(wbtc), true);

        // bob (WETH/USDC) is unaffected
        _borrow(bob, usdc, 100e6);

        // carol's WBTC collateral cannot back a borrow while its price is untrusted
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleAssetPaused.selector, address(wbtc)));
        pool.borrow(address(usdc), 1e6);

        // but carol has no debt, so she can still exit
        assertEq(_withdraw(carol, wbtc, type(uint256).max), 1e8);
    }

    function test_oraclePause_haltsLiquidationOfExposedAccounts() public {
        _setWethPrice(1800e8);
        vm.prank(guardian);
        oracle.setAssetPaused(address(weth), true);
        deal(address(usdc), liquidator, 1000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleAssetPaused.selector, address(weth)));
        pool.liquidate(address(weth), address(usdc), bob, 1000e6, false);
        vm.stopPrank();
    }
}
