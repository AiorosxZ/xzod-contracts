// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/Pausable.sol";

/**
 * @title IERC20ICO
 * @notice Minimal ERC-20 interface for USDC and xZOD.
 */
interface IERC20ICO {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title IxZodNFTICO
 * @notice Minimal interface to mint NFT gifts via xZodNFT.
 */
interface IxZodNFTICO {
    function mint(address to, uint256 tokenId, uint256 amount) external;
}

/**
 * @title ICOPresale
 * @notice 3-round public ICO for xZOD tokens.
 *
 * Round structure:
 *   Round 1 — $0.05/xZOD, NFT gift: Air Element   (tokenId 3)
 *   Round 2 — $0.08/xZOD, NFT gift: Water Element (tokenId 2)
 *   Round 3 — $0.12/xZOD, NFT gift: Fire Element  (tokenId 1)
 *
 * NFT distribution (anti-sybil):
 *   >= $500 USDC cumulative in round  -> NFT guaranteed (100%)
 *   $100–$499 USDC cumulative         -> 50% chance (pseudo-random, evaluated once)
 *   < $100 USDC                       -> no NFT
 *   1 evaluation max per wallet per round — no retry on additional purchases
 *
 * Note: pseudo-random is sufficient for MVP (Sepolia). Upgrade to Chainlink VRF
 * before mainnet launch.
 *
 * Anti-sybil:
 *   - $100 minimum per transaction
 *   - $500 maximum cumulative per wallet per round
 *   - NFT evaluated once per wallet per round
 *
 * Vesting:
 *   - 90-day cliff, then linear over 270 days (1 year total)
 *   - Params configurable per round via configureRound()
 *
 * Payment: USDC only (6 decimals).
 *
 * xZodNFT  (Sepolia): 0x5249D8eacbD47080642a7d89884CC3A1c0A110e3
 * xZOD     (Sepolia): 0x017f4333Aa7e83fA42d119d5489c41e3648c9D2f
 * USDC     (Sepolia): 0x5FF41728ceC9D457a98ba9903aD19D6C8fc12e83
 */
contract ICOPresale is Ownable, ReentrancyGuard, Pausable {

    // ─── External contracts ───────────────────────────────────────────────────
    IERC20ICO   public xZodToken;
    IERC20ICO   public usdcToken;
    IxZodNFTICO public nftContract;

    // ─── Round config ─────────────────────────────────────────────────────────

    struct RoundConfig {
        uint256 pricePerToken;       // USDC per xZOD (6 dec), e.g. 50000 = $0.05
        uint256 hardCap;             // Max USDC to raise (6 dec)
        uint256 minPurchaseUSDC;     // Min per tx (6 dec), default $100
        uint256 maxPurchaseUSDC;     // Max cumulative per wallet (6 dec), default $500
        uint256 nftTokenId;          // xZodNFT tokenId to gift (1=Fire, 2=Water, 3=Air)
        uint256 nftGuaranteeUSDC;    // Cumulative USDC for guaranteed NFT, default $500
        uint256 nftThresholdUSDC;    // Cumulative USDC for 50% chance, default $100
        uint256 cliffDuration;       // Seconds before any tokens unlock
        uint256 vestingDuration;     // Linear unlock duration after cliff
        bool    active;
    }

    mapping(uint256 => RoundConfig) public rounds;
    uint256 public currentRound;
    uint256 public constant TOTAL_ROUNDS = 3;

    // ─── Round state ──────────────────────────────────────────────────────────
    mapping(uint256 => uint256) public roundRaised;
    mapping(uint256 => uint256) public roundAllocated;

    // ─── Per-wallet state ─────────────────────────────────────────────────────

    struct WalletRoundData {
        uint256 usdcPaid;           // Cumulative USDC this round
        uint256 xZodAllocated;      // Cumulative xZOD allocated this round
        uint256 firstPurchaseAt;    // Timestamp of first purchase (vesting anchor)
        bool    nftEvaluated;       // True once NFT roll has been evaluated
        bool    nftReceived;        // True if NFT was actually minted
    }

    mapping(address => mapping(uint256 => WalletRoundData)) public walletRoundData;

    // ─── Vesting positions ────────────────────────────────────────────────────

    struct VestingPosition {
        uint256 totalXZod;
        uint256 claimedXZod;
        uint256 cliffEnd;
        uint256 vestingEnd;
        uint256 round;
    }

    mapping(address => VestingPosition[]) public vestingPositions;

    // ─── Events ───────────────────────────────────────────────────────────────
    event RoundConfigured(uint256 indexed round, uint256 price, uint256 hardCap);
    event RoundOpened(uint256 indexed round);
    event RoundClosed(uint256 indexed round, uint256 totalRaised);
    event Purchase(
        address indexed buyer,
        uint256 indexed round,
        uint256 usdcPaid,
        uint256 xZodAllocated
    );
    event NFTRollResult(
        address indexed buyer,
        uint256 indexed round,
        bool    guaranteed,
        bool    won,
        uint256 tokenId
    );
    event Claimed(address indexed wallet, uint256 positionIndex, uint256 amount);
    event USDCWithdrawn(address indexed to, uint256 amount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address xZodAddress,
        address usdcAddress,
        address nftAddress
    ) Ownable(msg.sender) {
        require(xZodAddress != address(0), "ICO: zero xZOD address");
        require(usdcAddress != address(0), "ICO: zero USDC address");
        require(nftAddress  != address(0), "ICO: zero NFT address");

        xZodToken   = IERC20ICO(xZodAddress);
        usdcToken   = IERC20ICO(usdcAddress);
        nftContract = IxZodNFTICO(nftAddress);

        _configureDefaultRounds();
    }

    // ─── Round management ─────────────────────────────────────────────────────

    /**
     * @notice Configure or reconfigure a round before opening it.
     */
    function configureRound(
        uint256 round,
        uint256 pricePerToken,
        uint256 hardCap,
        uint256 minPurchaseUSDC,
        uint256 maxPurchaseUSDC,
        uint256 nftTokenId,
        uint256 nftGuaranteeUSDC,
        uint256 nftThresholdUSDC,
        uint256 cliffDuration,
        uint256 vestingDuration
    ) external onlyOwner {
        require(round >= 1 && round <= TOTAL_ROUNDS,  "ICO: invalid round");
        require(!rounds[round].active,                "ICO: round already active");
        require(round > currentRound,                 "ICO: round already passed");
        require(pricePerToken > 0,                    "ICO: price must be > 0");
        require(hardCap > 0,                          "ICO: hardcap must be > 0");
        require(maxPurchaseUSDC >= minPurchaseUSDC,   "ICO: max < min");
        require(nftGuaranteeUSDC >= nftThresholdUSDC, "ICO: guarantee < threshold");
        require(nftTokenId >= 1 && nftTokenId <= 4,  "ICO: invalid NFT tokenId");

        rounds[round] = RoundConfig({
            pricePerToken:    pricePerToken,
            hardCap:          hardCap,
            minPurchaseUSDC:  minPurchaseUSDC,
            maxPurchaseUSDC:  maxPurchaseUSDC,
            nftTokenId:       nftTokenId,
            nftGuaranteeUSDC: nftGuaranteeUSDC,
            nftThresholdUSDC: nftThresholdUSDC,
            cliffDuration:    cliffDuration,
            vestingDuration:  vestingDuration,
            active:           false
        });

        emit RoundConfigured(round, pricePerToken, hardCap);
    }

    /**
     * @notice Open a round. Rounds must open in order (1 then 2 then 3).
     */
    function openRound(uint256 round) external onlyOwner {
        require(round >= 1 && round <= TOTAL_ROUNDS, "ICO: invalid round");
        require(!rounds[round].active,               "ICO: already active");
        require(round == currentRound + 1,           "ICO: must open in order");
        require(rounds[round].pricePerToken > 0,     "ICO: not configured");

        if (currentRound > 0 && rounds[currentRound].active) {
            rounds[currentRound].active = false;
            emit RoundClosed(currentRound, roundRaised[currentRound]);
        }

        currentRound = round;
        rounds[round].active = true;
        emit RoundOpened(round);
    }

    /// @notice Manually close the current round.
    function closeCurrentRound() external onlyOwner {
        require(currentRound > 0,                "ICO: no active round");
        require(rounds[currentRound].active,     "ICO: round not active");
        rounds[currentRound].active = false;
        emit RoundClosed(currentRound, roundRaised[currentRound]);
    }

    // ─── Purchase ─────────────────────────────────────────────────────────────

    /**
     * @notice Buy xZOD with USDC.
     *
     * NFT logic:
     *   On FIRST purchase that brings cumulative spend to >= nftThresholdUSDC,
     *   the NFT roll is evaluated exactly once:
     *     - cumulative >= nftGuaranteeUSDC  -> guaranteed mint
     *     - cumulative >= nftThresholdUSDC  -> 50% pseudo-random mint
     *   Subsequent purchases in the same round do NOT re-roll.
     *
     * Pseudo-random: keccak256(wallet, block.prevrandao, block.timestamp, round).
     * Sufficient for MVP. Replace with Chainlink VRF before mainnet.
     *
     * @param usdcAmount  USDC to spend (6 decimals)
     */
    function buy(uint256 usdcAmount) external nonReentrant whenNotPaused {
        require(currentRound > 0, "ICO: no active round");
        RoundConfig storage rc = rounds[currentRound];
        require(rc.active,                        "ICO: round not active");
        require(usdcAmount >= rc.minPurchaseUSDC, "ICO: below minimum ($100)");

        WalletRoundData storage wd = walletRoundData[msg.sender][currentRound];

        uint256 newCumulative = wd.usdcPaid + usdcAmount;
        require(
            newCumulative <= rc.maxPurchaseUSDC,
            "ICO: exceeds wallet cap for this round ($500)"
        );
        require(
            roundRaised[currentRound] + usdcAmount <= rc.hardCap,
            "ICO: round hardcap reached"
        );

        // Compute xZOD allocation
        // usdcAmount (6 dec) / pricePerToken (6 dec) * 1e18 = xZOD (18 dec)
        uint256 xZodAmount = (usdcAmount * 1e18) / rc.pricePerToken;
        require(xZodAmount > 0, "ICO: zero xZOD allocation");

        // ── Effects ──
        wd.usdcPaid      = newCumulative;
        wd.xZodAllocated += xZodAmount;
        roundRaised[currentRound]    += usdcAmount;
        roundAllocated[currentRound] += xZodAmount;

        // First purchase: record timestamp + create vesting position
        if (wd.firstPurchaseAt == 0) {
            wd.firstPurchaseAt = block.timestamp;
            vestingPositions[msg.sender].push(VestingPosition({
                totalXZod:   xZodAmount,
                claimedXZod: 0,
                cliffEnd:    block.timestamp + rc.cliffDuration,
                vestingEnd:  block.timestamp + rc.cliffDuration + rc.vestingDuration,
                round:       currentRound
            }));
        } else {
            // Extend existing position
            uint256 posIdx = _findVestingPosition(msg.sender, currentRound);
            vestingPositions[msg.sender][posIdx].totalXZod += xZodAmount;
        }

        // ── Interactions ──
        require(
            usdcToken.transferFrom(msg.sender, address(this), usdcAmount),
            "ICO: USDC transfer failed"
        );

        emit Purchase(msg.sender, currentRound, usdcAmount, xZodAmount);

        // ── NFT roll (once per wallet per round) ──
        if (!wd.nftEvaluated && newCumulative >= rc.nftThresholdUSDC && rc.nftTokenId > 0) {
            wd.nftEvaluated = true;
            bool guaranteed = newCumulative >= rc.nftGuaranteeUSDC;
            bool won        = guaranteed || _roll50(msg.sender);

            emit NFTRollResult(msg.sender, currentRound, guaranteed, won, rc.nftTokenId);

            if (won) {
                wd.nftReceived = true;
                nftContract.mint(msg.sender, rc.nftTokenId, 1);
            }
        }

        // ── Auto-close if hardcap reached ──
        if (roundRaised[currentRound] >= rc.hardCap) {
            rc.active = false;
            emit RoundClosed(currentRound, roundRaised[currentRound]);
        }
    }

    // ─── Vesting / claim ──────────────────────────────────────────────────────

    /**
     * @notice Claim unlocked xZOD from a vesting position.
     * Linear vesting: cliff -> then proportional over vestingDuration.
     *
     * @param positionIndex  Index in vestingPositions[msg.sender]
     */
    function claim(uint256 positionIndex) external nonReentrant {
        require(positionIndex < vestingPositions[msg.sender].length, "ICO: invalid position");
        VestingPosition storage pos = vestingPositions[msg.sender][positionIndex];
        require(pos.totalXZod > 0,                "ICO: empty position");
        require(block.timestamp >= pos.cliffEnd,  "ICO: cliff not reached yet");

        uint256 unlocked       = _computeUnlocked(pos);
        uint256 claimableAmount = unlocked - pos.claimedXZod;
        require(claimableAmount > 0, "ICO: nothing to claim yet");

        pos.claimedXZod += claimableAmount;

        require(
            xZodToken.transfer(msg.sender, claimableAmount),
            "ICO: xZOD transfer failed"
        );

        emit Claimed(msg.sender, positionIndex, claimableAmount);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /// @notice Returns claimable xZOD for a position right now.
    function claimable(address wallet, uint256 positionIndex)
        external view returns (uint256)
    {
        if (positionIndex >= vestingPositions[wallet].length) return 0;
        VestingPosition storage pos = vestingPositions[wallet][positionIndex];
        if (block.timestamp < pos.cliffEnd) return 0;
        return _computeUnlocked(pos) - pos.claimedXZod;
    }

    /// @notice Returns all vesting positions for a wallet (for Dashboard display).
    function getVestingPositions(address wallet)
        external view returns (VestingPosition[] memory)
    {
        return vestingPositions[wallet];
    }

    /// @notice Returns current round config.
    function getCurrentRound() external view returns (RoundConfig memory) {
        return rounds[currentRound];
    }

    /// @notice Returns wallet summary for current round.
    function getWalletStatus(address wallet)
        external view
        returns (
            uint256 usdcPaid,
            uint256 xZodAllocated,
            bool    nftEvaluated,
            bool    nftReceived,
            uint256 remainingCap
        )
    {
        WalletRoundData storage wd = walletRoundData[wallet][currentRound];
        usdcPaid      = wd.usdcPaid;
        xZodAllocated = wd.xZodAllocated;
        nftEvaluated  = wd.nftEvaluated;
        nftReceived   = wd.nftReceived;
        remainingCap  = rounds[currentRound].maxPurchaseUSDC > wd.usdcPaid
            ? rounds[currentRound].maxPurchaseUSDC - wd.usdcPaid
            : 0;
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /**
     * @dev Pseudo-random 50% roll.
     * Uses block.prevrandao (EIP-4399, replaces difficulty post-merge) +
     * block.timestamp + wallet address + round for entropy.
     * Not manipulation-proof — upgrade to Chainlink VRF for mainnet.
     */
    function _roll50(address wallet) internal view returns (bool) {
        uint256 seed = uint256(
            keccak256(abi.encodePacked(wallet, block.prevrandao, block.timestamp, currentRound))
        );
        return seed % 2 == 0;
    }

    function _computeUnlocked(VestingPosition storage pos)
        internal view returns (uint256)
    {
        if (block.timestamp >= pos.vestingEnd) return pos.totalXZod;
        uint256 elapsed  = block.timestamp - pos.cliffEnd;
        uint256 duration = pos.vestingEnd   - pos.cliffEnd;
        return (pos.totalXZod * elapsed) / duration;
    }

    function _findVestingPosition(address wallet, uint256 round)
        internal view returns (uint256)
    {
        VestingPosition[] storage positions = vestingPositions[wallet];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].round == round) return i;
        }
        revert("ICO: vesting position not found");
    }

