// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {KinkedInterestRateModel} from "../../contracts/interest/KinkedInterestRateModel.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Kinked model with round numbers: base 2%, slope1 4%, slope2 75%, kink 80%.
contract InterestRateModelTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant PCT = 1e25;

    KinkedInterestRateModel irm;

    function setUp() public {
        irm = new KinkedInterestRateModel(2 * PCT, 4 * PCT, 75 * PCT, 80 * PCT);
    }

    /// @dev cash/debt pair that produces utilization `u` (in percent) exactly.
    function _state(uint256 uPct) internal pure returns (uint256 cash, uint256 debt) {
        debt = uPct * 1e18;
        cash = (100 - uPct) * 1e18;
    }

    function test_zeroUtilization_paysBaseRate() public view {
        assertEq(irm.utilization(1000e18, 0), 0);
        assertEq(irm.getBorrowRate(1000e18, 0), 2 * PCT);
        assertEq(irm.getBorrowRate(0, 0), 2 * PCT); // empty market
    }

    function test_normalUtilization_isLinearInFirstSlope() public view {
        (uint256 cash, uint256 debt) = _state(40); // half-way to the kink
        assertEq(irm.utilization(cash, debt), 40 * PCT);
        assertEq(irm.getBorrowRate(cash, debt), 2 * PCT + 2 * PCT);
    }

    function test_optimalUtilization_isBasePlusSlope1() public view {
        (uint256 cash, uint256 debt) = _state(80);
        assertEq(irm.getBorrowRate(cash, debt), 6 * PCT);
    }

    function test_aboveOptimal_jumpsOntoSecondSlope() public view {
        (uint256 cash, uint256 debt) = _state(90); // half of the excess range
        assertEq(irm.getBorrowRate(cash, debt), 2 * PCT + 4 * PCT + 37.5e25);
    }

    function test_maximumUtilization_isBasePlusBothSlopes() public view {
        assertEq(irm.utilization(0, 1000e18), RAY);
        assertEq(irm.getBorrowRate(0, 1000e18), 81 * PCT);
        assertEq(irm.maxBorrowRate(), 81 * PCT);
    }

    /// @dev The curve is continuous at the kink: the first slope's end is the second slope's start.
    function test_continuousAtKink() public view {
        uint256 atKink = irm.getBorrowRate(20e18, 80e18);
        uint256 justAbove = irm.getBorrowRate(20e18 - 1, 80e18 + 1);
        assertEq(atKink, 6 * PCT);
        assertApproxEqAbs(justAbove, atKink, 1e10);
        assertGe(justAbove, atKink);
    }

    /// @dev Monotonic: more utilization never lowers the borrow rate.
    function testFuzz_rateMonotonicInUtilization(uint128 total, uint128 debtA, uint128 debtB) public view {
        vm.assume(total > 0);
        uint256 a = bound(debtA, 0, total);
        uint256 b = bound(debtB, a, total);
        uint256 rateA = irm.getBorrowRate(total - a, a);
        uint256 rateB = irm.getBorrowRate(total - b, b);
        assertGe(rateB, rateA);
        assertLe(rateB, irm.maxBorrowRate());
    }

    function testFuzz_utilizationNeverExceedsOne(uint128 cash, uint128 debt) public view {
        assertLe(irm.utilization(cash, debt), RAY);
    }

    // ------------------------------------------------------------------ parameter validation

    function test_revert_kinkAtZero() public {
        vm.expectRevert(Errors.InvalidRateModelParams.selector);
        new KinkedInterestRateModel(0, 4 * PCT, 75 * PCT, 0);
    }

    function test_revert_kinkAtHundredPercent() public {
        vm.expectRevert(Errors.InvalidRateModelParams.selector);
        new KinkedInterestRateModel(0, 4 * PCT, 75 * PCT, RAY);
    }

    function test_revert_maxRateAboveCeiling() public {
        vm.expectRevert(Errors.InvalidRateModelParams.selector);
        new KinkedInterestRateModel(1 * RAY, 5 * RAY, 5 * RAY, 80 * PCT);
    }
}
