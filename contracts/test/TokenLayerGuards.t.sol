// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {BondManager} from "../src/BondManager.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Guards added by the independent review of this phase (D-098), plus the revert branches and
/// privileged-caller cases that review found uncovered on the staking side.
contract TokenLayerGuardsTest is TokenBaseTest {
    // ═════════════════════════════ SafetyModule ═════════════════════════════

    /// @dev The cooldown alone does not stop a dodge: a standing request opens a 3-day window every 17 days,
    /// which overlaps a 48 h execution window about 29 % of the time. A slash voids requests that matured
    /// before it, so sitting permanently one block from an exit no longer works.
    function test_slash_voidsAlreadyMaturedUnstakeRequests() public {
        _stake(staker1, 1_000e18);
        uint256 shares = sm.sharesOf(staker1);
        vm.prank(staker1);
        uint64 unlockAt = sm.requestUnstake(shares);
        vm.warp(uint256(unlockAt) + 1); // matured, inside the claim window

        vm.prank(admin);
        sm.slash(300e18, shortfallReserve, "ipfs://evidence");

        // README:75 -- read the view into a local, or it consumes the prank and the call comes from the
        // test contract instead of the staker.
        bytes memory voided = abi.encodeWithSelector(SafetyModule.RequestVoidedBySlash.selector, sm.lastSlashAt());
        vm.prank(staker1);
        vm.expectRevert(voided);
        sm.unstake();

        // The staker is not locked out -- they serve a fresh cooldown and then exit, minus the slash.
        vm.prank(staker1);
        uint64 again = sm.requestUnstake(shares);
        vm.warp(uint256(again) + 1);
        vm.prank(staker1);
        assertApproxEqRel(sm.unstake(), 700e18, 1e12, "and they bear the slash");
    }

    /// @dev A request opened after the slash is unaffected, so an honest staker is never voided twice.
    function test_slash_doesNotVoidARequestOpenedAfterIt() public {
        _stake(staker1, 1_000e18);
        vm.prank(admin);
        sm.slash(300e18, shortfallReserve, "ipfs://evidence");

        uint256 shares = sm.sharesOf(staker1);
        vm.prank(staker1);
        uint64 unlockAt = sm.requestUnstake(shares);
        vm.warp(uint256(unlockAt) + 1);
        vm.prank(staker1);
        assertGt(sm.unstake(), 0);
    }

    /// @dev `address(this)` would decrement `totalStaked` while leaving the tokens where no credit can reach
    /// them: the stakers take the loss and the WRITE is unrecoverable.
    function test_slash_rejectsTheModuleItselfAsRecipient() public {
        _stake(staker1, 1_000e18);
        vm.prank(admin);
        vm.expectRevert(SafetyModule.ZeroAddress.selector);
        sm.slash(1e18, address(sm), "ipfs://x");
    }

    function test_redirectUnallocated_rejectsTheModuleItself() public {
        _warpWithOracles(7 days);
        sm.poke();
        vm.prank(admin);
        vm.expectRevert(SafetyModule.ZeroAddress.selector);
        sm.redirectUnallocated(address(sm));
    }

    /// @dev A slash may not cross the residual floor...
    function test_slash_revertsWhenItWouldCrossTheResidualFloor() public {
        // Crossing the floor while staying inside the 30 % cap needs 0.7 x staked < floor, so the pool has to
        // sit just above it: 1.2e12 staked, a 3e11 slash leaves 9e11, under the 1e12 floor.
        uint256 floor_ = sm.MIN_RESIDUAL_STAKE();
        _stake(staker1, floor_ * 12 / 10);
        vm.prank(admin);
        vm.expectRevert(SafetyModule.SlashWouldWipe.selector);
        sm.slash(floor_ * 3 / 10, shortfallReserve, "ipfs://x");
    }

    /// @dev ...but a pool already below it stays slashable, which is the whole point of D-073: a flat rule
    /// would disable slashing exactly when the module is weakest.
    function test_slash_isStillAllowedBelowTheResidualFloor() public {
        _stake(staker1, 1_000); // far below MIN_RESIDUAL_STAKE
        assertLt(sm.totalStaked(), sm.MIN_RESIDUAL_STAKE());
        vm.prank(admin);
        sm.slash(300, shortfallReserve, "ipfs://x");
        assertEq(sm.totalStaked(), 700);
    }

    /// @dev Slashing can never empty the pool: the cap is 30 % of what remains, so `PoolInsolvent` is
    /// unreachable through this path however many times it is applied.
    function test_repeatedSlashesCannotEmptyThePool() public {
        _stake(staker1, 1_000e18);
        for (uint256 i; i < 8; ++i) {
            uint256 cap = sm.totalStaked() * sm.MAX_SLASH_BPS() / sm.BPS();
            if (cap == 0) break;
            uint256 floor_ = sm.MIN_RESIDUAL_STAKE();
            if (sm.totalStaked() > floor_ && sm.totalStaked() - cap < floor_) break;
            vm.prank(admin);
            sm.slash(cap, shortfallReserve, "ipfs://x");
            vm.warp(block.timestamp + sm.SLASH_INTERVAL());
            assertGt(sm.totalStaked(), 0, "principal never reaches zero");
        }
    }

    function test_renounceOwnershipDisabledAcrossTheLayer() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeRouter.RenounceDisabled.selector);
        fr.renounceOwnership();
        vm.expectRevert(BondManager.RenounceDisabled.selector);
        bm.renounceOwnership();
        vm.stopPrank();
    }

    // ═════════════════════════════ FeeRouter ═════════════════════════════

    function _launchWriteMode() internal {
        vm.startPrank(admin);
        fr.setWriteToken(address(write));
        fr.setPriceOracle(address(wOracle));
        fr.setCurator(address(vault), curator);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);
        vm.stopPrank();
    }

    /// @dev Without a curator there is no withdrawal path at all, so the deposit would be unrecoverable.
    function test_depositWrite_revertsWithoutACurator() public {
        vm.startPrank(admin);
        fr.setWriteToken(address(write));
        fr.setPriceOracle(address(wOracle));
        vm.stopPrank();

        _buyWrite(alice, 100e18);
        vm.startPrank(alice);
        write.approve(address(fr), type(uint256).max);
        vm.expectRevert(FeeRouter.NotCurator.selector);
        fr.depositWrite(address(vault), 100e18);
        vm.stopPrank();
    }

    /// @dev `flush` is permissionless and priced at call time, so a curator could otherwise watch the price
    /// and pull the prefunded WRITE moments before a flush would have debited it.
    function test_withdrawWrite_cannotStrandAnAlreadyBookedFee() public {
        _launchWriteMode();
        _buyWrite(curator, 1_000_000e18);
        vm.startPrank(curator);
        write.approve(address(fr), type(uint256).max);
        fr.depositWrite(address(vault), 1_000_000e18);
        vm.stopPrank();

        usdg.mint(address(ah), 100e6);
        vm.prank(address(ah));
        fr.collect(address(vault), 1, 100e6);

        (uint256 needed,) = fr.previewWriteFee(100e6);
        uint256 balance = fr.writeBalance(address(vault));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.WriteBalanceReserved.selector, needed, needed - 1));
        fr.withdrawWrite(address(vault), balance - needed + 1);

        // Leaving exactly the reservation is fine.
        vm.prank(curator);
        fr.withdrawWrite(address(vault), balance - needed);
        assertEq(fr.writeBalance(address(vault)), needed);

        // And the flush still succeeds in WRITE mode.
        uint256 supplyBefore = write.totalSupply();
        fr.flush(address(vault));
        assertLt(write.totalSupply(), supplyBefore, "the burn happened");
    }

    function test_feeRouter_zeroAmountBranches() public {
        _launchWriteMode();
        vm.startPrank(curator);
        vm.expectRevert(FeeRouter.ZeroAmount.selector);
        fr.depositWrite(address(vault), 0);
        vm.expectRevert(FeeRouter.ZeroAmount.selector);
        fr.withdrawWrite(address(vault), 0);
        vm.stopPrank();
    }

    // ═════════════════════════════ BondManager ═════════════════════════════

    function test_extendGrace_revertsBeforeAMigrationStarts() public {
        vm.prank(admin);
        vm.expectRevert(BondManager.MigrationNotStarted.selector);
        bm.extendGrace(uint64(block.timestamp + 1 days));
    }

    function test_extendGrace_rejectsBeyondTheMaximum() public {
        _startMigration();
        uint64 tooLate = uint64(block.timestamp) + bm.MAX_GRACE() + 1;
        vm.prank(admin);
        vm.expectRevert(BondManager.OutOfBounds.selector);
        bm.extendGrace(tooLate);
    }

    /// @dev The one-argument aliases follow `bondAsset`, so after a migration `cancelWithdraw` targets the
    /// WRITE leg. The explicit form is how a holder reaches the legacy one.
    function test_cancelWithdrawIn_perLegAndTheAliasFollowsTheCurrentAsset() public {
        vm.prank(mm1);
        bm.requestWithdrawIn(IBondManager.BondKind.MM, IBondManager.BondAsset.USDG);
        (,, uint64 unlockAt) = bm.statusIn(mm1, IBondManager.BondKind.MM, IBondManager.BondAsset.USDG);
        assertGt(unlockAt, 0);

        _startMigration(); // bondAsset is now WRITE

        vm.prank(mm1);
        vm.expectRevert(BondManager.NoWithdrawalPending.selector);
        bm.cancelWithdraw(IBondManager.BondKind.MM); // alias -> the WRITE leg, which has no request

        vm.prank(mm1);
        bm.cancelWithdrawIn(IBondManager.BondKind.MM, IBondManager.BondAsset.USDG);
        (,, uint64 after_) = bm.statusIn(mm1, IBondManager.BondKind.MM, IBondManager.BondAsset.USDG);
        assertEq(after_, 0, "the legacy request was cancelled");
    }

    function _startMigration() internal {
        vm.startPrank(admin);
        bm.setWriteToken(address(write));
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.MM, 250_000e18);
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.CURATOR, 100_000e18);
        bm.startMigration(30 days);
        vm.stopPrank();
    }

    // ═════════════════════════════ WritePriceOracle ═════════════════════════════

    /// @dev T-05: `observe` interpolates across a sequencer outage and reports a pre-outage tick as fresh.
    /// That stale price would size every vault's deposit cap, so the window is rejected while the sequencer
    /// is down and during the recovery grace.
    function test_T05_writeTwapIsRejectedWhileTheSequencerIsDown() public {
        MockAggregatorV3 seq = new MockAggregatorV3(0);
        seq.setRound(1, 1, block.timestamp); // answer 1 == down
        vm.prank(admin);
        wOracle.setSequencerFeed(address(seq), 1 hours);

        (, bool ok) = wOracle.writePrice();
        assertFalse(ok, "no price while the sequencer is down");
        (, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("SEQUENCER_DOWN"));

        // Just recovered: still inside the grace.
        seq.setRound(2, 0, block.timestamp);
        (, ok) = wOracle.writePrice();
        assertFalse(ok, "still rejected inside the recovery grace");

        // Recovered long enough ago.
        seq.setRound(3, 0, block.timestamp - 2 hours);
        _refreshWriteOracle();
        (, ok) = wOracle.writePrice();
        assertTrue(ok, "priced again once the grace has elapsed");
    }

    function test_setSequencerFeed_boundedAndClearable() public {
        vm.startPrank(admin);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setSequencerFeed(address(1), 7 hours);
        wOracle.setSequencerFeed(address(0), 0); // disabled
        vm.stopPrank();
        assertEq(wOracle.sequencerFeed(), address(0));
        (, bool ok) = wOracle.writePrice();
        assertTrue(ok, "the check is off while the feed is unset");
    }

    /// @dev `_inBand(0)` would otherwise be true, so a feed answer truncating to zero would be reported as a
    /// usable price of zero.
    function test_setSanityBand_rejectsAZeroFloor() public {
        vm.prank(admin);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setSanityBand(0, 5e8);
    }

    /// @dev A fresh but out-of-band Chainlink answer is rejected outright; it does NOT silently fall through
    /// to the TWAP, because a feed that far off is a configuration error, not a missing source.
    function test_writePrice_freshChainlinkOutOfBandDoesNotFallBackToTheTwap() public {
        MockAggregatorV3 cl = new MockAggregatorV3(8);
        cl.setRound(1, 10e8, block.timestamp); // above sanityHigh8 = 5e8
        vm.prank(admin);
        wOracle.setChainlinkFeed(address(cl));

        (uint256 price8, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        assertEq(price8, 0);
        (uint256 raw, bytes32 reason, uint8 source) = wOracle.previewPrice();
        assertEq(reason, bytes32("OUT_OF_BAND"));
        assertEq(source, wOracle.SOURCE_NONE());
        assertEq(raw, 10e8, "the raw quote stays visible for diagnosis");
    }

    function test_writePrice_notOkOnNegativeOrIncompleteChainlinkRound() public {
        MockAggregatorV3 cl = new MockAggregatorV3(8);
        vm.prank(admin);
        wOracle.setChainlinkFeed(address(cl));

        cl.setRound(1, -1, block.timestamp); // negative answer
        (,, uint8 src) = wOracle.previewPrice();
        assertEq(src, wOracle.SOURCE_TWAP(), "falls through to the TWAP");

        cl.setRound(2, 1e8, 0, block.timestamp); // startedAt 0 is fine; updatedAt 0 is the incomplete case
        cl.setRound(3, 1e8, block.timestamp, 0);
        cl.setLatest(3);
        (,, src) = wOracle.previewPrice();
        assertEq(src, wOracle.SOURCE_TWAP(), "an incomplete round is not a price");
    }

    /// @dev A tick outside TickMath's domain is reported, never allowed to revert `getSqrtRatioAtTick`.
    function test_writePrice_notOkOnAnOutOfRangeTick() public {
        int24 absurd = 900_000; // beyond MAX_TICK 887 272
        writePool.write(uint32(block.timestamp), absurd, WRITE_POOL_LIQ);
        vm.warp(block.timestamp + wOracle.twapWindow() + 1);
        writePool.write(uint32(block.timestamp), absurd, WRITE_POOL_LIQ);
        _usdgFresh();

        (uint256 price8, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        assertEq(price8, 0);
        (, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("TICK_RANGE"));
    }

    function test_setChainlinkFeed_clearableBackToTheTwap() public {
        MockAggregatorV3 cl = new MockAggregatorV3(8);
        cl.setRound(1, 0.2e8, block.timestamp);
        vm.startPrank(admin);
        wOracle.setChainlinkFeed(address(cl));
        assertEq(wOracle.chainlinkDecimals(), 8);
        wOracle.setChainlinkFeed(address(0));
        vm.stopPrank();
        assertEq(wOracle.chainlinkDecimals(), 0);
        (,, uint8 src) = wOracle.previewPrice();
        assertEq(src, wOracle.SOURCE_TWAP());
    }

    // ═════════════════════════════ unauthorised callers (rule 5) ═════════════════════════════

    function test_privilegedFunctionsRejectAStranger() public {
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);

        vm.expectRevert(denied);
        sm.setOracle(address(wOracle));
        vm.expectRevert(denied);
        sm.redirectUnallocated(alice);

        vm.expectRevert(denied);
        wOracle.setChainlinkFeed(address(0));
        vm.expectRevert(denied);
        wOracle.setTwapWindow(1 hours);
        vm.expectRevert(denied);
        wOracle.setDepthParams(100, 1e6);
        vm.expectRevert(denied);
        wOracle.setSanityBand(1, 2);
        vm.expectRevert(denied);
        wOracle.setSequencerFeed(address(0), 0);

        vm.expectRevert(denied);
        fr.setWriteToken(address(write));
        vm.expectRevert(denied);
        fr.setPriceOracle(address(wOracle));
        vm.expectRevert(denied);
        fr.setWriteDiscountBps(0);
        vm.expectRevert(denied);
        fr.setWriteBurnShareBps(0);
        vm.expectRevert(denied);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.USDG);

        vm.expectRevert(denied);
        bm.setWriteToken(address(write));
        vm.expectRevert(denied);
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.MM, 1);
        vm.expectRevert(denied);
        bm.extendGrace(uint64(block.timestamp + 1));
        vm.expectRevert(denied);
        bm.slashBondIn(mm1, IBondManager.BondKind.MM, IBondManager.BondAsset.USDG, 1, "x");

        vm.stopPrank();
    }
}
