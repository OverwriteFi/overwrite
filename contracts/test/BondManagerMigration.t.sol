// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {BondManager} from "../src/BondManager.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev The USDG -> WRITE bond migration (D-007, SPEC §13, D-079..D-082). The pre-migration behaviour is
/// covered by the untouched `BondManager.t.sol`; this file is only about the dual-asset window.
contract BondManagerMigrationTest is TokenBaseTest {
    IBondManager.BondKind internal constant MM = IBondManager.BondKind.MM;
    IBondManager.BondKind internal constant CURATOR = IBondManager.BondKind.CURATOR;
    IBondManager.BondAsset internal constant USDG_ASSET = IBondManager.BondAsset.USDG;
    IBondManager.BondAsset internal constant WRITE_ASSET = IBondManager.BondAsset.WRITE;

    uint256 internal constant WRITE_MM_BOND = 250_000e18; // ~25 000 USDG at the launch price
    uint256 internal constant WRITE_CURATOR_BOND = 100_000e18;
    uint64 internal constant GRACE = 30 days;

    uint256 internal round = 100;

    function _setWriteRequirements() internal {
        vm.startPrank(admin);
        bm.setWriteToken(address(write));
        bm.setRequiredAmountFor(WRITE_ASSET, MM, WRITE_MM_BOND);
        bm.setRequiredAmountFor(WRITE_ASSET, CURATOR, WRITE_CURATOR_BOND);
        vm.stopPrank();
    }

    function _startMigration() internal {
        _setWriteRequirements();
        vm.prank(admin);
        bm.startMigration(GRACE);
    }

    function _fundWriteBond(address who) internal {
        _grantWrite(who, WRITE_MM_BOND, round++);
        vm.startPrank(who);
        write.approve(address(bm), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Gives `mm1` a live series so it carries an active lock.
    function _lockMm1() internal returns (uint256 id) {
        _deposit(alice, DEPOSIT);
        id = _openDefault();
        _bid(mm1, id, 100e18, 2e6);
        assertEq(bm.activeLocks(mm1), 1);
    }

    // ═════════════════════════════ isBonded ═════════════════════════════

    function test_isBonded_matchesHasActiveMMBond() public view {
        assertTrue(bm.isBonded(mm1, MM));
        assertTrue(bm.hasActiveMMBond(mm1));
        assertFalse(bm.isBonded(alice, MM));
        assertFalse(bm.hasActiveMMBond(alice));
        assertFalse(bm.isBonded(mm1, CURATOR), "MM bond does not confer curator standing");
    }

    function test_usdgStaysImmutable() public view {
        assertEq(address(bm.usdg()), address(usdg), "AuctionHouse asserts this in its constructor");
        assertEq(uint256(bm.bondAsset()), uint256(USDG_ASSET));
        assertEq(bm.migrationEndsAt(), 0);
    }

    function test_oneArgAliasesOperateOnTheCurrentAsset() public view {
        assertEq(bm.requiredAmount(MM), bm.requiredAmountOf(USDG_ASSET, MM));
        assertEq(bm.requiredAmount(MM), 25_000e6);
        (uint256 amount, address asset,) = bm.status(mm1, MM);
        assertEq(amount, 25_000e6);
        assertEq(asset, address(usdg));
    }

    // ═════════════════════════════ starting the migration ═════════════════════════════

    function test_startMigration_onlyOwner() public {
        _setWriteRequirements();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bm.startMigration(GRACE);
    }

    function test_startMigration_requiresTheWriteToken() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Miswired.selector, bytes32("WRITE_TOKEN")));
        bm.startMigration(GRACE);
    }

    /// @dev A half-configured migration would un-bond everyone the moment it starts.
    function test_startMigration_requiresBothRequirements() public {
        vm.startPrank(admin);
        bm.setWriteToken(address(write));
        bm.setRequiredAmountFor(WRITE_ASSET, MM, WRITE_MM_BOND);
        vm.expectRevert(abi.encodeWithSelector(BondManager.RequirementUnset.selector, WRITE_ASSET, CURATOR));
        bm.startMigration(GRACE);
        vm.stopPrank();
    }

    function test_startMigration_boundedAndOneWay() public {
        _setWriteRequirements();
        vm.startPrank(admin);
        vm.expectRevert(BondManager.OutOfBounds.selector);
        bm.startMigration(0);
        vm.expectRevert(BondManager.OutOfBounds.selector);
        bm.startMigration(91 days);

        bm.startMigration(GRACE);
        vm.expectRevert(BondManager.MigrationStarted.selector);
        bm.startMigration(GRACE);
        vm.stopPrank();

        assertEq(uint256(bm.bondAsset()), uint256(WRITE_ASSET));
        assertEq(uint256(bm.previousAsset()), uint256(USDG_ASSET));
        assertEq(bm.migrationEndsAt(), uint64(block.timestamp) + GRACE);
    }

    function test_setRequiredAmountFor_writeNeedsTheTokenFirst() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Miswired.selector, bytes32("WRITE_TOKEN")));
        bm.setRequiredAmountFor(WRITE_ASSET, MM, WRITE_MM_BOND);
    }

    function test_extendGrace_onlyIncreases() public {
        _startMigration();
        uint64 endsAt = bm.migrationEndsAt();
        vm.startPrank(admin);
        vm.expectRevert(BondManager.OutOfBounds.selector);
        bm.extendGrace(endsAt - 1);
        bm.extendGrace(endsAt + 5 days);
        vm.stopPrank();
        assertEq(bm.migrationEndsAt(), endsAt + 5 days);
    }

    // ═════════════════════════════ the grace window ═════════════════════════════

    function test_bothAssetsCountDuringGrace() public {
        _startMigration();
        assertTrue(bm.assetAccepted(USDG_ASSET), "the legacy asset still qualifies");
        assertTrue(bm.assetAccepted(WRITE_ASSET));
        assertTrue(bm.isBonded(mm1, MM), "an MM bonded in USDG keeps bidding through the window");

        _fundWriteBond(mm2);
        vm.prank(mm2);
        bm.postBondIn(MM, WRITE_ASSET);
        assertTrue(bm.isBonded(mm2, MM), "and one bonded in both is bonded twice over");
        (uint256 usdgLeg,,) = bm.statusIn(mm2, MM, USDG_ASSET);
        (uint256 writeLeg,,) = bm.statusIn(mm2, MM, WRITE_ASSET);
        assertEq(usdgLeg, 25_000e6);
        assertEq(writeLeg, WRITE_MM_BOND);
    }

    /// @dev The seamless path: post the new asset during grace, so there is never a moment unbonded.
    function test_migration_noGapForAnMmThatPostsDuringGrace() public {
        _startMigration();
        _fundWriteBond(mm1);
        vm.prank(mm1);
        bm.postBondIn(MM, WRITE_ASSET);
        assertTrue(bm.isBonded(mm1, MM));

        vm.warp(uint256(bm.migrationEndsAt()) + 1);
        assertTrue(bm.isBonded(mm1, MM), "still bonded after the window closes");
        assertFalse(bm.assetAccepted(USDG_ASSET));
    }

    function test_legacyAssetStopsCountingAfterGrace() public {
        _startMigration();
        vm.warp(uint256(bm.migrationEndsAt()) + 1);
        assertFalse(bm.assetAccepted(USDG_ASSET));
        assertFalse(bm.isBonded(mm1, MM), "a USDG-only MM is no longer eligible to bid");
    }

    function test_postBondIn_rejectsADeAcceptedAsset() public {
        _startMigration();
        vm.warp(uint256(bm.migrationEndsAt()) + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondManager.AssetNotAccepted.selector, USDG_ASSET));
        bm.postBondIn(MM, USDG_ASSET);
    }

    // ═════════════════════════════ never stranded (SPEC §13) ═════════════════════════════

    /// @dev SPEC §13: after grace a legacy bond is withdrawable immediately, with no cooldown.
    function test_legacyBondWithdrawableWithoutCooldownAfterGrace() public {
        _startMigration();
        vm.warp(uint256(bm.migrationEndsAt()) + 1);

        uint256 before = usdg.balanceOf(mm1);
        vm.prank(mm1);
        uint256 amount = bm.withdrawBondIn(MM, USDG_ASSET);
        assertEq(amount, 25_000e6);
        assertEq(usdg.balanceOf(mm1), before + 25_000e6, "no request, no 7-day wait");
    }

    function test_legacyBondStillNeedsTheCooldownDuringGrace() public {
        _startMigration();
        vm.prank(mm1);
        vm.expectRevert(BondManager.NoWithdrawalPending.selector);
        bm.withdrawBondIn(MM, USDG_ASSET);

        vm.prank(mm1);
        uint64 unlockAt = bm.requestWithdrawIn(MM, USDG_ASSET);
        vm.warp(unlockAt);
        vm.prank(mm1);
        assertEq(bm.withdrawBondIn(MM, USDG_ASSET), 25_000e6);
    }

    /// @dev The lock check is never waived: migration must not become a collateral escape hatch.
    function test_T13_migrationIsNotACollateralEscapeHatch() public {
        _lockMm1();
        _startMigration();
        vm.warp(uint256(bm.migrationEndsAt()) + 1);

        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Locked.selector, uint256(1)));
        bm.withdrawBondIn(MM, USDG_ASSET);
    }

    /// @dev But the lock gates *qualification*, not a named asset: a locked MM that has already posted the
    /// new asset may pull the old leg, so migrating never costs it an auction (D-082).
    function test_lockedMmMayPullTheLegItIsNotStandingOn() public {
        _lockMm1();
        _startMigration();
        _fundWriteBond(mm1);
        vm.prank(mm1);
        bm.postBondIn(MM, WRITE_ASSET);

        vm.warp(uint256(bm.migrationEndsAt()) + 1);
        vm.prank(mm1);
        assertEq(bm.withdrawBondIn(MM, USDG_ASSET), 25_000e6, "the WRITE leg still backs the live series");
        assertTrue(bm.isBonded(mm1, MM));
        assertEq(bm.activeLocks(mm1), 1, "the lock itself is untouched");
    }

    function test_slashedBelowRequirementStopsQualifying() public {
        _startMigration();
        _fundWriteBond(mm2);
        vm.prank(mm2);
        bm.postBondIn(MM, WRITE_ASSET);

        vm.prank(admin);
        bm.slashBondIn(mm2, MM, WRITE_ASSET, 1e18, "ipfs://evidence");
        assertTrue(bm.isBonded(mm2, MM), "the USDG leg still qualifies during grace");

        vm.prank(admin);
        bm.slashBondIn(mm2, MM, USDG_ASSET, 1, "ipfs://evidence");
        assertFalse(bm.isBonded(mm2, MM), "neither leg meets its requirement now");
    }

    /// @dev Slashing names its asset; there is no spillover between legs.
    function test_slashBondIn_hasNoSpillover() public {
        _startMigration();
        _fundWriteBond(mm2);
        vm.prank(mm2);
        bm.postBondIn(MM, WRITE_ASSET);

        vm.prank(admin);
        bm.slashBondIn(mm2, MM, WRITE_ASSET, 100e18, "ipfs://x");
        (uint256 usdgLeg,,) = bm.statusIn(mm2, MM, USDG_ASSET);
        (uint256 writeLeg,,) = bm.statusIn(mm2, MM, WRITE_ASSET);
        assertEq(usdgLeg, 25_000e6, "the USDG leg is untouched");
        assertEq(writeLeg, WRITE_MM_BOND - 100e18);
        assertEq(write.balanceOf(treasury), 100e18);
    }

    function test_slashBondIn_cappedAtTheLeg() public {
        _startMigration();
        _fundWriteBond(mm2);
        vm.prank(mm2);
        bm.postBondIn(MM, WRITE_ASSET);
        uint256 tooMuch = WRITE_MM_BOND + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BondManager.ExceedsBond.selector, tooMuch, WRITE_MM_BOND));
        bm.slashBondIn(mm2, MM, WRITE_ASSET, tooMuch, "ipfs://x");
    }

    /// @dev A grantee claims WRITE from the points bucket and posts it directly; no coupling is needed.
    function test_bondGranteeCanPostAWriteBond() public {
        _startMigration();
        address newMm = makeAddr("grantedMM");
        _fundWriteBond(newMm);
        vm.prank(newMm);
        bm.postBondIn(MM, WRITE_ASSET);
        assertTrue(bm.isBonded(newMm, MM));
        assertTrue(bm.hasActiveMMBond(newMm), "and can bid immediately");
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    /// @dev Whatever the sequence of posts, slashes and warps, every token still recorded against a holder
    /// is eventually withdrawable — the migration never strands a bond.
    function testFuzz_migrationNeverStrandsABond(uint8 actions, uint256 warpSeed) public {
        _startMigration();
        _fundWriteBond(mm2);

        if (actions & 1 == 1) {
            vm.prank(mm2);
            bm.postBondIn(MM, WRITE_ASSET);
        }
        if (actions & 2 == 2) {
            vm.prank(admin);
            bm.slashBondIn(mm2, MM, USDG_ASSET, 1_000e6, "ipfs://x");
        }
        if (actions & 4 == 4) {
            vm.prank(mm2);
            bm.requestWithdrawIn(MM, USDG_ASSET);
        }
        vm.warp(block.timestamp + bound(warpSeed, 0, 120 days));

        (uint256 usdgLeg,,) = bm.statusIn(mm2, MM, USDG_ASSET);
        (uint256 writeLeg,,) = bm.statusIn(mm2, MM, WRITE_ASSET);

        // mm2 holds no lock, so both legs must be reachable: directly once de-accepted, or after a cooldown.
        if (usdgLeg > 0) {
            _drainLeg(mm2, USDG_ASSET);
            (uint256 left,,) = bm.statusIn(mm2, MM, USDG_ASSET);
            assertEq(left, 0, "the USDG leg was never stranded");
        }
        if (writeLeg > 0) {
            _drainLeg(mm2, WRITE_ASSET);
            (uint256 left,,) = bm.statusIn(mm2, MM, WRITE_ASSET);
            assertEq(left, 0, "the WRITE leg was never stranded");
        }
    }

    /// @dev Withdraws a leg the way a holder would: straight out if de-accepted, else request + cooldown.
    function _drainLeg(address who, IBondManager.BondAsset asset) internal {
        if (!bm.assetAccepted(asset)) {
            vm.prank(who);
            bm.withdrawBondIn(MM, asset);
            return;
        }
        (,, uint64 unlockAt) = bm.statusIn(who, MM, asset);
        if (unlockAt == 0) {
            vm.prank(who);
            unlockAt = bm.requestWithdrawIn(MM, asset);
        }
        if (block.timestamp < unlockAt) vm.warp(unlockAt);
        vm.prank(who);
        bm.withdrawBondIn(MM, asset);
    }
}
