// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IAuctionHouse} from "./interfaces/IAuctionHouse.sol";
import {IBondManager} from "./interfaces/IBondManager.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";
import {ICoveredCallVault} from "./interfaces/ICoveredCallVault.sol";
import {IOptionToken} from "./interfaces/IOptionToken.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {SeriesKind, SeriesState} from "./Types.sol";

/// @title AuctionHouse
/// @notice Weekly open-bid, uniform-price auctions of covered calls (SPEC §5, §7.2, §8). The keeper opens one
/// auction per series with a strike distance and a reserve; bonded market makers escrow USDG per bid; anyone
/// clears after 15 minutes. Clearing fills the highest bids first, pro-rata at the marginal price, and books
/// refunds (D-023) and option allocations (D-024) for pull. `clear` makes no outbound transfer to a bidder
/// and mints no ERC-1155, so no third party can block it. Premium net of the performance fee is pulled by
/// the vault (`mintSeries`); the fee is booked in `FeeRouter`.
/// @dev Deployment order: BondManager and FeeRouter first, then this contract (their `auctionHouse` is set
/// once, D-044), then the vaults, whose `auctionHouse` is immutable. `priceSource` is settable until
/// SettlementOracle ships (D-039, D-047): `sRef == S_cap` until then.
contract AuctionHouse is IAuctionHouse, Ownable2Step, AccessControl, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ───────────────────────────── constants ─────────────────────────────

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 1e4;
    /// @dev SPEC §5: 900 s. The 64-bid gas bound (§8.2) is measured against these two constants.
    uint64 public constant AUCTION_DURATION = 900;
    uint256 public constant MAX_BIDS = 64;
    uint64 public constant MAX_OPEN_TOLERANCE = 4 hours; // keeps both open windows inside one epoch week
    /// @dev Epoch-week offsets, seconds since Thursday 00:00 UTC (SPEC §5, D-046).
    uint64 public constant WEEK = 604_800;
    uint64 public constant MON_1400 = 396_000;
    uint64 public constant FRI_1930 = 156_600;
    uint64 public constant FRI_2000 = 158_400; // default weekday expiry under EDT; 21:00 UTC under EST
    uint64 public constant FRI_2130 = 163_800;
    uint64 public constant SUN_2359 = 345_540;
    uint64 public constant WEEKEND_GAP = 600; // SPEC §5 (d): weekend auction opens at weekdayExpiry + 600 s
    /// @dev Protocol bounds (SPEC §7.2, §8.3, D-027).
    uint16 public constant STRIKE_LO_WEEKDAY = 300;
    uint16 public constant STRIKE_HI_WEEKDAY = 1500;
    uint16 public constant STRIKE_LO_WEEKEND = 100;
    uint16 public constant STRIKE_HI_WEEKEND = 1000;
    uint16 public constant RESERVE_LO_BPS = 1;
    uint16 public constant RESERVE_HI_BPS = 500;
    uint16 public constant DEFAULT_RESERVE_WEEKDAY = 10;
    uint16 public constant DEFAULT_RESERVE_WEEKEND = 3;
    uint256 public constant GRID_BPS = 25; // strike grid = 0.25 % of S_ref (D-009)
    bytes32 internal constant KEY_MIN_STRIKE_WEEKDAY = "minStrikeDistanceWeekday";
    bytes32 internal constant KEY_MIN_STRIKE_WEEKEND = "minStrikeDistanceWeekend";
    bytes32 internal constant KEY_MIN_RESERVE_WEEKDAY = "minReserveWeekday";
    bytes32 internal constant KEY_MIN_RESERVE_WEEKEND = "minReserveWeekend";

    // ───────────────────────────── immutables ─────────────────────────────

    IERC20 public immutable usdg;
    IBondManager public immutable bondManager;
    IFeeRouter public immutable feeRouter;

    // ───────────────────────────── parameters (timelock) ─────────────────────────────

    IPriceSource public priceSource;
    uint64 public openTolerance = 7200; // SPEC §5 (a)
    uint256 public maxBidsPerBidder = 8; // SPEC §8.1
    uint256 public minBidQty = 1e17; // SPEC §8.1: 0.1 option

    // ───────────────────────────── per-vault config ─────────────────────────────

    mapping(address vault => bool) public isVault;
    mapping(address vault => IOptionToken) public optionTokenOf;
    mapping(address vault => mapping(SeriesKind kind => uint16)) public minStrikeDistanceBps;
    mapping(address vault => mapping(SeriesKind kind => uint16)) public minReserveBpsOfSpot;
    mapping(address vault => uint64) public lastWeekdayExpiry;
    mapping(address vault => uint256) public currentAuction;

    // ───────────────────────────── auctions ─────────────────────────────

    mapping(uint256 seriesId => Auction) internal _auctions;
    mapping(uint256 seriesId => Bid[]) internal _bids;
    mapping(uint256 seriesId => address[]) internal _bidders;
    mapping(uint256 seriesId => mapping(address bidder => uint256)) public bidCount;
    mapping(address account => uint256) public refundable;
    mapping(uint256 seriesId => mapping(address account => uint256)) public claimableOptions;
    /// @dev Set only around the self-mint inside `claimPayout`; any other ERC-1155 transfer to this contract reverts.
    bool private _expectingMint;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error NotRegistered(address vault);
    error AlreadyRegistered(address vault);
    error VaultNotWired(address vault);
    error CannotOpen(bytes32 reason);
    error DistanceOutOfBounds(uint16 bps, uint16 lo, uint16 hi);
    error NoReferencePrice();
    error GridZero();
    error ReserveOutOfBounds(uint256 reserve, uint256 lo, uint256 hi);
    error OfferTooSmall(uint256 offered, uint256 minBidQty);
    error WrongAuctionState(AuctionState state);
    error AuctionClosed();
    error AuctionNotClosed();
    error NoActiveBond(address bidder);
    error BidTooSmall(uint256 qty, uint256 minBidQty);
    error BelowReserve(uint256 price, uint256 reserve);
    error TooManyBids(uint256 max);
    error TooManyBidsPerBidder(uint256 max);
    error ZeroEscrow();
    error NothingToClaim();
    error InvalidRecipient();
    error SeriesNotSettled(SeriesState state);
    error UnexpectedTokens();
    error OutOfBounds();

    // ───────────────────────────── events (SPEC §16.1) ─────────────────────────────

    event VaultRegistered(address indexed vault, address indexed optionToken);
    event AuctionOpened(
        address indexed vault,
        uint256 indexed seriesId,
        SeriesKind kind,
        uint64 auctionOpen,
        uint64 auctionClose,
        uint64 expiry,
        uint256 sRef,
        uint256 strike,
        uint256 offeredQty,
        uint256 reservePrice,
        uint256 multiplierAtOpen
    );
    event BidPlaced(
        uint256 indexed seriesId, address indexed bidder, uint256 bidId, uint256 qty, uint256 price, uint256 escrow
    );
    event AuctionCleared(
        uint256 indexed seriesId, uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, uint256 fee
    );
    event BidFilled(uint256 indexed seriesId, address indexed bidder, uint256 bidId, uint256 filledQty, uint256 refund);
    event RefundCredited(uint256 indexed seriesId, address indexed bidder, uint256 usdg);
    event RefundWithdrawn(address indexed bidder, address indexed to, uint256 usdg);
    event OptionsAllocated(uint256 indexed seriesId, address indexed bidder, uint256 qty);
    event OptionsClaimed(uint256 indexed seriesId, address indexed bidder, address indexed to, uint256 qty);
    event PayoutClaimed(
        uint256 indexed seriesId, address indexed bidder, address indexed to, uint256 qty, uint256 tokens
    );
    event AuctionSkipped(uint256 indexed seriesId);
    event LocksReleased(uint256 indexed seriesId);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address usdg_, address bondManager_, address feeRouter_, address priceSource_, address owner_)
        Ownable(owner_)
    {
        if (usdg_ == address(0) || bondManager_ == address(0) || feeRouter_ == address(0) || priceSource_ == address(0))
        {
            revert ZeroAddress();
        }
        usdg = IERC20(usdg_);
        bondManager = IBondManager(bondManager_);
        feeRouter = IFeeRouter(feeRouter_);
        priceSource = IPriceSource(priceSource_);
    }

    // ═════════════════════════════ keeper: open (SPEC §5, §7.2, §8.3, D-028) ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    /// @dev `auctionOpen = block.timestamp`, validated against the §5 schedule (D-046). `S_ref` is read on-chain,
    /// never keeper-supplied; the strike is derived from it (§7.2) and the reserve is bounded by it (§8.3).
    /// The vault computes `offeredQty` and allocates the seriesId (D-009, D-038).
    function openAuction(address vault, SeriesKind kind, uint64 expiry, uint16 strikeDistanceBps, uint128 reservePrice)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 seriesId)
    {
        (uint256 sRef, uint128 strike) = _checkOpen(vault, kind, expiry, strikeDistanceBps, reservePrice);
        uint256 offered;
        (seriesId, offered) = ICoveredCallVault(vault).openSeries(kind, strike, expiry);
        if (offered < minBidQty) revert OfferTooSmall(offered, minBidQty);
        _record(seriesId, vault, kind, expiry, sRef, strike, offered, reservePrice);
    }

    /// @dev Schedule (§5), distance bounds (§7.2, D-027), on-chain `S_ref`, strike and reserve bounds (§8.3).
    function _checkOpen(address vault, SeriesKind kind, uint64 expiry, uint16 strikeDistanceBps, uint128 reservePrice)
        internal
        view
        returns (uint256 sRef, uint128 strike)
    {
        (bool ok, bytes32 reason) = canOpen(vault, kind, expiry, uint64(block.timestamp));
        if (!ok) revert CannotOpen(reason);
        (uint16 lo, uint16 hi) = strikeDistanceBounds(vault, kind);
        if (strikeDistanceBps < lo || strikeDistanceBps > hi) revert DistanceOutOfBounds(strikeDistanceBps, lo, hi);
        sRef = referencePrice(vault);
        strike = computeStrike(sRef, strikeDistanceBps);
        (uint256 rLo, uint256 rHi) = reserveBounds(vault, kind, sRef);
        if (reservePrice == 0 || reservePrice < rLo || reservePrice > rHi) {
            revert ReserveOutOfBounds(reservePrice, rLo, rHi);
        }
    }

    /// @dev Stores the auction fields (SPEC §6 split) and emits `AuctionOpened`.
    function _record(
        uint256 seriesId,
        address vault,
        SeriesKind kind,
        uint64 expiry,
        uint256 sRef,
        uint128 strike,
        uint256 offered,
        uint128 reservePrice
    ) internal {
        Auction storage a = _auctions[seriesId];
        a.vault = vault;
        a.kind = kind;
        a.state = AuctionState.OPEN;
        a.auctionOpen = uint64(block.timestamp);
        a.auctionClose = uint64(block.timestamp) + AUCTION_DURATION;
        a.expiry = expiry;
        a.sRef = sRef.toUint128();
        a.strike = strike;
        a.offeredQty = offered.toUint128();
        a.reservePrice = reservePrice;
        currentAuction[vault] = seriesId;
        if (kind == SeriesKind.WEEKDAY) lastWeekdayExpiry[vault] = expiry;
        _emitOpened(seriesId, a);
    }

    function _emitOpened(uint256 seriesId, Auction storage a) internal {
        uint256 multiplier = ICoveredCallVault(a.vault).series(seriesId).multiplierAtOpen;
        emit AuctionOpened(
            a.vault,
            seriesId,
            a.kind,
            a.auctionOpen,
            a.auctionClose,
            a.expiry,
            a.sRef,
            a.strike,
            a.offeredQty,
            a.reservePrice,
            multiplier
        );
    }

    // ═════════════════════════════ bidding (SPEC §8.1) ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    /// @dev Escrow `qty × price / 1e18` is pulled now; a bid that cannot fund itself is never stored (T-07.1).
    /// No amendment, no cancellation (founder decision). First bid of a bidder locks its bond (D-030).
    function bid(uint256 seriesId, uint256 qty, uint256 price) external nonReentrant returns (uint256 bidId) {
        Auction storage a = _auctions[seriesId];
        if (a.state != AuctionState.OPEN) revert WrongAuctionState(a.state);
        if (block.timestamp >= a.auctionClose) revert AuctionClosed();
        if (!bondManager.hasActiveMMBond(msg.sender)) revert NoActiveBond(msg.sender);
        if (qty < minBidQty) revert BidTooSmall(qty, minBidQty);
        if (price < a.reservePrice) revert BelowReserve(price, a.reservePrice);
        Bid[] storage bs = _bids[seriesId];
        if (bs.length >= MAX_BIDS) revert TooManyBids(MAX_BIDS);
        uint256 count = bidCount[seriesId][msg.sender];
        if (count >= maxBidsPerBidder) revert TooManyBidsPerBidder(maxBidsPerBidder);
        uint256 escrow = Math.mulDiv(qty, price, WAD);
        if (escrow == 0) revert ZeroEscrow();

        bidId = bs.length;
        bs.push(Bid({bidder: msg.sender, qty: qty.toUint128(), price: price.toUint128(), escrow: escrow.toUint128()}));
        bidCount[seriesId][msg.sender] = count + 1;
        if (count == 0) {
            _bidders[seriesId].push(msg.sender);
            bondManager.lock(msg.sender, seriesId);
        }
        usdg.safeTransferFrom(msg.sender, address(this), escrow);
        emit BidPlaced(seriesId, msg.sender, bidId, qty, price, escrow);
    }

    // ═════════════════════════════ clearing (SPEC §8.2, D-023, D-024, D-043, D-045) ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    /// @dev Permissionless at or after `auctionClose`. Skips (SPEC §8.2 step 8, D-045) when there is no bid,
    /// when the coverable quantity is zero, when `expiry` has already passed, or when the vault could not
    /// accrue the premium (every share escrowed). Otherwise fills per `_compute`, books refunds and allocations,
    /// forwards the fee, and lets the vault pull the net premium. `premiumGross` is the sum of the per-bid
    /// floored payments (D-043), so `Σ refund + premiumNet + fee == Σ escrow` to the unit.
    function clear(uint256 seriesId)
        external
        nonReentrant
        returns (uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, uint256 fee)
    {
        Auction storage a = _auctions[seriesId];
        if (a.state != AuctionState.OPEN) revert WrongAuctionState(a.state);
        if (block.timestamp < a.auctionClose) revert AuctionNotClosed();
        bool skip;
        (clearingPrice, filledQty, premiumGross, skip) = _settleBids(seriesId, a);
        if (skip) {
            _skip(seriesId, a);
            return (0, 0, 0, 0);
        }
        fee = _finalize(seriesId, a, clearingPrice, filledQty, premiumGross);
    }

    /// @dev Effects of `clear`: computes fills and books every bid's refund and allocation.
    function _settleBids(uint256 seriesId, Auction storage a)
        internal
        returns (uint256 cp, uint256 filled, uint256 gross, bool skip)
    {
        Bid[] storage bs = _bids[seriesId];
        uint256[] memory fills;
        (fills, cp, filled, gross, skip) = _compute(a, bs);
        if (skip) return (0, 0, 0, true);
        uint256 n = bs.length;
        for (uint256 i; i < n; ++i) {
            _creditBid(seriesId, bs[i], i, fills[i], cp);
        }
    }

    /// @dev `payment = floor(fill × cp / 1e18) ≤ escrow` because `cp ≤ price` (T-09.2); the rest is refundable.
    function _creditBid(uint256 seriesId, Bid storage b, uint256 bidId, uint256 fill, uint256 cp) internal {
        uint256 refund = b.escrow - Math.mulDiv(fill, cp, WAD);
        if (refund > 0) {
            refundable[b.bidder] += refund;
            emit RefundCredited(seriesId, b.bidder, refund);
        }
        if (fill > 0) {
            claimableOptions[seriesId][b.bidder] += fill;
            emit OptionsAllocated(seriesId, b.bidder, fill);
        }
        emit BidFilled(seriesId, b.bidder, bidId, fill, refund);
    }

    /// @dev State transition and interactions of `clear`: fee to the router (bookkeeping only), premium pulled by
    /// the vault in `mintSeries`, bonds of bidders without a fill released.
    function _finalize(uint256 seriesId, Auction storage a, uint256 cp, uint256 filled, uint256 gross)
        internal
        returns (uint256 fee)
    {
        fee = Math.mulDiv(gross, feeRouter.feeBps(a.vault), BPS);
        uint256 net = gross - fee;
        a.state = AuctionState.CLEARED;
        a.clearingPrice = cp.toUint128();
        a.filledQty = filled.toUint128();
        a.premiumGross = gross.toUint128();
        a.fee = fee.toUint128();
        emit AuctionCleared(seriesId, cp, filled, gross, fee);

        if (fee > 0) {
            usdg.safeTransfer(address(feeRouter), fee);
            feeRouter.collect(a.vault, seriesId, fee);
        }
        if (net > 0) usdg.forceApprove(a.vault, net);
        ICoveredCallVault(a.vault).mintSeries(seriesId, filled, net);
        address[] storage bidders_ = _bidders[seriesId];
        uint256 m = bidders_.length;
        for (uint256 i; i < m; ++i) {
            address bidder = bidders_[i];
            if (claimableOptions[seriesId][bidder] == 0) bondManager.unlock(bidder, seriesId);
        }
    }

    /// @dev SPEC §8.2 step 8: every escrow becomes refundable, every bond lock is released, vault → IDLE.
    function _skip(uint256 seriesId, Auction storage a) internal {
        a.state = AuctionState.SKIPPED;
        Bid[] storage bs = _bids[seriesId];
        uint256 n = bs.length;
        for (uint256 i; i < n; ++i) {
            Bid storage b = bs[i];
            refundable[b.bidder] += b.escrow;
            emit RefundCredited(seriesId, b.bidder, b.escrow);
            emit BidFilled(seriesId, b.bidder, i, 0, b.escrow);
        }
        emit AuctionSkipped(seriesId);
        ICoveredCallVault(a.vault).skipSeries(seriesId);
        address[] storage bidders_ = _bidders[seriesId];
        uint256 m = bidders_.length;
        for (uint256 i; i < m; ++i) {
            bondManager.unlock(bidders_[i], seriesId);
        }
    }

    /// @dev Uniform-price clearing (SPEC §8.2 steps 1-4, D-048). Sorts an index array by price desc / bidId asc,
    /// fills fully above the clearing price and pro-rata (floor) at it, assigning the rounding dust to the
    /// earliest bids in order, each capped at its own qty. `remaining = min(offeredQty, totalAssets())` so an
    /// issuer burn between open and clear cannot make `mintSeries` revert (D-040 mirror).
    /// @return fills per bidId
    /// @return cp clearing price (0 when skipping)
    /// @return filled Σ fills
    /// @return gross Σ floor(fill × cp / 1e18)
    /// @return skip true when the auction must take the skip path
    function _compute(Auction storage a, Bid[] storage bs)
        internal
        view
        returns (uint256[] memory fills, uint256 cp, uint256 filled, uint256 gross, bool skip)
    {
        uint256 n = bs.length;
        uint256 remaining = Math.min(a.offeredQty, IERC4626(a.vault).totalAssets());
        if (n == 0 || remaining == 0 || block.timestamp >= a.expiry) return (new uint256[](n), 0, 0, 0, true);

        (uint256[] memory qty, uint256[] memory price, uint256[] memory idx) = _loadSorted(bs);
        cp = _clearingPrice(qty, price, idx, remaining);
        (fills, filled) = _allocate(qty, price, idx, remaining, cp);
        for (uint256 i; i < n; ++i) {
            gross += Math.mulDiv(fills[i], cp, WAD);
        }
        // D-045: the vault cannot accrue premium when every share is escrowed for redeem (NoSharesForPremium)
        if (gross > 0 && IERC20(a.vault).totalSupply() == IERC20(a.vault).balanceOf(a.vault)) skip = true;
    }

    /// @dev Loads the bids into memory and insertion-sorts an index array: price desc, bidId asc (ties favour
    /// the earlier bid). ≤ 64 entries (SPEC §8.2 step 1).
    function _loadSorted(Bid[] storage bs)
        internal
        view
        returns (uint256[] memory qty, uint256[] memory price, uint256[] memory idx)
    {
        uint256 n = bs.length;
        qty = new uint256[](n);
        price = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            qty[i] = bs[i].qty;
            price[i] = bs[i].price;
        }
        idx = _sortIdx(price);
    }

    /// @dev Insertion sort of an index array over `price`: descending, ties by index ascending.
    function _sortIdx(uint256[] memory price) internal pure returns (uint256[] memory idx) {
        uint256 n = price.length;
        idx = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            idx[i] = i;
        }
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = idx[i];
            uint256 j = i;
            while (j > 0 && (price[key] > price[idx[j - 1]] || (price[key] == price[idx[j - 1]] && key < idx[j - 1]))) {
                idx[j] = idx[j - 1];
                --j;
            }
            idx[j] = key;
        }
    }

    /// @dev SPEC §8.2 steps 2-3: walk the sorted list; the clearing price is the price of the last bid that
    /// receives any fill (a single bid clears at its own price).
    function _clearingPrice(uint256[] memory qty, uint256[] memory price, uint256[] memory idx, uint256 remaining)
        internal
        pure
        returns (uint256 cp)
    {
        uint256 rem = remaining;
        for (uint256 k; k < idx.length && rem > 0; ++k) {
            uint256 b = idx[k];
            rem -= Math.min(qty[b], rem);
            cp = price[b];
        }
    }

    /// @dev Full fills strictly above `cp`; the marginal group at `cp` is filled fully if it fits, else pro-rata.
    function _allocate(
        uint256[] memory qty,
        uint256[] memory price,
        uint256[] memory idx,
        uint256 remaining,
        uint256 cp
    ) internal pure returns (uint256[] memory fills, uint256 filled) {
        (uint256 s, uint256 e) = _marginalRange(price, idx, cp);
        fills = new uint256[](idx.length);
        uint256 remM = remaining - _fillRange(qty, idx, fills, 0, s); // > 0: the first bid at cp got a fill
        uint256 total = _sumRange(qty, idx, s, e);
        if (total <= remM) {
            _fillRange(qty, idx, fills, s, e);
            filled = remaining - remM + total;
        } else {
            _proRata(qty, idx, fills, s, e, remM, total);
            filled = remaining;
        }
    }

    /// @dev Sorted positions [s, e) of the bids priced exactly at `cp`; contiguous and in bidId order.
    function _marginalRange(uint256[] memory price, uint256[] memory idx, uint256 cp)
        internal
        pure
        returns (uint256 s, uint256 e)
    {
        uint256 n = idx.length;
        for (; s < n && price[idx[s]] > cp; ++s) {}
        e = s;
        for (; e < n && price[idx[e]] == cp; ++e) {}
    }

    function _fillRange(uint256[] memory qty, uint256[] memory idx, uint256[] memory fills, uint256 from, uint256 to)
        internal
        pure
        returns (uint256 sum)
    {
        for (uint256 t = from; t < to; ++t) {
            fills[idx[t]] = qty[idx[t]];
            sum += qty[idx[t]];
        }
    }

    function _sumRange(uint256[] memory qty, uint256[] memory idx, uint256 from, uint256 to)
        internal
        pure
        returns (uint256 sum)
    {
        for (uint256 t = from; t < to; ++t) {
            sum += qty[idx[t]];
        }
    }

    /// @dev SPEC §8.2 step 4 / D-048: floor pro-rata by qty, then the rounding dust goes to the earliest bids in
    /// bidId order, each capped at its own qty. `dust < (e − s) ≤ Σ headroom`, so the carry always ends inside
    /// the group and Σ fills == remM exactly.
    function _proRata(
        uint256[] memory qty,
        uint256[] memory idx,
        uint256[] memory fills,
        uint256 s,
        uint256 e,
        uint256 remM,
        uint256 total
    ) internal pure {
        uint256 sum;
        for (uint256 t = s; t < e; ++t) {
            uint256 f = Math.mulDiv(qty[idx[t]], remM, total);
            fills[idx[t]] = f;
            sum += f;
        }
        uint256 dust = remM - sum;
        for (uint256 t = s; t < e && dust > 0; ++t) {
            uint256 add = Math.min(dust, qty[idx[t]] - fills[idx[t]]);
            fills[idx[t]] += add;
            dust -= add;
        }
    }

    // ═════════════════════════════ pull: refunds, options, payout (D-023, D-024, D-038) ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    function withdrawRefund(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = refundable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        refundable[msg.sender] = 0;
        usdg.safeTransfer(to, amount);
        emit RefundWithdrawn(msg.sender, to, amount);
    }

    /// @inheritdoc IAuctionHouse
    /// @dev Mints the bidder's allocation through the vault (only minter, D-038). Callable while the series is
    /// LIVE, HALTED, SETTLED or RESOLVED.
    function claimOptions(uint256 seriesId, address to) external nonReentrant returns (uint256 qty) {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        qty = claimableOptions[seriesId][msg.sender];
        if (qty == 0) revert NothingToClaim();
        claimableOptions[seriesId][msg.sender] = 0;
        ICoveredCallVault(_auctions[seriesId].vault).mintOptions(seriesId, to, qty);
        emit OptionsClaimed(seriesId, msg.sender, to, qty);
    }

    /// @inheritdoc IAuctionHouse
    /// @dev SPEC §8.2 step 6 / D-038: an unclaimed allocation is still an option. Mints to this contract and
    /// claims the settlement payout for `to` in one transaction. Reverts until the series is settled.
    function claimPayout(uint256 seriesId, address to) external nonReentrant returns (uint256 qty, uint256 tokens) {
        if (to == address(0)) revert ZeroAddress();
        qty = claimableOptions[seriesId][msg.sender];
        if (qty == 0) revert NothingToClaim();
        claimableOptions[seriesId][msg.sender] = 0;
        address vault = _auctions[seriesId].vault;
        _expectingMint = true;
        ICoveredCallVault(vault).mintOptions(seriesId, address(this), qty);
        _expectingMint = false;
        tokens = optionTokenOf[vault].claim(seriesId, qty, to);
        emit PayoutClaimed(seriesId, msg.sender, to, qty, tokens);
    }

    /// @inheritdoc IAuctionHouse
    /// @dev Permissionless and idempotent: releases every remaining bond lock of a cleared series once the vault
    /// reports it SETTLED or RESOLVED (SPEC §8.1, §13, D-030). Iterates the stored bidder list (≤ 64).
    function releaseLocks(uint256 seriesId) external nonReentrant {
        Auction storage a = _auctions[seriesId];
        if (a.state != AuctionState.CLEARED) revert WrongAuctionState(a.state);
        SeriesState st = ICoveredCallVault(a.vault).series(seriesId).state;
        if (st != SeriesState.SETTLED && st != SeriesState.RESOLVED) revert SeriesNotSettled(st);
        address[] storage bidders_ = _bidders[seriesId];
        uint256 m = bidders_.length;
        for (uint256 i; i < m; ++i) {
            bondManager.unlock(bidders_[i], seriesId);
        }
        emit LocksReleased(seriesId);
    }

    /// @dev Only the self-mint inside `claimPayout` may deposit option tokens here; anything else reverts so
    /// options can never be stranded in the AuctionHouse.
    function onERC1155Received(address, address from, uint256 id, uint256, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        if (!_expectingMint || from != address(0) || msg.sender != address(optionTokenOf[_auctions[id].vault])) {
            revert UnexpectedTokens();
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        revert UnexpectedTokens();
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice Register a vault whose immutable `auctionHouse` is this contract; sets the curator floors to the
    /// protocol defaults (D-027) and initialises its fee in the router.
    function registerVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        if (isVault[vault]) revert AlreadyRegistered(vault);
        if (ICoveredCallVault(vault).auctionHouse() != address(this)) revert VaultNotWired(vault);
        IOptionToken optionToken = ICoveredCallVault(vault).optionToken();
        if (address(optionToken) == address(0)) revert ZeroAddress();
        isVault[vault] = true;
        optionTokenOf[vault] = optionToken;
        minStrikeDistanceBps[vault][SeriesKind.WEEKDAY] = STRIKE_LO_WEEKDAY;
        minStrikeDistanceBps[vault][SeriesKind.WEEKEND] = STRIKE_LO_WEEKEND;
        minReserveBpsOfSpot[vault][SeriesKind.WEEKDAY] = DEFAULT_RESERVE_WEEKDAY;
        minReserveBpsOfSpot[vault][SeriesKind.WEEKEND] = DEFAULT_RESERVE_WEEKEND;
        feeRouter.initVault(vault);
        emit VaultRegistered(vault, address(optionToken));
    }

    /// @notice Curator floor on the strike distance, within the protocol bounds (SPEC §7.2, D-027).
    function setMinStrikeDistanceBps(address vault, SeriesKind kind, uint16 bps) external onlyOwner {
        if (!isVault[vault]) revert NotRegistered(vault);
        (uint16 lo, uint16 hi) = _protocolStrikeBounds(kind);
        if (bps < lo || bps > hi) revert OutOfBounds();
        bytes32 key = kind == SeriesKind.WEEKDAY ? KEY_MIN_STRIKE_WEEKDAY : KEY_MIN_STRIKE_WEEKEND;
        emit ParameterChanged(vault, key, minStrikeDistanceBps[vault][kind], bps);
        minStrikeDistanceBps[vault][kind] = bps;
    }

    /// @notice Curator floor on the reserve as bps of spot, within [1, 500] (SPEC §8.3, D-027). Never zero.
    function setMinReserveBpsOfSpot(address vault, SeriesKind kind, uint16 bps) external onlyOwner {
        if (!isVault[vault]) revert NotRegistered(vault);
        if (bps < RESERVE_LO_BPS || bps > RESERVE_HI_BPS) revert OutOfBounds();
        bytes32 key = kind == SeriesKind.WEEKDAY ? KEY_MIN_RESERVE_WEEKDAY : KEY_MIN_RESERVE_WEEKEND;
        emit ParameterChanged(vault, key, minReserveBpsOfSpot[vault][kind], bps);
        minReserveBpsOfSpot[vault][kind] = bps;
    }

    function setOpenTolerance(uint64 seconds_) external onlyOwner {
        if (seconds_ > MAX_OPEN_TOLERANCE) revert OutOfBounds();
        emit ParameterChanged(address(this), "openTolerance", openTolerance, seconds_);
        openTolerance = seconds_;
    }

    function setMaxBidsPerBidder(uint256 n) external onlyOwner {
        if (n == 0 || n > MAX_BIDS) revert OutOfBounds();
        emit ParameterChanged(address(this), "maxBidsPerBidder", maxBidsPerBidder, n);
        maxBidsPerBidder = n;
    }

    function setMinBidQty(uint256 qty) external onlyOwner {
        if (qty == 0) revert OutOfBounds();
        emit ParameterChanged(address(this), "minBidQty", minBidQty, qty);
        minBidQty = qty;
    }

    /// @notice Temporary until SettlementOracle implements `IPriceSource` (D-039, D-047).
    function setPriceSource(address source) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        emit ParameterChanged(
            address(this), "priceSource", uint256(uint160(address(priceSource))), uint256(uint160(source))
        );
        priceSource = IPriceSource(source);
    }

    /// @notice Grant or revoke `KEEPER_ROLE` (D-028). No account holds `DEFAULT_ADMIN_ROLE`; the owner is the admin.
    function setKeeper(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (enabled) _grantRole(KEEPER_ROLE, account);
        else _revokeRole(KEEPER_ROLE, account);
    }

    // ═════════════════════════════ views (SPEC §16.2) ═════════════════════════════

    /// @inheritdoc IAuctionHouse
    /// @dev Adds the §5 schedule checks on top of `vault.canOpenAuction` (D-046). Epoch weeks start Thursday
    /// 00:00 UTC, so a Friday and the following Sunday share a week while Monday's Friday is in the next one.
    function canOpen(address vault, SeriesKind kind, uint64 expiry, uint64 at)
        public
        view
        returns (bool ok, bytes32 reason)
    {
        if (!isVault[vault]) return (false, "NOT_REGISTERED");
        uint64 off = at % WEEK;
        uint64 ws = at - off;
        if (kind == SeriesKind.WEEKDAY) {
            uint64 diff = off > MON_1400 ? off - MON_1400 : MON_1400 - off;
            if (diff > openTolerance) return (false, "OPEN_WINDOW");
            uint64 fri = ws + WEEK;
            if (expiry < fri + FRI_1930 || expiry > fri + FRI_2130) return (false, "EXPIRY");
        } else {
            if (off < FRI_1930 + WEEKEND_GAP || off > FRI_2130 + WEEKEND_GAP + openTolerance) {
                return (false, "OPEN_WINDOW");
            }
            if (expiry != ws + SUN_2359) return (false, "EXPIRY");
            uint64 last = lastWeekdayExpiry[vault];
            if (last >= ws && at < last + WEEKEND_GAP) return (false, "WEEKDAY_GAP");
        }
        return ICoveredCallVault(vault).canOpenAuction(expiry);
    }

    /// @inheritdoc IAuctionHouse
    /// @dev WEEKDAY: the Friday 20:00 UTC (EDT close) of the week after `at`; the keeper substitutes 21:00 UTC
    /// under EST, still inside [19:30, 21:30]. WEEKEND: Sunday 23:59:00 UTC of the week of `at`.
    function scheduledExpiry(SeriesKind kind, uint64 at) public pure returns (uint64) {
        uint64 ws = at - (at % WEEK);
        return kind == SeriesKind.WEEKDAY ? ws + WEEK + FRI_2000 : ws + SUN_2359;
    }

    /// @inheritdoc IAuctionHouse
    /// @dev Mirrors `clear`: `willSkip` is true when `clear` would take the skip path right now. For a cleared
    /// auction returns the stored result.
    function previewClear(uint256 seriesId)
        external
        view
        returns (uint256 clearingPrice, uint256 filledQty, uint256 premiumGross, bool willSkip)
    {
        Auction storage a = _auctions[seriesId];
        if (a.state == AuctionState.CLEARED) return (a.clearingPrice, a.filledQty, a.premiumGross, false);
        if (a.state != AuctionState.OPEN) return (0, 0, 0, true);
        (, uint256 cp, uint256 filled, uint256 gross, bool skip) = _compute(a, _bids[seriesId]);
        if (skip) return (0, 0, 0, true);
        return (cp, filled, gross, false);
    }

    /// @notice Effective strike-distance bounds: max(protocol floor, curator floor) .. protocol ceiling.
    function strikeDistanceBounds(address vault, SeriesKind kind) public view returns (uint16 lo, uint16 hi) {
        (lo, hi) = _protocolStrikeBounds(kind);
        uint16 floor = minStrikeDistanceBps[vault][kind];
        if (floor > lo) lo = floor;
    }

    /// @notice Reserve bounds in USDG per option for a given `sRef` (8-dec USD): [sRef × floorBps / 1e4, sRef]
    /// converted 8 → 6 decimals (SPEC §8.3).
    function reserveBounds(address vault, SeriesKind kind, uint256 sRef) public view returns (uint256 lo, uint256 hi) {
        lo = Math.mulDiv(sRef, minReserveBpsOfSpot[vault][kind], 1e6);
        hi = sRef / 1e2;
    }

    /// @notice `S_ref` read on-chain (SPEC §7.2; `S_cap` until SettlementOracle ships, D-047).
    function referencePrice(address vault) public view returns (uint256 sRef) {
        bool ok;
        (sRef, ok) = priceSource.capPrice(vault);
        if (!ok || sRef == 0) revert NoReferencePrice();
    }

    /// @notice Strike on the relative 0.25 % grid, rounded up (SPEC §7.2, D-009): at most one grid step above
    /// the requested distance. Reverts `GridZero` for an `sRef` below 400 (T-09.4).
    function computeStrike(uint256 sRef, uint16 strikeDistanceBps) public pure returns (uint128) {
        uint256 grid = sRef * GRID_BPS / BPS;
        if (grid == 0) revert GridZero();
        uint256 kRaw = sRef * (BPS + strikeDistanceBps) / BPS;
        return (Math.ceilDiv(kRaw, grid) * grid).toUint128();
    }

    /// @inheritdoc IAuctionHouse
    function auctions(uint256 seriesId) external view returns (Auction memory) {
        return _auctions[seriesId];
    }

    /// @inheritdoc IAuctionHouse
    function bids(uint256 seriesId) external view returns (Bid[] memory) {
        return _bids[seriesId];
    }

    /// @inheritdoc IAuctionHouse
    function bidders(uint256 seriesId) external view returns (address[] memory) {
        return _bidders[seriesId];
    }

    function _protocolStrikeBounds(SeriesKind kind) internal pure returns (uint16 lo, uint16 hi) {
        return
            kind == SeriesKind.WEEKDAY ? (STRIKE_LO_WEEKDAY, STRIKE_HI_WEEKDAY) : (STRIKE_LO_WEEKEND, STRIKE_HI_WEEKEND);
    }

    function supportsInterface(bytes4 id) public view override(AccessControl, ERC1155Holder) returns (bool) {
        return AccessControl.supportsInterface(id) || ERC1155Holder.supportsInterface(id);
    }
}
