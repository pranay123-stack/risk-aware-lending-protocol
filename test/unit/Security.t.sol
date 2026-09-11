// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingPool} from "../../contracts/core/LendingPool.sol";
import {PoolConfigurator} from "../../contracts/core/PoolConfigurator.sol";
import {AggregatorV3Interface} from "../../contracts/interfaces/AggregatorV3Interface.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {IReentryHook, ReentrantToken} from "../mocks/ReentrantToken.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Attacker that re-enters the pool from a token transfer hook.
contract ReentryAttacker is IReentryHook {
    LendingPool public immutable pool;
    address public immutable borrowAsset;
    bool public armed;
    bytes public lastRevert;
    uint256 public observedSupplyDuringHook;
    address public hookToken;

    constructor(LendingPool pool_, address borrowAsset_) {
        pool = pool_;
        borrowAsset = borrowAsset_;
    }

    function arm(address token) external {
        armed = true;
        hookToken = token;
    }

    function onTokenTransfer(address, address to, uint256) external {
        if (!armed || to != address(this)) return;
        armed = false;
        // Read-only view during the callback: CEI means state is already final.
        observedSupplyDuringHook = pool.supplyBalanceOf(hookToken, address(this));
        // Re-entry attempt: borrow against collateral that is mid-withdrawal.
        try pool.borrow(borrowAsset, 1e6) {
            lastRevert = "";
        } catch (bytes memory reason) {
            lastRevert = reason;
        }
    }

    function supply(address token, uint256 amount) external {
        ReentrantToken(token).approve(address(pool), amount);
        pool.supply(token, amount, address(this));
    }

    function withdraw(address token, uint256 amount) external {
        pool.withdraw(token, amount, address(this));
    }
}

contract SecurityTest is BaseTest {
    // ================================================================== reentrancy

    function _listHookToken() internal returns (ReentrantToken hookToken) {
        vm.startPrank(admin);
        hookToken = new ReentrantToken();
        MockAggregator feed = new MockAggregator(8, "HOOK / USD", 1e8, admin);
        oracle.setAssetOracle(
            address(hookToken), feed, 1 days, AggregatorV3Interface(address(0)), 0, 0, 1e16, 1e20
        );
        configurator.initReserve(
            PoolConfigurator.InitReserveInput({
                asset: address(hookToken),
                interestRateModel: address(usdcIrm),
                ltv: 5000,
                liquidationThreshold: 6000,
                liquidationBonus: 1000,
                reserveFactor: 1000,
                supplyCap: 0,
                borrowCap: 0,
                borrowingEnabled: true,
                collateralEnabled: true
            })
        );
        vm.stopPrank();
    }

    /// @dev The attacker withdraws hook-token collateral; in the transfer callback it tries to
    ///      borrow against the collateral it is withdrawing. The transient lock rejects the
    ///      re-entry, and CEI means any read during the callback already sees the post-withdraw state.
    function test_reentrancyFromTokenHook_isBlocked() public {
        ReentrantToken hookToken = _listHookToken();
        _supply(alice, usdc, 100_000e6);

        ReentryAttacker attacker = new ReentryAttacker(pool, address(usdc));
        hookToken.mint(address(attacker), 10_000e18);
        attacker.supply(address(hookToken), 10_000e18);

        hookToken.setHook(attacker);
        attacker.arm(address(hookToken));
        attacker.withdraw(address(hookToken), 10_000e18);

        assertEq(
            bytes4(attacker.lastRevert()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(attacker.observedSupplyDuringHook(), 0, "state final before the external call");
        assertEq(pool.debtBalanceOf(address(usdc), address(attacker)), 0);
    }

    // ================================================================== donation

    /// @dev Tokens sent straight to the pool change nothing: no index, rate, cash or balance moves,
    ///      and nobody can claim them.
    function test_directDonation_doesNotAffectAccounting() public {
        _openBobPosition();
        DataTypes.ReserveData memory before = _reserve(usdc);
        uint256 aliceBefore = pool.supplyBalanceOf(address(usdc), alice);

        deal(address(usdc), carol, 1_000_000e6);
        vm.prank(carol);
        assertTrue(usdc.transfer(address(pool), 1_000_000e6));

        DataTypes.ReserveData memory afterDonation = _reserve(usdc);
        assertEq(afterDonation.cash, before.cash);
        assertEq(afterDonation.liquidityIndex, before.liquidityIndex);
        assertEq(afterDonation.liquidityRate, before.liquidityRate);
        assertEq(afterDonation.borrowRate, before.borrowRate);
        assertEq(pool.supplyBalanceOf(address(usdc), alice), aliceBefore);

        _warpAndRefresh(30 days);
        _supply(carol, usdc, 1e6);
        // interest still follows real utilization (15%), not the donation-inflated balance
        assertEq(_reserve(usdc).cash, before.cash + 1e6);
    }

    // ================================================================== same-block manipulation

    /// @dev A flash-loan-sized position opened and closed in one block cannot move anyone's
    ///      balance: indexes advance only with elapsed time, and every rate is time-weighted.
    function test_sameBlockUtilizationSpike_movesNoBalances() public {
        _openBobPosition();
        uint256 aliceBefore = pool.supplyBalanceOf(address(usdc), alice);
        uint256 bobDebtBefore = pool.debtBalanceOf(address(usdc), bob);

        address whale = makeAddr("whale");
        _supply(whale, weth, 50_000e18);
        _borrow(whale, usdc, 85_000e6); // utilization 100%: rates jump to the max
        assertGt(_reserve(usdc).borrowRate, 0.6e27);
        _repay(whale, usdc, type(uint128).max);
        _withdraw(whale, weth, type(uint256).max);

        assertEq(pool.supplyBalanceOf(address(usdc), alice), aliceBefore);
        assertEq(pool.debtBalanceOf(address(usdc), bob), bobDebtBefore);
    }

    // ================================================================== DoS bound

    /// @dev MAX_RESERVES bounds the account-valuation loop. An account exposed to every listed
    ///      reserve can still be valued, and therefore liquidated, well inside a block.
    function test_accountValuationGasBoundedAtMaxReserves() public {
        vm.startPrank(admin);
        MockERC20[] memory tokens = new MockERC20[](29);
        for (uint256 i; i < 29; ++i) {
            tokens[i] = new MockERC20("T", "T", 18, 1_000_000);
            MockAggregator feed = new MockAggregator(8, "T / USD", 1e8, admin);
            oracle.setAssetOracle(
                address(tokens[i]), feed, 1 days, AggregatorV3Interface(address(0)), 0, 0, 1e16, 1e20
            );
            configurator.initReserve(
                PoolConfigurator.InitReserveInput({
                    asset: address(tokens[i]),
                    interestRateModel: address(usdcIrm),
                    ltv: 5000,
                    liquidationThreshold: 6000,
                    liquidationBonus: 1000,
                    reserveFactor: 1000,
                    supplyCap: 0,
                    borrowCap: 0,
                    borrowingEnabled: true,
                    collateralEnabled: true
                })
            );
        }
        vm.stopPrank();
        assertEq(pool.getReservesList().length, 32);

        for (uint256 i; i < 29; ++i) {
            _supply(bob, tokens[i], 1000e18);
        }
        _supply(alice, usdc, 1_000_000e6);
        _supply(bob, weth, 1e18);
        _supply(bob, wbtc, 1e6);
        _borrow(bob, usdc, 1000e6);

        uint256 g = gasleft();
        pool.getUserAccountData(bob);
        uint256 used = g - gasleft();
        assertLt(used, 1_000_000, "valuing a max-exposure account costs < 1M gas");
    }
}
