// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────
//  Minimal ERC20 interface — no heavy imports
// ─────────────────────────────────────────────
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ─────────────────────────────────────────────
//  ReservePool — xZOD ↔ ZOD exchange
//
//  Core invariant:
//  • 1 xZOD = 12 ZOD (any type or mix)
//  • Owner can deposit, never withdraw
//  • Emergency pause by owner
//  • Gas optimised: immutable, uint128, unchecked
// ─────────────────────────────────────────────
contract ReservePool {

    // ── Custom errors (cheaper than require + string) ──
    error NotOwner();
    error Paused();
    error NotPaused();
    error InvalidArrayLength();
    error InvalidSignIndex();
    error ZeroAmount();
    error InsufficientPoolZOD(uint8 signIndex);
    error InsufficientPoolXZOD();
    error InsufficientAllowance();
    error TransferFailed();
    error SameSign();

    // ── Events ──
    event ZODBought(address indexed user, uint8[] signs, uint256[] amounts, uint256 xzodSpent);
    event ZODSold(address indexed user, uint8[] signs, uint256[] amounts, uint256 xzodReceived);
    event ZODSwapped(address indexed user, uint8 fromSign, uint8 toSign, uint256 amount);
    event Deposited(address indexed token, uint256 amount);
    event PauseToggled(bool paused);

    // ── Constants ──
    uint256 public constant RATIO = 12;          // 1 xZOD = 12 ZOD
    uint8   public constant NUM_SIGNS = 12;

    // ── Immutables (read from bytecode, not storage = free gas) ──
    address public immutable owner;
    IERC20  public immutable xzod;

    // ── Storage ──
    address[NUM_SIGNS] public zodTokens;         // The 12 ZOD token addresses
    bool public paused;

    // ── Constructor ──
    constructor(address _xzod, address[12] memory _zodTokens) {
        owner     = msg.sender;
        xzod      = IERC20(_xzod);
        zodTokens = _zodTokens;
    }

    // ── Modifiers ──
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ── Emergency pause ──
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }

    // ────────────────────────────────────────────────────────────────
    //  INITIAL DEPOSIT (owner only — no withdrawal function)
    // ────────────────────────────────────────────────────────────────

    /// @notice Deposit xZOD into the pool
    function depositXZOD(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (!xzod.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposited(address(xzod), amount);
    }

    /// @notice Deposit a single ZOD sign into the pool
    function depositZOD(uint8 signIndex, uint256 amount) external onlyOwner {
        if (signIndex >= NUM_SIGNS) revert InvalidSignIndex();
        if (amount == 0) revert ZeroAmount();
        if (!IERC20(zodTokens[signIndex]).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposited(zodTokens[signIndex], amount);
    }

    /// @notice Deposit all 12 ZODs in a single transaction (saves gas vs 12 calls)
    function depositAllZODs(uint256[12] calldata amounts) external onlyOwner {
        for (uint8 i = 0; i < NUM_SIGNS;) {
            if (amounts[i] > 0) {
                if (!IERC20(zodTokens[i]).transferFrom(msg.sender, address(this), amounts[i])) revert TransferFailed();
                emit Deposited(zodTokens[i], amounts[i]);
            }
            unchecked { ++i; }
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  BUY: xZOD → ZOD(s)
    //
    //  User specifies a mix of desired ZODs.
    //  Contract calculates the total xZOD cost.
    //  Rule: sum(amounts) / RATIO = xZOD cost (integer division).
    //  12 ZOD = 1 xZOD exactly.
    // ────────────────────────────────────────────────────────────────

    /// @notice Buy a mix of ZODs with xZOD
    /// @param signs   Indices of desired signs (0=Aries...11=Pisces)
    /// @param amounts Desired ZOD amounts per sign (in wei)
    function buyZOD(
        uint8[]  calldata signs,
        uint256[] calldata amounts
    ) external whenNotPaused {
        uint256 len = signs.length;
        if (len == 0 || len != amounts.length) revert InvalidArrayLength();

        // Calculate total ZOD requested
        uint256 totalZOD;
        for (uint256 i = 0; i < len; ++i) {
            if (signs[i] >= NUM_SIGNS) revert InvalidSignIndex();
            if (amounts[i] == 0) revert ZeroAmount();
            unchecked { totalZOD += amounts[i]; } // overflow impossible: supply is bounded
        }

        // xZOD cost = totalZOD / 12
        // Integer division — remainder is gifted to the pool (anti-dust)
        uint256 xzodCost = totalZOD / RATIO;
        if (xzodCost == 0) revert ZeroAmount();

        // Verify pool has enough ZOD BEFORE any transfer
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                if (IERC20(zodTokens[signs[i]]).balanceOf(address(this)) < amounts[i]) {
                    revert InsufficientPoolZOD(signs[i]);
                }
            }
        }

        // Pull xZOD from user
        if (!xzod.transferFrom(msg.sender, address(this), xzodCost)) revert TransferFailed();

        // Send ZODs to user
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                if (!IERC20(zodTokens[signs[i]]).transfer(msg.sender, amounts[i])) revert TransferFailed();
            }
        }

        emit ZODBought(msg.sender, signs, amounts, xzodCost);
    }

    // ────────────────────────────────────────────────────────────────
    //  SELL: ZOD(s) → xZOD
    //
    //  User returns a mix of ZODs.
    //  Contract calculates the xZOD to return.
    // ────────────────────────────────────────────────────────────────

    /// @notice Sell a mix of ZODs to receive xZOD
    /// @param signs   Indices of signs to sell
    /// @param amounts ZOD amounts to sell per sign (in wei)
    function sellZOD(
        uint8[]  calldata signs,
        uint256[] calldata amounts
    ) external whenNotPaused {
        uint256 len = signs.length;
        if (len == 0 || len != amounts.length) revert InvalidArrayLength();

        // Calculate total ZOD sold
        uint256 totalZOD;
        for (uint256 i = 0; i < len; ++i) {
            if (signs[i] >= NUM_SIGNS) revert InvalidSignIndex();
            if (amounts[i] == 0) revert ZeroAmount();
            unchecked { totalZOD += amounts[i]; } // overflow impossible: supply is bounded
        }

        // xZOD to return = totalZOD / 12
        uint256 xzodOut = totalZOD / RATIO;
        if (xzodOut == 0) revert ZeroAmount();

        // Verify pool has enough xZOD
        if (xzod.balanceOf(address(this)) < xzodOut) revert InsufficientPoolXZOD();

        // Pull ZODs from user
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                if (!IERC20(zodTokens[signs[i]]).transferFrom(msg.sender, address(this), amounts[i])) revert TransferFailed();
            }
        }

        // Send xZOD to user
        if (!xzod.transfer(msg.sender, xzodOut)) revert TransferFailed();

        emit ZODSold(msg.sender, signs, amounts, xzodOut);
    }

    // ────────────────────────────────────────────────────────────────
    //  DIRECT SWAP: ZOD → ZOD (single transaction, no xZOD involved)
    //
    //  Internal exchange between two pool reserves.
    //  xZOD does not move — only ZODs are exchanged.
    //  Gas optimal: no double xZOD transfer.
    // ────────────────────────────────────────────────────────────────

    /// @notice Direct swap ZOD source → ZOD target, same amount, single tx
    /// @param fromSign  Source sign index (0=Aries...11=Pisces)
    /// @param toSign    Target sign index
    /// @param amount    ZOD amount to swap (in wei)
    function swapZOD(
        uint8 fromSign,
        uint8 toSign,
        uint256 amount
    ) external whenNotPaused {
        if (fromSign >= NUM_SIGNS) revert InvalidSignIndex();
        if (toSign >= NUM_SIGNS) revert InvalidSignIndex();
        if (fromSign == toSign) revert SameSign();
        if (amount == 0) revert ZeroAmount();

        // Verify pool has enough of the target ZOD
        if (IERC20(zodTokens[toSign]).balanceOf(address(this)) < amount) {
            revert InsufficientPoolZOD(toSign);
        }

        // Pull source ZOD from user
        if (!IERC20(zodTokens[fromSign]).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        // Send target ZOD to user
        if (!IERC20(zodTokens[toSign]).transfer(msg.sender, amount)) revert TransferFailed();

        emit ZODSwapped(msg.sender, fromSign, toSign, amount);
    }

    // ────────────────────────────────────────────────────────────────
    //  VIEWS (read-only, free gas)
    // ────────────────────────────────────────────────────────────────

    /// @notice Returns pool balances for all tokens
    function getPoolBalances() external view returns (
        uint256 xzodBalance,
        uint256[12] memory zodBalances
    ) {
        xzodBalance = xzod.balanceOf(address(this));
        for (uint8 i = 0; i < NUM_SIGNS;) {
            zodBalances[i] = IERC20(zodTokens[i]).balanceOf(address(this));
            unchecked { ++i; }
        }
    }

    /// @notice Quote the xZOD cost for a given ZOD purchase amount
    function quoteBuy(uint256 totalZODAmount) external pure returns (uint256 xzodCost) {
        xzodCost = totalZODAmount / RATIO;
    }

    /// @notice Quote the xZOD received for a given ZOD sale amount
    function quoteSell(uint256 totalZODAmount) external pure returns (uint256 xzodOut) {
        xzodOut = totalZODAmount / RATIO;
    }
}
