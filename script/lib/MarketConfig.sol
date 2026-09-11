// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MarketConfig
/// @notice Demo market parameters, the single source for both the deploy script and the test
///         fixture, so tests always exercise what actually gets deployed.
///         Rationale for every number: docs/economics.md#5-demo-parameters.
library MarketConfig {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant PCT = 1e25; // 1% in ray

    struct MarketSpec {
        // token
        string name;
        string symbol;
        uint8 decimals;
        uint256 faucetLimit; //       whole tokens per mint call
        // oracle
        int256 price; //              8-decimal USD (Chainlink convention)
        uint32 heartbeat;
        bool withSecondary; //        second independent feed with 18 decimals
        uint16 maxDeviationBps;
        uint128 minPrice; //          1e18 USD
        uint128 maxPrice;
        // interest rate model (ray / year)
        uint256 baseRate;
        uint256 slope1;
        uint256 slope2;
        uint256 optimalUtilization;
        // risk (bps)
        uint16 ltv;
        uint16 liquidationThreshold;
        uint16 liquidationBonus;
        uint16 reserveFactor;
        uint64 supplyCap; //          whole tokens
        uint64 borrowCap;
        bool borrowingEnabled;
        bool collateralEnabled;
    }

    /// @notice Volatile, deep-liquidity collateral. Moderate kink at 80%.
    function weth() internal pure returns (MarketSpec memory) {
        return MarketSpec({
            name: "Mock Wrapped Ether",
            symbol: "WETH",
            decimals: 18,
            faucetLimit: 1000,
            price: 2500e8,
            heartbeat: 1 hours,
            withSecondary: true,
            maxDeviationBps: 300, // 3%
            minPrice: 100e18,
            maxPrice: 1_000_000e18,
            baseRate: 0,
            slope1: 4 * PCT,
            slope2: 80 * PCT,
            optimalUtilization: 80 * PCT,
            ltv: 8000,
            liquidationThreshold: 8250,
            liquidationBonus: 500,
            reserveFactor: 1500,
            supplyCap: 100_000,
            borrowCap: 80_000,
            borrowingEnabled: true,
            collateralEnabled: true
        });
    }

    /// @notice Volatile collateral with thinner on-chain liquidity: lower LTV, larger bonus, early
    ///         and very steep kink so its borrow side cannot be drained cheaply.
    function wbtc() internal pure returns (MarketSpec memory) {
        return MarketSpec({
            name: "Mock Wrapped Bitcoin",
            symbol: "WBTC",
            decimals: 8,
            faucetLimit: 50,
            price: 60_000e8,
            heartbeat: 1 hours,
            withSecondary: false,
            maxDeviationBps: 0,
            minPrice: 1000e18,
            maxPrice: 10_000_000e18,
            baseRate: 0,
            slope1: 4 * PCT,
            slope2: 300 * PCT,
            optimalUtilization: 45 * PCT,
            ltv: 7300,
            liquidationThreshold: 7800,
            liquidationBonus: 650,
            reserveFactor: 2000,
            supplyCap: 5000,
            borrowCap: 2500,
            borrowingEnabled: true,
            collateralEnabled: true
        });
    }

    /// @notice Stablecoin: the main borrow asset. High kink (90%) because stable borrow demand is
    ///         price-sensitive and utilization should run hot; wide sanity bounds because a depeg
    ///         must be *priced*, not hidden behind a hard-coded $1.
    function usdc() internal pure returns (MarketSpec memory) {
        return MarketSpec({
            name: "Mock USD Coin",
            symbol: "USDC",
            decimals: 6,
            faucetLimit: 1_000_000,
            price: 1e8,
            heartbeat: 1 days,
            withSecondary: false,
            maxDeviationBps: 0,
            minPrice: 0.5e18,
            maxPrice: 2e18,
            baseRate: 0,
            slope1: 6 * PCT,
            slope2: 60 * PCT,
            optimalUtilization: 90 * PCT,
            ltv: 7700,
            liquidationThreshold: 8000,
            liquidationBonus: 450,
            reserveFactor: 1000,
            supplyCap: 100_000_000,
            borrowCap: 90_000_000,
            borrowingEnabled: true,
            collateralEnabled: true
        });
    }
}
