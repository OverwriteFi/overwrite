// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IWriteHolder} from "./interfaces/IWriteHolder.sol";

/// @title LiquidityEscrow
/// @notice Holds the 250 000 000 WRITE launch liquidity (docs/TOKENOMICS.md) and can send it to exactly one
/// destination, the launchpad pool, set by the timelock. There is no rescue, no arbitrary destination and no
/// second transfer target, per SPEC §15 ("no contract that holds user funds has a sweep, rescue or
/// arbitrary-call function").
/// @dev `setPool` refuses a raw AMM pool (D-094): a bare `transfer` of 250 M WRITE into a Uniswap v3 pool is
/// a donation the next swap takes — 25 % of supply gone in one block — and `onlyOwner` does not help, because
/// the timelock is the one that would make the typo. The destination must be a launchpad or locker contract
/// that pulls or accounts for the deposit. `renounceOwnership` is disabled: renouncing would strand the
/// balance forever.
contract LiquidityEscrow is Ownable2Step, ReentrancyGuard, IWriteHolder {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants ─────────────────────────────

    /// @inheritdoc IWriteHolder
    uint256 public constant allocation = 250_000_000e18;

    // ───────────────────────────── state ─────────────────────────────

    address public writeToken;
    /// @notice Re-pointable while `released == 0`, frozen after the first `fund` (D-094).
    address public pool;
    uint256 public released;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error AlreadySet();
    error NotAContract(address target);
    error PoolIsRawAmm(address candidate);
    error PoolFrozen(uint256 released);
    error PoolNotSet();
    error Underfunded(uint256 have, uint256 want);
    error ExceedsAllocation(uint256 released, uint256 cap);
    error RenounceDisabled();

    // ───────────────────────────── events ─────────────────────────────

    event WriteTokenSet(address indexed writeToken);
    event PoolSet(address indexed pool);
    event Funded(address indexed pool, uint256 amount, uint256 released);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address owner_) Ownable(owner_) {}

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @inheritdoc IWriteHolder
    /// @dev One-shot wiring (D-044, D-060). The funding check is `>=`, never `==`, so a donation cannot brick
    /// it (D-062); every bound below derives from `allocation`, never from `balanceOf`.
    function setWriteToken(address write_) external onlyOwner {
        if (write_ == address(0)) revert ZeroAddress();
        if (writeToken != address(0)) revert AlreadySet();
        if (write_.code.length == 0) revert NotAContract(write_);
        uint256 bal = IERC20(write_).balanceOf(address(this));
        if (bal < allocation) revert Underfunded(bal, allocation);
        writeToken = write_;
        emit WriteTokenSet(write_);
    }

    /// @notice Sets the single legal destination. Re-pointable until the first `fund`, then frozen.
    function setPool(address pool_) external onlyOwner {
        if (writeToken == address(0) || pool_ == address(0)) revert ZeroAddress();
        if (released != 0) revert PoolFrozen(released);
        if (pool_.code.length == 0) revert NotAContract(pool_);
        // A self- or token-directed pool would park 250 M unreachably: both have code and neither exposes a
        // pair getter, so the shape probe alone would wave them through (D-098).
        if (pool_ == address(this) || pool_ == writeToken) revert PoolIsRawAmm(pool_);
        if (_isRawAmm(pool_)) revert PoolIsRawAmm(pool_);
        pool = pool_;
        emit PoolSet(pool_);
    }

    /// @notice Sends `amount` WRITE to `pool`. The destination is structural: there is no other transfer.
    function fund(uint256 amount) public onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        address to = pool;
        if (to == address(0)) revert PoolNotSet();
        uint256 newReleased = released + amount;
        if (newReleased > allocation) revert ExceedsAllocation(newReleased, allocation);
        released = newReleased;
        IERC20(writeToken).safeTransfer(to, amount);
        emit Funded(to, amount, newReleased);
    }

    function fundAll() external {
        fund(allocation - released);
    }

    /// @dev Renouncing would strand the escrow's balance forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═════════════════════════════ internal ═════════════════════════════

    /// @dev True when `candidate` looks like a bare AMM pool holding WRITE as one of its pair tokens, i.e. a
    /// contract where a plain `transfer` is a donation rather than a deposit (D-094). Decoded as `uint256`
    /// so a non-conforming return value can never revert this probe.
    /// This recognises the Uniswap v2/v3 `token0()/token1()` shape and the Curve `coins(uint256)` shape. It is
    /// a typo guard, not a proof of safety: a venue that wraps a pool, or any shape not probed here, still has
    /// to be verified by whoever writes the timelock proposal (D-098).
    function _isRawAmm(address candidate) internal view returns (bool) {
        if (_probeHoldsWrite(candidate, abi.encodeWithSignature("token0()"))) return true;
        if (_probeHoldsWrite(candidate, abi.encodeWithSignature("token1()"))) return true;
        if (_probeHoldsWrite(candidate, abi.encodeWithSignature("coins(uint256)", uint256(0)))) return true;
        if (_probeHoldsWrite(candidate, abi.encodeWithSignature("coins(uint256)", uint256(1)))) return true;
        return false;
    }

    function _probeHoldsWrite(address candidate, bytes memory call_) internal view returns (bool) {
        (bool ok, bytes memory data) = candidate.staticcall(call_);
        if (!ok || data.length < 32) return false;
        return address(uint160(abi.decode(data, (uint256)))) == writeToken;
    }
}
