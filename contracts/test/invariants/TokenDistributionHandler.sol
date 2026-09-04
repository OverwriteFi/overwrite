// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WRITE} from "../../src/WRITE.sol";
import {PointsDistributor} from "../../src/PointsDistributor.sol";
import {LiquidityEscrow} from "../../src/LiquidityEscrow.sol";
import {MerkleTreeLib} from "../utils/MerkleTreeLib.sol";

/// @dev Drives the three genesis-funded distribution contracts under `fail_on_revert = true`. The Merkle tree
/// is fixed at construction so the handler can produce valid proofs; the interesting properties are the
/// accounting ones, which is why every action guards rather than reverts.
contract TokenDistributionHandler is Test {
    struct Deps {
        WRITE write;
        PointsDistributor points;
        LiquidityEscrow escrow;
        address admin;
        address pool;
    }

    WRITE public immutable write;
    PointsDistributor public immutable points;
    LiquidityEscrow public immutable escrow;
    address public immutable admin;
    address public immutable pool;

    address[4] public claimants;
    uint256[4] public amounts;
    bytes32[] internal _leaves;

    uint256 public calls;
    uint256 public roundsOpened;
    uint256 public claimsMade;
    uint256 public sweeps;
    uint256 public funds;
    uint256 public burns;
    uint256 public totalBurned;
    /// @notice The highest round id opened so far; ids are dense from 1.
    uint256 public lastRound;

    modifier count() {
        calls++;
        _;
    }

    constructor(Deps memory d, address[4] memory claimants_, uint256[4] memory amounts_) {
        write = d.write;
        points = d.points;
        escrow = d.escrow;
        admin = d.admin;
        pool = d.pool;
        claimants = claimants_;
        amounts = amounts_;
    }

    /// @dev Leaves for `roundId`. Rebuilt per round because the round id is part of the leaf (D-093).
    function _leavesFor(uint256 roundId) internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            leaves[i] = points.leafHash(roundId, i, claimants[i], amounts[i]);
        }
    }

    function roundTotal() public view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += amounts[i];
        }
    }

    // ───────────────────────────── actions ─────────────────────────────

    function openRound(uint256 windowSeed) external count {
        uint256 id = lastRound + 1;
        uint256 amount = roundTotal();
        if (amount > points.unreserved()) return;
        uint64 start = uint64(block.timestamp);
        uint64 deadline = start + uint64(bound(windowSeed, 1 days, 60 days));

        // README:75 -- `_leavesFor` makes external `leafHash` calls, which would consume the prank.
        bytes32 root = MerkleTreeLib.root(_leavesFor(id));
        vm.prank(admin);
        points.setRound(id, root, amount, start, deadline);
        lastRound = id;
        roundsOpened++;
    }

    function claim(uint256 roundSeed, uint256 indexSeed) external count {
        if (lastRound == 0) return;
        uint256 id = bound(roundSeed, 1, lastRound);
        uint256 i = indexSeed % 4;

        PointsDistributor.Round memory r = points.rounds(id);
        if (r.root == bytes32(0) || r.swept) return;
        if (block.timestamp < r.start || block.timestamp > r.deadline) return;
        if (points.isClaimed(id, i)) return;
        if (amounts[i] > r.amount - r.claimed) return;

        points.claim(id, i, claimants[i], amounts[i], MerkleTreeLib.proof(_leavesFor(id), i));
        claimsMade++;
    }

    function sweep(uint256 roundSeed) external count {
        if (lastRound == 0) return;
        uint256 id = bound(roundSeed, 1, lastRound);
        PointsDistributor.Round memory r = points.rounds(id);
        if (r.root == bytes32(0) || r.swept || block.timestamp <= r.deadline) return;
        points.sweep(id);
        sweeps++;
    }

    function fundPool(uint256 amountSeed) external count {
        if (escrow.pool() == address(0)) return;
        uint256 left = escrow.allocation() - escrow.released();
        if (left == 0) return;
        vm.prank(admin);
        escrow.fund(bound(amountSeed, 1, left));
        funds++;
    }

    /// @dev Burning is the only way supply can move, and it must never take it above MAX_SUPPLY.
    function burn(uint256 seed, uint256 amountSeed) external count {
        address a = claimants[seed % 4];
        uint256 bal = write.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(a);
        write.burn(amount);
        totalBurned += amount;
        burns++;
    }

    /// @dev A donation must not expand what governance may commit.
    function donate(uint256 seed, uint256 amountSeed) external count {
        address a = claimants[seed % 4];
        uint256 bal = write.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        write.transfer(address(points), bound(amountSeed, 1, bal));
    }

    function warp(uint256 dt) external count {
        vm.warp(block.timestamp + bound(dt, 1 hours, 30 days));
    }

    // ───────────────────────────── views ─────────────────────────────

    function sumRoundAmounts() external view returns (uint256 total) {
        for (uint256 id = 1; id <= lastRound; ++id) {
            total += points.rounds(id).amount;
        }
    }

    function sumRoundClaimed() external view returns (uint256 total) {
        for (uint256 id = 1; id <= lastRound; ++id) {
            total += points.rounds(id).claimed;
        }
    }
}
