// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DataTypes} from "../libraries/DataTypes.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title ValidationLogic
/// @notice Stateless precondition checks shared by the pool's entry points.
///
/// Emergency action matrix (enforced here and in LiquidationLogic):
///
///   action          | pool paused | reserve paused | reserve frozen
///   ----------------|-------------|----------------|---------------
///   supply          |   blocked   |    blocked     |    blocked
///   withdraw        |   blocked   |    blocked     |    allowed
///   borrow          |   blocked   |    blocked     |    blocked
///   repay           |   allowed   |    allowed     |    allowed
///   liquidate       |   blocked   |    blocked     |    allowed
///   enable collat.  |   blocked   |    blocked     |    blocked
///   disable collat. |   blocked   |    blocked     |    allowed
///
/// Repay is never blocked: it only lowers risk, and interest keeps accruing during a pause.
/// Frozen reserves wind down: no new exposure, but every exit and liquidation still works.
library ValidationLogic {
    function validateSupply(
        DataTypes.ReserveConfig memory c,
        uint256 amount,
        address onBehalfOf,
        bool poolPaused
    ) internal pure {
        if (amount == 0) revert Errors.ZeroAmount();
        if (onBehalfOf == address(0)) revert Errors.ZeroAddress();
        _requireOperational(c, poolPaused);
        if (c.frozen) revert Errors.ReserveFrozen();
    }

    function validateWithdraw(DataTypes.ReserveConfig memory c, uint256 amount, address to, bool poolPaused)
        internal
        pure
    {
        if (amount == 0) revert Errors.ZeroAmount();
        if (to == address(0)) revert Errors.ZeroAddress();
        _requireOperational(c, poolPaused);
    }

    function validateBorrow(DataTypes.ReserveConfig memory c, uint256 amount, bool poolPaused) internal pure {
        if (amount == 0) revert Errors.ZeroAmount();
        _requireOperational(c, poolPaused);
        if (c.frozen) revert Errors.ReserveFrozen();
        if (!c.borrowingEnabled) revert Errors.BorrowingNotEnabled();
    }

    function validateRepay(DataTypes.ReserveConfig memory c, uint256 amount, address onBehalfOf)
        internal
        pure
    {
        if (amount == 0) revert Errors.ZeroAmount();
        if (onBehalfOf == address(0)) revert Errors.ZeroAddress();
        if (!c.active) revert Errors.ReserveNotActive();
    }

    function validateSetCollateral(DataTypes.ReserveConfig memory c, bool enable, bool poolPaused)
        internal
        pure
    {
        _requireOperational(c, poolPaused);
        if (enable) {
            if (c.frozen) revert Errors.ReserveFrozen();
            if (!c.collateralEnabled || c.liquidationThreshold == 0) {
                revert Errors.CollateralNotEnabledForReserve();
            }
        }
    }

    /// @dev Checks that apply to both reserves involved in a liquidation.
    function validateLiquidationReserve(DataTypes.ReserveConfig memory c) internal pure {
        if (!c.active) revert Errors.ReserveNotActive();
        if (c.paused) revert Errors.ReservePaused();
    }

    function _requireOperational(DataTypes.ReserveConfig memory c, bool poolPaused) private pure {
        if (!c.active) revert Errors.ReserveNotActive();
        if (poolPaused) revert Errors.PoolPaused();
        if (c.paused) revert Errors.ReservePaused();
    }
}
