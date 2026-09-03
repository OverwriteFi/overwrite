// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IBondManager} from "./interfaces/IBondManager.sol";

/// @title BondManager
/// @notice Curator and market-maker bonds in USDG (SPEC §13, D-011, D-030). A bond is locked by participation:
/// `AuctionHouse.bid` locks it on the bidder's first bid in a series and the AuctionHouse releases it at clear
/// (no fill) or once the series is SETTLED / RESOLVED (filled). Withdrawal needs zero active locks and a
/// 7-day cooldown. Slashing is timelock-only (`onlyOwner`), capped at the bond, proceeds to `treasury`.
/// @dev `auctionHouse` is set once after deployment (D-044): the AuctionHouse holds this contract as an
/// immutable, so one side of the pair cannot be immutable. Out of scope until the token launches: WRITE
/// migration with the 30-day dual-asset grace (D-007), per-series curator locks (VaultFactory phase).
contract BondManager is IBondManager, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants / immutables ─────────────────────────────

    uint64 public constant BOND_COOLDOWN = 7 days;
    bytes32 internal constant KEY_REQUIRED_MM = "requiredAmountMM";
    bytes32 internal constant KEY_REQUIRED_CURATOR = "requiredAmountCurator";
    IERC20 public immutable usdg;

    // ───────────────────────────── state ─────────────────────────────

    address public auctionHouse;
    address public treasury;
    mapping(BondKind kind => uint256) public requiredAmount;

    mapping(address account => mapping(BondKind kind => uint256)) internal _bond;
    mapping(address account => mapping(BondKind kind => uint64)) internal _unlockAt;
    /// @notice Number of series in which `account` currently has a locked MM bond (SPEC §16.2, I-13). Gates the
    /// MM bond only; curator locks (one per live series of the curator's vault) arrive with VaultFactory (D-049).
    mapping(address account => uint256) public activeLocks;
    mapping(address account => mapping(uint256 seriesId => bool)) public isLocked;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error NotAuctionHouse();
    error AlreadySet();
    error AlreadyBonded();
    error NoBond();
    error WithdrawalPending();
    error NoWithdrawalPending();
    error Locked(uint256 activeLocks);
    error CooldownActive(uint64 unlockAt);
    error ExceedsBond(uint256 amount, uint256 bond);

    // ───────────────────────────── events (SPEC §16.1) ─────────────────────────────

    event BondPosted(address indexed holder, BondKind kind, address asset, uint256 amount);
    event BondLocked(address indexed holder, uint256 indexed seriesId);
    event BondUnlocked(address indexed holder, uint256 indexed seriesId);
    event BondWithdrawRequested(address indexed holder, BondKind kind, uint64 unlockAt);
    event BondWithdrawCancelled(address indexed holder, BondKind kind);
    event BondWithdrawn(address indexed holder, BondKind kind, uint256 amount);
    event BondSlashed(address indexed holder, BondKind kind, uint256 amount, string evidenceURI);
    event AuctionHouseSet(address indexed auctionHouse);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address usdg_, address owner_, address treasury_) Ownable(owner_) {
        if (usdg_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdg = IERC20(usdg_);
        treasury = treasury_;
        requiredAmount[BondKind.CURATOR] = 10_000e6; // SPEC §13, D-011
        requiredAmount[BondKind.MM] = 25_000e6; // SPEC §13, founder decision
    }

    modifier onlyAuctionHouse() {
        if (msg.sender != auctionHouse || auctionHouse == address(0)) revert NotAuctionHouse();
        _;
    }

    // ═════════════════════════════ holders (SPEC §13) ═════════════════════════════

    /// @inheritdoc IBondManager
    /// @dev Tops the bond up to `requiredAmount[kind]`, so a raised requirement never strands existing holders.
    function postBond(BondKind kind) external nonReentrant returns (uint256 posted) {
        if (_unlockAt[msg.sender][kind] != 0) revert WithdrawalPending();
        uint256 current = _bond[msg.sender][kind];
        uint256 required = requiredAmount[kind];
        if (current >= required) revert AlreadyBonded();
        posted = required - current;
        _bond[msg.sender][kind] = required;
        usdg.safeTransferFrom(msg.sender, address(this), posted);
        emit BondPosted(msg.sender, kind, address(usdg), posted);
    }

    /// @inheritdoc IBondManager
    /// @dev The bond stops counting as active immediately (`hasActiveMMBond` is false while a withdrawal is
    /// pending, SPEC §13) and is withdrawable after `BOND_COOLDOWN` if no lock is added meanwhile.
    function requestWithdraw(BondKind kind) external nonReentrant returns (uint64 unlockAt) {
        if (_bond[msg.sender][kind] == 0) revert NoBond();
        if (_unlockAt[msg.sender][kind] != 0) revert WithdrawalPending();
        if (kind == BondKind.MM && activeLocks[msg.sender] != 0) revert Locked(activeLocks[msg.sender]);
        unlockAt = uint64(block.timestamp) + BOND_COOLDOWN;
        _unlockAt[msg.sender][kind] = unlockAt;
        emit BondWithdrawRequested(msg.sender, kind, unlockAt);
    }

    /// @inheritdoc IBondManager
    function cancelWithdraw(BondKind kind) external nonReentrant {
        if (_unlockAt[msg.sender][kind] == 0) revert NoWithdrawalPending();
        _unlockAt[msg.sender][kind] = 0;
        emit BondWithdrawCancelled(msg.sender, kind);
    }

    /// @inheritdoc IBondManager
    function withdrawBond(BondKind kind) external nonReentrant returns (uint256 amount) {
        uint64 unlockAt = _unlockAt[msg.sender][kind];
        if (unlockAt == 0) revert NoWithdrawalPending();
        if (block.timestamp < unlockAt) revert CooldownActive(unlockAt);
        if (kind == BondKind.MM && activeLocks[msg.sender] != 0) revert Locked(activeLocks[msg.sender]);
        amount = _bond[msg.sender][kind];
        if (amount == 0) revert NoBond();
        _bond[msg.sender][kind] = 0;
        _unlockAt[msg.sender][kind] = 0;
        usdg.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, kind, amount);
    }

    // ═════════════════════════════ AuctionHouse (D-030) ═════════════════════════════

    /// @inheritdoc IBondManager
    /// @dev Idempotent: a second lock for the same series is a no-op.
    function lock(address holder, uint256 seriesId) external onlyAuctionHouse {
        if (isLocked[holder][seriesId]) return;
        isLocked[holder][seriesId] = true;
        activeLocks[holder] += 1;
        emit BondLocked(holder, seriesId);
    }

    /// @inheritdoc IBondManager
    /// @dev Idempotent: unlocking a series that is not locked is a no-op, so `releaseLocks` can be repeated.
    function unlock(address holder, uint256 seriesId) external onlyAuctionHouse {
        if (!isLocked[holder][seriesId]) return;
        isLocked[holder][seriesId] = false;
        activeLocks[holder] -= 1;
        emit BondUnlocked(holder, seriesId);
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice One-time wiring (D-044). Reverts once set.
    function setAuctionHouse(address auctionHouse_) external onlyOwner {
        if (auctionHouse_ == address(0)) revert ZeroAddress();
        if (auctionHouse != address(0)) revert AlreadySet();
        auctionHouse = auctionHouse_;
        emit AuctionHouseSet(auctionHouse_);
    }

    /// @notice Slash part or all of a bond; grounds are off-chain and public in the timelock queue (SPEC §13).
    function slashBond(address holder, BondKind kind, uint256 amount, string calldata evidenceURI)
        external
        onlyOwner
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        uint256 bond = _bond[holder][kind];
        if (amount > bond) revert ExceedsBond(amount, bond);
        _bond[holder][kind] = bond - amount;
        usdg.safeTransfer(treasury, amount);
        emit BondSlashed(holder, kind, amount, evidenceURI);
    }

    function setRequiredAmount(BondKind kind, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        bytes32 key = kind == BondKind.MM ? KEY_REQUIRED_MM : KEY_REQUIRED_CURATOR;
        emit ParameterChanged(address(this), key, requiredAmount[kind], amount);
        requiredAmount[kind] = amount;
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit ParameterChanged(address(this), "treasury", uint256(uint160(treasury)), uint256(uint160(treasury_)));
        treasury = treasury_;
    }

    // ═════════════════════════════ views (SPEC §16.2) ═════════════════════════════

    /// @inheritdoc IBondManager
    /// @dev True while the full required amount is posted and no withdrawal is pending (SPEC §13). A slashed
    /// bond below the requirement no longer qualifies until topped up.
    function hasActiveMMBond(address account) public view returns (bool) {
        return _bond[account][BondKind.MM] >= requiredAmount[BondKind.MM] && _unlockAt[account][BondKind.MM] == 0;
    }

    /// @inheritdoc IBondManager
    function status(address account, BondKind kind)
        external
        view
        returns (uint256 amount, address asset, uint64 unlockAt)
    {
        return (_bond[account][kind], address(usdg), _unlockAt[account][kind]);
    }
}
