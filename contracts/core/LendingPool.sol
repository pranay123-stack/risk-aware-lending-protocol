// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IACLManager} from "../interfaces/IACLManager.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IOracleManager} from "../interfaces/IOracleManager.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {Errors} from "../libraries/Errors.sol";
import {Roles} from "../libraries/Roles.sol";
import {UserConfiguration} from "../libraries/UserConfiguration.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";
import {LiquidationLogic} from "../logic/LiquidationLogic.sol";
import {ReserveLogic} from "../logic/ReserveLogic.sol";
import {RiskEngine} from "../logic/RiskEngine.sol";
import {ValidationLogic} from "../logic/ValidationLogic.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LendingPool
/// @notice Holds every reserve's funds and accounting. Users supply, withdraw, borrow, repay and
///         liquidate here; the configurator is the only privileged caller.
///
/// Security properties this contract is built around (see docs/security.md):
///  - Internal `cash` accounting: donations cannot move indexes, rates or share prices.
///  - Checks-effects-interactions everywhere, plus a transient reentrancy lock on every
///    state-changing entry point: defence in depth against hook-bearing tokens and read-only reentrancy.
///  - Risk checks run on post-action state, so a check can never be bypassed by intermediate state.
///  - Every rounding decision favours the protocol.
contract LendingPool is ILendingPool, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using WadRayMath for uint256;
    using UserConfiguration for uint256;
    using ReserveLogic for DataTypes.ReserveData;

    /// @notice Hard cap on listed reserves. It bounds the gas of account valuation and bad-debt
    ///         write-off loops, so no configuration can make liquidations exceed the block gas limit.
    uint256 public constant MAX_RESERVES = 32;
    uint256 public constant MAX_GRACE_PERIOD = 4 hours;

    IACLManager public immutable ACL;

    mapping(address asset => DataTypes.ReserveData) internal _reserves;
    mapping(uint256 id => address asset) internal _reservesList;
    mapping(address user => mapping(uint256 id => DataTypes.UserReserve)) internal _userReserves;
    mapping(address user => uint256) internal _userConfig;

    // Packed into a single slot: read together by every action.
    IOracleManager internal _oracle;
    bool internal _paused;
    uint40 internal _liquidationGraceUntil;
    uint32 internal _liquidationGracePeriod;
    uint16 internal _reservesCount;

    modifier onlyConfigurator() {
        _onlyConfigurator();
        _;
    }

    constructor(IACLManager acl, IOracleManager oracle_) {
        if (address(acl) == address(0) || address(oracle_) == address(0)) revert Errors.ZeroAddress();
        ACL = acl;
        _oracle = oracle_;
        emit OracleUpdated(address(0), address(oracle_));
    }

    // ================================================================== supply side

    /// @inheritdoc ILendingPool
    function supply(address asset, uint256 amount, address onBehalfOf) external nonReentrant {
        DataTypes.ReserveData storage r = _reserves[asset];
        DataTypes.ReserveConfig memory c = r.config;
        ValidationLogic.validateSupply(c, amount, onBehalfOf, _paused);

        r.accrue();
        uint256 index = r.liquidityIndex;
        uint256 scaled = amount.rayDivDown(index);
        if (scaled == 0) revert Errors.AmountTooSmall();

        uint256 newTotalScaled = uint256(r.totalScaledSupply) + scaled;
        if (c.supplyCap != 0) {
            uint256 liabilities = (newTotalScaled + r.accruedToTreasury).rayMulDown(index);
            if (liabilities > uint256(c.supplyCap) * 10 ** c.decimals) revert Errors.SupplyCapExceeded();
        }

        uint256 id = r.id;
        DataTypes.UserReserve storage ur = _userReserves[onBehalfOf][id];
        uint256 previous = ur.scaledSupply;
        ur.scaledSupply = (previous + scaled).toUint128();
        r.totalScaledSupply = newTotalScaled.toUint128();
        r.cash = (uint256(r.cash) + amount).toUint128();

        // Auto-enable collateral only for the owner's own first supply. Supplying on behalf of
        // someone else must never add oracle exposure to their account (griefing vector).
        if (previous == 0 && onBehalfOf == msg.sender && c.collateralEnabled && c.liquidationThreshold != 0) {
            uint256 cfg = _userConfig[onBehalfOf];
            if (!cfg.isCollateral(id)) {
                _userConfig[onBehalfOf] = cfg.setCollateral(id, true);
                emit ReserveUsedAsCollateral(asset, onBehalfOf, true);
            }
        }

        r.updateRates(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Supply(asset, onBehalfOf, msg.sender, amount);
    }

    /// @inheritdoc ILendingPool
    /// @dev `amount == type(uint256).max` withdraws the full balance.
    function withdraw(address asset, uint256 amount, address to) external nonReentrant returns (uint256) {
        DataTypes.ReserveData storage r = _reserves[asset];
        ValidationLogic.validateWithdraw(r.config, amount, to, _paused);

        r.accrue();
        uint256 id = r.id;
        DataTypes.UserReserve storage ur = _userReserves[msg.sender][id];
        uint256 scaledBalance = ur.scaledSupply;
        uint256 balance = scaledBalance.rayMulDown(r.liquidityIndex);

        uint256 burn;
        if (amount == type(uint256).max || amount == balance) {
            amount = balance;
            burn = scaledBalance;
        } else {
            if (amount > balance) revert Errors.InsufficientBalance();
            burn = amount.rayDivUp(r.liquidityIndex);
        }
        if (amount == 0) revert Errors.NoSupply();
        if (amount > r.cash) revert Errors.InsufficientLiquidity();

        ur.scaledSupply = (scaledBalance - burn).toUint128();
        r.totalScaledSupply = (uint256(r.totalScaledSupply) - burn).toUint128();
        r.cash = (uint256(r.cash) - amount).toUint128();

        uint256 cfg = _userConfig[msg.sender];
        bool isCollateral = cfg.isCollateral(id);
        if (isCollateral && burn == scaledBalance) {
            cfg = cfg.setCollateral(id, false);
            _userConfig[msg.sender] = cfg;
            emit ReserveUsedAsCollateral(asset, msg.sender, false);
        }
        // Only collateral withdrawals by indebted accounts need prices. Debt-free lenders can always
        // exit, even while an oracle is down.
        if (isCollateral && cfg.isBorrowingAny()) {
            RiskEngine.requireWithinBorrowCapacity(
                _reserves, _reservesList, _userReserves[msg.sender], cfg, _oracle
            );
        }

        r.updateRates(asset);
        IERC20(asset).safeTransfer(to, amount);
        emit Withdraw(asset, msg.sender, to, amount);
        return amount;
    }

    // ================================================================== borrow side

    /// @inheritdoc ILendingPool
    function borrow(address asset, uint256 amount) external nonReentrant {
        DataTypes.ReserveData storage r = _reserves[asset];
        DataTypes.ReserveConfig memory c = r.config;
        ValidationLogic.validateBorrow(c, amount, _paused);

        r.accrue();
        if (amount > r.cash) revert Errors.InsufficientLiquidity();

        uint256 index = r.borrowIndex;
        uint256 scaled = amount.rayDivUp(index);
        uint256 newTotalScaledDebt = uint256(r.totalScaledDebt) + scaled;
        if (c.borrowCap != 0 && newTotalScaledDebt.rayMulUp(index) > uint256(c.borrowCap) * 10 ** c.decimals)
        {
            revert Errors.BorrowCapExceeded();
        }

        uint256 id = r.id;
        DataTypes.UserReserve storage ur = _userReserves[msg.sender][id];
        ur.scaledDebt = (uint256(ur.scaledDebt) + scaled).toUint128();
        r.totalScaledDebt = newTotalScaledDebt.toUint128();
        r.cash = (uint256(r.cash) - amount).toUint128();

        uint256 cfg = _userConfig[msg.sender];
        if (!cfg.isBorrowing(id)) {
            cfg = cfg.setBorrowing(id, true);
            _userConfig[msg.sender] = cfg;
        }

        RiskEngine.requireWithinBorrowCapacity(
            _reserves, _reservesList, _userReserves[msg.sender], cfg, _oracle
        );

        r.updateRates(asset);
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrow(asset, msg.sender, amount, r.borrowRate);
    }

    /// @inheritdoc ILendingPool
    /// @dev Intentionally allowed while paused. `amount >= debt` (e.g. type(uint256).max) repays in full.
    function repay(address asset, uint256 amount, address onBehalfOf)
        external
        nonReentrant
        returns (uint256)
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        ValidationLogic.validateRepay(r.config, amount, onBehalfOf);

        r.accrue();
        uint256 id = r.id;
        DataTypes.UserReserve storage ur = _userReserves[onBehalfOf][id];
        uint256 scaledDebt = ur.scaledDebt;
        if (scaledDebt == 0) revert Errors.NoDebt();

        uint256 index = r.borrowIndex;
        uint256 debt = scaledDebt.rayMulUp(index);
        uint256 payback;
        uint256 burn;
        if (amount >= debt) {
            payback = debt;
            burn = scaledDebt;
        } else {
            payback = amount;
            burn = amount.rayDivDown(index);
            if (burn == 0) revert Errors.AmountTooSmall();
        }

        ur.scaledDebt = (scaledDebt - burn).toUint128();
        r.totalScaledDebt = (uint256(r.totalScaledDebt) - burn).toUint128();
        r.cash = (uint256(r.cash) + payback).toUint128();
        if (burn == scaledDebt) _userConfig[onBehalfOf] = _userConfig[onBehalfOf].setBorrowing(id, false);

        r.updateRates(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), payback);
        emit Repay(asset, onBehalfOf, msg.sender, payback);
        return payback;
    }

    /// @inheritdoc ILendingPool
    function setUseReserveAsCollateral(address asset, bool enabled) external nonReentrant {
        DataTypes.ReserveData storage r = _reserves[asset];
        ValidationLogic.validateSetCollateral(r.config, enabled, _paused);

        uint256 id = r.id;
        if (_userReserves[msg.sender][id].scaledSupply == 0) revert Errors.NoSupply();

        uint256 cfg = _userConfig[msg.sender];
        if (cfg.isCollateral(id) == enabled) return;
        cfg = cfg.setCollateral(id, enabled);
        _userConfig[msg.sender] = cfg;

        if (!enabled && cfg.isBorrowingAny()) {
            RiskEngine.requireWithinBorrowCapacity(
                _reserves, _reservesList, _userReserves[msg.sender], cfg, _oracle
            );
        }
        emit ReserveUsedAsCollateral(asset, msg.sender, enabled);
    }

    // ================================================================== liquidation & losses

    /// @inheritdoc ILendingPool
    /// @param debtToCover Maximum debt the caller is willing to repay; capped by the close factor.
    /// @param receiveSupply Take the seized collateral as a supply position instead of underlying.
    function liquidate(
        address collateralAsset,
        address debtAsset,
        address borrower,
        uint256 debtToCover,
        bool receiveSupply
    ) external nonReentrant returns (uint256, uint256) {
        if (debtToCover == 0) revert Errors.ZeroAmount();
        if (_paused) revert Errors.PoolPaused();
        if (block.timestamp < _liquidationGraceUntil) revert Errors.LiquidationGracePeriod();

        return LiquidationLogic.executeLiquidation(
            _reserves,
            _reservesList,
            _userReserves,
            _userConfig,
            _oracle,
            LiquidationLogic.LiquidationParams({
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                borrower: borrower,
                debtToCover: debtToCover,
                receiveSupply: receiveSupply
            })
        );
    }

    /// @inheritdoc ILendingPool
    /// @notice Recapitalise a reserve's recognised bad debt. Permissionless: a treasury, insurance
    ///         fund or any benefactor can restore full backing for suppliers.
    function coverDeficit(address asset, uint256 amount) external nonReentrant returns (uint256) {
        if (amount == 0) revert Errors.ZeroAmount();
        DataTypes.ReserveData storage r = _reserves[asset];
        uint256 deficit = r.deficit;
        if (deficit == 0) revert Errors.NoDeficit();
        if (amount > deficit) amount = deficit;

        r.accrue();
        r.deficit = (deficit - amount).toUint128();
        r.cash = (uint256(r.cash) + amount).toUint128();
        r.updateRates(asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit DeficitCovered(asset, msg.sender, amount);
        return amount;
    }

    // ================================================================== configurator-only

    /// @inheritdoc ILendingPool
    function initReserve(address asset, address interestRateModel, DataTypes.ReserveConfig calldata config)
        external
        onlyConfigurator
    {
        if (asset == address(0) || interestRateModel == address(0)) revert Errors.ZeroAddress();
        DataTypes.ReserveData storage r = _reserves[asset];
        if (r.lastUpdateTimestamp != 0) revert Errors.ReserveAlreadyInitialized();
        uint256 id = _reservesCount;
        if (id >= MAX_RESERVES) revert Errors.MaxReservesReached();

        r.config = config;
        r.liquidityIndex = uint128(WadRayMath.RAY);
        r.borrowIndex = uint128(WadRayMath.RAY);
        r.interestRateModel = interestRateModel;
        r.lastUpdateTimestamp = uint40(block.timestamp);
        // Both casts are bounded by the MAX_RESERVES (32) check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.id = uint16(id);
        _reservesList[id] = asset;
        // forge-lint: disable-next-line(unsafe-typecast)
        _reservesCount = uint16(id + 1);

        r.updateRates(asset);
        emit ReserveInitialized(asset, id, interestRateModel);
        emit ReserveConfigUpdated(asset, config);
    }

    /// @inheritdoc ILendingPool
    /// @dev Accrues first: a reserve-factor change must not apply retroactively to elapsed time.
    function setReserveConfig(address asset, DataTypes.ReserveConfig calldata config)
        external
        onlyConfigurator
    {
        DataTypes.ReserveData storage r = _requireListed(asset);
        if (config.decimals != r.config.decimals) revert Errors.InvalidDecimals();
        r.accrue();
        r.config = config;
        r.updateRates(asset);
        emit ReserveConfigUpdated(asset, config);
    }

    /// @inheritdoc ILendingPool
    /// @dev Accrues at the old model's rate up to now, then prices the next interval with the new one.
    function setInterestRateModel(address asset, address interestRateModel) external onlyConfigurator {
        if (interestRateModel == address(0)) revert Errors.ZeroAddress();
        DataTypes.ReserveData storage r = _requireListed(asset);
        r.accrue();
        address old = r.interestRateModel;
        r.interestRateModel = interestRateModel;
        r.updateRates(asset);
        emit InterestRateModelUpdated(asset, old, interestRateModel);
    }

    /// @inheritdoc ILendingPool
    /// @dev Unpausing opens a liquidation grace window so borrowers can react to interest and price
    ///      moves that happened while they were unable to act.
    function setPoolPaused(bool paused_) external onlyConfigurator {
        _paused = paused_;
        uint256 graceUntil = _liquidationGraceUntil;
        if (!paused_) {
            graceUntil = block.timestamp + _liquidationGracePeriod;
            // uint40 seconds overflow in year 36812; the grace period itself is capped at 4 hours.
            // forge-lint: disable-next-line(unsafe-typecast)
            _liquidationGraceUntil = uint40(graceUntil);
        }
        emit PoolPauseUpdated(paused_, graceUntil);
    }

    /// @inheritdoc ILendingPool
    function setLiquidationGracePeriod(uint32 gracePeriod) external onlyConfigurator {
        if (gracePeriod > MAX_GRACE_PERIOD) revert Errors.InvalidGracePeriod();
        _liquidationGracePeriod = gracePeriod;
        emit LiquidationGracePeriodUpdated(gracePeriod);
    }

    /// @inheritdoc ILendingPool
    function setOracle(address oracle_) external onlyConfigurator {
        if (oracle_ == address(0)) revert Errors.ZeroAddress();
        emit OracleUpdated(address(_oracle), oracle_);
        _oracle = IOracleManager(oracle_);
    }

    /// @inheritdoc ILendingPool
    /// @notice Withdraw accumulated reserve-factor income. It is the reserve's first-loss buffer, so
    ///         withdrawing it is a governance (timelocked) decision.
    function withdrawReserves(address asset, uint256 amount, address to)
        external
        onlyConfigurator
        returns (uint256)
    {
        if (to == address(0)) revert Errors.ZeroAddress();
        DataTypes.ReserveData storage r = _requireListed(asset);
        r.accrue();

        uint256 index = r.liquidityIndex;
        uint256 treasuryScaled = r.accruedToTreasury;
        uint256 available = treasuryScaled.rayMulDown(index);
        uint256 burn;
        if (amount >= available) {
            amount = available;
            burn = treasuryScaled;
        } else {
            burn = amount.rayDivUp(index);
        }
        if (amount == 0) revert Errors.InsufficientReserves();
        if (amount > r.cash) revert Errors.InsufficientLiquidity();

        r.accruedToTreasury = (treasuryScaled - burn).toUint128();
        r.cash = (uint256(r.cash) - amount).toUint128();
        r.updateRates(asset);

        IERC20(asset).safeTransfer(to, amount);
        emit ReservesWithdrawn(asset, to, amount);
        return amount;
    }

    // ================================================================== views

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory) {
        return _reserves[asset];
    }

    function getReserveConfig(address asset) external view returns (DataTypes.ReserveConfig memory) {
        return _reserves[asset].config;
    }

    function getReservesList() external view returns (address[] memory list) {
        uint256 count = _reservesCount;
        list = new address[](count);
        for (uint256 i; i < count; ++i) {
            list[i] = _reservesList[i];
        }
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return _reserves[asset].normalizedIncome();
    }

    function getReserveNormalizedDebt(address asset) external view returns (uint256) {
        return _reserves[asset].normalizedDebt();
    }

    /// @notice Total supply liabilities (suppliers + treasury) as of now.
    function totalSupplied(address asset) external view returns (uint256) {
        return _reserves[asset].totalSupplyLiabilities();
    }

    function totalBorrowed(address asset) external view returns (uint256) {
        DataTypes.ReserveData storage r = _reserves[asset];
        return uint256(r.totalScaledDebt).rayMulUp(r.normalizedDebt());
    }

    /// @notice Reserve-factor income owed to the protocol as of now (including not-yet-written accrual).
    function treasuryBalance(address asset) external view returns (uint256) {
        DataTypes.ReserveData storage r = _reserves[asset];
        return r.treasuryScaledNow().rayMulDown(r.normalizedIncome());
    }

    function supplyBalanceOf(address asset, address user) external view returns (uint256) {
        DataTypes.ReserveData storage r = _reserves[asset];
        return uint256(_userReserves[user][r.id].scaledSupply).rayMulDown(r.normalizedIncome());
    }

    function debtBalanceOf(address asset, address user) external view returns (uint256) {
        DataTypes.ReserveData storage r = _reserves[asset];
        return uint256(_userReserves[user][r.id].scaledDebt).rayMulUp(r.normalizedDebt());
    }

    /// @notice Raw scaled balances: what reconciliation (indexer, invariant suite) sums against the totals.
    function getUserScaledBalances(address asset, address user) external view returns (uint256, uint256) {
        DataTypes.UserReserve memory ur = _userReserves[user][_reserves[asset].id];
        return (ur.scaledSupply, ur.scaledDebt);
    }

    function getUserConfiguration(address user) external view returns (uint256) {
        return _userConfig[user];
    }

    function isUsingAsCollateral(address asset, address user) external view returns (bool) {
        DataTypes.ReserveData storage r = _reserves[asset];
        return r.lastUpdateTimestamp != 0 && _userConfig[user].isCollateral(r.id);
    }

    /// @notice Account valuation at current prices. Reverts if an exposed asset's oracle is unhealthy;
    ///         use PoolLens for a non-reverting batch variant.
    function getUserAccountData(address user) external view returns (DataTypes.AccountData memory) {
        return RiskEngine.calculateAccountData(
            _reserves, _reservesList, _userReserves[user], _userConfig[user], _oracle
        );
    }

    function oracle() external view returns (IOracleManager) {
        return _oracle;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function liquidationGraceUntil() external view returns (uint256) {
        return _liquidationGraceUntil;
    }

    function liquidationGracePeriod() external view returns (uint256) {
        return _liquidationGracePeriod;
    }

    function _onlyConfigurator() internal view {
        if (!ACL.hasRole(Roles.CONFIGURATOR, msg.sender)) revert Errors.NotConfigurator();
    }

    function _requireListed(address asset) internal view returns (DataTypes.ReserveData storage r) {
        r = _reserves[asset];
        if (r.lastUpdateTimestamp == 0) revert Errors.ReserveNotActive();
    }
}
