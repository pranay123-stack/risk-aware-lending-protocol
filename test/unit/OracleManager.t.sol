// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ACLManager} from "../../contracts/core/ACLManager.sol";
import {AggregatorV3Interface} from "../../contracts/interfaces/AggregatorV3Interface.sol";
import {IOracleManager} from "../../contracts/interfaces/IOracleManager.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {OracleManager} from "../../contracts/oracle/OracleManager.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Every oracle failure mode in docs/oracles.md has a test here.
contract OracleManagerTest is Test {
    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address asset = makeAddr("asset");

    ACLManager acl;
    OracleManager oracle;
    MockAggregator primary; //   8 decimals, like Chainlink USD feeds
    MockAggregator secondary; // 18 decimals

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(admin);
        acl = new ACLManager(admin);
        acl.grantRole(Roles.POOL_ADMIN, admin);
        acl.grantRole(Roles.EMERGENCY_ADMIN, guardian);
        oracle = new OracleManager(acl);
        primary = new MockAggregator(8, "ETH / USD", 2000e8, admin);
        secondary = new MockAggregator(18, "ETH / USD 2", 2000e18, admin);
        oracle.setAssetOracle(asset, primary, 1 hours, secondary, 1 hours, 300, 100e18, 100_000e18);
        vm.stopPrank();
    }

    function _configurePrimaryOnly() internal {
        vm.prank(admin);
        oracle.setAssetOracle(
            asset, primary, 1 hours, AggregatorV3Interface(address(0)), 0, 0, 100e18, 100_000e18
        );
    }

    // ------------------------------------------------------------------ happy path & decimals

    function test_getPrice_normalizesEightDecimalFeed() public view {
        assertEq(oracle.getPrice(asset), 2000e18);
        IOracleManager.PriceState memory s = oracle.getPriceState(asset);
        assertEq(uint8(s.status), uint8(IOracleManager.PriceStatus.OK));
        assertEq(s.primaryPrice, 2000e18);
        assertEq(s.secondaryPrice, 2000e18); // 18-dec feed normalised identically
    }

    function test_decimalNormalization_moreThan18Decimals() public {
        vm.startPrank(admin);
        MockAggregator feed24 = new MockAggregator(24, "24dec", 2000e24, admin);
        oracle.setAssetOracle(asset, feed24, 1 hours, AggregatorV3Interface(address(0)), 0, 0, 1e18, 1e24);
        vm.stopPrank();
        assertEq(oracle.getPrice(asset), 2000e18);
    }

    function test_decimalNormalization_zeroDecimals() public {
        vm.startPrank(admin);
        MockAggregator feed0 = new MockAggregator(0, "0dec", 2000, admin);
        oracle.setAssetOracle(asset, feed0, 1 hours, AggregatorV3Interface(address(0)), 0, 0, 1e18, 1e24);
        vm.stopPrank();
        assertEq(oracle.getPrice(asset), 2000e18);
    }

    /// @dev Answers are bounded to 2^128 before normalisation, so feeds with many decimals can
    ///      only express proportionally smaller whole-unit prices (see test below).
    function testFuzz_decimalNormalization(uint8 dec, uint64 whole) public {
        dec = uint8(bound(dec, 0, 27));
        whole = uint64(bound(whole, 1, 1e9));
        vm.startPrank(admin);
        MockAggregator feed = new MockAggregator(dec, "f", int256(uint256(whole) * 10 ** dec), admin);
        oracle.setAssetOracle(
            asset, feed, 1 hours, AggregatorV3Interface(address(0)), 0, 0, 1, type(uint128).max
        );
        vm.stopPrank();
        assertEq(oracle.getPrice(asset), uint256(whole) * 1e18);
    }

    // ------------------------------------------------------------------ staleness

    function test_stalePrimary_fallsBackToSecondary() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(admin);
        secondary.setAnswer(2010e18); // secondary still fresh
        IOracleManager.PriceState memory s = oracle.getPriceState(asset);
        assertEq(uint8(s.primaryStatus), uint8(IOracleManager.FeedStatus.STALE));
        assertEq(uint8(s.status), uint8(IOracleManager.PriceStatus.OK_FALLBACK));
        assertEq(oracle.getPrice(asset), 2010e18);
    }

    function test_revert_bothStale() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);
    }

    function test_heartbeatBoundaryIsInclusive() public {
        vm.warp(block.timestamp + 1 hours);
        assertEq(oracle.getPrice(asset), 2000e18);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);
    }

    function test_revert_stalePrimaryOnly() public {
        _configurePrimaryOnly();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);
    }

    // ------------------------------------------------------------------ invalid data

    function test_invalidAnswers_areRejected() public {
        _configurePrimaryOnly();
        int256[3] memory bad = [int256(0), int256(-1), type(int256).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            primary.setAnswer(bad[i]);
            assertEq(
                uint8(oracle.getPriceState(asset).primaryStatus),
                uint8(IOracleManager.FeedStatus.INVALID_ANSWER)
            );
            vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
            oracle.getPrice(asset);
        }
    }

    function test_answerAbove2to128_isRejectedNotOverflowed() public {
        _configurePrimaryOnly();
        vm.prank(admin);
        primary.setAnswer(int256(uint256(type(uint128).max)) + 1);
        assertEq(
            uint8(oracle.getPriceState(asset).primaryStatus), uint8(IOracleManager.FeedStatus.INVALID_ANSWER)
        );
    }

    function test_futureTimestamp_isRejected() public {
        _configurePrimaryOnly();
        vm.prank(admin);
        primary.setAnswerWithTimestamp(2000e8, block.timestamp + 60);
        assertEq(
            uint8(oracle.getPriceState(asset).primaryStatus),
            uint8(IOracleManager.FeedStatus.FUTURE_TIMESTAMP)
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);
    }

    function test_incompleteRound_isRejected() public {
        _configurePrimaryOnly();
        vm.prank(admin);
        primary.setIncompleteRound();
        assertEq(
            uint8(oracle.getPriceState(asset).primaryStatus),
            uint8(IOracleManager.FeedStatus.INCOMPLETE_ROUND)
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);
    }

    /// @dev Oracle downtime / a deprecated aggregator that reverts: reported, not propagated,
    ///      so the healthy secondary takes over.
    function test_revertingPrimary_isContainedAndFallsBack() public {
        vm.prank(admin);
        primary.setReverting(true);
        IOracleManager.PriceState memory s = oracle.getPriceState(asset);
        assertEq(uint8(s.primaryStatus), uint8(IOracleManager.FeedStatus.CALL_FAILED));
        assertEq(uint8(s.status), uint8(IOracleManager.PriceStatus.OK_FALLBACK));
        assertEq(oracle.getPrice(asset), 2000e18);
    }

    function test_revert_totalOracleDowntime() public {
        vm.startPrank(admin);
        primary.setReverting(true);
        secondary.setReverting(true);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);
    }

    // ------------------------------------------------------------------ bounds (min/maxAnswer clamping)

    /// @dev LUNA-style incident: a feed clamps at its floor while the market keeps falling. A
    ///      price at or beyond the sanity bound is treated as a malfunction.
    function test_outOfBounds_isRejected() public {
        _configurePrimaryOnly();
        vm.prank(admin);
        primary.setAnswer(99e8); // below minPrice of 100
        assertEq(
            uint8(oracle.getPriceState(asset).primaryStatus), uint8(IOracleManager.FeedStatus.OUT_OF_BOUNDS)
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);

        vm.prank(admin);
        primary.setAnswer(100_001e8); // above maxPrice
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceUnavailable.selector, asset));
        oracle.getPrice(asset);
    }

    // ------------------------------------------------------------------ deviation circuit breaker

    function test_deviationWithinTolerance_isAccepted() public {
        vm.prank(admin);
        secondary.setAnswer(2060e18); // +3.0% vs the lower price: exactly the limit
        assertEq(oracle.getPrice(asset), 2000e18); // primary is reported
    }

    /// @dev A manipulated or malfunctioning single source cannot move the protocol's price:
    ///      disagreement beyond the tolerance halts every price-dependent action.
    function test_revert_deviationBeyondTolerance() public {
        vm.prank(admin);
        primary.setAnswer(2061e8);
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePriceDeviation.selector, asset, 2061e18, 2000e18));
        oracle.getPrice(asset);
        assertEq(uint8(oracle.getPriceState(asset).status), uint8(IOracleManager.PriceStatus.DEVIATION));
    }

    function testFuzz_deviationIsSymmetric(uint64 p1, uint64 p2) public {
        p1 = uint64(bound(p1, 1000, 50_000));
        p2 = uint64(bound(p2, 1000, 50_000));
        vm.startPrank(admin);
        primary.setAnswer(int256(uint256(p1)) * 1e8);
        secondary.setAnswer(int256(uint256(p2)) * 1e18);
        vm.stopPrank();
        IOracleManager.PriceState memory s1 = oracle.getPriceState(asset);

        vm.startPrank(admin);
        primary.setAnswer(int256(uint256(p2)) * 1e8);
        secondary.setAnswer(int256(uint256(p1)) * 1e18);
        vm.stopPrank();
        IOracleManager.PriceState memory s2 = oracle.getPriceState(asset);
        assertEq(uint8(s1.status), uint8(s2.status));
    }

    // ------------------------------------------------------------------ manual breaker & access

    function test_guardianPause_haltsReads() public {
        vm.prank(guardian);
        oracle.setAssetPaused(asset, true);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleAssetPaused.selector, asset));
        oracle.getPrice(asset);
        // monitoring still sees the underlying feed data
        IOracleManager.PriceState memory s = oracle.getPriceState(asset);
        assertEq(uint8(s.status), uint8(IOracleManager.PriceStatus.PAUSED));
        assertEq(s.primaryPrice, 2000e18);

        vm.prank(guardian);
        oracle.setAssetPaused(asset, false);
        assertEq(oracle.getPrice(asset), 2000e18);
    }

    function test_reconfigureDoesNotLiftPause() public {
        vm.prank(guardian);
        oracle.setAssetPaused(asset, true);
        _configurePrimaryOnly();
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleAssetPaused.selector, asset));
        oracle.getPrice(asset);
    }

    function test_revert_unconfiguredAsset() public {
        address other = makeAddr("other");
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleNotConfigured.selector, other));
        oracle.getPrice(other);
    }

    function test_revert_nonAdminCannotConfigure() public {
        vm.prank(guardian);
        vm.expectRevert(Errors.NotPoolAdmin.selector);
        oracle.setAssetOracle(asset, primary, 1 hours, AggregatorV3Interface(address(0)), 0, 0, 1, 2);
    }

    function test_revert_strangerCannotPause() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.NotEmergencyAdmin.selector);
        oracle.setAssetPaused(asset, true);
    }

    function test_revert_invalidConfigs() public {
        vm.startPrank(admin);
        AggregatorV3Interface none = AggregatorV3Interface(address(0));
        vm.expectRevert(Errors.InvalidOracleConfig.selector); // zero heartbeat
        oracle.setAssetOracle(asset, primary, 0, none, 0, 0, 1, 2);
        vm.expectRevert(Errors.InvalidOracleConfig.selector); // heartbeat above max
        oracle.setAssetOracle(asset, primary, 3 days, none, 0, 0, 1, 2);
        vm.expectRevert(Errors.InvalidOracleConfig.selector); // min >= max
        oracle.setAssetOracle(asset, primary, 1 hours, none, 0, 0, 2, 2);
        vm.expectRevert(Errors.InvalidOracleConfig.selector); // secondary without deviation bound
        oracle.setAssetOracle(asset, primary, 1 hours, secondary, 1 hours, 0, 1, 2);
        vm.expectRevert(Errors.InvalidOracleConfig.selector); // secondary == primary
        oracle.setAssetOracle(asset, primary, 1 hours, primary, 1 hours, 100, 1, 2);
        vm.expectRevert(Errors.InvalidOracleConfig.selector); // deviation above max
        oracle.setAssetOracle(asset, primary, 1 hours, secondary, 1 hours, 2001, 1, 2);
        vm.expectRevert(Errors.InvalidOracleConfig.selector); // dangling deviation without secondary
        oracle.setAssetOracle(asset, primary, 1 hours, none, 0, 100, 1, 2);
        vm.stopPrank();
    }
}
