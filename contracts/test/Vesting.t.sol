// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "./TokenUnitBase.t.sol";
import {Vesting} from "../src/Vesting.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VestingTest is TokenUnitBaseTest {
    uint64 internal constant TEAM_CLIFF = 365 days;
    uint64 internal constant VEST_DURATION = 1095 days; // 36 months
    uint256 internal constant TEAM_GRANT = 60_000_000e18;

    function _teamSchedule(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(admin);
        id = teamVesting.createSchedule(who, uint64(block.timestamp), TEAM_CLIFF, VEST_DURATION, amount, true);
    }

    function _treasurySchedule() internal returns (uint256 id) {
        vm.prank(admin);
        id = treasuryVesting.createSchedule(treasury, uint64(block.timestamp), 0, VEST_DURATION, 200_000_000e18, false);
    }

    // ═════════════════════════════ construction ═════════════════════════════

    function test_twoInstancesWithDifferentPowers() public view {
        assertEq(treasuryVesting.allocation(), 200_000_000e18);
        assertFalse(treasuryVesting.allowRevocable(), "treasury tokens can never be revoked");
        assertEq(teamVesting.allocation(), 150_000_000e18);
        assertTrue(teamVesting.allowRevocable());
        assertEq(treasuryVesting.unallocated(), 200_000_000e18);
        assertEq(teamVesting.unallocated(), 150_000_000e18);
    }

    // ═════════════════════════════ createSchedule ═════════════════════════════

    function test_createSchedule_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        teamVesting.createSchedule(teamMember, uint64(block.timestamp), TEAM_CLIFF, VEST_DURATION, 1e18, true);
    }

    /// @dev The treasury instance is structurally incapable of accepting a revocable grant (D-062).
    function test_createSchedule_treasuryInstanceRejectsRevocable() public {
        vm.prank(admin);
        vm.expectRevert(Vesting.RevocableNotAllowed.selector);
        treasuryVesting.createSchedule(treasury, uint64(block.timestamp), 0, VEST_DURATION, 1e18, true);
    }

    function test_createSchedule_revertsOnOverAllocation() public {
        _teamSchedule(teamMember, 150_000_000e18);
        assertEq(teamVesting.unallocated(), 0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Vesting.ExceedsUnallocated.selector, 1, 0));
        teamVesting.createSchedule(alice, uint64(block.timestamp), TEAM_CLIFF, VEST_DURATION, 1, true);
    }

    /// @dev Backdating `start` to TGE is legal, but a schedule whose cliff has already passed would unlock a
    /// large grant instantly in a single proposal (D-091).
    function test_createSchedule_revertsWhenCliffAlreadyPassed() public {
        vm.warp(block.timestamp + 400 days);
        uint64 start = uint64(block.timestamp - 400 days);
        vm.prank(admin);
        vm.expectRevert(Vesting.InvalidSchedule.selector);
        teamVesting.createSchedule(teamMember, start, TEAM_CLIFF, VEST_DURATION, TEAM_GRANT, true);
    }

    function test_createSchedule_backdatingToTgeIsLegal() public {
        vm.warp(block.timestamp + 100 days);
        uint64 start = uint64(block.timestamp - 100 days);
        vm.prank(admin);
        uint256 id = teamVesting.createSchedule(teamMember, start, TEAM_CLIFF, VEST_DURATION, TEAM_GRANT, true);
        assertEq(teamVesting.vestedAmount(id, block.timestamp), 0, "still inside the cliff");
    }

    function test_createSchedule_revertsOnBadShape() public {
        vm.startPrank(admin);
        vm.expectRevert(Vesting.ZeroAddress.selector);
        teamVesting.createSchedule(address(0), uint64(block.timestamp), TEAM_CLIFF, VEST_DURATION, 1e18, true);
        vm.expectRevert(Vesting.ZeroAmount.selector);
        teamVesting.createSchedule(teamMember, uint64(block.timestamp), TEAM_CLIFF, VEST_DURATION, 0, true);
        vm.expectRevert(Vesting.InvalidSchedule.selector);
        teamVesting.createSchedule(teamMember, uint64(block.timestamp), VEST_DURATION + 1, VEST_DURATION, 1e18, true);
        vm.stopPrank();
    }

    // ═════════════════════════════ vesting curve ═════════════════════════════

    function test_vested_zeroBeforeCliff() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        assertEq(teamVesting.vestedAmount(id, block.timestamp), 0);
        assertEq(teamVesting.vestedAmount(id, block.timestamp + TEAM_CLIFF - 1), 0);
    }

    /// @dev "12-month cliff, 36-month linear": nothing until month 12, then 12/36 unlocks in a lump.
    function test_vested_lumpAtCliffThenLinear() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        uint256 start = block.timestamp;

        assertEq(teamVesting.vestedAmount(id, start + TEAM_CLIFF), TEAM_GRANT * TEAM_CLIFF / VEST_DURATION);
        assertEq(teamVesting.vestedAmount(id, start + VEST_DURATION / 2), TEAM_GRANT / 2);
        assertEq(teamVesting.vestedAmount(id, start + VEST_DURATION), TEAM_GRANT);
        assertEq(teamVesting.vestedAmount(id, start + VEST_DURATION * 5), TEAM_GRANT, "clamped at the end");
    }

    function test_vested_treasuryHasNoCliff() public {
        uint256 id = _treasurySchedule();
        uint256 start = block.timestamp;
        assertEq(treasuryVesting.vestedAmount(id, start), 0);
        assertEq(treasuryVesting.vestedAmount(id, start + 1 days), 200_000_000e18 * 1 days / VEST_DURATION);
        assertGt(treasuryVesting.vestedAmount(id, start + 1 days), 0, "streams from day one");
    }

    // ═════════════════════════════ release ═════════════════════════════

    function test_release_permissionlessButPaysTheBeneficiary() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        vm.warp(block.timestamp + VEST_DURATION / 2);

        vm.prank(alice); // anyone may poke it
        uint256 amount = teamVesting.release(id);
        assertEq(amount, TEAM_GRANT / 2);
        assertEq(write.balanceOf(teamMember), TEAM_GRANT / 2, "funds always go to the beneficiary");
        assertEq(write.balanceOf(alice), 0);
        assertEq(teamVesting.totalReleased(), amount);
    }

    function test_release_revertsWithNothingVested() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        vm.expectRevert(abi.encodeWithSelector(Vesting.NothingToRelease.selector, id));
        teamVesting.release(id);
    }

    function test_release_neverExceedsVestedAcrossManyCalls() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 200 days);
            // The first steps land inside the 365-day cliff, where there is nothing to release.
            if (teamVesting.releasable(id) > 0) total += teamVesting.release(id);
            assertLe(total, teamVesting.vestedAmount(id, block.timestamp));
        }
        vm.warp(block.timestamp + VEST_DURATION);
        if (teamVesting.releasable(id) > 0) total += teamVesting.release(id);
        assertEq(total, TEAM_GRANT, "the whole grant is released exactly once, in pieces");
    }

    // ═════════════════════════════ revoke ═════════════════════════════

    function test_revoke_onlyOwner() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        teamVesting.revoke(id);
    }

    function test_revoke_revertsForNonRevocableTreasurySchedule() public {
        uint256 id = _treasurySchedule();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Vesting.NotRevocable.selector, id));
        treasuryVesting.revoke(id);
    }

    /// @dev Revoke moves no tokens: it freezes `totalAmount` at the vested figure, so the beneficiary keeps
    /// everything earned and the remainder returns to the unallocated pool.
    function test_revoke_freezesAndLeavesVestedPortionClaimable() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        vm.warp(block.timestamp + VEST_DURATION / 2);
        uint256 vested = teamVesting.vestedAmount(id, block.timestamp);

        vm.prank(admin);
        teamVesting.revoke(id);
        assertEq(teamVesting.vestedAmount(id, block.timestamp), vested, "frozen at revoke time");

        vm.warp(block.timestamp + VEST_DURATION);
        assertEq(teamVesting.vestedAmount(id, block.timestamp), vested, "and it stays frozen");

        uint256 released = teamVesting.release(id);
        assertEq(released, vested, "the earned half is still claimable");
        assertEq(write.balanceOf(teamMember), vested);
    }

    function test_revoke_returnsUnvestedToTheUnallocatedPool() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        assertEq(teamVesting.unallocated(), 150_000_000e18 - TEAM_GRANT);
        vm.warp(block.timestamp + VEST_DURATION / 2);
        uint256 vested = teamVesting.vestedAmount(id, block.timestamp);

        vm.prank(admin);
        teamVesting.revoke(id);
        assertEq(teamVesting.totalAllocated(), vested, "allocation shrinks to what was earned");
        assertEq(teamVesting.unallocated(), 150_000_000e18 - vested, "the rest is re-grantable");
    }

    function test_revoke_cannotBeRepeated() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        vm.startPrank(admin);
        teamVesting.revoke(id);
        vm.expectRevert(abi.encodeWithSelector(Vesting.AlreadyRevoked.selector, id));
        teamVesting.revoke(id);
        vm.stopPrank();
    }

    // ═════════════════════════════ reallocation and rotation ═════════════════════════════

    function test_reallocateUnallocated_boundedByThePool() public {
        _teamSchedule(teamMember, TEAM_GRANT);
        uint256 free = teamVesting.unallocated();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Vesting.ExceedsUnallocated.selector, free + 1, free));
        teamVesting.reallocateUnallocated(treasury, free + 1);

        vm.prank(admin);
        teamVesting.reallocateUnallocated(treasury, free);
        assertEq(write.balanceOf(treasury), free);
        assertEq(teamVesting.unallocated(), 0);
    }

    /// @dev A donation must not expand what governance may allocate or reallocate (D-090).
    function test_donationDoesNotExpandTheUnallocatedPool() public {
        uint256 before = teamVesting.unallocated();
        _grantWrite(alice, 1_000e18, 1);
        vm.prank(alice);
        write.transfer(address(teamVesting), 1_000e18);
        assertEq(teamVesting.unallocated(), before, "accounting derives from `allocation`, not `balanceOf`");
    }

    function test_beneficiaryRotationIsTwoStepAndSelfInitiated() public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Vesting.NotBeneficiary.selector, admin));
        teamVesting.proposeBeneficiary(id, alice);

        vm.prank(teamMember);
        teamVesting.proposeBeneficiary(id, alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Vesting.NotPendingBeneficiary.selector, bob));
        teamVesting.acceptBeneficiary(id);

        vm.prank(alice);
        teamVesting.acceptBeneficiary(id);
        assertEq(teamVesting.schedules(id).beneficiary, alice);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(Vesting.RenounceDisabled.selector);
        teamVesting.renounceOwnership();
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    function testFuzz_vestedIsMonotonicAndCapped(uint256[8] memory steps) public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        uint256 last;
        for (uint256 i; i < 8; ++i) {
            vm.warp(block.timestamp + bound(steps[i], 0, 300 days));
            uint256 v = teamVesting.vestedAmount(id, block.timestamp);
            assertGe(v, last, "vesting never goes backwards");
            assertLe(v, TEAM_GRANT, "and never exceeds the grant");
            last = v;
        }
    }

    function testFuzz_releasedNeverExceedsVested(uint256[8] memory steps) public {
        uint256 id = _teamSchedule(teamMember, TEAM_GRANT);
        for (uint256 i; i < 8; ++i) {
            vm.warp(block.timestamp + bound(steps[i], 0, 300 days));
            uint256 vested = teamVesting.vestedAmount(id, block.timestamp);
            if (teamVesting.releasable(id) > 0) teamVesting.release(id);
            assertLe(teamVesting.schedules(id).released, vested);
            assertEq(write.balanceOf(teamMember), teamVesting.schedules(id).released);
        }
    }

    function testFuzz_allocationIsAlwaysCoveredByTheBalance(uint256 grant, uint256 dt) public {
        grant = bound(grant, 1e18, 150_000_000e18);
        uint256 id = _teamSchedule(teamMember, grant);
        vm.warp(block.timestamp + bound(dt, 0, 2000 days));
        if (teamVesting.releasable(id) > 0) teamVesting.release(id);

        uint256 outstanding = teamVesting.totalAllocated() - teamVesting.totalReleased();
        assertLe(outstanding, write.balanceOf(address(teamVesting)), "every promise is still funded");
    }
}
