// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "./TokenUnitBase.t.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EmissionsControllerTest is TokenUnitBaseTest {
    // ═════════════════════════════ construction ═════════════════════════════

    function test_constructor_fourYearLinearSchedule() public view {
        assertEq(emis.allocation(), 300_000_000e18);
        assertEq(emis.startTime(), START_TS);
        assertEq(emis.endTime(), START_TS + EMISSIONS_DURATION);
        assertEq(emis.rate(), 300_000_000e18 / uint256(EMISSIONS_DURATION));
        assertEq(emis.writeToken(), address(write));
        assertEq(emis.sink(), address(sm));
        assertEq(emis.released(), 0);
    }

    /// @dev Without the duration floor a one-day schedule yields a rate hundreds of times above the `setRate`
    /// cap, draining the whole bucket in a day (D-076).
    function test_constructor_enforcesMinAndMaxDuration() public {
        vm.expectRevert(EmissionsController.OutOfBounds.selector);
        new EmissionsController(admin, 1 days);
        vm.expectRevert(EmissionsController.OutOfBounds.selector);
        new EmissionsController(admin, 3651 days);
        EmissionsController ok = new EmissionsController(admin, 365 days);
        assertLe(ok.rate(), ok.MAX_RATE());
    }

    function test_maxRateIsTheWholeBucketOverTheMinimumDuration() public view {
        assertEq(emis.MAX_RATE(), 300_000_000e18 / uint256(365 days));
        assertLe(emis.rate(), emis.MAX_RATE());
    }

    // ═════════════════════════════ accrual ═════════════════════════════

    function test_accrued_isLinearInTime() public {
        assertEq(emis.accrued(), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(emis.accrued(), emis.rate() * 7 days);
        vm.warp(block.timestamp + 7 days);
        assertEq(emis.accrued(), emis.rate() * 14 days);
    }

    function test_accrued_clampsAtEndTime() public {
        vm.warp(uint256(emis.endTime()) + 365 days);
        uint256 full = emis.rate() * uint256(EMISSIONS_DURATION);
        assertEq(emis.accrued(), full);
        assertLe(full, emis.allocation(), "integer division leaves a tail, never an overshoot");
    }

    function test_claim_onlySink() public {
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(EmissionsController.NotSink.selector);
        emis.claim();
    }

    function test_claim_transfersAndCheckpoints() public {
        vm.warp(block.timestamp + 7 days);
        uint256 expected = emis.rate() * 7 days;

        vm.prank(address(sm));
        uint256 amount = emis.claim();

        assertEq(amount, expected);
        assertEq(write.balanceOf(address(sm)), expected);
        assertEq(emis.released(), expected);
        assertEq(emis.accrued(), 0, "checkpoint advanced");
        assertEq(emis.lastAccrual(), block.timestamp);
    }

    function test_claim_zeroWhenNothingAccrued() public {
        vm.prank(address(sm));
        assertEq(emis.claim(), 0);
    }

    function test_undistributed_shrinksAsEmissionsAreReleased() public {
        assertEq(emis.undistributed(), 300_000_000e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(address(sm));
        uint256 amount = emis.claim();
        assertEq(emis.undistributed(), 300_000_000e18 - amount);
    }

    // ═════════════════════════════ rate changes ═════════════════════════════

    function test_setRate_onlyOwnerAndBounded() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        emis.setRate(1);

        // README:75 — a view read inside the argument list consumes both cheatcodes. Hoist it.
        uint256 tooFast = emis.MAX_RATE() + 1;
        vm.prank(admin);
        vm.expectRevert(EmissionsController.OutOfBounds.selector);
        emis.setRate(tooFast);
    }

    /// @dev The checkpoint runs first, so a rate change never reprices time that has already elapsed.
    function test_setRate_isNeverRetroactive() public {
        uint256 oldRate = emis.rate();
        vm.warp(block.timestamp + 7 days);
        uint256 earned = oldRate * 7 days;

        vm.prank(admin);
        emis.setRate(oldRate * 2);
        assertEq(emis.accrued(), earned, "the first week keeps the old rate");
        assertEq(emis.owed(), earned);

        vm.warp(block.timestamp + 7 days);
        assertEq(emis.accrued(), earned + oldRate * 2 * 7 days);
    }

    function test_setRateZero_stopsAndRestarts() public {
        vm.prank(admin);
        emis.setRate(0);
        vm.warp(block.timestamp + 30 days);
        assertEq(emis.accrued(), 0, "a zero rate stops the stream");

        uint256 resumed = emis.MAX_RATE() / 10;
        vm.prank(admin);
        emis.setRate(resumed);
        vm.warp(block.timestamp + 1 days);
        assertEq(emis.accrued(), resumed * 1 days);
    }

    /// @dev `endTime` is immutable and there is no `setEndTime` (D-076): `setRate` is the only time lever.
    function test_noSetEndTimeSelectorExists() public {
        (bool ok,) = address(emis).call(abi.encodeWithSignature("setEndTime(uint64)", uint64(1)));
        assertFalse(ok);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(EmissionsController.RenounceDisabled.selector);
        emis.renounceOwnership();
    }

    // ═════════════════════════════ sink wiring ═════════════════════════════

    function test_setSink_onceOnly() public {
        vm.prank(admin);
        vm.expectRevert(EmissionsController.AlreadySet.selector);
        emis.setSink(address(sm));
    }

    /// @dev The reverse assert stops a half-wired pair: the candidate must already point back here.
    function test_setSink_assertsBackReference() public {
        EmissionsController fresh = new EmissionsController(admin, EMISSIONS_DURATION);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EmissionsController.Miswired.selector, bytes32("WRITE_TOKEN")));
        fresh.setSink(address(sm));
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    function testFuzz_accruedIsMonotonicAndBounded(uint256[6] memory steps) public {
        uint256 last;
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + bound(steps[i], 0, 200 days));
            uint256 now_ = emis.accrued();
            assertGe(now_, last, "accrual never goes backwards");
            assertLe(now_ + emis.released(), emis.allocation(), "never exceeds the bucket");
            last = now_;
        }
    }

    function testFuzz_releasedNeverExceedsAllocation(uint256[6] memory steps) public {
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + bound(steps[i], 0, 400 days));
            vm.prank(address(sm));
            emis.claim();
            assertLe(emis.released(), emis.allocation());
            assertEq(write.balanceOf(address(sm)), emis.released(), "every released token reached the sink");
        }
    }
}
