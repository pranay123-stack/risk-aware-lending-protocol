// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolConfigurator} from "../../contracts/core/PoolConfigurator.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Access control, parameter validation and the timelocked admin path.
contract GovernanceTest is BaseTest {
    uint256 constant DELAY = 2 days;
    TimelockController timelock;
    address proposer = makeAddr("proposer");

    function _handOver() internal {
        vm.startPrank(admin);
        timelock = ProtocolDeployer.deployTimelock(DELAY, proposer);
        ProtocolDeployer.handOverToTimelock(
            ProtocolDeployer.Core(acl, oracle, pool, configurator, lens), timelock, admin
        );
        vm.stopPrank();
    }

    function _schedule(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(proposer);
        timelock.schedule(target, 0, data, bytes32(0), salt, DELAY);
    }

    // ================================================================== timelock

    function test_handOver_removesDeployerPowers() public {
        _handOver();
        assertFalse(acl.hasRole(Roles.POOL_ADMIN, admin));
        assertFalse(acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(acl.hasRole(Roles.POOL_ADMIN, address(timelock)));
        assertTrue(acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), address(timelock)));

        vm.prank(admin);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setRiskParameters(address(weth), 7000, 8000, 500);
    }

    function test_timelock_parameterChangeRequiresDelay() public {
        _handOver();
        bytes memory call =
            abi.encodeCall(PoolConfigurator.setRiskParameters, (address(weth), 7500, 8000, 500));
        _schedule(address(configurator), call, "risk-1");

        // Executing early fails
        vm.expectRevert();
        timelock.execute(address(configurator), 0, call, bytes32(0), "risk-1");

        // Anyone can execute once matured
        vm.warp(block.timestamp + DELAY);
        vm.prank(makeAddr("anyone"));
        timelock.execute(address(configurator), 0, call, bytes32(0), "risk-1");

        DataTypes.ReserveConfig memory c = pool.getReserveConfig(address(weth));
        assertEq(c.ltv, 7500);
        assertEq(c.liquidationThreshold, 8000);
    }

    function test_timelock_proposerCanCancel() public {
        _handOver();
        bytes memory call = abi.encodeCall(PoolConfigurator.setReserveFactor, (address(usdc), 4000));
        _schedule(address(configurator), call, "rf");
        bytes32 id = timelock.hashOperation(address(configurator), 0, call, bytes32(0), "rf");
        vm.prank(proposer);
        timelock.cancel(id);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert();
        timelock.execute(address(configurator), 0, call, bytes32(0), "rf");
    }

    function test_revert_nonProposerCannotSchedule() public {
        _handOver();
        vm.prank(admin);
        vm.expectRevert();
        timelock.schedule(address(configurator), 0, "", bytes32(0), "x", DELAY);
    }

    function test_revert_scheduleShorterThanMinDelay() public {
        _handOver();
        vm.prank(proposer);
        vm.expectRevert();
        timelock.schedule(address(configurator), 0, "", bytes32(0), "x", DELAY - 1);
    }

    /// @dev The guardian keeps its instant, risk-reducing powers after the hand-over.
    function test_guardianStillActsInstantlyAfterHandOver() public {
        _handOver();
        vm.startPrank(guardian);
        configurator.setPoolPaused(true);
        configurator.setPoolPaused(false);
        configurator.setReserveFrozen(address(weth), true);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setReserveFrozen(address(weth), false); // unfreeze is governance-only
        vm.stopPrank();

        bytes memory call = abi.encodeCall(PoolConfigurator.setReserveFrozen, (address(weth), false));
        _schedule(address(configurator), call, "unfreeze");
        vm.warp(block.timestamp + DELAY);
        timelock.execute(address(configurator), 0, call, bytes32(0), "unfreeze");
        assertFalse(pool.getReserveConfig(address(weth)).frozen);
    }

    function test_roleRevocation_isGovernanceControlled() public {
        _handOver();
        bytes memory call = abi.encodeCall(IAccessControl.revokeRole, (Roles.EMERGENCY_ADMIN, guardian));
        _schedule(address(acl), call, "revoke");
        vm.warp(block.timestamp + DELAY);
        timelock.execute(address(acl), 0, call, bytes32(0), "revoke");
        vm.prank(guardian);
        vm.expectRevert(Errors.NotEmergencyAdmin.selector);
        configurator.setPoolPaused(true);
    }

    // ================================================================== access control

    function test_revert_strangerCannotConfigure() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setRiskParameters(address(weth), 7000, 8000, 500);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setReserveFactor(address(weth), 1000);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setCaps(address(weth), 1, 1);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setInterestRateModel(address(weth), address(wethIrm));
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.withdrawReserves(address(weth), 1, stranger);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setOracle(stranger);
        vm.expectRevert(Errors.NotEmergencyAdmin.selector);
        configurator.setPoolPaused(true);
        vm.expectRevert(Errors.NotEmergencyAdmin.selector);
        configurator.setReservePaused(address(weth), true);
        vm.expectRevert(Errors.NotEmergencyAdmin.selector);
        configurator.setReserveFrozen(address(weth), true);
        vm.stopPrank();
    }

    function test_revert_guardianCannotChangeRiskParameters() public {
        vm.prank(guardian);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        configurator.setRiskParameters(address(weth), 7000, 8000, 500);
    }

    /// @dev The pool trusts only the configurator, not even the pool admin directly.
    function test_revert_poolSettersOnlyConfigurator() public {
        DataTypes.ReserveConfig memory c = pool.getReserveConfig(address(weth));
        vm.startPrank(admin);
        vm.expectRevert(Errors.NotConfigurator.selector);
        pool.setReserveConfig(address(weth), c);
        vm.expectRevert(Errors.NotConfigurator.selector);
        pool.setPoolPaused(true);
        vm.expectRevert(Errors.NotConfigurator.selector);
        pool.initReserve(address(1), address(2), c);
        vm.expectRevert(Errors.NotConfigurator.selector);
        pool.withdrawReserves(address(weth), 1, admin);
        vm.expectRevert(Errors.NotConfigurator.selector);
        pool.setOracle(address(1));
        vm.expectRevert(Errors.NotConfigurator.selector);
        pool.setInterestRateModel(address(weth), address(1));
        vm.stopPrank();
    }

    function test_revert_onlyDefaultAdminGrantsRoles() public {
        vm.prank(guardian);
        vm.expectRevert();
        acl.grantRole(Roles.POOL_ADMIN, guardian);
    }

    // ================================================================== parameter validation

    function test_revert_riskParameterInvariants() public {
        vm.startPrank(admin);
        vm.expectRevert(Errors.InvalidRiskParameters.selector); // ltv == lt
        configurator.setRiskParameters(address(weth), 8000, 8000, 500);
        vm.expectRevert(Errors.InvalidRiskParameters.selector); // ltv > lt
        configurator.setRiskParameters(address(weth), 8500, 8000, 500);
        vm.expectRevert(Errors.InvalidRiskParameters.selector); // lt above 95%
        configurator.setRiskParameters(address(weth), 9000, 9600, 100);
        vm.expectRevert(Errors.InvalidRiskParameters.selector); // no bonus
        configurator.setRiskParameters(address(weth), 7000, 8000, 0);
        vm.expectRevert(Errors.InvalidRiskParameters.selector); // bonus above 20%
        configurator.setRiskParameters(address(weth), 7000, 8000, 2001);
        // LT * (1 + bonus) must stay below 100%: 90% * 1.12 = 100.8%
        vm.expectRevert(Errors.InvalidRiskParameters.selector);
        configurator.setRiskParameters(address(weth), 8500, 9000, 1200);
        // the boundary is strict and rounds against the parameters: 90.91% * 1.10 = 100.001%
        vm.expectRevert(Errors.InvalidRiskParameters.selector);
        configurator.setRiskParameters(address(weth), 8500, 9091, 1000);
        vm.expectRevert(Errors.InvalidRiskParameters.selector); // LT 0 requires LTV 0
        configurator.setRiskParameters(address(weth), 100, 0, 0);
        vm.stopPrank();
    }

    function test_nonCollateralAsset_zeroParams() public {
        vm.startPrank(admin);
        configurator.setCollateralEnabled(address(usdc), false);
        configurator.setRiskParameters(address(usdc), 0, 0, 0);
        vm.expectRevert(Errors.InvalidRiskParameters.selector);
        configurator.setCollateralEnabled(address(usdc), true); // cannot enable with LT 0
        vm.stopPrank();
    }

    function testFuzz_acceptedParamsSatisfyLiquidationSafety(uint16 ltv, uint16 lt, uint16 bonus) public {
        vm.prank(admin);
        try configurator.setRiskParameters(address(weth), ltv, lt, bonus) {
            DataTypes.ReserveConfig memory c = pool.getReserveConfig(address(weth));
            if (c.liquidationThreshold != 0) {
                assertLt(c.ltv, c.liquidationThreshold);
                assertLt(uint256(c.liquidationThreshold) * (10_000 + c.liquidationBonus), 10_000 * 10_000);
                assertGt(c.liquidationBonus, 0);
            }
        } catch {}
    }

    function test_revert_reserveFactorAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidReserveFactor.selector);
        configurator.setReserveFactor(address(weth), 5001);
    }

    function test_revert_rateModelWithoutCode() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidRateModelParams.selector);
        configurator.setInterestRateModel(address(weth), makeAddr("eoa"));
    }

    function test_revert_listSameAssetTwice() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ReserveAlreadyInitialized.selector);
        configurator.initReserve(_input(address(weth)));
    }

    function test_revert_maxReserves() public {
        vm.startPrank(admin);
        for (uint256 i = 3; i < pool.MAX_RESERVES(); ++i) {
            configurator.initReserve(_input(address(new MockERC20("T", "T", 18, 1))));
        }
        address extra = address(new MockERC20("X", "X", 18, 1));
        vm.expectRevert(Errors.MaxReservesReached.selector);
        configurator.initReserve(_input(extra));
        vm.stopPrank();
        assertEq(pool.getReservesList().length, pool.MAX_RESERVES());
    }

    function test_revert_decimalsCannotChange() public {
        vm.prank(admin);
        acl.grantRole(Roles.CONFIGURATOR, address(this));
        DataTypes.ReserveConfig memory c = pool.getReserveConfig(address(weth));
        c.decimals = 6;
        vm.expectRevert(Errors.InvalidDecimals.selector);
        pool.setReserveConfig(address(weth), c);
    }

    function test_deactivateOnlyEmptyReserve() public {
        _supply(alice, wbtc, 1e8);
        vm.startPrank(admin);
        vm.expectRevert(Errors.InvalidRiskParameters.selector);
        configurator.setReserveActive(address(wbtc), false);
        vm.stopPrank();
        _withdraw(alice, wbtc, type(uint256).max);
        vm.prank(admin);
        configurator.setReserveActive(address(wbtc), false);
        assertFalse(pool.getReserveConfig(address(wbtc)).active);
    }

    function test_revert_gracePeriodAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidGracePeriod.selector);
        configurator.setLiquidationGracePeriod(4 hours + 1);
    }

    function _input(address asset) internal view returns (PoolConfigurator.InitReserveInput memory) {
        return PoolConfigurator.InitReserveInput({
            asset: asset,
            interestRateModel: address(wethIrm),
            ltv: 5000,
            liquidationThreshold: 6000,
            liquidationBonus: 1000,
            reserveFactor: 1000,
            supplyCap: 0,
            borrowCap: 0,
            borrowingEnabled: true,
            collateralEnabled: true
        });
    }
}
