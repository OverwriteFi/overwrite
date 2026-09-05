// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";
import {IWritePriceOracle} from "./interfaces/IWritePriceOracle.sol";

/// @dev The one getter `setAuctionHouse` needs; kept local so this file imports no AuctionHouse code.
interface IAuctionHouseFeeWiring {
    function feeRouter() external view returns (address);
}

/// @title FeeRouter
/// @notice Performance fee on premium (SPEC §11): `feeBps` per vault (default 10 %, bound [0, 20 %]), booked
/// by `collect` at clearing and settled by the permissionless `flush` (D-023). In USDG mode the fee goes to
/// `treasury`. In WRITE mode (D-011) the router instead debits the curator's prefunded WRITE at a 20 %
/// discount, burns half of it, sends the rest to `treasury`, and rebates the USDG fee to the curator.
/// There is no distribution to token holders anywhere in this contract (CLAUDE.md rule 7).
/// @dev `collect` is pure bookkeeping and is deliberately left byte-for-byte as it was: the entire WRITE path
/// runs inside `flush` (D-085), so `AuctionHouse.clear` — which is permissionless and must never brick —
/// cannot be affected by an oracle, a burn or a transfer. A debit at collect time, even inside a try/catch,
/// would expose `clear` to a gas-bomb oracle via EIP-150's 63/64 rule.
/// Every WRITE-path failure degrades to the USDG path and emits `WriteModeFallback` with a reason, so "why
/// did WRITE mode not fire" is answerable from chain data alone.
/// `writePool` was removed (D-084, superseding D-016): a pool address this contract never reads was dead
/// state and a second, unverifiable place to point at a pool. The launch gate is now `writeToken` plus
/// `priceOracle`. `auctionHouse` is set once after deployment (D-044).
contract FeeRouter is IFeeRouter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants / immutables ─────────────────────────────

    uint16 public constant DEFAULT_FEE_BPS = 1000; // SPEC §11
    uint16 public constant MAX_FEE_BPS = 2000;
    uint16 public constant MAX_DISCOUNT_BPS = 5000;
    uint16 public constant MAX_BURN_SHARE_BPS = 10_000;
    uint256 public constant BPS = 1e4;
    IERC20 public immutable usdg;

    // ───────────────────────────── state ─────────────────────────────

    address public auctionHouse;
    address public treasury;
    /// @notice Set once post-launch; while zero the WRITE mode is unreachable (the D-016 intent).
    address public writeToken;
    /// @notice Re-settable, like `SafetyModule.oracle` (D-039 precedent).
    address public priceOracle;
    uint16 public writeDiscountBps = 2000; // D-011: 20 % discount
    uint16 public writeBurnShareBps = 5000; // D-011: 50 % of the WRITE fee is burned

    mapping(address vault => uint16) internal _feeBps;
    mapping(address vault => bool) public initialised;
    mapping(address vault => uint256) public pending;
    mapping(address vault => FeeMode) internal _mode;
    mapping(address vault => address) public curatorOf;
    mapping(address vault => uint256) internal _writeBalance;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error NotAuctionHouse();
    error NotCurator();
    error AlreadySet();
    error NotInitialised(address vault);
    error OutOfBounds();
    error NothingToFlush();
    error WriteNotLaunched();
    error InsufficientWriteBalance(uint256 have, uint256 want);
    error Miswired(bytes32 what);
    error WriteBalanceReserved(uint256 needed, uint256 remaining);
    error RenounceDisabled();

    // ───────────────────────────── events (SPEC §16.1) ─────────────────────────────

    event FeeCollected(address indexed vault, uint256 indexed seriesId, uint256 usdg, FeeMode mode);
    event FeeFlushed(address indexed vault, address indexed to, uint256 usdg);
    /// @dev `price8` is what makes flush-time pricing auditable on-chain (D-089).
    event WriteFeePaid(
        address indexed vault,
        address indexed curator,
        uint256 feeUSDG,
        uint256 writeAmount,
        uint256 burned,
        uint256 price8
    );
    event WriteModeFallback(address indexed vault, bytes32 reason);
    event WriteDeposited(address indexed vault, address indexed from, uint256 amount);
    event WriteWithdrawn(address indexed vault, address indexed to, uint256 amount);
    event VaultInitialised(address indexed vault, uint16 feeBps);
    event AuctionHouseSet(address indexed auctionHouse);
    event WriteTokenSet(address indexed writeToken);
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
    /// @dev Pure bookkeeping: the USDG stays in the AuctionHouse, which holds a standing approval for this
    /// contract; `flush` pulls it. No transfer happens here, so nothing fee-side can revert `clear` (D-023,
    /// D-049, D-085) — this is why the WRITE path lives in `flush` and not here.
    function collect(address vault, uint256 seriesId, uint256 amount) external onlyAuctionHouse {
        pending[vault] += amount;
        emit FeeCollected(vault, seriesId, amount, _mode[vault]);
    }

    // ═════════════════════════════ permissionless ═════════════════════════════

    /// @inheritdoc IFeeRouter
    /// @dev USDG mode: pulls the pending balance from the AuctionHouse straight to `treasury`. WRITE mode:
    /// debits the curator's prefunded WRITE, burns the burn share, sends the rest to `treasury`, and rebates
    /// the USDG to the curator. Any WRITE-path failure falls back to the USDG path.
    function flush(address vault) external nonReentrant returns (uint256 amount) {
        amount = pending[vault];
        if (amount == 0) revert NothingToFlush();
        pending[vault] = 0;

        if (_mode[vault] == FeeMode.WRITE) {
            (bool paid, bytes32 reason) = _tryWritePath(vault, amount);
            if (paid) {
                address curator = curatorOf[vault];
                usdg.safeTransferFrom(auctionHouse, curator, amount);
                emit FeeFlushed(vault, curator, amount);
                return amount;
            }
            emit WriteModeFallback(vault, reason);
        }

        usdg.safeTransferFrom(auctionHouse, treasury, amount);
        emit FeeFlushed(vault, treasury, amount);
    }

    // ═════════════════════════════ curator (SPEC §11) ═════════════════════════════

    /// @inheritdoc IFeeRouter
    /// @dev Permissionless top-up: anyone may fund a vault's WRITE balance, only its curator may take it out.
    function depositWrite(address vault, uint256 amount) external nonReentrant {
        address token = writeToken;
        if (token == address(0)) revert WriteNotLaunched();
        if (!initialised[vault]) revert NotInitialised(vault);
        // Without a curator there is no withdrawal path at all, so the deposit would be unrecoverable.
        if (curatorOf[vault] == address(0)) revert NotCurator();
        if (amount == 0) revert ZeroAmount();
        _writeBalance[vault] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit WriteDeposited(vault, msg.sender, amount);
    }

    /// @inheritdoc IFeeRouter
    /// @dev Withdrawals are allowed at any time, with no lock (SPEC §11). The launch check comes first so the
    /// pre-launch revert reason stays `WriteNotLaunched` rather than `NotCurator` (D-089).
    function withdrawWrite(address vault, uint256 amount) external nonReentrant {
        address token = writeToken;
        if (token == address(0)) revert WriteNotLaunched();
        if (msg.sender != curatorOf[vault]) revert NotCurator();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = _writeBalance[vault];
        if (amount > bal) revert InsufficientWriteBalance(bal, amount);
        uint256 remaining = bal - amount;
        // A fee that is already booked must stay covered. `flush` is permissionless and priced at call time,
        // so without this a curator could watch the price and pull the prefunded WRITE moments before a flush
        // would have debited it, taking the discount only when it suits them (D-098). If the oracle cannot
        // price the fee the reservation is skipped -- the flush would fall back to USDG anyway.
        if (_mode[vault] == FeeMode.WRITE) {
            uint256 booked = pending[vault];
            if (booked != 0) {
                (uint256 needed, bool ok) = previewWriteFee(booked);
                if (ok && remaining < needed) revert WriteBalanceReserved(needed, remaining);
            }
        }
        _writeBalance[vault] = remaining;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit WriteWithdrawn(vault, msg.sender, amount);
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice One-time wiring (D-044). Reverts once set.
    function setAuctionHouse(address auctionHouse_) external onlyOwner {
        if (auctionHouse_ == address(0)) revert ZeroAddress();
        if (auctionHouse != address(0)) revert AlreadySet();
        if (IAuctionHouseFeeWiring(auctionHouse_).feeRouter() != address(this)) revert Miswired("AUCTION_HOUSE"); // C-3
        auctionHouse = auctionHouse_;
        emit AuctionHouseSet(auctionHouse_);
    }

    /// @notice One-time wiring of WRITE, post-launch. Until this lands, WRITE mode is unreachable (D-016).
    function setWriteToken(address write_) external onlyOwner {
        if (write_ == address(0)) revert ZeroAddress();
        if (writeToken != address(0)) revert AlreadySet();
        if (write_.code.length == 0) revert Miswired("WRITE_TOKEN");
        writeToken = write_;
        emit WriteTokenSet(write_);
    }

    /// @notice Points at the shared WRITE price oracle. Asserts it quotes the token this router debits.
    function setPriceOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        if (writeToken == address(0)) revert WriteNotLaunched();
        if (IWritePriceOracle(oracle).writeToken() != writeToken) revert Miswired("ORACLE_WRITE");
        emit ParameterChanged(address(this), "priceOracle", uint256(uint160(priceOracle)), uint256(uint160(oracle)));
        priceOracle = oracle;
    }

    /// @notice The vault's curator: the account that funds and withdraws WRITE and receives the USDG rebate.
    function setCurator(address vault, address curator) external onlyOwner {
        if (!initialised[vault]) revert NotInitialised(vault);
        if (curator == address(0)) revert ZeroAddress();
        emit ParameterChanged(vault, "curator", uint256(uint160(curatorOf[vault])), uint256(uint160(curator)));
        curatorOf[vault] = curator;
    }

    /// @dev Renouncing would freeze the fee mode, the curator wiring and every prefunded WRITE balance.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
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

    /// @dev Global, not per-vault (D-087): a per-vault discount of 100 % would be a silent fee waiver.
    function setWriteDiscountBps(uint16 bps) external onlyOwner {
        if (bps > MAX_DISCOUNT_BPS) revert OutOfBounds();
        emit ParameterChanged(address(this), "writeDiscountBps", writeDiscountBps, bps);
        writeDiscountBps = bps;
    }

    function setWriteBurnShareBps(uint16 bps) external onlyOwner {
        if (bps > MAX_BURN_SHARE_BPS) revert OutOfBounds();
        emit ParameterChanged(address(this), "writeBurnShareBps", writeBurnShareBps, bps);
        writeBurnShareBps = bps;
    }

    /// @notice WRITE mode is unreachable until the token and its oracle are wired (SPEC §11, D-016, D-084).
    function setFeeMode(address vault, FeeMode newMode) external onlyOwner {
        if (!initialised[vault]) revert NotInitialised(vault);
        if (newMode == FeeMode.WRITE && (writeToken == address(0) || priceOracle == address(0))) {
            revert WriteNotLaunched();
        }
        emit ParameterChanged(vault, "feeMode", uint256(_mode[vault]), uint256(newMode));
        _mode[vault] = newMode;
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
    function writeBalance(address vault) external view returns (uint256) {
        return _writeBalance[vault];
    }

    /// @notice WRITE the curator would owe for a `feeUSD6` fee right now, and whether the path is available.
    function previewWriteFee(uint256 feeUSD6) public view returns (uint256 writeAmount, bool ok) {
        uint256 price8;
        (price8, ok) = _quote();
        if (!ok || price8 == 0) return (0, false);
        writeAmount = _writeAmount(feeUSD6, price8);
    }

    // ═════════════════════════════ internal ═════════════════════════════

    /// @dev Never reverts: every failure is a reason code, so `flush` degrades to the USDG path instead of
    /// stranding the fee.
    function _tryWritePath(address vault, uint256 feeUSD6) internal returns (bool paid, bytes32 reason) {
        address token = writeToken;
        if (token == address(0)) return (false, "WRITE_UNSET");
        address curator = curatorOf[vault];
        if (curator == address(0)) return (false, "CURATOR_UNSET");

        (uint256 price8, bool ok) = _quote();
        if (!ok || price8 == 0) return (false, "NO_PRICE");

        uint256 writeAmount = _writeAmount(feeUSD6, price8);
        if (writeAmount == 0) return (false, "ZERO_WRITE");

        uint256 bal = _writeBalance[vault];
        if (writeAmount > bal) return (false, "INSUFFICIENT_WRITE");
        _writeBalance[vault] = bal - writeAmount;

        uint256 burned = Math.mulDiv(writeAmount, writeBurnShareBps, BPS);
        if (burned != 0) IERC20Burnable(token).burn(burned);
        uint256 toTreasury = writeAmount - burned;
        if (toTreasury != 0) IERC20(token).safeTransfer(treasury, toTreasury);

        emit WriteFeePaid(vault, curator, feeUSD6, writeAmount, burned, price8);
        return (true, "OK");
    }

    /// @dev 6-dec USDG fee → discounted USD → 18-dec WRITE at an 8-dec price: 6 + 20 − 8 = 18. Both legs
    /// round up (D-088), so a curator can never underpay by a rounding unit on a repeated clearing.
    function _writeAmount(uint256 feeUSD6, uint256 price8) internal view returns (uint256) {
        uint256 discounted6 = Math.mulDiv(feeUSD6, BPS - writeDiscountBps, BPS, Math.Rounding.Ceil);
        return Math.mulDiv(discounted6, 1e20, price8, Math.Rounding.Ceil);
    }

    function _quote() internal view returns (uint256 price8, bool ok) {
        address o = priceOracle;
        if (o == address(0)) return (0, false);
        try IWritePriceOracle(o).writePrice() returns (uint256 p, bool available) {
            return (p, available);
        } catch {
            return (0, false);
        }
    }
}
