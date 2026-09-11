// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DataTypes} from "../libraries/DataTypes.sol";
import {IOracleManager} from "./IOracleManager.sol";

/// @title ILendingPool
/// @notice User-facing entry point and the event surface the indexer consumes.
interface ILendingPool {
    // ------------------------------------------------------------------ user events
    event Supply(address indexed reserve, address indexed onBehalfOf, address indexed caller, uint256 amount);
    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);
    event Borrow(address indexed reserve, address indexed user, uint256 amount, uint256 borrowRate);
    event Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount);
    event ReserveUsedAsCollateral(address indexed reserve, address indexed user, bool enabled);
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed borrower,
        address liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        bool receiveSupply
    );

    // ------------------------------------------------------------------ accounting events
    /// @notice Emitted whenever a reserve's rates are recomputed (after every state change).
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 borrowRate,
        uint256 liquidityIndex,
        uint256 borrowIndex
    );
    event BadDebtRecognized(
        address indexed reserve,
        address indexed borrower,
        uint256 amount,
        uint256 coveredByTreasury,
        uint256 deficitAdded
    );
    event DeficitCovered(address indexed reserve, address indexed payer, uint256 amount);
    event ReservesWithdrawn(address indexed reserve, address indexed to, uint256 amount);

    // ------------------------------------------------------------------ configuration events
    event ReserveInitialized(address indexed reserve, uint256 id, address interestRateModel);
    event ReserveConfigUpdated(address indexed reserve, DataTypes.ReserveConfig config);
    event InterestRateModelUpdated(address indexed reserve, address oldModel, address newModel);
    event PoolPauseUpdated(bool paused, uint256 liquidationGraceUntil);
    event LiquidationGracePeriodUpdated(uint256 gracePeriod);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    // ------------------------------------------------------------------ user actions
    function supply(address asset, uint256 amount, address onBehalfOf) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount) external;
    function repay(address asset, uint256 amount, address onBehalfOf) external returns (uint256);
    function setUseReserveAsCollateral(address asset, bool enabled) external;
    function liquidate(
        address collateralAsset,
        address debtAsset,
        address borrower,
        uint256 debtToCover,
        bool receiveSupply
    ) external returns (uint256 debtRepaid, uint256 collateralSeized);
    function coverDeficit(address asset, uint256 amount) external returns (uint256);

    // ------------------------------------------------------------------ configurator-only
    function initReserve(address asset, address interestRateModel, DataTypes.ReserveConfig calldata config)
        external;
    function setReserveConfig(address asset, DataTypes.ReserveConfig calldata config) external;
    function setInterestRateModel(address asset, address interestRateModel) external;
    function setPoolPaused(bool isPaused) external;
    function setLiquidationGracePeriod(uint32 gracePeriod) external;
    function setOracle(address newOracle) external;
    function withdrawReserves(address asset, uint256 amount, address to) external returns (uint256);

    // ------------------------------------------------------------------ views
    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);
    function getReserveConfig(address asset) external view returns (DataTypes.ReserveConfig memory);
    function getReservesList() external view returns (address[] memory);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getReserveNormalizedDebt(address asset) external view returns (uint256);
    function totalSupplied(address asset) external view returns (uint256);
    function totalBorrowed(address asset) external view returns (uint256);
    function treasuryBalance(address asset) external view returns (uint256);
    function supplyBalanceOf(address asset, address user) external view returns (uint256);
    function debtBalanceOf(address asset, address user) external view returns (uint256);
    function getUserScaledBalances(address asset, address user)
        external
        view
        returns (uint256 scaledSupply, uint256 scaledDebt);
    function getUserConfiguration(address user) external view returns (uint256);
    function isUsingAsCollateral(address asset, address user) external view returns (bool);
    function getUserAccountData(address user) external view returns (DataTypes.AccountData memory);
    function oracle() external view returns (IOracleManager);
    function paused() external view returns (bool);
    function liquidationGraceUntil() external view returns (uint256);
    function liquidationGracePeriod() external view returns (uint256);
}
