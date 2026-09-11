// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DemoBase} from "./lib/DemoBase.sol";
import {console2} from "forge-std/Script.sol";

/// @title Demo
/// @notice The brief's end-to-end scenario on a local Anvil chain, after Deploy.s.sol:
///   6. mint test tokens            9. borrow
///   7. create sample users        10. change the oracle price
///   8. supply collateral          11. liquidate
///                                 12. display the resulting state
///
///   alice       liquidity provider: 250,000 USDC + 100 WETH, plus 10,000 USDC in the ERC-4626 vault
///   bob         the brief's borrower: 10 WETH collateral, 15,000 USDC debt
///   carol       a second, healthy borrower on WBTC collateral
///   liquidator  repays half of bob's debt after ETH falls from $2,500 to $1,800
///
/// Run: forge script script/Demo.s.sol --rpc-url anvil --broadcast --slow
contract Demo is DemoBase {
    function run() external {
        _load();

        _step("6-7. Mint mock tokens to the sample users (open faucet, no real value)");
        vm.startBroadcast(aliceKey);
        usdc.mint(alice, 260_000e6);
        weth.mint(alice, 100e18);
        vm.stopBroadcast();
        vm.startBroadcast(bobKey);
        weth.mint(bob, 10e18);
        vm.stopBroadcast();
        vm.startBroadcast(carolKey);
        wbtc.mint(carol, 5e8);
        vm.stopBroadcast();
        vm.startBroadcast(liquidatorKey);
        usdc.mint(liquidator, 50_000e6);
        vm.stopBroadcast();
        console2.log("  alice      ", alice);
        console2.log("  bob        ", bob);
        console2.log("  carol      ", carol);
        console2.log("  liquidator ", liquidator);

        _step("8. Supply: alice provides liquidity, bob and carol post collateral");
        vm.startBroadcast(aliceKey);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.supply(address(usdc), 250_000e6, alice);
        pool.supply(address(weth), 100e18, alice);
        usdc.approve(address(usdcVault), 10_000e6);
        usdcVault.deposit(10_000e6, alice);
        vm.stopBroadcast();
        vm.startBroadcast(bobKey);
        weth.approve(address(pool), type(uint256).max);
        pool.supply(address(weth), 10e18, bob);
        vm.stopBroadcast();
        vm.startBroadcast(carolKey);
        wbtc.approve(address(pool), type(uint256).max);
        pool.supply(address(wbtc), 5e8, carol);
        vm.stopBroadcast();

        _step("9. Borrow: bob 15,000 USDC against 10 WETH; carol 150,000 USDC against 5 WBTC");
        vm.startBroadcast(bobKey);
        pool.borrow(address(usdc), 15_000e6);
        vm.stopBroadcast();
        vm.startBroadcast(carolKey);
        pool.borrow(address(usdc), 150_000e6);
        vm.stopBroadcast();
        _printMarkets();
        _printAccount("bob", bob);
        _printAccount("carol", carol);

        _step("10. Oracle: ETH/USD falls from $2,500 to $1,800 (both feeds, so the deviation check passes)");
        vm.startBroadcast(deployerKey);
        wethFeed.setAnswer(1800e8);
        wethFeed2.setAnswer(1800e18);
        vm.stopBroadcast();
        _printAccount("bob", bob);
        console2.log("  bob is liquidatable: HF < 1 (10 WETH x $1,800 x 82.5% LT = $14,850 < $15,000 debt)");

        _step("11. Liquidation: repay up to the 50% close factor, receive WETH + 5% bonus");
        vm.startBroadcast(liquidatorKey);
        usdc.approve(address(pool), type(uint256).max);
        (uint256 repaid, uint256 seized) =
            pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, false);
        vm.stopBroadcast();
        console2.log(string.concat("  repaid  ", _fmt(repaid, 6, 2), " USDC"));
        console2.log(
            string.concat("  seized  ", _fmt(seized, 18, 4), " WETH  (= $", _fmt(seized * 1800, 18, 2), ")")
        );

        _step("12. Resulting state");
        _printMarkets();
        _printAccount("bob", bob);
        _printAccount("carol", carol);
        _printAccount("liquidator", liquidator);
        console2.log(string.concat("  liquidator WETH balance: ", _fmt(weth.balanceOf(liquidator), 18, 4)));
        console2.log(
            string.concat(
                "  alice's lvUSDC vault position: ",
                _fmt(usdcVault.previewRedeem(usdcVault.balanceOf(alice)), 6, 2),
                " USDC"
            )
        );
    }
}
