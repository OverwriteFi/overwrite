// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {ICoveredCallVault} from "../src/interfaces/ICoveredCallVault.sol";
import {SeriesKind} from "../src/Types.sol";

contract CoveredCallVaultFuzzTest is BaseTest {
    uint256 internal constant MAX_DEP = 1_000_000e18;

    // ───────────────────────────── deposit / withdraw math ─────────────────────────────

    function testFuzz_depositRedeemRoundTrip_neverProfits(uint256 assets) public {
        assets = bound(assets, 1, MAX_DEP);
        uint256 shares = _deposit(alice, assets);
        assertEq(vault.previewRedeem(shares), assets);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertLe(got, assets);
        assertGe(got + 1, assets); // offset-6 rounding loses at most 1 wei
    }

    function testFuzz_twoDepositors_conserve(uint256 a, uint256 b) public {
        a = bound(a, 1, MAX_DEP);
        b = bound(b, 1, MAX_DEP);
        uint256 sa = _deposit(alice, a);
        uint256 sb = _deposit(bob, b);
        vm.prank(alice);
        uint256 ga = vault.redeem(sa, alice, alice);
        vm.prank(bob);
        uint256 gb = vault.redeem(sb, bob, bob);
        assertLe(ga, a);
        assertLe(gb, b);
        assertLe(ga + gb, a + b);
        assertGe(ga + gb + 2, a + b);
    }

    function testFuzz_previewsMatchExecution(uint256 a, uint256 w) public {
        a = bound(a, 1, MAX_DEP);
        uint256 pd = vault.previewDeposit(a);
        uint256 shares = _deposit(alice, a);
        assertEq(shares, pd);
        _deposit(bob, a / 3 + 1); // perturb the ratio
        w = bound(w, 1, a);
        uint256 pw = vault.previewWithdraw(w);
        vm.prank(alice);
        uint256 burned = vault.withdraw(w, alice, alice);
        assertEq(burned, pw);
        uint256 left = vault.balanceOf(alice);
        uint256 pr = vault.previewRedeem(left);
        if (pr == 0) {
            // audit N-1: a redeem that would pay nothing is refused instead of burning the shares
            vm.prank(alice);
            vm.expectRevert(CoveredCallVault.ZeroAmount.selector);
            vault.redeem(left, alice, alice);
            return;
        }
        vm.prank(alice);
        uint256 got = vault.redeem(left, alice, alice);
        assertEq(got, pr);
    }

    function testFuzz_T06_inflationAttackUnprofitable(uint256 donation, uint256 victim) public {
        // attacker deposits 1 wei, donates, victim deposits; attacker never ends with more than deposited+donated
        donation = bound(donation, 1, 1_000e18);
        victim = bound(victim, 1, 1_000e18);
        _deposit(mm, 1);
        vm.prank(mm);
        stock.transfer(address(vault), donation);
        uint256 vShares = _deposit(alice, victim);
        uint256 mmShares = vault.balanceOf(mm);
        vm.prank(mm);
        uint256 attackerOut = vault.redeem(mmShares, mm, mm);
        assertLe(attackerOut, 1 + donation, "T-06: attacker never gets back more than deposit + donation");
        uint256 victimOut;
        if (vShares > 0) {
            vm.prank(alice);
            victimOut = vault.redeem(vShares, alice, alice);
        }
        // With offset 6 the attacker must donate 1e6 × the amount they hope to strand: the victim's loss is
        // bounded by the value of one share unit, i.e. donation / 1e6 (+1 wei rounding).
        assertLe(victim - victimOut, donation / 1e6 + 1, "T-06: victim loss <= donation / 1e6 + 1");
    }

    // ───────────────────────────── series / coverage ─────────────────────────────

    function testFuzz_mintSeries_boundedByOfferedAndFree(uint256 dep, uint256 qty) public {
        dep = bound(dep, 1, MAX_DEP);
        _deposit(alice, dep);
        (uint256 id, uint256 offered) = _open(210e8);
        assertEq(offered, dep);
        qty = bound(qty, 0, dep * 2);
        vm.prank(auction);
        if (qty == 0) {
            vm.expectRevert(CoveredCallVault.ZeroAmount.selector);
            vault.mintSeries(id, qty, 0);
        } else if (qty > offered) {
            vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.ExceedsOffered.selector, qty, offered));
            vault.mintSeries(id, qty, 0);
        } else {
            vault.mintSeries(id, qty, 0);
            assertEq(vault.encumbered(), qty);
            assertLe(vault.encumbered(), vault.totalAssets());
            assertEq(vault.freeAssets(), dep - qty);
        }
    }

    function testFuzz_payoutFormula(uint128 s, uint128 k, uint256 dep) public {
        s = uint128(bound(s, 1, type(uint128).max / 2));
        k = uint128(bound(k, 1, type(uint128).max / 2));
        dep = bound(dep, 1, MAX_DEP);
        _deposit(alice, dep);
        (uint256 id, uint256 filled) = _openAndClear(k, 0);
        _settle(id, s, 1);
        uint256 ppo = vault.series(id).payoutPerOption;
        assertLt(ppo, WAD, "I-2: payoutPerOption < 1e18");
        if (s <= k) {
            assertEq(ppo, 0);
            assertEq(vault.payoutOwed(), 0);
        } else {
            assertEq(ppo, uint256(s - k) * WAD / s); // may floor to 0 when S − K < S / 1e18
        }
        uint256 payout = filled * ppo / WAD;
        assertEq(vault.payoutOwed(), payout);
        assertLe(payout, filled);
        assertLe(vault.payoutOwed(), stock.balanceOf(address(vault)), "I-2: payoutOwed backed");
        assertEq(vault.totalAssets() + vault.payoutOwed(), stock.balanceOf(address(vault)));
        assertEq(vault.encumbered(), 0, "I3: nothing encumbered after settlement");
    }

    // ───────────────────────────── injectCoverage (SPEC §14) ─────────────────────────────

    /// @dev Settles a series whose payout was scaled down by an issuer burn. The bounds guarantee a shortfall:
    /// `s > 2k` puts the unscaled payout above 0.5, and at least half the collateral is burned.
    function _shortfall(uint128 s, uint128 k, uint256 dep, uint256 burnBps)
        internal
        returns (uint256 id, uint256 filled)
    {
        _deposit(alice, dep);
        (id, filled) = _openAndClear(k, 0);
        _mintOptions(id, mm, filled);
        vm.prank(admin);
        stock.burn(address(vault), dep * burnBps / 10_000);
        _settle(id, s, 1);
    }

    /// @dev Reference implementation of the injection maths in plain arithmetic (SPEC §14): `rem` and the
    /// payouts are well under 2^128, so no product here can overflow. Used both to skip draws too small to
    /// move the rate by one wei — a documented revert, not a property under test — and to cross-check `mulDiv`.
    function _previewInject(uint256 id, uint256 tokens, uint256 full) internal view returns (uint256 pulled) {
        ICoveredCallVault.VaultSeries memory sr = vault.series(id);
        uint256 rem = sr.filledQty - sr.claimedQty;
        uint256 ppoOld = sr.payoutPerOption;
        uint256 owedNow = rem * ppoOld / WAD;
        uint256 need = rem * full / WAD - owedNow;
        uint256 budget = tokens < need ? tokens : need;
        uint256 ppoNew = budget == need ? full : ppoOld + budget * WAD / rem;
        pulled = rem * ppoNew / WAD - owedNow;
    }

    function _inject(uint256 id, uint256 tokens) internal returns (uint256 pulled) {
        vm.startPrank(admin);
        stock.mint(admin, tokens);
        stock.approve(address(vault), tokens);
        uint256 before = stock.balanceOf(admin);
        vault.injectCoverage(id, tokens);
        pulled = before - stock.balanceOf(admin);
        vm.stopPrank();
    }

    /// @dev An injection never raises the payout past the unscaled value, never pulls more than it was
    /// offered, and never moves the share price — whatever the caller passes.
    function testFuzz_injectCoverageNeverExceedsUnscaled(
        uint128 s,
        uint128 k,
        uint256 dep,
        uint256 burnBps,
        uint256 tokensSeed
    ) public {
        k = uint128(bound(k, 1e8, 1_000e8));
        s = uint128(bound(s, uint256(k) * 2 + 1, 10_000e8));
        dep = bound(dep, 1e18, MAX_DEP);
        burnBps = bound(burnBps, 5_000, 9_900);
        (uint256 id,) = _shortfall(s, k, dep, burnBps);

        uint256 full = _ppo(s, k);
        uint256 need = vault.coverageNeeded(id);
        assertGt(need, 0, "the bounds guarantee a shortfall");
        uint256 tokens = bound(tokensSeed, 1, need * 3 + 1);
        uint256 expected = _previewInject(id, tokens, full);
        if (expected == 0) return;

        uint256 priceBefore = _sharePrice();
        uint256 pulled = _inject(id, tokens);
        assertEq(pulled, expected, "matches the reference maths");

        uint256 ppo = vault.series(id).payoutPerOption;
        assertLe(ppo, full, "never above the unscaled payout");
        assertLt(ppo, WAD, "I-2: payoutPerOption < 1e18");
        assertLe(pulled, tokens, "`tokens` is an upper bound");
        assertEq(_sharePrice(), priceBefore, "the share price never moves");
        assertLe(vault.payoutOwed(), stock.balanceOf(address(vault)), "I-2: payoutOwed backed");
        assertEq(opt.series(id).payoutPerOption, ppo, "the OptionToken mirror follows");
        if (tokens >= need) {
            assertEq(ppo, full, "a sufficient injection restores 100 %");
            assertEq(pulled, need, "and pulls exactly what was needed");
            assertEq(vault.coverageNeeded(id), 0);
        }
    }

    /// @dev Claims before and after an injection can never underflow `payoutOwed`, however the raise is split.
    function testFuzz_injectCoverageClaimsNeverUnderflow(
        uint128 s,
        uint128 k,
        uint256 dep,
        uint256 burnBps,
        uint256 claimBps,
        uint256 tokensSeed
    ) public {
        k = uint128(bound(k, 1e8, 1_000e8));
        s = uint128(bound(s, uint256(k) * 2 + 1, 10_000e8));
        dep = bound(dep, 1e18, MAX_DEP);
        burnBps = bound(burnBps, 5_000, 9_900);
        (uint256 id, uint256 filled) = _shortfall(s, k, dep, burnBps);

        uint256 first = filled * bound(claimBps, 0, 9_999) / 10_000;
        if (first > 0) {
            vm.prank(mm);
            opt.claim(id, first, mm);
        }

        uint256 rem = filled - first;
        uint256 need = vault.coverageNeeded(id);
        if (need == 0) return; // everything already claimed at the scaled rate
        uint256 tokens = bound(tokensSeed, 1, need * 3 + 1);
        if (_previewInject(id, tokens, _ppo(s, k)) == 0) return;
        _inject(id, tokens);

        // the remainder must still be claimable: `payoutOwed` is never left short of what it owes
        vm.prank(mm);
        opt.claim(id, rem, mm);
        assertEq(vault.series(id).claimedQty, filled, "every option was claimed");
        assertLe(vault.payoutOwed(), 1, "at most one wei of settlement rounding dust is left behind");
        assertLe(vault.payoutOwed(), stock.balanceOf(address(vault)), "I-2: payoutOwed backed");
    }

    function testFuzz_zeroPayoutNeverLowersSharePrice(uint128 s, uint128 k, uint256 dep, uint256 premium) public {
        k = uint128(bound(k, 1, type(uint128).max / 2));
        s = uint128(bound(s, 1, k)); // S ≤ K → zero payout
        dep = bound(dep, 1, MAX_DEP);
        premium = bound(premium, 0, 1e12);
        _deposit(alice, dep);
        (uint256 id,) = _openAndClear(k, premium);
        uint256 before = _sharePrice();
        _settle(id, s, 1);
        assertGe(_sharePrice(), before, "I4");
        assertEq(vault.totalAssets(), dep);
    }

    function testFuzz_claimsNeverExceedPayoutOwed(uint128 s, uint256 dep, uint256 split) public {
        uint128 k = 200e8;
        s = uint128(bound(s, k + 1, 100_000e8));
        dep = bound(dep, 2, MAX_DEP);
        _deposit(alice, dep);
        (uint256 id, uint256 filled) = _openAndClear(k, 0);
        split = bound(split, 1, filled - 1);
        _mintOptions(id, mm, split);
        _mintOptions(id, bob, filled - split);
        _settle(id, s, 2);
        uint256 owed = vault.payoutOwed();
        vm.prank(mm);
        uint256 g1 = opt.claim(id, split, mm);
        vm.prank(bob);
        uint256 g2 = opt.claim(id, filled - split, bob);
        assertLe(g1 + g2, owed);
        assertGe(g1 + g2 + 1, owed, "sum of floors loses at most 1 wei");
        assertEq(vault.payoutOwed(), owed - g1 - g2);
    }

    // ───────────────────────────── queues ─────────────────────────────

    function testFuzz_queuedDeposit_pricedLikeDirect(uint256 a, uint256 b, uint128 s) public {
        a = bound(a, 1, MAX_DEP);
        b = bound(b, 1, MAX_DEP);
        s = uint128(bound(s, 100e8, 400e8));
        _deposit(alice, a);
        (uint256 id,) = _openAndClear(200e8, 0);
        vm.prank(bob);
        vault.requestDeposit(b, bob);
        _settle(id, s, 1); // may be ITM: bob must be priced post-settlement
        // bob executed inside settle; compare against a direct deposit at the same price now
        uint256 bobShares = vault.balanceOf(bob);
        uint256 previewNow = vault.previewDeposit(b);
        // share price is unchanged by bob's own deposit up to rounding, so the two agree within 1 share unit / 1e6
        assertApproxEqRel(bobShares, previewNow, 1e12); // 1e-6 relative
        assertGt(bobShares, 0);
    }

    function testFuzz_premiumProportional(uint256 a, uint256 b, uint256 premium) public {
        a = bound(a, 1e6, MAX_DEP);
        b = bound(b, 1e6, MAX_DEP);
        premium = bound(premium, 0, 1e13);
        _deposit(alice, a);
        _deposit(bob, b);
        _openAndClear(210e8, premium);
        uint256 pa = vault.premiumClaimable(alice);
        uint256 pb = vault.premiumClaimable(bob);
        assertLe(pa + pb, premium, "I-4 premium conservation");
        assertGe(pa + pb + 2, premium);
        uint256 expectA = premium * vault.balanceOf(alice) / vault.totalSupply();
        assertApproxEqAbs(pa, expectA, 1);
        assertEq(usdg.balanceOf(address(vault)), premium);
    }

    function testFuzz_requestRedeem_escrowConserved(uint256 dep, uint256 part) public {
        dep = bound(dep, 1, MAX_DEP);
        uint256 shares = _deposit(alice, dep);
        (uint256 id,) = _openAndClear(210e8, 0);
        part = bound(part, 1, shares);
        vm.prank(alice);
        vault.requestRedeem(part, alice);
        assertEq(vault.balanceOf(alice) + vault.balanceOf(address(vault)), shares);
        assertEq(vault.escrowedRedeemShares(), part);
        _settle(id, 210e8, 1);
        assertEq(vault.escrowedRedeemShares(), 0);
        assertEq(vault.withdrawalClaimable(alice), vault.withdrawalClaimableTotal());
        assertEq(
            vault.totalAssets() + vault.withdrawalClaimableTotal() + vault.payoutOwed(), stock.balanceOf(address(vault))
        );
        uint256 claimable = vault.withdrawalClaimable(alice);
        if (claimable > 0) {
            vm.prank(alice);
            uint256 got = vault.claimWithdrawal(alice);
            assertEq(got, claimable);
            assertLe(got, dep);
        }
    }
}
