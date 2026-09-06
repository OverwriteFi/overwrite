import { parseAbi } from "viem";

/**
 * Human-readable ABIs for the slice of the protocol a market maker touches. Enums are uint8 on the wire:
 *   SeriesKind   0 WEEKDAY, 1 WEEKEND
 *   AuctionState 0 NONE, 1 OPEN, 2 CLEARED, 3 SKIPPED
 *   SeriesState  0 NONE, 1 AUCTION, 2 SKIPPED, 3 LIVE, 4 SETTLED, 5 HALTED, 6 RESOLVED
 *   BondKind     0 CURATOR, 1 MM
 * Full ABIs live in keeper/src/abi/generated.ts if you need more.
 */

export const auctionHouseAbi = parseAbi([
  "struct Auction { address vault; uint8 kind; uint8 state; uint64 auctionOpen; uint64 auctionClose; uint64 expiry; uint128 sRef; uint128 strike; uint128 offeredQty; uint128 reservePrice; uint128 clearingPrice; uint128 filledQty; uint128 premiumGross; uint128 fee; uint16 feeBps; }",
  "struct Bid { address bidder; uint128 qty; uint128 price; uint128 escrow; }",
  // writes
  "function bid(uint256 seriesId, uint256 qty, uint256 price) returns (uint256 bidId)",
  "function clear(uint256 seriesId) returns (uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, uint256 fee)",
  "function withdrawRefund(address to) returns (uint256 amount)",
  "function claimOptions(uint256 seriesId, address to) returns (uint256 qty)",
  "function claimPayout(uint256 seriesId, address to) returns (uint256 qty, uint256 tokens)",
  "function releaseLocks(uint256 seriesId)",
  // reads
  "function currentAuction(address vault) view returns (uint256)",
  "function auctions(uint256 seriesId) view returns (Auction)",
  "function bids(uint256 seriesId) view returns (Bid[])",
  "function bidders(uint256 seriesId) view returns (address[])",
  "function bidCount(uint256 seriesId, address bidder) view returns (uint256)",
  "function refundable(address account) view returns (uint256)",
  "function claimableOptions(uint256 seriesId, address account) view returns (uint256)",
  "function previewClear(uint256 seriesId) view returns (uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, bool willSkip)",
  "function minBidQty() view returns (uint256)",
  "function maxBidsPerBidder() view returns (uint256)",
  "function clearGrace() view returns (uint64)",
  "function referencePrice(address vault) view returns (uint256)",
  "function reserveBounds(address vault, uint8 kind, uint256 sRef) view returns (uint256 lo, uint256 hi)",
  "function computeStrike(uint256 sRef, uint16 strikeDistanceBps) pure returns (uint128)",
  "function isVault(address vault) view returns (bool)",
  // events
  "event AuctionOpened(address indexed vault, uint256 indexed seriesId, uint8 kind, uint64 auctionOpen, uint64 auctionClose, uint64 expiry, uint256 sRef, uint256 strike, uint256 offeredQty, uint256 reservePrice, uint256 multiplierAtOpen)",
  "event BidPlaced(uint256 indexed seriesId, address indexed bidder, uint256 bidId, uint256 qty, uint256 price, uint256 escrow)",
  "event AuctionCleared(uint256 indexed seriesId, uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, uint256 fee)",
  "event BidFilled(uint256 indexed seriesId, address indexed bidder, uint256 bidId, uint256 filledQty, uint256 refund)",
  "event AuctionSkipped(uint256 indexed seriesId)",
  "event OptionsClaimed(uint256 indexed seriesId, address indexed bidder, address indexed to, uint256 qty)",
  "event PayoutClaimed(uint256 indexed seriesId, address indexed bidder, address indexed to, uint256 qty, uint256 tokens)",
  "event LocksReleased(uint256 indexed seriesId)",
  // errors (so simulate failures decode)
  "error NoActiveBond(address bidder)",
  "error BidTooSmall(uint256 qty, uint256 minBidQty)",
  "error BelowReserve(uint256 price, uint256 reserve)",
  "error TooManyBids(uint256 max)",
  "error TooManyBidsPerBidder(uint256 max)",
  "error ZeroEscrow()",
  "error AuctionClosed()",
  "error AuctionNotClosed()",
  "error WrongAuctionState(uint8 state)",
  "error NothingToClaim()",
  "error InvalidRecipient()",
  "error SeriesNotSettled(uint8 state)",
]);

export const bondManagerAbi = parseAbi([
  "function postBond(uint8 kind) returns (uint256 posted)",
  "function requestWithdraw(uint8 kind) returns (uint64 unlockAt)",
  "function cancelWithdraw(uint8 kind)",
  "function withdrawBond(uint8 kind) returns (uint256 amount)",
  "function hasActiveMMBond(address account) view returns (bool)",
  "function isBonded(address account, uint8 kind) view returns (bool)",
  "function activeLocks(address account) view returns (uint256)",
  "function isLocked(address account, uint256 seriesId) view returns (bool)",
  "function requiredAmount(uint8 kind) view returns (uint256)",
  "function status(address account, uint8 kind) view returns (uint256 amount, address asset, uint64 unlockAt)",
  "function BOND_COOLDOWN() view returns (uint64)",
  "event BondPosted(address indexed holder, uint8 kind, address asset, uint256 amount)",
  "event BondLocked(address indexed holder, uint256 indexed seriesId)",
  "event BondUnlocked(address indexed holder, uint256 indexed seriesId)",
  "error AlreadyBonded()",
  "error NoBond()",
  "error WithdrawalPending()",
  "error NoWithdrawalPending()",
  "error Locked(uint256 activeLocks)",
  "error CooldownActive(uint64 unlockAt)",
]);

export const optionTokenAbi = parseAbi([
  "struct SeriesInfo { address vault; address underlying; uint8 kind; bool settled; uint64 expiry; uint128 strike; uint128 settlementPrice; uint128 payoutPerOption; uint256 multiplierAtCreation; }",
  "function claim(uint256 id, uint256 qty, address to) returns (uint256 tokens)",
  "function series(uint256 id) view returns (SeriesInfo)",
  "function balanceOf(address account, uint256 id) view returns (uint256)",
  "function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data)",
  "function setApprovalForAll(address operator, bool approved)",
  "error NotSettled(uint256 id)",
]);

export const vaultAbi = parseAbi([
  "struct VaultSeries { uint8 kind; uint8 state; uint8 settlementPath; uint64 expiry; uint128 strike; uint128 offeredQty; uint128 filledQty; uint128 mintedQty; uint128 claimedQty; uint128 settlementPrice; uint128 payoutPerOption; uint256 multiplierAtOpen; }",
  "function series(uint256 seriesId) view returns (VaultSeries)",
  "function state() view returns (uint8)",
  "function totalAssets() view returns (uint256)",
  "function payoutOwed() view returns (uint256)",
  "function asset() view returns (address)",
]);

export const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
  // testnet mock only
  "function mint(address to, uint256 amount)",
]);

export const feedAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);
