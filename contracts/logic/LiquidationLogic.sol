// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IOracleManager} from "../interfaces/IOracleManager.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {Errors} from "../libraries/Errors.sol";
import {PercentageMath} from "../libraries/PercentageMath.sol";
import {UserConfiguration} from "../libraries/UserConfiguration.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";
import {ReserveLogic} from "./ReserveLogic.sol";
import {RiskEngine} from "./RiskEngine.sol";
import {ValidationLogic} from "./ValidationLogic.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LiquidationLogic
/// @notice Permissionless liquidation of accounts with health factor < 1, plus bad-debt recognition.
///
///   debtRepaid       = min(debtToCover, borrowerDebt * closeFactor)
///   collateralSeized = debtRepaid * P_debt / P_coll * (1 + bonus)       (capped at borrower balance)
///
/// Close factor is 50%, or 100% when HF < 0.95 or either leg of the position is worth less than
/// $2,000. Deeply unhealthy or small positions must be closable in one call, otherwise they
/// linger as unprofitable dust and become bad debt.
///
/// A partial liquidation may not leave less than $1,000 of debt or collateral behind (the
/// "dust rule"). The liquidator must close the leg entirely instead.
///
/// If the borrower is left with no collateral anywhere but still owes debt, that debt is written
/// off: it is absorbed by the reserve's treasury accrual first, and the rest is recorded as `deficit`.
///
/// @dev `executeLiquidation` is `external`: the library is deployed once and the pool reaches it by
///      DELEGATECALL, so it runs on the pool's storage and emits from the pool's address. That keeps
///      the pool under the EIP-170 24 KiB limit, at the cost of ~2.6k gas per liquidation. This is
///      the same split Aave v3 uses. `calculateAmounts` stays `internal` so PoolLens inlines it.
library LiquidationLogic {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using UserConfiguration for uint256;
    using ReserveLogic for DataTypes.ReserveData;

    uint256 internal constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18;
    uint256 internal constant DEFAULT_CLOSE_FACTOR = 5000;
    uint256 internal constant MAX_CLOSE_FACTOR = 10_000;
    uint256 internal constant SMALL_POSITION_VALUE = 2000e18;
    uint256 internal constant MIN_LEFTOVER_VALUE = 1000e18;

    /// @dev There is deliberately no `liquidator` field. The library runs via DELEGATECALL, so
    ///      `msg.sender` is the pool's caller, and funds can only ever be pulled from the account
    ///      that initiated the liquidation. (Solidity also blocks direct CALLs into state-changing
    ///      external library functions.)
    struct LiquidationParams {
        address collateralAsset;
        address debtAsset;
        address borrower;
        uint256 debtToCover;
        bool receiveSupply;
    }

    struct LiquidationVars {
        uint256 debtId;
        uint256 collateralId;
        uint256 healthFactor;
        uint256 debtPrice;
        uint256 collateralPrice;
        uint256 borrowerDebt;
        uint256 borrowerCollateral;
        uint256 closeFactor;
        uint256 debtRepaid;
        uint256 collateralSeized;
        uint256 debtBurn;
        uint256 collateralBurn;
        uint256 touched;
    }

    function executeLiquidation(
        mapping(address => DataTypes.ReserveData) storage reserves,
        mapping(uint256 => address) storage reservesList,
        mapping(address => mapping(uint256 => DataTypes.UserReserve)) storage userReserves,
        mapping(address => uint256) storage userConfigs,
        IOracleManager oracle,
        LiquidationParams memory p
    ) external returns (uint256, uint256) {
        DataTypes.ReserveData storage debtR = reserves[p.debtAsset];
        DataTypes.ReserveData storage collR = reserves[p.collateralAsset];
        ValidationLogic.validateLiquidationReserve(debtR.config);
        ValidationLogic.validateLiquidationReserve(collR.config);

        debtR.accrue();
        collR.accrue();

        LiquidationVars memory v;
        v.debtId = debtR.id;
        v.collateralId = collR.id;

        uint256 cfg = userConfigs[p.borrower];
        if (!cfg.isBorrowing(v.debtId)) revert Errors.NoDebt();
        if (!cfg.isCollateral(v.collateralId)) revert Errors.CollateralNotEnabledByUser();

        // ------------------------------------------------------------ eligibility
        {
            RiskEngine.PriceCapture memory prices =
                RiskEngine.PriceCapture({idA: v.debtId, idB: v.collateralId, priceA: 0, priceB: 0});
            DataTypes.AccountData memory account = RiskEngine.calculateAccountData(
                reserves, reservesList, userReserves[p.borrower], cfg, oracle, prices
            );
            if (account.healthFactor >= RiskEngine.HEALTH_FACTOR_ONE) revert Errors.HealthyPosition();
            v.healthFactor = account.healthFactor;
            // Both legs are always priced during valuation (their bits are set and balances are
            // non-zero). The fallback only guards that assumption; the price source is the same.
            v.debtPrice = prices.priceA != 0 ? prices.priceA : oracle.getPrice(p.debtAsset);
            v.collateralPrice = prices.priceB != 0 ? prices.priceB : oracle.getPrice(p.collateralAsset);
        }

        // ------------------------------------------------------------ amounts
        _computeAmounts(v, debtR, collR, userReserves[p.borrower], p);

        // ------------------------------------------------------------ effects: debt leg
        DataTypes.UserReserve storage borrowerDebtPos = userReserves[p.borrower][v.debtId];
        {
            uint256 scaledDebt = borrowerDebtPos.scaledDebt;
            v.debtBurn =
                v.debtRepaid == v.borrowerDebt ? scaledDebt : v.debtRepaid.rayDivDown(debtR.borrowIndex);
            if (v.debtBurn == 0) revert Errors.NothingToLiquidate();
            borrowerDebtPos.scaledDebt = (scaledDebt - v.debtBurn).toUint128();
            debtR.totalScaledDebt = (uint256(debtR.totalScaledDebt) - v.debtBurn).toUint128();
            debtR.cash = (uint256(debtR.cash) + v.debtRepaid).toUint128();
            if (v.debtBurn == scaledDebt) cfg = cfg.setBorrowing(v.debtId, false);
        }

        // ------------------------------------------------------------ effects: collateral leg
        DataTypes.UserReserve storage borrowerCollPos = userReserves[p.borrower][v.collateralId];
        {
            uint256 scaledColl = borrowerCollPos.scaledSupply;
            v.collateralBurn = v.collateralSeized == v.borrowerCollateral
                ? scaledColl
                : v.collateralSeized.rayDivUp(collR.liquidityIndex);
            borrowerCollPos.scaledSupply = (scaledColl - v.collateralBurn).toUint128();
            if (v.collateralBurn == scaledColl) {
                cfg = cfg.setCollateral(v.collateralId, false);
                emit ILendingPool.ReserveUsedAsCollateral(p.collateralAsset, p.borrower, false);
            }
        }
        userConfigs[p.borrower] = cfg;

        if (p.receiveSupply) {
            _creditLiquidatorSupply(collR, userReserves[msg.sender][v.collateralId], userConfigs, p, v);
        } else {
            // For a same-asset liquidation the debt leg above already added the repayment to cash.
            if (v.collateralSeized > collR.cash) revert Errors.InsufficientLiquidity();
            collR.totalScaledSupply = (uint256(collR.totalScaledSupply) - v.collateralBurn).toUint128();
            collR.cash = (uint256(collR.cash) - v.collateralSeized).toUint128();
        }

        // One bit per touched reserve id (ids < 32): set-membership mask, operands in intended order.
        // forge-lint: disable-next-line(incorrect-shift)
        v.touched = (1 << v.debtId) | (1 << v.collateralId);

        // ------------------------------------------------------------ bad debt
        cfg = userConfigs[p.borrower];
        if (!cfg.hasCollateralAny() && cfg.isBorrowingAny()) {
            v.touched |= _writeOffBadDebt(reserves, reservesList, userReserves[p.borrower], cfg, p.borrower);
            userConfigs[p.borrower] = cfg & ~UserConfiguration.BORROWING_MASK;
        }

        _updateTouchedRates(reserves, reservesList, v.touched);

        // ------------------------------------------------------------ interactions
        IERC20(p.debtAsset).safeTransferFrom(msg.sender, address(this), v.debtRepaid);
        if (!p.receiveSupply) IERC20(p.collateralAsset).safeTransfer(msg.sender, v.collateralSeized);

        emit ILendingPool.LiquidationCall(
            p.collateralAsset,
            p.debtAsset,
            p.borrower,
            msg.sender,
            v.debtRepaid,
            v.collateralSeized,
            p.receiveSupply
        );
        return (v.debtRepaid, v.collateralSeized);
    }

    /// @dev Loads the liquidation inputs (prices were captured during valuation), then delegates
    ///      the maths to the pure `calculateAmounts`, which PoolLens reuses for previews.
    function _computeAmounts(
        LiquidationVars memory v,
        DataTypes.ReserveData storage debtR,
        DataTypes.ReserveData storage collR,
        mapping(uint256 => DataTypes.UserReserve) storage borrowerReserves,
        LiquidationParams memory p
    ) private view {
        v.borrowerDebt = uint256(borrowerReserves[v.debtId].scaledDebt).rayMulUp(debtR.borrowIndex);
        v.borrowerCollateral =
            uint256(borrowerReserves[v.collateralId].scaledSupply).rayMulDown(collR.liquidityIndex);

        AmountsResult memory res = calculateAmounts(
            AmountsInput({
                healthFactor: v.healthFactor,
                borrowerDebt: v.borrowerDebt,
                borrowerCollateral: v.borrowerCollateral,
                debtPrice: v.debtPrice,
                collateralPrice: v.collateralPrice,
                debtUnit: 10 ** debtR.config.decimals,
                collateralUnit: 10 ** collR.config.decimals,
                bonus: collR.config.liquidationBonus,
                debtToCover: p.debtToCover
            })
        );
        if (res.status == AmountsStatus.NOTHING_TO_LIQUIDATE) revert Errors.NothingToLiquidate();
        if (res.status == AmountsStatus.LEAVES_DUST) revert Errors.MustNotLeaveDust();
        v.closeFactor = res.closeFactor;
        v.debtRepaid = res.debtRepaid;
        v.collateralSeized = res.collateralSeized;
    }

    enum AmountsStatus {
        OK,
        NOTHING_TO_LIQUIDATE,
        LEAVES_DUST
    }

    struct AmountsInput {
        uint256 healthFactor;
        uint256 borrowerDebt; //       debt asset units
        uint256 borrowerCollateral; // collateral asset units
        uint256 debtPrice; //          1e18 USD
        uint256 collateralPrice;
        uint256 debtUnit; //           10^decimals
        uint256 collateralUnit;
        uint256 bonus; //              bps
        uint256 debtToCover;
    }

    struct AmountsResult {
        AmountsStatus status;
        uint256 closeFactor;
        uint256 debtRepaid;
        uint256 collateralSeized;
    }

    /// @notice Close factor, seizure amount and dust rule. Pure, so previews and execution share one
    ///         implementation and cannot drift apart.
    function calculateAmounts(AmountsInput memory i) internal pure returns (AmountsResult memory res) {
        uint256 debtValue = (i.borrowerDebt * i.debtPrice) / i.debtUnit;
        uint256 collateralValue = (i.borrowerCollateral * i.collateralPrice) / i.collateralUnit;

        res.closeFactor = (i.healthFactor < CLOSE_FACTOR_HF_THRESHOLD || debtValue < SMALL_POSITION_VALUE
                || collateralValue < SMALL_POSITION_VALUE)
            ? MAX_CLOSE_FACTOR
            : DEFAULT_CLOSE_FACTOR;

        uint256 maxDebt = i.borrowerDebt.percentMulDown(res.closeFactor);
        res.debtRepaid = i.debtToCover < maxDebt ? i.debtToCover : maxDebt;

        // collateral = debtRepaid * P_debt / P_coll * (1 + bonus), decimals-adjusted, rounded down.
        res.collateralSeized = Math.mulDiv(
            res.debtRepaid * i.debtPrice,
            i.collateralUnit * (PercentageMath.PERCENTAGE_FACTOR + i.bonus),
            i.debtUnit * i.collateralPrice * PercentageMath.PERCENTAGE_FACTOR
        );

        if (res.collateralSeized > i.borrowerCollateral) {
            // Not enough collateral for the full bonus: seize everything and repay only what it
            // covers (rounded up, against the liquidator).
            res.collateralSeized = i.borrowerCollateral;
            res.debtRepaid = Math.mulDiv(
                res.collateralSeized * i.collateralPrice,
                i.debtUnit * PercentageMath.PERCENTAGE_FACTOR,
                i.collateralUnit * i.debtPrice * (PercentageMath.PERCENTAGE_FACTOR + i.bonus),
                Math.Rounding.Ceil
            );
            if (res.debtRepaid > i.borrowerDebt) res.debtRepaid = i.borrowerDebt;
        }
        if (res.debtRepaid == 0 || res.collateralSeized == 0) {
            res.status = AmountsStatus.NOTHING_TO_LIQUIDATE;
            return res;
        }

        // Dust rule: a partial liquidation must leave both legs economically liquidatable.
        if (res.debtRepaid < i.borrowerDebt && res.collateralSeized < i.borrowerCollateral) {
            uint256 leftoverDebt = ((i.borrowerDebt - res.debtRepaid) * i.debtPrice) / i.debtUnit;
            uint256 leftoverCollateral =
                ((i.borrowerCollateral - res.collateralSeized) * i.collateralPrice) / i.collateralUnit;
            if (leftoverDebt < MIN_LEFTOVER_VALUE || leftoverCollateral < MIN_LEFTOVER_VALUE) {
                res.status = AmountsStatus.LEAVES_DUST;
            }
        }
    }

    /// @dev Moves seized scaled supply to the liquidator instead of paying out underlying. This keeps
    ///      liquidations possible when the collateral reserve is fully utilized (cash == 0).
    function _creditLiquidatorSupply(
        DataTypes.ReserveData storage collR,
        DataTypes.UserReserve storage liquidatorPos,
        mapping(address => uint256) storage userConfigs,
        LiquidationParams memory p,
        LiquidationVars memory v
    ) private {
        uint256 previous = liquidatorPos.scaledSupply;
        liquidatorPos.scaledSupply = (previous + v.collateralBurn).toUint128();
        if (previous == 0 && collR.config.collateralEnabled && collR.config.liquidationThreshold != 0) {
            uint256 lcfg = userConfigs[msg.sender];
            if (!lcfg.isCollateral(v.collateralId)) {
                userConfigs[msg.sender] = lcfg.setCollateral(v.collateralId, true);
                emit ILendingPool.ReserveUsedAsCollateral(p.collateralAsset, msg.sender, true);
            }
        }
    }

    /// @dev Burns every remaining debt of a borrower with no collateral left. Returns a bitmask of
    ///      touched reserve ids so their rates are refreshed exactly once.
    function _writeOffBadDebt(
        mapping(address => DataTypes.ReserveData) storage reserves,
        mapping(uint256 => address) storage reservesList,
        mapping(uint256 => DataTypes.UserReserve) storage borrowerReserves,
        uint256 cfg,
        address borrower
    ) private returns (uint256 touched) {
        uint256 id;
        while (cfg != 0) {
            if (cfg & 1 != 0) {
                address asset = reservesList[id];
                DataTypes.ReserveData storage r = reserves[asset];
                r.accrue();

                DataTypes.UserReserve storage pos = borrowerReserves[id];
                uint256 scaled = pos.scaledDebt;
                if (scaled != 0) {
                    uint256 debt = scaled.rayMulUp(r.borrowIndex);
                    pos.scaledDebt = 0;
                    r.totalScaledDebt = (uint256(r.totalScaledDebt) - scaled).toUint128();

                    uint256 covered = _absorbWithTreasury(r, debt);
                    uint256 deficitAdded = debt - covered;
                    r.deficit = (uint256(r.deficit) + deficitAdded).toUint128();
                    emit ILendingPool.BadDebtRecognized(asset, borrower, debt, covered, deficitAdded);
                }
                // forge-lint: disable-next-line(incorrect-shift)
                touched |= 1 << id;
            }
            cfg >>= 2;
            unchecked {
                ++id;
            }
        }
    }

    /// @dev The reserve's accumulated reserve-factor income is the first-loss buffer. Burning the
    ///      treasury's claim lowers liabilities by the same amount the write-off lowers assets.
    function _absorbWithTreasury(DataTypes.ReserveData storage r, uint256 loss)
        private
        returns (uint256 covered)
    {
        uint256 treasuryScaled = r.accruedToTreasury;
        if (treasuryScaled == 0) return 0;
        uint256 index = r.liquidityIndex;
        uint256 treasuryValue = treasuryScaled.rayMulDown(index);
        if (treasuryValue <= loss) {
            r.accruedToTreasury = 0;
            return treasuryValue;
        }
        // loss < treasuryScaled * index, so the rounded-up burn is <= treasuryScaled.
        r.accruedToTreasury = (treasuryScaled - loss.rayDivUp(index)).toUint128();
        return loss;
    }

    function _updateTouchedRates(
        mapping(address => DataTypes.ReserveData) storage reserves,
        mapping(uint256 => address) storage reservesList,
        uint256 touched
    ) private {
        uint256 id;
        while (touched != 0) {
            if (touched & 1 != 0) {
                address asset = reservesList[id];
                reserves[asset].updateRates(asset);
            }
            touched >>= 1;
            unchecked {
                ++id;
            }
        }
    }
}
