// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IWriteHolder} from "./interfaces/IWriteHolder.sol";

/// @title Vesting
/// @notice Linear vesting with an optional cliff for many beneficiaries (CLAUDE.md rule 5: treasury and team
/// tokens live in Vesting contracts, never in the admin wallet). Deployed twice (D-062): a treasury instance
/// holding 200 000 000 WRITE with `allowRevocable = false`, and a team instance holding 150 000 000 with
/// `allowRevocable = true`. Splitting the buckets makes the treasury grant structurally unrevocable rather
/// than merely unrevoked.
/// @dev No accounting term reads `balanceOf` (D-090): `unallocated()` derives from the `allocation` immutable,
/// so a donation can never expand what governance may allocate or reallocate. `revoke` moves no tokens — it
/// freezes `totalAmount` at the amount vested so far, which keeps the already-vested-but-unreleased portion
/// claimable and keeps `totalAllocated == Σ totalAmount` exact. There is no sweep and no timelock power to
/// redirect a grant (SPEC §15, D-092).
contract Vesting is Ownable2Step, ReentrancyGuard, IWriteHolder {
    using SafeERC20 for IERC20;

    // ───────────────────────────── immutables ─────────────────────────────

    /// @inheritdoc IWriteHolder
    uint256 public immutable allocation;
    /// @notice False on the treasury instance: `createSchedule` then rejects every revocable schedule.
    bool public immutable allowRevocable;

    /// @notice A schedule must still have this much of its term left when it is created, so no single
    /// proposal can create a grant that is already (or almost) fully vested (D-091, D-098).
    uint64 public constant MIN_REMAINING_TERM = 90 days;

    // ───────────────────────────── types ─────────────────────────────

    struct Schedule {
        address beneficiary;
        uint64 start;
        uint64 cliffDuration;
        uint64 duration;
        bool revocable;
        bool revoked;
        uint64 revokedAt;
        uint256 totalAmount;
        uint256 released;
    }

    // ───────────────────────────── state ─────────────────────────────

    address public writeToken;
    Schedule[] internal _schedules;
    uint256 public totalAllocated;
    uint256 public totalReleased;
    /// @notice Returned to the timelock from the unallocated pool (revoked grants and the never-granted tail).
    uint256 public reallocated;
    mapping(address beneficiary => uint256[]) internal _idsOf;
    mapping(uint256 id => address) public pendingBeneficiary;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error AlreadySet();
    error NotAContract(address target);
    error Underfunded(uint256 have, uint256 want);
    error RevocableNotAllowed();
    error InvalidSchedule();
    error ExceedsUnallocated(uint256 want, uint256 have);
    error UnknownSchedule(uint256 id);
    error NotRevocable(uint256 id);
    error AlreadyRevoked(uint256 id);
    error NothingToRelease(uint256 id);
    error NotBeneficiary(address caller);
    error NotPendingBeneficiary(address caller);
    error NoSchedulesYet();
    error RenounceDisabled();

    // ───────────────────────────── events ─────────────────────────────

    event WriteTokenSet(address indexed writeToken);
    event ScheduleCreated(
        uint256 indexed id, address indexed beneficiary, uint256 totalAmount, uint64 start, uint64 cliff, uint64 end
    );
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 vested, uint256 returnedToPool);
    event Reallocated(address indexed to, uint256 amount);
    event BeneficiaryProposed(uint256 indexed id, address indexed from, address indexed to);
    event BeneficiaryChanged(uint256 indexed id, address indexed from, address indexed to);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address owner_, uint256 allocation_, bool allowRevocable_) Ownable(owner_) {
        if (allocation_ == 0) revert ZeroAmount();
        allocation = allocation_;
        allowRevocable = allowRevocable_;
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

    /// @notice Allocates `totalAmount` out of the unallocated pool to `beneficiary`.
    /// @dev Rejects a schedule whose cliff has already passed (D-091): backdating `start` to TGE stays legal,
    /// but a single proposal that unlocks a large grant instantly does not.
    function createSchedule(
        address beneficiary,
        uint64 start,
        uint64 cliffDuration,
        uint64 duration,
        uint256 totalAmount,
        bool revocable
    ) external onlyOwner returns (uint256 id) {
        if (writeToken == address(0)) revert ZeroAddress();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (revocable && !allowRevocable) revert RevocableNotAllowed();
        if (duration == 0 || cliffDuration >= duration) revert InvalidSchedule();
        if (uint256(start) + uint256(cliffDuration) < block.timestamp) revert InvalidSchedule();
        // Backdating `start` to TGE stays legal, but the grant must still have a real term ahead of it:
        // `cliff == duration` or a term ending now would vest the whole amount in the creating block.
        if (uint256(start) + uint256(duration) < block.timestamp + MIN_REMAINING_TERM) revert InvalidSchedule();
        uint256 room = unallocated();
        if (totalAmount > room) revert ExceedsUnallocated(totalAmount, room);

        totalAllocated += totalAmount;
        id = _schedules.length;
        _schedules.push(
            Schedule({
                beneficiary: beneficiary,
                start: start,
                cliffDuration: cliffDuration,
                duration: duration,
                revocable: revocable,
                revoked: false,
                revokedAt: 0,
                totalAmount: totalAmount,
                released: 0
            })
        );
        _idsOf[beneficiary].push(id);
        emit ScheduleCreated(id, beneficiary, totalAmount, start, start + cliffDuration, start + duration);
    }

    /// @notice Stops future vesting on a revocable schedule. Moves no tokens: `totalAmount` is frozen at the
    /// amount already vested, so the beneficiary keeps everything earned and the remainder returns to the
    /// unallocated pool for governance to re-grant.
    function revoke(uint256 id) external onlyOwner {
        Schedule storage s = _schedule(id);
        if (!s.revocable) revert NotRevocable(id);
        if (s.revoked) revert AlreadyRevoked(id);

        uint256 vested = vestedAmount(id, block.timestamp);
        uint256 returned = s.totalAmount - vested;
        s.totalAmount = vested;
        s.revoked = true;
        s.revokedAt = uint64(block.timestamp);
        totalAllocated -= returned;
        emit Revoked(id, vested, returned);
    }

    /// @notice Sends part of the unallocated pool to `to` (the timelock's treasury address). Bounded by
    /// `unallocated()`, which never reads `balanceOf`, so this can never touch an allocated grant.
    function reallocateUnallocated(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // Before any grant exists the "unallocated pool" is the whole bucket, so this would be a drain rather
        // than the re-granting path it is meant to be (D-098). Its legitimate uses all follow a schedule.
        if (_schedules.length == 0) revert NoSchedulesYet();
        uint256 room = unallocated();
        if (amount > room) revert ExceedsUnallocated(amount, room);
        reallocated += amount;
        IERC20(writeToken).safeTransfer(to, amount);
        emit Reallocated(to, amount);
    }

    /// @dev Renouncing would make every revocable schedule permanent and strand the unallocated pool.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═════════════════════════════ beneficiaries ═════════════════════════════

    /// @notice Permissionless: the destination is always the schedule's beneficiary.
    function release(uint256 id) external nonReentrant returns (uint256 amount) {
        Schedule storage s = _schedule(id);
        amount = vestedAmount(id, block.timestamp) - s.released;
        if (amount == 0) revert NothingToRelease(id);
        s.released += amount;
        totalReleased += amount;
        address to = s.beneficiary;
        IERC20(writeToken).safeTransfer(to, amount);
        emit Released(id, to, amount);
    }

    /// @notice Two-step beneficiary rotation, initiated by the beneficiary. The timelock has no redirect
    /// power (D-092): a lost key strands the grant, which is the cost of that guarantee.
    function proposeBeneficiary(uint256 id, address to) external {
        Schedule storage s = _schedule(id);
        if (msg.sender != s.beneficiary) revert NotBeneficiary(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        pendingBeneficiary[id] = to;
        emit BeneficiaryProposed(id, s.beneficiary, to);
    }

    function acceptBeneficiary(uint256 id) external {
        Schedule storage s = _schedule(id);
        if (msg.sender != pendingBeneficiary[id]) revert NotPendingBeneficiary(msg.sender);
        address from = s.beneficiary;
        s.beneficiary = msg.sender;
        delete pendingBeneficiary[id];
        _removeId(from, id);
        _idsOf[msg.sender].push(id);
        emit BeneficiaryChanged(id, from, msg.sender);
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @notice WRITE not yet promised to any schedule and not yet returned to the timelock.
    function unallocated() public view returns (uint256) {
        return allocation - reallocated - totalAllocated;
    }

    /// @notice Vested amount at `t`. A revoked schedule is frozen at the amount vested when it was revoked.
    function vestedAmount(uint256 id, uint256 t) public view returns (uint256) {
        Schedule storage s = _schedule(id);
        if (s.revoked) return s.totalAmount;
        if (t < uint256(s.start) + uint256(s.cliffDuration)) return 0;
        if (t >= uint256(s.start) + uint256(s.duration)) return s.totalAmount;
        return Math.mulDiv(s.totalAmount, t - uint256(s.start), uint256(s.duration));
    }

    function releasable(uint256 id) external view returns (uint256) {
        return vestedAmount(id, block.timestamp) - _schedule(id).released;
    }

    function schedules(uint256 id) external view returns (Schedule memory) {
        return _schedule(id);
    }

    function scheduleCount() external view returns (uint256) {
        return _schedules.length;
    }

    function idsOf(address beneficiary) external view returns (uint256[] memory) {
        return _idsOf[beneficiary];
    }

    // ═════════════════════════════ internal ═════════════════════════════

    /// @dev Drops `id` from `who`'s index so a rotated grant is not reported against both addresses.
    function _removeId(address who, uint256 id) internal {
        uint256[] storage ids = _idsOf[who];
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            if (ids[i] != id) continue;
            ids[i] = ids[n - 1];
            ids.pop();
            return;
        }
    }

    function _schedule(uint256 id) internal view returns (Schedule storage) {
        if (id >= _schedules.length) revert UnknownSchedule(id);
        return _schedules[id];
    }
}
