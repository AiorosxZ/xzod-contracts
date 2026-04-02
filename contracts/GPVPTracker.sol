// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/AccessControl.sol";

/**
 * @title INFTRules
 * @notice Minimal interface to read GP/VP multipliers from NFTRules.
 */
interface INFTRules {
    function applyGPMultiplier(address wallet, uint256 rawGP) external view returns (uint256);
    function applyVPMultiplier(address wallet, uint256 rawVP) external view returns (uint256);
}

/**
 * @title GPVPTracker
 * @notice Tracks lifetime Governance Points (GP) and Validator Points (VP)
 *         for every wallet in the xZOD ecosystem.
 *
 * Points are cumulative and never reset.
 * GP gives voting power in the DAO.
 * VP determines eligibility for xZile validator role (2028).
 *
 * NFT multipliers (from NFTRules):
 *   Fire Element active  -> x1.5 GP on all recorded actions
 *   Earth Element active -> x1.5 VP on all recorded actions
 *
 * Who can record points (RECORDER_ROLE):
 *   - SeasonWars  (burn actions -> GP, swap fees -> GP)
 *   - StakingVault (stake >90 days -> VP, stake -> GP low)
 *   - LiquidityPool (LP >30 days -> GP + VP)
 *
 * Deployed after NFTRules. Constructor requires NFTRules address.
 * NFTRules (Sepolia): 0xd7e46DfF9E0095C8df9BCc5d2D6230bD4b72e7FF
 */
