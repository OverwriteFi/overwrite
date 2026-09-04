// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IEmissionsController, ISafetyModuleWiring} from "./interfaces/IEmissionsController.sol";
import {IWriteHolder} from "./interfaces/IWriteHolder.sol";

/// @title EmissionsController
/// @notice Holds the 300 000 000 WRITE emissions bucket (docs/TOKENOMICS.md) and streams it linearly to one
/// sink, the SafetyModule, over four years. These are fixed-supply incentives decided by governance, not a
/// share of protocol revenue — CLAUDE.md rule 7 forbids the latter, and no fee ever reaches this contract.
/// @dev Emissions are PULLED by the sink, never pushed (D-074): the stake asset is also the reward asset, so
/// a push would force `balanceOf`-based reward accounting in the SafetyModule and let a slash silently eat
/// unclaimed rewards. `_checkpoint` moves elapsed emissions into `owed` before any rate change, so `setRate`
/// can never reprice time that has already passed. `endTime` is immutable (D-076): `setRate(0)` stops the
/// stream and `setRate` restarts it, which makes a second mutable time axis unnecessary.
contract EmissionsController is Ownable2Step, IEmissionsController, IWriteHolder {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants ─────────────────────────────

    /// @inheritdoc IWriteHolder
    uint256 public constant allocation = 300_000_000e18;
    uint64 public constant MIN_DURATION = 365 days;
    uint64 public constant MAX_DURATION = 3650 days;
    /// @notice Fastest legal stream: the whole bucket in `MIN_DURATION`. Without this bound a short
    /// constructor duration produces a rate far above anything `setRate` would accept (D-076).
    uint256 public constant MAX_RATE = allocation / uint256(MIN_DURATION);

    // ───────────────────────────── immutables ─────────────────────────────

    uint64 public immutable startTime;
    uint64 public immutable endTime;

    // ───────────────────────────── state ─────────────────────────────

    address public writeToken;
    address public sink;
    /// @notice WRITE per second, `[0, MAX_RATE]`.
    uint256 public rate;
    uint64 public lastAccrual;
    /// @notice Accrued at the then-current rate but not yet pulled by the sink.
    uint256 public owed;
    /// @notice Transferred to the sink so far.
    uint256 public released;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error AlreadySet();
    error NotAContract(address target);
    error NotSink();
    error OutOfBounds();
    error Underfunded(uint256 have, uint256 want);
    error Miswired(bytes32 what);
    error RenounceDisabled();

    // ───────────────────────────── events ─────────────────────────────

    event WriteTokenSet(address indexed writeToken);
    event SinkSet(address indexed sink);
    event Emitted(address indexed sink, uint256 amount, uint256 released);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    /// @param duration Stream length in seconds, bounded `[MIN_DURATION, MAX_DURATION]`; 4 years at launch.
    constructor(address owner_, uint64 duration) Ownable(owner_) {
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert OutOfBounds();
        startTime = uint64(block.timestamp);
        endTime = uint64(block.timestamp) + duration;
        lastAccrual = uint64(block.timestamp);
        uint256 rate_ = allocation / uint256(duration);
        if (rate_ > MAX_RATE) revert OutOfBounds(); // unreachable given the duration bound; kept as a guard
        rate = rate_;
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @inheritdoc IWriteHolder
    /// @dev One-shot wiring (D-044, D-060); `>=` so a donation cannot brick it (D-062).
    function setWriteToken(address write_) external onlyOwner {
        if (write_ == address(0)) revert ZeroAddress();
        if (writeToken != address(0)) revert AlreadySet();
        if (write_.code.length == 0) revert NotAContract(write_);
        uint256 bal = IERC20(write_).balanceOf(address(this));
        if (bal < allocation) revert Underfunded(bal, allocation);
        writeToken = write_;
        emit WriteTokenSet(write_);
    }

    /// @notice One-shot wiring of the single sink. Asserts the candidate points back here and at the same
    /// token, so a half-wired pair cannot be created (D-049, D-063).
    function setSink(address sink_) external onlyOwner {
        if (sink_ == address(0)) revert ZeroAddress();
        if (sink != address(0)) revert AlreadySet();
        if (writeToken == address(0)) revert Miswired("WRITE_TOKEN");
        if (ISafetyModuleWiring(sink_).emissions() != address(this)) revert Miswired("SINK_EMISSIONS");
        if (ISafetyModuleWiring(sink_).writeToken() != writeToken) revert Miswired("SINK_WRITE");
        sink = sink_;
        emit SinkSet(sink_);
    }

    /// @notice Changes the stream rate. Checkpoints first, so time already elapsed keeps its old rate.
    function setRate(uint256 rate_) external onlyOwner {
        if (rate_ > MAX_RATE) revert OutOfBounds();
        _checkpoint();
        emit ParameterChanged(address(this), "rate", rate, rate_);
        rate = rate_;
    }

    /// @dev Renouncing would freeze the rate forever with no way to stop or restart the stream.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═════════════════════════════ sink ═════════════════════════════

    /// @inheritdoc IEmissionsController
    function claim() external returns (uint256 amount) {
        if (msg.sender != sink || sink == address(0)) revert NotSink();
        _checkpoint();
        amount = owed;
        if (amount == 0) return 0;
        owed = 0;
        released += amount;
        IERC20(writeToken).safeTransfer(sink, amount);
        emit Emitted(sink, amount, released);
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc IEmissionsController
    /// @dev `owed` plus what has accrued since `lastAccrual`, capped at the undistributed remainder.
    function accrued() public view returns (uint256) {
        return owed + _pending();
    }

    /// @notice WRITE that will never be emitted under the current schedule (the tail left by `setRate(0)`
    /// windows and by integer division), readable by governance for a re-schedule decision.
    function undistributed() external view returns (uint256) {
        return allocation - released - owed;
    }

    // ═════════════════════════════ internal ═════════════════════════════

    function _pending() internal view returns (uint256) {
        uint64 upto = block.timestamp < endTime ? uint64(block.timestamp) : endTime;
        if (upto <= lastAccrual) return 0;
        uint256 amount = rate * (upto - lastAccrual);
        uint256 room = allocation - released - owed;
        return amount > room ? room : amount;
    }

    function _checkpoint() internal {
        uint64 upto = block.timestamp < endTime ? uint64(block.timestamp) : endTime;
        uint256 amount = _pending();
        if (upto > lastAccrual) lastAccrual = upto;
        if (amount != 0) owed += amount;
    }
}
