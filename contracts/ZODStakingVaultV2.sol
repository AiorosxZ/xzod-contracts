// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────
//  ZODStakingVault V2
//
//  Multi-token staking vault for xZod Network.
//
//  - One position per (user, ZOD token)
//  - APY follows the tropical zodiac calendar (same pure math as SeasonWars)
//    Each token's APY = f(distance between token's sign and current HOT sign)
//  - Seasonal multiplier: S1 ×1.0 · S2 ×0.75 · S3 ×0.50
//  - NFT Earth boost applied on top
//  - Lock: 45 days, resets on every additional deposit
//  - Rewards crystallised on every interaction (lazy checkpoint)
//  - Rewards paid in the same token as staked
//  - Unstake: all-or-nothing (MVP)
// ─────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface INFTController {
    function getAPYBoost(address player) external view returns (uint16);
}

contract ZODStakingVaultV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Events ───────────────────────────────────────────────────
    event Staked(address indexed user, address indexed token, uint256 amount, uint256 crystallised);
    event Unstaked(address indexed user, address indexed token, uint256 amount, uint256 rewards);
    event RewardsClaimed(address indexed user, address indexed token, uint256 rewards);
    event TokenRegistered(address indexed token, uint8 signIndex);
    event APYRatesUpdated();
    event SeasonMultipliersUpdated();
    event PauserChanged(address indexed newPauser);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // ── Errors ───────────────────────────────────────────────────
    error VaultError_ZeroAmount();
    error VaultError_Unauthorized();
    error VaultError_ZeroAddress();
    error VaultError_LockActive();
    error VaultError_NothingStaked();
    error VaultError_InsufficientReserve();
    error VaultError_TokenNotAllowed();
    error VaultError_InvalidSignIndex();
    error VaultError_NothingToClaim();

    // ── Structs ──────────────────────────────────────────────────

    struct Position {
        uint256 amount;              // tokens staked
        uint256 lockEndsAt;          // unix timestamp of lock expiry
        uint256 lastCheckpointTime;  // last time rewards were crystallised
        uint256 accumulatedRewards;  // crystallised rewards not yet claimed
    }

    // ── Constants ────────────────────────────────────────────────

    uint256 public constant LOCK_DURATION   = 45 days;
    uint256 public constant SECONDS_IN_YEAR = 31_536_000;
    uint256 public constant SEASON_DURATION = SECONDS_IN_YEAR / 2;

    // APY rates stored in basis points (800 = 8%).
    // reward = amount * effectiveAPY_bps * duration / (SECONDS_IN_YEAR * 10_000)
    uint256 private constant DENOMINATOR = SECONDS_IN_YEAR * 10_000;

    // ── Storage ──────────────────────────────────────────────────

    // user => token => Position
    mapping(address => mapping(address => Position)) private _positions;

    // token => total staked (principal only, not rewards)
    mapping(address => uint256) private _totalStaked;

    // token => zodiac sign index (0 = Aries … 11 = Pisces)
    mapping(address => uint8)   public tokenSignIndex;

    // token => allowed
    mapping(address => bool)    public allowedTokens;

    address private _pauserAddress;

    // ── Immutables ───────────────────────────────────────────────

    INFTController public immutable nftController;
    uint256        public immutable START_TIMESTAMP;  // S1 start — used for season calculation

    // ── Configurable ─────────────────────────────────────────────

    // APY rotation in bps: index 0 = HOT sign (8%), index 11 = COLD sign (2%)
    // Default S1: [800, 600, 500, 500, 400, 400, 400, 300, 300, 300, 300, 200]
    uint16[12] public ZODIAC_APY_RATES;

    // Season multipliers in pct (100 = ×1, 75 = ×0.75, 50 = ×0.50)
    // Index 0 = S1, 1 = S2, 2 = S3, 3 = fallback (xZile era)
    uint16[4] public SEASON_MULTIPLIERS;

    // ── Constructor ──────────────────────────────────────────────

    constructor(
        address ownerAddress,
        address pauserAddr,
        address nftControllerAddress,
        uint256 startTimestamp,
        uint16[12] memory apyRates,
        uint16[4]  memory seasonMultipliers
    ) Ownable(ownerAddress) {
        if (nftControllerAddress == address(0)) revert VaultError_ZeroAddress();

        _pauserAddress  = pauserAddr;
        nftController   = INFTController(nftControllerAddress);
        START_TIMESTAMP = startTimestamp;
        ZODIAC_APY_RATES    = apyRates;
        SEASON_MULTIPLIERS  = seasonMultipliers;

        _pause(); // starts paused — owner must unpause after setup
    }

    // ── Admin ─────────────────────────────────────────────────────

    function setPauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert VaultError_ZeroAddress();
        _pauserAddress = newPauser;
        emit PauserChanged(newPauser);
    }

    function pause() public {
        if (msg.sender != owner() && msg.sender != _pauserAddress)
            revert VaultError_Unauthorized();
        _pause();
    }

    function unpause() public {
        if (msg.sender != owner() && msg.sender != _pauserAddress)
            revert VaultError_Unauthorized();
        _unpause();
    }

    /// @notice Register a ZOD token and its zodiac sign index (0–11).
    function registerToken(address token, uint8 signIndex) external onlyOwner {
        if (token == address(0))  revert VaultError_ZeroAddress();
        if (signIndex >= 12)      revert VaultError_InvalidSignIndex();
        tokenSignIndex[token] = signIndex;
        allowedTokens[token]  = true;
        emit TokenRegistered(token, signIndex);
    }

    function disableToken(address token) external onlyOwner {
        allowedTokens[token] = false;
    }

    /// @notice Update the 12-slot APY rotation array (in bps).
    function setAPYRates(uint16[12] memory newRates) external onlyOwner {
        ZODIAC_APY_RATES = newRates;
        emit APYRatesUpdated();
    }

    /// @notice Update the season multipliers.
    function setSeasonMultipliers(uint16[4] memory newMultipliers) external onlyOwner {
        SEASON_MULTIPLIERS = newMultipliers;
        emit SeasonMultipliersUpdated();
    }

    /// @notice Emergency fund recovery — owner only.
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdraw(token, amount);
    }

    // ── Core: Staking ─────────────────────────────────────────────

    /// @notice Stake `amount` of `token`.
    ///         If a position exists, crystallises pending rewards first.
    ///         Lock always resets to 45 days on every deposit.
    function stake(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0)             revert VaultError_ZeroAmount();
        if (!allowedTokens[token])   revert VaultError_TokenNotAllowed();

        // Crystallise any pending rewards on existing position
        uint256 crystallised = _checkpoint(msg.sender, token);

        // Pull tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update position
        Position storage pos = _positions[msg.sender][token];
        pos.amount             += amount;
        pos.lockEndsAt          = block.timestamp + LOCK_DURATION; // always resets
        pos.lastCheckpointTime  = block.timestamp;

        unchecked { _totalStaked[token] += amount; }

        emit Staked(msg.sender, token, amount, crystallised);
    }

    /// @notice Unstake everything. Returns principal + all accumulated rewards.
    function unstake(address token) external whenNotPaused nonReentrant {
        Position storage pos = _positions[msg.sender][token];

        if (pos.amount == 0)                          revert VaultError_NothingStaked();
        if (block.timestamp < pos.lockEndsAt)         revert VaultError_LockActive();

        // Final crystallisation
        _checkpoint(msg.sender, token);

        uint256 principal   = pos.amount;
        uint256 rewards     = pos.accumulatedRewards;

        // Guard against empty rewards reserve (principal always returned)
        uint256 rewardsReserve = _rewardsReserve(token, principal);
        if (rewards > rewardsReserve) {
            rewards = rewardsReserve; // pay what's available
        }

        // Clear position
        _totalStaked[token]        -= principal;
        pos.amount                  = 0;
        pos.lockEndsAt              = 0;
        pos.lastCheckpointTime      = 0;
        pos.accumulatedRewards      = 0;

        // Transfer principal
        IERC20(token).safeTransfer(msg.sender, principal);

        // Transfer rewards if any
        if (rewards > 0) {
            IERC20(token).safeTransfer(msg.sender, rewards);
            emit RewardsClaimed(msg.sender, token, rewards);
        }

        emit Unstaked(msg.sender, token, principal, rewards);
    }

    /// @notice Claim crystallised rewards without unstaking.
    function claimRewards(address token) external whenNotPaused nonReentrant {
        _checkpoint(msg.sender, token);

        Position storage pos = _positions[msg.sender][token];
        uint256 rewards = pos.accumulatedRewards;
        if (rewards == 0) revert VaultError_NothingToClaim();

        uint256 rewardsReserve = _rewardsReserve(token, pos.amount);
        if (rewardsReserve < rewards) revert VaultError_InsufficientReserve();

        pos.accumulatedRewards = 0;
        IERC20(token).safeTransfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, token, rewards);
    }

    // ── Internal: Checkpoint ──────────────────────────────────────

    /// @dev Calculates and stores pending rewards since last checkpoint.
    ///      Must be called before any mutation to a position.
    function _checkpoint(address user, address token) internal returns (uint256 pending) {
        Position storage pos = _positions[user][token];
        if (pos.amount == 0 || pos.lastCheckpointTime == 0) return 0;

        pending = _pendingRewards(pos, token, user);
        pos.accumulatedRewards += pending;
        pos.lastCheckpointTime  = block.timestamp;
    }

    /// @dev Pure reward math: amount × effectiveAPY × duration / DENOMINATOR
    function _pendingRewards(
        Position memory pos,
        address token,
        address user
    ) internal view returns (uint256) {
        if (pos.amount == 0) return 0;
        uint256 duration    = block.timestamp - pos.lastCheckpointTime;
        uint256 effectiveAPY = _getEffectiveAPY(tokenSignIndex[token], user);
        return (pos.amount * effectiveAPY * duration) / DENOMINATOR;
    }

    // ── Internal: APY ─────────────────────────────────────────────

    /// @dev effectiveAPY (bps) = (baseRate × seasonMultiplier / 100) + nftBoost
    function _getEffectiveAPY(uint8 tokenSign, address user) internal view returns (uint256) {
        uint8  hotSign       = _getCurrentHotSign();
        // Distance from HOT: 0 = HOT (highest APY), 11 = COLD (lowest)
        uint8  rotationIdx   = uint8((uint256(tokenSign) + 12 - uint256(hotSign)) % 12);
        uint16 baseRate      = ZODIAC_APY_RATES[rotationIdx];
        uint16 seasonMult    = _getCurrentSeasonMultiplier();
        uint16 nftBoost      = nftController.getAPYBoost(user);
        return (uint256(baseRate) * uint256(seasonMult) / 100) + uint256(nftBoost);
    }

    function _getCurrentSeasonMultiplier() internal view returns (uint16) {
        if (block.timestamp < START_TIMESTAMP) return SEASON_MULTIPLIERS[0];
        uint256 elapsed    = block.timestamp - START_TIMESTAMP;
        uint256 seasonIdx  = elapsed / SEASON_DURATION;
        return seasonIdx >= 4 ? SEASON_MULTIPLIERS[3] : SEASON_MULTIPLIERS[uint256(seasonIdx)];
    }

    // ── Internal: Reserve guard ────────────────────────────────────

    /// @dev Rewards reserve = vault balance − total staked principal (excluding this user's principal)
    function _rewardsReserve(address token, uint256 userPrincipal) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 locked  = _totalStaked[token] > userPrincipal
            ? _totalStaked[token] - userPrincipal
            : 0;
        return balance > locked ? balance - locked : 0;
    }

    // ── Zodiac Calendar — pure math, identical to SeasonWars ──────

    function _getCurrentHotSign() internal view returns (uint8) {
        (uint256 month, uint256 day) = _tsToMonthDay(block.timestamp);
        return _zodiacSign(month, day);
    }

    function _tsToMonthDay(uint256 ts) internal pure returns (uint256 month, uint256 day) {
        uint256 totalDays = ts / 86400;
        uint256 z   = totalDays + 719469;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp  = (5 * doy + 2) / 153;
        day   = doy - (153 * mp + 2) / 5 + 1;
        month = mp < 10 ? mp + 3 : mp - 9;
    }

    function _zodiacSign(uint256 month, uint256 day) internal pure returns (uint8) {
        if ((month == 3  && day >= 21) || (month == 4  && day <= 19)) return 0;  // Aries
        if ((month == 4  && day >= 20) || (month == 5  && day <= 20)) return 1;  // Taurus
        if ((month == 5  && day >= 21) || (month == 6  && day <= 20)) return 2;  // Gemini
        if ((month == 6  && day >= 21) || (month == 7  && day <= 22)) return 3;  // Cancer
        if ((month == 7  && day >= 23) || (month == 8  && day <= 22)) return 4;  // Leo
        if ((month == 8  && day >= 23) || (month == 9  && day <= 22)) return 5;  // Virgo
        if ((month == 9  && day >= 23) || (month == 10 && day <= 22)) return 6;  // Libra
        if ((month == 10 && day >= 23) || (month == 11 && day <= 21)) return 7;  // Scorpio
        if ((month == 11 && day >= 22) || (month == 12 && day <= 21)) return 8;  // Sagittarius
        if ((month == 12 && day >= 22) || (month == 1  && day <= 19)) return 9;  // Capricorn
        if ((month == 1  && day >= 20) || (month == 2  && day <= 18)) return 10; // Aquarius
        return 11; // Pisces
    }

    // ── Views ─────────────────────────────────────────────────────

    function getPosition(address user, address token) external view returns (
        uint256 amount,
        uint256 lockEndsAt,
        uint256 accumulatedRewards,
        uint256 pendingRewards,
        bool    isLocked,
        uint256 currentAPY_bps
    ) {
        Position memory pos = _positions[user][token];
        return (
            pos.amount,
            pos.lockEndsAt,
            pos.accumulatedRewards,
            _pendingRewards(pos, token, user),
            block.timestamp < pos.lockEndsAt,
            _getEffectiveAPY(tokenSignIndex[token], user)
        );
    }

    function getCurrentHotSign() external view returns (uint8) {
        return _getCurrentHotSign();
    }

    function getCurrentSeasonMultiplier() external view returns (uint16) {
        return _getCurrentSeasonMultiplier();
    }

    function totalStaked(address token) external view returns (uint256) {
        return _totalStaked[token];
    }

    function pauserAddress() external view returns (address) {
        return _pauserAddress;
    }

    /// @notice Returns the current effective APY in bps for a given token and user.
    function getEffectiveAPY(address token, address user) external view returns (uint256) {
        return _getEffectiveAPY(tokenSignIndex[token], user);
    }
}
