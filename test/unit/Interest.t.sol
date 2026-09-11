// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {KinkedInterestRateModel} from "../../contracts/interest/KinkedInterestRateModel.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {MathUtils} from "../../contracts/libraries/MathUtils.sol";
import {WadRayMath} from "../../contracts/libraries/WadRayMath.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

contract InterestTest is BaseTest {
    using WadRayMath for uint256;

    function setUp() public override {
        super.setUp();
        _supply(alice, usdc, 100_000e6);
        _supply(bob, weth, 100e18); // $250k collateral
    }

    function test_noBorrows_noInterest() public {
        _warpAndRefresh(365 days);
        assertEq(pool.supplyBalanceOf(address(usdc), alice), 100_000e6);
        assertEq(pool.getReserveNormalizedIncome(address(usdc)), RAY);
        assertEq(_reserve(usdc).liquidityRate, 0);
    }

    /// @dev 50% utilization on the USDC curve (kink 90%, slope1 6%): 50/90 * 6% = 3.333...% APR.
    function test_ratesFollowUtilization() public {
        _borrow(bob, usdc, 50_000e6);
        DataTypes.ReserveData memory r = _reserve(usdc);
        uint256 expectedBorrow = uint256(6e25).rayMulDown(uint256(50e25).rayDivDown(90e25));
        assertEq(r.borrowRate, expectedBorrow);
        // supply rate = borrow * U * (1 - RF) = 3.333% * 0.5 * 0.9 = 1.5%
        assertApproxEqRel(r.liquidityRate, uint256(r.borrowRate) * 45 / 100, 1e9);
    }

    function test_borrowIndexCompoundsAtStoredRate() public {
        _borrow(bob, usdc, 50_000e6);
        uint256 rate = _reserve(usdc).borrowRate;
        uint256 t0 = block.timestamp;
        _warpAndRefresh(180 days);

        vm.warp(t0 + 180 days); // compute the expectation at the same timestamp
        uint256 expectedIndex = MathUtils.compoundedInterest(rate, t0).rayMulUp(RAY);
        assertEq(pool.getReserveNormalizedDebt(address(usdc)), expectedIndex);
        assertEq(pool.debtBalanceOf(address(usdc), bob), uint256(50_000e6).rayMulUp(expectedIndex));
    }

    /// @dev Who gets what after a year: borrower pays I, suppliers + treasury receive <= I, and the
    ///      treasury's share is exactly the reserve factor of the interest.
    function test_interestSplit_suppliersTreasuryBorrower() public {
        _borrow(bob, usdc, 50_000e6);
        _warpAndRefresh(365 days);
        _supply(carol, usdc, 1e6); // touch the reserve so accrual is written

        uint256 borrowerInterest = pool.debtBalanceOf(address(usdc), bob) - 50_000e6;
        uint256 supplierInterest = pool.supplyBalanceOf(address(usdc), alice) - 100_000e6;
        uint256 treasury = pool.treasuryBalance(address(usdc));

        assertGt(borrowerInterest, 1650e6); // ~3.39% compounded on 50k
        assertApproxEqRel(treasury, borrowerInterest / 10, 1e15); //  RF = 10%
        assertLe(supplierInterest + treasury, borrowerInterest); //    never pays out more than it earns
        // linear vs compound gap is the only difference, and it is small
        assertApproxEqRel(supplierInterest + treasury, borrowerInterest, 2e16);
    }

    function test_solvency_afterYearsOfAccrual() public {
        _borrow(bob, usdc, 80_000e6);
        for (uint256 i; i < 10; ++i) {
            _warpAndRefresh(180 days);
            _repay(bob, usdc, 1e6); // periodic touches compound the supply side too
        }
        DataTypes.ReserveData memory r = _reserve(usdc);
        uint256 assets = uint256(r.cash) + pool.totalBorrowed(address(usdc));
        assertGe(assets, pool.totalSupplied(address(usdc)));
    }

    /// @dev Indexes are only ever multiplied by factors >= 1.
    function test_indexesMonotonic() public {
        _borrow(bob, usdc, 90_000e6);
        uint256 li;
        uint256 bi;
        for (uint256 i; i < 20; ++i) {
            _warpAndRefresh(3 days);
            _repay(bob, usdc, 100e6);
            DataTypes.ReserveData memory r = _reserve(usdc);
            assertGe(r.liquidityIndex, li);
            assertGe(r.borrowIndex, bi);
            (li, bi) = (r.liquidityIndex, r.borrowIndex);
        }
    }

    /// @dev Swapping the rate model must not re-price time that already elapsed.
    function test_rateModelSwap_accruesAtOldRateFirst() public {
        _borrow(bob, usdc, 50_000e6);
        uint256 oldRate = _reserve(usdc).borrowRate;
        uint256 t0 = block.timestamp;
        _warpAndRefresh(100 days);

        KinkedInterestRateModel expensive = new KinkedInterestRateModel(50e25, 50e25, 100e25, 80e25);
        vm.prank(admin);
        configurator.setInterestRateModel(address(usdc), address(expensive));

        uint256 expectedIndex = MathUtils.compoundedInterest(oldRate, t0).rayMulUp(RAY);
        assertEq(_reserve(usdc).borrowIndex, expectedIndex); // accrued with the OLD model
        assertEq(_reserve(usdc).interestRateModel, address(expensive));
        assertGt(_reserve(usdc).borrowRate, oldRate); // next interval priced by the new one
    }

    /// @dev A reserve-factor change applies only from now on.
    function test_reserveFactorChange_isNotRetroactive() public {
        _borrow(bob, usdc, 50_000e6);
        _warpAndRefresh(365 days);
        uint256 treasuryBefore = pool.treasuryBalance(address(usdc));

        vm.prank(admin);
        configurator.setReserveFactor(address(usdc), 5000);
        // the year that elapsed was credited at 10%, not 50%
        assertApproxEqAbs(pool.treasuryBalance(address(usdc)), treasuryBefore, 1);
    }

    function test_treasuryBalanceView_matchesAccruedState() public {
        _borrow(bob, usdc, 50_000e6);
        _warpAndRefresh(200 days);
        uint256 viewBefore = pool.treasuryBalance(address(usdc));
        _supply(carol, usdc, 1e6); // writes the accrual
        assertApproxEqAbs(pool.treasuryBalance(address(usdc)), viewBefore, 1);
    }

    /// @dev Regression for bug #4 (found by the invariant suite): between interactions, the
    ///      liabilities view must already include the treasury's share of pending interest.
    ///      Otherwise it overstates solvency until someone touches the reserve.
    function test_totalSuppliedView_includesPendingTreasuryAccrual() public {
        _borrow(bob, usdc, 90_000e6);
        _warpAndRefresh(90 days);
        uint256 viewBefore = pool.totalSupplied(address(usdc));
        _supply(carol, usdc, 1e6); // writes the accrual
        assertApproxEqAbs(pool.totalSupplied(address(usdc)) - 1e6, viewBefore, 2);
    }

    function test_withdrawReserves_toTreasury() public {
        _borrow(bob, usdc, 50_000e6);
        _warpAndRefresh(365 days);
        _repay(bob, usdc, 10_000e6);
        address treasury = makeAddr("treasury");
        uint256 accrued = pool.treasuryBalance(address(usdc));

        vm.prank(admin);
        uint256 out = configurator.withdrawReserves(address(usdc), type(uint256).max, treasury);
        assertEq(out, accrued);
        assertEq(usdc.balanceOf(treasury), accrued);
        assertEq(pool.treasuryBalance(address(usdc)), 0);
    }
}
