// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {PercentageMath} from "../libraries/PercentageMath.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ReserveLogic
/// @notice Interest accrual, treasury accrual and rate updates for a single reserve.
///
/// Every state-changing action follows the same shape:
///   1. accrue()       move indexes to `block.timestamp` using the rates stored last time
///   2. mutate balances / cash
///   3. updateRates()  price the *next* interval from the new utilization
/// Skipping (1) would price elapsed time at the new utilization, a retroactive rate change.
/// Skipping (3) would leave stale rates for the next interval. Both are classic accounting bugs.
library ReserveLogic {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeCast for uint256;

    /// @notice Supply index as of now, without writing.
    function normalizedIncome(DataTypes.ReserveData storage r) internal view returns (uint256) {
        uint256 last = r.lastUpdateTimestamp;
        if (last == block.timestamp) return r.liquidityIndex;
        return MathUtils.linearInterest(r.liquidityRate, last).rayMulDown(r.liquidityIndex);
    }

    /// @notice Borrow index as of now, without writing.
    function normalizedDebt(DataTypes.ReserveData storage r) internal view returns (uint256) {
        uint256 last = r.lastUpdateTimestamp;
        if (last == block.timestamp || r.totalScaledDebt == 0) return r.borrowIndex;
        return MathUtils.compoundedInterest(r.borrowRate, last).rayMulUp(r.borrowIndex);
    }

    /// @notice Bring indexes up to date and credit the reserve factor's share of interest.
    /// @dev Idempotent within a block. Indexes are monotonically non-decreasing by construction:
    ///      both growth factors are >= RAY.
    function accrue(DataTypes.ReserveData storage r) internal {
        uint256 last = r.lastUpdateTimestamp;
        if (last == block.timestamp) return;

        uint256 newLiquidityIndex = r.liquidityIndex;
        uint256 liquidityRate = r.liquidityRate;
        if (liquidityRate != 0) {
            newLiquidityIndex = MathUtils.linearInterest(liquidityRate, last).rayMulDown(newLiquidityIndex);
            r.liquidityIndex = newLiquidityIndex.toUint128();
        }

        if (r.totalScaledDebt != 0) {
            uint256 newBorrowIndex = MathUtils.compoundedInterest(r.borrowRate, last).rayMulUp(r.borrowIndex);
            uint256 toTreasuryScaled = _treasuryAccrualScaled(r, newBorrowIndex, newLiquidityIndex);
            r.borrowIndex = newBorrowIndex.toUint128();
            if (toTreasuryScaled != 0) {
                r.accruedToTreasury = (uint256(r.accruedToTreasury) + toTreasuryScaled).toUint128();
            }
        }

        r.lastUpdateTimestamp = uint40(block.timestamp);
    }

    /// @notice Treasury claim (scaled) including the share accrued since the last interaction.
    /// @dev Every view must use this, not the stored `accruedToTreasury`. Otherwise views count
    ///      borrower interest up to now as an asset but omit the treasury's share of it as a
    ///      liability, and overstate solvency between interactions. The invariant suite caught
    ///      exactly that (docs/testing.md, bug #4).
    function treasuryScaledNow(DataTypes.ReserveData storage r) internal view returns (uint256) {
        uint256 stored = r.accruedToTreasury;
        if (r.lastUpdateTimestamp == block.timestamp || r.totalScaledDebt == 0) return stored;
        return stored + _treasuryAccrualScaled(r, normalizedDebt(r), normalizedIncome(r));
    }

    /// @dev Reserve-factor share of the interest accrued between the stored borrow index and
    ///      `newBorrowIndex`, expressed in scaled supply at `newLiquidityIndex`. Shared by accrue()
    ///      and the views so they cannot drift apart. The rounding matches how debts are reported,
    ///      so the treasury never accrues against interest nobody owes.
    function _treasuryAccrualScaled(
        DataTypes.ReserveData storage r,
        uint256 newBorrowIndex,
        uint256 newLiquidityIndex
    ) private view returns (uint256) {
        uint256 reserveFactor = r.config.reserveFactor;
        if (reserveFactor == 0) return 0;
        uint256 scaledDebt = r.totalScaledDebt;
        uint256 interest = scaledDebt.rayMulDown(newBorrowIndex) - scaledDebt.rayMulDown(r.borrowIndex);
        return interest.percentMulDown(reserveFactor).rayDivDown(newLiquidityIndex);
    }

    /// @notice Recompute and store rates from current utilization. Emits `ReserveDataUpdated`.
    /// @dev liquidityRate = borrowRate * (1 - RF) * min(totalDebt / supplyLiabilities, 1)
    ///      With no deficit this equals the textbook borrowRate * U * (1 - RF). The general form
    ///      guarantees suppliers are credited at most what borrowers are charged. The cap at 1
    ///      stops a vanishing supplier base from receiving an unbounded rate on leftover surplus.
    function updateRates(DataTypes.ReserveData storage r, address asset) internal {
        uint256 liquidityIndex = r.liquidityIndex;
        uint256 borrowIndex = r.borrowIndex;
        uint256 totalDebt = uint256(r.totalScaledDebt).rayMulUp(borrowIndex);

        uint256 borrowRate = IInterestRateModel(r.interestRateModel).getBorrowRate(r.cash, totalDebt);

        uint256 liquidityRate;
        if (totalDebt != 0) {
            // Liabilities rounded UP: a larger denominator means a (weakly) lower supply rate.
            uint256 liabilities =
                (uint256(r.totalScaledSupply) + r.accruedToTreasury).rayMulUp(liquidityIndex);
            if (liabilities != 0) {
                uint256 debtRatio = totalDebt.rayDivDown(liabilities);
                if (debtRatio > WadRayMath.RAY) debtRatio = WadRayMath.RAY;
                liquidityRate = borrowRate.rayMulDown(debtRatio)
                    .percentMulDown(PercentageMath.PERCENTAGE_FACTOR - r.config.reserveFactor);
            }
        }

        r.liquidityRate = liquidityRate.toUint128();
        r.borrowRate = borrowRate.toUint128();

        emit ILendingPool.ReserveDataUpdated(asset, liquidityRate, borrowRate, liquidityIndex, borrowIndex);
    }

    /// @notice Everything suppliers (including the treasury) can claim as of now, in underlying units.
    function totalSupplyLiabilities(DataTypes.ReserveData storage r) internal view returns (uint256) {
        return (uint256(r.totalScaledSupply) + treasuryScaledNow(r)).rayMulDown(normalizedIncome(r));
    }
}
