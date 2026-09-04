// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev The WRITE fee mode (SPEC §11, D-011, D-084..D-089). The USDG mode is covered by the untouched
/// `FeeRouter.t.sol`; this file is only about the post-token path.
contract FeeRouterWriteTest is TokenBaseTest {
    uint256 internal constant CURATOR_WRITE = 1_000_000e18;
    uint256 internal round = 200;

    function _launchWriteMode() internal {
        vm.startPrank(admin);
        fr.setWriteToken(address(write));
        fr.setPriceOracle(address(wOracle));
        fr.setCurator(address(vault), curator);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);
        vm.stopPrank();
    }

    function _fundCurator(uint256 amount) internal {
        _grantWrite(curator, amount, round++);
        vm.startPrank(curator);
        write.approve(address(fr), type(uint256).max);
        fr.depositWrite(address(vault), amount);
        vm.stopPrank();
    }

    /// @dev Runs one full auction cycle and returns the fee it booked.
    function _cycleAndCollect() internal returns (uint256 fee) {
        _deposit(alice, DEPOSIT);
        uint256 id = _openDefault();
        _bid(mm1, id, 500e18, 2e6);
        (,,, fee) = _clear(id);
    }

    // ═════════════════════════════ launch gating (D-084) ═════════════════════════════

    function test_writePoolIsGone_gateIsTokenPlusOracle() public {
        (bool ok,) = address(fr).call(abi.encodeWithSignature("writePool()"));
        assertFalse(ok, "writePool was removed (D-084, superseding D-016)");
        assertEq(fr.writeToken(), address(0));
        assertEq(fr.priceOracle(), address(0));
    }

    function test_setFeeMode_revertsUntilBothAreWired() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeRouter.WriteNotLaunched.selector);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);

        fr.setWriteToken(address(write));
        vm.expectRevert(FeeRouter.WriteNotLaunched.selector);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);

        fr.setPriceOracle(address(wOracle));
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);
        vm.stopPrank();
        assertEq(uint256(fr.mode(address(vault))), uint256(IFeeRouter.FeeMode.WRITE));
    }

    function test_setWriteToken_onceOnlyAndMustBeAContract() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.Miswired.selector, bytes32("WRITE_TOKEN")));
        fr.setWriteToken(makeAddr("notAToken"));
        fr.setWriteToken(address(write));
        vm.expectRevert(FeeRouter.AlreadySet.selector);
        fr.setWriteToken(address(write));
        vm.stopPrank();
    }

    function test_setPriceOracle_assertsTheToken() public {
        WritePriceOracle wrong = new WritePriceOracle(address(usdg), address(usdg), address(usdgFeed), admin);
        vm.startPrank(admin);
        vm.expectRevert(FeeRouter.WriteNotLaunched.selector);
        fr.setPriceOracle(address(wOracle));
        fr.setWriteToken(address(write));
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.Miswired.selector, bytes32("ORACLE_WRITE")));
        fr.setPriceOracle(address(wrong));
        vm.stopPrank();
    }

    // ═════════════════════════════ curator balance (SPEC §11) ═════════════════════════════

    function test_depositWrite_creditsTheVault() public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);
        assertEq(fr.writeBalance(address(vault)), CURATOR_WRITE);
        assertEq(write.balanceOf(address(fr)), CURATOR_WRITE);
    }

    function test_withdrawWrite_onlyCuratorAndUnlocked() public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);

        vm.prank(alice);
        vm.expectRevert(FeeRouter.NotCurator.selector);
        fr.withdrawWrite(address(vault), 1e18);

        vm.prank(curator);
        fr.withdrawWrite(address(vault), 400_000e18);
        assertEq(fr.writeBalance(address(vault)), 600_000e18);
        assertEq(write.balanceOf(curator), 400_000e18, "no lock on withdrawals");
    }

    function test_withdrawWrite_cappedAtTheBalance() public {
        _launchWriteMode();
        _fundCurator(1_000e18);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.InsufficientWriteBalance.selector, 1_000e18, 1_001e18));
        fr.withdrawWrite(address(vault), 1_001e18);
    }

    // ═════════════════════════════ the WRITE flush ═════════════════════════════

    function test_flush_writeModeBurnsAndPaysTreasuryAndRebatesTheCurator() public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);
        uint256 fee = _cycleAndCollect();
        assertGt(fee, 0);

        (uint256 expectedWrite, bool ok) = fr.previewWriteFee(fee);
        assertTrue(ok);
        uint256 expectedBurn = expectedWrite * fr.writeBurnShareBps() / fr.BPS();
        uint256 supplyBefore = write.totalSupply();
        uint256 treasuryWriteBefore = write.balanceOf(treasury);
        uint256 curatorUsdgBefore = usdg.balanceOf(curator);

        fr.flush(address(vault));

        assertEq(supplyBefore - write.totalSupply(), expectedBurn, "half the WRITE fee is burned");
        assertEq(write.balanceOf(treasury) - treasuryWriteBefore, expectedWrite - expectedBurn, "rest to treasury");
        assertEq(usdg.balanceOf(curator) - curatorUsdgBefore, fee, "the USDG fee is rebated to the curator");
        assertEq(fr.writeBalance(address(vault)), CURATOR_WRITE - expectedWrite);
        assertEq(fr.pending(address(vault)), 0);
    }

    /// @dev The 20 % discount means the curator pays 80 % of the fee's USD value in WRITE.
    function test_flush_appliesTheTwentyPercentDiscount() public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);
        uint256 fee = _cycleAndCollect();

        uint256 price8 = _writePrice8();
        uint256 fullPriceWrite = fee * 1e20 / price8;
        (uint256 discounted,) = fr.previewWriteFee(fee);
        assertApproxEqRel(discounted, fullPriceWrite * 8 / 10, 1e12, "20 % cheaper than paying at par");
    }

    /// @dev Both conversion legs round up, so a curator never underpays by a rounding unit (D-088).
    function test_previewWriteFee_roundsUpInTheProtocolsFavour() public {
        _launchWriteMode();
        uint256 price8 = _writePrice8();
        uint256 fee = 100e6 + 1; // deliberately awkward
        (uint256 amount,) = fr.previewWriteFee(fee);

        uint256 discountedFloor = fee * 8000 / 10_000;
        uint256 exactFloor = discountedFloor * 1e20 / price8;
        assertGe(amount, exactFloor, "never less than the exact amount");
        // The two ceilings can add at most one 6-decimal USD unit (worth `1e20 / price8` WRITE-wei once
        // converted) plus one wei from the second rounding -- not two wei.
        assertLe(amount, exactFloor + 1e20 / price8 + 1, "and no more than the two ceilings can add");
    }

    function test_flush_usdgModeIsUnchanged() public {
        uint256 fee = _cycleAndCollect();
        uint256 before = usdg.balanceOf(treasury);
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury) - before, fee, "USDG mode still goes straight to treasury");
        assertEq(write.totalSupply(), 1_000_000_000e18, "and burns nothing");
    }

    // ═════════════════════════════ fallbacks (all non-reverting) ═════════════════════════════

    function test_flush_fallsBackOnInsufficientWriteBalance() public {
        _launchWriteMode();
        _fundCurator(1e18); // far too little
        uint256 fee = _cycleAndCollect();
        uint256 before = usdg.balanceOf(treasury);

        vm.expectEmit(true, false, false, true);
        emit FeeRouter.WriteModeFallback(address(vault), bytes32("INSUFFICIENT_WRITE"));
        fr.flush(address(vault));

        assertEq(usdg.balanceOf(treasury) - before, fee, "the USDG path took over");
        assertEq(fr.writeBalance(address(vault)), 1e18, "the curator's WRITE was not touched");
    }

    function test_flush_fallsBackWhenTheOracleHasNoPrice() public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);
        uint256 fee = _cycleAndCollect();
        writePool.setDead(true);
        uint256 before = usdg.balanceOf(treasury);

        vm.expectEmit(true, false, false, true);
        emit FeeRouter.WriteModeFallback(address(vault), bytes32("NO_PRICE"));
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury) - before, fee);
    }

    function test_flush_fallsBackWhenTheCuratorIsUnset() public {
        vm.startPrank(admin);
        fr.setWriteToken(address(write));
        fr.setPriceOracle(address(wOracle));
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);
        vm.stopPrank();
        uint256 fee = _cycleAndCollect();
        uint256 before = usdg.balanceOf(treasury);

        vm.expectEmit(true, false, false, true);
        emit FeeRouter.WriteModeFallback(address(vault), bytes32("CURATOR_UNSET"));
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury) - before, fee);
    }

    // ═════════════════════════════ threats ═════════════════════════════

    /// @dev T-07: `clear()` is permissionless and must never brick. The WRITE path lives entirely in `flush`
    /// (D-085), so `collect` is byte-for-byte what it always was and no oracle, burn or transfer can reach
    /// the clearing path. Driven here with every WRITE component broken at once.
    function test_T07_clearNeverRevertsBecauseOfTheWritePath() public {
        _launchWriteMode();
        _fundCurator(0.5e18); // not enough to pay any fee
        writePool.setDead(true); // and no price either

        _deposit(alice, DEPOSIT);
        uint256 id = _openDefault();
        _bid(mm1, id, 500e18, 2e6);
        (,,, uint256 fee) = _clear(id); // must not revert
        assertGt(fee, 0, "the fee was still booked");
        assertEq(fr.pending(address(vault)), fee);

        // And the flush degrades rather than stranding the fee.
        uint256 before = usdg.balanceOf(treasury);
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury) - before, fee);
    }

    /// @dev CLAUDE.md rule 7: nothing here pays WRITE holders. The fee is burned or sent to the treasury,
    /// and the rebate returns to the curator who funded it.
    function test_noHolderDistributionPathExists() public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);
        uint256 fee = _cycleAndCollect();
        uint256 stakerBefore = write.balanceOf(address(sm));
        fr.flush(address(vault));
        assertEq(write.balanceOf(address(sm)), stakerBefore, "not one token reaches the stakers");
        assertEq(usdg.balanceOf(address(sm)), 0, "and no USDG either");
        // The fee left the protocol only as a burn and a treasury credit, plus the curator's priced swap.
        assertGt(fee, 0, "a fee was actually charged");
        assertEq(sm.totalUnclaimedRewards(), 0, "no reward credit was created by a fee");
    }

    // ═════════════════════════════ parameters ═════════════════════════════

    function test_discountAndBurnShareAreBounded() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeRouter.OutOfBounds.selector);
        fr.setWriteDiscountBps(5001);
        vm.expectRevert(FeeRouter.OutOfBounds.selector);
        fr.setWriteBurnShareBps(10_001);
        fr.setWriteDiscountBps(1000);
        fr.setWriteBurnShareBps(10_000);
        vm.stopPrank();
        assertEq(fr.writeDiscountBps(), 1000);
        assertEq(fr.writeBurnShareBps(), 10_000);
    }

    function test_fullBurnShareSendsNothingToTreasury() public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);
        vm.prank(admin);
        fr.setWriteBurnShareBps(10_000);
        uint256 fee = _cycleAndCollect();
        (uint256 amount,) = fr.previewWriteFee(fee);
        uint256 supplyBefore = write.totalSupply();
        uint256 treasuryBefore = write.balanceOf(treasury);

        fr.flush(address(vault));
        assertEq(supplyBefore - write.totalSupply(), amount, "everything burned");
        assertEq(write.balanceOf(treasury), treasuryBefore);
    }

    function test_setCurator_onlyOwnerAndInitialisedVault() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fr.setCurator(address(vault), curator);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.NotInitialised.selector, alice));
        fr.setCurator(alice, curator);
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    /// @dev Drives a real `flush` and observes the three token movements, rather than asserting an identity
    /// on locally computed numbers -- which would pass with the split deleted from the contract.
    function testFuzz_flushWriteSplitConservesTheDebit(uint256 feeSeed) public {
        _launchWriteMode();
        _fundCurator(CURATOR_WRITE);
        uint256 fee = bound(feeSeed, 1e6, 100_000e6);

        usdg.mint(address(ah), fee);
        vm.prank(address(ah));
        fr.collect(address(vault), 1, fee);

        (uint256 expected, bool ok) = fr.previewWriteFee(fee);
        assertTrue(ok);
        uint256 supplyBefore = write.totalSupply();
        uint256 treasuryBefore = write.balanceOf(treasury);
        uint256 balanceBefore = fr.writeBalance(address(vault));

        fr.flush(address(vault));

        uint256 burned = supplyBefore - write.totalSupply();
        uint256 toTreasury = write.balanceOf(treasury) - treasuryBefore;
        uint256 debited = balanceBefore - fr.writeBalance(address(vault));
        assertEq(debited, expected, "the curator was debited exactly the quoted amount");
        assertEq(burned + toTreasury, debited, "burn + treasury == the whole debit");
        assertEq(burned, expected * fr.writeBurnShareBps() / fr.BPS(), "the burn share is exact");
    }

    function testFuzz_writeAmountScalesWithTheFee(uint256 a, uint256 b) public {
        _launchWriteMode();
        a = bound(a, 1e6, 10_000e6);
        b = bound(b, a, 100_000e6);
        (uint256 wa,) = fr.previewWriteFee(a);
        (uint256 wb,) = fr.previewWriteFee(b);
        assertLe(wa, wb, "a larger fee never costs less WRITE");
    }
}
