// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IEmissionsController} from "./interfaces/IEmissionsController.sol";
import {ISafetyModule} from "./interfaces/ISafetyModule.sol";
import {IWritePriceOracle} from "./interfaces/IWritePriceOracle.sol";

/// @title SafetyModule
/// @notice Stakes WRITE as the protocol's backstop (SPEC §14). Staking earns WRITE emissions from the
/// `EmissionsController`; unstaking takes a 14-day cooldown and must be claimed inside a 3-day window;
/// the timelock may slash up to 30 % of the staked total per event. `valueUSD()` is what
/// `CapController.SAFETY_MODULE` mode multiplies by `k` to size every vault's deposit cap (SPEC §12).
/// There is no revenue share: stakers receive fixed-supply emissions decided by governance and nothing
/// else — no fee, premium or settlement flow reaches this contract (CLAUDE.md rule 7).
/// @dev Accounting is share-based rather than the 1:1 `sWRITE` of SPEC §14 (D-071): a 1:1 peg breaks the
/// instant a slash lands, whereas shares over an explicit `totalStaked` accumulator make a slash a pro-rata
/// reduction in share price. Shares are non-transferable and never leave this ledger.
/// The reward asset *is* the stake asset, which is the classic footgun here: `totalStaked` is an explicit
/// accumulator and is NEVER `write.balanceOf(this)`, so rewards sitting in the contract can never be counted
/// as principal and a slash can never consume them. Emissions are pulled, never pushed (D-074), and
/// emissions accruing while nobody is staked are parked in `unallocatedRewards` rather than being handed to
/// the first staker who arrives (D-075).
/// A staker cannot dodge a slash: the 14-day cooldown dominates the 48 h timelock delay, so anyone reacting
/// to a publicly queued slash proposal can exit no earlier than 14 days after it has executed.
contract SafetyModule is Ownable2Step, ReentrancyGuard, ISafetyModule {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants (SPEC §14) ─────────────────────────────

    uint256 public constant COOLDOWN = 14 days;
    uint256 public constant CLAIM_WINDOW = 3 days;
    uint256 public constant MAX_SLASH_BPS = 3000;
    /// @dev SPEC §14 caps a slash at 30 % *per event* and at one event per 14 days. The per-call cap alone
    /// would permit 65.7 % across three consecutive timelock executions (D-077).
    uint256 public constant SLASH_INTERVAL = 14 days;
    uint256 public constant ACC_PRECISION = 1e36; // matches CoveredCallVault
    uint256 public constant BPS = 1e4;
    uint8 public constant DECIMALS_OFFSET = 6; // matches CoveredCallVault's virtual-share offset
    /// @dev A slash may not *cross* this floor, but a pool already below it stays slashable (D-073):
    /// a flat "no slash below the floor" rule disables slashing exactly when the module is weakest.
    uint256 public constant MIN_RESIDUAL_STAKE = 1e12;

    // ───────────────────────────── immutables ─────────────────────────────

    address public immutable writeToken;
    address public immutable emissions;

    // ───────────────────────────── types ─────────────────────────────

    struct UnstakeRequest {
        /// @dev `uint256`, not `uint128` (D-072): every slash raises the shares-per-asset multiplier, so a
        /// packed width would eventually make a large holder unable to open a request at all.
        uint256 shares;
        uint64 unlockAt;
    }

    // ───────────────────────────── state ─────────────────────────────

    /// @notice Re-settable by the timelock (D-078, the D-039 precedent): a dead oracle would otherwise
    /// freeze every vault's deposits with no fix short of a redeploy.
    IWritePriceOracle public oracle;

    uint256 public totalShares;
    /// @notice Staked principal. Deliberately an accumulator, never `write.balanceOf(this)`.
    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public totalUnclaimedRewards;
    /// @notice Emissions that accrued while nothing was staked; only the timelock can redirect them.
    uint256 public unallocatedRewards;

    mapping(address account => uint256) public sharesOf;
    mapping(address account => uint256) internal _rewardDebt;
    mapping(address account => uint256) public claimableRewards;
    mapping(address account => UnstakeRequest) public cooldowns;
    uint64 public lastSlashAt;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error Miswired(bytes32 what);
    error PoolInsolvent();
    error InsufficientShares(uint256 have, uint256 want);
    error NoCooldown();
    error CooldownActive(uint64 unlockAt);
    error ClaimWindowClosed(uint64 closedAt);
    error ExceedsSlashCap(uint256 amount, uint256 cap);
    error SlashTooSoon(uint64 allowedAt);
    error SlashWouldWipe();
    error RenounceDisabled();

    // ───────────────────────────── events (SPEC §16.1) ─────────────────────────────

    event Staked(address indexed account, uint256 assets, uint256 shares);
    event UnstakeRequested(address indexed account, uint256 shares, uint64 unlockAt);
    event UnstakeCancelled(address indexed account, uint256 shares);
    event Unstaked(address indexed account, uint256 shares, uint256 assets);
    event RewardsClaimed(address indexed account, uint256 amount);
    event RewardsAccrued(uint256 amount, uint256 accRewardPerShare);
    event RewardsUnallocated(uint256 amount, uint256 total);
    event UnallocatedRedirected(address indexed to, uint256 amount);
    event Slashed(address indexed recipient, uint256 amount, string evidenceURI);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address write_, address emissions_, address oracle_, address owner_) Ownable(owner_) {
        if (write_ == address(0) || emissions_ == address(0) || oracle_ == address(0)) revert ZeroAddress();
        if (IEmissionsController(emissions_).writeToken() != write_) revert Miswired("EMISSIONS_WRITE");
        if (IWritePriceOracle(oracle_).writeToken() != write_) revert Miswired("ORACLE_WRITE");
        writeToken = write_;
        emissions = emissions_;
        oracle = IWritePriceOracle(oracle_);
    }

    // ═════════════════════════════ stakers (SPEC §14) ═════════════════════════════

    function stake(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        _harvest(msg.sender);
        if (totalShares != 0 && totalStaked == 0) revert PoolInsolvent();

        shares = previewStake(assets);
        if (shares == 0) revert ZeroAmount();
        totalShares += shares;
        totalStaked += assets;
        sharesOf[msg.sender] += shares;
        _syncDebt(msg.sender);

        IERC20(writeToken).safeTransferFrom(msg.sender, address(this), assets);
        emit Staked(msg.sender, assets, shares);
    }

    /// @notice Starts the 14-day cooldown on `shares`. The shares stay in the pool, so they keep earning
    /// emissions and remain fully slashable (SPEC §14) — that symmetry is the point of the cooldown.
    /// A second request replaces the first and restarts the clock.
    function requestUnstake(uint256 shares) external nonReentrant returns (uint64 unlockAt) {
        if (shares == 0) revert ZeroAmount();
        uint256 have = sharesOf[msg.sender];
        if (shares > have) revert InsufficientShares(have, shares);
        _accrue();
        _harvest(msg.sender);

        unlockAt = uint64(block.timestamp) + uint64(COOLDOWN);
        cooldowns[msg.sender] = UnstakeRequest({shares: shares, unlockAt: unlockAt});
        emit UnstakeRequested(msg.sender, shares, unlockAt);
    }

    function cancelUnstake() external {
        UnstakeRequest memory req = cooldowns[msg.sender];
        if (req.shares == 0) revert NoCooldown();
        delete cooldowns[msg.sender];
        emit UnstakeCancelled(msg.sender, req.shares);
    }

    /// @notice Redeems a matured request inside its 3-day claim window at the *current* share price, so a
    /// slash during the cooldown is borne by the leaver too.
    function unstake() external nonReentrant returns (uint256 assets) {
        UnstakeRequest memory req = cooldowns[msg.sender];
        if (req.shares == 0) revert NoCooldown();
        if (block.timestamp < req.unlockAt) revert CooldownActive(req.unlockAt);
        uint64 closesAt = req.unlockAt + uint64(CLAIM_WINDOW);
        if (block.timestamp > closesAt) revert ClaimWindowClosed(closesAt);

        _accrue();
        _harvest(msg.sender);

        uint256 have = sharesOf[msg.sender];
        uint256 shares = req.shares > have ? have : req.shares;
        assets = previewUnstake(shares);

        delete cooldowns[msg.sender];
        sharesOf[msg.sender] = have - shares;
        totalShares -= shares;
        totalStaked -= assets;
        _syncDebt(msg.sender);

        IERC20(writeToken).safeTransfer(msg.sender, assets);
        emit Unstaked(msg.sender, shares, assets);
    }

    /// @dev The payout is capped at the surplus the module actually holds above principal, which makes "a
    /// reward claim never touches staked principal" structural rather than a consequence of the index being
    /// exact. It is not: credits come from a floored cumulative index, and
    /// `floor(s x A2 / P) - floor(s x A1 / P)` can exceed `floor(s x (A2 - A1) / P)` by one wei, so the sum of
    /// credits drifts above `totalUnclaimedRewards` by roughly a wei per harvest. Without the cap the last
    /// claimant's subtraction underflows and their claim is bricked (found by the CI-profile invariant run).
    /// Any shortfall is dust; the remainder stays credited to the account.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _accrue();
        _harvest(msg.sender);
        amount = claimableRewards[msg.sender];
        if (amount == 0) revert ZeroAmount();

        uint256 surplus = rewardSurplus();
        if (amount > surplus) amount = surplus;
        if (amount == 0) revert ZeroAmount();

        claimableRewards[msg.sender] -= amount;
        totalUnclaimedRewards = amount > totalUnclaimedRewards ? 0 : totalUnclaimedRewards - amount;
        IERC20(writeToken).safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Permissionless accrual, so emissions keep checkpointing even in a quiet week.
    function poke() external {
        _accrue();
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice Slashes staked principal to `recipient` (SPEC §14). Shares are untouched, so the loss lands
    /// pro-rata on every staker, including everyone in cooldown.
    function slash(uint256 amount, address recipient, string calldata evidenceURI) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        _accrue();

        uint256 staked = totalStaked;
        uint256 cap = Math.mulDiv(staked, MAX_SLASH_BPS, BPS);
        if (amount > cap) revert ExceedsSlashCap(amount, cap);
        if (lastSlashAt != 0) {
            uint64 allowedAt = lastSlashAt + uint64(SLASH_INTERVAL);
            if (block.timestamp < allowedAt) revert SlashTooSoon(allowedAt);
        }
        if (staked > MIN_RESIDUAL_STAKE && staked - amount < MIN_RESIDUAL_STAKE) revert SlashWouldWipe();

        lastSlashAt = uint64(block.timestamp);
        totalStaked = staked - amount;
        IERC20(writeToken).safeTransfer(recipient, amount);
        emit Slashed(recipient, amount, evidenceURI);
    }

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        if (IWritePriceOracle(oracle_).writeToken() != writeToken) revert Miswired("ORACLE_WRITE");
        emit ParameterChanged(address(this), "oracle", uint256(uint160(address(oracle))), uint256(uint160(oracle_)));
        oracle = IWritePriceOracle(oracle_);
    }

    /// @notice Sends emissions that accrued while nothing was staked to a timelock-chosen address.
    function redirectUnallocated(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        _accrue();
        amount = unallocatedRewards;
        if (amount == 0) revert ZeroAmount();
        unallocatedRewards = 0;
        IERC20(writeToken).safeTransfer(to, amount);
        emit UnallocatedRedirected(to, amount);
    }

    /// @dev A SafetyModule with no owner could never slash, which is its whole purpose.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═════════════════════════════ views (SPEC §12, §16.2) ═════════════════════════════

    /// @inheritdoc ISafetyModule
    /// @dev Returns 0 rather than reverting when no price is available (D-069). `CapController.vaultCapUSD`
    /// is a public view the frontend and keepers read; a revert would make the whole cap system unreadable
    /// instead of merely closed. Both fail closed — with `cap6 == 0` no deposit can be accepted — but only
    /// this one keeps the views answerable. Note the consequence: `deposit()` then reverts with OpenZeppelin's
    /// `ERC4626ExceededMaxDeposit`, not `CapPriceUnavailable`.
    function valueUSD() external view returns (uint256) {
        (uint256 usd6,) = valueUSDView();
        return usd6;
    }

    /// @notice The same number with the availability flag the cap machinery hides.
    function valueUSDView() public view returns (uint256 usd6, bool ok) {
        try oracle.usdValueOfWrite(totalStaked) returns (uint256 value, bool available) {
            return available ? (value, true) : (0, false);
        } catch {
            return (0, false);
        }
    }

    /// @notice SPEC §12's name for `valueUSD()`; identical semantics.
    function safetyModuleValueUSD() external view returns (uint256) {
        (uint256 usd6,) = valueUSDView();
        return usd6;
    }

    /// @dev Virtual shares and assets, as in CoveredCallVault: a donation cannot move the share price
    /// (`totalStaked` is an accumulator), and the offset keeps the first deposit's precision.
    function previewStake(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalShares + 10 ** DECIMALS_OFFSET, totalStaked + 1);
    }

    function previewUnstake(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalStaked + 1, totalShares + 10 ** DECIMALS_OFFSET);
    }

    /// @notice WRITE currently backing `account`'s shares, after every slash so far.
    function stakedOf(address account) external view returns (uint256) {
        return previewUnstake(sharesOf[account]);
    }

    /// @notice WRITE held above staked principal and parked emissions: everything that can ever be paid out
    /// as a reward. Saturating, so it can never revert on an unexpected state.
    function rewardSurplus() public view returns (uint256) {
        uint256 bal = IERC20(writeToken).balanceOf(address(this));
        uint256 reserved = totalStaked + unallocatedRewards;
        return bal > reserved ? bal - reserved : 0;
    }

    function pendingRewards(address account) external view returns (uint256) {
        uint256 acc = Math.mulDiv(sharesOf[account], accRewardPerShare, ACC_PRECISION);
        uint256 debt = _rewardDebt[account];
        return claimableRewards[account] + (acc > debt ? acc - debt : 0);
    }

    function unstakeWindow(address account) external view returns (uint64 opensAt, uint64 closesAt) {
        UnstakeRequest memory req = cooldowns[account];
        if (req.shares == 0) return (0, 0);
        return (req.unlockAt, req.unlockAt + uint64(CLAIM_WINDOW));
    }

    // ═════════════════════════════ internal ═════════════════════════════

    /// @dev Pulls whatever the controller owes. The `sink` check keeps `stake` working in the deployment
    /// window before `EmissionsController.setSink` has executed, without a try/catch around a trusted call.
    function _accrue() internal {
        address e = emissions;
        if (IEmissionsController(e).sink() != address(this)) return;
        uint256 pulled = IEmissionsController(e).claim();
        if (pulled == 0) return;
        if (totalShares == 0) {
            unallocatedRewards += pulled;
            emit RewardsUnallocated(pulled, unallocatedRewards);
            return;
        }
        accRewardPerShare += Math.mulDiv(pulled, ACC_PRECISION, totalShares);
        totalUnclaimedRewards += pulled;
        emit RewardsAccrued(pulled, accRewardPerShare);
    }

    /// @dev Credits `account` for the index movement since its last checkpoint. Must be called before any
    /// change to `sharesOf[account]`, and `_syncDebt` immediately after.
    function _harvest(address account) internal {
        uint256 acc = Math.mulDiv(sharesOf[account], accRewardPerShare, ACC_PRECISION);
        uint256 debt = _rewardDebt[account];
        if (acc > debt) claimableRewards[account] += acc - debt;
        _rewardDebt[account] = acc;
    }

    function _syncDebt(address account) internal {
        _rewardDebt[account] = Math.mulDiv(sharesOf[account], accRewardPerShare, ACC_PRECISION);
    }
}
