// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {MerkleTreeLib} from "./utils/MerkleTreeLib.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";

/// @dev Records whether it was called back during a token transfer. WRITE is a plain ERC-20 with no hooks, so
/// this must stay false — which is what closes the T-16 class for the whole token layer.
contract CallbackWatcher {
    bool public wasCalled;

    receive() external payable {
        wasCalled = true;
    }

    fallback() external payable {
        wasCalled = true;
    }
}

/// @dev THREAT-MODEL regressions for the WRITE token layer (T-05, T-11, T-12, T-13, T-16, T-21…T-24).
/// T-05's sequencer case lives in `TokenLayerGuards.t.sol` next to the guard it exercises.
contract TokenLayerThreatsTest is TokenBaseTest {
    // ═════════════════════════════ T-11 · token-level failure modes ═════════════════════════════

    /// @dev The stock token can be paused, frozen and burned by its issuer (T-11), and USDG by Paxos (T-12).
    /// WRITE deliberately has none of that surface: no owner, no pause, no blocklist, no mint. A transfer
    /// therefore cannot be blocked by anyone, which is why bonds and stakes denominated in it cannot be
    /// frozen out from under their holders.
    function test_T11_writeHasNoPauseFreezeOrBlocklist() public {
        string[6] memory sigs = [
            "pause()",
            "unpause()",
            "setPaused(bool)",
            "setFrozen(address,bool)",
            "blacklist(address)",
            "mint(address,uint256)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(write).call(abi.encodeWithSignature(sigs[i], address(0), uint256(0)));
            assertFalse(ok, "WRITE must expose no issuer control surface");
        }

        // And a transfer works with no privileged party able to intervene.
        _buyWrite(alice, 100e18);
        vm.prank(alice);
        write.transfer(bob, 100e18);
        assertEq(write.balanceOf(bob), 100e18);
    }

    // ═════════════════════════════ T-12 · a frozen counterparty ═════════════════════════════

    /// @dev Paxos can freeze the curator's address. In WRITE mode the USDG rebate is the last leg of `flush`,
    /// so a frozen curator makes the whole flush revert. Because the revert rolls the call back, the booked
    /// fee is delayed rather than destroyed, and a mode flip recovers it. `clear` is unaffected throughout —
    /// the fee-side liveness guarantee is about clearing, not flushing.
    function test_T12_frozenCuratorBlocksTheFlushButNeverTheClearing() public {
        _launchWriteMode();
        _fundCurator(1_000_000e18);

        _deposit(alice, DEPOSIT);
        uint256 id = _openDefault();
        _bid(mm1, id, 500e18, 2e6);
        (,,, uint256 fee) = _clear(id); // must not revert whatever USDG does
        assertGt(fee, 0);

        usdg.setFrozen(curator, true);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.AccountFrozen.selector, curator));
        fr.flush(address(vault));

        // The whole call reverts, so `pending` rolls back with it: the fee is delayed, never destroyed.
        assertEq(fr.pending(address(vault)), fee, "the booked fee survives the failed flush");

        // Governance's remedy is a mode flip; no re-collection is needed.
        vm.prank(admin);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.USDG);
        uint256 before = usdg.balanceOf(treasury);
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury) - before, fee, "the fee reaches the treasury after the mode flip");
        assertEq(fr.pending(address(vault)), 0);
    }

    /// @dev A clearing must survive every USDG and WRITE failure at once, because `clear` is permissionless.
    function test_T12_clearSurvivesAFrozenCuratorAndADeadOracle() public {
        _launchWriteMode();
        _fundCurator(1_000e18);
        usdg.setFrozen(curator, true);
        writePool.setDead(true);

        _deposit(alice, DEPOSIT);
        uint256 id = _openDefault();
        _bid(mm1, id, 500e18, 2e6);
        (,,, uint256 fee) = _clear(id);
        assertGt(fee, 0, "clearing is untouched by the fee configuration");
    }

    // ═════════════════════════════ T-13 · privileged-role abuse ═════════════════════════════

    /// @dev The 30 % cap and the 14-day interval together bound how fast a compromised timelock can drain the
    /// backstop: after n events at most 1 - 0.7^n is gone, and n is one per fortnight.
    function test_T13_repeatedSlashesDrainSlowlyAndNeverFully() public {
        _stake(staker1, 1_000_000e18);
        uint256 start = sm.totalStaked();

        for (uint256 i; i < 5; ++i) {
            uint256 cap = sm.totalStaked() * sm.MAX_SLASH_BPS() / sm.BPS();
            vm.prank(admin);
            sm.slash(cap, shortfallReserve, "ipfs://x");
            vm.warp(block.timestamp + sm.SLASH_INTERVAL());
        }

        // 0.7^5 = 16.8 % remains, and ten weeks have had to pass to get there.
        assertApproxEqRel(sm.totalStaked(), start * 168 / 1000, 1e16, "0.7^5 of the stake survives");
        assertGt(sm.totalStaked(), 0);
        assertEq(write.balanceOf(shortfallReserve), start - sm.totalStaked(), "every slashed token is accounted");
    }

    /// @dev `redirectUnallocated` moves only emissions that accrued while nothing was staked. It must not be
    /// able to reach a staker's credited rewards.
    function test_T13_redirectUnallocatedCannotReachStakerRewards() public {
        _warpWithOracles(10 days); // nobody staked: these emissions are parked
        sm.poke();
        uint256 parked = sm.unallocatedRewards();
        assertGt(parked, 0);

        _stake(staker1, 1_000e18);
        _warpWithOracles(10 days); // these belong to staker1
        sm.poke();
        uint256 owed = sm.pendingRewards(staker1);
        assertGt(owed, 0);

        vm.prank(admin);
        uint256 moved = sm.redirectUnallocated(treasury);
        assertEq(moved, parked, "only the parked emissions moved");
        assertEq(sm.pendingRewards(staker1), owed, "the staker's credit is untouched");

        vm.prank(staker1);
        assertApproxEqAbs(sm.claimRewards(), owed, 1, "and is still payable");
    }

    // ═════════════════════════════ T-16 · reentrancy ═════════════════════════════

    /// @dev The token layer's reentrancy story rests on WRITE having no transfer hook: a recipient is never
    /// called, so no payout can re-enter. Proven directly rather than assumed.
    function test_T16_writeTransfersNeverCallTheRecipient() public {
        CallbackWatcher watcher = new CallbackWatcher();
        _buyWrite(alice, 10e18);
        vm.prank(alice);
        write.transfer(address(watcher), 10e18);
        assertEq(write.balanceOf(address(watcher)), 10e18);
        assertFalse(watcher.wasCalled(), "a plain ERC-20 transfer must not call the recipient");
    }

    /// @dev Every payout path in the layer sends WRITE to a caller-influenced address. With no hook they
    /// cannot be re-entered, and each is `nonReentrant` besides. Driving them all to a contract recipient
    /// documents that the combination holds.
    function test_T16_everyPayoutPathToAContractRecipientIsInert() public {
        CallbackWatcher watcher = new CallbackWatcher();

        _stake(staker1, 1_000e18);
        vm.prank(admin);
        sm.slash(100e18, address(watcher), "ipfs://x"); // SafetyModule.slash

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = points.leafHash(50, 0, address(watcher), 5e18);
        vm.prank(admin);
        points.setRound(50, leaves[0], 5e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));
        points.claim(50, 0, address(watcher), 5e18, new bytes32[](0)); // PointsDistributor.claim

        assertEq(write.balanceOf(address(watcher)), 105e18);
        assertFalse(watcher.wasCalled(), "no payout path calls its recipient");
    }

    // ═════════════════════════════ T-21 · WRITE price manipulation into the cap ═════════════════

    /// @dev The WRITE/USDG pool is newer and thinner than any stock pool, and its price now sizes every
    /// vault's deposit cap. The depth rule and the sanity band are what bound the damage: a pump beyond the
    /// ceiling reports no price at all rather than an inflated one, which closes deposits instead of
    /// inflating them.
    function test_T21_aPumpBeyondTheSanityCeilingClosesCapsRatherThanInflatingThem() public {
        _stake(staker1, 10_000_000e18);
        _enableSafetyModuleCap(10_000);
        uint256 capBefore = cap.vaultCapUSD(address(vault));
        assertGt(capBefore, 0);

        _setWritePrice(20e8); // 200x the launch price, far beyond sanityHigh8

        assertEq(sm.valueUSD(), 0, "no price, so no backstop value");
        assertEq(cap.vaultCapUSD(address(vault)), 0, "and no deposit capacity");
        assertEq(vault.maxDeposit(alice), 0, "the pump cannot buy deposit headroom");
    }

    /// @dev Inside the band the cap does track the price, which is the intended behaviour — the band bounds
    /// the manipulation, it does not disable the mechanism.
    function test_T21_withinTheBandTheCapTracksThePrice() public {
        _stake(staker1, 10_000_000e18);
        _enableSafetyModuleCap(10_000);
        uint256 capBefore = cap.vaultCapUSD(address(vault));

        _setWritePrice(0.2e8); // double, still inside the band
        assertApproxEqRel(cap.vaultCapUSD(address(vault)), capBefore * 2, 1e15, "the cap doubled with the price");
    }

    // ═════════════════════════════ T-22 · bond migration griefing ═════════════════════════════

    /// @dev A migration cannot silently un-bond everyone: it needs both requirements set first, and the grace
    /// window keeps the legacy asset qualifying while MMs move across.
    function test_T22_migrationCannotUnbondEveryoneInOneCall() public {
        assertTrue(bm.hasActiveMMBond(mm1));
        vm.startPrank(admin);
        bm.setWriteToken(address(write));
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.MM, 250_000e18);
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.CURATOR, 100_000e18);
        bm.startMigration(30 days);
        vm.stopPrank();

        assertTrue(bm.hasActiveMMBond(mm1), "still bonded the whole grace window");
        vm.warp(block.timestamp + 29 days);
        assertTrue(bm.hasActiveMMBond(mm1));
    }

    // ═════════════════════════════ T-23 · emissions misdirection ═════════════════════════════

    /// @dev The rate is bounded by the whole bucket over one year and the sink is one-shot, so a compromised
    /// timelock can slow or stop emissions but cannot point the stream somewhere else or accelerate it past
    /// the bucket.
    function test_T23_emissionsRateIsBoundedAndTheSinkIsOneShot() public {
        uint256 tooFast = emis.MAX_RATE() + 1;
        vm.prank(admin);
        vm.expectRevert(EmissionsController.OutOfBounds.selector);
        emis.setRate(tooFast);

        vm.prank(admin);
        vm.expectRevert(EmissionsController.AlreadySet.selector);
        emis.setSink(address(0xdead));

        // Stopping the stream is allowed; it cannot exceed the bucket however long it runs.
        vm.prank(admin);
        emis.setRate(0);
        vm.warp(block.timestamp + 365 days);
        assertEq(emis.accrued(), 0, "a zero rate emits nothing");
        assertLe(emis.released() + emis.accrued(), emis.allocation(), "and the bucket is never exceeded");
    }

    // ═════════════════════════════ T-24 · points root mis-issuance ═════════════════════════════

    /// @dev An over-issuing root cannot reach beyond its own round's allocation, so a bad root is a race
    /// inside that round rather than a loss of the bucket.
    function test_T24_anOverIssuingRootIsConfinedToItsRound() public {
        address[2] memory who = [alice, bob];
        uint256[2] memory amt = [uint256(3_000e18), 3_000e18];
        bytes32[] memory leaves = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            leaves[i] = points.leafHash(60, i, who[i], amt[i]);
        }

        uint64 start = uint64(block.timestamp);
        vm.prank(admin);
        points.setRound(60, MerkleTreeLib.root(leaves), 4_000e18, start, start + 1 days); // under-reserved

        points.claim(60, 0, alice, amt[0], MerkleTreeLib.proof(leaves, 0));
        bytes32[] memory proof = MerkleTreeLib.proof(leaves, 1);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundExhausted.selector, 60, 3_000e18, 1_000e18));
        points.claim(60, 1, bob, amt[1], proof);

        assertEq(points.rounds(60).claimed, 3_000e18);
        assertLe(points.rounds(60).claimed, points.rounds(60).amount, "confined to its own allocation");
        assertGt(points.unreserved(), 0, "the rest of the bucket is untouched");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _launchWriteMode() internal {
        vm.startPrank(admin);
        fr.setWriteToken(address(write));
        fr.setPriceOracle(address(wOracle));
        fr.setCurator(address(vault), curator);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);
        vm.stopPrank();
    }

    function _fundCurator(uint256 amount) internal {
        _buyWrite(curator, amount);
        vm.startPrank(curator);
        write.approve(address(fr), type(uint256).max);
        fr.depositWrite(address(vault), amount);
        vm.stopPrank();
    }
}
