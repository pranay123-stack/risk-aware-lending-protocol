// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingPool} from "../../contracts/core/LendingPool.sol";
import {DataTypes} from "../../contracts/libraries/DataTypes.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {LendingVault} from "../../contracts/periphery/LendingVault.sol";
import {PoolLens} from "../../contracts/periphery/PoolLens.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Shared plumbing for the demo scripts: loads deployments/<chainId>.json, derives the demo
///         accounts from Anvil's public test mnemonic and pretty-prints protocol state.
abstract contract DemoBase is Script {
    /// @dev Anvil's default mnemonic. Every key it derives is public knowledge: local use only.
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    LendingPool internal pool;
    PoolLens internal lens;
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal usdc;
    MockAggregator internal wethFeed;
    MockAggregator internal wethFeed2;
    LendingVault internal usdcVault;

    uint256 internal deployerKey;
    uint256 internal aliceKey;
    uint256 internal bobKey;
    uint256 internal carolKey;
    uint256 internal liquidatorKey;
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal liquidator;

    function _load() internal {
        require(block.chainid == 31_337, "demo scripts use public Anvil keys: local chain only");
        string memory path = vm.envOr(
            "DEPLOYMENT_FILE",
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json")
        );
        string memory json = vm.readFile(path);
        pool = LendingPool(vm.parseJsonAddress(json, ".contracts.lendingPool"));
        lens = PoolLens(vm.parseJsonAddress(json, ".contracts.poolLens"));
        weth = MockERC20(vm.parseJsonAddress(json, ".markets[0].token"));
        wbtc = MockERC20(vm.parseJsonAddress(json, ".markets[1].token"));
        usdc = MockERC20(vm.parseJsonAddress(json, ".markets[2].token"));
        wethFeed = MockAggregator(vm.parseJsonAddress(json, ".markets[0].primaryFeed"));
        wethFeed2 = MockAggregator(vm.parseJsonAddress(json, ".markets[0].secondaryFeed"));
        usdcVault = LendingVault(vm.parseJsonAddress(json, ".markets[2].vault"));

        deployerKey = vm.deriveKey(ANVIL_MNEMONIC, 0);
        aliceKey = vm.deriveKey(ANVIL_MNEMONIC, 1);
        bobKey = vm.deriveKey(ANVIL_MNEMONIC, 2);
        carolKey = vm.deriveKey(ANVIL_MNEMONIC, 3);
        liquidatorKey = vm.deriveKey(ANVIL_MNEMONIC, 4);
        deployer = vm.addr(deployerKey);
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        carol = vm.addr(carolKey);
        liquidator = vm.addr(liquidatorKey);
    }

    // ------------------------------------------------------------------ printing

    function _step(string memory title) internal pure {
        console2.log("");
        console2.log(string.concat("==> ", title));
    }

    function _printMarkets() internal view {
        PoolLens.MarketData[] memory m = lens.getMarkets();
        console2.log(
            "  market  price(USD)     supplied        borrowed        util%   borrowAPR%  supplyAPR%"
        );
        for (uint256 i; i < m.length; ++i) {
            console2.log(string.concat("  ", _marketLeft(m[i]), _marketRight(m[i])));
        }
    }

    function _marketLeft(PoolLens.MarketData memory m) internal pure returns (string memory) {
        return string.concat(
            _pad(m.symbol, 7),
            _pad(_fmt(m.price, 18, 2), 15),
            _pad(_fmt(m.totalSupplied, m.decimals, 2), 16),
            _pad(_fmt(m.totalBorrowed, m.decimals, 2), 16)
        );
    }

    /// @dev Rates and utilization are ray (1e27); 25 decimals turns them into percent.
    function _marketRight(PoolLens.MarketData memory m) internal pure returns (string memory) {
        return string.concat(
            _pad(_fmt(m.utilization, 25, 2), 8),
            _pad(_fmt(m.borrowRate, 25, 2), 12),
            _fmt(m.liquidityRate, 25, 2)
        );
    }

    function _printAccount(string memory name, address user) internal view {
        DataTypes.AccountData memory d = pool.getUserAccountData(user);
        string memory hf = d.totalDebtValue == 0 ? "no debt" : _fmt(d.healthFactor, 18, 4);
        string memory left = string.concat(
            "  ", _pad(name, 11), "collateral $", _pad(_fmt(d.totalCollateralValue, 18, 2), 13)
        );
        string memory right = string.concat(
            "debt $",
            _pad(_fmt(d.totalDebtValue, 18, 2), 12),
            "capacity $",
            _pad(_fmt(d.borrowCapacityValue, 18, 2), 13)
        );
        console2.log(string.concat(left, right, "HF ", hf));
    }

    /// @dev Fixed-point to decimal string with `precision` fractional digits (truncated).
    function _fmt(uint256 value, uint8 decimals, uint8 precision) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 whole = value / unit;
        uint256 frac = value % unit;
        if (precision == 0) return vm.toString(whole);
        uint256 scaled =
            decimals >= precision ? frac / 10 ** (decimals - precision) : frac * 10 ** (precision - decimals);
        string memory f = vm.toString(scaled);
        while (bytes(f).length < precision) f = string.concat("0", f);
        return string.concat(_thousands(whole), ".", f);
    }

    function _thousands(uint256 n) internal pure returns (string memory s) {
        if (n < 1000) return vm.toString(n);
        string memory tail = vm.toString(n % 1000);
        while (bytes(tail).length < 3) tail = string.concat("0", tail);
        return string.concat(_thousands(n / 1000), ",", tail);
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        while (bytes(s).length < width) s = string.concat(s, " ");
        return s;
    }
}
