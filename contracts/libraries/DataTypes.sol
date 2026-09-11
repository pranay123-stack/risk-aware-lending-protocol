// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title DataTypes
/// @notice Storage layout for reserves and user positions. Field order is chosen for slot packing;
///         see docs/architecture.md#3-storage-model before reordering anything.
library DataTypes {
    /// @notice Risk and lifecycle parameters of one reserve. Packs into a single slot (240 bits).
    struct ReserveConfig {
        uint16 ltv; //                  bps; max borrow power granted by this collateral
        uint16 liquidationThreshold; // bps; collateral weight in the health factor
        uint16 liquidationBonus; //     bps paid to liquidators on top of repaid value (500 = 5%)
        uint16 reserveFactor; //        bps of borrower interest kept by the protocol
        uint8 decimals; //              underlying token decimals, immutable after listing
        bool active; //                 listed and usable
        bool frozen; //                 no new supply / borrow; exits and liquidations still allowed
        bool paused; //                 everything except repay halted
        bool borrowingEnabled;
        bool collateralEnabled; //      users may enable this reserve as collateral
        uint64 supplyCap; //            whole tokens, 0 = uncapped
        uint64 borrowCap; //            whole tokens, 0 = uncapped
    }

    struct ReserveData {
        ReserveConfig config; //        slot 0
        uint128 liquidityIndex; //      slot 1, ray, cumulative supply growth
        uint128 borrowIndex; //                  ray, cumulative debt growth
        uint128 liquidityRate; //       slot 2, ray / year
        uint128 borrowRate; //                   ray / year
        uint128 totalScaledSupply; //   slot 3
        uint128 totalScaledDebt;
        uint128 cash; //                slot 4, internally tracked liquidity (never balanceOf)
        uint128 accruedToTreasury; //            scaled supply owed to the protocol (first-loss buffer)
        uint128 deficit; //             slot 5, recognised bad debt not yet recapitalised, underlying units
        address interestRateModel; //   slot 6
        uint40 lastUpdateTimestamp;
        uint16 id;
    }

    /// @notice One user's position in one reserve. Both legs share a slot so valuation is one SLOAD.
    struct UserReserve {
        uint128 scaledSupply;
        uint128 scaledDebt;
    }

    /// @notice Result of valuing an account at current oracle prices. All values are 18-decimal USD.
    struct AccountData {
        uint256 totalCollateralValue;
        uint256 totalDebtValue;
        uint256 borrowCapacityValue; //    sum(collateral_i * ltv_i)
        uint256 liquidationValue; //       sum(collateral_i * liquidationThreshold_i)
        uint256 healthFactor; //           liquidationValue / totalDebtValue, 1e18 = 1.0
    }
}
