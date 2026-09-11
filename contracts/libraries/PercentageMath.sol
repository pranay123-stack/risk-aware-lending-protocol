// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title PercentageMath
/// @notice Basis-point arithmetic (10_000 = 100%) with explicit rounding.
library PercentageMath {
    uint256 internal constant PERCENTAGE_FACTOR = 1e4;

    function percentMulDown(uint256 value, uint256 bps) internal pure returns (uint256) {
        return (value * bps) / PERCENTAGE_FACTOR;
    }

    function percentMulUp(uint256 value, uint256 bps) internal pure returns (uint256) {
        uint256 p = value * bps;
        unchecked {
            return p / PERCENTAGE_FACTOR + (p % PERCENTAGE_FACTOR == 0 ? 0 : 1);
        }
    }
}
