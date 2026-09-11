// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IInterestRateModel
/// @notice Maps a reserve's liquidity state to an annual borrow rate (ray). The model is a pure
///         pricing function: it knows nothing about reserve factors or supply-side accounting,
///         which the pool derives from what borrowers actually pay.
interface IInterestRateModel {
    /// @param cash Underlying available to borrow or withdraw.
    /// @param totalDebt Outstanding borrows, including accrued interest.
    /// @return borrowRate Annual variable borrow rate in ray.
    function getBorrowRate(uint256 cash, uint256 totalDebt) external view returns (uint256 borrowRate);

    /// @return utilization totalDebt / (cash + totalDebt) in ray; 0 when there is no debt.
    function utilization(uint256 cash, uint256 totalDebt) external pure returns (uint256);

    function baseRate() external view returns (uint256);
    function slope1() external view returns (uint256);
    function slope2() external view returns (uint256);
    function optimalUtilization() external view returns (uint256);
    function maxBorrowRate() external view returns (uint256);
}
