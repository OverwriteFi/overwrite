// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {CapController} from "../src/CapController.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {MerkleTreeLib} from "./utils/MerkleTreeLib.sol";
import {SeriesKind, VaultState} from "../src/Types.sol";

/// @dev One narrative covering the whole protocol with the token layer live: launch and wiring, staking,
/// the post-token deposit cap, two full auction cycles settling ITM and OTM, the performance fee taken once
/// in USDG and once in WRITE with its discount and burn, emissions, the bond migration, a Merkle points
/// claim, and finally a slash flowing back through the cap.
contract DayInTheLifeTest is TokenBaseTest {
    uint64 internal constant TEAM_CLIFF = 365 days;
    uint64 internal constant VEST_DURATION = 1095 days;
    uint256 internal constant CURATOR_WRITE = 5_000_000e18;
    uint256 internal constant WRITE_MM_BOND = 250_000e18;

    address[3] internal airdropees;
    uint256[3] internal airdropAmounts;
    bytes32[] internal leaves;

    function test_e2e_dayInTheLife() public {
        // ═══════════════ 1. the token launched into contracts, never into a wallet ═══════════════
        assertEq(write.totalSupply(), 1_000_000_000e18);
        assertEq(write.balanceOf(address(escrow)), 0, "the escrow already funded the launchpad");
        assertEq(write.balanceOf(address(launchpad)), 250_000_000e18);
        assertEq(write.balanceOf(address(emis)), 300_000_000e18);
        assertEq(write.balanceOf(address(treasuryVesting)), 200_000_000e18);
        assertEq(write.balanceOf(address(teamVesting)), 150_000_000e18);
        assertEq(write.balanceOf(address(points)), 100_000_000e18);

        // ═══════════════ 2. vesting: treasury cannot be revoked, team can ═══════════════
        vm.startPrank(admin);
        uint256 treasuryId =
            treasuryVesting.createSchedule(treasury, uint64(block.timestamp), 0, VEST_DURATION, 200_000_000e18, false);
        uint256 teamId = teamVesting.createSchedule(
            teamMember, uint64(block.timestamp), TEAM_CLIFF, VEST_DURATION, 50_000_000e18, true
        );
        vm.stopPrank();
        assertEq(treasuryVesting.vestedAmount(treasuryId, block.timestamp), 0);
        assertEq(teamVesting.vestedAmount(teamId, block.timestamp), 0, "inside the 12-month cliff");

        // ═══════════════ 3. the price oracle is live on the launch pool ═══════════════
        uint256 price8 = _writePrice8();
        assertApproxEqRel(price8, WRITE_PRICE_8, 1e14, "TWAP prices WRITE at ~$0.10");

        // ═══════════════ 4. stakers back the protocol ═══════════════
        _stake(staker1, STAKE_1);
        _stake(staker2, STAKE_2);
        assertEq(sm.totalStaked(), STAKE_1 + STAKE_2, "100 M WRITE staked");
        uint256 valueUSD = sm.valueUSD();
        assertApproxEqRel(valueUSD, 10_000_000e6, 1e14, "~$10 M of backstop, 6 decimals");
        assertEq(sm.safetyModuleValueUSD(), valueUSD);

        // ═══════════════ 5. the deposit cap switches to the post-token formula ═══════════════
        _enableSafetyModuleCap(10_000);
        uint256 expectedCap = valueUSD * cap.k() / 1e18;
        assertEq(cap.vaultCapUSD(address(vault)), expectedCap, "cap = k x safetyModuleValueUSD x weight");
        assertApproxEqRel(expectedCap, 50_000_000e6, 1e14, "k = 5 gives a ~$50 M cap");
        assertGt(vault.maxDeposit(alice), 0);

        // ═══════════════ 6. a depositor arrives ═══════════════
        uint256 headroomBefore = vault.maxDeposit(alice);
        _deposit(alice, DEPOSIT);
        assertEq(vault.totalAssets(), DEPOSIT);
        assertApproxEqRel(
            headroomBefore - vault.maxDeposit(alice), DEPOSIT, 1e12, "headroom shrank by exactly the deposit"
        );

        // ═══════════════ 7. series 1: auction and clearing ═══════════════
        uint256 id1 = _openDefault();
        _bid(mm1, id1, 400e18, 3e6);
        _bid(mm2, id1, 300e18, 2e6);
        _bid(mm3, id1, 200e18, 1.5e6);
        (, uint256 filled1, uint256 gross1, uint256 fee1) = _clear(id1);
        assertGt(filled1, 0);
        assertEq(fee1, gross1 * 1000 / 1e4, "10 % performance fee on premium");
        assertEq(fr.pending(address(vault)), fee1, "booked, not moved (clear can never be bricked by fees)");

        // ═══════════════ 8. series 1 settles ITM ═══════════════
        _settle(id1, 250e8); // strike 216
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
        uint256 ppo = _ppo(250e8, vault.series(id1).strike);
        assertGt(ppo, 0, "in the money: option holders are owed stock");
        assertLt(ppo, WAD, "I-2: payoutPerOption < 1e18");

        vm.prank(mm1);
        ah.claimOptions(id1, mm1);
        uint256 mm1Options = opt.balanceOf(mm1, id1);
        vm.prank(mm1);
        opt.claim(id1, mm1Options, mm1);
        assertGt(stock.balanceOf(mm1), 0, "the ITM holder was paid in stock");

        // ═══════════════ 9. the fee for series 1 is taken in USDG ═══════════════
        uint256 treasuryUsdgBefore = usdg.balanceOf(treasury);
        uint256 supplyBeforeUsdgFlush = write.totalSupply();
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury) - treasuryUsdgBefore, fee1, "USDG mode: straight to treasury");
        assertEq(write.totalSupply(), supplyBeforeUsdgFlush, "and nothing is burned");

        // ═══════════════ 10. the curator switches the vault to paying fees in WRITE ═══════════════
        vm.startPrank(admin);
        fr.setWriteToken(address(write));
        fr.setPriceOracle(address(wOracle));
        fr.setCurator(address(vault), curator);
        fr.setFeeMode(address(vault), IFeeRouter.FeeMode.WRITE);
        vm.stopPrank();

        _grantWrite(curator, CURATOR_WRITE, 3);
        vm.startPrank(curator);
        write.approve(address(fr), type(uint256).max);
        fr.depositWrite(address(vault), CURATOR_WRITE);
        vm.stopPrank();
        assertEq(fr.writeBalance(address(vault)), CURATOR_WRITE);

        // ═══════════════ 11. series 2: a fresh week, a new auction ═══════════════
        _nextWeek();
        uint256 id2 = _openDefault();
        _bid(mm2, id2, 300e18, 2e6);
        (,,, uint256 fee2) = _clear(id2);
        assertGt(fee2, 0);

        // ═══════════════ 12. series 2 settles OTM ═══════════════
        uint256 sharePriceBefore = vault.convertToAssets(WAD);
        _settle(id2, 190e8);
        assertEq(_ppo(190e8, vault.series(id2).strike), 0, "out of the money: nothing is owed");
        assertGe(vault.convertToAssets(WAD), sharePriceBefore, "depositors keep the whole premium");

        // ═══════════════ 13. the fee for series 2 is taken in WRITE, discounted and half burned ═══════════
        _refreshWriteOracle();
        (uint256 expectedWrite, bool priceOk) = fr.previewWriteFee(fee2);
        assertTrue(priceOk);
        uint256 expectedBurn = expectedWrite * fr.writeBurnShareBps() / fr.BPS();
        uint256 supplyBefore = write.totalSupply();
        uint256 treasuryWriteBefore = write.balanceOf(treasury);
        uint256 curatorUsdgBefore = usdg.balanceOf(curator);

        fr.flush(address(vault));

        assertEq(supplyBefore - write.totalSupply(), expectedBurn, "50 % of the WRITE fee is burned");
        assertEq(write.balanceOf(treasury) - treasuryWriteBefore, expectedWrite - expectedBurn, "the rest to treasury");
        assertEq(usdg.balanceOf(curator) - curatorUsdgBefore, fee2, "the USDG fee is rebated to the curator");
        assertEq(fr.writeBalance(address(vault)), CURATOR_WRITE - expectedWrite);
        assertGt(write.balanceOf(address(sm)), 0, "stakers hold their own principal, not fee proceeds");
        // CLAUDE.md rule 7: no fee reaches a token holder as revenue.
        assertEq(usdg.balanceOf(address(sm)), 0, "stakers receive no protocol revenue, ever");

        // ═══════════════ 14. emissions accrue to the stakers, pro rata ═══════════════
        sm.poke();
        uint256 pending1Before = sm.pendingRewards(staker1);
        uint256 pending2Before = sm.pendingRewards(staker2);
        uint256 t0 = block.timestamp;

        _warpWithOracles(14 days);
        sm.poke();

        // Emissions have been accruing since the stake in step 4, so the property is the delta over this
        // window, priced off `emis.rate()` rather than allocation/duration (which differ by integer division).
        uint256 emitted = emis.rate() * (block.timestamp - t0);
        uint256 delta = (sm.pendingRewards(staker1) - pending1Before) + (sm.pendingRewards(staker2) - pending2Before);
        assertApproxEqRel(delta, emitted, 1e13, "the window's emissions landed on the stakers");

        vm.prank(staker1);
        uint256 claimed1 = sm.claimRewards();
        assertEq(write.balanceOf(staker1), claimed1);
        assertApproxEqRel(claimed1 * 40, sm.pendingRewards(staker2) * 60, 1e13, "60/40 stake, 60/40 rewards");

        // ═══════════════ 15. the MM bond migrates from USDG to WRITE with no gap ═══════════════
        vm.startPrank(admin);
        bm.setWriteToken(address(write));
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.MM, WRITE_MM_BOND);
        bm.setRequiredAmountFor(IBondManager.BondAsset.WRITE, IBondManager.BondKind.CURATOR, 100_000e18);
        bm.startMigration(30 days);
        vm.stopPrank();

        assertTrue(bm.isBonded(mm1, IBondManager.BondKind.MM), "still bonded in USDG during grace");
        _grantWrite(mm1, WRITE_MM_BOND, 4);
        vm.startPrank(mm1);
        write.approve(address(bm), type(uint256).max);
        bm.postBondIn(IBondManager.BondKind.MM, IBondManager.BondAsset.WRITE);
        vm.stopPrank();

        vm.warp(uint256(bm.migrationEndsAt()) + 1);
        assertTrue(bm.isBonded(mm1, IBondManager.BondKind.MM), "no gap: the WRITE leg took over");
        assertTrue(bm.hasActiveMMBond(mm1), "and the AuctionHouse gate still sees it");

        uint256 mm1UsdgBefore = usdg.balanceOf(mm1);
        vm.prank(mm1);
        bm.withdrawBondIn(IBondManager.BondKind.MM, IBondManager.BondAsset.USDG);
        assertEq(usdg.balanceOf(mm1) - mm1UsdgBefore, 25_000e6, "the legacy bond was never stranded");

        // ═══════════════ 16. the points airdrop is claimed, and the tail swept ═══════════════
        _setupAirdrop();
        vm.prank(admin);
        points.setRound(
            9, MerkleTreeLib.root(leaves), 6_000e18, uint64(block.timestamp), uint64(block.timestamp + 7 days)
        );

        points.claim(9, 0, airdropees[0], airdropAmounts[0], MerkleTreeLib.proof(leaves, 0));
        assertEq(write.balanceOf(airdropees[0]), airdropAmounts[0], "a real Merkle claim, paid to the account");
        vm.expectRevert();
        points.claim(9, 0, airdropees[0], airdropAmounts[0], MerkleTreeLib.proof(leaves, 0));

        uint256 treasuryWritePreSweep = write.balanceOf(treasury);
        vm.warp(uint256(points.rounds(9).deadline) + 1);
        uint256 swept = points.sweep(9);
        assertEq(swept, 6_000e18 - airdropAmounts[0], "the unclaimed tail goes to treasury");
        assertEq(write.balanceOf(treasury) - treasuryWritePreSweep, swept);

        // ═══════════════ 17. a slash shrinks the backstop, and the cap follows it down ═══════════════
        _refreshWriteOracle();
        uint256 capBefore = cap.vaultCapUSD(address(vault));
        uint256 stakedBefore = sm.totalStaked();
        uint256 slashAmount = stakedBefore * 20 / 100;

        vm.prank(admin);
        sm.slash(slashAmount, shortfallReserve, "ipfs://shortfall-evidence");

        assertEq(write.balanceOf(shortfallReserve), slashAmount, "slashed WRITE is at the timelock's disposal");
        assertEq(sm.totalStaked(), stakedBefore - slashAmount);
        assertApproxEqRel(cap.vaultCapUSD(address(vault)), capBefore * 80 / 100, 1e13, "the cap fell 20 % with it");
        assertApproxEqRel(sm.stakedOf(staker1) + sm.stakedOf(staker2), sm.totalStaked(), 1e12, "loss shared pro rata");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Moves to the next Monday 14:00 UTC with every oracle leg answerable: the stock feed for the
    /// reference price and the deposit cap, the USDG feed for the peg check, and the WRITE pool for the TWAP.
    function _nextWeek() internal {
        uint256 target = _nextMonday1400(block.timestamp);
        // The stock feed must not go stale (80 h cap bound) across a 7-day gap.
        for (uint256 t = block.timestamp + 4 hours; t < target; t += 4 hours) {
            vm.warp(t);
            _feedRoundAt(t, PRICE);
        }
        vm.warp(target);
        _feedRoundAt(target - 30 minutes, PRICE);
        _refreshWriteOracle();
    }

    function _setupAirdrop() internal {
        airdropees = [makeAddr("air1"), makeAddr("air2"), makeAddr("air3")];
        airdropAmounts = [uint256(1_000e18), 2_000e18, 3_000e18];
        leaves = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            leaves[i] = points.leafHash(9, i, airdropees[i], airdropAmounts[i]);
        }
    }
}
