// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILendingPool} from "../../contracts/interfaces/ILendingPool.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

contract BorrowRepayTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _supply(alice, usdc, 1_000_000e6);
        _supply(alice, weth, 1000e18);
    }

    // ================================================================== borrow

    function test_borrow_transfersAndRecordsDebt() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 15_000e6);
        assertEq(usdc.balanceOf(bob), 15_000e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 15_000e6);
        assertEq(pool.totalBorrowed(address(usdc)), 15_000e6);
        assertEq(_reserve(usdc).cash, 1_000_000e6 - 15_000e6);

        DataTypes.AccountData memory d = pool.getUserAccountData(bob);
        assertEq(d.totalCollateralValue, 25_000e18);
        assertEq(d.totalDebtValue, 15_000e18);
        assertEq(d.borrowCapacityValue, 20_000e18);
        assertEq(d.healthFactor, 1.375e18); // 25,000 * 0.825 / 15,000
    }

    function test_borrow_emitsEventWithRate() public {
        _supply(bob, weth, 10e18);
        vm.expectEmit(true, true, false, false, address(pool));
        emit ILendingPool.Borrow(address(usdc), bob, 15_000e6, 0);
        _borrow(bob, usdc, 15_000e6);
    }

    /// @dev Exactly at the LTV boundary succeeds; one more unit of debt fails.
    function test_borrow_ltvBoundaryIsExact() public {
        _supply(bob, weth, 10e18); // capacity exactly $20,000
        _borrow(bob, usdc, 20_000e6);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.borrow(address(usdc), 1);
    }

    /// @dev Because LTV < LT, a max borrow leaves HF = LT / LTV > 1. A fresh borrow is never
    ///      immediately liquidatable.
    function test_maxBorrow_leavesHealthFactorAboveOne() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 20_000e6);
        assertEq(_hf(bob), 1.03125e18); // 0.825 / 0.8
    }

    function test_revert_borrowWithoutCollateral() public {
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.borrow(address(usdc), 1);
    }

    function test_revert_borrowAgainstDisabledCollateral() public {
        _supply(bob, weth, 10e18);
        vm.prank(bob);
        pool.setUseReserveAsCollateral(address(weth), false);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.borrow(address(usdc), 1e6);
    }

    function test_borrow_multiCollateralCapacityAdds() public {
        _supply(bob, weth, 10e18); // 25k * 0.80 = 20,000
        _supply(bob, wbtc, 1e8); //   60k * 0.73 = 43,800
        _borrow(bob, usdc, 63_800e6);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.borrow(address(usdc), 1);
    }

    function test_borrow_multipleDebtAssets() public {
        _supply(alice, wbtc, 100e8);
        _supply(bob, weth, 100e18); // capacity $200k
        _borrow(bob, usdc, 100_000e6);
        _borrow(bob, wbtc, 1e8); // $60k
        DataTypes.AccountData memory d = pool.getUserAccountData(bob);
        assertEq(d.totalDebtValue, 160_000e18);
    }

    function test_revert_borrowInsufficientLiquidity() public {
        _supply(bob, weth, 1000e18);
        _supply(carol, wbtc, 100e8); // collateral for carol
        // WBTC cash is exactly carol's 100 WBTC; bob has ample capacity but the pool has no more.
        vm.prank(bob);
        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        pool.borrow(address(wbtc), 100e8 + 1);
    }

    function test_revert_borrowCapExceeded() public {
        vm.prank(admin);
        configurator.setCaps(address(usdc), 0, 10_000);
        _supply(bob, weth, 10e18);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapExceeded.selector);
        pool.borrow(address(usdc), 10_000e6 + 1);
        _borrow(bob, usdc, 10_000e6);
    }

    function test_revert_borrowWhenDisabled() public {
        vm.prank(admin);
        configurator.setBorrowingEnabled(address(usdc), false);
        _supply(bob, weth, 10e18);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowingNotEnabled.selector);
        pool.borrow(address(usdc), 1e6);
    }

    function test_revert_borrowWhenFrozen() public {
        _supply(bob, weth, 10e18);
        vm.prank(guardian);
        configurator.setReserveFrozen(address(usdc), true);
        vm.prank(bob);
        vm.expectRevert(Errors.ReserveFrozen.selector);
        pool.borrow(address(usdc), 1e6);
    }

    function test_revert_borrowZero() public {
        vm.prank(bob);
        vm.expectRevert(Errors.ZeroAmount.selector);
        pool.borrow(address(usdc), 0);
    }

    /// @dev Borrowing needs every exposed price. A broken collateral oracle fails closed.
    function test_revert_borrowWhenCollateralOracleDown() public {
        _supply(bob, weth, 10e18);
        vm.startPrank(admin);
        wethFeed.setReverting(true);
        wethFeed2.setReverting(true);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, address(weth)));
        pool.borrow(address(usdc), 1e6);
    }

    /// @dev Market isolation: an outage on WBTC does not affect accounts without WBTC exposure.
    function test_oracleOutage_isolatedToExposedAccounts() public {
        _supply(bob, weth, 10e18);
        vm.prank(admin);
        wbtcFeed.setReverting(true);
        _borrow(bob, usdc, 1000e6); // bob never touched WBTC: unaffected
        assertEq(pool.debtBalanceOf(address(usdc), bob), 1000e6);
    }

    // ================================================================== repay

    function test_repay_partial() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 15_000e6);
        uint256 paid = _repay(bob, usdc, 5000e6);
        assertEq(paid, 5000e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 10_000e6);
    }

    function test_repay_fullWithMaxClearsBorrowingBit() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 15_000e6);
        _warpAndRefresh(30 days);
        uint256 owed = pool.debtBalanceOf(address(usdc), bob);
        assertGt(owed, 15_000e6);

        deal(address(usdc), bob, owed);
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        uint256 paid = pool.repay(address(usdc), type(uint256).max, bob);
        vm.stopPrank();

        assertEq(paid, owed);
        assertEq(usdc.balanceOf(bob), 0); // charged exactly the debt, not the max
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
        assertEq(pool.getUserConfiguration(bob) & 0x5555, 0); // no borrowing bits
        assertEq(_reserve(usdc).totalScaledDebt, 0);
    }

    function test_repay_overpaymentOnlyChargesDebt() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 1000e6);
        deal(address(usdc), bob, 5000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 5000e6);
        uint256 paid = pool.repay(address(usdc), 5000e6, bob);
        vm.stopPrank();
        assertEq(paid, 1000e6);
        assertEq(usdc.balanceOf(bob), 4000e6);
    }

    function test_repay_onBehalfOfAnotherUser() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 1000e6);
        deal(address(usdc), carol, 1000e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 1000e6);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ILendingPool.Repay(address(usdc), bob, carol, 1000e6);
        pool.repay(address(usdc), 1000e6, bob);
        vm.stopPrank();
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
    }

    /// @dev Repay is never blocked by pause: it only lowers risk.
    function test_repay_worksWhilePoolAndReservePaused() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 1000e6);
        vm.startPrank(guardian);
        configurator.setPoolPaused(true);
        configurator.setReservePaused(address(usdc), true);
        vm.stopPrank();
        _repay(bob, usdc, 1000e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
    }

    function test_repay_worksDuringOracleOutage() public {
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 1000e6);
        vm.startPrank(admin);
        wethFeed.setReverting(true);
        usdcFeed.setReverting(true);
        vm.stopPrank();
        _repay(bob, usdc, 400e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 600e6);
    }

    function test_revert_repayWithoutDebt() public {
        deal(address(usdc), bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 1e6);
        vm.expectRevert(Errors.NoDebt.selector);
        pool.repay(address(usdc), 1e6, bob);
        vm.stopPrank();
    }

    /// @dev Debt can never go negative: the debt balance is floored at zero and the surplus stays
    ///      with the payer (checked above). Scaled debt is unsigned and burn <= balance.
    function testFuzz_repayNeverCreatesNegativeDebt(uint96 borrowAmt, uint96 repayAmt, uint32 dt) public {
        borrowAmt = uint96(bound(borrowAmt, 1e6, 20_000e6));
        repayAmt = uint96(bound(repayAmt, 1, type(uint96).max));
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, borrowAmt);
        _warpAndRefresh(bound(dt, 0, 365 days));

        uint256 before = pool.debtBalanceOf(address(usdc), bob);
        deal(address(usdc), bob, repayAmt);
        vm.startPrank(bob);
        usdc.approve(address(pool), repayAmt);
        try pool.repay(address(usdc), repayAmt, bob) returns (uint256 paid) {
            uint256 afterDebt = pool.debtBalanceOf(address(usdc), bob);
            assertLe(paid, before); //                 never charged more than owed
            assertGe(afterDebt + paid, before); //     rounding never forgives debt
            assertLe(afterDebt, before - paid + 2); // ...and never adds more than index rounding
            if (paid == before) assertEq(afterDebt, 0);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), Errors.AmountTooSmall.selector); // only dust repays can fail
        }
        vm.stopPrank();
    }
}
