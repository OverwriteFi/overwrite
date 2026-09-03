// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IFeeRouter} from "./interfaces/IFeeRouter.sol";

/// @title FeeRouter
/// @notice Performance fee on premium (SPEC §11): `feeBps` per vault (default 10 %, bound [0, 20 %]), booked
/// by `collect` at clearing and forwarded to `treasury` by the permissionless `flush` (D-023). The WRITE mode
/// (D-011, D-016) is gated behind `writePool`, which stays `address(0)` until the token launches; every
/// WRITE entry point reverts `WriteNotLaunched` until then.
/// @dev `auctionHouse` is set once after deployment (D-044).
contract FeeRouter is IFeeRouter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants / immutables ─────────────────────────────

    uint16 public constant DEFAULT_FEE_BPS = 1000; // SPEC §11
    uint16 public constant MAX_FEE_BPS = 2000;
    uint256 public constant BPS = 1e4;
    IERC20 public immutable usdg;

    // ───────────────────────────── state ─────────────────────────────

    address public auctionHouse;
    address public treasury;
    /// @notice WRITE/USDG pool for the WRITE fee mode; placeholder `address(0)` until launch (D-016).
    address public writePool;

    mapping(address vault => uint16) internal _feeBps;
    mapping(address vault => bool) public initialised;
    mapping(address vault => uint256) public pending;
    mapping(address vault => FeeMode) internal _mode;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error NotAuctionHouse();
    error AlreadySet();
    error NotInitialised(address vault);
    error OutOfBounds();
    error NothingToFlush();
    error WriteNotLaunched();

    // ───────────────────────────── events (SPEC §16.1) ─────────────────────────────

    event FeeCollected(address indexed vault, uint256 indexed seriesId, uint256 usdg, FeeMode mode);
    event FeeFlushed(address indexed vault, address indexed treasury, uint256 usdg);
    event WriteModeFallback(address indexed vault);
    event VaultInitialised(address indexed vault, uint16 feeBps);
    event AuctionHouseSet(address indexed auctionHouse);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address usdg_, address owner_, address treasury_) Ownable(owner_) {
        if (usdg_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdg = IERC20(usdg_);
        treasury = treasury_;
    }

    modifier onlyAuctionHouse() {
        if (msg.sender != auctionHouse || auctionHouse == address(0)) revert NotAuctionHouse();
        _;
    }

    // ═════════════════════════════ AuctionHouse ═════════════════════════════

    /// @inheritdoc IFeeRouter
    /// @dev Called by `AuctionHouse.registerVault`. Sets the default fee once; `feeBps == 0` is a legal value,
    /// hence the explicit flag.
    function initVault(address vault) external onlyAuctionHouse {
        if (initialised[vault]) return;
        initialised[vault] = true;
        _feeBps[vault] = DEFAULT_FEE_BPS;
        emit VaultInitialised(vault, DEFAULT_FEE_BPS);
    }

    /// @inheritdoc IFeeRouter
    /// @dev Pure bookkeeping: the USDG was transferred in by the caller beforehand. Never reverts on accounting,
    /// so it can never block `clear` (D-023).
    function collect(address vault, uint256 seriesId, uint256 amount) external onlyAuctionHouse {
        pending[vault] += amount;
        emit FeeCollected(vault, seriesId, amount, _mode[vault]);
    }

    // ═════════════════════════════ permissionless ═════════════════════════════

    /// @inheritdoc IFeeRouter
    /// @dev USDG mode only until the token launches: forwards the pending balance to `treasury`. A frozen
    /// treasury makes only this call revert.
    function flush(address vault) external nonReentrant returns (uint256 amount) {
        amount = pending[vault];
        if (amount == 0) revert NothingToFlush();
        pending[vault] = 0;
        usdg.safeTransfer(treasury, amount);
        emit FeeFlushed(vault, treasury, amount);
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice One-time wiring (D-044). Reverts once set.
    function setAuctionHouse(address auctionHouse_) external onlyOwner {
        if (auctionHouse_ == address(0)) revert ZeroAddress();
        if (auctionHouse != address(0)) revert AlreadySet();
        auctionHouse = auctionHouse_;
        emit AuctionHouseSet(auctionHouse_);
    }

    function setFeeBps(address vault, uint16 bps) external onlyOwner {
        if (!initialised[vault]) revert NotInitialised(vault);
        if (bps > MAX_FEE_BPS) revert OutOfBounds();
        emit ParameterChanged(vault, "feeBps", _feeBps[vault], bps);
        _feeBps[vault] = bps;
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit ParameterChanged(address(this), "treasury", uint256(uint160(treasury)), uint256(uint160(treasury_)));
        treasury = treasury_;
    }

    /// @notice WRITE mode is unreachable until `writePool` is set post-launch (SPEC §11, D-016).
    function setFeeMode(address vault, FeeMode newMode) external onlyOwner {
        if (!initialised[vault]) revert NotInitialised(vault);
        if (newMode == FeeMode.WRITE && writePool == address(0)) revert WriteNotLaunched();
        emit ParameterChanged(vault, "feeMode", uint256(_mode[vault]), uint256(newMode));
        _mode[vault] = newMode;
    }

    // ═════════════════════════════ WRITE mode stubs (post-token) ═════════════════════════════

    function depositWrite(address, uint256) external pure {
        revert WriteNotLaunched();
    }

    function withdrawWrite(address, uint256) external pure {
        revert WriteNotLaunched();
    }

    // ═════════════════════════════ views (SPEC §16.2) ═════════════════════════════

    /// @inheritdoc IFeeRouter
    function feeBps(address vault) external view returns (uint16) {
        return _feeBps[vault];
    }

    /// @inheritdoc IFeeRouter
    function mode(address vault) external view returns (FeeMode) {
        return _mode[vault];
    }

    /// @inheritdoc IFeeRouter
    function writeBalance(address) external pure returns (uint256) {
        return 0;
    }
}
