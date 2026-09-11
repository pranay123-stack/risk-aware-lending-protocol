// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title UserConfiguration
/// @notice Bitmap of a user's exposure: bit 2i = borrowing reserve i, bit 2i+1 = reserve i used as
///         collateral. One SLOAD tells the risk engine which reserves to price, so accounts pay
///         (and depend on oracles) only for the markets they actually touch.
library UserConfiguration {
    /// @dev Every even bit set: the "borrowing" half of each 2-bit pair.
    uint256 internal constant BORROWING_MASK =
        0x5555555555555555555555555555555555555555555555555555555555555555;
    /// @dev Every odd bit set: the "collateral" half of each 2-bit pair.
    uint256 internal constant COLLATERAL_MASK =
        0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;

    function setBorrowing(uint256 cfg, uint256 id, bool borrowing) internal pure returns (uint256) {
        // Intentional: shift the literal 1 into bit position 2*id (not a swapped-operand bug).
        // forge-lint: disable-next-line(incorrect-shift)
        uint256 bit = 1 << (id << 1);
        return borrowing ? cfg | bit : cfg & ~bit;
    }

    function setCollateral(uint256 cfg, uint256 id, bool enabled) internal pure returns (uint256) {
        // forge-lint: disable-next-line(incorrect-shift)
        uint256 bit = 1 << ((id << 1) + 1);
        return enabled ? cfg | bit : cfg & ~bit;
    }

    function isBorrowing(uint256 cfg, uint256 id) internal pure returns (bool) {
        return (cfg >> (id << 1)) & 1 != 0;
    }

    function isCollateral(uint256 cfg, uint256 id) internal pure returns (bool) {
        return (cfg >> ((id << 1) + 1)) & 1 != 0;
    }

    function isBorrowingAny(uint256 cfg) internal pure returns (bool) {
        return cfg & BORROWING_MASK != 0;
    }

    function hasCollateralAny(uint256 cfg) internal pure returns (bool) {
        return cfg & COLLATERAL_MASK != 0;
    }
}
