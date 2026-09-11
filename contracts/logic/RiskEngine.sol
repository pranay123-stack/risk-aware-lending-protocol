// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleManager} from "../interfaces/IOracleManager.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {Errors} from "../libraries/Errors.sol";
import {PercentageMath} from "../libraries/PercentageMath.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";
import {ReserveLogic} from "./ReserveLogic.sol";

/// @title RiskEngine
/// @notice Values an account at validated oracle prices and enforces borrowing power.
///
///   collateralValue_i = supplyBalance_i * price_i / 10^decimals_i        (rounded down)
///   debtValue_i       = debtBalance_i   * price_i / 10^decimals_i        (rounded up)
///   borrowCapacity    = sum(collateralValue_i * LTV_i)
///   liquidationValue  = sum(collateralValue_i * LT_i)
///   healthFactor      = liquidationValue / totalDebtValue                 (1e18 = 1.0)
///
/// Prices come only from the OracleManager, never from users. Only reserves flagged in the user's
/// bitmap are priced, so an account is exposed only to the oracles of markets it actually uses.
library RiskEngine {
    using WadRayMath for uint256;
    using ReserveLogic for DataTypes.ReserveData;

    uint256 internal constant HEALTH_FACTOR_ONE = 1e18;

    /// @notice Prices captured for two reserve ids while valuing an account (0 = not encountered).
    struct PriceCapture {
        uint256 idA;
        uint256 idB;
        uint256 priceA;
        uint256 priceB;
    }

    /// @notice Value `user`'s whole account at current prices. Reverts if any exposed price is invalid.
    function calculateAccountData(
        mapping(address => DataTypes.ReserveData) storage reserves,
        mapping(uint256 => address) storage reservesList,
        mapping(uint256 => DataTypes.UserReserve) storage userReserves,
        uint256 userConfig,
        IOracleManager oracle
    ) internal view returns (DataTypes.AccountData memory data) {
        PriceCapture memory none = PriceCapture({
            idA: type(uint256).max, idB: type(uint256).max, priceA: 0, priceB: 0
        });
        return calculateAccountData(reserves, reservesList, userReserves, userConfig, oracle, none);
    }

    /// @notice Same valuation, also capturing the prices of `capture.idA` / `capture.idB` as they are
    ///         read. Liquidation reuses them instead of calling the oracle a second time: one
    ///         validated price per asset per transaction, ~14k gas saved (docs/gas-report.md).
    function calculateAccountData(
        mapping(address => DataTypes.ReserveData) storage reserves,
        mapping(uint256 => address) storage reservesList,
        mapping(uint256 => DataTypes.UserReserve) storage userReserves,
        uint256 userConfig,
        IOracleManager oracle,
        PriceCapture memory capture
    ) internal view returns (DataTypes.AccountData memory data) {
        uint256 cfg = userConfig;
        uint256 id;
        while (cfg != 0) {
            if (cfg & 3 != 0) {
                address asset = reservesList[id];
                DataTypes.ReserveData storage r = reserves[asset];
                DataTypes.UserReserve memory ur = userReserves[id];

                bool isCollateral = cfg & 2 != 0 && ur.scaledSupply != 0;
                bool isBorrowing = cfg & 1 != 0 && ur.scaledDebt != 0;

                if (isCollateral || isBorrowing) {
                    uint256 price = oracle.getPrice(asset);
                    if (id == capture.idA) capture.priceA = price;
                    if (id == capture.idB) capture.priceB = price;
                    uint256 unit = 10 ** r.config.decimals;

                    if (isCollateral) {
                        uint256 balance = uint256(ur.scaledSupply).rayMulDown(r.normalizedIncome());
                        uint256 value = (balance * price) / unit;
                        data.totalCollateralValue += value;
                        data.borrowCapacityValue += value * r.config.ltv;
                        data.liquidationValue += value * r.config.liquidationThreshold;
                    }
                    if (isBorrowing) {
                        uint256 debt = uint256(ur.scaledDebt).rayMulUp(r.normalizedDebt());
                        data.totalDebtValue += WadRayMath.divUp(debt * price, unit);
                    }
                }
            }
            cfg >>= 2;
            unchecked {
                ++id;
            }
        }

        // Accumulated as value * bps above to avoid one rounding step per reserve.
        data.borrowCapacityValue /= PercentageMath.PERCENTAGE_FACTOR;
        data.liquidationValue /= PercentageMath.PERCENTAGE_FACTOR;
        data.healthFactor = data.totalDebtValue == 0
            ? type(uint256).max
            : data.liquidationValue.wadDivDown(data.totalDebtValue);
    }

    /// @notice Revert unless the account's debt fits inside its LTV-weighted borrowing capacity.
    /// @dev Called after the state change (effects-then-check); a revert undoes the action.
    ///      Because LTV < LT for every listed asset, passing implies HF >= LT/LTV > 1.
    function requireWithinBorrowCapacity(
        mapping(address => DataTypes.ReserveData) storage reserves,
        mapping(uint256 => address) storage reservesList,
        mapping(uint256 => DataTypes.UserReserve) storage userReserves,
        uint256 userConfig,
        IOracleManager oracle
    ) internal view {
        DataTypes.AccountData memory data =
            calculateAccountData(reserves, reservesList, userReserves, userConfig, oracle);
        if (data.totalDebtValue > data.borrowCapacityValue) revert Errors.BorrowCapacityExceeded();
    }
}
