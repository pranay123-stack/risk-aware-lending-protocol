// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ACLManager} from "../../contracts/core/ACLManager.sol";
import {LendingPool} from "../../contracts/core/LendingPool.sol";
import {PoolConfigurator} from "../../contracts/core/PoolConfigurator.sol";
import {KinkedInterestRateModel} from "../../contracts/interest/KinkedInterestRateModel.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {OracleManager} from "../../contracts/oracle/OracleManager.sol";
import {PoolLens} from "../../contracts/periphery/PoolLens.sol";
import {MarketConfig} from "../../script/lib/MarketConfig.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Full protocol fixture: 3 markets deployed with the exact production demo parameters.
abstract contract BaseTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant START_TIME = 1_700_000_000;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal liquidator = makeAddr("liquidator");

    ACLManager internal acl;
    OracleManager internal oracle;
    LendingPool internal pool;
    PoolConfigurator internal configurator;
    PoolLens internal lens;

    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal usdc;
    MockAggregator internal wethFeed;
    MockAggregator internal wethFeed2; // secondary, 18 decimals
    MockAggregator internal wbtcFeed;
    MockAggregator internal usdcFeed;
    KinkedInterestRateModel internal wethIrm;
    KinkedInterestRateModel internal wbtcIrm;
    KinkedInterestRateModel internal usdcIrm;

    function setUp() public virtual {
        vm.warp(START_TIME);
        vm.startPrank(admin);
        ProtocolDeployer.Core memory c = ProtocolDeployer.deployCore(admin, guardian);
        acl = c.acl;
        oracle = c.oracle;
        pool = c.pool;
        configurator = c.configurator;
        lens = c.lens;

        ProtocolDeployer.Market memory m = ProtocolDeployer.deployMockMarket(c, MarketConfig.weth(), admin);
        (weth, wethFeed, wethFeed2, wethIrm) = (m.token, m.primaryFeed, m.secondaryFeed, m.irm);
        m = ProtocolDeployer.deployMockMarket(c, MarketConfig.wbtc(), admin);
        (wbtc, wbtcFeed, wbtcIrm) = (m.token, m.primaryFeed, m.irm);
        m = ProtocolDeployer.deployMockMarket(c, MarketConfig.usdc(), admin);
        (usdc, usdcFeed, usdcIrm) = (m.token, m.primaryFeed, m.irm);
        vm.stopPrank();

        vm.label(address(pool), "LendingPool");
        vm.label(address(weth), "WETH");
        vm.label(address(wbtc), "WBTC");
        vm.label(address(usdc), "USDC");
    }

    // ------------------------------------------------------------------ actions

    function _supply(address user, MockERC20 token, uint256 amount) internal {
        deal(address(token), user, token.balanceOf(user) + amount);
        vm.startPrank(user);
        token.approve(address(pool), amount);
        pool.supply(address(token), amount, user);
        vm.stopPrank();
    }

    function _borrow(address user, MockERC20 token, uint256 amount) internal {
        vm.prank(user);
        pool.borrow(address(token), amount);
    }

    function _repay(address user, MockERC20 token, uint256 amount) internal returns (uint256 paid) {
        deal(address(token), user, token.balanceOf(user) + amount);
        vm.startPrank(user);
        token.approve(address(pool), amount);
        paid = pool.repay(address(token), amount, user);
        vm.stopPrank();
    }

    function _withdraw(address user, MockERC20 token, uint256 amount) internal returns (uint256) {
        vm.prank(user);
        return pool.withdraw(address(token), amount, user);
    }

    function _liquidate(
        address who,
        MockERC20 coll,
        MockERC20 debt,
        address borrower,
        uint256 amount,
        bool receiveSupply
    ) internal returns (uint256 repaid, uint256 seized) {
        deal(address(debt), who, debt.balanceOf(who) + amount);
        vm.startPrank(who);
        debt.approve(address(pool), amount);
        (repaid, seized) = pool.liquidate(address(coll), address(debt), borrower, amount, receiveSupply);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ oracle helpers

    /// @dev Moves WETH's price on both feeds so the cross-source check stays satisfied.
    function _setWethPrice(uint256 usd8) internal {
        vm.startPrank(admin);
        wethFeed.setAnswer(int256(usd8));
        wethFeed2.setAnswer(int256(usd8) * 1e10);
        vm.stopPrank();
    }

    function _setPrice(MockAggregator feed, uint256 usd8) internal {
        vm.prank(admin);
        feed.setAnswer(int256(usd8));
    }

    /// @dev Warp and refresh every feed so time-based tests are not tripped by staleness.
    function _warpAndRefresh(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.startPrank(admin);
        wethFeed.poke();
        wethFeed2.poke();
        wbtcFeed.poke();
        usdcFeed.poke();
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ views

    function _hf(address user) internal view returns (uint256) {
        return pool.getUserAccountData(user).healthFactor;
    }

    function _reserve(MockERC20 token) internal view returns (DataTypes.ReserveData memory) {
        return pool.getReserveData(address(token));
    }

    /// @dev Classic scenario from the brief: 10 WETH collateral, 15,000 USDC debt.
    function _openBobPosition() internal {
        _supply(alice, usdc, 100_000e6);
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 15_000e6);
    }
}
