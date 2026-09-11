// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ACLManager} from "../../contracts/core/ACLManager.sol";
import {LendingPool} from "../../contracts/core/LendingPool.sol";
import {PoolConfigurator} from "../../contracts/core/PoolConfigurator.sol";
import {KinkedInterestRateModel} from "../../contracts/interest/KinkedInterestRateModel.sol";
import {AggregatorV3Interface} from "../../contracts/interfaces/AggregatorV3Interface.sol";
import {ILendingPool} from "../../contracts/interfaces/ILendingPool.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {OracleManager} from "../../contracts/oracle/OracleManager.sol";
import {LendingVault} from "../../contracts/periphery/LendingVault.sol";
import {PoolLens} from "../../contracts/periphery/PoolLens.sol";
import {MarketConfig} from "./MarketConfig.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ProtocolDeployer
/// @notice Deployment steps shared by script/Deploy.s.sol and the test fixture. Internal library
///         functions run in the caller's context, so `new` and every admin call are made by the
///         broadcaster (in scripts) or the pranked admin (in tests).
/// @dev The caller must be `admin` for the whole sequence: it receives DEFAULT_ADMIN_ROLE and uses
///      it to wire the other roles.
library ProtocolDeployer {
    struct Core {
        ACLManager acl;
        OracleManager oracle;
        LendingPool pool;
        PoolConfigurator configurator;
        PoolLens lens;
    }

    struct Market {
        MockERC20 token;
        MockAggregator primaryFeed;
        MockAggregator secondaryFeed; // address(0) when the spec has no secondary
        KinkedInterestRateModel irm;
    }

    function deployCore(address admin, address guardian) internal returns (Core memory c) {
        c.acl = new ACLManager(admin);
        c.acl.grantRole(Roles.POOL_ADMIN, admin);
        c.acl.grantRole(Roles.EMERGENCY_ADMIN, guardian);
        c.oracle = new OracleManager(c.acl);
        c.pool = new LendingPool(c.acl, c.oracle);
        c.configurator = new PoolConfigurator(ILendingPool(address(c.pool)), c.acl);
        c.acl.grantRole(Roles.CONFIGURATOR, address(c.configurator));
        c.lens = new PoolLens(ILendingPool(address(c.pool)));
    }

    /// @notice Deploy a mock token + mock feed(s) + rate model and list the market.
    function deployMockMarket(Core memory c, MarketConfig.MarketSpec memory s, address feedOwner)
        internal
        returns (Market memory m)
    {
        m.token = new MockERC20(s.name, s.symbol, s.decimals, s.faucetLimit);
        m.primaryFeed = new MockAggregator(8, string.concat(s.symbol, " / USD"), s.price, feedOwner);
        if (s.withSecondary) {
            // 18-decimal secondary source: exercises decimal normalisation on every read.
            m.secondaryFeed = new MockAggregator(
                18, string.concat(s.symbol, " / USD (secondary)"), s.price * 1e10, feedOwner
            );
        }
        m.irm = new KinkedInterestRateModel(s.baseRate, s.slope1, s.slope2, s.optimalUtilization);
        listMarket(c, s, address(m.token), m.primaryFeed, m.secondaryFeed, address(m.irm));
    }

    /// @notice Configure the oracle and list a reserve for an existing token and feed set.
    function listMarket(
        Core memory c,
        MarketConfig.MarketSpec memory s,
        address token,
        AggregatorV3Interface primary,
        AggregatorV3Interface secondary,
        address irm
    ) internal {
        bool hasSecondary = address(secondary) != address(0);
        c.oracle
            .setAssetOracle(
                token,
                primary,
                s.heartbeat,
                secondary,
                hasSecondary ? s.heartbeat : 0,
                hasSecondary ? s.maxDeviationBps : 0,
                s.minPrice,
                s.maxPrice
            );
        c.configurator
            .initReserve(
                PoolConfigurator.InitReserveInput({
                    asset: token,
                    interestRateModel: irm,
                    ltv: s.ltv,
                    liquidationThreshold: s.liquidationThreshold,
                    liquidationBonus: s.liquidationBonus,
                    reserveFactor: s.reserveFactor,
                    supplyCap: s.supplyCap,
                    borrowCap: s.borrowCap,
                    borrowingEnabled: s.borrowingEnabled,
                    collateralEnabled: s.collateralEnabled
                })
            );
    }

    /// @notice Timelock with an open executor set (anyone may execute a matured operation) and no
    ///         external admin: after construction it administers itself, so the delay cannot be
    ///         bypassed by an admin key.
    function deployTimelock(uint256 delay, address proposer) internal returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        return new TimelockController(delay, proposers, executors, address(0));
    }

    /// @notice Move every risk-increasing power to the timelock and drop the deployer's. After this
    ///         the deployer keeps nothing but (optionally) the guardian role granted in deployCore.
    function handOverToTimelock(Core memory c, TimelockController timelock, address deployer) internal {
        c.acl.grantRole(Roles.POOL_ADMIN, address(timelock));
        c.acl.grantRole(c.acl.DEFAULT_ADMIN_ROLE(), address(timelock));
        c.acl.renounceRole(Roles.POOL_ADMIN, deployer);
        c.acl.renounceRole(c.acl.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function deployVault(Core memory c, address token) internal returns (LendingVault) {
        string memory symbol = IERC20Metadata(token).symbol();
        return new LendingVault(
            ILendingPool(address(c.pool)),
            IERC20Metadata(token),
            string.concat("Lending Vault ", symbol),
            string.concat("lv", symbol)
        );
    }
}
