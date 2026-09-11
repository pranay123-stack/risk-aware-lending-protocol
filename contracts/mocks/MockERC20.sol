// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Freely mintable test token with configurable decimals (WETH 18, WBTC 8, USDC 6).
///         Minting is open, capped per call so a public testnet faucet cannot be trivially abused.
///         Mock tokens carry no value; the protocol never touches real assets.
contract MockERC20 is ERC20 {
    error FaucetLimitExceeded(uint256 requested, uint256 limit);

    uint8 private immutable _decimals;
    uint256 public immutable faucetLimit;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetLimitWholeTokens)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
        faucetLimit = faucetLimitWholeTokens * 10 ** decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        if (amount > faucetLimit) revert FaucetLimitExceeded(amount, faucetLimit);
        _mint(to, amount);
    }
}