contract GPVPTracker is AccessControl {

    // ─── Roles ────────────────────────────────────────────────────────────────
    /// @notice Granted to contracts that are allowed to record GP/VP (SeasonWars, StakingVault, LP)
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    // ─── External contracts ───────────────────────────────────────────────────
    INFTRules public nftRules;

    // ─── Points storage ───────────────────────────────────────────────────────
    /// @notice Lifetime GP per wallet (never decreases)
    mapping(address => uint256) public totalGP;
    /// @notice Lifetime VP per wallet (never decreases)
    mapping(address => uint256) public totalVP;

    // ─── Source tracking (for transparency) ──────────────────────────────────
    /// @notice GP earned from burns per wallet
    mapping(address => uint256) public gpFromBurns;
    /// @notice GP earned from swaps per wallet
    mapping(address => uint256) public gpFromSwaps;
    /// @notice GP earned from staking per wallet
    mapping(address => uint256) public gpFromStaking;
    /// @notice GP earned from LP per wallet
    mapping(address => uint256) public gpFromLP;

    /// @notice VP earned from staking per wallet
    mapping(address => uint256) public vpFromStaking;
    /// @notice VP earned from LP per wallet
    mapping(address => uint256) public vpFromLP;

    // ─── Global totals (for quorum calculations) ──────────────────────────────
    uint256 public globalTotalGP;
    uint256 public globalTotalVP;

    // ─── Events ───────────────────────────────────────────────────────────────
    event GPRecorded(
        address indexed wallet,
        uint256 rawAmount,
        uint256 finalAmount,
        string  source
    );
    event VPRecorded(
        address indexed wallet,
        uint256 rawAmount,
        uint256 finalAmount,
        string  source
    );
    event NFTRulesUpdated(address indexed newNFTRules);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param nftRulesAddress Address of the deployed NFTRules contract.
     */
    constructor(address nftRulesAddress) {
        require(nftRulesAddress != address(0), "GPVPTracker: zero address");
        nftRules = INFTRules(nftRulesAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RECORDER_ROLE, msg.sender);
    }

    // ─── Record functions (called by protocol contracts) ──────────────────────

    /**
     * @notice Record Governance Points for a wallet.
     * Automatically applies Fire NFT x1.5 multiplier if active.
     *
     * @param wallet  The wallet earning GP
     * @param rawGP   Raw GP amount before NFT multiplier
     * @param source  Human-readable source label: "burn", "swap", "stake", "lp"
     */
    function recordGP(
        address wallet,
        uint256 rawGP,
        string calldata source
    ) external onlyRole(RECORDER_ROLE) {
        require(wallet != address(0), "GPVPTracker: zero address");
        require(rawGP > 0, "GPVPTracker: GP amount must be > 0");

        uint256 finalGP = nftRules.applyGPMultiplier(wallet, rawGP);

        totalGP[wallet]  += finalGP;
        globalTotalGP    += finalGP;

        // Track by source
        bytes32 sourceHash = keccak256(bytes(source));
        if      (sourceHash == keccak256("burn"))  gpFromBurns[wallet]   += finalGP;
        else if (sourceHash == keccak256("swap"))  gpFromSwaps[wallet]   += finalGP;
        else if (sourceHash == keccak256("stake")) gpFromStaking[wallet] += finalGP;
        else if (sourceHash == keccak256("lp"))    gpFromLP[wallet]      += finalGP;

        emit GPRecorded(wallet, rawGP, finalGP, source);
    }

    /**
     * @notice Record Validator Points for a wallet.
     * Automatically applies Earth NFT x1.5 multiplier if active.
     *
     * @param wallet  The wallet earning VP
     * @param rawVP   Raw VP amount before NFT multiplier
     * @param source  Human-readable source label: "stake", "lp"
     */
    function recordVP(
        address wallet,
        uint256 rawVP,
        string calldata source
    ) external onlyRole(RECORDER_ROLE) {
        require(wallet != address(0), "GPVPTracker: zero address");
        require(rawVP > 0, "GPVPTracker: VP amount must be > 0");

        uint256 finalVP = nftRules.applyVPMultiplier(wallet, rawVP);

        totalVP[wallet]  += finalVP;
        globalTotalVP    += finalVP;

        bytes32 sourceHash = keccak256(bytes(source));
        if      (sourceHash == keccak256("stake")) vpFromStaking[wallet] += finalVP;
        else if (sourceHash == keccak256("lp"))    vpFromLP[wallet]      += finalVP;

        emit VPRecorded(wallet, rawVP, finalVP, source);
    }

    /**
     * @notice Record both GP and VP in a single call.
     * Useful for LP actions which earn both simultaneously.
     */
    function recordGPAndVP(
        address wallet,
        uint256 rawGP,
        uint256 rawVP,
        string calldata source
    ) external onlyRole(RECORDER_ROLE) {
        require(wallet != address(0), "GPVPTracker: zero address");

        if (rawGP > 0) {
            uint256 finalGP = nftRules.applyGPMultiplier(wallet, rawGP);
            totalGP[wallet]  += finalGP;
            globalTotalGP    += finalGP;
            if (keccak256(bytes(source)) == keccak256("lp")) gpFromLP[wallet] += finalGP;
            emit GPRecorded(wallet, rawGP, finalGP, source);
        }

        if (rawVP > 0) {
            uint256 finalVP = nftRules.applyVPMultiplier(wallet, rawVP);
            totalVP[wallet]  += finalVP;
            globalTotalVP    += finalVP;
            if (keccak256(bytes(source)) == keccak256("lp")) vpFromLP[wallet] += finalVP;
            emit VPRecorded(wallet, rawVP, finalVP, source);
        }
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Returns GP and VP for a wallet in a single call.
     */
    function getPoints(address wallet)
        external view
        returns (uint256 gp, uint256 vp)
    {
        gp = totalGP[wallet];
        vp = totalVP[wallet];
    }

    /**
     * @notice Returns the wallet's GP as a percentage of total GP (basis points).
     * Used by governance to compute voting weight.
     * Returns 0 if globalTotalGP is 0.
     */
    function gpShareBp(address wallet) external view returns (uint256) {
        if (globalTotalGP == 0) return 0;
        return (totalGP[wallet] * 10000) / globalTotalGP;
    }

    /**
     * @notice Returns the wallet's VP as a percentage of total VP (basis points).
     * Used to check if a wallet meets the validator quorum threshold.
     */
    function vpShareBp(address wallet) external view returns (uint256) {
        if (globalTotalVP == 0) return 0;
        return (totalVP[wallet] * 10000) / globalTotalVP;
    }

    /**
     * @notice Returns the GP quorum participation rate in basis points.
     * Used by governance to verify the 25% quorum requirement for emission votes.
     * @param participatingGP Total GP of wallets that participated in the vote
     */
    function quorumReached(uint256 participatingGP) external view returns (bool) {
        if (globalTotalGP == 0) return false;
        // 25% quorum required (2500 bp)
        return (participatingGP * 10000) / globalTotalGP >= 2500;
    }

    /**
     * @notice Full GP breakdown by source for a wallet.
     * Used by the Dashboard frontend.
     */
    struct GPBreakdown {
        uint256 total;
        uint256 fromBurns;
        uint256 fromSwaps;
        uint256 fromStaking;
        uint256 fromLP;
    }

    function getGPBreakdown(address wallet) external view returns (GPBreakdown memory) {
        return GPBreakdown({
            total:       totalGP[wallet],
            fromBurns:   gpFromBurns[wallet],
            fromSwaps:   gpFromSwaps[wallet],
            fromStaking: gpFromStaking[wallet],
            fromLP:      gpFromLP[wallet]
        });
    }

    /**
     * @notice Full VP breakdown by source for a wallet.
     */
    struct VPBreakdown {
        uint256 total;
        uint256 fromStaking;
        uint256 fromLP;
    }

    function getVPBreakdown(address wallet) external view returns (VPBreakdown memory) {
        return VPBreakdown({
            total:       totalVP[wallet],
            fromStaking: vpFromStaking[wallet],
            fromLP:      vpFromLP[wallet]
        });
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Update NFTRules address (e.g. after seasonal redeployment).
     */
    function updateNFTRules(address newNFTRules) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newNFTRules != address(0), "GPVPTracker: zero address");
        nftRules = INFTRules(newNFTRules);
        emit NFTRulesUpdated(newNFTRules);
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
