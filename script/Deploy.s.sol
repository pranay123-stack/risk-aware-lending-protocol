// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {KinkedInterestRateModel} from "../contracts/interest/KinkedInterestRateModel.sol";
import {AggregatorV3Interface} from "../contracts/interfaces/AggregatorV3Interface.sol";
import {Roles} from "../contracts/libraries/Roles.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MarketConfig} from "./lib/MarketConfig.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title Deploy
/// @notice Deploys the full protocol with mock tokens, lists WETH / WBTC / USDC, deploys ERC-4626
///         vaults, and hands every risk-increasing power to a TimelockController.
///
/// Price feeds:
///   FEEDS_MODE=mock (default)  MockAggregator feeds owned by the deployer, so the demo can move prices.
///   FEEDS_MODE=chainlink       real feeds from ETH_USD_FEED / BTC_USD_FEED / USDC_USD_FEED (testnet).
///
/// Environment (all optional):
///   DEPLOYER_PRIVATE_KEY   default: Anvil account #0, a PUBLIC test key. Never fund it anywhere real.
///   GUARDIAN               emergency admin, default deployer
///   TIMELOCK_PROPOSER      default deployer
///   TIMELOCK_DELAY         seconds, default 60 on Anvil and 1 day elsewhere
///   LIQUIDATION_GRACE      seconds, default 300 on Anvil and 1800 elsewhere
///
/// Output: deployments/<chainId>.json, consumed by the indexer, API, frontend and Demo.s.sol.
contract Deploy is Script {
    /// @dev Anvil / Hardhat default account #0. Publicly known; only valid on local dev chains.
    uint256 internal constant ANVIL_KEY_0 =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_CHAIN_ID = 31_337;

    struct MarketOut {
        string symbol;
        address token;
        address primaryFeed;
        address secondaryFeed;
        address irm;
        address vault;
    }

    struct Config {
        uint256 pk;
        address deployer;
        address guardian;
        address proposer;
        uint256 delay;
        uint256 grace;
        bool chainlink;
        uint256 startBlock;
    }

    function run() external {
        Config memory cfg = _config();

        vm.startBroadcast(cfg.pk);

        ProtocolDeployer.Core memory c = ProtocolDeployer.deployCore(cfg.deployer, cfg.guardian);
        MarketOut[3] memory markets = _listMarkets(c, cfg);

        // ERC-4626 lender vaults for the two assets passive lenders most want.
        markets[0].vault = address(ProtocolDeployer.deployVault(c, markets[0].token));
        markets[2].vault = address(ProtocolDeployer.deployVault(c, markets[2].token));

        c.configurator.setLiquidationGracePeriod(uint32(cfg.grace));

        TimelockController timelock = ProtocolDeployer.deployTimelock(cfg.delay, cfg.proposer);
        ProtocolDeployer.handOverToTimelock(c, timelock, cfg.deployer);

        vm.stopBroadcast();

        _assertHandOver(c, timelock, cfg);
        _write(c, timelock, markets, cfg);
    }

    /// @dev Fails the deployment unless governance ended up exactly as docs/security.md#admin
    ///      describes: the timelock (self-administered) holds every admin role, the deployer none.
    function _assertHandOver(ProtocolDeployer.Core memory c, TimelockController timelock, Config memory cfg)
        internal
        view
    {
        bytes32 aclAdmin = c.acl.DEFAULT_ADMIN_ROLE();
        require(c.acl.hasRole(Roles.POOL_ADMIN, address(timelock)), "timelock lacks POOL_ADMIN");
        require(c.acl.hasRole(aclAdmin, address(timelock)), "timelock lacks DEFAULT_ADMIN");
        require(!c.acl.hasRole(Roles.POOL_ADMIN, cfg.deployer), "deployer kept POOL_ADMIN");
        require(!c.acl.hasRole(aclAdmin, cfg.deployer), "deployer kept DEFAULT_ADMIN");
        require(
            !timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), cfg.deployer),
            "deployer administers the timelock"
        );
        require(c.acl.hasRole(Roles.CONFIGURATOR, address(c.configurator)), "configurator not wired");
        require(c.acl.hasRole(Roles.EMERGENCY_ADMIN, cfg.guardian), "guardian not set");
        require(timelock.getMinDelay() == cfg.delay, "unexpected timelock delay");
        console2.log("Roles (verified on-chain)");
        console2.log("  POOL_ADMIN + DEFAULT_ADMIN ", address(timelock));
        console2.log("  EMERGENCY_ADMIN (guardian) ", cfg.guardian);
        console2.log("  timelock proposer          ", cfg.proposer);
        console2.log("  timelock delay (s)         ", cfg.delay);
    }

    function _config() internal view returns (Config memory cfg) {
        cfg.pk = vm.envOr("DEPLOYER_PRIVATE_KEY", ANVIL_KEY_0);
        bool local = block.chainid == ANVIL_CHAIN_ID;
        if (cfg.pk == ANVIL_KEY_0 && !local) {
            revert("Refusing to use the public Anvil key on a non-local chain: set DEPLOYER_PRIVATE_KEY");
        }
        cfg.deployer = vm.addr(cfg.pk);
        cfg.guardian = vm.envOr("GUARDIAN", cfg.deployer);
        cfg.proposer = vm.envOr("TIMELOCK_PROPOSER", cfg.deployer);
        cfg.delay = vm.envOr("TIMELOCK_DELAY", local ? uint256(60) : uint256(1 days));
        cfg.grace = vm.envOr("LIQUIDATION_GRACE", local ? uint256(300) : uint256(1800));
        cfg.chainlink = keccak256(bytes(vm.envOr("FEEDS_MODE", string("mock")))) == keccak256("chainlink");
        cfg.startBlock = block.number;
    }

    function _listMarkets(ProtocolDeployer.Core memory c, Config memory cfg)
        internal
        returns (MarketOut[3] memory markets)
    {
        MarketConfig.MarketSpec[3] memory specs =
            [MarketConfig.weth(), MarketConfig.wbtc(), MarketConfig.usdc()];
        string[3] memory feedEnv = [string("ETH_USD_FEED"), "BTC_USD_FEED", "USDC_USD_FEED"];
        for (uint256 i; i < 3; ++i) {
            markets[i] = cfg.chainlink
                ? _listWithChainlink(c, specs[i], vm.envAddress(feedEnv[i]))
                : _listWithMocks(c, specs[i], cfg.deployer);
        }
    }

    function _listWithMocks(ProtocolDeployer.Core memory c, MarketConfig.MarketSpec memory s, address owner)
        internal
        returns (MarketOut memory out)
    {
        ProtocolDeployer.Market memory m = ProtocolDeployer.deployMockMarket(c, s, owner);
        out = MarketOut({
            symbol: s.symbol,
            token: address(m.token),
            primaryFeed: address(m.primaryFeed),
            secondaryFeed: address(m.secondaryFeed),
            irm: address(m.irm),
            vault: address(0)
        });
    }

    /// @dev Mock token, real feed. A secondary source is not configured: public testnets rarely offer
    ///      a second independent feed, and a mock secondary would let the deployer veto the real one.
    function _listWithChainlink(
        ProtocolDeployer.Core memory c,
        MarketConfig.MarketSpec memory s,
        address feed
    ) internal returns (MarketOut memory out) {
        MockERC20 token = new MockERC20(s.name, s.symbol, s.decimals, s.faucetLimit);
        KinkedInterestRateModel irm =
            new KinkedInterestRateModel(s.baseRate, s.slope1, s.slope2, s.optimalUtilization);
        s.withSecondary = false;
        ProtocolDeployer.listMarket(
            c, s, address(token), AggregatorV3Interface(feed), AggregatorV3Interface(address(0)), address(irm)
        );
        out = MarketOut({
            symbol: s.symbol,
            token: address(token),
            primaryFeed: feed,
            secondaryFeed: address(0),
            irm: address(irm),
            vault: address(0)
        });
    }

    function _write(
        ProtocolDeployer.Core memory c,
        TimelockController timelock,
        MarketOut[3] memory markets,
        Config memory cfg
    ) internal {
        // serializeString parses a JSON-valued string into a nested object/array.
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "startBlock", cfg.startBlock);
        vm.serializeAddress(root, "deployer", cfg.deployer);
        vm.serializeAddress(root, "guardian", cfg.guardian);
        vm.serializeAddress(root, "timelockProposer", cfg.proposer);
        vm.serializeUint(root, "timelockDelay", cfg.delay);
        vm.serializeString(root, "contracts", _contractsJson(c, timelock));
        string memory json = vm.serializeString(root, "markets", "placeholder");

        // DEPLOYMENT_OUT lets the end-to-end test write to a scratch file instead of the dev deployment.
        string memory path = vm.envOr(
            "DEPLOYMENT_OUT",
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json")
        );
        vm.writeJson(json, path);
        // serializeString nests JSON objects but not arrays, so the markets array is written in place.
        vm.writeJson(_marketsJson(markets), path, ".markets");

        console2.log("LendingPool      ", address(c.pool));
        console2.log("PoolConfigurator ", address(c.configurator));
        console2.log("OracleManager    ", address(c.oracle));
        console2.log("PoolLens         ", address(c.lens));
        console2.log("Timelock         ", address(timelock));
        console2.log("Deployment file  ", path);
    }

    function _contractsJson(ProtocolDeployer.Core memory c, TimelockController timelock)
        internal
        returns (string memory)
    {
        string memory k = "contracts";
        vm.serializeAddress(k, "aclManager", address(c.acl));
        vm.serializeAddress(k, "oracleManager", address(c.oracle));
        vm.serializeAddress(k, "lendingPool", address(c.pool));
        vm.serializeAddress(k, "poolConfigurator", address(c.configurator));
        vm.serializeAddress(k, "poolLens", address(c.lens));
        return vm.serializeAddress(k, "timelock", address(timelock));
    }

    function _marketsJson(MarketOut[3] memory markets) internal returns (string memory out) {
        out = "[";
        for (uint256 i; i < 3; ++i) {
            MarketOut memory m = markets[i];
            string memory k = string.concat("market", vm.toString(i));
            vm.serializeString(k, "symbol", m.symbol);
            vm.serializeAddress(k, "token", m.token);
            vm.serializeAddress(k, "primaryFeed", m.primaryFeed);
            vm.serializeAddress(k, "secondaryFeed", m.secondaryFeed);
            vm.serializeAddress(k, "interestRateModel", m.irm);
            out = string.concat(out, i == 0 ? "" : ",", vm.serializeAddress(k, "vault", m.vault));
        }
        out = string.concat(out, "]");
    }
}
