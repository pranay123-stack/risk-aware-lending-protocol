// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IOracleManager} from "../interfaces/IOracleManager.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {PercentageMath} from "../libraries/PercentageMath.sol";
import {UserConfiguration} from "../libraries/UserConfiguration.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";
import {LiquidationLogic} from "../logic/LiquidationLogic.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title PoolLens
/// @notice Stateless, batched read layer for the frontend, API and risk monitor. Two properties
///         matter more than gas here:
///  1. One bad account or oracle never breaks a batch. Every per-item read is wrapped so a
///     monitoring sweep still returns everything else when one feed is down.
///  2. No duplicated maths. Liquidation previews call the same pure function the pool executes.
/// @dev Deploys without chain-specific helpers (e.g. Multicall3), so it works on a fresh Anvil.
contract PoolLens {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using UserConfiguration for uint256;

    /// @notice Haircut applied to "max" suggestions so rounding in the pool's own checks (debt
    ///         rounds up, collateral down) never makes a max-button transaction revert. 1 ppm.
    uint256 internal constant MAX_HAIRCUT_PPM = 1;

    ILendingPool public immutable POOL;

    struct MarketData {
        address asset;
        string symbol;
        uint8 decimals;
        uint256 price; //            1e18 USD, 0 if unavailable
        IOracleManager.PriceStatus priceStatus;
        uint256 totalSupplied; //    underlying units (suppliers + treasury)
        uint256 totalBorrowed;
        uint256 cash;
        uint256 utilization; //      ray
        uint256 liquidityRate; //    ray / year (APR)
        uint256 borrowRate; //       ray / year (APR)
        uint256 liquidityIndex; //   normalised to now
        uint256 borrowIndex;
        uint256 treasury;
        uint256 deficit;
        DataTypes.ReserveConfig config;
        address interestRateModel;
        uint256 baseRate;
        uint256 slope1;
        uint256 slope2;
        uint256 optimalUtilization;
    }

    struct UserReserveData {
        address asset;
        uint256 supplyBalance;
        uint256 debtBalance;
        bool collateralEnabled;
        uint256 walletBalance;
        uint256 allowance; //      to the pool
        uint256 maxBorrow; //      0 if unavailable
        uint256 maxWithdraw;
    }

    struct AccountHealth {
        address user;
        bool ok; //                false if valuation reverted (e.g. an exposed oracle is down)
        uint256 totalCollateralValue;
        uint256 totalDebtValue;
        uint256 borrowCapacityValue;
        uint256 liquidationValue;
        uint256 healthFactor;
    }

    struct LiquidationPreview {
        bool liquidatable;
        LiquidationLogic.AmountsStatus status;
        uint256 healthFactor;
        uint256 closeFactor;
        uint256 debtRepaid;
        uint256 collateralSeized;
        uint256 debtRepaidValue; //        1e18 USD
        uint256 collateralSeizedValue; //  1e18 USD; minus debtRepaidValue = liquidator's gross profit
    }

    constructor(ILendingPool pool) {
        POOL = pool;
    }

    // ================================================================== markets

    function getMarkets() external view returns (MarketData[] memory markets) {
        address[] memory list = POOL.getReservesList();
        markets = new MarketData[](list.length);
        for (uint256 i; i < list.length; ++i) {
            markets[i] = getMarket(list[i]);
        }
    }

    function getMarket(address asset) public view returns (MarketData memory m) {
        DataTypes.ReserveData memory r = POOL.getReserveData(asset);
        m.asset = asset;
        m.symbol = _symbol(asset);
        m.decimals = r.config.decimals;
        m.config = r.config;
        m.totalSupplied = POOL.totalSupplied(asset);
        m.totalBorrowed = POOL.totalBorrowed(asset);
        m.cash = r.cash;
        m.liquidityRate = r.liquidityRate;
        m.borrowRate = r.borrowRate;
        m.liquidityIndex = POOL.getReserveNormalizedIncome(asset);
        m.borrowIndex = POOL.getReserveNormalizedDebt(asset);
        m.treasury = POOL.treasuryBalance(asset);
        m.deficit = r.deficit;
        m.interestRateModel = r.interestRateModel;

        IInterestRateModel irm = IInterestRateModel(r.interestRateModel);
        m.utilization = irm.utilization(r.cash, m.totalBorrowed);
        m.baseRate = irm.baseRate();
        m.slope1 = irm.slope1();
        m.slope2 = irm.slope2();
        m.optimalUtilization = irm.optimalUtilization();

        IOracleManager.PriceState memory ps = POOL.oracle().getPriceState(asset);
        m.price = ps.price;
        m.priceStatus = ps.status;
    }

    // ================================================================== users

    function getUserPositions(address user)
        external
        view
        returns (UserReserveData[] memory positions, AccountHealth memory health)
    {
        health = _accountHealth(user);
        address[] memory list = POOL.getReservesList();
        positions = new UserReserveData[](list.length);
        for (uint256 i; i < list.length; ++i) {
            address asset = list[i];
            UserReserveData memory p = positions[i];
            p.asset = asset;
            p.supplyBalance = POOL.supplyBalanceOf(asset, user);
            p.debtBalance = POOL.debtBalanceOf(asset, user);
            p.collateralEnabled = POOL.isUsingAsCollateral(asset, user);
            p.walletBalance = IERC20Metadata(asset).balanceOf(user);
            p.allowance = IERC20Metadata(asset).allowance(user, address(POOL));
            if (health.ok) p.maxBorrow = _maxBorrow(asset, health);
            p.maxWithdraw = _maxWithdraw(asset, user, p.supplyBalance, p.collateralEnabled, health);
        }
    }

    /// @notice Batch health read for the risk monitor. Never reverts on a single bad account.
    function getAccountsHealth(address[] calldata users) external view returns (AccountHealth[] memory out) {
        out = new AccountHealth[](users.length);
        for (uint256 i; i < users.length; ++i) {
            out[i] = _accountHealth(users[i]);
        }
    }

    function getMaxBorrow(address user, address asset) external view returns (uint256) {
        AccountHealth memory h = _accountHealth(user);
        return h.ok ? _maxBorrow(asset, h) : 0;
    }

    function getMaxWithdraw(address user, address asset) external view returns (uint256) {
        return _maxWithdraw(
            asset,
            user,
            POOL.supplyBalanceOf(asset, user),
            POOL.isUsingAsCollateral(asset, user),
            _accountHealth(user)
        );
    }

    // ================================================================== liquidations

    /// @notice What a liquidation would do right now, using the pool's own amount maths.
    /// @dev Reads indexes normalised to now, exactly what `liquidate` sees after accruing.
    function previewLiquidation(
        address borrower,
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover
    ) external view returns (LiquidationPreview memory preview) {
        AccountHealth memory h = _accountHealth(borrower);
        preview.healthFactor = h.healthFactor;
        if (!h.ok || h.healthFactor >= 1e18) return preview;
        if (!POOL.isUsingAsCollateral(collateralAsset, borrower)) return preview;

        uint256 debt = POOL.debtBalanceOf(debtAsset, borrower);
        if (debt == 0) return preview;

        IOracleManager oracle = POOL.oracle();
        LiquidationLogic.AmountsInput memory input = LiquidationLogic.AmountsInput({
            healthFactor: h.healthFactor,
            borrowerDebt: debt,
            borrowerCollateral: POOL.supplyBalanceOf(collateralAsset, borrower),
            debtPrice: oracle.getPrice(debtAsset),
            collateralPrice: oracle.getPrice(collateralAsset),
            debtUnit: 10 ** POOL.getReserveConfig(debtAsset).decimals,
            collateralUnit: 10 ** POOL.getReserveConfig(collateralAsset).decimals,
            bonus: POOL.getReserveConfig(collateralAsset).liquidationBonus,
            debtToCover: debtToCover
        });
        LiquidationLogic.AmountsResult memory res = LiquidationLogic.calculateAmounts(input);

        preview.status = res.status;
        preview.liquidatable = res.status == LiquidationLogic.AmountsStatus.OK;
        preview.closeFactor = res.closeFactor;
        preview.debtRepaid = res.debtRepaid;
        preview.collateralSeized = res.collateralSeized;
        preview.debtRepaidValue = (res.debtRepaid * input.debtPrice) / input.debtUnit;
        preview.collateralSeizedValue = (res.collateralSeized * input.collateralPrice) / input.collateralUnit;
    }

    // ================================================================== internals

    function _accountHealth(address user) internal view returns (AccountHealth memory h) {
        h.user = user;
        try POOL.getUserAccountData(user) returns (DataTypes.AccountData memory d) {
            h.ok = true;
            h.totalCollateralValue = d.totalCollateralValue;
            h.totalDebtValue = d.totalDebtValue;
            h.borrowCapacityValue = d.borrowCapacityValue;
            h.liquidationValue = d.liquidationValue;
            h.healthFactor = d.healthFactor;
        } catch {
            h.ok = false;
        }
    }

    function _maxBorrow(address asset, AccountHealth memory h) internal view returns (uint256) {
        DataTypes.ReserveData memory r = POOL.getReserveData(asset);
        DataTypes.ReserveConfig memory c = r.config;
        if (!c.active || c.frozen || c.paused || !c.borrowingEnabled || POOL.paused()) return 0;
        if (h.borrowCapacityValue <= h.totalDebtValue) return 0;

        uint256 price;
        try POOL.oracle().getPrice(asset) returns (uint256 p) {
            price = p;
        } catch {
            return 0;
        }
        uint256 unit = 10 ** c.decimals;
        uint256 amount = ((h.borrowCapacityValue - h.totalDebtValue) * unit) / price;
        amount = _min(amount, r.cash);
        if (c.borrowCap != 0) {
            uint256 cap = uint256(c.borrowCap) * unit;
            uint256 borrowed = POOL.totalBorrowed(asset);
            amount = borrowed >= cap ? 0 : _min(amount, cap - borrowed);
        }
        return _haircut(amount);
    }

    /// @dev Mirrors `LendingPool.withdraw`: only a collateral withdrawal by an account with debt is
    ///      risk-checked, and that check prices every exposed asset.
    function _maxWithdraw(
        address asset,
        address user,
        uint256 balance,
        bool isCollateral,
        AccountHealth memory h
    ) internal view returns (uint256) {
        DataTypes.ReserveData memory r = POOL.getReserveData(asset);
        if (!r.config.active || r.config.paused || POOL.paused()) return 0;
        uint256 amount = _min(balance, r.cash);
        if (!isCollateral || !POOL.getUserConfiguration(user).isBorrowingAny()) return amount;
        // The pool's check cannot pass while an exposed oracle is down.
        if (!h.ok) return 0;
        // LTV-0 collateral adds no capacity: withdrawing it only requires debt <= capacity to hold already.
        if (r.config.ltv == 0) return h.totalDebtValue > h.borrowCapacityValue ? 0 : amount;
        if (h.borrowCapacityValue <= h.totalDebtValue) return 0;

        // Withdrawing X lowers borrowing capacity by X * price * ltv.
        uint256 price = POOL.oracle().getPrice(asset);
        uint256 unit = 10 ** r.config.decimals;
        uint256 excessValue = h.borrowCapacityValue - h.totalDebtValue;
        uint256 byCapacity = (excessValue * PercentageMath.PERCENTAGE_FACTOR * unit) / (price * r.config.ltv);
        if (byCapacity >= amount) return amount;
        return _haircut(byCapacity);
    }

    function _haircut(uint256 amount) internal pure returns (uint256) {
        uint256 cut = WadRayMath.divUp(amount * MAX_HAIRCUT_PPM, 1e6);
        return amount > cut ? amount - cut : 0;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _symbol(address asset) internal view returns (string memory) {
        try IERC20Metadata(asset).symbol() returns (string memory s) {
            return s;
        } catch {
            return "";
        }
    }
}
