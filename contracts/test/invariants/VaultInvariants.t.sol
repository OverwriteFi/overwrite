// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {VaultHandler} from "./VaultHandler.sol";
import {ICoveredCallVault} from "../../src/interfaces/ICoveredCallVault.sol";
import {SeriesState, VaultState} from "../../src/Types.sol";

/// @dev Stateful invariants for CoveredCallVault + OptionToken (brief I1–I4, SPEC §17 I-1, I-2, I-3, I-4, I-8, I-16).
/// The handler includes issuer burns and pauses, guardian pauses, sunset, cap changes and a reentrant receiver.
contract VaultInvariants is BaseTest {
    VaultHandler internal h;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = mm;
        h = new VaultHandler(vault, opt, cap, stock, usdg, risk, priceSource, admin, auction, settlement, actors);
        targetContract(address(h));
    }

    /// I1: encumbered ≤ balance always; ≤ totalAssets unless the issuer burned vault tokens (SPEC I-1 coverage).
    function invariant_I1_encumberedCovered() public view {
        uint256 enc = vault.encumbered();
        assertLe(enc, stock.balanceOf(address(vault)) + h.issuerBurned(), "I1: encumbered <= balance (+ issuer burn)");
        if (h.issuerBurned() == 0) {
            assertLe(enc, stock.balanceOf(address(vault)), "I1: encumbered <= balance");
            assertLe(enc, vault.totalAssets(), "I1: encumbered <= totalAssets");
        }
        if (vault.state() == VaultState.LIVE || vault.state() == VaultState.HALTED) {
            assertEq(enc, vault.series(vault.currentSeriesId()).filledQty, "I1: encumbered == filledQty");
        }
    }

    /// I2: every claim on the vault is backed by tokens.
    function invariant_I2_claimsBacked() public view {
        uint256 sum;
        for (uint256 i; i < h.actorCount(); ++i) {
            sum += vault.convertToAssets(vault.balanceOf(h.actors(i)));
        }
        sum += vault.convertToAssets(vault.balanceOf(address(vault))); // escrowed redeem shares
        assertLe(sum, vault.totalAssets(), "I2: sum of share claims <= totalAssets");
        uint256 owed = vault.payoutOwed() + vault.withdrawalClaimableTotal() + vault.queuedDepositTokens();
        uint256 bal = stock.balanceOf(address(vault));
        // holds even after issuer burns of NAV: payouts are always set against what was available at settlement
        // (SPEC §9.7 step 5), so owed amounts never exceed the balance
        assertEq(vault.totalAssets() + owed, bal, "I2: totalAssets + owed == balance");
        assertLe(vault.payoutOwed(), bal, "I-2: payoutOwed backed");
    }

    /// SPEC §14: coverage restores option holders and nobody else. An injection never raises the payout past
    /// the value the series would have paid without the shortfall, `payoutOwed` stays backed by the balance
    /// after every injection, and the OptionToken mirror never drifts from the vault's authoritative rate.
    function invariant_I2_coverageBackedAndBounded() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            ICoveredCallVault.VaultSeries memory s = vault.series(id);
            if (s.state != SeriesState.SETTLED && s.state != SeriesState.RESOLVED) continue;
            uint256 full =
                s.settlementPrice > s.strike ? uint256(s.settlementPrice - s.strike) * 1e18 / s.settlementPrice : 0;
            assertLe(s.payoutPerOption, full, "coverage never pays above the unscaled payout");
            assertLt(s.payoutPerOption, 1e18, "I-2: payoutPerOption < 1e18");
            assertEq(opt.series(id).payoutPerOption, s.payoutPerOption, "the OptionToken mirror tracks the vault");
        }
        assertLe(vault.payoutOwed(), stock.balanceOf(address(vault)), "I-2: payoutOwed backed after injection");
    }

    /// I3: after settlement no series remains encumbered; IDLE means zero encumbrance.
    function invariant_I3_noEncumbranceAfterSettlement() public view {
        uint256 expected;
        for (uint256 i; i < h.seriesCount(); ++i) {
            ICoveredCallVault.VaultSeries memory s = vault.series(h.seriesIds(i));
            if (s.state == SeriesState.LIVE || s.state == SeriesState.HALTED) {
                expected += s.filledQty;
            } else if (s.state == SeriesState.SETTLED || s.state == SeriesState.RESOLVED) {
                assertTrue(opt.series(h.seriesIds(i)).settled, "I3: settled flag");
                assertLt(s.payoutPerOption, 1e18, "I-2: payoutPerOption < 1e18");
                assertTrue((s.state == SeriesState.RESOLVED) == (s.settlementPath >= 4), "path 4/5 <=> RESOLVED");
            }
        }
        assertEq(vault.encumbered(), expected, "I3: encumbered == sum of live filledQty");
        if (vault.state() == VaultState.IDLE) assertEq(vault.encumbered(), 0, "I3: IDLE => 0");
    }

    /// I4: a settlement that pays out zero never lowers the share price.
    function invariant_I4_zeroPayoutNeverLowersPrice() public view {
        assertEq(h.zeroPayoutPriceDrops(), 0, "I4");
    }

    /// SPEC I-8 (relaxed to non-decreasing for rounding): the share price only falls inside a paying settlement
    /// or through an issuer burn.
    function invariant_I8_priceNonDecreasingOutsideSettlement() public view {
        assertEq(h.nonSettlePriceDrops(), 0, "I-8");
    }

    /// SPEC I-4: premium conservation.
    function invariant_premiumConservation() public view {
        uint256 claimable;
        for (uint256 i; i < h.actorCount(); ++i) {
            claimable += vault.premiumClaimable(h.actors(i));
        }
        assertLe(claimable, usdg.balanceOf(address(vault)), "I-4: claimable backed by USDG");
        assertEq(usdg.balanceOf(address(vault)) + h.premiumClaimed(), h.premiumAccrued(), "I-4: no USDG leaks");
        assertLe(claimable + h.premiumClaimed(), h.premiumAccrued(), "I-4: never over-distribute");
    }

    /// SPEC I-16: option supply accounting and escrow bookkeeping.
    function invariant_I16_optionSupplyAndEscrow() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            ICoveredCallVault.VaultSeries memory s = vault.series(id);
            assertEq(opt.totalSupply(id) + s.claimedQty, s.mintedQty, "minted == outstanding + claimed");
            assertLe(s.mintedQty, s.filledQty, "minted <= filled");
        }
        assertEq(vault.balanceOf(address(vault)), vault.escrowedRedeemShares(), "escrow == vault share balance");
    }

    /// T-16: no reentrancy from the ERC-1155 receiver callback ever succeeds.
    function invariant_T16_noReentrancy() public view {
        assertEq(h.reenterer().reentrySuccesses(), 0, "T-16");
    }

    /// Guardian / sunset scope (SPEC §15, I-15): pauses and sunset never lock funds once the vault is IDLE.
    function invariant_I15_idleAlwaysWithdrawable() public view {
        if (vault.state() != VaultState.IDLE) return;
        for (uint256 i; i < h.actorCount(); ++i) {
            address a = h.actors(i);
            assertEq(vault.maxRedeem(a), vault.balanceOf(a), "I-15: IDLE => all shares redeemable");
        }
    }

    /// @dev Deterministic proof the handler is not vacuous on the shortfall path: a random walk has to burn
    /// through more than half the collateral between the clear and settlement before an injection is even
    /// possible, so the two ghosts the coverage invariant leans on are driven explicitly here.
    function test_handlerReachesShortfallAndInjection() public {
        h.deposit(0, 100e18);
        h.openSeries(200e8, 1 days, 0);
        h.mintSeries(type(uint256).max, 0); // fill the whole offered quantity
        h.mintOptions(0, type(uint256).max);
        // the issuer burns 10 % of NAV per call; ten of them put the payout above what is left
        for (uint256 i; i < 10; ++i) {
            h.issuerBurn(type(uint256).max);
        }
        h.settle(400e8, 1); // S = 2K → the unscaled payout is 0.5, well above the remaining collateral
        assertGt(h.shortfalls(), 0, "the burn produced a recorded shortfall");

        h.injectCoverage(0, type(uint256).max);
        assertGt(h.injections(), 0, "coverage was injected");
        assertGt(h.injected(), 0, "and tokens actually moved");
        assertGt(h.fullRestores(), 0, "an over-sized injection clamps to a full restore");
        assertEq(h.nonSettlePriceDrops(), 0, "I-8: the injection did not move the share price");

        invariant_I2_coverageBackedAndBounded();
        invariant_I2_claimsBacked();
    }
}
