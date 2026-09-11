// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WadRayMath} from "./WadRayMath.sol";

/// @title MathUtils
/// @notice Interest accrual factors. Rates are annual, expressed in ray (1e27 = 100% APR).
library MathUtils {
    using WadRayMath for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Simple-interest growth factor `1 + rate * dt / year`, in ray, rounded down.
    /// @dev Used for the supply (liquidity) index. Linear accrual pays suppliers slightly less
    ///      than the compounded accrual charged to borrowers, so the gap is a solvency cushion,
    ///      never a shortfall.
    function linearInterest(uint256 rate, uint256 lastUpdate) internal view returns (uint256) {
        return WadRayMath.RAY + (rate * (block.timestamp - lastUpdate)) / SECONDS_PER_YEAR;
    }

    /// @notice Compound-interest growth factor in ray: third-order Taylor expansion of e^x with
    ///         x = rate * dt / year, i.e. 1 + x + x^2/2 + x^3/6.
    /// @dev Every omitted term is positive, so this slightly under-states continuous compounding
    ///      (error < x^4/24: 4e-6 for 10% APR left untouched for a full year; any interaction resets
    ///      dt). It is always >= the linear factor, which is the inequality the solvency argument
    ///      needs. O(1) in dt.
    ///
    ///      `x` is formed first, and the powers are taken in ray. The widespread binomial form
    ///      computes rate^3 / year^3 as an integer, which truncates to ~31 wei at 10% APR and silently
    ///      under-charges borrowers (the unit test pins this against e^0.1). Overflow bound: rate is at
    ///      most 10 ray (IRM ceiling), so x^3 stays far below 2^256 for any dt under a century.
    function compoundedInterest(uint256 rate, uint256 lastUpdate) internal view returns (uint256) {
        uint256 dt = block.timestamp - lastUpdate;
        if (dt == 0) return WadRayMath.RAY;

        uint256 x = (rate * dt) / SECONDS_PER_YEAR;
        uint256 xSquared = x.rayMulDown(x);
        uint256 xCubed = xSquared.rayMulDown(x);

        return WadRayMath.RAY + x + xSquared / 2 + xCubed / 6;
    }
}
