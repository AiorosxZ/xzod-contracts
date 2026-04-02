// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ZodiacToken
 * @notice Generic ERC-20 template for the 12 ZOD sub-tokens.
 *         Each sign (ZARI, ZTAU, ZGEM... ZPIS) is deployed from this contract
 *         with its own name, symbol, and initial supply.
 *         ZOD tokens are protocol-only — not listed on external exchanges.
 *         Only obtainable via xZOD conversion through the ReservePool.
 */
contract ZodiacToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply
    ) ERC20(name_, symbol_) {
        _mint(msg.sender, initialSupply);
    }
}
