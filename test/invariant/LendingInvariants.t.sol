// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {UserConfiguration} from "../../contracts/libraries/UserConfiguration.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {LendingVault} from "../../contracts/periphery/LendingVault.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {LendingHandler} from "./LendingHandler.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice Protocol-wide invariants under random sequences of supply, withdraw, borrow, repay,
///         collateral toggles, liquidations, deficit coverage, vault flows, price moves and time.
///         See docs/testing.md for what each invariant protects against.
contract LendingInvariants is StdInvariant, BaseTest {
    using UserConfiguration for uint256;

    LendingHandler internal handler;
    LendingVault internal vault;
    MockERC20[3] internal toks;

    /// @dev Rounding slack for aggregate comparisons: every per-operation rounding favours the
    ///      protocol, and aggregate reads (sum-then-multiply vs multiply-then-sum) differ by at
    ///      most a few wei.
    uint256 internal constant DUST = 10;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault = ProtocolDeployer.deployVault(
            ProtocolDeployer.Core(acl, oracle, pool, configurator, lens), address(usdc)
        );

        toks = [weth, wbtc, usdc];
        handler = new LendingHandler(pool, lens, vault, toks, [wethFeed, wbtcFeed, usdcFeed], wethFeed2);

        handler.seedMarkets();

        vm.startPrank(admin);
        wethFeed.transferOwnership(address(handler));
        wethFeed2.transferOwnership(address(handler));
        wbtcFeed.transferOwnership(address(handler));
        usdcFeed.transferOwnership(address(handler));
        vm.stopPrank();

        // Weighted action mix: user flows dominate; price moves and time are rarer, as in reality.
        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = LendingHandler.supply.selector;
        selectors[1] = LendingHandler.supply.selector;
        selectors[2] = LendingHandler.supply.selector;
        selectors[3] = LendingHandler.withdraw.selector;
        selectors[4] = LendingHandler.borrow.selector;
        selectors[5] = LendingHandler.borrow.selector;
        selectors[6] = LendingHandler.borrow.selector;
        selectors[7] = LendingHandler.repay.selector;
        selectors[8] = LendingHandler.repay.selector;
        selectors[9] = LendingHandler.setCollateral.selector;
        selectors[10] = LendingHandler.liquidate.selector;
        selectors[11] = LendingHandler.liquidate.selector;
        selectors[12] = LendingHandler.coverDeficit.selector;
        selectors[13] = LendingHandler.vaultDeposit.selector;
        selectors[14] = LendingHandler.vaultRedeem.selector;
        selectors[15] = LendingHandler.movePrice.selector;
        selectors[16] = LendingHandler.movePrice.selector;
        selectors[17] = LendingHandler.warp.selector;
        selectors[18] = LendingHandler.crash.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ================================================================== solvency

    /// @notice total assets >= total liabilities, per reserve. Assets are cash plus outstanding
    ///         debt plus recognised deficit (bad debt is never hidden, only explicitly booked).
    function invariant_reserveSolvency() public view {
        for (uint256 i; i < 3; ++i) {
            address asset = address(toks[i]);
            DataTypes.ReserveData memory r = pool.getReserveData(asset);
            uint256 assets = uint256(r.cash) + pool.totalBorrowed(asset) + r.deficit;
            assertGe(assets + DUST, pool.totalSupplied(asset), "assets < liabilities");
        }
    }

    /// @notice The pool always holds at least the cash it accounts for. With no donations in the
    ///         handler this is equality: the internal ledger and the token ledger never diverge.
    function invariant_cashMatchesTokenBalance() public view {
        for (uint256 i; i < 3; ++i) {
            assertEq(
                toks[i].balanceOf(address(pool)), pool.getReserveData(address(toks[i])).cash, "cash drift"
            );
        }
    }

    /// @notice Liquidation never destroys value: no reserve's surplus drops across a liquidation.
    function invariant_liquidationCannotCreateInsolvency() public view {
        assertEq(handler.ghost_liquidationSurplusLoss(), 0);
        assertEq(handler.ghost_liquidationOfHealthy(), 0, "healthy account liquidated");
    }

    // ================================================================== risk

    /// @notice Every accepted borrow leaves the account within its LTV-weighted capacity.
    function invariant_borrowNeverExceedsCapacity() public view {
        assertEq(handler.ghost_borrowCapacityViolations(), 0);
    }

    /// @notice Without a price move or elapsed time, no healthy account becomes liquidatable,
    ///         whoever acts (including the account itself).
    function invariant_healthyStaysHealthyWithoutRiskChange() public view {
        assertEq(handler.ghost_healthyBecameLiquidatable(), 0);
    }

    /// @notice Withdrawals never pay out more than the reserve's available liquidity.
    function invariant_withdrawRespectsLiquidity() public view {
        assertEq(handler.ghost_withdrawBeyondCash(), 0);
    }

    /// @notice An account with debt always has collateral: the pool never leaves naked debt.
    ///         Liquidations that exhaust collateral write the rest off as deficit.
    function invariant_noUncollateralizedDebt() public view {
        for (uint256 i; i < handler.actorsLength(); ++i) {
            uint256 cfg = pool.getUserConfiguration(handler.actors(i));
            if (cfg.isBorrowingAny()) assertTrue(cfg.hasCollateralAny(), "debt without collateral");
        }
    }

    // ================================================================== accounting

    /// @notice Interest indexes never decrease.
    function invariant_indexesNeverDecrease() public view {
        assertEq(handler.ghost_indexDecreases(), 0);
    }

    /// @notice Totals equal the sum of their parts, exactly, in scaled units, and the user bitmap
    ///         agrees with the balances. User debt is unsigned and the bitmap tracks it exactly, so
    ///         debt cannot go negative or linger unflagged.
    function invariant_scaledBalancesSumToTotals() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i; i < 3; ++i) {
            address asset = address(toks[i]);
            DataTypes.ReserveData memory r = pool.getReserveData(asset);
            uint256 sumSupply;
            uint256 sumDebt;
            for (uint256 j; j < n; ++j) {
                address user = handler.actors(j);
                (uint256 s, uint256 d) = pool.getUserScaledBalances(asset, user);
                sumSupply += s;
                sumDebt += d;
                uint256 cfg = pool.getUserConfiguration(user);
                assertEq(cfg.isBorrowing(r.id), d != 0, "borrowing bit out of sync");
                if (cfg.isCollateral(r.id)) assertGt(s, 0, "collateral bit without supply");
            }
            (uint256 vs, uint256 vd) = pool.getUserScaledBalances(asset, address(vault));
            sumSupply += vs;
            sumDebt += vd;
            assertEq(sumSupply, r.totalScaledSupply, "scaled supply mismatch");
            assertEq(sumDebt, r.totalScaledDebt, "scaled debt mismatch");
        }
    }

    /// @notice The ERC-4626 vault never promises more than it holds.
    function invariant_vaultBacked() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets() + 1);
        assertEq(vault.totalAssets(), pool.supplyBalanceOf(address(usdc), address(vault)));
        assertEq(vault.maxDeposit(address(0)) == 0, false); // pool never paused in this campaign
    }

    /// @dev Per-run coverage stats, appended to a CSV when INVARIANT_STATS=1 so a campaign can be
    ///      audited for what it actually exercised (see docs/testing.md).
    function afterInvariant() external {
        if (!vm.envOr("INVARIANT_STATS", false)) return;
        bytes32[13] memory keys = [
            bytes32("supply"),
            "withdraw",
            "borrow",
            "repay",
            "liquidate",
            "liquidateReceiveSupply",
            "liquidateSameAsset",
            "liquidateReverted",
            "coverDeficit",
            "vaultDeposit",
            "movePrice",
            "warp",
            "crash"
        ];
        string memory line = vm.toString(handler.ghost_badDebtEvents());
        for (uint256 i; i < keys.length; ++i) {
            line = string.concat(line, ",", vm.toString(handler.calls(keys[i])));
        }
        vm.writeLine("test-results/invariant-stats.csv", line);
    }
}
