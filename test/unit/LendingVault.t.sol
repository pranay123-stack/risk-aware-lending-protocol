// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingVault} from "../../contracts/periphery/LendingVault.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

contract LendingVaultTest is BaseTest {
    LendingVault vault;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault = ProtocolDeployer.deployVault(
            ProtocolDeployer.Core(acl, oracle, pool, configurator, lens), address(usdc)
        );
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        deal(address(usdc), user, usdc.balanceOf(user) + assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function test_metadata() public view {
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.name(), "Lending Vault USDC");
        assertEq(vault.symbol(), "lvUSDC");
        assertEq(vault.decimals(), 12); // 6 + decimals offset 6
    }

    function test_depositSuppliesToPool() public {
        uint256 shares = _deposit(alice, 1000e6);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(pool.supplyBalanceOf(address(usdc), address(vault)), 1000e6);
        assertEq(vault.totalAssets(), 1000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no idle cash");
    }

    function test_redeemReturnsPrincipal() public {
        uint256 shares = _deposit(alice, 1000e6);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_sharesAccrueSupplyInterest() public {
        _deposit(alice, 100_000e6);
        _supply(bob, weth, 100e18);
        _borrow(bob, usdc, 80_000e6);
        _warpAndRefresh(365 days);
        uint256 value = vault.previewRedeem(vault.balanceOf(alice));
        assertGt(value, 100_000e6 + 2000e6, "~3% supply APY at 80% utilization");
    }

    /// @dev Classic ERC-4626 inflation attack via the pool's supply-on-behalf path. The attacker
    ///      front-runs the first depositor with 1 wei, then donates 1,000 USDC directly into the
    ///      vault's pool position. The virtual-shares offset leaves the victim essentially whole
    ///      and turns the attack into a ~500 USDC loss for the attacker.
    function test_inflationAttack_isUnprofitable() public {
        address attacker = makeAddr("attacker");
        _deposit(attacker, 1);

        deal(address(usdc), attacker, 1000e6);
        vm.startPrank(attacker);
        usdc.approve(address(pool), 1000e6);
        pool.supply(address(usdc), 1000e6, address(vault)); // donation: no shares minted
        vm.stopPrank();

        _deposit(alice, 1000e6);

        uint256 victimValue = vault.previewRedeem(vault.balanceOf(alice));
        uint256 attackerValue = vault.previewRedeem(vault.balanceOf(attacker));
        assertGe(victimValue, 999.99e6, "victim loses < 1 cent");
        assertLe(attackerValue, 501e6, "attacker recovers only ~half of the donation");
    }

    function test_maxWithdraw_boundedByPoolLiquidity() public {
        _deposit(alice, 10_000e6);
        _supply(bob, weth, 100e18);
        _borrow(bob, usdc, 9000e6);
        assertEq(vault.maxWithdraw(alice), 1000e6);
        assertEq(vault.maxRedeem(alice), vault.convertToShares(1000e6));

        vm.prank(alice);
        vault.withdraw(1000e6, alice, alice); // exactly the max works
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxDeposit_reflectsPauseFreezeAndCap() public {
        assertEq(vault.maxDeposit(alice), 100_000_000e6); // supply cap headroom
        _deposit(alice, 1000e6);
        assertEq(vault.maxDeposit(alice), 100_000_000e6 - 1000e6);

        vm.prank(guardian);
        configurator.setReserveFrozen(address(usdc), true);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertGt(vault.maxWithdraw(alice), 0, "frozen reserve still lets lenders exit");

        vm.prank(guardian);
        configurator.setPoolPaused(true);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    /// @dev The vault never borrows, so its withdrawals never read an oracle.
    function test_vaultRedeemableDuringOracleOutage() public {
        uint256 shares = _deposit(alice, 1000e6);
        vm.prank(admin);
        usdcFeed.setReverting(true);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 1000e6);
    }

    function test_allowanceRequiredForThirdPartyRedeem() public {
        uint256 shares = _deposit(alice, 1000e6);
        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(shares, bob, alice);

        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        vault.redeem(shares, bob, alice);
        assertEq(usdc.balanceOf(bob), 1000e6);
    }

    /// @dev Found by fuzzing: once the supply index exceeds 1, a 1-wei deposit rounds to zero
    ///      scaled units and the pool rejects it. That rejection protects vault holders: if the
    ///      pool accepted it, the vault would mint shares for a deposit that credited it nothing.
    function test_dustDepositRejected_protectsExistingHolders() public {
        _deposit(carol, 1000e6);
        _supply(bob, weth, 10e18);
        _borrow(bob, usdc, 900e6);
        _warpAndRefresh(30 days);
        _supply(bob, weth, 1e18); // touch: index > 1 is now written
        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        deal(address(usdc), alice, 1);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        vm.expectRevert();
        vault.deposit(1, alice);
        vm.stopPrank();
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.totalSupply(), supplyBefore);
    }

    /// @dev Round-tripping through the vault never creates value.
    function testFuzz_depositRedeemNeverProfits(uint64 seedDeposit, uint64 amount, uint32 dt) public {
        seedDeposit = uint64(bound(seedDeposit, 1, 1e12));
        amount = uint64(bound(amount, 2, 1e13)); // >= 2 wei (see dust test), below the supply cap
        _deposit(carol, seedDeposit);
        _supply(bob, weth, 1000e18);
        uint256 borrowAmt = seedDeposit / 2;
        if (borrowAmt > 0) _borrow(bob, usdc, borrowAmt);
        _warpAndRefresh(bound(dt, 0, 30 days));

        uint256 shares = _deposit(alice, amount);
        if (shares == 0) return;
        vm.prank(alice);
        try vault.redeem(shares, alice, alice) returns (uint256 out) {
            assertLe(out, amount);
        } catch {}
    }
}
