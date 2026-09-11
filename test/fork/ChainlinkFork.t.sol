// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ACLManager} from "../../contracts/core/ACLManager.sol";
import {AggregatorV3Interface} from "../../contracts/interfaces/AggregatorV3Interface.sol";
import {IOracleManager} from "../../contracts/interfaces/IOracleManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {OracleManager} from "../../contracts/oracle/OracleManager.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The one place a fork earns its keep: proving the OracleManager's validation and decimal
///         normalisation against *real* Chainlink aggregators, not only against our own mock.
///         Skipped unless MAINNET_RPC_URL is set (read-only; no keys, no transactions).
contract ChainlinkForkTest is Test {
    // Chainlink mainnet aggregators (8 decimals)
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    OracleManager oracle;
    address weth = makeAddr("weth");
    address wbtc = makeAddr("wbtc");
    address usdc = makeAddr("usdc");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        ACLManager acl = new ACLManager(address(this));
        acl.grantRole(Roles.POOL_ADMIN, address(this));
        oracle = new OracleManager(acl);
        AggregatorV3Interface none = AggregatorV3Interface(address(0));
        // Real heartbeats: ETH/USD and BTC/USD 1h, USDC/USD 24h
        oracle.setAssetOracle(
            weth, AggregatorV3Interface(ETH_USD), 1 hours + 5 minutes, none, 0, 0, 100e18, 1_000_000e18
        );
        oracle.setAssetOracle(
            wbtc, AggregatorV3Interface(BTC_USD), 1 hours + 5 minutes, none, 0, 0, 1000e18, 10_000_000e18
        );
        oracle.setAssetOracle(
            usdc, AggregatorV3Interface(USDC_USD), 1 days + 5 minutes, none, 0, 0, 0.5e18, 2e18
        );
    }

    function test_fork_realFeedsNormaliseToWad() public view {
        uint256 eth = oracle.getPrice(weth);
        uint256 btc = oracle.getPrice(wbtc);
        uint256 usd = oracle.getPrice(usdc);
        assertGt(eth, 100e18);
        assertGt(btc, eth, "BTC above ETH");
        assertApproxEqRel(usd, 1e18, 0.02e18, "USDC within 2% of peg");
    }

    function test_fork_realFeedGoesStaleAfterHeartbeat() public {
        vm.warp(block.timestamp + 1 days);
        IOracleManager.PriceState memory s = oracle.getPriceState(weth);
        assertEq(uint8(s.primaryStatus), uint8(IOracleManager.FeedStatus.STALE));
    }
}
