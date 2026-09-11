// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleManager} from "../../contracts/interfaces/IOracleManager.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {PoolLens} from "../../contracts/periphery/PoolLens.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

contract PoolLensTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _openBobPosition();
    }

    function test_getMarkets() public view {
        PoolLens.MarketData[] memory m = lens.getMarkets();
        assertEq(m.length, 3);
        assertEq(m[0].symbol, "WETH");
        assertEq(m[1].symbol, "WBTC");
        assertEq(m[2].symbol, "USDC");

        PoolLens.MarketData memory u = m[2];
        assertEq(u.price, 1e18);
        assertEq(uint8(u.priceStatus), uint8(IOracleManager.PriceStatus.OK));
        assertEq(u.totalSupplied, 100_000e6);
        assertEq(u.totalBorrowed, 15_000e6);
        assertEq(u.cash, 85_000e6);
        assertEq(u.utilization, 0.15e27);
        assertEq(u.optimalUtilization, 0.9e27);
        assertEq(u.config.ltv, 7700);
        assertGt(u.borrowRate, 0);
        assertGt(u.liquidityRate, 0);
    }

    function test_market_reportsOracleProblemWithoutReverting() public {
        vm.prank(admin);
        wbtcFeed.setReverting(true);
        PoolLens.MarketData memory m = lens.getMarket(address(wbtc));
        assertEq(m.price, 0);
        assertEq(uint8(m.priceStatus), uint8(IOracleManager.PriceStatus.UNAVAILABLE));
    }

    function test_userPositions() public view {
        (PoolLens.UserReserveData[] memory p, PoolLens.AccountHealth memory h) = lens.getUserPositions(bob);
        assertTrue(h.ok);
        assertEq(h.healthFactor, 1.375e18);
        assertEq(p[0].supplyBalance, 10e18);
        assertTrue(p[0].collateralEnabled);
        assertEq(p[2].debtBalance, 15_000e6);
        assertEq(p[2].walletBalance, 15_000e6);
    }

    /// @dev "Max" suggestions must be executable: borrowing exactly maxBorrow succeeds and a
    ///      little more fails.
    function test_maxBorrowIsExecutable() public {
        uint256 maxBorrow = lens.getMaxBorrow(bob, address(usdc));
        assertApproxEqRel(maxBorrow, 5000e6, 2e12); // capacity 20,000 - debt 15,000, less 1 ppm
        _borrow(bob, usdc, maxBorrow);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.borrow(address(usdc), 1e6);
    }

    function test_maxBorrowInOtherAsset() public {
        _supply(alice, wbtc, 10e8);
        uint256 maxBorrow = lens.getMaxBorrow(bob, address(wbtc)); // $5,000 at $60,000
        assertApproxEqRel(maxBorrow, 0.08333333e8, 2e12); // 1 ppm haircut + sat rounding
        assertLt(maxBorrow, 0.08333333e8, "never suggests more than the exact capacity");
        _borrow(bob, wbtc, maxBorrow);
    }

    function test_maxWithdrawIsExecutable() public {
        uint256 maxW = lens.getMaxWithdraw(bob, address(weth));
        assertApproxEqRel(maxW, 2.5e18, 2e12); // (20,000 - 15,000) / (2,500 * 0.8), less 1 ppm
        _withdraw(bob, weth, maxW);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.withdraw(address(weth), 0.001e18, bob);
    }

    function test_maxWithdraw_debtFreeIsFullBalance() public view {
        assertEq(lens.getMaxWithdraw(alice, address(usdc)), 85_000e6); // capped by cash
    }

    /// @dev Regression (found writing docs/risk-model.md): with an exposed oracle down, the lens
    ///      reported an indebted account's collateral as withdrawable (the pool reverts), and a
    ///      debt-free account's as 0 (the pool allows it, since it reads no price).
    function test_maxWithdraw_matchesPoolDuringOracleOutage() public {
        _supply(carol, weth, 1e18); // debt-free, WETH enabled as collateral
        vm.prank(guardian);
        oracle.setAssetPaused(address(weth), true);

        assertEq(lens.getMaxWithdraw(bob, address(weth)), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleAssetPaused.selector, address(weth)));
        pool.withdraw(address(weth), 1, bob);

        (PoolLens.UserReserveData[] memory p, PoolLens.AccountHealth memory h) = lens.getUserPositions(carol);
        assertFalse(h.ok, "valuation needs the paused price");
        assertEq(p[0].maxWithdraw, 1e18);
        assertEq(lens.getMaxWithdraw(carol, address(weth)), 1e18);
        _withdraw(carol, weth, 1e18);
    }

    /// @dev LTV-0 collateral adds no borrowing capacity. Withdrawing it is allowed while the account
    ///      is within capacity, and blocked once it is over (here: governance lowered the WETH LTV).
    function test_maxWithdraw_ltvZeroCollateral() public {
        _supply(bob, wbtc, 0.1e8);
        vm.prank(admin);
        configurator.setRiskParameters(address(wbtc), 0, 7800, 650);
        assertEq(lens.getMaxWithdraw(bob, address(wbtc)), 0.1e8, "within capacity: fully withdrawable");

        vm.prank(admin);
        configurator.setRiskParameters(address(weth), 5000, 8250, 500); // capacity 12,500 < debt 15,000
        assertEq(lens.getMaxWithdraw(bob, address(wbtc)), 0);
        vm.prank(bob);
        vm.expectRevert(Errors.BorrowCapacityExceeded.selector);
        pool.withdraw(address(wbtc), 1, bob);
    }

    /// @dev The monitor's batch read survives a broken oracle: the exposed account is flagged,
    ///      everyone else is still reported.
    function test_accountsHealth_neverRevertsOnOneBadAccount() public {
        _supply(carol, wbtc, 1e8);
        _borrow(carol, usdc, 1000e6);
        vm.prank(admin);
        wbtcFeed.setReverting(true);

        address[] memory users = new address[](3);
        (users[0], users[1], users[2]) = (bob, carol, alice);
        PoolLens.AccountHealth[] memory h = lens.getAccountsHealth(users);
        assertTrue(h[0].ok);
        assertEq(h[0].healthFactor, 1.375e18);
        assertFalse(h[1].ok, "carol is exposed to WBTC");
        assertTrue(h[2].ok);
        assertEq(h[2].healthFactor, type(uint256).max, "no debt");
    }

    function test_previewLiquidation_healthyIsNotLiquidatable() public view {
        PoolLens.LiquidationPreview memory p = lens.previewLiquidation(bob, address(weth), address(usdc), 1e6);
        assertFalse(p.liquidatable);
        assertEq(p.healthFactor, 1.375e18);
    }

    function test_previewLiquidation_reportsProfit() public {
        _setWethPrice(1800e8);
        PoolLens.LiquidationPreview memory p =
            lens.previewLiquidation(bob, address(weth), address(usdc), type(uint128).max);
        assertTrue(p.liquidatable);
        assertEq(p.closeFactor, 5000);
        assertEq(p.debtRepaidValue, 7500e18);
        assertEq(p.collateralSeizedValue, 7875e18); // +5%
    }
}
