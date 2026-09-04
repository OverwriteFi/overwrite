// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IWriteHolder} from "./interfaces/IWriteHolder.sol";

/// @title PointsDistributor
/// @notice Merkle claim of the 100 000 000 WRITE points bucket (docs/TOKENOMICS.md), which serves both the
/// retroactive points airdrop and the MM/curator bond grants. Points themselves are computed entirely
/// off-chain (D-013, the `points/` indexer); this contract is only the claim leg.
/// @dev Rounds, not a single root (D-093): one root cannot be replaced once claiming has started, and the two
/// purposes need separate distributions. A round is amendable only before it opens. The leaf commits to
/// `roundId`, so a proof cannot be replayed into another round, and it is double-hashed so an internal node
/// can never be presented as a leaf. `unreserved()` derives from the `allocation` immutable and never from
/// `balanceOf`, so a donation cannot expand what governance may commit.
contract PointsDistributor is Ownable2Step, ReentrancyGuard, IWriteHolder {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants ─────────────────────────────

    /// @inheritdoc IWriteHolder
    uint256 public constant allocation = 100_000_000e18;

    // ───────────────────────────── types ─────────────────────────────

    struct Round {
        bytes32 root;
        uint256 amount;
        uint256 claimed;
        uint64 start;
        uint64 deadline;
        bool swept;
    }

    // ───────────────────────────── state ─────────────────────────────

    address public writeToken;
    address public treasury;
    mapping(uint256 roundId => Round) internal _rounds;
    mapping(uint256 roundId => mapping(uint256 word => uint256)) internal _claimedBitMap;
    /// @notice Claimed and transferred out.
    uint256 public paidOut;
    /// @notice Sent to `treasury` by `sweep` after a deadline.
    uint256 public sweptTotal;
    /// @notice Committed to live rounds and not yet claimed or swept.
    uint256 public outstanding;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error AlreadySet();
    error NotAContract(address target);
    error Underfunded(uint256 have, uint256 want);
    error RoundLive(uint256 roundId);
    error RoundUnset(uint256 roundId);
    error RoundSwept(uint256 roundId);
    error RoundNotOpen(uint256 roundId);
    error RoundNotExpired(uint256 roundId, uint64 deadline);
    error RoundExhausted(uint256 roundId, uint256 want, uint256 left);
    error ExceedsUnreserved(uint256 want, uint256 have);
    error InvalidWindow();
    error AlreadyClaimed(uint256 roundId, uint256 index);
    error InvalidProof();
    error RenounceDisabled();

    // ───────────────────────────── events ─────────────────────────────

    event WriteTokenSet(address indexed writeToken);
    event RoundSet(uint256 indexed roundId, bytes32 root, uint256 amount, uint64 start, uint64 deadline);
    event Claimed(uint256 indexed roundId, uint256 indexed index, address indexed account, uint256 amount);
    event Swept(uint256 indexed roundId, address indexed treasury, uint256 amount);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address owner_, address treasury_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
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

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit ParameterChanged(address(this), "treasury", uint256(uint160(treasury)), uint256(uint160(treasury_)));
        treasury = treasury_;
    }

    /// @notice Creates or amends a round. Amendable only while `block.timestamp < start`, i.e. while nothing
    /// can have been claimed yet; after that the root and the amount are fixed.
    /// @dev The off-chain generator MUST assert that the leaf amounts sum to `amount` (D-093). On-chain,
    /// `RoundExhausted` confines an over-issuing root to its own round.
    function setRound(uint256 roundId, bytes32 root, uint256 amount, uint64 start, uint64 deadline) external onlyOwner {
        if (writeToken == address(0)) revert ZeroAddress();
        if (root == bytes32(0)) revert RoundUnset(roundId);
        if (amount == 0) revert ZeroAmount();
        if (start < block.timestamp || deadline <= start) revert InvalidWindow();

        Round storage r = _rounds[roundId];
        if (r.root != bytes32(0)) {
            if (block.timestamp >= r.start) revert RoundLive(roundId);
            outstanding -= r.amount; // un-commit the superseded amount before re-checking the room
        }
        uint256 room = unreserved();
        if (amount > room) revert ExceedsUnreserved(amount, room);

        outstanding += amount;
        r.root = root;
        r.amount = amount;
        r.start = start;
        r.deadline = deadline;
        emit RoundSet(roundId, root, amount, start, deadline);
    }

    /// @dev Renouncing would make every future round impossible and strand the unreserved balance.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═════════════════════════════ permissionless ═════════════════════════════

    /// @notice Claims `amount` for `account`. Callable by anyone; the destination is always `account`.
    function claim(uint256 roundId, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Round storage r = _rounds[roundId];
        if (r.root == bytes32(0)) revert RoundUnset(roundId);
        if (r.swept) revert RoundSwept(roundId);
        if (block.timestamp < r.start || block.timestamp > r.deadline) revert RoundNotOpen(roundId);
        if (isClaimed(roundId, index)) revert AlreadyClaimed(roundId, index);

        bytes32 leaf = leafHash(roundId, index, account, amount);
        if (!MerkleProof.verifyCalldata(proof, r.root, leaf)) revert InvalidProof();

        uint256 left = r.amount - r.claimed;
        if (amount > left) revert RoundExhausted(roundId, amount, left);

        _setClaimed(roundId, index);
        r.claimed += amount;
        outstanding -= amount;
        paidOut += amount;
        IERC20(writeToken).safeTransfer(account, amount);
        emit Claimed(roundId, index, account, amount);
    }

    /// @notice After the deadline, sends whatever the round did not distribute to `treasury`.
    function sweep(uint256 roundId) external nonReentrant returns (uint256 amount) {
        Round storage r = _rounds[roundId];
        if (r.root == bytes32(0)) revert RoundUnset(roundId);
        if (r.swept) revert RoundSwept(roundId);
        if (block.timestamp <= r.deadline) revert RoundNotExpired(roundId, r.deadline);

        amount = r.amount - r.claimed;
        r.swept = true;
        outstanding -= amount;
        sweptTotal += amount;
        address to = treasury;
        if (amount != 0) IERC20(writeToken).safeTransfer(to, amount);
        emit Swept(roundId, to, amount);
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @notice WRITE not paid out, not swept and not committed to a live round.
    function unreserved() public view returns (uint256) {
        return allocation - paidOut - sweptTotal - outstanding;
    }

    /// @notice The leaf a proof must open to. Double-hashed so an internal node can never pose as a leaf, and
    /// scoped to `roundId` so a proof cannot be replayed into another round. This encoding is the integration
    /// contract with the off-chain `points/` generator (SPEC §13, D-093).
    function leafHash(uint256 roundId, uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(roundId, index, account, amount))));
    }

    function isClaimed(uint256 roundId, uint256 index) public view returns (bool) {
        uint256 word = index >> 8;
        uint256 bit = index & 0xff;
        // `1 << bit` is the intended bitmap mask, not a transposed shift; `bit` is bounded to [0, 255].
        // forge-lint: disable-next-line(incorrect-shift)
        return _claimedBitMap[roundId][word] & (1 << bit) != 0;
    }

    function rounds(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    // ═════════════════════════════ internal ═════════════════════════════

    function _setClaimed(uint256 roundId, uint256 index) internal {
        uint256 word = index >> 8;
        uint256 bit = index & 0xff;
        // See `isClaimed`: the literal is the mask, not the shift amount.
        // forge-lint: disable-next-line(incorrect-shift)
        _claimedBitMap[roundId][word] |= (1 << bit);
    }
}
