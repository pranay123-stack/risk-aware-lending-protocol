// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title WadRayMath
/// @notice Fixed-point helpers with an explicit rounding direction on every operation.
/// @dev Every call site states which way it rounds. There is deliberately no "half-up"
///      variant: in a lending protocol the correct direction is always the one that favours the
///      protocol (see docs/architecture.md, "Rounding policy"). Inputs in this codebase are bounded
///      by uint128 storage, so `a * b` cannot overflow uint256 for the ranges used, and checked
///      arithmetic reverts instead of wrapping if that assumption is ever violated.
library WadRayMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD_RAY_RATIO = 1e9;

    function rayMulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / RAY;
    }

    function rayMulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 p = a * b;
        unchecked {
            return p / RAY + (p % RAY == 0 ? 0 : 1);
        }
    }

    function rayDivDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY) / b;
    }

    function rayDivUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 p = a * RAY;
        unchecked {
            return p / b + (p % b == 0 ? 0 : 1);
        }
    }

    function wadMulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    function wadDivDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD) / b;
    }

    /// @dev Integer division rounding up. `b` must be non-zero.
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a / b + (a % b == 0 ? 0 : 1);
        }
    }
}
