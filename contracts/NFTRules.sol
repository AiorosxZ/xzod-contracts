// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/Ownable.sol";

/**
 * @title IxZodNFT
 * @notice Minimal interface for NFTRules to read activation state from xZodNFT.
 */
interface IxZodNFT {
    function getActiveElements(address wallet)
        external view
        returns (bool fire, bool water, bool air, bool earth);

    function getActiveSignsBitmask(address wallet)
        external view
        returns (uint256 bitmask);
}

/**
 * @title NFTRules
 * @notice Seasonal rules contract. Reads activation state from xZodNFT and
 *         computes all active bonuses for a given wallet.
 *
 * All bonus values are stored in basis points (bp):
 *   100 bp = 1%
 *   10000 bp = base multiplier (x1.0)
 *   15000 bp = x1.5 multiplier
 *
 * Called by SeasonWars, StakingVault, LiquidityPool to apply NFT bonuses.
 * Season config is updated each season by owner (later: DAO vote).
 *
 * Deployed after xZodNFT. Constructor requires xZodNFT address.
 * xZodNFT (Sepolia): 0x5249D8eacbD47080642a7d89884CC3A1c0A110e3
 */
contract NFTRules is Ownable {

    IxZodNFT public nft;

    // ─── Current season ───────────────────────────────────────────────────────
    uint256 public currentSeason;

    // ─── Bonus struct returned to external contracts ──────────────────────────

    struct WalletBonuses {
        // Fire
        uint256 burnPointsBp;       // e.g. 1500 = +15% burn points
        uint256 clanWeightBp;       // e.g. 15000 = x1.5 clan weight (base 10000 = x1.0)
        // Water
        bool    lpAccess;           // true if Water element active
        // Air
        uint256 swapFeeDiscountBp;  // e.g. 1000 = -10% on swap fee (0.30% -> 0.20%)
        // Earth
        uint256 stakingApyBp;       // e.g. 200 = +2% APY
        // GP / VP multipliers
        uint256 gpMultiplierBp;     // e.g. 15000 = x1.5 GP (base 10000 = x1.0)
        uint256 vpMultiplierBp;     // e.g. 15000 = x1.5 VP (base 10000 = x1.0)
    }

    // ─── Season config storage ────────────────────────────────────────────────

    struct ElementConfig {
        uint256 baseBurnBp;          // Fire: base burn bonus bp (1500 = +15%)
        uint256 baseClanWeightBp;    // Fire: clan weight (15000 = x1.5)
        uint256 baseStakingApyBp;    // Earth: base staking APY bonus bp (200 = +2%)
        uint256 baseSwapDiscountBp;  // Air: base swap fee discount bp (1000 = -10%)
        uint256 gpMultiplierBp;      // Fire: GP multiplier (15000 = x1.5)
        uint256 vpMultiplierBp;      // Earth: VP multiplier (15000 = x1.5)
    }

    struct SignConfig {
        uint256 burnBpPerSign;           // Fire signs: extra burn bp per active sign (500 = +5%)
        uint256 stakingApyBpPerSign;     // Earth signs: extra APY bp per sign (100 = +1%)
        uint256 swapDiscountBpPerSign;   // Air signs: extra swap discount bp per sign (500)
        uint256 lpYieldBpPerSign;        // Water signs: extra LP yield bp per sign (500 = +5%)
    }

    // season => config
    mapping(uint256 => ElementConfig) public elementConfig;
    mapping(uint256 => SignConfig)    public signConfig;

    // ─── Events ───────────────────────────────────────────────────────────────
    event SeasonConfigSet(uint256 indexed season);
    event SeasonAdvanced(uint256 indexed newSeason);
    event NFTAddressUpdated(address indexed newNFT);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param nftAddress Address of the deployed xZodNFT contract.
     */
    constructor(address nftAddress) Ownable(msg.sender) {
        require(nftAddress != address(0), "NFTRules: zero address");
        nft = IxZodNFT(nftAddress);
        currentSeason = 1;
        _setDefaultS1Config();
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Set the full season config (element + sign bonuses).
     * Called by owner each season (later replaced by DAO vote).
     */
    function setSeasonConfig(
        uint256 season,
        ElementConfig calldata elConfig,
        SignConfig    calldata sgConfig
    ) external onlyOwner {
        elementConfig[season] = elConfig;
        signConfig[season]    = sgConfig;
        emit SeasonConfigSet(season);
    }

    /**
     * @notice Advance to a new season. Season number must increase.
     */
    function advanceSeason(uint256 newSeason) external onlyOwner {
        require(newSeason > currentSeason, "NFTRules: season must increase");
        currentSeason = newSeason;
        emit SeasonAdvanced(newSeason);
    }

    /**
     * @notice Update the xZodNFT contract address (e.g. after a migration).
     */
    function updateNFTAddress(address newNFT) external onlyOwner {
        require(newNFT != address(0), "NFTRules: zero address");
        nft = IxZodNFT(newNFT);
        emit NFTAddressUpdated(newNFT);
    }

    // ─── Core: compute bonuses ────────────────────────────────────────────────

    /**
     * @notice Returns all active bonuses for a wallet based on current season config.
     * Main function called by SeasonWars, StakingVault, LiquidityPool.
     *
     * @param wallet The wallet address to compute bonuses for.
     * @return bonuses Struct containing all active bonus values in basis points.
     */
    function getBonuses(address wallet) external view returns (WalletBonuses memory bonuses) {
        ElementConfig storage ec = elementConfig[currentSeason];
        SignConfig    storage sc = signConfig[currentSeason];

        (bool fire, bool water, bool air, bool earth) = nft.getActiveElements(wallet);
        uint256 bitmask = nft.getActiveSignsBitmask(wallet);

        // Count active signs per element using bitmask bit positions
        // Fire:  Aries(bit 0), Leo(bit 4), Sagittarius(bit 8)
        // Earth: Taurus(bit 1), Virgo(bit 5), Capricorn(bit 9)
        // Air:   Gemini(bit 2), Libra(bit 6), Aquarius(bit 10)
        // Water: Cancer(bit 3), Scorpio(bit 7), Pisces(bit 11)
        uint256 fireSigns  = _countBits(bitmask, 0)  + _countBits(bitmask, 4)  + _countBits(bitmask, 8);
        uint256 earthSigns = _countBits(bitmask, 1)  + _countBits(bitmask, 5)  + _countBits(bitmask, 9);
        uint256 airSigns   = _countBits(bitmask, 2)  + _countBits(bitmask, 6)  + _countBits(bitmask, 10);

        // ── Fire ──
        if (fire) {
            bonuses.burnPointsBp = ec.baseBurnBp + (fireSigns * sc.burnBpPerSign);
            bonuses.clanWeightBp = ec.baseClanWeightBp;
            bonuses.gpMultiplierBp = ec.gpMultiplierBp;
        } else {
            bonuses.clanWeightBp   = 10000; // x1.0 base
            bonuses.gpMultiplierBp = 10000;
        }

        // ── Water ──
        bonuses.lpAccess = water;
        // LP yield bonus available separately via getLPYieldBonus()
        // waterSigns used there to avoid redundant call

        // ── Air ──
        if (air) {
            bonuses.swapFeeDiscountBp = ec.baseSwapDiscountBp + (airSigns * sc.swapDiscountBpPerSign);
        }

        // ── Earth ──
        if (earth) {
            bonuses.stakingApyBp   = ec.baseStakingApyBp + (earthSigns * sc.stakingApyBpPerSign);
            bonuses.vpMultiplierBp = ec.vpMultiplierBp;
        } else {
            bonuses.vpMultiplierBp = 10000; // x1.0 base
        }
    }

    /**
     * @notice Returns LP yield bonus in basis points for a wallet.
     * Used specifically by the LiquidityPool contract.
     * Returns 0 if Water element is not active.
     */
    function getLPYieldBonus(address wallet) external view returns (uint256 lpYieldBp) {
        (, bool water,,) = nft.getActiveElements(wallet);
        if (!water) return 0;

        uint256 bitmask = nft.getActiveSignsBitmask(wallet);
        uint256 waterSigns = _countBits(bitmask, 3) + _countBits(bitmask, 7) + _countBits(bitmask, 11);
        lpYieldBp = waterSigns * signConfig[currentSeason].lpYieldBpPerSign;
    }

    /**
     * @notice Apply Fire NFT GP multiplier to a raw GP amount.
     * Returns rawGP unchanged if Fire element is not active.
     */
    function applyGPMultiplier(address wallet, uint256 rawGP) external view returns (uint256) {
        (bool fire,,,) = nft.getActiveElements(wallet);
        if (!fire) return rawGP;
        return (rawGP * elementConfig[currentSeason].gpMultiplierBp) / 10000;
    }

    /**
     * @notice Apply Earth NFT VP multiplier to a raw VP amount.
     * Returns rawVP unchanged if Earth element is not active.
     */
    function applyVPMultiplier(address wallet, uint256 rawVP) external view returns (uint256) {
        (,,, bool earth) = nft.getActiveElements(wallet);
        if (!earth) return rawVP;
        return (rawVP * elementConfig[currentSeason].vpMultiplierBp) / 10000;
    }

    // ─── Full status view (for Dashboard frontend) ────────────────────────────

    struct WalletNFTStatus {
        bool    fireActive;
        bool    waterActive;
        bool    airActive;
        bool    earthActive;
        uint256 activeSignsBitmask;
        WalletBonuses bonuses;
        uint256 lpYieldBp;
    }

    /**
     * @notice Returns complete NFT status and all bonuses for a wallet.
     * Called by the frontend Dashboard to display active bonuses.
     */
    function getFullStatus(address wallet) external view returns (WalletNFTStatus memory status) {
        (status.fireActive, status.waterActive, status.airActive, status.earthActive)
            = nft.getActiveElements(wallet);
        status.activeSignsBitmask = nft.getActiveSignsBitmask(wallet);
        status.bonuses   = this.getBonuses(wallet);
        status.lpYieldBp = this.getLPYieldBonus(wallet);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /**
     * @dev Returns 1 if bit at position `pos` is set in `bitmask`, else 0.
     * Used to count active signs per element.
     */
    function _countBits(uint256 bitmask, uint256 pos) internal pure returns (uint256) {
        return (bitmask >> pos) & 1;
    }

    // ─── Default Season 1 config ──────────────────────────────────────────────

    /**
     * @dev Sets the default Season 1 configuration.
     * All values in basis points (100 bp = 1%).
     *
     * Fire:  +15% burn points, x1.5 clan weight, x1.5 GP multiplier
     * Water: LP access + lunar airdrops (no bp value, boolean)
     * Air:   -10% swap fee (0.30% -> 0.20%), each Air sign -0.05% more
     * Earth: +2% APY, x1.5 VP multiplier, each Earth sign +1% APY
     *
     * Sign amplifiers (per active sign of matching element):
     * Fire signs:  +5% BP each  (max +15% with all 3)
     * Earth signs: +1% APY each (max +3% with all 3)
     * Air signs:   -0.05% swap  (min 0.05% with all 3)
     * Water signs: +5% LP yield (max +15% with all 3)
     */
    function _setDefaultS1Config() internal {
        elementConfig[1] = ElementConfig({
            baseBurnBp:         1500,   // Fire: +15% burn points
            baseClanWeightBp:   15000,  // Fire: x1.5 clan weight
            baseStakingApyBp:   200,    // Earth: +2% APY
            baseSwapDiscountBp: 1000,   // Air: 0.30% -> 0.20% (-10% of fee = -1000bp of fee)
            gpMultiplierBp:     15000,  // Fire: x1.5 GP
            vpMultiplierBp:     15000   // Earth: x1.5 VP
        });

        signConfig[1] = SignConfig({
            burnBpPerSign:         500,  // Fire signs: +5% BP each
            stakingApyBpPerSign:   100,  // Earth signs: +1% APY each
            swapDiscountBpPerSign: 500,  // Air signs: -0.05% swap each
            lpYieldBpPerSign:      500   // Water signs: +5% LP yield each
        });
    }
}
