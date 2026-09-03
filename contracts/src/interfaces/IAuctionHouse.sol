// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SeriesKind} from "../Types.sol";

/// @notice Weekly uniform-price auctions of covered-call options (SPEC §5, §7.2, §8). One auction per series;
/// the vault allocates the seriesId. Refunds and option allocations are pull-based (D-023, D-024).
interface IAuctionHouse {
    enum AuctionState {
        NONE,
        OPEN,
        CLEARED,
        SKIPPED
    }

    /// @dev Auction-side series fields (SPEC §6 storage split). Prices are USDG (6 dec) per option (1e18 units).
    struct Auction {
        address vault;
        SeriesKind kind;
        AuctionState state;
        uint64 auctionOpen;
        uint64 auctionClose;
        uint64 expiry;
        uint128 sRef; // USD 8 dec, reference spot used for the strike (SPEC §7.2)
        uint128 strike; // USD 8 dec, PER_TOKEN
        uint128 offeredQty; // raw stock-token units, 1e18 = one option
        uint128 reservePrice; // USDG per option
        uint128 clearingPrice; // USDG per option, 0 until cleared
        uint128 filledQty;
        uint128 premiumGross; // Σ per-bid payments, floored (D-043)
        uint128 fee;
        uint16 feeBps; // snapshot of FeeRouter.feeBps(vault) at open (D-049)
    }

    struct Bid {
        address bidder;
        uint128 qty;
        uint128 price;
        uint128 escrow; // qty × price / 1e18, floored (T-09.2)
    }

    function openAuction(address vault, SeriesKind kind, uint64 expiry, uint16 strikeDistanceBps, uint128 reservePrice)
        external
        returns (uint256 seriesId);
    function bid(uint256 seriesId, uint256 qty, uint256 price) external returns (uint256 bidId);
    function clear(uint256 seriesId)
        external
        returns (uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, uint256 fee);
    function withdrawRefund(address to) external returns (uint256 amount);
    function claimOptions(uint256 seriesId, address to) external returns (uint256 qty);
    function claimPayout(uint256 seriesId, address to) external returns (uint256 qty, uint256 tokens);
    function releaseLocks(uint256 seriesId) external;

    function auctions(uint256 seriesId) external view returns (Auction memory);
    function bids(uint256 seriesId) external view returns (Bid[] memory);
    function bidders(uint256 seriesId) external view returns (address[] memory);
    function bidCount(uint256 seriesId, address bidder) external view returns (uint256);
    function refundable(address account) external view returns (uint256);
    function claimableOptions(uint256 seriesId, address account) external view returns (uint256);
    function previewClear(uint256 seriesId)
        external
        view
        returns (uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, bool willSkip);
    function canOpen(address vault, SeriesKind kind, uint64 expiry, uint64 at)
        external
        view
        returns (bool ok, bytes32 reason);
    function scheduledExpiry(SeriesKind kind, uint64 at) external pure returns (uint64);
}
