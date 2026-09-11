// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MathUtils} from "../../contracts/libraries/MathUtils.sol";
import {PercentageMath} from "../../contracts/libraries/PercentageMath.sol";
import {UserConfiguration} from "../../contracts/libraries/UserConfiguration.sol";
import {WadRayMath} from "../../contracts/libraries/WadRayMath.sol";
import {Test} from "forge-std/Test.sol";

contract MathLibrariesTest is Test {
    using WadRayMath for uint256;
    using UserConfiguration for uint256;

    uint256 constant RAY = 1e27;

    // ----------------------------------------------------------- rounding direction

    function test_rayMul_roundsInStatedDirection() public pure {
        assertEq(uint256(3).rayMulDown(RAY / 2), 1); // 1.5 -> 1
        assertEq(uint256(3).rayMulUp(RAY / 2), 2); //   1.5 -> 2
        assertEq(uint256(4).rayMulUp(RAY / 2), 2); //   exact stays exact
    }

    function test_rayDiv_roundsInStatedDirection() public pure {
        assertEq(uint256(1).rayDivDown(3 * RAY), 0);
        assertEq(uint256(1).rayDivUp(3 * RAY), 1);
        assertEq(uint256(6).rayDivUp(3 * RAY), 2);
    }

    function testFuzz_upIsDownOrDownPlusOne(uint128 a, uint128 b) public pure {
        vm.assume(b != 0);
        uint256 down = uint256(a).rayMulDown(b);
        uint256 up = uint256(a).rayMulUp(b);
        assertTrue(up == down || up == down + 1);

        uint256 dDown = uint256(a).rayDivDown(b);
        uint256 dUp = uint256(a).rayDivUp(b);
        assertTrue(dUp == dDown || dUp == dDown + 1);
    }

    /// @dev scaled = amount.rayDivDown(i); scaled.rayMulDown(i) <= amount. A supply round trip
    ///      can never be worth more than what went in.
    function testFuzz_supplyRoundTripNeverInflates(uint96 amount, uint128 index) public pure {
        index = uint128(bound(index, RAY, 1000 * RAY));
        uint256 scaled = uint256(amount).rayDivDown(index);
        assertLe(scaled.rayMulDown(index), amount);
    }

    /// @dev debtScaled = amount.rayDivUp(i); debtScaled.rayMulUp(i) >= amount. Borrowers can never
    ///      owe less than they took.
    function testFuzz_borrowRoundTripNeverDeflates(uint96 amount, uint128 index) public pure {
        index = uint128(bound(index, RAY, 1000 * RAY));
        uint256 scaled = uint256(amount).rayDivUp(index);
        assertGe(scaled.rayMulUp(index), amount);
    }

    function test_percentMul() public pure {
        assertEq(PercentageMath.percentMulDown(10_001, 5000), 5000);
        assertEq(PercentageMath.percentMulUp(10_001, 5000), 5001);
    }

    // ----------------------------------------------------------- interest factors

    function test_linearInterest_oneYearAtTenPercent() public {
        vm.warp(365 days + 1);
        uint256 factor = MathUtils.linearInterest(RAY / 10, 1);
        assertEq(factor, RAY + RAY / 10);
    }

    function test_compoundedInterest_zeroElapsedIsOne() public {
        vm.warp(1000);
        assertEq(MathUtils.compoundedInterest(RAY, 1000), RAY);
    }

    /// @dev Continuous compounding of 10% for a year is e^0.1 = 1.105170918...; the third-order
    ///      expansion is 1.1051666..., within x^4/24 of it and never above. Regression test: the
    ///      binomial form (rate^3 / year^3 in integers) landed at 1.105162 here, 2x further off.
    function test_compoundedInterest_closeToContinuousCompounding() public {
        vm.warp(365 days + 1);
        uint256 factor = MathUtils.compoundedInterest(RAY / 10, 1);
        uint256 eToPointOne = 1_105_170_918_075_647_624_811_707_826; // e^0.1 in ray
        assertLe(factor, eToPointOne);
        assertApproxEqRel(factor, eToPointOne, 4e12); // 4e-6 relative, the x^4/24 bound
        assertApproxEqAbs(factor, 1_105_166_666_666_666_666_666_666_666, 1e6); // exact Taylor value
    }

    function testFuzz_compoundedAtLeastLinear(uint256 rate, uint32 dt) public {
        rate = bound(rate, 0, 10 * RAY);
        vm.warp(uint256(dt) + 1);
        assertGe(MathUtils.compoundedInterest(rate, 1), MathUtils.linearInterest(rate, 1));
    }

    // ----------------------------------------------------------- user bitmap

    function testFuzz_userConfigurationBitsAreIndependent(uint8 idA, uint8 idB) public pure {
        uint256 a = bound(idA, 0, 127);
        uint256 b = bound(idB, 0, 127);
        vm.assume(a != b);
        uint256 cfg;
        cfg = cfg.setBorrowing(a, true).setCollateral(b, true);
        assertTrue(cfg.isBorrowing(a));
        assertFalse(cfg.isCollateral(a));
        assertTrue(cfg.isCollateral(b));
        assertFalse(cfg.isBorrowing(b));
        assertTrue(cfg.isBorrowingAny());
        assertTrue(cfg.hasCollateralAny());

        cfg = cfg.setBorrowing(a, false);
        assertFalse(cfg.isBorrowingAny());
        cfg = cfg.setCollateral(b, false);
        assertEq(cfg, 0);
    }
}
