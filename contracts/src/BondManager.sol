// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IBondManager} from "./interfaces/IBondManager.sol";

/// @title BondManager
/// @notice Curator and market-maker bonds (SPEC §13, D-011, D-030). A bond is locked by participation:
/// `AuctionHouse.bid` locks it on the bidder's first bid in a series and the AuctionHouse releases it at
/// clear (no fill) or once the series is SETTLED / RESOLVED (filled). Withdrawal needs zero active locks and
/// a 7-day cooldown. Slashing is timelock-only (`onlyOwner`), capped at the bond, proceeds to `treasury`.
/// @dev Post-token the required asset migrates USDG → WRITE with a grace period during which both satisfy
/// the requirement (D-007, SPEC §13). A holder keeps one independent leg per asset — balance, cooldown and
/// requirement are all per-asset, and no cross-asset arithmetic exists in this file, so BondManager imports
/// no oracle and the WRITE requirement is a fixed token amount re-pegged by governance (D-080). A price-
/// denominated requirement would make `hasActiveMMBond` — which `AuctionHouse.bid` calls with no try/catch —
/// depend on an oracle, so a cheap TWAP push could un-bond every competing MM at once.
/// Migration never strands a bond: during grace both legs qualify, so an MM posts the new asset alongside
/// the old one and never has a gap; after grace the de-accepted leg is withdrawable with no cooldown. The
/// `activeLocks` check is *not* waived — instead it gates qualification rather than a named asset, so a
/// locked MM may pull the leg that is not backing its live series but can never withdraw the collateral
/// standing behind one (D-082).
/// `usdg` stays `immutable` with the same getter: `AuctionHouse`'s constructor asserts it.
/// `auctionHouse` is set once after deployment (D-044).
contract BondManager is IBondManager, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants / immutables ─────────────────────────────

    uint64 public constant BOND_COOLDOWN = 7 days;
    /// @notice Upper bound on the dual-asset grace window; D-007's value is 30 days.
    uint64 public constant MAX_GRACE = 90 days;
    bytes32 internal constant KEY_REQUIRED_MM = "requiredAmountMM";
    bytes32 internal constant KEY_REQUIRED_CURATOR = "requiredAmountCurator";
    bytes32 internal constant KEY_REQUIRED_MM_WRITE = "requiredAmountMMWrite";
    bytes32 internal constant KEY_REQUIRED_CURATOR_WRITE = "requiredAmountCuratorWrite";
    IERC20 public immutable usdg;

    // ───────────────────────────── state ─────────────────────────────

    address public auctionHouse;
    address public treasury;
    /// @notice Set once when the token launches; until then only `BondAsset.USDG` is usable.
    address public writeToken;
    /// @notice The asset new bonds must be posted in. `USDG` until `startMigration`.
    BondAsset public bondAsset;
    /// @notice The asset that was required before the migration; still accepted while in grace.
    BondAsset public previousAsset;
    /// @notice End of the dual-asset grace window; 0 before a migration starts.
    uint64 public migrationEndsAt;

    mapping(BondAsset asset => mapping(BondKind kind => uint256)) public requiredAmountOf;
    mapping(address account => mapping(BondKind kind => mapping(BondAsset asset => uint256))) internal _amount;
    mapping(address account => mapping(BondKind kind => mapping(BondAsset asset => uint64))) internal _unlockAt;
    /// @notice Number of series in which `account` currently has a locked MM bond (SPEC §16.2, I-13). Gates
    /// the MM bond only; curator locks (one per live series of the curator's vault) arrive with VaultFactory.
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
    error AssetNotAccepted(BondAsset asset);
    error RequirementUnset(BondAsset asset, BondKind kind);
    error MigrationStarted();
    error MigrationNotStarted();
    error OutOfBounds();
    error Miswired(bytes32 what);
    error RenounceDisabled();

    // ───────────────────────────── events (SPEC §16.1) ─────────────────────────────

    event BondPosted(address indexed holder, BondKind kind, address asset, uint256 amount);
    event BondLocked(address indexed holder, uint256 indexed seriesId);
    event BondUnlocked(address indexed holder, uint256 indexed seriesId);
    event BondWithdrawRequested(address indexed holder, BondKind kind, address asset, uint64 unlockAt);
    event BondWithdrawCancelled(address indexed holder, BondKind kind, address asset);
    event BondWithdrawn(address indexed holder, BondKind kind, address asset, uint256 amount);
    event BondSlashed(address indexed holder, BondKind kind, address asset, uint256 amount, string evidenceURI);
    event AuctionHouseSet(address indexed auctionHouse);
    event WriteTokenSet(address indexed writeToken);
    event MigrationStartedAt(BondAsset from, BondAsset to, uint64 graceEndsAt);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address usdg_, address owner_, address treasury_) Ownable(owner_) {
        if (usdg_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdg = IERC20(usdg_);
        treasury = treasury_;
        requiredAmountOf[BondAsset.USDG][BondKind.CURATOR] = 10_000e6; // SPEC §13, D-011
        requiredAmountOf[BondAsset.USDG][BondKind.MM] = 25_000e6; // SPEC §13, founder decision
    }

    modifier onlyAuctionHouse() {
        if (msg.sender != auctionHouse || auctionHouse == address(0)) revert NotAuctionHouse();
        _;
    }

    // ═════════════════════════════ holders (SPEC §13) ═════════════════════════════

    /// @inheritdoc IBondManager
    /// @dev Posts in the currently required asset. Tops the leg up to its requirement, so a raised
    /// requirement never strands an existing holder.
    function postBond(BondKind kind) external returns (uint256 posted) {
        return postBondIn(kind, bondAsset);
    }

    /// @inheritdoc IBondManager
    function requestWithdraw(BondKind kind) external returns (uint64 unlockAt) {
        return requestWithdrawIn(kind, bondAsset);
    }

    /// @inheritdoc IBondManager
    function cancelWithdraw(BondKind kind) external {
        cancelWithdrawIn(kind, bondAsset);
    }

    /// @inheritdoc IBondManager
    function withdrawBond(BondKind kind) external returns (uint256 amount) {
        return withdrawBondIn(kind, bondAsset);
    }

    /// @inheritdoc IBondManager
    function postBondIn(BondKind kind, BondAsset asset) public nonReentrant returns (uint256 posted) {
        if (!assetAccepted(asset)) revert AssetNotAccepted(asset);
        if (_unlockAt[msg.sender][kind][asset] != 0) revert WithdrawalPending();
        uint256 required = requiredAmountOf[asset][kind];
        if (required == 0) revert RequirementUnset(asset, kind);
        uint256 current = _amount[msg.sender][kind][asset];
        if (current >= required) revert AlreadyBonded();

        posted = required - current;
        _amount[msg.sender][kind][asset] = required;
        address token = assetToken(asset);
        IERC20(token).safeTransferFrom(msg.sender, address(this), posted);
        emit BondPosted(msg.sender, kind, token, posted);
    }

    /// @inheritdoc IBondManager
    /// @dev The leg stops counting immediately (`isBonded` is false for it while a withdrawal is pending,
    /// SPEC §13) and is withdrawable after `BOND_COOLDOWN` if no lock is added meanwhile.
    function requestWithdrawIn(BondKind kind, BondAsset asset) public nonReentrant returns (uint64 unlockAt) {
        if (_amount[msg.sender][kind][asset] == 0) revert NoBond();
        if (_unlockAt[msg.sender][kind][asset] != 0) revert WithdrawalPending();
        _requireUnlockable(msg.sender, kind, asset);

        unlockAt = uint64(block.timestamp) + BOND_COOLDOWN;
        _unlockAt[msg.sender][kind][asset] = unlockAt;
        emit BondWithdrawRequested(msg.sender, kind, assetToken(asset), unlockAt);
    }

    /// @inheritdoc IBondManager
    function cancelWithdrawIn(BondKind kind, BondAsset asset) public nonReentrant {
        if (_unlockAt[msg.sender][kind][asset] == 0) revert NoWithdrawalPending();
        _unlockAt[msg.sender][kind][asset] = 0;
        emit BondWithdrawCancelled(msg.sender, kind, assetToken(asset));
    }

    /// @inheritdoc IBondManager
    /// @dev A leg in an asset the protocol no longer accepts skips the cooldown entirely (SPEC §13: "after
    /// grace, USDG bonds no longer count and become withdrawable immediately"). The lock check is never
    /// skipped, so migration cannot be used as a collateral escape hatch (D-082).
    function withdrawBondIn(BondKind kind, BondAsset asset) public nonReentrant returns (uint256 amount) {
        if (assetAccepted(asset)) {
            uint64 unlockAt = _unlockAt[msg.sender][kind][asset];
            if (unlockAt == 0) revert NoWithdrawalPending();
            if (block.timestamp < unlockAt) revert CooldownActive(unlockAt);
        }
        _requireUnlockable(msg.sender, kind, asset);

        amount = _amount[msg.sender][kind][asset];
        if (amount == 0) revert NoBond();
        _amount[msg.sender][kind][asset] = 0;
        _unlockAt[msg.sender][kind][asset] = 0;
        address token = assetToken(asset);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, kind, token, amount);
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

    /// @notice One-time wiring of the WRITE token, post-launch. Must precede any WRITE requirement.
    function setWriteToken(address write_) external onlyOwner {
        if (write_ == address(0)) revert ZeroAddress();
        if (writeToken != address(0)) revert AlreadySet();
        if (write_.code.length == 0) revert Miswired("WRITE_TOKEN");
        writeToken = write_;
        emit WriteTokenSet(write_);
    }

    /// @notice Slash part or all of one leg; grounds are off-chain and public in the timelock queue (§13).
    function slashBond(address holder, BondKind kind, uint256 amount, string calldata evidenceURI) external onlyOwner {
        slashBondIn(holder, kind, bondAsset, amount, evidenceURI);
    }

    /// @notice Slashes a named leg. There is no spillover between assets: the timelock proposal says which.
    function slashBondIn(address holder, BondKind kind, BondAsset asset, uint256 amount, string calldata evidenceURI)
        public
        onlyOwner
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        uint256 bond = _amount[holder][kind][asset];
        if (amount > bond) revert ExceedsBond(amount, bond);
        _amount[holder][kind][asset] = bond - amount;
        address token = assetToken(asset);
        IERC20(token).safeTransfer(treasury, amount);
        emit BondSlashed(holder, kind, token, amount, evidenceURI);
    }

    /// @notice Sets the requirement for the currently required asset.
    function setRequiredAmount(BondKind kind, uint256 amount) external onlyOwner {
        setRequiredAmountFor(bondAsset, kind, amount);
    }

    /// @notice Sets the requirement for a named asset. The WRITE requirement is a fixed token amount, and
    /// governance re-pegs it as the token's USD value drifts (D-080).
    function setRequiredAmountFor(BondAsset asset, BondKind kind, uint256 amount) public onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (asset == BondAsset.WRITE && writeToken == address(0)) revert Miswired("WRITE_TOKEN");
        bytes32 key;
        if (asset == BondAsset.USDG) {
            key = kind == BondKind.MM ? KEY_REQUIRED_MM : KEY_REQUIRED_CURATOR;
        } else {
            key = kind == BondKind.MM ? KEY_REQUIRED_MM_WRITE : KEY_REQUIRED_CURATOR_WRITE;
        }
        emit ParameterChanged(address(this), key, requiredAmountOf[asset][kind], amount);
        requiredAmountOf[asset][kind] = amount;
    }

    /// @notice Starts the one-way USDG → WRITE migration with a dual-asset grace window (D-007, D-081).
    /// Both requirements must already be set, so a half-configured migration cannot un-bond everyone.
    function startMigration(uint64 graceSeconds) external onlyOwner {
        if (migrationEndsAt != 0) revert MigrationStarted();
        if (writeToken == address(0)) revert Miswired("WRITE_TOKEN");
        if (graceSeconds == 0 || graceSeconds > MAX_GRACE) revert OutOfBounds();
        if (requiredAmountOf[BondAsset.WRITE][BondKind.CURATOR] == 0) {
            revert RequirementUnset(BondAsset.WRITE, BondKind.CURATOR);
        }
        if (requiredAmountOf[BondAsset.WRITE][BondKind.MM] == 0) {
            revert RequirementUnset(BondAsset.WRITE, BondKind.MM);
        }

        previousAsset = bondAsset;
        bondAsset = BondAsset.WRITE;
        migrationEndsAt = uint64(block.timestamp) + graceSeconds;
        emit MigrationStartedAt(previousAsset, BondAsset.WRITE, migrationEndsAt);
    }

    /// @notice Extends the grace window. Can only move later, never earlier.
    function extendGrace(uint64 newEndsAt) external onlyOwner {
        if (migrationEndsAt == 0) revert MigrationNotStarted();
        if (newEndsAt <= migrationEndsAt) revert OutOfBounds();
        if (newEndsAt > uint64(block.timestamp) + MAX_GRACE) revert OutOfBounds();
        emit ParameterChanged(address(this), "migrationEndsAt", migrationEndsAt, newEndsAt);
        migrationEndsAt = newEndsAt;
    }

    /// @dev Renouncing would freeze `slashBond`, `setRequiredAmount` and the migration forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit ParameterChanged(address(this), "treasury", uint256(uint160(treasury)), uint256(uint160(treasury_)));
        treasury = treasury_;
    }

    // ═════════════════════════════ views (SPEC §16.2) ═════════════════════════════

    /// @inheritdoc IBondManager
    /// @dev True while a full requirement is posted in some accepted asset and that leg has no pending
    /// withdrawal. A slashed leg below its requirement no longer qualifies until topped up.
    function isBonded(address account, BondKind kind) public view returns (bool) {
        return _qualifies(account, kind, BondAsset.USDG) || _qualifies(account, kind, BondAsset.WRITE);
    }

    /// @inheritdoc IBondManager
    /// @dev The MM specialisation of `isBonded`; `AuctionHouse.bid` reads this.
    function hasActiveMMBond(address account) external view returns (bool) {
        return isBonded(account, BondKind.MM);
    }

    /// @inheritdoc IBondManager
    function requiredAmount(BondKind kind) external view returns (uint256) {
        return requiredAmountOf[bondAsset][kind];
    }

    /// @inheritdoc IBondManager
    function assetToken(BondAsset asset) public view returns (address) {
        return asset == BondAsset.USDG ? address(usdg) : writeToken;
    }

    /// @inheritdoc IBondManager
    /// @dev The required asset always counts; the previous one also counts until the grace window closes.
    function assetAccepted(BondAsset asset) public view returns (bool) {
        if (asset == bondAsset) return true;
        return migrationEndsAt != 0 && block.timestamp < migrationEndsAt && asset == previousAsset;
    }

    /// @inheritdoc IBondManager
    /// @dev Reports the required asset's leg, falling back to the other one when only that is posted. Before
    /// a migration only one leg can ever be non-zero, so this is identical to the single-asset behaviour.
    function status(address account, BondKind kind)
        external
        view
        returns (uint256 amount, address asset, uint64 unlockAt)
    {
        BondAsset a = bondAsset;
        if (_amount[account][kind][a] == 0) {
            BondAsset other = a == BondAsset.USDG ? BondAsset.WRITE : BondAsset.USDG;
            if (_amount[account][kind][other] != 0) a = other;
        }
        return (_amount[account][kind][a], assetToken(a), _unlockAt[account][kind][a]);
    }

    /// @inheritdoc IBondManager
    function statusIn(address account, BondKind kind, BondAsset asset)
        external
        view
        returns (uint256 amount, address token, uint64 unlockAt)
    {
        return (_amount[account][kind][asset], assetToken(asset), _unlockAt[account][kind][asset]);
    }

    // ═════════════════════════════ internal ═════════════════════════════

    function _qualifies(address account, BondKind kind, BondAsset asset) internal view returns (bool) {
        if (!assetAccepted(asset)) return false;
        uint256 required = requiredAmountOf[asset][kind];
        if (required == 0) return false;
        return _amount[account][kind][asset] >= required && _unlockAt[account][kind][asset] == 0;
    }

    /// @dev The lock gates *qualification*, not a named asset (D-082): a locked MM may pull a leg only while
    /// some other accepted leg still keeps it bonded, so the collateral behind a live series can never leave.
    /// With a single asset this is exactly the old "no withdrawal while locked" rule.
    function _requireUnlockable(address account, BondKind kind, BondAsset asset) internal view {
        if (kind != BondKind.MM) return;
        uint256 locks = activeLocks[account];
        if (locks == 0) return;
        BondAsset other = asset == BondAsset.USDG ? BondAsset.WRITE : BondAsset.USDG;
        if (_qualifies(account, kind, other)) return;
        revert Locked(locks);
    }
}
