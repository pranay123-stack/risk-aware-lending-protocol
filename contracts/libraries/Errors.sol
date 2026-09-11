// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Errors
/// @notice Every custom error in the protocol. Custom errors cost ~50 gas less than revert strings
///         on the failure path, keep bytecode small, and carry typed context for off-chain decoding.
library Errors {
    // --- access control
    error NotPoolAdmin();
    error NotEmergencyAdmin();
    error NotConfigurator();

    // --- generic input
    error ZeroAddress();
    error ZeroAmount();
    error AmountTooSmall();

    // --- reserve state
    error ReserveNotActive();
    error ReserveFrozen();
    error ReservePaused();
    error PoolPaused();
    error ReserveAlreadyInitialized();
    error MaxReservesReached();
    error BorrowingNotEnabled();
    error CollateralNotEnabledForReserve();
    error SupplyCapExceeded();
    error BorrowCapExceeded();
    error InsufficientLiquidity();

    // --- user state
    error InsufficientBalance();
    error NoDebt();
    error NoSupply();
    error BorrowCapacityExceeded();

    // --- liquidation
    error HealthyPosition();
    error CollateralNotEnabledByUser();
    error LiquidationGracePeriod();
    error MustNotLeaveDust();
    error NothingToLiquidate();

    // --- configuration
    error InvalidRiskParameters();
    error InvalidReserveFactor();
    error InvalidDecimals();
    error InvalidGracePeriod();
    error NoDeficit();
    error InsufficientReserves();

    // --- oracle
    error OracleNotConfigured(address asset);
    error OracleAssetPaused(address asset);
    error OraclePriceUnavailable(address asset);
    error OraclePriceDeviation(address asset, uint256 primaryPrice, uint256 secondaryPrice);
    error InvalidOracleConfig();

    // --- interest rate model
    error InvalidRateModelParams();
}
