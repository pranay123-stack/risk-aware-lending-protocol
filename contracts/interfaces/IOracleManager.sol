// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";

/// @title IOracleManager
/// @notice Validated USD prices (18 decimals per whole token). `getPrice` fails closed;
///         `getPriceState` never reverts and exists for monitoring.
interface IOracleManager {
    /// @notice Health of a single feed read.
    enum FeedStatus {
        NOT_CONFIGURED,
        OK,
        CALL_FAILED, //        feed reverted (deprecated / access-controlled / not a feed)
        INVALID_ANSWER, //     answer <= 0
        INCOMPLETE_ROUND, //   updatedAt == 0
        FUTURE_TIMESTAMP, //   updatedAt > block.timestamp
        STALE, //              older than the heartbeat
        OUT_OF_BOUNDS //       outside [minPrice, maxPrice], e.g. a feed clamped at its minAnswer
    }

    /// @notice Resolution of an asset price across both sources.
    enum PriceStatus {
        OK, //                 primary healthy and agrees with the healthy secondary
        OK_PRIMARY_ONLY, //    primary healthy, secondary absent or unhealthy (degraded)
        OK_FALLBACK, //        primary unhealthy, secondary healthy (degraded)
        NOT_CONFIGURED,
        PAUSED, //             guardian circuit breaker engaged
        DEVIATION, //          both healthy but disagree beyond maxDeviationBps
        UNAVAILABLE //         no healthy source
    }

    struct AssetOracleConfig {
        AggregatorV3Interface primaryFeed; // slot 0
        uint32 primaryHeartbeat;
        uint8 primaryDecimals;
        uint16 maxDeviationBps;
        bool paused;
        AggregatorV3Interface secondaryFeed; // slot 1
        uint32 secondaryHeartbeat;
        uint8 secondaryDecimals;
        uint128 minPrice; //                  slot 2, 18-decimal USD sanity bounds
        uint128 maxPrice;
    }

    struct PriceState {
        uint256 price; //           resolved price, 0 unless status is OK*
        PriceStatus status;
        FeedStatus primaryStatus;
        FeedStatus secondaryStatus;
        uint256 primaryPrice; //    normalised, 0 if the read failed
        uint256 secondaryPrice;
        uint256 primaryUpdatedAt;
        uint256 secondaryUpdatedAt;
    }

    event AssetOracleConfigured(
        address indexed asset,
        address primaryFeed,
        uint32 primaryHeartbeat,
        address secondaryFeed,
        uint32 secondaryHeartbeat,
        uint16 maxDeviationBps,
        uint128 minPrice,
        uint128 maxPrice
    );
    event AssetOraclePaused(address indexed asset, bool paused);

    function getPrice(address asset) external view returns (uint256);
    function getPriceState(address asset) external view returns (PriceState memory);
    function getAssetConfig(address asset) external view returns (AssetOracleConfig memory);
}
