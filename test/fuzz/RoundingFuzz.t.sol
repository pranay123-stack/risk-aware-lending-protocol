// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice Rounding-exploitation fuzzing. An attacker who can extract even 1 wei per round trip can
///         loop it in a flash loan. Every property here says "no sequence creates value from nothing".
contract RoundingFuzzTest is BaseTest {
    /// @dev Grow indexes to an awkward, non-round value so rounding actually bites.
    function _ageMarkets(uint32 dt) internal {
        _supply(alice, usdc, 1_000_000e6);
        _supply(alice, weth, 1000e18);
        _supply(carol, wbtc, 100e8);
        _borrow(carol, usdc, 700_000e6);
        _borrow(carol, weth, 700e18);
        _warpAndRefresh(bound(dt, 1, 3 * 365 days));
        _repay(carol, usdc, 1e6);
        _repay(carol, weth, 1e12);
    }

    function _token(uint8 which) internal view returns (MockERC20) {
        return which % 2 == 0 ? usdc : weth;
    }

    /// @notice supply x then withdraw everything in the same block returns at most x.
    function testFuzz_supplyWithdrawRoundTripNeverProfits(uint32 dt, uint8 which, uint96 amount) public {
        _ageMarkets(dt);
        MockERC20 t = _token(which);
        amount = uint96(bound(amount, 1, t == usdc ? 50_000_000e6 : 10_000e18));
        deal(address(t), bob, amount);
        vm.startPrank(bob);
        t.approve(address(pool), amount);
        try pool.supply(address(t), amount, bob) {
            pool.withdraw(address(t), type(uint256).max, bob);
        } catch {}
        vm.stopPrank();
        assertLe(t.balanceOf(bob), amount, "round trip created value");
    }

    /// @notice borrow x then repay in full in the same block costs at least x.
    function testFuzz_borrowRepayRoundTripCostsAtLeastPrincipal(uint32 dt, uint8 which, uint96 amount)
        public
    {
        _ageMarkets(dt);
        MockERC20 t = _token(which);
        _supply(bob, wbtc, 50e8); // $3M of collateral
        amount = uint96(bound(amount, 1, t == usdc ? 200_000e6 : 50e18));
        vm.prank(bob);
        try pool.borrow(address(t), amount) {
            uint256 owed = pool.debtBalanceOf(address(t), bob);
            assertGe(owed, amount, "borrower owes less than borrowed");
            uint256 paid = _repay(bob, t, owed);
            assertGe(paid, amount);
            assertEq(pool.debtBalanceOf(address(t), bob), 0);
        } catch {}
    }

    /// @notice Splitting one deposit into many small ones never yields a larger balance than
    ///         depositing once. Rounding down per call can only cost the splitter.
    function testFuzz_splitDepositsNeverBeatSingleDeposit(uint32 dt, uint64 total, uint8 pieces) public {
        _ageMarkets(dt);
        total = uint64(bound(total, 1000, 10_000_000e6));
        pieces = uint8(bound(pieces, 2, 20));

        address splitter = makeAddr("splitter");
        address single = makeAddr("single");
        uint256 piece = total / pieces;
        if (piece < 2) return;
        for (uint256 i; i < pieces; ++i) {
            _supply(splitter, usdc, piece);
        }
        _supply(single, usdc, piece * pieces);
        assertLe(pool.supplyBalanceOf(address(usdc), splitter), pool.supplyBalanceOf(address(usdc), single));
    }

    /// @notice Many partial withdrawals never extract more than one full withdrawal.
    function testFuzz_partialWithdrawalsNeverBeatFullWithdrawal(uint32 dt, uint64 amount, uint8 pieces)
        public
    {
        _ageMarkets(dt);
        amount = uint64(bound(amount, 1000e6, 10_000_000e6));
        pieces = uint8(bound(pieces, 2, 20));
        _supply(bob, usdc, amount);
        uint256 balance = pool.supplyBalanceOf(address(usdc), bob);

        // Each partial burn rounds UP, so the balance can fall by piece + 1 wei per call and the last
        // piece may exceed what is left. Clamp to the live balance, as a real client would.
        uint256 piece = balance / pieces;
        uint256 out;
        for (uint256 i; i < pieces; ++i) {
            uint256 live = pool.supplyBalanceOf(address(usdc), bob);
            if (live == 0) break;
            out += _withdraw(bob, usdc, piece < live ? piece : live);
        }
        if (pool.supplyBalanceOf(address(usdc), bob) != 0) out += _withdraw(bob, usdc, type(uint256).max);
        assertLe(out, balance, "partial withdrawals extracted extra");
    }

    /// @notice Many partial repayments never clear more debt than they pay for.
    function testFuzz_partialRepaysNeverForgiveDebt(uint32 dt, uint64 amount, uint8 pieces) public {
        _ageMarkets(dt);
        _supply(bob, wbtc, 50e8);
        amount = uint64(bound(amount, 1000e6, 200_000e6));
        pieces = uint8(bound(pieces, 2, 20));
        _borrow(bob, usdc, amount);
        uint256 owed = pool.debtBalanceOf(address(usdc), bob);

        uint256 paid;
        uint256 piece = owed / pieces;
        for (uint256 i; i < pieces; ++i) {
            paid += _repay(bob, usdc, piece);
        }
        // With exact division the last partial may already clear the debt.
        if (pool.debtBalanceOf(address(usdc), bob) != 0) paid += _repay(bob, usdc, type(uint128).max);
        assertGe(paid, owed, "repaid less than owed in total");
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
    }

    /// @notice Interest over arbitrary, irregular touch patterns keeps each reserve solvent.
    function testFuzz_irregularAccrualStaysSolvent(uint32[6] memory gaps) public {
        _ageMarkets(1);
        for (uint256 i; i < gaps.length; ++i) {
            _warpAndRefresh(bound(gaps[i], 1, 120 days));
            _repay(carol, usdc, 1e6);
            _supply(bob, usdc, 1e6);
        }
        DataTypes.ReserveData memory r = _reserve(usdc);
        assertGe(uint256(r.cash) + pool.totalBorrowed(address(usdc)) + 2, pool.totalSupplied(address(usdc)));
    }
}
