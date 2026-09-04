// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "../TokenBase.t.sol";
import {WriteFeeBondHandler} from "./WriteFeeBondHandler.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {IBondManager} from "../../src/interfaces/IBondManager.sol";

/// @dev Invariants for the two paths this phase added to already-deployed contracts. `AuctionInvariants` runs
/// on `AuctionBaseTest`, where the WRITE token and the migration are unreachable, so its fee-conservation and
/// bond-lock properties only ever cover USDG mode and the pre-migration ledger (D-097).
contract WriteFeeBondInvariants is TokenBaseTest {
    WriteFeeBondHandler internal handler;
    address[3] internal mms;

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        fr.setWriteToken(address(write));
        fr.setPriceOracle(address(wOracle));
        fr.setCurator(address(vault), curator);
        bm.setWriteToken(address(write));
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.MM, 250_000e18);
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.CURATOR, 100_000e18);
        vm.stopPrank();

        mms = [makeAddr("im1"), makeAddr("im2"), makeAddr("im3")];
        handler = new WriteFeeBondHandler(
            WriteFeeBondHandler.Deps({
                write: write,
                usdg: usdg,
                fr: fr,
                bm: bm,
                oracle: wOracle,
                pool: writePool,
                admin: admin,
                auctionHouse: address(ah),
                vault: address(vault),
                curator: curator
            }),
            mms,
            writeTick
        );

        _buyWrite(curator, 20_000_000e18);
        vm.prank(curator);
        write.approve(address(fr), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            _buyWrite(mms[i], 2_000_000e18);
            vm.startPrank(mms[i]);
            write.approve(address(bm), type(uint256).max);
            usdg.approve(address(bm), type(uint256).max);
            vm.stopPrank();
        }
        // The AuctionHouse holds a standing approval for the router in production; mirror it here.
        vm.prank(address(ah));
        usdg.approve(address(fr), type(uint256).max);

        targetContract(address(handler));
    }

    /// @dev I-36: every USDG fee booked is either still pending or has been flushed. The WRITE mode changes
    /// where the USDG goes, never how much of it there is.
    function invariant_I36_feeConservation() public view {
        assertEq(
            handler.collected(), handler.flushed() + fr.pending(address(vault)), "I-36: collected == flushed + pending"
        );
    }

    /// @dev I-37: the curator's prefunded WRITE is conserved exactly. Everything deposited either still sits
    /// in the router, was withdrawn, was burned, or reached the treasury -- there is no fifth destination.
    function invariant_I37_prefundedWriteIsConserved() public view {
        assertEq(
            handler.writeDeposited(),
            fr.writeBalance(address(vault)) + handler.writeWithdrawn() + handler.writeBurned()
                + handler.writeToTreasury(),
            "I-37: deposited == held + withdrawn + burned + treasury"
        );
    }

    /// @dev I-38: the router holds exactly the WRITE it is accounting for, and never any USDG.
    function invariant_I38_routerHoldsWhatItAccountsFor() public view {
        assertEq(write.balanceOf(address(fr)), fr.writeBalance(address(vault)), "I-38: WRITE balance matches");
        assertEq(usdg.balanceOf(address(fr)), 0, "I-38: the router never holds USDG");
    }

    /// @dev I-39: each bond leg is backed one-for-one by tokens the BondManager actually holds, in every
    /// state of the migration.
    function invariant_I39_bondLegsAreBackedPerAsset() public view {
        assertLe(
            handler.sumBondLegs(IBondManager.BondAsset.USDG), usdg.balanceOf(address(bm)), "I-39: USDG legs are covered"
        );
        assertLe(
            handler.sumBondLegs(IBondManager.BondAsset.WRITE),
            write.balanceOf(address(bm)),
            "I-39: WRITE legs are covered"
        );
    }

    /// @dev I-40: a qualifying bond always meets its own asset's requirement. A migration must never leave an
    /// account counted as bonded on a leg that no longer satisfies the amount.
    function invariant_I40_bondedImpliesTheRequirementIsMet() public view {
        for (uint256 i; i < 3; ++i) {
            address mm = handler.mms(i);
            if (!bm.isBonded(mm, IBondManager.BondKind.MM)) continue;
            bool ok;
            for (uint256 a; a < 2; ++a) {
                IBondManager.BondAsset asset = IBondManager.BondAsset(a);
                if (!bm.assetAccepted(asset)) continue;
                (uint256 amount,, uint64 unlockAt) = bm.statusIn(mm, IBondManager.BondKind.MM, asset);
                uint256 required = bm.requiredAmountOf(asset, IBondManager.BondKind.MM);
                if (required != 0 && amount >= required && unlockAt == 0) ok = true;
            }
            assertTrue(ok, "I-40: bonded implies some accepted leg meets its requirement");
        }
    }

    /// @dev I-41: WRITE mode never mints. The only supply movement the router can cause is the burn.
    function invariant_I41_theRouterOnlyEverBurns() public view {
        assertEq(write.totalSupply(), write.MAX_SUPPLY() - handler.writeBurned(), "I-41: supply falls only by the burn");
    }

    function afterInvariant() public {
        emit log_named_uint("calls", handler.calls());
        emit log_named_uint("fees collected", handler.collected());
        emit log_named_uint("fees flushed", handler.flushed());
        emit log_named_uint("WRITE burned", handler.writeBurned());
        emit log_named_uint("bonds posted", handler.bondsPosted());
        emit log_named_uint("bonds withdrawn", handler.bondsWithdrawn());
        emit log_named_uint("migrations started", handler.migrations());
    }

    /// @dev Deterministic proof the handler is not vacuous: the WRITE fee path and the migration must both be
    /// reachable, which is exactly what the existing auction suite cannot do.
    function test_handlerReachesEveryState() public {
        handler.depositWrite(5_000_000e18);
        handler.setWriteMode(0); // WRITE
        handler.collectFee(1_000e6);
        handler.flush();
        handler.postBond(0, 0);
        handler.startMigration(30 days);
        handler.postBond(0, 1);
        handler.warp(40 days);
        handler.withdrawBond(0, 0);

        assertGt(handler.writeDeposited(), 0, "prefunded WRITE");
        assertGt(handler.writeBurned(), 0, "the WRITE fee path actually fired");
        assertGt(handler.bondsPosted(), 0, "posted a bond");
        assertGt(handler.migrations(), 0, "started the migration");
    }
}
