// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DemoBase} from "./lib/DemoBase.sol";

/// @notice Read-only: prints live market and demo-account state from the chain. No broadcast.
///         forge script script/ShowState.s.sol --rpc-url anvil
contract ShowState is DemoBase {
    function run() external {
        _load();
        _step("Markets (live chain state)");
        _printMarkets();
        _step("Accounts");
        _printAccount("alice", alice);
        _printAccount("bob", bob);
        _printAccount("carol", carol);
        _printAccount("liquidator", liquidator);
    }
}
