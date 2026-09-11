// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice Gas benchmarks for the core user operations, one scenario per test.
/// @dev Run with `FOUNDRY_PROFILE=gas forge test` (`make gas`); the profile sets `isolate`, which runs every top-level
///      call as its own transaction, so cold/warm storage costs (EIP-2929) match mainnet reality.
///      `vm.snapshotGasLastCall` writes results to snapshots/GasBenchmarks.json; docs/gas-report.md
///      is built from that file.
contract GasBenchmarks is BaseTest {
    function setUp() public override {
        super.setUp();
        // Live market: liquidity in every reserve and an existing borrower, so benchmarks hit the
        // realistic path (non-zero rates, non-trivial indexes), not the empty-market fast path.
        _supply(alice, usdc, 1_000_000e6);
        _supply(alice, weth, 1000e18);
        _supply(alice, wbtc, 100e8);
        _supply(carol, weth, 100e18);
        _borrow(carol, usdc, 100_000e6);
        _warpAndRefresh(1 days);

        deal(address(usdc), bob, 1_000_000e6);
        deal(address(weth), bob, 1000e18);
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _bobPosition() internal {
        vm.startPrank(bob);
        pool.supply(address(weth), 10e18, bob);
        pool.borrow(address(usdc), 15_000e6);
        vm.stopPrank();
        _warpAndRefresh(1 hours);
    }

    function test_gas_supply_first() public {
        vm.prank(bob);
        pool.supply(address(weth), 10e18, bob);
        vm.snapshotGasLastCall("supply (first, enables collateral)");
    }

    function test_gas_supply_subsequent() public {
        vm.prank(bob);
        pool.supply(address(weth), 10e18, bob);
        _warpAndRefresh(1 hours);
        vm.prank(bob);
        pool.supply(address(weth), 1e18, bob);
        vm.snapshotGasLastCall("supply (subsequent)");
    }

    function test_gas_withdraw_noDebt() public {
        vm.prank(bob);
        pool.supply(address(weth), 10e18, bob);
        _warpAndRefresh(1 hours);
        vm.prank(bob);
        pool.withdraw(address(weth), 1e18, bob);
        vm.snapshotGasLastCall("withdraw (no debt, no oracle read)");
    }

    function test_gas_withdraw_withHealthCheck() public {
        _bobPosition();
        vm.prank(bob);
        pool.withdraw(address(weth), 1e18, bob);
        vm.snapshotGasLastCall("withdraw (collateral, with debt: LTV check)");
    }

    function test_gas_borrow_first() public {
        vm.prank(bob);
        pool.supply(address(weth), 10e18, bob);
        _warpAndRefresh(1 hours);
        vm.prank(bob);
        pool.borrow(address(usdc), 15_000e6);
        vm.snapshotGasLastCall("borrow (first)");
    }

    function test_gas_borrow_subsequent() public {
        _bobPosition();
        vm.prank(bob);
        pool.borrow(address(usdc), 1000e6);
        vm.snapshotGasLastCall("borrow (subsequent)");
    }

    function test_gas_repay_partial() public {
        _bobPosition();
        vm.prank(bob);
        pool.repay(address(usdc), 5000e6, bob);
        vm.snapshotGasLastCall("repay (partial)");
    }

    function test_gas_repay_full() public {
        _bobPosition();
        vm.prank(bob);
        pool.repay(address(usdc), type(uint256).max, bob);
        vm.snapshotGasLastCall("repay (full)");
    }

    function test_gas_liquidate_partial() public {
        _bobPosition();
        _setWethPrice(1800e8);
        deal(address(usdc), liquidator, 10_000e6);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(liquidator);
        pool.liquidate(address(weth), address(usdc), bob, 7500e6, false);
        vm.snapshotGasLastCall("liquidate (50% close factor, underlying)");
    }

    function test_gas_liquidate_receiveSupply() public {
        _bobPosition();
        _setWethPrice(1800e8);
        deal(address(usdc), liquidator, 10_000e6);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(liquidator);
        pool.liquidate(address(weth), address(usdc), bob, 7500e6, true);
        vm.snapshotGasLastCall("liquidate (receiveSupply)");
    }

    function test_gas_liquidate_withBadDebt() public {
        _bobPosition();
        _setWethPrice(1400e8);
        deal(address(usdc), liquidator, 20_000e6);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(liquidator);
        pool.liquidate(address(weth), address(usdc), bob, type(uint128).max, false);
        vm.snapshotGasLastCall("liquidate (collateral exhausted: bad-debt write-off)");
    }

    function test_gas_setCollateral() public {
        vm.prank(bob);
        pool.supply(address(weth), 10e18, bob);
        vm.prank(bob);
        pool.setUseReserveAsCollateral(address(weth), false);
        vm.snapshotGasLastCall("disable collateral (no debt)");
    }
}