    // ─── Default S1 config ────────────────────────────────────────────────────

    /**
     * @dev Default Season 1 ICO parameters. All adjustable via configureRound().
     *
     * Round 1: $0.05/xZOD — Air NFT  — $50k cap   — 90d cliff + 270d vesting
     * Round 2: $0.08/xZOD — Water NFT — $100k cap  — 90d cliff + 270d vesting
     * Round 3: $0.12/xZOD — Fire NFT  — $150k cap  — 90d cliff + 270d vesting
     *
     * NFT tiers (all rounds):
     *   >= $500 cumulative -> guaranteed
     *   >= $100 cumulative -> 50% chance
     */
    function _configureDefaultRounds() internal {
        // Round 1 — Air Element
        rounds[1] = RoundConfig({
            pricePerToken:    50000,           // $0.05 per xZOD
            hardCap:          50_000_000000,   // $50,000
            minPurchaseUSDC:  100_000000,      // $100 min per tx
            maxPurchaseUSDC:  500_000000,      // $500 max per wallet
            nftTokenId:       3,               // Air Element
            nftGuaranteeUSDC: 500_000000,      // $500 -> guaranteed
            nftThresholdUSDC: 100_000000,      // $100 -> 50% chance
            cliffDuration:    90 days,
            vestingDuration:  270 days,
            active:           false
        });

        // Round 2 — Water Element
        rounds[2] = RoundConfig({
            pricePerToken:    80000,            // $0.08 per xZOD
            hardCap:          100_000_000000,   // $100,000
            minPurchaseUSDC:  100_000000,       // $100 min per tx
            maxPurchaseUSDC:  500_000000,       // $500 max per wallet
            nftTokenId:       2,                // Water Element
            nftGuaranteeUSDC: 500_000000,       // $500 -> guaranteed
            nftThresholdUSDC: 100_000000,       // $100 -> 50% chance
            cliffDuration:    90 days,
            vestingDuration:  270 days,
            active:           false
        });

        // Round 3 — Fire Element
        rounds[3] = RoundConfig({
            pricePerToken:    120000,           // $0.12 per xZOD
            hardCap:          150_000_000000,   // $150,000
            minPurchaseUSDC:  100_000000,       // $100 min per tx
            maxPurchaseUSDC:  500_000000,       // $500 max per wallet
            nftTokenId:       1,                // Fire Element
            nftGuaranteeUSDC: 500_000000,       // $500 -> guaranteed
            nftThresholdUSDC: 100_000000,       // $100 -> 50% chance
            cliffDuration:    90 days,
            vestingDuration:  270 days,
            active:           false
        });
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit xZOD into the contract to cover all vesting payouts.
     * Must be called before opening Round 1.
     * Amount = sum of all hardcaps / average price (conservative estimate).
     */
    function depositXZod(uint256 amount) external onlyOwner {
        require(amount > 0, "ICO: amount must be > 0");
        require(
            xZodToken.transferFrom(msg.sender, address(this), amount),
            "ICO: xZOD deposit failed"
        );
    }

    /// @notice Withdraw collected USDC to treasury.
    function withdrawUSDC(address to) external onlyOwner {
        require(to != address(0), "ICO: zero address");
        uint256 balance = usdcToken.balanceOf(address(this));
        require(balance > 0, "ICO: no USDC to withdraw");
        require(usdcToken.transfer(to, balance), "ICO: withdrawal failed");
        emit USDCWithdrawn(to, balance);
    }

    /// @notice Emergency pause.
    function pause()   external onlyOwner { _pause(); }
    /// @notice Resume after pause.
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Update NFT contract address.
    function setNFTContract(address newNFT) external onlyOwner {
        require(newNFT != address(0), "ICO: zero address");
        nftContract = IxZodNFTICO(newNFT);
    }
}
