// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IxZodNFTMarket
 * @notice Minimal interface to xZodNFT needed by the marketplace.
 */
interface IxZodNFTMarket {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function locked(address wallet, uint256 tokenId) external view returns (bool);
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

/**
 * @title IERC20Min
 * @notice Minimal ERC-20 interface for ZOD payment tokens.
 */
interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
}

/**
 * @title NFTMarketplace
 * @notice Peer-to-peer marketplace for xZOD NFTs.
 *
 * Payments in any of the 12 ZOD tokens (ZARI, ZTAU, ZGEM, ZCAN, ZLEO, ZVIR,
 * ZLIB, ZSCO, ZSAG, ZCAP, ZAQU, ZPIS). Seller chooses which ZOD to accept
 * at listing time. Buyer pays in that ZOD.
 *
 * Commission: 2.5% of sale price sent to treasury (owner wallet for MVP).
 * Use setTreasury() to redirect to a DAO contract later.
 *
 * Flow:
 *   1. Seller approves marketplace via xZodNFT.setApprovalForAll()
 *   2. Seller calls listNFT(tokenId, amount, priceZOD, zodToken)
 *   3. Buyer approves marketplace to spend the ZOD via ERC-20 approve()
 *   4. Buyer calls buyNFT(listingId) - atomic split:
 *        97.5% ZOD -> seller
 *        2.5%  ZOD -> treasury
 *        NFT       -> buyer
 *
 * xZodNFT (Sepolia): 0x5249D8eacbD47080642a7d89884CC3A1c0A110e3
 */
