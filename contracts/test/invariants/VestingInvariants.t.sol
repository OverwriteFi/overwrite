// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "../TokenUnitBase.t.sol";
import {VestingHandler} from "./VestingHandler.sol";

/// @dev Invariants for the vesting accounting. Every property is stated against the `allocation` immutable
/// rather than `balanceOf`, which is the point: a donation must not be able to move any of them.
contract VestingInvariants is TokenUnitBaseTest {
    VestingHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[4] memory people = [makeAddr("b1"), makeAddr("b2"), makeAddr("b3"), makeAddr("b4")];
        handler = new VestingHandler(VestingHandler.Deps({write: write, vesting: teamVesting, admin: admin}), people);
        // The handler needs a float of its own to exercise the donation action.
        _grantWrite(address(handler), 1_000e18, 1);
        targetContract(address(handler));
    }

    /// @dev I-23: the allocated total is exactly the sum of the live schedules. `revoke` shrinks a schedule's
    /// `totalAmount` and the total together, so the identity survives revocation.
    function invariant_I23_allocatedEqualsSumOfSchedules() public view {
        assertEq(teamVesting.totalAllocated(), handler.sumScheduleTotals(), "I-23: totalAllocated == sum");
    }

    /// @dev I-24: the three buckets always partition the allocation exactly.
    function invariant_I24_bucketsPartitionTheAllocation() public view {
        assertEq(
            teamVesting.unallocated() + teamVesting.totalAllocated() + teamVesting.reallocated(),
            teamVesting.allocation(),
            "I-24: unallocated + allocated + reallocated == allocation"
        );
    }

    /// @dev I-25: no schedule ever pays out more than it has vested, checked per schedule so an offsetting
    /// error in another cannot hide it.
    function invariant_I25_releasedNeverExceedsVested() public view {
        assertFalse(handler.anyOverRelease(), "I-25: released <= vested, per schedule");
    }

    /// @dev I-26: every outstanding promise is still funded by tokens the contract actually holds.
    function invariant_I26_outstandingIsFunded() public view {
        uint256 outstanding = teamVesting.totalAllocated() - teamVesting.totalReleased();
        assertLe(outstanding, write.balanceOf(address(teamVesting)), "I-26: promises are covered");
    }

    /// @dev I-27: the bookkeeping of releases matches the schedules it came from.
    function invariant_I27_totalReleasedMatchesSchedules() public view {
        assertEq(teamVesting.totalReleased(), handler.sumScheduleReleased(), "I-27: totalReleased == sum");
    }

    function afterInvariant() public {
        emit log_named_uint("calls", handler.calls());
        emit log_named_uint("schedules created", handler.created());
        emit log_named_uint("releases", handler.released());
        emit log_named_uint("revocations", handler.revoked());
        emit log_named_uint("reallocations", handler.reallocations());
    }

    /// @dev Deterministic proof the handler is not vacuous.
    function test_handlerReachesEveryState() public {
        handler.createSchedule(0, 1_000_000e18, 0, 400 days);
        handler.warp(100 days);
        handler.release(0);
        handler.revoke(0);
        handler.reallocate(1_000e18);

        assertGt(handler.created(), 0, "created");
        assertGt(handler.released(), 0, "released");
        assertGt(handler.revoked(), 0, "revoked");
        assertGt(handler.reallocations(), 0, "reallocated");
    }
}
