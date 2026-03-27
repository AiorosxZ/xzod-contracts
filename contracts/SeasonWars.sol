// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────
//  SeasonWars — Burn Wars V2.3
//
//  - Cycle  = full moon to full moon (~29.5 days)
//  - Season = 6 months (managed by ZODStakingVault)
//
//  HOT sign: calculated dynamically from block.timestamp
//  using the tropical solar zodiac calendar.
//  Changes automatically ~the 20th-21st of each month.
//
//  COLD  = (hotSign + 11) % 12
//  OPP   = (hotSign + 6)  % 12
//
//  Burn distribution:
//  • 40% → player reward bucket (claimable)
//  • 25% → clan reward bucket (weighted ranking)
//  • 20% → definitive burn (0xdead)
//  • 10% → staking pool
//  •  5% → treasury
//
//  Clan ranking: score = totalBurnPoints / sqrt(playerCount)
//  Distribution: 24/18/14/10/8/6/3.33% (ranks 1→12)
//
//  Rewards paid in OPPOSITE token at finalization time.
//  Admin must deposit enough OPPOSITE tokens before finalization
//  using depositRewards(). Excess can be recovered with withdrawExcess().
//
//  V2.1 fix: createCycle no longer auto-sets currentCycleId.
//  Use setCurrentCycleId(id) to activate a cycle manually.
//
//  V2.2 fix: stakingPool is no longer immutable.
//  Use setStakingPool(address) to update it without redeploying.
//
//  V2.3 fix: rewards paid in OPPOSITE token (not HOT).
//  Added depositRewards() and withdrawExcess() for admin reserve management.
// ─────────────────────────────────────────────────────────────────

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

library SafeTransfer {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bool ok = token.transferFrom(from, to, amount);
        require(ok, "TransferFrom failed");
    }
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        bool ok = token.transfer(to, amount);
        require(ok, "Transfer failed");
    }
}

library BPS {
    function share(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }
}

library Math {
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}

