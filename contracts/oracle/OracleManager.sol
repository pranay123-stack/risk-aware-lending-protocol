// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IOracleManager} from "../interfaces/IOracleManager.sol";
import {Errors} from "../libraries/Errors.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title OracleManager
/// @notice Turns raw Chainlink-style feeds into validated 18-decimal USD prices.
///
/// Validation pipeline, per feed:
///   answer > 0, answer <= 2^128, updatedAt != 0, updatedAt <= now, now - updatedAt <= heartbeat,
///   normalise decimals -> 1e18, minPrice <= price <= maxPrice.
/// Resolution across feeds:
///   both healthy          -> must agree within maxDeviationBps, else DEVIATION (revert)
///   only primary healthy  -> primary (degraded if a secondary is configured)
///   only secondary healthy-> secondary (fallback)
///   none healthy / paused -> revert
///
/// @dev Deliberately view-only: there is no stored "last good price". A stateful breaker would add
///      an SSTORE to every pool action and a keeper dependency. The cross-source deviation check is
///      what defends against a single manipulated or malfunctioning source. A last-good-price
///      comparison would instead freeze the market after every genuine crash.
///      See docs/oracles.md for the full threat analysis.
contract OracleManager is IOracleManager {
    uint256 internal constant BPS = 1e4;
    uint32 public constant MAX_HEARTBEAT = 2 days;
    uint16 public constant MAX_DEVIATION_BPS = 2000; // 20%
    uint8 internal constant MAX_FEED_DECIMALS = 36;

    IACLManager public immutable ACL;

    mapping(address asset => AssetOracleConfig) internal _configs;

    modifier onlyPoolAdmin() {
        _onlyPoolAdmin();
        _;
    }

    modifier onlyEmergencyOrPoolAdmin() {
        _onlyEmergencyOrPoolAdmin();
        _;
    }

    constructor(IACLManager acl) {
        if (address(acl) == address(0)) revert Errors.ZeroAddress();
        ACL = acl;
    }

    // ================================================================== admin

    /// @notice Configure (or reconfigure) an asset's price sources. Timelocked in production:
    ///         the oracle is the single most security-critical dependency of the pool.
    /// @param secondary Optional independent source; address(0) disables cross-checking.
    /// @param maxDeviationBps Maximum allowed primary/secondary disagreement, relative to the lower
    ///        of the two prices. Required when a secondary is set.
    /// @param minPrice Lowest plausible price (1e18 USD). Catches feeds clamped at their minAnswer.
    /// @param maxPrice Highest plausible price (1e18 USD).
    function setAssetOracle(
        address asset,
        AggregatorV3Interface primary,
        uint32 primaryHeartbeat,
        AggregatorV3Interface secondary,
        uint32 secondaryHeartbeat,
        uint16 maxDeviationBps,
        uint128 minPrice,
        uint128 maxPrice
    ) external onlyPoolAdmin {
        if (asset == address(0) || address(primary) == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (primaryHeartbeat == 0 || primaryHeartbeat > MAX_HEARTBEAT) revert Errors.InvalidOracleConfig();
        if (minPrice == 0 || minPrice >= maxPrice) revert Errors.InvalidOracleConfig();

        uint8 primaryDecimals = primary.decimals();
        if (primaryDecimals > MAX_FEED_DECIMALS) revert Errors.InvalidOracleConfig();

        uint8 secondaryDecimals;
        if (address(secondary) != address(0)) {
            if (secondary == primary) revert Errors.InvalidOracleConfig();
            if (secondaryHeartbeat == 0 || secondaryHeartbeat > MAX_HEARTBEAT) {
                revert Errors.InvalidOracleConfig();
            }
            if (maxDeviationBps == 0 || maxDeviationBps > MAX_DEVIATION_BPS) {
                revert Errors.InvalidOracleConfig();
            }
            secondaryDecimals = secondary.decimals();
            if (secondaryDecimals > MAX_FEED_DECIMALS) revert Errors.InvalidOracleConfig();
        } else if (secondaryHeartbeat != 0 || maxDeviationBps != 0) {
            revert Errors.InvalidOracleConfig();
        }

        bool wasPaused = _configs[asset].paused;
        _configs[asset] = AssetOracleConfig({
            primaryFeed: primary,
            primaryHeartbeat: primaryHeartbeat,
            primaryDecimals: primaryDecimals,
            maxDeviationBps: maxDeviationBps,
            paused: wasPaused, // reconfiguring must not silently lift a guardian pause
            secondaryFeed: secondary,
            secondaryHeartbeat: secondaryHeartbeat,
            secondaryDecimals: secondaryDecimals,
            minPrice: minPrice,
            maxPrice: maxPrice
        });

        emit AssetOracleConfigured(
            asset,
            address(primary),
            primaryHeartbeat,
            address(secondary),
            secondaryHeartbeat,
            maxDeviationBps,
            minPrice,
            maxPrice
        );
    }

    /// @notice Manual circuit breaker. While paused, every price read for the asset reverts, which
    ///         halts borrows, collateral withdrawals and liquidations for exposed accounts only.
    function setAssetPaused(address asset, bool paused) external onlyEmergencyOrPoolAdmin {
        if (address(_configs[asset].primaryFeed) == address(0)) revert Errors.OracleNotConfigured(asset);
        _configs[asset].paused = paused;
        emit AssetOraclePaused(asset, paused);
    }

    // ================================================================== reads

    /// @inheritdoc IOracleManager
    function getPrice(address asset) external view returns (uint256) {
        PriceState memory s = _evaluate(asset);
        PriceStatus status = s.status;
        if (
            status == PriceStatus.OK || status == PriceStatus.OK_PRIMARY_ONLY
                || status == PriceStatus.OK_FALLBACK
        ) {
            return s.price;
        }
        if (status == PriceStatus.NOT_CONFIGURED) revert Errors.OracleNotConfigured(asset);
        if (status == PriceStatus.PAUSED) revert Errors.OracleAssetPaused(asset);
        if (status == PriceStatus.DEVIATION) {
            revert Errors.OraclePriceDeviation(asset, s.primaryPrice, s.secondaryPrice);
        }
        revert Errors.OraclePriceUnavailable(asset);
    }

    /// @inheritdoc IOracleManager
    function getPriceState(address asset) external view returns (PriceState memory) {
        return _evaluate(asset);
    }

    /// @inheritdoc IOracleManager
    function getAssetConfig(address asset) external view returns (AssetOracleConfig memory) {
        return _configs[asset];
    }

    // ================================================================== internals

    function _onlyPoolAdmin() internal view {
        if (!ACL.hasRole(Roles.POOL_ADMIN, msg.sender)) revert Errors.NotPoolAdmin();
    }

    function _onlyEmergencyOrPoolAdmin() internal view {
        if (!ACL.hasRole(Roles.EMERGENCY_ADMIN, msg.sender) && !ACL.hasRole(Roles.POOL_ADMIN, msg.sender)) {
            revert Errors.NotEmergencyAdmin();
        }
    }

    function _evaluate(address asset) internal view returns (PriceState memory s) {
        AssetOracleConfig memory c = _configs[asset];
        if (address(c.primaryFeed) == address(0)) {
            s.status = PriceStatus.NOT_CONFIGURED;
            return s;
        }

        (s.primaryStatus, s.primaryPrice, s.primaryUpdatedAt) =
            _readFeed(c.primaryFeed, c.primaryDecimals, c.primaryHeartbeat, c.minPrice, c.maxPrice);
        (s.secondaryStatus, s.secondaryPrice, s.secondaryUpdatedAt) =
            _readFeed(c.secondaryFeed, c.secondaryDecimals, c.secondaryHeartbeat, c.minPrice, c.maxPrice);

        if (c.paused) {
            s.status = PriceStatus.PAUSED;
            return s;
        }

        bool primaryOk = s.primaryStatus == FeedStatus.OK;
        bool secondaryOk = s.secondaryStatus == FeedStatus.OK;

        if (primaryOk && secondaryOk) {
            if (_deviates(s.primaryPrice, s.secondaryPrice, c.maxDeviationBps)) {
                s.status = PriceStatus.DEVIATION;
            } else {
                s.status = PriceStatus.OK;
                s.price = s.primaryPrice;
            }
        } else if (primaryOk) {
            s.status =
                s.secondaryStatus == FeedStatus.NOT_CONFIGURED ? PriceStatus.OK : PriceStatus.OK_PRIMARY_ONLY;
            s.price = s.primaryPrice;
        } else if (secondaryOk) {
            s.status = PriceStatus.OK_FALLBACK;
            s.price = s.secondaryPrice;
        } else {
            s.status = PriceStatus.UNAVAILABLE;
        }
    }

    /// @dev Reads and validates one feed. A reverting feed is reported, not propagated, so the
    ///      other source can take over. The price is still returned for STALE / OUT_OF_BOUNDS
    ///      reads so monitoring can show what the feed is saying.
    function _readFeed(
        AggregatorV3Interface feed,
        uint8 feedDecimals,
        uint32 heartbeat,
        uint128 minPrice,
        uint128 maxPrice
    ) internal view returns (FeedStatus, uint256 price, uint256 updatedAt) {
        if (address(feed) == address(0)) return (FeedStatus.NOT_CONFIGURED, 0, 0);

        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updated, uint80) {
            // Bounded before normalisation so the multiplication below cannot overflow.
            // The cast only runs when answer > 0 (short-circuit), so it cannot wrap.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (answer <= 0 || uint256(answer) > type(uint128).max) {
                return (FeedStatus.INVALID_ANSWER, 0, updated);
            }
            if (updated == 0) return (FeedStatus.INCOMPLETE_ROUND, 0, 0);
            if (updated > block.timestamp) return (FeedStatus.FUTURE_TIMESTAMP, 0, updated);

            // answer is in (0, 2^128] here.
            // forge-lint: disable-next-line(unsafe-typecast)
            price = _normalize(uint256(answer), feedDecimals);
            if (block.timestamp - updated > heartbeat) return (FeedStatus.STALE, price, updated);
            if (price < minPrice || price > maxPrice) return (FeedStatus.OUT_OF_BOUNDS, price, updated);
            return (FeedStatus.OK, price, updated);
        } catch {
            return (FeedStatus.CALL_FAILED, 0, 0);
        }
    }

    function _normalize(uint256 answer, uint8 feedDecimals) internal pure returns (uint256) {
        if (feedDecimals == 18) return answer;
        if (feedDecimals < 18) return answer * 10 ** (18 - feedDecimals);
        return answer / 10 ** (feedDecimals - 18);
    }

    /// @dev Deviation relative to the lower price, the stricter of the two symmetric choices.
    function _deviates(uint256 a, uint256 b, uint16 maxDeviationBps) internal pure returns (bool) {
        uint256 diff = a > b ? a - b : b - a;
        uint256 lower = a < b ? a : b;
        return diff * BPS > lower * maxDeviationBps;
    }
}
