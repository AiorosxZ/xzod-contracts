// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────
//  xZOD Faucet — Testnet only
//  Distributes 100 xZOD per wallet every 24h
// ─────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract XZodFaucet {

    error NotOwner();
    error CooldownActive(uint256 availableAt);
    error InsufficientFaucetBalance();
    error ZeroAmount();

    event Claimed(address indexed user, uint256 amount);
    event FaucetFunded(uint256 amount);
    event AmountUpdated(uint256 newAmount);
    event CooldownUpdated(uint256 newCooldown);

    address public immutable owner;
    IERC20  public immutable xZOD;

    uint256 public claimAmount  = 100 ether; // 100 xZOD (18 decimals)
    uint256 public cooldown     = 24 hours;

    mapping(address => uint256) public lastClaim;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _xZOD) {
        owner = msg.sender;
        xZOD  = IERC20(_xZOD);
    }

    // ── User ────────────────────────────────────────────────────

    function claim() external {
        uint256 available = lastClaim[msg.sender] + cooldown;
        if (block.timestamp < available) revert CooldownActive(available);
        if (xZOD.balanceOf(address(this)) < claimAmount) revert InsufficientFaucetBalance();

        lastClaim[msg.sender] = block.timestamp;
        xZOD.transfer(msg.sender, claimAmount);

        emit Claimed(msg.sender, claimAmount);
    }

    // ── Views ───────────────────────────────────────────────────

    function nextClaimAt(address user) external view returns (uint256) {
        uint256 next = lastClaim[user] + cooldown;
        return next > block.timestamp ? next : 0;
    }

    function faucetBalance() external view returns (uint256) {
        return xZOD.balanceOf(address(this));
    }

    // ── Owner ───────────────────────────────────────────────────

    function setClaimAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        claimAmount = amount;
        emit AmountUpdated(amount);
    }

    function setCooldown(uint256 _cooldown) external onlyOwner {
        cooldown = _cooldown;
        emit CooldownUpdated(_cooldown);
    }

    function withdraw(uint256 amount) external onlyOwner {
        xZOD.transfer(owner, amount);
    }
}
