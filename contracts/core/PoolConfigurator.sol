// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IACLManager} from "../interfaces/IACLManager.sol";
import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {Errors} from "../libraries/Errors.sol";
import {PercentageMath} from "../libraries/PercentageMath.sol";
import {Roles} from "../libraries/Roles.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title PoolConfigurator
/// @notice The only privileged entry point into the pool. It validates every parameter before
///         writing it, and splits powers by direction of risk:
///
///   POOL_ADMIN (TimelockController, delayed)   listing, LTV/LT/bonus, reserve factor, caps,
///                                              rate model, unfreeze, grace period, reserves withdrawal
///   EMERGENCY_ADMIN (guardian, instant)        pause/unpause pool or reserve, freeze reserve
///
/// Risk-reducing actions are instant; risk-increasing ones wait out the timelock, which gives users
/// time to exit before, for example, a liquidation threshold is lowered under them.
contract PoolConfigurator {
    using PercentageMath for uint256;

    /// @notice Liquidation bonus ceiling (20%). A larger bonus overpays liquidators and pushes
    ///         LT * (1 + bonus) toward 100%, where liquidation stops improving health.
    uint16 public constant MAX_LIQUIDATION_BONUS = 2000;
    uint16 public constant MAX_RESERVE_FACTOR = 5000;
    /// @notice No asset may be weighted above 95% in the health factor.
    uint16 public constant MAX_LIQUIDATION_THRESHOLD = 9500;

    ILendingPool public immutable POOL;
    IACLManager public immutable ACL;

    struct InitReserveInput {
        address asset;
        address interestRateModel;
        uint16 ltv;
        uint16 liquidationThreshold;
        uint16 liquidationBonus;
        uint16 reserveFactor;
        uint64 supplyCap;
        uint64 borrowCap;
        bool borrowingEnabled;
        bool collateralEnabled;
    }

    event RiskParametersUpdated(
        address indexed asset, uint16 ltv, uint16 liquidationThreshold, uint16 liquidationBonus
    );
    event ReserveFactorUpdated(address indexed asset, uint16 oldFactor, uint16 newFactor);
    event CapsUpdated(address indexed asset, uint64 supplyCap, uint64 borrowCap);
    event BorrowingToggled(address indexed asset, bool enabled);
    event CollateralToggled(address indexed asset, bool enabled);
    event ReserveFrozen(address indexed asset, bool frozen);
    event ReservePaused(address indexed asset, bool paused);
    event ReserveActiveToggled(address indexed asset, bool active);

    modifier onlyPoolAdmin() {
        _onlyPoolAdmin();
        _;
    }

    modifier onlyEmergencyOrPoolAdmin() {
        _onlyEmergencyOrPoolAdmin();
        _;
    }

    constructor(ILendingPool pool, IACLManager acl) {
        if (address(pool) == address(0) || address(acl) == address(0)) revert Errors.ZeroAddress();
        POOL = pool;
        ACL = acl;
    }

    // ================================================================== listing

    function initReserve(InitReserveInput calldata input) external onlyPoolAdmin {
        if (input.asset == address(0) || input.interestRateModel == address(0)) revert Errors.ZeroAddress();
        _validateRateModel(input.interestRateModel);
        _validateRiskParams(input.ltv, input.liquidationThreshold, input.liquidationBonus);
        if (input.reserveFactor > MAX_RESERVE_FACTOR) revert Errors.InvalidReserveFactor();
        if (input.collateralEnabled && input.liquidationThreshold == 0) {
            revert Errors.InvalidRiskParameters();
        }

        uint8 decimals = IERC20Metadata(input.asset).decimals();
        // Values are computed as amount * price / 10^decimals; bounding decimals bounds that product.
        if (decimals == 0 || decimals > 24) revert Errors.InvalidDecimals();

        DataTypes.ReserveConfig memory config = DataTypes.ReserveConfig({
            ltv: input.ltv,
            liquidationThreshold: input.liquidationThreshold,
            liquidationBonus: input.liquidationBonus,
            reserveFactor: input.reserveFactor,
            decimals: decimals,
            active: true,
            frozen: false,
            paused: false,
            borrowingEnabled: input.borrowingEnabled,
            collateralEnabled: input.collateralEnabled,
            supplyCap: input.supplyCap,
            borrowCap: input.borrowCap
        });
        POOL.initReserve(input.asset, input.interestRateModel, config);
    }

    // ================================================================== risk-increasing (timelocked)

    /// @notice Lowering a liquidation threshold can make existing positions liquidatable at once.
    ///         That is exactly why this sits behind the timelock and not with the guardian.
    function setRiskParameters(
        address asset,
        uint16 ltv,
        uint16 liquidationThreshold,
        uint16 liquidationBonus
    ) external onlyPoolAdmin {
        _validateRiskParams(ltv, liquidationThreshold, liquidationBonus);
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(asset);
        if (c.collateralEnabled && liquidationThreshold == 0) revert Errors.InvalidRiskParameters();
        c.ltv = ltv;
        c.liquidationThreshold = liquidationThreshold;
        c.liquidationBonus = liquidationBonus;
        POOL.setReserveConfig(asset, c);
        emit RiskParametersUpdated(asset, ltv, liquidationThreshold, liquidationBonus);
    }

    function setReserveFactor(address asset, uint16 reserveFactor) external onlyPoolAdmin {
        if (reserveFactor > MAX_RESERVE_FACTOR) revert Errors.InvalidReserveFactor();
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(asset);
        uint16 old = c.reserveFactor;
        c.reserveFactor = reserveFactor;
        POOL.setReserveConfig(asset, c);
        emit ReserveFactorUpdated(asset, old, reserveFactor);
    }

    function setCaps(address asset, uint64 supplyCap, uint64 borrowCap) external onlyPoolAdmin {
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(asset);
        c.supplyCap = supplyCap;
        c.borrowCap = borrowCap;
        POOL.setReserveConfig(asset, c);
        emit CapsUpdated(asset, supplyCap, borrowCap);
    }

    function setBorrowingEnabled(address asset, bool enabled) external onlyPoolAdmin {
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(asset);
        c.borrowingEnabled = enabled;
        POOL.setReserveConfig(asset, c);
        emit BorrowingToggled(asset, enabled);
    }

    /// @notice Disabling only stops *new* collateral enablement; existing collateral keeps counting
    ///         until its LTV/LT are lowered through setRiskParameters.
    function setCollateralEnabled(address asset, bool enabled) external onlyPoolAdmin {
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(asset);
        if (enabled && c.liquidationThreshold == 0) revert Errors.InvalidRiskParameters();
        c.collateralEnabled = enabled;
        POOL.setReserveConfig(asset, c);
        emit CollateralToggled(asset, enabled);
    }

    function setInterestRateModel(address asset, address interestRateModel) external onlyPoolAdmin {
        _validateRateModel(interestRateModel);
        POOL.setInterestRateModel(asset, interestRateModel);
    }

    /// @notice Deactivation is only possible for an empty reserve; otherwise users would be locked out.
    function setReserveActive(address asset, bool active) external onlyPoolAdmin {
        DataTypes.ReserveData memory r = POOL.getReserveData(asset);
        if (!active && (r.totalScaledSupply != 0 || r.totalScaledDebt != 0 || r.accruedToTreasury != 0)) {
            revert Errors.InvalidRiskParameters();
        }
        r.config.active = active;
        POOL.setReserveConfig(asset, r.config);
        emit ReserveActiveToggled(asset, active);
    }

    function setLiquidationGracePeriod(uint32 gracePeriod) external onlyPoolAdmin {
        POOL.setLiquidationGracePeriod(gracePeriod);
    }

    function setOracle(address oracle) external onlyPoolAdmin {
        POOL.setOracle(oracle);
    }

    function withdrawReserves(address asset, uint256 amount, address to)
        external
        onlyPoolAdmin
        returns (uint256)
    {
        return POOL.withdrawReserves(asset, amount, to);
    }

    // ================================================================== emergency (instant)

    function setPoolPaused(bool paused) external onlyEmergencyOrPoolAdmin {
        POOL.setPoolPaused(paused);
    }

    function setReservePaused(address asset, bool paused) external onlyEmergencyOrPoolAdmin {
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(asset);
        c.paused = paused;
        POOL.setReserveConfig(asset, c);
        emit ReservePaused(asset, paused);
    }

    /// @notice Freezing is risk-reducing and instant. Unfreezing re-opens exposure, so only the
    ///         timelocked pool admin may do it.
    function setReserveFrozen(address asset, bool frozen) external {
        if (frozen) {
            if (!ACL.hasRole(Roles.EMERGENCY_ADMIN, msg.sender) && !ACL.hasRole(Roles.POOL_ADMIN, msg.sender))
            {
                revert Errors.NotEmergencyAdmin();
            }
        } else if (!ACL.hasRole(Roles.POOL_ADMIN, msg.sender)) {
            revert Errors.NotPoolAdmin();
        }
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(asset);
        c.frozen = frozen;
        POOL.setReserveConfig(asset, c);
        emit ReserveFrozen(asset, frozen);
    }

    // ================================================================== access

    function _onlyPoolAdmin() internal view {
        if (!ACL.hasRole(Roles.POOL_ADMIN, msg.sender)) revert Errors.NotPoolAdmin();
    }

    function _onlyEmergencyOrPoolAdmin() internal view {
        if (!ACL.hasRole(Roles.EMERGENCY_ADMIN, msg.sender) && !ACL.hasRole(Roles.POOL_ADMIN, msg.sender)) {
            revert Errors.NotEmergencyAdmin();
        }
    }

    // ================================================================== validation

    /// @dev Invariants every listed asset must satisfy:
    ///   ltv < liquidationThreshold          borrowing to the max leaves a buffer before liquidation
    ///   LT <= 95%
    ///   LT * (1 + bonus) < 100%             otherwise seizing collateral at a bonus *lowers* the
    ///                                       borrower's health factor and every liquidation
    ///                                       accelerates insolvency (see docs/liquidations.md)
    ///   bonus > 0 whenever LT > 0           liquidators must be paid to act
    ///   LT == 0  =>  ltv == 0               a non-collateral asset grants no borrowing power
    function _validateRiskParams(uint16 ltv, uint16 liquidationThreshold, uint16 liquidationBonus)
        internal
        pure
    {
        if (liquidationThreshold == 0) {
            if (ltv != 0 || liquidationBonus != 0) revert Errors.InvalidRiskParameters();
            return;
        }
        if (ltv >= liquidationThreshold) revert Errors.InvalidRiskParameters();
        if (liquidationThreshold > MAX_LIQUIDATION_THRESHOLD) revert Errors.InvalidRiskParameters();
        if (liquidationBonus == 0 || liquidationBonus > MAX_LIQUIDATION_BONUS) {
            revert Errors.InvalidRiskParameters();
        }
        if (
            uint256(liquidationThreshold).percentMulUp(PercentageMath.PERCENTAGE_FACTOR + liquidationBonus)
                >= PercentageMath.PERCENTAGE_FACTOR
        ) revert Errors.InvalidRiskParameters();
    }

    /// @dev Cheap sanity check that the address behaves like a rate model before it prices a market.
    function _validateRateModel(address model) internal view {
        if (model.code.length == 0) revert Errors.InvalidRateModelParams();
        IInterestRateModel(model).getBorrowRate(1, 1);
    }
}
