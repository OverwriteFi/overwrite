// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuctionBaseTest} from "../AuctionBase.t.sol";
import {AuctionHandler} from "./AuctionHandler.sol";
import {IAuctionHouse} from "../../src/interfaces/IAuctionHouse.sol";
import {ICoveredCallVault} from "../../src/interfaces/ICoveredCallVault.sol";
import {SeriesState, VaultState} from "../../src/Types.sol";

/// @dev Stateful invariants for AuctionHouse + BondManager + FeeRouter (SPEC §17 I-3, I-13, fee conservation,
/// preview == clear, no over-allocation). `fail_on_revert = true`.
contract AuctionInvariants is AuctionBaseTest {
    AuctionHandler internal h;

    function setUp() public override {
        super.setUp();
        address[] memory mms = new address[](4);
        mms[0] = mm1;
        mms[1] = mm2;
        mms[2] = mm3;
        mms[3] = mm4;
        address[] memory deps = new address[](2);
        deps[0] = alice;
        deps[1] = bob;
        h = new AuctionHandler(
            AuctionHandler.Deps({
                vault: vault,
                opt: opt,
                ah: ah,
                bm: bm,
                fr: fr,
                stock: stock,
                usdg: usdg,
                admin: admin,
                keeper: keeper,
                settlement: settlement,
                treasury: treasury
            }),
            mms,
            deps
        );
        targetContract(address(h));
    }

    /// @dev Coverage report per run (visible with -vv): the handler must actually reach open / bid / clear / settle.
    function afterInvariant() public {
        emit log_named_uint("calls", h.calls());
        emit log_named_uint("opens", h.opens());
        emit log_named_uint("bids", h.bidsPlaced());
        emit log_named_uint("clears", h.clears());
        emit log_named_uint("skips", h.skips());
        emit log_named_uint("settles", h.settles());
        emit log_named_uint("refunds withdrawn", h.refundsWithdrawn());
    }

    /// SPEC I-3 (exact): the AuctionHouse holds exactly the open escrow plus every refund not yet withdrawn.
    function invariant_I3_escrowExact() public view {
        uint256 refundable;
        for (uint256 i; i < h.mmCount(); ++i) {
            refundable += ah.refundable(h.mms(i));
        }
        assertEq(
            usdg.balanceOf(address(ah)), h.escrowOpenTotal() + refundable, "I-3: balance == open escrow + refundable"
        );
    }

    /// SPEC I-3 / D-043: for every closed auction, Σ escrow == Σ refunds credited + premiumNet + fee, to the unit.
    function invariant_I3_closedConservation() public view {
        assertEq(
            h.escrowClosed(), h.refundsCredited() + h.premiumNetTotal() + h.feeTotal(), "I-3: closed escrow conserved"
        );
    }

    /// SPEC I-3 allocation identity: claimable + outstanding tokens + claimed == filledQty, and the vault agrees.
    function invariant_I3_allocationIdentity() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            IAuctionHouse.Auction memory a = ah.auctions(id);
            ICoveredCallVault.VaultSeries memory s = vault.series(id);
            uint256 claimable;
            for (uint256 j; j < h.mmCount(); ++j) {
                claimable += ah.claimableOptions(id, h.mms(j));
            }
            assertEq(claimable + opt.totalSupply(id) + s.claimedQty, a.filledQty, "I-3: allocation identity");
            assertEq(s.filledQty, a.filledQty, "vault and auction agree on filledQty");
            assertLe(a.filledQty, a.offeredQty, "no over-allocation");
            if (a.state == IAuctionHouse.AuctionState.CLEARED) {
                assertGe(a.clearingPrice, a.reservePrice, "cleared at or above reserve");
                assertGt(a.filledQty, 0, "a cleared auction filled something");
                assertEq(a.premiumGross, a.fee + (a.premiumGross - a.fee));
            } else if (a.state == IAuctionHouse.AuctionState.SKIPPED) {
                assertEq(a.filledQty, 0);
                assertEq(uint256(s.state), uint256(SeriesState.SKIPPED));
            }
        }
    }

    /// Fees only ever sit in the router or the treasury.
    function invariant_feeConservation() public view {
        assertEq(fr.pending(address(vault)) + usdg.balanceOf(treasury), h.feeTotal(), "fee conservation");
        assertEq(usdg.balanceOf(address(fr)), fr.pending(address(vault)), "router balance == pending");
    }

    /// SPEC I-13: a filled bidder of the LIVE / HALTED series is locked and cannot withdraw its bond.
    function invariant_I13_bondLocks() public view {
        assertEq(h.withdrawWhileLocked(), 0, "I-13: no withdrawal while locked");
        VaultState st = vault.state();
        if (st != VaultState.LIVE && st != VaultState.HALTED) return;
        uint256 id = vault.currentSeriesId();
        for (uint256 j; j < h.mmCount(); ++j) {
            address mm = h.mms(j);
            if (h.hadFill(id, mm)) {
                assertTrue(bm.isLocked(mm, id), "I-13: filled bidder locked while the series is live");
                assertGt(bm.activeLocks(mm), 0);
            }
        }
    }

    /// `previewClear` never disagrees with `clear`.
    function invariant_previewMatchesClear() public view {
        assertEq(h.previewMismatches(), 0, "preview == clear");
    }

    /// The vault never stays in AUCTION once the window closed and someone called `clear` (skip paths work).
    function invariant_openAuctionMatchesVaultState() public view {
        uint256 id = ah.currentAuction(address(vault));
        if (id == 0) return;
        bool open = ah.auctions(id).state == IAuctionHouse.AuctionState.OPEN;
        assertEq(open, vault.state() == VaultState.AUCTION, "auction OPEN <=> vault AUCTION");
    }
}
