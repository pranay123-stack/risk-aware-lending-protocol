// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILendingPool} from "../../contracts/interfaces/ILendingPool.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice Bad debt: collateral value < debt value. See docs/liquidations.md#bad-debt.
contract BadDebtTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _openBobPosition(); // 10 WETH vs 15,000 USDC
    }

    function _assertSolvencyWithDeficit(address asset) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 assets = uint256(r.cash) + pool.totalBorrowed(asset) + r.deficit;
        assertGe(assets + 2, pool.totalSupplied(asset), "cash + debt + deficit >= liabilities");
    }

    /// @dev ETH gaps down to $1,400: collateral $14,000 < debt $15,000. The liquidator can only
    ///      recover 13,333.33 against the whole 10 WETH, and the remaining 1,666.67 is written off.
    function test_badDebt_recognizedWhenCollateralExhausted() public {
        _setWethPrice(1400e8);
        deal(address(usdc), liquidator, 15_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), 15_000e6);
        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.BadDebtRecognized(address(usdc), bob, 1_666_666_666, 0, 1_666_666_666);
        pool.liquidate(address(weth), address(usdc), bob, 15_000e6, false);
        vm.stopPrank();

        assertEq(pool.debtBalanceOf(address(usdc), bob), 0, "zombie debt removed");
        assertEq(pool.supplyBalanceOf(address(weth), bob), 0);
        assertEq(pool.getUserConfiguration(bob), 0, "account fully closed");
        assertEq(_reserve(usdc).deficit, 1_666_666_666);
        assertEq(_reserve(usdc).totalScaledDebt, 0);
        _assertSolvencyWithDeficit(address(usdc));
    }

    /// @dev Reserve-factor income is the first-loss buffer: it absorbs bad debt before any deficit.
    function test_badDebt_absorbedByTreasuryFirst() public {
        // Build a meaningful treasury: a large borrower at ~95% utilization for a year.
        _supply(carol, wbtc, 100e8);
        _borrow(carol, usdc, 80_000e6);
        _warpAndRefresh(365 days);
        _repay(carol, usdc, 1e6); // write the accrual
        uint256 treasury = pool.treasuryBalance(address(usdc));
        assertGt(treasury, 1000e6);

        // Price WETH so the 10 WETH cover all but ~$500 of bob's (interest-grown) debt.
        uint256 bobDebt = pool.debtBalanceOf(address(usdc), bob);
        _setWethPrice((bobDebt - 500e6) * 105 / 10);
        (uint256 repaid, uint256 seized) = _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);
        assertEq(seized, 10e18, "all collateral seized");

        uint256 loss = bobDebt - repaid;
        assertApproxEqAbs(loss, 500e6, 1e6);
        assertEq(_reserve(usdc).deficit, 0, "fully absorbed by reserves");
        assertApproxEqAbs(pool.treasuryBalance(address(usdc)), treasury - loss, 2);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
        _assertSolvencyWithDeficit(address(usdc));
    }

    /// @dev All remaining debts are written off, across every reserve the borrower owes.
    function test_badDebt_writtenOffAcrossAllDebtReserves() public {
        _supply(alice, wbtc, 10e8);
        _borrow(bob, wbtc, 0.05e8); // $3,000 more debt: bob now owes $18,000 against $25,000
        _setWethPrice(1400e8); // collateral $14,000

        _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);

        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
        assertEq(pool.debtBalanceOf(address(wbtc), bob), 0);
        assertGt(_reserve(usdc).deficit, 0);
        assertEq(_reserve(wbtc).deficit, 0.05e8, "whole WBTC debt was unbacked");
        assertEq(pool.getUserConfiguration(bob), 0);
        _assertSolvencyWithDeficit(address(usdc));
        _assertSolvencyWithDeficit(address(wbtc));
    }

    /// @dev Dust collateral elsewhere delays write-off. It is not an escape hatch: that dust
    ///      is itself liquidatable, and seizing it triggers the write-off.
    function test_dustCollateralDoesNotShieldBadDebtForever() public {
        _supply(bob, wbtc, 1000); // 0.00001 WBTC = $0.60
        _setWethPrice(1400e8);
        _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);
        assertGt(pool.debtBalanceOf(address(usdc), bob), 0, "not written off yet: WBTC dust remains");
        assertEq(_reserve(usdc).deficit, 0);

        _liquidate(liquidator, wbtc, usdc, bob, type(uint128).max, false);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
        assertGt(_reserve(usdc).deficit, 0);
        _assertSolvencyWithDeficit(address(usdc));
    }

    function test_coverDeficit_restoresFullBacking() public {
        _setWethPrice(1400e8);
        _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);
        uint256 deficit = _reserve(usdc).deficit;

        address insurer = makeAddr("insurer");
        deal(address(usdc), insurer, deficit * 2);
        vm.startPrank(insurer);
        usdc.approve(address(pool), deficit * 2);
        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.DeficitCovered(address(usdc), insurer, deficit);
        uint256 covered = pool.coverDeficit(address(usdc), deficit * 2); // capped at the deficit
        vm.stopPrank();

        assertEq(covered, deficit);
        assertEq(usdc.balanceOf(insurer), deficit);
        assertEq(_reserve(usdc).deficit, 0);
        // every supplier can now be paid in full
        DataTypes.ReserveData memory r = _reserve(usdc);
        assertGe(uint256(r.cash) + pool.totalBorrowed(address(usdc)), pool.totalSupplied(address(usdc)));
        assertEq(_withdraw(alice, usdc, type(uint256).max), 100_000e6);
    }

    function test_revert_coverDeficitWhenNone() public {
        vm.expectRevert(Errors.NoDeficit.selector);
        pool.coverDeficit(address(usdc), 1);
    }

    /// @dev Why a deficit must be covered promptly: without recapitalisation the last suppliers out
    ///      bear the loss (bank-run dynamics). The first withdrawers are paid in full.
    function test_uncoveredDeficit_isBorneByLastWithdrawer() public {
        _setWethPrice(1400e8);
        _liquidate(liquidator, weth, usdc, bob, type(uint128).max, false);
        uint256 deficit = _reserve(usdc).deficit;
        // alice is the only supplier: her claim is 100,000 but only 100,000 - deficit exists
        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        pool.withdraw(address(usdc), type(uint256).max, alice);
        assertEq(_withdraw(alice, usdc, 100_000e6 - deficit), 100_000e6 - deficit);
    }
}
