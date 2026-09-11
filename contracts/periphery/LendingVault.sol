// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {Errors} from "../libraries/Errors.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendingVault
/// @notice ERC-4626 vault for passive lenders: deposits are supplied to the LendingPool and earn
///         the reserve's supply rate. Shares are freely transferable ERC-20s, usable anywhere
///         4626 is understood. The vault never borrows.
///
/// Why this shape: making the pool's own supply positions transferable would put collateral
/// transfers (and the health-factor check each one requires) on the attack surface. A vault that
/// never borrows gets composability with none of that risk. Its pool position has no debt, so
/// withdrawals never read an oracle: the vault stays redeemable during an oracle outage.
///
/// Inflation / donation attack: anyone can `pool.supply(asset, x, vault)` to push `totalAssets`
/// up without minting shares. The classic attack front-runs the first depositor to make their
/// shares round to zero. OpenZeppelin's virtual-shares offset (`_decimalsOffset`) makes that
/// attack cost the attacker ~10^offset times what it can steal (test/unit/LendingVault.t.sol).
contract LendingVault is ERC4626 {
    using SafeERC20 for IERC20;

    ILendingPool public immutable POOL;

    constructor(ILendingPool pool, IERC20Metadata asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {
        if (address(pool) == address(0)) revert Errors.ZeroAddress();
        POOL = pool;
        IERC20(address(asset_)).forceApprove(address(pool), type(uint256).max);
    }

    /// @notice Assets are the vault's pool supply balance, including interest accrued up to now.
    function totalAssets() public view override returns (uint256) {
        return POOL.supplyBalanceOf(asset(), address(this));
    }

    /// @notice ERC-4626 requires max* to reflect real limits: pause/freeze and the supply cap.
    function maxDeposit(address) public view override returns (uint256) {
        address a = asset();
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(a);
        if (!c.active || c.frozen || c.paused || POOL.paused()) return 0;
        if (c.supplyCap == 0) return type(uint256).max;
        uint256 cap = uint256(c.supplyCap) * 10 ** c.decimals;
        uint256 supplied = POOL.totalSupplied(a);
        return supplied >= cap ? 0 : cap - supplied;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == type(uint256).max ? type(uint256).max : convertToShares(assets);
    }

    /// @notice Bounded by the pool's available liquidity: at 100% utilization nothing can leave.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 liquidity = _availableLiquidity();
        uint256 owned = convertToAssets(balanceOf(owner));
        return owned < liquidity ? owned : liquidity;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 byLiquidity = convertToShares(_availableLiquidity());
        uint256 owned = balanceOf(owner);
        return owned < byLiquidity ? owned : byLiquidity;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        POOL.supply(asset(), assets, address(this));
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);
        POOL.withdraw(asset(), assets, receiver);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _availableLiquidity() internal view returns (uint256) {
        address a = asset();
        DataTypes.ReserveConfig memory c = POOL.getReserveConfig(a);
        if (!c.active || c.paused || POOL.paused()) return 0;
        return POOL.getReserveData(a).cash;
    }
}
