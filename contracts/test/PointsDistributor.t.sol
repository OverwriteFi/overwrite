// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "./TokenUnitBase.t.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {MerkleTreeLib} from "./utils/MerkleTreeLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PointsDistributorTest is TokenUnitBaseTest {
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint256 internal constant R1 = 1;
    uint256 internal constant ROUND_AMOUNT = 10_000e18;

    address[4] internal claimants;
    uint256[4] internal amounts;
    bytes32[] internal leaves;

    function setUp() public override {
        super.setUp();
        claimants = [alice, bob, carol, dave];
        amounts = [uint256(1_000e18), 2_000e18, 3_000e18, 4_000e18]; // sums to ROUND_AMOUNT
        leaves = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            leaves[i] = points.leafHash(R1, i, claimants[i], amounts[i]);
        }
    }

    function _openRound(uint256 roundId, uint256 amount) internal returns (bytes32 root) {
        root = MerkleTreeLib.root(leaves);
        vm.prank(admin);
        points.setRound(roundId, root, amount, uint64(block.timestamp), uint64(block.timestamp + 30 days));
    }

    function _claim(uint256 i) internal {
        points.claim(R1, i, claimants[i], amounts[i], MerkleTreeLib.proof(leaves, i));
    }

    // ═════════════════════════════ wiring ═════════════════════════════

    function test_allocationAndFunding() public view {
        assertEq(points.allocation(), 100_000_000e18);
        assertEq(write.balanceOf(address(points)), 100_000_000e18);
        assertEq(points.unreserved(), 100_000_000e18);
        assertEq(points.treasury(), treasury);
    }

    // ═════════════════════════════ rounds ═════════════════════════════

    function test_setRound_onlyOwner() public {
        bytes32 root = MerkleTreeLib.root(leaves);
        uint64 start = uint64(block.timestamp);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        points.setRound(R1, root, ROUND_AMOUNT, start, start + 30 days);
    }

    function test_setRound_reservesAgainstTheBucket() public {
        _openRound(R1, ROUND_AMOUNT);
        assertEq(points.unreserved(), 100_000_000e18 - ROUND_AMOUNT);
        assertEq(points.outstanding(), ROUND_AMOUNT);
    }

    function test_setRound_revertsOnOverCommit() public {
        bytes32 root = MerkleTreeLib.root(leaves);
        uint64 start = uint64(block.timestamp);
        uint256 tooMuch = 100_000_000e18 + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.ExceedsUnreserved.selector, tooMuch, 100_000_000e18));
        points.setRound(R1, root, tooMuch, start, start + 30 days);
    }

    function test_setRound_amendableOnlyBeforeStart() public {
        bytes32 root = MerkleTreeLib.root(leaves);
        uint64 start = uint64(block.timestamp + 1 days);
        vm.prank(admin);
        points.setRound(R1, root, ROUND_AMOUNT, start, start + 30 days);

        // Still amendable while the round has not opened; the reservation is re-computed, not doubled.
        vm.prank(admin);
        points.setRound(R1, root, ROUND_AMOUNT * 2, start, start + 30 days);
        assertEq(points.outstanding(), ROUND_AMOUNT * 2);

        vm.warp(start);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundLive.selector, R1));
        points.setRound(R1, root, ROUND_AMOUNT, start, start + 30 days);
    }

    function test_setRound_revertsOnBadWindow() public {
        bytes32 root = MerkleTreeLib.root(leaves);
        uint64 start = uint64(block.timestamp);
        vm.startPrank(admin);
        vm.expectRevert(PointsDistributor.InvalidWindow.selector);
        points.setRound(R1, root, ROUND_AMOUNT, start, start); // deadline == start
        vm.expectRevert(PointsDistributor.InvalidWindow.selector);
        points.setRound(R1, root, ROUND_AMOUNT, start - 1, start + 1 days); // start in the past
        vm.stopPrank();
    }

    // ═════════════════════════════ claiming ═════════════════════════════

    function test_claim_validProofPaysTheAccount() public {
        _openRound(R1, ROUND_AMOUNT);
        _claim(1);
        assertEq(write.balanceOf(bob), 2_000e18);
        assertTrue(points.isClaimed(R1, 1));
        assertFalse(points.isClaimed(R1, 0));
        assertEq(points.paidOut(), 2_000e18);
        assertEq(points.rounds(R1).claimed, 2_000e18);
    }

    /// @dev Permissionless, but the destination is always the leaf's `account`, never the caller.
    function test_claim_paysAccountNotCaller() public {
        _openRound(R1, ROUND_AMOUNT);
        vm.prank(dave);
        points.claim(R1, 0, alice, amounts[0], MerkleTreeLib.proof(leaves, 0));
        assertEq(write.balanceOf(alice), 1_000e18);
        assertEq(write.balanceOf(dave), 0);
    }

    function test_claim_revertsOnBadProof() public {
        _openRound(R1, ROUND_AMOUNT);
        vm.expectRevert(PointsDistributor.InvalidProof.selector);
        points.claim(R1, 0, alice, amounts[0], MerkleTreeLib.proof(leaves, 1));
    }

    function test_claim_revertsOnTamperedAmount() public {
        _openRound(R1, ROUND_AMOUNT);
        vm.expectRevert(PointsDistributor.InvalidProof.selector);
        points.claim(R1, 0, alice, amounts[0] + 1, MerkleTreeLib.proof(leaves, 0));
    }

    /// @dev The leaf commits to `roundId`, so a proof from one round cannot be replayed into another.
    function test_claim_revertsOnCrossRoundReplay() public {
        _openRound(R1, ROUND_AMOUNT);
        bytes32 root = MerkleTreeLib.root(leaves);
        vm.prank(admin);
        points.setRound(2, root, ROUND_AMOUNT, uint64(block.timestamp), uint64(block.timestamp + 30 days));

        vm.expectRevert(PointsDistributor.InvalidProof.selector);
        points.claim(2, 0, alice, amounts[0], MerkleTreeLib.proof(leaves, 0));
    }

    function test_claim_revertsWhenAlreadyClaimed() public {
        _openRound(R1, ROUND_AMOUNT);
        _claim(0);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.AlreadyClaimed.selector, R1, 0));
        _claim(0);
    }

    function test_claim_revertsOutsideTheWindow() public {
        bytes32 root = MerkleTreeLib.root(leaves);
        uint64 start = uint64(block.timestamp + 1 days);
        vm.prank(admin);
        points.setRound(R1, root, ROUND_AMOUNT, start, start + 10 days);

        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundNotOpen.selector, R1));
        _claim(0);

        vm.warp(uint256(start) + 10 days + 1);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundNotOpen.selector, R1));
        _claim(0);
    }

    function test_claim_revertsOnUnsetRound() public {
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundUnset.selector, uint256(99)));
        points.claim(99, 0, alice, 1e18, new bytes32[](0));
    }

    /// @dev An over-issuing root cannot reach beyond its own round's allocation.
    function test_claim_roundExhaustedConfinesAnOverIssuingRoot() public {
        _openRound(R1, 3_500e18); // less than the leaves sum to
        _claim(0); // 1 000 fits
        _claim(1); // 2 000 fits, 500 left
        bytes32[] memory proof = MerkleTreeLib.proof(leaves, 3);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundExhausted.selector, R1, 4_000e18, 500e18));
        points.claim(R1, 3, dave, amounts[3], proof); // 4 000 does not
        assertEq(write.balanceOf(dave), 0);
        assertLe(points.rounds(R1).claimed, points.rounds(R1).amount, "confined to its own allocation");
    }

    // ═════════════════════════════ sweep ═════════════════════════════

    function test_sweep_onlyAfterDeadline() public {
        _openRound(R1, ROUND_AMOUNT);
        uint64 deadline = points.rounds(R1).deadline;
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundNotExpired.selector, R1, deadline));
        points.sweep(R1);
    }

    function test_sweep_sendsTheRemainderToTreasury() public {
        _openRound(R1, ROUND_AMOUNT);
        _claim(0); // 1 000 claimed, 9 000 unclaimed
        vm.warp(uint256(points.rounds(R1).deadline) + 1);

        uint256 swept = points.sweep(R1);
        assertEq(swept, 9_000e18);
        assertEq(write.balanceOf(treasury), 9_000e18);
        assertEq(points.outstanding(), 0);
        assertEq(points.unreserved(), 100_000_000e18 - ROUND_AMOUNT);
    }

    function test_sweep_thenClaimReverts() public {
        _openRound(R1, ROUND_AMOUNT);
        vm.warp(uint256(points.rounds(R1).deadline) + 1);
        points.sweep(R1);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundSwept.selector, R1));
        _claim(0);
    }

    function test_sweep_cannotBeRepeated() public {
        _openRound(R1, ROUND_AMOUNT);
        vm.warp(uint256(points.rounds(R1).deadline) + 1);
        points.sweep(R1);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundSwept.selector, R1));
        points.sweep(R1);
    }

    // ═════════════════════════════ accounting ═════════════════════════════

    /// @dev A donation must not expand what governance may commit (D-093).
    function test_donationDoesNotExpandTheUnreservedPool() public {
        uint256 before = points.unreserved();
        _openRound(R1, ROUND_AMOUNT);
        _claim(0);
        vm.prank(alice);
        write.transfer(address(points), 500e18);
        assertEq(points.unreserved(), before - ROUND_AMOUNT, "derives from `allocation`, not `balanceOf`");
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        points.setTreasury(alice);
        vm.prank(admin);
        points.setTreasury(bob);
        assertEq(points.treasury(), bob);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(PointsDistributor.RenounceDisabled.selector);
        points.renounceOwnership();
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    function testFuzz_bitmapMarksExactlyOneIndex(uint256 indexSeed) public {
        _openRound(R1, ROUND_AMOUNT);
        uint256 i = bound(indexSeed, 0, 3);
        _claim(i);
        for (uint256 j; j < 4; ++j) {
            assertEq(points.isClaimed(R1, j), j == i, "only the claimed index is marked");
        }
    }

    function testFuzz_claimedNeverExceedsAllocation(uint8 mask) public {
        _openRound(R1, ROUND_AMOUNT);
        uint256 expected;
        for (uint256 i; i < 4; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            _claim(i);
            expected += amounts[i];
        }
        assertEq(points.rounds(R1).claimed, expected);
        assertLe(points.rounds(R1).claimed, points.rounds(R1).amount);
        assertEq(points.paidOut(), expected);
        assertEq(
            points.allocation() - points.paidOut() - points.sweptTotal() - points.outstanding(), points.unreserved()
        );
        assertEq(write.balanceOf(address(points)), points.allocation() - expected);
    }
}