contract SeasonWars {
    using Math for uint256;
    using SafeTransfer for IERC20;
    using BPS for uint256;

    // ── Errors ──────────────────────────────────────────────────
    error NotOwner();
    error Paused();
    error InvalidSign();
    error CycleNotActive();
    error RegistrationClosed();
    error AlreadyRegistered();
    error NotRegistered();
    error ZeroAmount();
    error CycleStillActive();
    error InvalidCycle();
    error NothingToClaim();
    error ArrayLengthMismatch();
    error ZeroAddress();

    // ── Events ──────────────────────────────────────────────────
    event CycleCreated(uint256 indexed cycleId, uint256 startTime, uint256 endTime, uint256 registrationDeadline);
    event CurrentCycleSet(uint256 indexed cycleId);
    event PlayerRegistered(uint256 indexed cycleId, address indexed player, uint8 clanSign);
    event ZODBurned(uint256 indexed cycleId, address indexed player, uint8 zodSign, uint256 amount, uint256 burnPoints);
    event CycleFinalized(uint256 indexed cycleId, uint8 winnerClan, uint256 totalBurned, uint8 rewardToken);
    event PlayerRewardClaimed(uint256 indexed cycleId, address indexed player, uint256 amount);
    event ClanRewardClaimed(uint256 indexed cycleId, address indexed player, uint256 amount);
    event PauseToggled(bool paused);
    event StakingPoolUpdated(address indexed newStakingPool);
    event RewardsDeposited(uint8 indexed tokenIndex, uint256 amount);
    event ExcessWithdrawn(uint8 indexed tokenIndex, uint256 amount);

    // ── Constants ───────────────────────────────────────────────
    uint8   public constant NUM_SIGNS           = 12;
    uint256 public constant BASIS               = 10_000;
    uint256 public constant REGISTRATION_WINDOW = 7 days;

    uint256 public constant PLAYER_REWARD_BPS = 4_000;
    uint256 public constant CLAN_REWARD_BPS   = 2_500;
    uint256 public constant BURN_BPS          = 2_000;
    uint256 public constant STAKING_BPS       = 1_000;
    uint256 public constant TREASURY_BPS      =   500;

    uint256 public constant BONUS_COLD      = 2_000; // x1.20
    uint256 public constant BONUS_OPPOSITE  = 1_000; // x1.10
    uint256 public constant BONUS_OWN_WEEK1 =   500; // x1.05

    // ── Immutables ──────────────────────────────────────────────
    address public immutable owner;
    address public immutable treasury;
    address[NUM_SIGNS] public zodTokens;

    // ── Storage ─────────────────────────────────────────────────
    address public stakingPool;

    bool    public paused;
    uint256 public currentCycleId;
    uint256 public nextCycleId;

    uint256[12] private CLAN_RANK_BPS;

    struct Cycle {
        uint256 startTime;
        uint256 endTime;
        uint256 registrationDeadline;
        bool    finalized;
        uint256 totalBurnedAmount;
        uint8   winnerClan;
        uint8   finalHotSign;
        uint8   rewardToken;        // ← V2.3: OPPOSITE sign at finalization
        uint8[12] rankedClans;
    }

    struct PlayerInfo {
        uint8   clanSign;
        bool    registered;
        uint256 burnPoints;
        uint256 rawBurned;
        uint256 playerRewardBucket;
        bool    playerRewardClaimed;
        bool    clanRewardClaimed;
    }

    struct ClanInfo {
        uint256 totalBurnPoints;
        uint256 clanRewardBucket;
        uint256 playerCount;
        uint256 weightedScore;
    }

    mapping(uint256 => Cycle)                          public cycles;
    mapping(uint256 => mapping(address => PlayerInfo)) public players;
    mapping(uint256 => mapping(uint8 => ClanInfo))     public clans;

    // ── Modifiers ───────────────────────────────────────────────
    modifier onlyOwner()     { if (msg.sender != owner) revert NotOwner(); _; }
    modifier whenNotPaused() { if (paused) revert Paused(); _; }

    // ────────────────────────────────────────────────────────────
    constructor(
        address _treasury,
        address _stakingPool,
        address[12] memory _zodTokens
    ) {
        owner       = msg.sender;
        treasury    = _treasury;
        stakingPool = _stakingPool;
        for (uint8 i = 0; i < NUM_SIGNS; i++) {
            zodTokens[i] = _zodTokens[i];
        }
        CLAN_RANK_BPS[0]  = 2_400;
        CLAN_RANK_BPS[1]  = 1_800;
        CLAN_RANK_BPS[2]  = 1_400;
        CLAN_RANK_BPS[3]  = 1_000;
        CLAN_RANK_BPS[4]  =   800;
        CLAN_RANK_BPS[5]  =   600;
        CLAN_RANK_BPS[6]  =   333;
        CLAN_RANK_BPS[7]  =   333;
        CLAN_RANK_BPS[8]  =   333;
        CLAN_RANK_BPS[9]  =   333;
        CLAN_RANK_BPS[10] =   333;
        CLAN_RANK_BPS[11] =   331;
    }

    // ────────────────────────────────────────────────────────────
    //  HOT SIGN — Dynamic calculation
    // ────────────────────────────────────────────────────────────

    function getCurrentHotSign() public view returns (uint8) {
        return getHotSignAt(block.timestamp);
    }

    function getHotSignAt(uint256 ts) public pure returns (uint8) {
        (uint256 month, uint256 day) = _tsToMonthDay(ts);
        return _zodiacSign(month, day);
    }

    function getCurrentSigns() external view returns (uint8 hot, uint8 cold, uint8 opposite) {
        hot      = getCurrentHotSign();
        cold     = uint8((hot + 11) % NUM_SIGNS);
        opposite = uint8((hot + 6)  % NUM_SIGNS);
    }

    // ────────────────────────────────────────────────────────────
    //  OWNER
    // ────────────────────────────────────────────────────────────

    function setStakingPool(address newStakingPool) external onlyOwner {
        if (newStakingPool == address(0)) revert ZeroAddress();
        stakingPool = newStakingPool;
        emit StakingPoolUpdated(newStakingPool);
    }

    function createCycle(uint256 startTime, uint256 endTime) external onlyOwner {
        if (endTime <= startTime) revert InvalidCycle();
        nextCycleId++;
        uint256 cid = nextCycleId;
        Cycle storage c = cycles[cid];
        c.startTime            = startTime;
        c.endTime              = endTime;
        c.registrationDeadline = endTime - REGISTRATION_WINDOW;
        c.finalized            = false;
        c.totalBurnedAmount    = 0;
        emit CycleCreated(cid, startTime, endTime, c.registrationDeadline);
    }

    function setCurrentCycleId(uint256 cycleId) external onlyOwner {
        if (cycles[cycleId].startTime == 0) revert InvalidCycle();
        currentCycleId = cycleId;
        emit CurrentCycleSet(cycleId);
    }

    /// @notice V2.3 — Deposit OPPOSITE tokens as reward reserve before finalization.
    /// @param tokenIndex Index of the ZOD token to deposit (0-11)
    /// @param amount Amount to deposit (in wei)
    function depositRewards(uint8 tokenIndex, uint256 amount) external onlyOwner {
        if (tokenIndex >= NUM_SIGNS) revert InvalidSign();
        if (amount == 0) revert ZeroAmount();
        IERC20(zodTokens[tokenIndex]).safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsDeposited(tokenIndex, amount);
    }

    /// @notice V2.3 — Withdraw excess tokens after all claims are done.
    /// @param tokenIndex Index of the ZOD token to withdraw (0-11)
    /// @param amount Amount to withdraw (in wei)
    function withdrawExcess(uint8 tokenIndex, uint256 amount) external onlyOwner {
        if (tokenIndex >= NUM_SIGNS) revert InvalidSign();
        if (amount == 0) revert ZeroAmount();
        IERC20(zodTokens[tokenIndex]).safeTransfer(owner, amount);
        emit ExcessWithdrawn(tokenIndex, amount);
    }

    function finalizeCycle(uint256 cycleId) external onlyOwner {
        Cycle storage c = cycles[cycleId];
        if (c.startTime == 0)            revert InvalidCycle();
        if (c.finalized)                 revert InvalidCycle();
        if (block.timestamp < c.endTime) revert CycleStillActive();

        c.finalHotSign = getCurrentHotSign();

        // ← V2.3: reward token is OPPOSITE sign at finalization time
        c.rewardToken = uint8((c.finalHotSign + 6) % NUM_SIGNS);

        for (uint8 i = 0; i < NUM_SIGNS; i++) {
            ClanInfo storage cl = clans[cycleId][i];
            uint256 pc = cl.playerCount;
            cl.weightedScore = pc == 0 ? 0 : cl.totalBurnPoints / Math.sqrt(pc);
        }

        uint8[12] memory ranked;
        for (uint8 i = 0; i < NUM_SIGNS; i++) ranked[i] = i;
        for (uint8 i = 1; i < NUM_SIGNS; i++) {
            uint8 key = ranked[i];
            int8  j   = int8(i) - 1;
            while (j >= 0 && clans[cycleId][ranked[uint8(j)]].weightedScore < clans[cycleId][key].weightedScore) {
                ranked[uint8(j + 1)] = ranked[uint8(j)];
                j--;
            }
            ranked[uint8(j + 1)] = key;
        }
        c.rankedClans = ranked;
        c.winnerClan  = ranked[0];

        uint256 totalClanBucket = 0;
        for (uint8 i = 0; i < NUM_SIGNS; i++) {
            totalClanBucket += clans[cycleId][i].clanRewardBucket;
        }
        for (uint8 rank = 0; rank < NUM_SIGNS; rank++) {
            uint8 clanSign = ranked[rank];
            clans[cycleId][clanSign].clanRewardBucket = totalClanBucket * CLAN_RANK_BPS[rank] / BASIS;
        }

        c.finalized = true;
        emit CycleFinalized(cycleId, ranked[0], c.totalBurnedAmount, c.rewardToken);
    }

    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }

    // ────────────────────────────────────────────────────────────
    //  PLAYERS
    // ────────────────────────────────────────────────────────────

    function register(uint8 clanSign) external whenNotPaused {
        if (clanSign >= NUM_SIGNS) revert InvalidSign();
        uint256 cid = currentCycleId;
        _checkCycleActive(cid);
        _checkRegistrationOpen(cid);
        PlayerInfo storage p = players[cid][msg.sender];
        if (p.registered) revert AlreadyRegistered();
        p.registered = true;
        p.clanSign   = clanSign;
        clans[cid][clanSign].playerCount++;
        emit PlayerRegistered(cid, msg.sender, clanSign);
    }

    function registerAndBurn(uint8 clanSign, uint8 zodSign, uint256 amount) external whenNotPaused {
        if (clanSign >= NUM_SIGNS) revert InvalidSign();
        if (zodSign  >= NUM_SIGNS) revert InvalidSign();
        if (amount == 0)           revert ZeroAmount();
        uint256 cid = currentCycleId;
        _checkCycleActive(cid);
        _checkRegistrationOpen(cid);
        PlayerInfo storage p = players[cid][msg.sender];
        if (p.registered) revert AlreadyRegistered();
        p.registered = true;
        p.clanSign   = clanSign;
        clans[cid][clanSign].playerCount++;
        emit PlayerRegistered(cid, msg.sender, clanSign);
        _burn(cid, zodSign, amount);
    }

    function burnZOD(uint8 zodSign, uint256 amount) external whenNotPaused {
        if (zodSign >= NUM_SIGNS) revert InvalidSign();
        if (amount == 0)          revert ZeroAmount();
        uint256 cid = currentCycleId;
        _checkCycleActive(cid);
        PlayerInfo storage p = players[cid][msg.sender];
        if (!p.registered) revert NotRegistered();
        _burn(cid, zodSign, amount);
    }

    function burnMultiple(uint8[] calldata zodSigns, uint256[] calldata amounts) external whenNotPaused {
        if (zodSigns.length != amounts.length) revert ArrayLengthMismatch();
        uint256 cid = currentCycleId;
        _checkCycleActive(cid);
        PlayerInfo storage p = players[cid][msg.sender];
        if (!p.registered) revert NotRegistered();
        for (uint256 i = 0; i < zodSigns.length; i++) {
            if (zodSigns[i] >= NUM_SIGNS) revert InvalidSign();
            if (amounts[i] == 0)          revert ZeroAmount();
            _burn(cid, zodSigns[i], amounts[i]);
        }
    }

    function claimPlayerReward(uint256 cycleId) external {
        Cycle storage c = cycles[cycleId];
        if (!c.finalized) revert CycleStillActive();
        PlayerInfo storage p = players[cycleId][msg.sender];
        if (!p.registered)         revert NotRegistered();
        if (p.playerRewardClaimed) revert NothingToClaim();
        if (p.playerRewardBucket == 0) revert NothingToClaim();
        uint256 amount = p.playerRewardBucket;
        p.playerRewardClaimed = true;
        p.playerRewardBucket  = 0;
        // ← V2.3: pay in OPPOSITE token
        IERC20(zodTokens[c.rewardToken]).safeTransfer(msg.sender, amount);
        emit PlayerRewardClaimed(cycleId, msg.sender, amount);
    }

    function claimClanReward(uint256 cycleId) external {
        Cycle storage c = cycles[cycleId];
        if (!c.finalized) revert CycleStillActive();
        PlayerInfo storage p = players[cycleId][msg.sender];
        if (!p.registered)       revert NotRegistered();
        if (p.clanRewardClaimed) revert NothingToClaim();
        if (p.burnPoints == 0)   revert NothingToClaim();
        ClanInfo storage cl = clans[cycleId][p.clanSign];
        if (cl.totalBurnPoints == 0) revert NothingToClaim();
        uint256 share = cl.clanRewardBucket * p.burnPoints / cl.totalBurnPoints;
        if (share == 0) revert NothingToClaim();
        p.clanRewardClaimed = true;
        // ← V2.3: pay in OPPOSITE token
        IERC20(zodTokens[c.rewardToken]).safeTransfer(msg.sender, share);
        emit ClanRewardClaimed(cycleId, msg.sender, share);
    }

    // ────────────────────────────────────────────────────────────
    //  VIEWS
    // ────────────────────────────────────────────────────────────

    function getCycleInfo(uint256 cycleId) external view returns (Cycle memory) {
        return cycles[cycleId];
    }

    function getPlayerInfo(uint256 cycleId, address player) external view returns (PlayerInfo memory) {
        return players[cycleId][player];
    }

    function getClanInfo(uint256 cycleId, uint8 clanSign) external view returns (ClanInfo memory) {
        return clans[cycleId][clanSign];
    }

    function getLeaderboard(uint256 cycleId) external view returns (uint256[12] memory points) {
        for (uint8 i = 0; i < NUM_SIGNS; i++) {
            points[i] = clans[cycleId][i].totalBurnPoints;
        }
    }

    function getWeightedLeaderboard(uint256 cycleId) external view returns (uint256[12] memory scores) {
        for (uint8 i = 0; i < NUM_SIGNS; i++) {
            ClanInfo storage cl = clans[cycleId][i];
            uint256 pc = cl.playerCount;
            scores[i] = pc == 0 ? 0 : cl.totalBurnPoints / Math.sqrt(pc);
        }
    }

    function getRankedClans(uint256 cycleId) external view returns (uint8[12] memory) {
        return cycles[cycleId].rankedClans;
    }

    function quoteBurn(uint256 cycleId, address player, uint8 zodSign, uint256 amount)
        external view returns (uint256)
    {
        if (zodSign >= NUM_SIGNS) return 0;
        PlayerInfo storage p = players[cycleId][player];
        if (!p.registered) return 0;
        uint8 hot_      = getCurrentHotSign();
        uint8 cold_     = uint8((hot_ + 11) % NUM_SIGNS);
        uint8 opposite_ = uint8((hot_ + 6)  % NUM_SIGNS);
        uint256 bonusBps = _getBonusDynamic(cycleId, p.clanSign, zodSign, cold_, opposite_);
        return amount + amount.share(bonusBps);
    }

    /// @notice V2.3 — Returns how many OPPOSITE tokens are needed to cover all pending rewards.
    /// @param cycleId The cycle to check
    function getRewardDeficit(uint256 cycleId) external view returns (uint256 needed, uint256 available, int256 deficit) {
        Cycle storage c = cycles[cycleId];
        uint256 totalRewards = 0;
        for (uint8 i = 0; i < NUM_SIGNS; i++) {
            totalRewards += clans[cycleId][i].clanRewardBucket;
        }
        uint8 oppSign = c.finalized
            ? c.rewardToken
            : uint8((getCurrentHotSign() + 6) % NUM_SIGNS);
        needed    = totalRewards + c.totalBurnedAmount.share(PLAYER_REWARD_BPS);
        available = IERC20(zodTokens[oppSign]).balanceOf(address(this));
        deficit   = int256(available) - int256(needed);
    }

    // ────────────────────────────────────────────────────────────
    //  INTERNAL
    // ────────────────────────────────────────────────────────────

    function _burn(uint256 cid, uint8 zodSign, uint256 amount) internal {
        PlayerInfo storage p  = players[cid][msg.sender];
        uint8 clanSign_       = p.clanSign;
        ClanInfo storage clan = clans[cid][clanSign_];
        Cycle storage cyc     = cycles[cid];

        uint8 hot_      = getCurrentHotSign();
        uint8 cold_     = uint8((hot_ + 11) % NUM_SIGNS);
        uint8 opposite_ = uint8((hot_ + 6)  % NUM_SIGNS);
        uint256 bonusBps   = _getBonusDynamic(cid, clanSign_, zodSign, cold_, opposite_);
        uint256 burnPoints = amount + amount.share(bonusBps);

        _distribute(cid, zodSign, amount, burnPoints, p, clan, cyc);
    }

    function _distribute(
        uint256 cid,
        uint8 zodSign,
        uint256 amount,
        uint256 burnPoints,
        PlayerInfo storage p,
        ClanInfo storage clan,
        Cycle storage cyc
    ) internal {
        uint256 playerShare  = amount.share(PLAYER_REWARD_BPS);
        uint256 clanShare    = amount.share(CLAN_REWARD_BPS);
        uint256 burnShare    = amount.share(BURN_BPS);
        uint256 stakingShare = amount.share(STAKING_BPS);
        uint256 distributed  = playerShare + clanShare + burnShare + stakingShare;
        uint256 treasuryShare = amount - distributed;

        p.playerRewardBucket  += playerShare;
        p.burnPoints          += burnPoints;
        p.rawBurned           += amount;
        clan.clanRewardBucket += clanShare;
        clan.totalBurnPoints  += burnPoints;
        cyc.totalBurnedAmount += burnShare;

        IERC20 token = IERC20(zodTokens[zodSign]);
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.safeTransfer(address(0x000000000000000000000000000000000000dEaD), burnShare);
        token.safeTransfer(stakingPool, stakingShare);
        token.safeTransfer(treasury, treasuryShare);

        emit ZODBurned(cid, msg.sender, zodSign, amount, burnPoints);
    }

    function _getBonusDynamic(
        uint256 cid,
        uint8 playerClan,
        uint8 zodSign,
        uint8 cold,
        uint8 opposite
    ) internal view returns (uint256) {
        if (zodSign == cold)     return BONUS_COLD;
        if (zodSign == opposite) return BONUS_OPPOSITE;
        if (zodSign == playerClan && block.timestamp < cycles[cid].startTime + 7 days)
            return BONUS_OWN_WEEK1;
        return 0;
    }

    function _checkCycleActive(uint256 cid) internal view {
        Cycle storage c = cycles[cid];
        if (c.startTime == 0 || block.timestamp < c.startTime) revert CycleNotActive();
        if (block.timestamp >= c.endTime) revert CycleNotActive();
        if (c.finalized) revert CycleStillActive();
    }

    function _checkRegistrationOpen(uint256 cid) internal view {
        if (block.timestamp > cycles[cid].registrationDeadline) revert RegistrationClosed();
    }

    // ────────────────────────────────────────────────────────────
    //  ZODIAC CALENDAR — Pure arithmetic (no oracle)
    // ────────────────────────────────────────────────────────────

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
}
