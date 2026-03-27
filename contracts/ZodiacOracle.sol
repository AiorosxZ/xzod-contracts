// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IZodiacOracle.sol";

contract ZodiacOracle is Ownable, IZodiacOracle {

    // Constants
    uint256 public constant N_SIGNS = 12;
    uint256 public constant SIGN_DURATION_SECONDS = 30 days;

    // Storage — override removed (these variables are not in the interface)
    uint32 public currentZodiacIndex;
    uint32 public lastUpdateTimestamp;

    // Pauser/Admin address
    address public pauserAddress;

    constructor(address initialOwner) Ownable(initialOwner) {
        lastUpdateTimestamp = uint32(block.timestamp);
        currentZodiacIndex = 0;
    }

    // Admin functions
    function setPauser(address newPauserAddress) external onlyOwner {
        if (newPauserAddress == address(0)) revert('ZeroAddress');
        pauserAddress = newPauserAddress;
    }

    function manualUpdateZodiacSign(uint32 newIndex) external {
        if (msg.sender != owner() && msg.sender != pauserAddress) {
            revert('Unauthorized');
        }
        if (newIndex >= N_SIGNS) revert('BadIndex');

        currentZodiacIndex = newIndex;
        lastUpdateTimestamp = uint32(block.timestamp);

        emit ZodiacSignUpdated(newIndex, lastUpdateTimestamp);
    }

    // Core function — writes state, cannot be view
    function getCurrentZodiacIndex() public override returns (uint32) {
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;

        if (timeElapsed < SIGN_DURATION_SECONDS) {
            return currentZodiacIndex;
        }

        uint256 cyclesElapsed = timeElapsed / SIGN_DURATION_SECONDS;

        currentZodiacIndex = uint32(
            (uint256(currentZodiacIndex) + cyclesElapsed) % N_SIGNS
        );

        // ✅ Drift fix: preserve the time already elapsed in the current period
        lastUpdateTimestamp = uint32(
            lastUpdateTimestamp + cyclesElapsed * SIGN_DURATION_SECONDS
        );

        emit ZodiacSignUpdated(currentZodiacIndex, lastUpdateTimestamp);

        return currentZodiacIndex;
    }

    // ✅ Read-only for frontend — no state modification
    function peekCurrentZodiacIndex() external view returns (uint32) {
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        if (timeElapsed < SIGN_DURATION_SECONDS) {
            return currentZodiacIndex;
        }
        uint256 cyclesElapsed = timeElapsed / SIGN_DURATION_SECONDS;
        return uint32((uint256(currentZodiacIndex) + cyclesElapsed) % N_SIGNS);
    }
}