contract NFTMarketplace is Ownable, ReentrancyGuard {

    // --- External contracts --------------------------------------------------
    IxZodNFTMarket public nftContract;

    // --- Commission ----------------------------------------------------------
    /// @notice Protocol commission in basis points (250 = 2.5%)
    uint256 public commissionBp = 250;
    /// @notice Hard cap on commission - protects sellers
    uint256 public constant MAX_COMMISSION_BP = 500; // 5%
    /// @notice Receives protocol commissions (owner wallet for MVP)
    address public treasury;

    // --- ZOD whitelist -------------------------------------------------------
    /// @notice True if a token address is an accepted ZOD payment token
    mapping(address => bool) public isZodToken;
    /// @notice List of all whitelisted ZOD addresses (for frontend enumeration)
    address[] public zodTokenList;

    // --- Listing storage -----------------------------------------------------

    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 amount;
        uint256 priceZOD;   // total price in the specified ZOD token (18 decimals)
        address zodToken;   // which ZOD token is accepted as payment
        bool    active;
    }

    uint256 public nextListingId;
    mapping(uint256 => Listing) public listings;
    /// @notice seller => listing IDs (active + historical, filter by active flag)
    mapping(address => uint256[]) public sellerListings;

    // --- Events --------------------------------------------------------------
    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 priceZOD,
        address zodToken
    );
    event ListingUpdated(
        uint256 indexed listingId,
        uint256 oldPrice,
        uint256 newPrice,
        address zodToken
    );
    event Sale(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 tokenId,
        uint256 priceZOD,
        address zodToken,
        uint256 commission
    );
    event ListingCancelled(uint256 indexed listingId, address indexed seller);
    event ZodTokenAdded(address indexed token, string symbol);
    event ZodTokenRemoved(address indexed token);
    event CommissionUpdated(uint256 newCommissionBp);
    event TreasuryUpdated(address newTreasury);

    // --- Constructor ---------------------------------------------------------

    /**
     * @param nftAddress  Address of xZodNFT contract
     * @param zodTokens   Array of the 12 ZOD token addresses to whitelist at deploy
     */
    constructor(address nftAddress, address[] memory zodTokens) Ownable(msg.sender) {
        require(nftAddress != address(0), "Marketplace: zero nft address");
        nftContract = IxZodNFTMarket(nftAddress);
        treasury    = msg.sender;

        for (uint256 i = 0; i < zodTokens.length; i++) {
            require(zodTokens[i] != address(0), "Marketplace: zero token address");
            _addZodToken(zodTokens[i]);
        }
    }

    // --- ZOD whitelist management --------------------------------------------

    function _addZodToken(address token) internal {
        if (!isZodToken[token]) {
            isZodToken[token] = true;
            zodTokenList.push(token);
            emit ZodTokenAdded(token, IERC20Min(token).symbol());
        }
    }

    /// @notice Add a ZOD token to the accepted payment whitelist. Admin only.
    function addZodToken(address token) external onlyOwner {
        require(token != address(0), "Marketplace: zero address");
        _addZodToken(token);
    }

    /// @notice Remove a ZOD token from the whitelist. Existing listings unaffected.
    function removeZodToken(address token) external onlyOwner {
        require(isZodToken[token], "Marketplace: token not whitelisted");
        isZodToken[token] = false;
        emit ZodTokenRemoved(token);
    }

    /// @notice Returns the full list of whitelisted ZOD token addresses.
    function getZodTokenList() external view returns (address[] memory) {
        return zodTokenList;
    }

    // --- Listing -------------------------------------------------------------

    /**
     * @notice List an NFT for sale, specifying which ZOD token to accept.
     *
     * Requirements:
     *  - tokenId not locked (cannot list an active NFT)
     *  - Seller owns >= amount of tokenId
     *  - Marketplace approved via xZodNFT.setApprovalForAll()
     *  - zodToken must be in the whitelist
     *  - priceZOD > 0
     *
     * @param tokenId   xZodNFT token ID to sell
     * @param amount    Quantity (typically 1)
     * @param priceZOD  Total asking price in the specified ZOD (18 decimals)
     * @param zodToken  Address of the ZOD token accepted as payment
     */
    function listNFT(
        uint256 tokenId,
        uint256 amount,
        uint256 priceZOD,
        address zodToken
    ) external nonReentrant returns (uint256 listingId) {
        require(amount > 0,           "Marketplace: amount must be > 0");
        require(priceZOD > 0,         "Marketplace: price must be > 0");
        require(isZodToken[zodToken], "Marketplace: zodToken not accepted");
        require(
            nftContract.balanceOf(msg.sender, tokenId) >= amount,
            "Marketplace: insufficient NFT balance"
        );
        require(
            !nftContract.locked(msg.sender, tokenId),
            "Marketplace: NFT is locked - deactivate before listing"
        );
        require(
            nftContract.isApprovedForAll(msg.sender, address(this)),
            "Marketplace: call setApprovalForAll() on xZodNFT first"
        );

        listingId = nextListingId++;

        listings[listingId] = Listing({
            seller:   msg.sender,
            tokenId:  tokenId,
            amount:   amount,
            priceZOD: priceZOD,
            zodToken: zodToken,
            active:   true
        });

        sellerListings[msg.sender].push(listingId);

        emit Listed(listingId, msg.sender, tokenId, amount, priceZOD, zodToken);
    }

    /**
     * @notice Update price and/or accepted ZOD token for an active listing.
     * Only the original seller can update.
     *
     * @param listingId    The listing to update
     * @param newPrice     New price in ZOD (must be > 0)
     * @param newZodToken  New ZOD token to accept (must be whitelisted)
     */
    function updateListing(
        uint256 listingId,
        uint256 newPrice,
        address newZodToken
    ) external {
        Listing storage l = listings[listingId];
        require(l.active,                "Marketplace: listing not active");
        require(l.seller == msg.sender,  "Marketplace: not the seller");
        require(newPrice > 0,            "Marketplace: price must be > 0");
        require(isZodToken[newZodToken], "Marketplace: zodToken not accepted");

        uint256 oldPrice = l.priceZOD;
        l.priceZOD = newPrice;
        l.zodToken = newZodToken;

        emit ListingUpdated(listingId, oldPrice, newPrice, newZodToken);
    }

    /**
     * @notice Cancel an active listing. NFT stays in seller's wallet.
     * Callable by the seller or contract owner.
     */
    function cancelListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        require(l.active, "Marketplace: listing not active");
        require(
            l.seller == msg.sender || msg.sender == owner(),
            "Marketplace: not seller or owner"
        );

        l.active = false;
        emit ListingCancelled(listingId, l.seller);
    }

    // --- Purchase ------------------------------------------------------------

    /**
     * @notice Buy an NFT from an active listing.
     *
     * Buyer must have approved this contract to spend the listing's ZOD token
     * via ERC-20 approve() before calling this function.
     *
     * ZOD split (checks-effects-interactions pattern):
     *   price * 97.5% -> seller
     *   price * 2.5%  -> treasury
     * NFT transferred from seller to buyer atomically.
     *
     * @param listingId  The listing to purchase
     */
    function buyNFT(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active,               "Marketplace: listing not active");
        require(l.seller != msg.sender, "Marketplace: cannot buy your own listing");
        require(
            nftContract.balanceOf(l.seller, l.tokenId) >= l.amount,
            "Marketplace: seller no longer holds this NFT"
        );
        require(
            !nftContract.locked(l.seller, l.tokenId),
            "Marketplace: NFT is now locked - listing invalidated"
        );

        // Cache values before state change
        uint256 price      = l.priceZOD;
        uint256 commission = (price * commissionBp) / 10000;
        uint256 sellerNet  = price - commission;
        address seller     = l.seller;
        uint256 tokenId    = l.tokenId;
        uint256 amount     = l.amount;
        address zodToken   = l.zodToken;

        // Effects: mark inactive before external calls
        l.active = false;

        // Interactions: ZOD transfers then NFT transfer
        IERC20Min zod = IERC20Min(zodToken);
        require(
            zod.transferFrom(msg.sender, seller, sellerNet),
            "Marketplace: ZOD transfer to seller failed"
        );
        if (commission > 0) {
            require(
                zod.transferFrom(msg.sender, treasury, commission),
                "Marketplace: ZOD commission transfer failed"
            );
        }

        nftContract.safeTransferFrom(seller, msg.sender, tokenId, amount, "");

        emit Sale(listingId, msg.sender, seller, tokenId, price, zodToken, commission);
    }

    // --- View functions ------------------------------------------------------

    /**
     * @notice Returns listing details and a real-time validity flag.
     * valid = false if inactive, seller lost NFT, or NFT got locked since listing.
     */
    function getListing(uint256 listingId)
        external view
        returns (Listing memory listing, bool valid)
    {
        listing = listings[listingId];
        if (!listing.active) return (listing, false);
        bool holdsNFT  = nftContract.balanceOf(listing.seller, listing.tokenId) >= listing.amount;
        bool notLocked = !nftContract.locked(listing.seller, listing.tokenId);
        valid = holdsNFT && notLocked;
    }

    /// @notice Returns all listing IDs for a seller (filter by active flag on each).
    function getSellerListings(address seller)
        external view
        returns (uint256[] memory)
    {
        return sellerListings[seller];
    }

    /**
     * @notice Compute the ZOD split for a given price.
     * Use for frontend checkout display before calling buyNFT().
     */
    function computeSplit(uint256 priceZOD)
        external view
        returns (uint256 sellerReceives, uint256 protocolFee)
    {
        protocolFee    = (priceZOD * commissionBp) / 10000;
        sellerReceives = priceZOD - protocolFee;
    }

    // --- Admin ---------------------------------------------------------------

    /// @notice Update commission rate. Cannot exceed 5%.
    function setCommission(uint256 newCommissionBp) external onlyOwner {
        require(newCommissionBp <= MAX_COMMISSION_BP, "Marketplace: exceeds 5% max");
        commissionBp = newCommissionBp;
        emit CommissionUpdated(newCommissionBp);
    }

    /// @notice Redirect commissions to a new treasury address (e.g. DAO contract).
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Marketplace: zero address");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Update xZodNFT contract address.
    function setNFTContract(address newNFT) external onlyOwner {
        require(newNFT != address(0), "Marketplace: zero address");
        nftContract = IxZodNFTMarket(newNFT);
    }
}
