// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC1155/ERC1155.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/ReentrancyGuard.sol";

/**
 * @title xZodNFT
 * @notice ERC-1155 NFT contract for the xZOD ecosystem.
 *
 * Token ID ranges:
 *   Elemental  :    1 –   4   (Fire=1, Water=2, Air=3, Earth=4)
 *   Zodiac Sign:  101 – 112   (Aries=101 … Pisces=112)
 *   Collector  : 1001+        (minted manually by owner)
 *
 * Activation rules:
 *   Elemental  — activate() once per wallet, locks token, 72h cooldown after deactivate()
 *   Zodiac     — activate() once ever (burned flag), locks for 180 days, auto-unlocks on expiry
 *   Collector  — never locked, purely commemorative
 *
 * Note: SafeMath is not used — Solidity 0.8.x has built-in overflow protection.
 */
contract xZodNFT is ERC1155, AccessControl, ReentrancyGuard {

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ─── Token ID constants ───────────────────────────────────────────────────
    uint256 public constant FIRE   = 1;
    uint256 public constant WATER  = 2;
    uint256 public constant AIR    = 3;
    uint256 public constant EARTH  = 4;

    uint256 public constant ARIES       = 101;
    uint256 public constant TAURUS      = 102;
    uint256 public constant GEMINI      = 103;
    uint256 public constant CANCER      = 104;
    uint256 public constant LEO         = 105;
    uint256 public constant VIRGO       = 106;
    uint256 public constant LIBRA       = 107;
    uint256 public constant SCORPIO     = 108;
    uint256 public constant SAGITTARIUS = 109;
    uint256 public constant CAPRICORN   = 110;
    uint256 public constant AQUARIUS    = 111;
    uint256 public constant PISCES      = 112;

    /// @notice Maps each zodiac sign tokenId to its parent element tokenId
    mapping(uint256 => uint256) public signElement;

    // ─── Collector supply tracking ────────────────────────────────────────────
    /// @notice Fixed max supply per collector tokenId (set at creation, immutable)
    mapping(uint256 => uint256) public collectorMaxSupply;
    /// @notice Number of collector tokens minted so far per tokenId
    mapping(uint256 => uint256) public collectorMinted;

    // ─── Elemental activation state ───────────────────────────────────────────
    /// @notice True if a wallet has explicitly activated a given elemental NFT
    mapping(address => mapping(uint256 => bool))    public elementActivated;
    /// @notice Timestamp of last deactivation — used to enforce 72h cooldown
    mapping(address => mapping(uint256 => uint256)) public elementDeactivatedAt;

    uint256 public constant ELEMENT_COOLDOWN = 72 hours;

    // ─── Zodiac activation state ──────────────────────────────────────────────
    /// @notice Timestamp when a wallet activated a given sign (0 = never activated)
    mapping(address => mapping(uint256 => uint256)) public signActivatedAt;
    /// @notice True if a wallet ever activated a sign — prevents re-activation after expiry
    mapping(address => mapping(uint256 => bool))    public signActivatedOnce;

    uint256 public constant SIGN_DURATION = 180 days;

    // ─── Transfer lock ────────────────────────────────────────────────────────
    /// @notice True if a token is locked for a wallet — prevents any transfer
    mapping(address => mapping(uint256 => bool)) public locked;

    // ─── Events ───────────────────────────────────────────────────────────────
    event ElementActivated(address indexed wallet, uint256 indexed tokenId);
    event ElementDeactivated(address indexed wallet, uint256 indexed tokenId);
    event SignActivated(address indexed wallet, uint256 indexed tokenId, uint256 expiresAt);
    /// @notice Emitted when an expired sign lock is released (combines SignExpired + Unlocked)
    event SignExpiredAndUnlocked(address indexed wallet, uint256 indexed tokenId, uint256 expiredAt);
    event CollectorCreated(uint256 indexed tokenId, uint256 maxSupply);
    event CollectorMinted(address indexed to, uint256 indexed tokenId, uint256 amount);
    event Locked(address indexed wallet, uint256 indexed tokenId);
    event Unlocked(address indexed wallet, uint256 indexed tokenId);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param uri_ ERC-1155 metadata URI. Use {id} placeholder for per-token URIs.
     *             Example: "https://meta.xzod.io/nft/{id}.json"
     */
    constructor(string memory uri_) ERC1155(uri_) {
        require(bytes(uri_).length > 0, "URI cannot be empty");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        // Map each zodiac sign to its parent element
        signElement[ARIES]       = FIRE;
        signElement[LEO]         = FIRE;
        signElement[SAGITTARIUS] = FIRE;
        signElement[CANCER]      = WATER;
        signElement[SCORPIO]     = WATER;
        signElement[PISCES]      = WATER;
        signElement[GEMINI]      = AIR;
        signElement[LIBRA]       = AIR;
        signElement[AQUARIUS]    = AIR;
        signElement[TAURUS]      = EARTH;
        signElement[VIRGO]       = EARTH;
        signElement[CAPRICORN]   = EARTH;
    }

    // ─── Type helpers ─────────────────────────────────────────────────────────

    /// @notice Returns true if tokenId is an elemental NFT (Fire, Water, Air, Earth)
    function isElemental(uint256 tokenId) public pure returns (bool) {
        return tokenId >= 1 && tokenId <= 4;
    }

    /// @notice Returns true if tokenId is a zodiac sign NFT (Aries–Pisces)
    function isZodiac(uint256 tokenId) public pure returns (bool) {
        return tokenId >= 101 && tokenId <= 112;
    }

    /// @notice Returns true if tokenId is a collector NFT (commemorative, no gameplay effect)
    function isCollector(uint256 tokenId) public pure returns (bool) {
        return tokenId >= 1001;
    }

    // ─── Sign status helpers ──────────────────────────────────────────────────

    /**
     * @notice Returns true if a zodiac sign is currently active (activated and not expired).
     * @param wallet The wallet to check
     * @param tokenId Must be a zodiac sign token (101–112)
     */
    function isSignActive(address wallet, uint256 tokenId) public view returns (bool) {
        if (!isZodiac(tokenId)) return false;
        uint256 activatedAt = signActivatedAt[wallet][tokenId];
        if (activatedAt == 0) return false;
        return block.timestamp < activatedAt + SIGN_DURATION;
    }

    /**
     * @notice Returns the number of seconds remaining before a sign expires.
     * Returns 0 if the sign is inactive or already expired.
     */
    function signTimeRemaining(address wallet, uint256 tokenId) external view returns (uint256) {
        if (!isSignActive(wallet, tokenId)) return 0;
        return (signActivatedAt[wallet][tokenId] + SIGN_DURATION) - block.timestamp;
    }

    /**
     * @notice Returns the number of seconds remaining on the deactivation cooldown.
     * Returns 0 if no cooldown is active (wallet can activate freely).
     */
    function elementCooldownRemaining(address wallet, uint256 tokenId) external view returns (uint256) {
        uint256 deactivatedAt = elementDeactivatedAt[wallet][tokenId];
        if (deactivatedAt == 0) return 0;
        uint256 cooldownEnd = deactivatedAt + ELEMENT_COOLDOWN;
        if (block.timestamp >= cooldownEnd) return 0;
        return cooldownEnd - block.timestamp;
    }

    // ─── Elemental activation ─────────────────────────────────────────────────

    /**
     * @notice Activate an elemental NFT to enable its season bonuses.
     *
     * Activation locks the token — it cannot be transferred while active.
     * A 72-hour cooldown applies if the wallet previously deactivated this element.
     *
     * Requirements:
     *  - tokenId must be an elemental (1–4)
     *  - Caller must hold at least 1 of this token
     *  - Token must not already be activated
     *  - 72h cooldown since last deactivation must have elapsed
     */
    function activateElement(uint256 tokenId) external nonReentrant {
        require(isElemental(tokenId), "xZodNFT: not an elemental token (use IDs 1-4)");
        require(balanceOf(msg.sender, tokenId) > 0, "xZodNFT: caller does not own this NFT");
        require(!elementActivated[msg.sender][tokenId], "xZodNFT: elemental already activated");

        uint256 deactivatedAt = elementDeactivatedAt[msg.sender][tokenId];
        if (deactivatedAt > 0) {
            require(
                block.timestamp >= deactivatedAt + ELEMENT_COOLDOWN,
                "xZodNFT: 72h cooldown in effect - wait before re-activating"
            );
        }

        elementActivated[msg.sender][tokenId] = true;
        locked[msg.sender][tokenId]           = true;

        emit ElementActivated(msg.sender, tokenId);
        emit Locked(msg.sender, tokenId);
    }

    /**
     * @notice Deactivate an elemental NFT, removing its bonuses immediately.
     *
     * Starts a 72-hour cooldown before the same wallet can re-activate.
     * The token becomes transferable again after deactivation.
     *
     * Requirements:
     *  - tokenId must be an elemental (1–4)
     *  - Token must currently be activated by the caller
     */
    function deactivateElement(uint256 tokenId) external nonReentrant {
        require(isElemental(tokenId), "xZodNFT: not an elemental token (use IDs 1-4)");
        require(elementActivated[msg.sender][tokenId], "xZodNFT: elemental is not currently activated");

        elementActivated[msg.sender][tokenId]    = false;
        elementDeactivatedAt[msg.sender][tokenId] = block.timestamp;
        locked[msg.sender][tokenId]              = false;

        emit ElementDeactivated(msg.sender, tokenId);
        emit Unlocked(msg.sender, tokenId);
    }

    // ─── Zodiac activation ────────────────────────────────────────────────────

    /**
     * @notice Activate a zodiac sign NFT to enable its season bonuses for 180 days.
     *
     * This is a ONE-TIME operation per wallet per sign token — once used,
     * the sign cannot be re-activated even after it expires. The token is locked
     * for the full 180-day duration and unlocked via releaseExpiredSign() after expiry.
     *
     * Requirements:
     *  - tokenId must be a zodiac sign (101–112)
     *  - Caller must hold at least 1 of this token
     *  - Sign must never have been activated by this wallet before
     *  - The matching elemental NFT must currently be activated by this wallet
     *    (e.g., activating Aries requires Fire to be active)
     */
    function activateSign(uint256 tokenId) external nonReentrant {
        require(isZodiac(tokenId), "xZodNFT: not a zodiac sign token (use IDs 101-112)");
        require(balanceOf(msg.sender, tokenId) > 0, "xZodNFT: caller does not own this NFT");
        require(
            !signActivatedOnce[msg.sender][tokenId],
            "xZodNFT: this sign has already been activated - one-time use only"
        );

        uint256 parentElement = signElement[tokenId];
        require(
            elementActivated[msg.sender][parentElement],
            "xZodNFT: parent elemental NFT must be activated before activating this sign"
        );

        signActivatedAt[msg.sender][tokenId]   = block.timestamp;
        signActivatedOnce[msg.sender][tokenId] = true;
        locked[msg.sender][tokenId]            = true;

        uint256 expiresAt = block.timestamp + SIGN_DURATION;
        emit SignActivated(msg.sender, tokenId, expiresAt);
        emit Locked(msg.sender, tokenId);
    }

    /**
     * @notice Release the transfer lock on an expired zodiac sign NFT.
     *
     * Can be called by anyone (e.g., keeper bots, frontend) once the 180-day
     * duration has elapsed. The sign's bonus is already inactive at this point
     * (isSignActive() returns false) — this call only cleans up the lock so
     * the token can be transferred or sold on the marketplace.
     *
     * Requirements:
     *  - tokenId must be a zodiac sign (101–112)
     *  - Token must currently be locked for this wallet
     *  - 180 days must have passed since activation
     */
    function releaseExpiredSign(address wallet, uint256 tokenId) external {
        require(isZodiac(tokenId), "xZodNFT: not a zodiac sign token (use IDs 101-112)");
        require(locked[wallet][tokenId], "xZodNFT: token is not locked for this wallet");
        require(
            signActivatedAt[wallet][tokenId] > 0 &&
            block.timestamp >= signActivatedAt[wallet][tokenId] + SIGN_DURATION,
            "xZodNFT: sign has not yet expired (180 days must pass)"
        );

        locked[wallet][tokenId] = false;
        uint256 expiredAt = signActivatedAt[wallet][tokenId] + SIGN_DURATION;
        emit SignExpiredAndUnlocked(wallet, tokenId, expiredAt);
    }

    // ─── Transfer guard ───────────────────────────────────────────────────────

    /**
     * @dev Overrides ERC-1155 internal transfer hook to enforce the lock mechanism.
     * Minting (from == address(0)) bypasses the lock check intentionally.
     * Uses calldata arrays for gas efficiency.
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        if (from != address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                require(
                    !locked[from][ids[i]],
                    "xZodNFT: token is locked - deactivate it before transferring"
                );
            }
        }
        super._update(from, to, ids, values);
    }

    // ─── Minting ──────────────────────────────────────────────────────────────

    /**
     * @notice Mint elemental or zodiac NFTs.
     * Called by contracts with MINTER_ROLE (SeasonWars rewards, ICO contract).
     * @param to Recipient address
     * @param tokenId Must be elemental (1–4) or zodiac (101–112)
     * @param amount Number of tokens to mint
     */
    function mint(address to, uint256 tokenId, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(!isCollector(tokenId), "xZodNFT: use mintCollector() for collector NFTs");
        require(to != address(0), "xZodNFT: mint to zero address");
        _mint(to, tokenId, amount, "");
    }

    /**
     * @notice Batch mint elemental or zodiac NFTs.
     * Useful for ICO distributions (mint Air NFT to all Round 1 participants).
     */
    function mintBatch(
        address to,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "xZodNFT: mint to zero address");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(!isCollector(tokenIds[i]), "xZodNFT: use mintCollector() for collector NFTs");
        }
        _mintBatch(to, tokenIds, amounts, "");
    }

    /**
     * @notice Register a new collector NFT type with a fixed, immutable max supply.
     * Must be called before mintCollector().
     * @param tokenId Must be >= 1001 and not previously registered
     * @param maxSupply Total number that will ever exist — cannot be changed
     */
    function createCollector(uint256 tokenId, uint256 maxSupply)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(isCollector(tokenId), "xZodNFT: collector tokenId must be >= 1001");
        require(collectorMaxSupply[tokenId] == 0, "xZodNFT: collector already registered");
        require(maxSupply > 0, "xZodNFT: max supply must be greater than zero");

        collectorMaxSupply[tokenId] = maxSupply;
        emit CollectorCreated(tokenId, maxSupply);
    }

    /**
     * @notice Mint collector NFTs to a recipient. Admin only.
     * Respects the fixed max supply registered via createCollector().
     * @param to Recipient address
     * @param tokenId Must be a registered collector token (>= 1001)
     * @param amount Number to mint — must not exceed remaining supply
     */
    function mintCollector(address to, uint256 tokenId, uint256 amount)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(isCollector(tokenId), "xZodNFT: not a collector token (use IDs >= 1001)");
        require(to != address(0), "xZodNFT: mint to zero address");
        require(collectorMaxSupply[tokenId] > 0, "xZodNFT: collector not registered - call createCollector() first");
        require(
            collectorMinted[tokenId] + amount <= collectorMaxSupply[tokenId],
            "xZodNFT: amount exceeds remaining collector supply"
        );

        collectorMinted[tokenId] += amount;
        _mint(to, tokenId, amount, "");
        emit CollectorMinted(to, tokenId, amount);
    }

    // ─── URI management ───────────────────────────────────────────────────────

    /**
     * @notice Update the metadata URI. Admin only.
     * @param newuri New URI string, should contain {id} placeholder
     */
    function setURI(string memory newuri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bytes(newuri).length > 0, "xZodNFT: URI cannot be empty");
        _setURI(newuri);
    }

    // ─── View functions for external contracts ────────────────────────────────

    /**
     * @notice Returns the activation status of all 4 elemental NFTs for a wallet.
     * Used by NFTRules.getBonuses() and the frontend Dashboard.
     */
    function getActiveElements(address wallet)
        external view
        returns (bool fire, bool water, bool air, bool earth)
    {
        fire  = elementActivated[wallet][FIRE];
        water = elementActivated[wallet][WATER];
        air   = elementActivated[wallet][AIR];
        earth = elementActivated[wallet][EARTH];
    }

    /**
     * @notice Returns a bitmask of currently active zodiac signs for a wallet.
     * Bit i is set if sign token (101 + i) is currently active and not expired.
     * Bit 0 = Aries, Bit 1 = Taurus, ..., Bit 11 = Pisces
     * Used by NFTRules to count active signs per element.
     */
    function getActiveSignsBitmask(address wallet) external view returns (uint256 bitmask) {
        for (uint256 i = 0; i < 12; i++) {
            if (isSignActive(wallet, 101 + i)) {
                bitmask |= (1 << i);
            }
        }
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
