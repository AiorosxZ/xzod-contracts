// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

// Custom errors
error UnauthorizedCaller();
error VaultAlreadySet();

/**
 * @title NFTControllerStub
 * @notice Testnet stub for NFT APY boost logic.
 *         Returns a static 10% boost for all wallets.
 *         Will be replaced by full NFTRules integration at mainnet.
 */
contract TestNFTController is Ownable {

    // Static boost of 10% (1000, DENOMINATOR = 10,000)
    uint16 public constant STATIC_BOOST = 1000;

    // Non-immutable to allow setting after deployment
    address private _vaultAddress;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Set the vault address after deployment
    function setVaultAddress(address _vault) external onlyOwner {
        if (_vaultAddress != address(0)) revert VaultAlreadySet();
        if (_vault == address(0)) revert UnauthorizedCaller();
        _vaultAddress = _vault;
    }

    /// @notice Returns the configured vault address
    function vaultAddress() public view returns (address) {
        return _vaultAddress;
    }

    /**
     * @notice Returns a static APY boost for testing purposes.
     * @dev Restricted to ZODStakingVault. The address parameter is required by the
     *      interface but ignored in this stub implementation.
     * @return APY boost in basis points (e.g. 1000 = 10%)
     */
    function getAPYBoost(address /* _player */) external view returns (uint16) {
        if (msg.sender != _vaultAddress) revert UnauthorizedCaller();
        return STATIC_BOOST;
    }
}
