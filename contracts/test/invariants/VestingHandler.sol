// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WRITE} from "../../src/WRITE.sol";
import {Vesting} from "../../src/Vesting.sol";

/// @dev Drives the team Vesting instance under `fail_on_revert = true`: every action early-returns on a
/// guard. The properties worth proving here are all accounting ones, so the handler deliberately never
/// touches the token directly — only the contract does.
contract VestingHandler is Test {
    struct Deps {
        WRITE write;
        Vesting vesting;
        address admin;
    }

    WRITE public immutable write;
    Vesting public immutable vesting;
    address public immutable admin;

    address[4] public beneficiaries;

    uint256 public calls;
    uint256 public created;
    uint256 public released;
    uint256 public revoked;
    uint256 public reallocations;
    uint256 public donations;

    modifier count() {
        calls++;
        _;
    }

    constructor(Deps memory d, address[4] memory beneficiaries_) {
        write = d.write;
        vesting = d.vesting;
        admin = d.admin;
        beneficiaries = beneficiaries_;
    }

    function createSchedule(uint256 seed, uint256 amountSeed, uint256 cliffSeed, uint256 durationSeed) external count {
        uint256 room = vesting.unallocated();
        if (room == 0) return;
        uint256 amount = bound(amountSeed, 1, room);
        // The contract requires a real term ahead of the grant and `cliff < duration` (D-098).
        uint64 minTerm = vesting.MIN_REMAINING_TERM();
        uint64 duration = uint64(bound(durationSeed, uint256(minTerm) + 1 days, 2000 days));
        uint64 cliff = uint64(bound(cliffSeed, 0, duration - 1));

        vm.prank(admin);
        vesting.createSchedule(beneficiaries[seed % 4], uint64(block.timestamp), cliff, duration, amount, true);
        created++;
    }

    function release(uint256 idSeed) external count {
        uint256 n = vesting.scheduleCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        if (vesting.releasable(id) == 0) return;
        vesting.release(id);
        released++;
    }

    function revoke(uint256 idSeed) external count {
        uint256 n = vesting.scheduleCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        Vesting.Schedule memory s = vesting.schedules(id);
        if (!s.revocable || s.revoked) return;
        vm.prank(admin);
        vesting.revoke(id);
        revoked++;
    }

    function reallocate(uint256 amountSeed) external count {
        uint256 room = vesting.unallocated();
        if (room == 0) return;
        // Blocked until at least one grant exists, so it is a re-granting path and not a genesis drain (D-098).
        if (vesting.scheduleCount() == 0) return;
        vm.prank(admin);
        vesting.reallocateUnallocated(admin, bound(amountSeed, 1, room));
        reallocations++;
    }

    /// @dev A donation must not expand `unallocated()` — the property I-24 states.
    function donate(uint256 amount) external count {
        uint256 bal = write.balanceOf(address(this));
        if (bal == 0) return;
        write.transfer(address(vesting), bound(amount, 1, bal));
        donations++;
    }

    function warp(uint256 dt) external count {
        vm.warp(block.timestamp + bound(dt, 1 days, 200 days));
    }

    // ───────────────────────────── views for the invariants ─────────────────────────────

    function sumScheduleTotals() external view returns (uint256 total) {
        uint256 n = vesting.scheduleCount();
        for (uint256 i; i < n; ++i) {
            total += vesting.schedules(i).totalAmount;
        }
    }

    function sumScheduleReleased() external view returns (uint256 total) {
        uint256 n = vesting.scheduleCount();
        for (uint256 i; i < n; ++i) {
            total += vesting.schedules(i).released;
        }
    }

    /// @dev True when some schedule has released more than it has vested — the one thing that must never
    /// happen, checked per schedule because a sum could hide an offsetting error.
    function anyOverRelease() external view returns (bool) {
        uint256 n = vesting.scheduleCount();
        for (uint256 i; i < n; ++i) {
            if (vesting.schedules(i).released > vesting.vestedAmount(i, block.timestamp)) return true;
        }
        return false;
    }
}
