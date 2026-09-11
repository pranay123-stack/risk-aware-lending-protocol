// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {Errors} from "../libraries/Errors.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";

/// @title KinkedInterestRateModel
/// @notice Two-slope ("jump") utilization curve:
///
///   U <= U*:  rate = base + slope1 * U / U*
///   U  > U*:  rate = base + slope1 + slope2 * (U - U*) / (1 - U*)
///
/// Below the kink U* borrowing is cheap, so capital gets used. Above it the rate climbs steeply.
/// That pays suppliers to deposit and pushes borrowers to repay, which keeps a liquidity buffer
/// for withdrawals and liquidations. See docs/economics.md.
///
/// @dev Parameters are immutable. A parameter change means deploying a new model and swapping it in
///      through the timelock. The pool accrues interest at the old rate before the swap, so no
///      interval is ever priced retroactively.
contract KinkedInterestRateModel is IInterestRateModel {
    using WadRayMath for uint256;

    /// @notice Upper bound on base + slope1 + slope2 (1000% APR). It bounds index growth: uint128
    ///         ray indexes cannot overflow for years even at 100% utilization. It also rules out
    ///         fat-finger parameters that would liquidate every borrower within hours.
    uint256 public constant MAX_BORROW_RATE = 10 * WadRayMath.RAY;

    uint256 public immutable baseRate;
    uint256 public immutable slope1;
    uint256 public immutable slope2;
    uint256 public immutable optimalUtilization;
    uint256 private immutable _excessUtilizationRange; // RAY - optimalUtilization, cached

    constructor(uint256 baseRate_, uint256 slope1_, uint256 slope2_, uint256 optimalUtilization_) {
        if (optimalUtilization_ == 0 || optimalUtilization_ >= WadRayMath.RAY) {
            revert Errors.InvalidRateModelParams();
        }
        if (baseRate_ + slope1_ + slope2_ > MAX_BORROW_RATE) revert Errors.InvalidRateModelParams();
        baseRate = baseRate_;
        slope1 = slope1_;
        slope2 = slope2_;
        optimalUtilization = optimalUtilization_;
        _excessUtilizationRange = WadRayMath.RAY - optimalUtilization_;
    }

    /// @inheritdoc IInterestRateModel
    function utilization(uint256 cash, uint256 totalDebt) public pure returns (uint256) {
        if (totalDebt == 0) return 0;
        return totalDebt.rayDivDown(cash + totalDebt);
    }

    /// @inheritdoc IInterestRateModel
    function getBorrowRate(uint256 cash, uint256 totalDebt) external view returns (uint256) {
        uint256 u = utilization(cash, totalDebt);
        if (u <= optimalUtilization) {
            return baseRate + slope1.rayMulDown(u.rayDivDown(optimalUtilization));
        }
        uint256 excess = (u - optimalUtilization).rayDivDown(_excessUtilizationRange);
        return baseRate + slope1 + slope2.rayMulDown(excess);
    }

    /// @inheritdoc IInterestRateModel
    function maxBorrowRate() external view returns (uint256) {
        return baseRate + slope1 + slope2;
    }
}
