// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IStockToken} from "./interfaces/IStockToken.sol";
import {IOptionToken} from "./interfaces/IOptionToken.sol";
import {IRiskModule} from "./interfaces/IRiskModule.sol";
import {ICapController} from "./interfaces/ICapController.sol";
import {ICoveredCallVault} from "./interfaces/ICoveredCallVault.sol";
import {SeriesKind, SeriesState, VaultState} from "./Types.sol";

/// @title CoveredCallVault
/// @notice ERC-4626 vault over one Robinhood stock token that writes physically-collateralised covered
/// calls (SPEC §4, §5, §7, §9.7). Premium is a per-share USDG accumulator outside NAV (D-004). Direct
/// deposits and withdrawals only in IDLE; queues otherwise (D-006, D-032). `settleSeries` performs no
/// ERC-20 transfer (THREAT-MODEL T-11); option payouts are pulled through `OptionToken.claim`.
/// All cross-contract references are immutable; no proxy (D-034). Ownership (the timelock) is two-step.
contract CoveredCallVault is ERC4626, ReentrancyGuard, Ownable2Step, ICoveredCallVault {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ───────────────────────────── constants ─────────────────────────────

    uint256 public constant WAD = 1e18;
    /// @dev Premium accumulator precision. SPEC §4.2 writes 1e18; shares have 24 decimals (offset 6), so
    /// 1e18 would truncate up to 1 USDG per token-worth of shares. 1e36 bounds the loss to 1e-12 USDG.
    uint256 public constant ACC_PRECISION = 1e36;
    /// @dev Upper bound for queue ops per settle/open. Gas-measured in `test_T07_settleGasAtMaxQueueOps`:
    /// 100 redeems + 100 deposits inside one `settleSeries` stay well under the Arbitrum 32 M per-tx limit.
    uint256 public constant MAX_QUEUE_OPS = 100;
    uint8 internal constant DECIMALS_OFFSET = 6; // SPEC §4.1, THREAT-MODEL T-06

    // ───────────────────────────── immutables ─────────────────────────────

    IStockToken public immutable stock;
    IERC20 public immutable usdg;
    IOptionToken public immutable optionToken;
    address public immutable auctionHouse;
    address public immutable settlement;
    IRiskModule public immutable riskModule;
    ICapController public immutable capController;

    // ───────────────────────────── types ─────────────────────────────

    enum RequestStatus {
        NONE,
        QUEUED,
        EXECUTED,
        CANCELLED,
        EXPIRED
    }

    struct DepositRequest {
        address requester;
        address receiver;
        uint128 assets;
        RequestStatus status;
    }

    struct RedeemRequest {
        address requester;
        address receiver;
        uint128 shares;
        RequestStatus status;
    }

    // ───────────────────────────── state ─────────────────────────────

    VaultState public state;
    bool public sunset;
    uint256 public currentSeriesId;
    mapping(uint256 seriesId => VaultSeries) internal _series;

    /// @notice Stock tokens owed to option holders of settled series, not yet claimed (SPEC §4.1).
    uint256 public payoutOwed;
    /// @notice Stock tokens set aside for executed queued redeems, not yet claimed.
    uint256 public withdrawalClaimableTotal;
    /// @notice Stock tokens transferred in by queued depositors, not yet the vault's.
    uint256 public queuedDepositTokens;
    /// @notice filledQty of the LIVE / HALTED series; 0 when IDLE (SPEC I-1, brief I1/I3).
    uint256 public encumbered;
    /// @notice Shares escrowed in this contract by `requestRedeem` (D-036).
    uint256 public escrowedRedeemShares;
    /// @notice Cumulative payout shortfall recorded at settlement (SPEC §9.7 step 5).
    uint256 public totalShortfall;

    mapping(address account => uint256) public withdrawalClaimable;

    uint256 public accPremiumPerShare; // USDG × ACC_PRECISION / share
    mapping(address account => uint256) public premiumDebt;
    mapping(address account => uint256) internal _premiumClaimable;

    uint256 public maxQueueOpsPerOpen = 50;
    uint256 public maxQueueOpsPerSettle = 50;

    DepositRequest[] internal _depositQueue;
    uint256 public depositQueueHead;
    RedeemRequest[] internal _redeemQueue;
    uint256 public redeemQueueHead;

    /// @dev Set only while `requestRedeem` moves shares into escrow; every other transfer to the vault reverts.
    bool private _escrowing;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error NotAuctionHouse();
    error NotSettlement();
    error NotOptionToken();
    error VaultNotIdle();
    error VaultIsIdle();
    error VaultSunsetted();
    error DepositsPaused();
    error CapPriceUnavailable();
    error WithdrawalsClosed();
    error CannotOpen(bytes32 reason);
    error ZeroStrike();
    error NothingToOffer();
    error WrongSeries(uint256 seriesId);
    error WrongSeriesState(SeriesState state);
    error ExceedsOffered(uint256 qty, uint256 offered);
    error InsufficientCoverage(uint256 qty, uint256 available);
    error CannotTransferToVault();
    error ExceedsFilled(uint256 qty, uint256 remaining);
    error NoSharesForPremium();
    error InvalidPath(uint8 path);
    error ZeroPrice();
    error NotRequester();
    error BadRequestStatus(RequestStatus status);
    error NothingToClaim();
    error OutOfBounds();

    // ───────────────────────────── events (SPEC §16.1) ─────────────────────────────

    event DepositQueued(address indexed receiver, uint256 indexed requestId, uint256 assets);
    event DepositQueueCancelled(uint256 indexed requestId);
    event DepositRequestExpired(uint256 indexed requestId);
    event DepositExecuted(uint256 indexed requestId, uint256 shares, uint256 sharePrice);
    event RedeemQueued(address indexed owner, uint256 indexed requestId, uint256 shares);
    event RedeemQueueCancelled(uint256 indexed requestId);
    event RedeemExecuted(uint256 indexed requestId, uint256 assets);
    event WithdrawalClaimed(address indexed owner, address indexed to, uint256 assets);
    event PremiumAccrued(uint256 indexed seriesId, uint256 premiumNet, uint256 accPremiumPerShare);
    event PremiumClaimed(address indexed account, address indexed to, uint256 usdg);
    event VaultStateChanged(VaultState from, VaultState to);
    event VaultSunset();
    event ShortfallRecorded(uint256 indexed seriesId, uint256 tokensShort);
    event SeriesOpened(
        uint256 indexed seriesId,
        SeriesKind kind,
        uint128 strike,
        uint64 expiry,
        uint256 offeredQty,
        uint256 multiplierAtOpen
    );
    event SeriesCleared(uint256 indexed seriesId, uint256 filledQty, uint256 premiumNet);
    event SeriesSkipped(uint256 indexed seriesId);
    event SeriesHalted(uint256 indexed seriesId, bytes32 reason);
    event SeriesSettled(
        uint256 indexed seriesId,
        uint128 settlementPrice,
        uint8 settlementPath,
        uint256 payoutPerOption,
        uint256 payoutTotal
    );
    event OptionsMinted(uint256 indexed seriesId, address indexed to, uint256 qty);
    event OptionPaid(uint256 indexed seriesId, address indexed to, uint256 qty, uint256 tokens);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    struct Config {
        address stock;
        address usdg;
        address optionToken;
        address auctionHouse;
        address settlement;
        address riskModule;
        address capController;
        address owner;
        string name;
        string symbol;
    }

    constructor(Config memory c) ERC4626(IERC20(c.stock)) ERC20(c.name, c.symbol) Ownable(c.owner) {
        if (
            c.stock == address(0) || c.usdg == address(0) || c.optionToken == address(0) || c.auctionHouse == address(0)
                || c.settlement == address(0) || c.riskModule == address(0) || c.capController == address(0)
        ) revert ZeroAddress();
        stock = IStockToken(c.stock);
        usdg = IERC20(c.usdg);
        optionToken = IOptionToken(c.optionToken);
        auctionHouse = c.auctionHouse;
        settlement = c.settlement;
        riskModule = IRiskModule(c.riskModule);
        capController = ICapController(c.capController);
    }

    // ───────────────────────────── modifiers ─────────────────────────────

    modifier onlyAuctionHouse() {
        if (msg.sender != auctionHouse) revert NotAuctionHouse();
        _;
    }

    modifier onlySettlement() {
        if (msg.sender != settlement) revert NotSettlement();
        _;
    }

    modifier onlyOptionToken() {
        if (msg.sender != address(optionToken)) revert NotOptionToken();
        _;
    }

    // ═════════════════════════════ ERC-4626 (SPEC §4.1) ═════════════════════════════

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @inheritdoc ERC4626
    /// @dev Saturates at 0 so views never revert if the issuer burns vault tokens (SPEC §2, §9.7 step 5).
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 owed = payoutOwed + withdrawalClaimableTotal + queuedDepositTokens;
        return bal > owed ? bal - owed : 0;
    }

    /// @notice Assets backing shares escrowed for queued redeems; excluded from `offeredQty` (D-009).
    function pendingRedeemAssets() public view returns (uint256) {
        return _convertToAssets(escrowedRedeemShares, Math.Rounding.Floor);
    }

    /// @notice Unencumbered assets: totalAssets − encumbered − pendingRedeemAssets, saturating.
    function freeAssets() public view returns (uint256) {
        uint256 ta = totalAssets();
        uint256 locked = encumbered + pendingRedeemAssets();
        return ta > locked ? ta - locked : 0;
    }

    function _depositsOpen() internal view returns (bool) {
        return state == VaultState.IDLE && !sunset && !riskModule.depositsPaused(address(this));
    }

    /// @dev Cap headroom in raw stock units. A reverting cap controller / price source reads as "no price"
    /// (ok = false): ERC-4626 `max*` views must not revert and settlement must not depend on an oracle (D-041).
    function _capHeadroom() internal view returns (uint256 remaining, bool ok) {
        try capController.remainingDepositAssets(address(this), totalAssets()) returns (uint256 rem, bool ok_) {
            return (rem, ok_);
        } catch {
            return (0, false);
        }
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (!_depositsOpen()) return 0;
        (uint256 assets, bool ok) = _capHeadroom();
        return ok ? assets : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return state == VaultState.IDLE ? super.maxWithdraw(owner) : 0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return state == VaultState.IDLE ? super.maxRedeem(owner) : 0;
    }

    /// @dev Typed reasons before OZ's generic ExceededMax error.
    function _checkDepositOpen() internal view {
        if (state != VaultState.IDLE) revert VaultNotIdle();
        if (sunset) revert VaultSunsetted();
        if (riskModule.depositsPaused(address(this))) revert DepositsPaused();
        (, bool ok) = _capHeadroom();
        if (!ok) revert CapPriceUnavailable();
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _checkDepositOpen();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _checkDepositOpen();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        if (state != VaultState.IDLE) revert WithdrawalsClosed();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        if (state != VaultState.IDLE) revert WithdrawalsClosed();
        return super.redeem(shares, receiver, owner);
    }

    // ═════════════════════════════ premium accumulator (SPEC §4.2, D-004) ═════════════════════════════

    /// @dev Settles premium for both parties on every mint/burn/transfer. The vault's own escrow balance
    /// is skipped: escrowed redeem shares earn nothing and are excluded from the denominator (D-036).
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this) && !_escrowing) revert CannotTransferToVault(); // shares sent here would be stranded
        bool trackFrom = from != address(0) && from != address(this);
        bool trackTo = to != address(0) && to != address(this);
        if (trackFrom) _settlePremium(from);
        if (trackTo) _settlePremium(to);
        super._update(from, to, value);
        if (trackFrom) premiumDebt[from] = Math.mulDiv(balanceOf(from), accPremiumPerShare, ACC_PRECISION);
        if (trackTo) premiumDebt[to] = Math.mulDiv(balanceOf(to), accPremiumPerShare, ACC_PRECISION);
    }

    function _settlePremium(address account) internal {
        uint256 owed = Math.mulDiv(balanceOf(account), accPremiumPerShare, ACC_PRECISION);
        _premiumClaimable[account] += owed - premiumDebt[account];
        premiumDebt[account] = owed;
    }

    function _accruePremium(uint256 seriesId, uint256 premiumNet) internal {
        uint256 eligible = totalSupply() - balanceOf(address(this));
        if (eligible == 0) revert NoSharesForPremium();
        accPremiumPerShare += Math.mulDiv(premiumNet, ACC_PRECISION, eligible);
        emit PremiumAccrued(seriesId, premiumNet, accPremiumPerShare);
    }

    /// @notice USDG claimable by `account` right now, including premium not yet settled into storage.
    function premiumClaimable(address account) public view returns (uint256) {
        if (account == address(this)) return 0;
        uint256 owed = Math.mulDiv(balanceOf(account), accPremiumPerShare, ACC_PRECISION);
        return _premiumClaimable[account] + owed - premiumDebt[account];
    }

    /// @notice Always callable, including while paused, halted or sunset (SPEC §4.2, §15).
    function claimPremium(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        _settlePremium(msg.sender);
        amount = _premiumClaimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _premiumClaimable[msg.sender] = 0;
        usdg.safeTransfer(to, amount);
        emit PremiumClaimed(msg.sender, to, amount);
    }

    // ═════════════════════════════ queues (SPEC §4.3, D-006, D-032, D-037) ═════════════════════════════

    /// @notice Allowed in any vault state (D-032) unless sunset or deposits are paused.
    function requestDeposit(uint256 assets, address receiver) external nonReentrant returns (uint256 requestId) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert CannotTransferToVault();
        if (sunset) revert VaultSunsetted();
        if (riskModule.depositsPaused(address(this))) revert DepositsPaused();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        queuedDepositTokens += assets;
        requestId = _depositQueue.length;
        _depositQueue.push(
            DepositRequest({
                requester: msg.sender, receiver: receiver, assets: assets.toUint128(), status: RequestStatus.QUEUED
            })
        );
        emit DepositQueued(receiver, requestId, assets);
    }

    /// @notice Cancel a QUEUED or EXPIRED request; tokens go back to the requester.
    function cancelDeposit(uint256 requestId) external nonReentrant {
        DepositRequest storage r = _depositQueue[requestId];
        if (r.requester != msg.sender) revert NotRequester();
        if (r.status != RequestStatus.QUEUED && r.status != RequestStatus.EXPIRED) revert BadRequestStatus(r.status);
        r.status = RequestStatus.CANCELLED;
        queuedDepositTokens -= r.assets;
        IERC20(asset()).safeTransfer(msg.sender, r.assets);
        emit DepositQueueCancelled(requestId);
    }

    /// @notice Execute up to `n` queued deposits. Only in IDLE (share price constant, SPEC I-8).
    function processDeposits(uint256 n) external nonReentrant {
        if (state != VaultState.IDLE) revert VaultNotIdle();
        _processDeposits(n);
    }

    /// @dev Bookkeeping only: no ERC-20 transfer. Every visited entry (including cancelled ones) counts
    /// against `n`, so a run of cancelled entries can never make `settleSeries`/`openSeries` run out of
    /// gas (THREAT-MODEL T-18). A request larger than the remaining headroom is EXPIRED and refundable via
    /// `cancelDeposit` (D-037); when the cap is fully used (`remaining == 0`) processing stops instead, so
    /// filling the cap cannot mass-expire the queue. Stops when the cap price is unavailable or the cap
    /// controller reverts (settlement must never depend on an external oracle, T-11/T-12), when deposits
    /// are paused or the vault is sunset.
    function _processDeposits(uint256 n) internal {
        uint256 len = _depositQueue.length;
        uint256 head = depositQueueHead;
        bool blocked = sunset || riskModule.depositsPaused(address(this));
        while (head < len && n > 0 && !blocked) {
            DepositRequest storage r = _depositQueue[head];
            if (r.status != RequestStatus.QUEUED) {
                unchecked {
                    ++head;
                    --n;
                }
                continue;
            }
            (uint256 remaining, bool ok) = _capHeadroom();
            if (!ok || remaining == 0) break;
            uint256 assets = r.assets;
            if (assets > remaining) {
                r.status = RequestStatus.EXPIRED;
                emit DepositRequestExpired(head);
            } else {
                uint256 shares = _convertToShares(assets, Math.Rounding.Floor);
                r.status = RequestStatus.EXECUTED;
                queuedDepositTokens -= assets;
                _mint(r.receiver, shares);
                emit DepositExecuted(head, shares, _convertToAssets(WAD, Math.Rounding.Floor));
            }
            unchecked {
                ++head;
                --n;
            }
        }
        depositQueueHead = head;
    }

    /// @notice Queue a redeem while a series is open. In IDLE use `redeem`. Shares are escrowed here.
    function requestRedeem(uint256 shares, address receiver) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert CannotTransferToVault();
        if (state == VaultState.IDLE) revert VaultIsIdle();
        _escrowing = true;
        _transfer(msg.sender, address(this), shares);
        _escrowing = false;
        escrowedRedeemShares += shares;
        requestId = _redeemQueue.length;
        _redeemQueue.push(
            RedeemRequest({
                requester: msg.sender, receiver: receiver, shares: shares.toUint128(), status: RequestStatus.QUEUED
            })
        );
        emit RedeemQueued(msg.sender, requestId, shares);
    }

    function cancelRedeem(uint256 requestId) external nonReentrant {
        RedeemRequest storage r = _redeemQueue[requestId];
        if (r.requester != msg.sender) revert NotRequester();
        if (r.status != RequestStatus.QUEUED) revert BadRequestStatus(r.status);
        r.status = RequestStatus.CANCELLED;
        escrowedRedeemShares -= r.shares;
        _transfer(address(this), msg.sender, r.shares);
        emit RedeemQueueCancelled(requestId);
    }

    /// @notice Execute up to `n` queued redeems at the current (post-settlement) share price. Only in IDLE.
    function processRedeems(uint256 n) external nonReentrant {
        if (state != VaultState.IDLE) revert VaultNotIdle();
        _processRedeems(n);
    }

    /// @dev Bookkeeping only: burns escrowed shares and moves assets into `withdrawalClaimable`. Every
    /// visited entry counts against `n` (T-18, see `_processDeposits`).
    function _processRedeems(uint256 n) internal {
        uint256 len = _redeemQueue.length;
        uint256 head = redeemQueueHead;
        while (head < len && n > 0) {
            RedeemRequest storage r = _redeemQueue[head];
            if (r.status != RequestStatus.QUEUED) {
                unchecked {
                    ++head;
                    --n;
                }
                continue;
            }
            uint256 shares = r.shares;
            uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);
            r.status = RequestStatus.EXECUTED;
            escrowedRedeemShares -= shares;
            _burn(address(this), shares);
            withdrawalClaimable[r.receiver] += assets;
            withdrawalClaimableTotal += assets;
            emit RedeemExecuted(head, assets);
            unchecked {
                ++head;
                --n;
            }
        }
        redeemQueueHead = head;
    }

    /// @notice Pull assets of executed queued redeems. Always callable.
    function claimWithdrawal(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = withdrawalClaimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        withdrawalClaimable[msg.sender] = 0;
        withdrawalClaimableTotal -= amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit WithdrawalClaimed(msg.sender, to, amount);
    }

    // ═════════════════════════════ series lifecycle (SPEC §4.4, §5, §9.7) ═════════════════════════════

    /// @notice Pre-checks for `openSeries` (SPEC §16.2 `canOpenAuction`). Schedule/strike/reserve checks
    /// live in AuctionHouse.
    function canOpenAuction(uint64 expiry) public view returns (bool ok, bytes32 reason) {
        if (state != VaultState.IDLE) return (false, "NOT_IDLE");
        if (sunset) return (false, "SUNSET");
        if (riskModule.auctionsPaused(address(this))) return (false, "AUCTIONS_PAUSED");
        if (expiry <= block.timestamp) return (false, "EXPIRY_PAST");
        if (stock.oraclePaused()) return (false, "ORACLE_PAUSED");
        // D-026 / SPEC §10.3: refuse a staged change inside (now, expiry]. ERC-8056 tokens keep the LAST
        // effectiveAt after it passed (AAPL: 1786720366 on 2026-09-02, multiplier already applied), so a
        // past value must not block the vault.
        uint256 effectiveAt = stock.effectiveAt();
        if (effectiveAt > block.timestamp && effectiveAt <= expiry) return (false, "MULTIPLIER_CHANGE");
        return (true, bytes32(0));
    }

    /// @inheritdoc ICoveredCallVault
    /// @dev IDLE → AUCTION. Executes queued deposits first (D-032), then offers 100 % of the unencumbered
    /// balance net of queued redeems (D-009).
    function openSeries(SeriesKind kind, uint128 strike, uint64 expiry)
        external
        onlyAuctionHouse
        nonReentrant
        returns (uint256 seriesId, uint256 offeredQty)
    {
        (bool ok, bytes32 reason) = canOpenAuction(expiry);
        if (!ok) revert CannotOpen(reason);
        if (strike == 0) revert ZeroStrike();
        _processDeposits(maxQueueOpsPerOpen);
        uint256 ta = totalAssets();
        uint256 pending = pendingRedeemAssets();
        offeredQty = ta > pending ? ta - pending : 0;
        if (offeredQty == 0) revert NothingToOffer();
        uint256 multiplier = stock.uiMultiplier();
        seriesId = optionToken.create(address(stock), kind, strike, expiry, multiplier);
        VaultSeries storage s = _series[seriesId];
        s.kind = kind;
        s.state = SeriesState.AUCTION;
        s.expiry = expiry;
        s.strike = strike;
        s.offeredQty = offeredQty.toUint128();
        s.multiplierAtOpen = multiplier;
        currentSeriesId = seriesId;
        _setState(VaultState.AUCTION);
        emit SeriesOpened(seriesId, kind, strike, expiry, offeredQty, multiplier);
    }

    /// @inheritdoc ICoveredCallVault
    /// @dev AUCTION → IDLE when no valid bid (SPEC §8.2 step 8).
    function skipSeries(uint256 seriesId) external onlyAuctionHouse nonReentrant {
        VaultSeries storage s = _currentSeries(seriesId, SeriesState.AUCTION);
        s.state = SeriesState.SKIPPED;
        _setState(VaultState.IDLE);
        emit SeriesSkipped(seriesId);
    }

    /// @inheritdoc ICoveredCallVault
    /// @dev AUCTION → LIVE at clearing. Encumbers `filledQty` (≤ offered and ≤ totalAssets, SPEC I-1) and
    /// pulls the net premium from the AuctionHouse. No ERC-1155 mint here (D-024). The coverage re-check is
    /// against `totalAssets()`, not `freeAssets()`: redeem requests filed during the AUCTION window stay inside
    /// `offeredQty` (D-036, D-040) and are processed only after the encumbrance is released, so they never
    /// break coverage; checking against `freeAssets()` would let a 1-wei request grief every clear.
    function mintSeries(uint256 seriesId, uint256 filledQty, uint256 premiumNet)
        external
        onlyAuctionHouse
        nonReentrant
    {
        VaultSeries storage s = _currentSeries(seriesId, SeriesState.AUCTION);
        if (filledQty == 0) revert ZeroAmount();
        if (filledQty > s.offeredQty) revert ExceedsOffered(filledQty, s.offeredQty);
        uint256 available = totalAssets(); // < offeredQty only after an issuer burn between open and clear
        if (filledQty > available) revert InsufficientCoverage(filledQty, available);
        s.filledQty = filledQty.toUint128();
        s.state = SeriesState.LIVE;
        encumbered += filledQty;
        _setState(VaultState.LIVE);
        if (premiumNet > 0) {
            usdg.safeTransferFrom(msg.sender, address(this), premiumNet);
            _accruePremium(seriesId, premiumNet);
        }
        emit SeriesCleared(seriesId, filledQty, premiumNet);
    }

    /// @inheritdoc ICoveredCallVault
    /// @dev The pull step of `AuctionHouse.claimOptions` (D-024, D-038). Cumulative mints ≤ filledQty.
    function mintOptions(uint256 seriesId, address to, uint256 qty) external onlyAuctionHouse nonReentrant {
        VaultSeries storage s = _series[seriesId];
        if (
            s.state != SeriesState.LIVE && s.state != SeriesState.HALTED && s.state != SeriesState.SETTLED
                && s.state != SeriesState.RESOLVED
        ) revert WrongSeriesState(s.state);
        if (qty == 0) revert ZeroAmount();
        uint256 remaining = s.filledQty - s.mintedQty;
        if (qty > remaining) revert ExceedsFilled(qty, remaining);
        s.mintedQty += qty.toUint128();
        optionToken.mint(seriesId, to, qty);
        emit OptionsMinted(seriesId, to, qty);
    }

    /// @inheritdoc ICoveredCallVault
    /// @dev LIVE/HALTED → IDLE. Oracle policy, jump guard and resolution band are enforced by the caller
    /// (SettlementOracle, SPEC §9). Pure bookkeeping: NO stock-token transfer (SPEC I-6, T-11).
    function settleSeries(uint256 seriesId, uint128 price8, uint8 path) external onlySettlement nonReentrant {
        VaultSeries storage s = _series[seriesId];
        if (seriesId != currentSeriesId) revert WrongSeries(seriesId);
        if (s.state != SeriesState.LIVE && s.state != SeriesState.HALTED) revert WrongSeriesState(s.state);
        if (price8 == 0) revert ZeroPrice();
        if (path == 0 || path > 5) revert InvalidPath(path);
        // SPEC §4.4 / §9.6: LIVE settles on an oracle path (1-3); HALTED exits only through a resolution (4-5).
        if (s.state == SeriesState.HALTED ? path < 4 : path > 3) revert InvalidPath(path);

        uint256 filled = s.filledQty;
        uint256 strike = s.strike;
        // SPEC §7.1: payoutPerOption = S > K ? (S − K) × 1e18 / S : 0, rounded down; always < 1e18.
        uint256 ppo = price8 > strike ? Math.mulDiv(price8 - strike, WAD, price8) : 0;
        uint256 payoutTotal = Math.mulDiv(filled, ppo, WAD);

        // SPEC §9.7 step 5: only reachable if the issuer burned vault tokens.
        uint256 available = totalAssets();
        if (payoutTotal > available) {
            uint256 short = payoutTotal - available;
            ppo = Math.mulDiv(ppo, available, payoutTotal);
            payoutTotal = Math.mulDiv(filled, ppo, WAD);
            totalShortfall += short;
            emit ShortfallRecorded(seriesId, short);
        }

        payoutOwed += payoutTotal;
        encumbered -= filled;
        s.settlementPrice = price8;
        s.payoutPerOption = ppo.toUint128();
        s.settlementPath = path;
        s.state = path >= 4 ? SeriesState.RESOLVED : SeriesState.SETTLED;
        optionToken.markSettled(seriesId, price8, ppo.toUint128());
        _setState(VaultState.IDLE);
        emit SeriesSettled(seriesId, price8, path, ppo, payoutTotal);

        _processRedeems(maxQueueOpsPerSettle);
        _processDeposits(maxQueueOpsPerSettle);
    }

    /// @inheritdoc ICoveredCallVault
    /// @dev LIVE → HALTED (SPEC §9.6). Deposits blocked; everything else keeps working.
    function haltSeries(uint256 seriesId, bytes32 reason) external onlySettlement nonReentrant {
        VaultSeries storage s = _currentSeries(seriesId, SeriesState.LIVE);
        s.state = SeriesState.HALTED;
        _setState(VaultState.HALTED);
        emit SeriesHalted(seriesId, reason);
    }

    /// @inheritdoc ICoveredCallVault
    /// @dev Called by `OptionToken.claim` after it burned `qty`. Σ floor(q_i × ppo) ≤ floor(Σ q_i × ppo),
    /// so `payoutOwed` never underflows.
    function payOptionClaim(uint256 seriesId, address to, uint256 qty)
        external
        onlyOptionToken
        nonReentrant
        returns (uint256 tokens)
    {
        VaultSeries storage s = _series[seriesId];
        if (s.state != SeriesState.SETTLED && s.state != SeriesState.RESOLVED) revert WrongSeriesState(s.state);
        if (qty == 0) revert ZeroAmount();
        uint256 remaining = s.filledQty - s.claimedQty;
        if (qty > remaining) revert ExceedsFilled(qty, remaining);
        s.claimedQty += qty.toUint128();
        tokens = Math.mulDiv(qty, s.payoutPerOption, WAD);
        if (tokens > 0) {
            payoutOwed -= tokens;
            IERC20(asset()).safeTransfer(to, tokens);
        }
        emit OptionPaid(seriesId, to, qty, tokens);
    }

    function _currentSeries(uint256 seriesId, SeriesState expected) internal view returns (VaultSeries storage s) {
        if (seriesId != currentSeriesId) revert WrongSeries(seriesId);
        s = _series[seriesId];
        if (s.state != expected) revert WrongSeriesState(s.state);
    }

    function _setState(VaultState to) internal {
        VaultState from = state;
        state = to;
        emit VaultStateChanged(from, to);
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice Irreversible (D-034). Blocks new series and new deposits; withdrawals stay open forever.
    function setSunset() external onlyOwner {
        if (sunset) revert VaultSunsetted();
        sunset = true;
        emit VaultSunset();
    }

    function setMaxQueueOps(uint256 perOpen, uint256 perSettle) external onlyOwner {
        if (perOpen == 0 || perOpen > MAX_QUEUE_OPS || perSettle == 0 || perSettle > MAX_QUEUE_OPS) {
            revert OutOfBounds();
        }
        emit ParameterChanged(address(this), "maxQueueOpsPerOpen", maxQueueOpsPerOpen, perOpen);
        emit ParameterChanged(address(this), "maxQueueOpsPerSettle", maxQueueOpsPerSettle, perSettle);
        maxQueueOpsPerOpen = perOpen;
        maxQueueOpsPerSettle = perSettle;
    }

    // ═════════════════════════════ views ═════════════════════════════

    function series(uint256 seriesId) external view returns (VaultSeries memory) {
        return _series[seriesId];
    }

    function queuedDeposit(uint256 requestId) external view returns (DepositRequest memory) {
        return _depositQueue[requestId];
    }

    function queuedRedeem(uint256 requestId) external view returns (RedeemRequest memory) {
        return _redeemQueue[requestId];
    }

    /// @return depositsPending entries at or after the head (includes cancelled ones not yet skipped)
    /// @return redeemsPending same for the redeem queue
    function queueLengths() external view returns (uint256 depositsPending, uint256 redeemsPending) {
        depositsPending = _depositQueue.length - depositQueueHead;
        redeemsPending = _redeemQueue.length - redeemQueueHead;
    }

    function depositQueueLength() external view returns (uint256) {
        return _depositQueue.length;
    }

    function redeemQueueLength() external view returns (uint256) {
        return _redeemQueue.length;
    }
}
