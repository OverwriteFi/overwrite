// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {ICoveredCallVault} from "../src/interfaces/ICoveredCallVault.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CoveredCallVaultTest is BaseTest {
    uint128 internal constant K = 210e8;

    // ═════════════════════════════ construction ═════════════════════════════

    function test_constructor_wiring() public view {
        assertEq(vault.decimals(), 24); // 18 + offset 6
        assertEq(vault.asset(), address(stock));
        assertEq(address(vault.stock()), address(stock));
        assertEq(vault.auctionHouse(), auction);
        assertEq(vault.settlement(), settlement);
        assertEq(vault.owner(), admin);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        assertEq(vault.maxQueueOpsPerOpen(), 50);
    }

    function test_constructor_revertsZeroAddress() public {
        CoveredCallVault.Config memory c = CoveredCallVault.Config({
            stock: address(stock),
            usdg: address(usdg),
            optionToken: address(opt),
            auctionHouse: address(0),
            settlement: settlement,
            riskModule: address(risk),
            capController: address(cap),
            owner: admin,
            name: "x",
            symbol: "x"
        });
        vm.expectRevert(CoveredCallVault.ZeroAddress.selector);
        new CoveredCallVault(c);
    }

    // ═════════════════════════════ deposit / mint ═════════════════════════════

    function test_deposit_idle() public {
        uint256 shares = _deposit(alice, 100e18);
        assertEq(shares, 100e18 * 1e6);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(stock.balanceOf(address(vault)), 100e18);
        assertEq(vault.freeAssets(), 100e18);
    }

    function test_mint_idle() public {
        vm.prank(alice);
        uint256 assets = vault.mint(50e24, alice);
        assertEq(assets, 50e18);
        assertEq(vault.balanceOf(alice), 50e24);
    }

    function test_deposit_revertsOutsideIdle() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
        vm.expectRevert(CoveredCallVault.VaultNotIdle.selector);
        _deposit(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(CoveredCallVault.VaultNotIdle.selector);
        vault.mint(1e24, bob);
        _clear(id, 100e18, 0);
        vm.expectRevert(CoveredCallVault.VaultNotIdle.selector);
        _deposit(bob, 1e18);
        vm.prank(settlement);
        vault.haltSeries(id, "NO_ORACLE_PATH");
        vm.expectRevert(CoveredCallVault.VaultNotIdle.selector);
        _deposit(bob, 1e18);
    }

    function test_deposit_revertsWhenPaused() public {
        risk.setDepositsPaused(address(vault), true);
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert(CoveredCallVault.DepositsPaused.selector);
        _deposit(alice, 1e18);
    }

    function test_deposit_revertsWhenSunset() public {
        vm.prank(admin);
        vault.setSunset();
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert(CoveredCallVault.VaultSunsetted.selector);
        _deposit(alice, 1e18);
    }

    function test_deposit_revertsWhenCapPriceUnavailable() public {
        priceSource.set(address(vault), PRICE, false);
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert(CoveredCallVault.CapPriceUnavailable.selector);
        _deposit(alice, 1e18);
    }

    function test_deposit_capEnforced() public {
        vm.prank(admin);
        cap.setCapUSD(address(vault), 25_000e6); // 125 tokens at $200
        assertEq(vault.maxDeposit(alice), 125e18);
        _deposit(alice, 100e18);
        assertEq(vault.maxDeposit(alice), 25e18);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 25e18 + 1, 25e18));
        _deposit(bob, 25e18 + 1);
        _deposit(bob, 25e18);
        assertEq(vault.maxDeposit(bob), 0);
    }

    // ═════════════════════════════ withdraw / redeem ═════════════════════════════

    function test_withdraw_and_redeem_idle() public {
        uint256 shares = _deposit(alice, 100e18);
        vm.startPrank(alice);
        uint256 burned = vault.withdraw(40e18, alice, alice);
        assertEq(burned, 40e18 * 1e6);
        uint256 got = vault.redeem(shares - burned, bob, alice);
        vm.stopPrank();
        assertEq(got, 60e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(stock.balanceOf(bob), 1_000_000e18 + 60e18);
    }

    function test_withdraw_revertsOutsideIdle() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        vm.startPrank(alice);
        vm.expectRevert(CoveredCallVault.WithdrawalsClosed.selector);
        vault.withdraw(1e18, alice, alice);
        vm.expectRevert(CoveredCallVault.WithdrawalsClosed.selector);
        vault.redeem(1e24, alice, alice);
        vm.stopPrank();
        _clear(id, 100e18, 0);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.WithdrawalsClosed.selector);
        vault.redeem(1e24, alice, alice);
    }

    function test_withdraw_worksWhilePausedAndSunset() public {
        _deposit(alice, 100e18);
        risk.setDepositsPaused(address(vault), true);
        risk.setAuctionsPaused(address(vault), true);
        vm.prank(admin);
        vault.setSunset();
        assertEq(vault.maxWithdraw(alice), 100e18);
        vm.prank(alice);
        vault.withdraw(100e18, alice, alice);
        assertEq(vault.totalAssets(), 0);
    }

    // ═════════════════════════════ deposit queue ═════════════════════════════

    function test_requestDeposit_anyState() public {
        _deposit(alice, 100e18);
        vm.prank(bob);
        uint256 id0 = vault.requestDeposit(10e18, bob); // IDLE (D-032)
        (uint256 sid,) = _open(K);
        vm.prank(bob);
        uint256 id1 = vault.requestDeposit(5e18, carol); // AUCTION
        _clear(sid, 100e18, 0);
        vm.prank(bob);
        uint256 id2 = vault.requestDeposit(1e18, bob); // LIVE
        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2);
        // id0 was executed inside openSeries (D-032); id1 and id2 wait for the next IDLE
        assertEq(uint8(vault.queuedDeposit(id0).status), uint8(CoveredCallVault.RequestStatus.EXECUTED));
        assertEq(vault.series(sid).offeredQty, 110e18);
        assertEq(vault.queuedDepositTokens(), 6e18);
        assertEq(vault.totalAssets(), 110e18, "queued tokens are not the vault's");
        assertEq(stock.balanceOf(address(vault)), 116e18);
        CoveredCallVault.DepositRequest memory r = vault.queuedDeposit(id1);
        assertEq(r.requester, bob);
        assertEq(r.receiver, carol);
        assertEq(r.assets, 5e18);
        assertEq(uint8(r.status), uint8(CoveredCallVault.RequestStatus.QUEUED));
    }

    function test_requestDeposit_reverts() public {
        vm.prank(bob);
        vm.expectRevert(CoveredCallVault.ZeroAmount.selector);
        vault.requestDeposit(0, bob);
        vm.prank(bob);
        vm.expectRevert(CoveredCallVault.ZeroAddress.selector);
        vault.requestDeposit(1, address(0));
        risk.setDepositsPaused(address(vault), true);
        vm.prank(bob);
        vm.expectRevert(CoveredCallVault.DepositsPaused.selector);
        vault.requestDeposit(1e18, bob);
        risk.setDepositsPaused(address(vault), false);
        vm.prank(admin);
        vault.setSunset();
        vm.prank(bob);
        vm.expectRevert(CoveredCallVault.VaultSunsetted.selector);
        vault.requestDeposit(1e18, bob);
    }

    function test_cancelDeposit() public {
        vm.prank(bob);
        uint256 id = vault.requestDeposit(10e18, bob);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotRequester.selector);
        vault.cancelDeposit(id);
        uint256 before = stock.balanceOf(bob);
        vm.prank(bob);
        vault.cancelDeposit(id);
        assertEq(stock.balanceOf(bob) - before, 10e18);
        assertEq(vault.queuedDepositTokens(), 0);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(CoveredCallVault.BadRequestStatus.selector, CoveredCallVault.RequestStatus.CANCELLED)
        );
        vault.cancelDeposit(id);
    }

    function test_processDeposits_onlyIdleAndSamePriceAsDirect() public {
        _deposit(alice, 100e18);
        vm.prank(bob);
        vault.requestDeposit(10e18, bob);
        (uint256 sid,) = _open(K);
        // queue processing in open executed bob's request: offered includes it
        assertEq(vault.series(sid).offeredQty, 110e18);
        vm.prank(carol);
        vault.requestDeposit(10e18, carol);
        vm.expectRevert(CoveredCallVault.VaultNotIdle.selector);
        vault.processDeposits(10);
        _clear(sid, 110e18, 0);
        _settle(sid, K - 1, 1); // OTM, processes queue
        uint256 expected = vault.previewDeposit(10e18);
        // carol executed inside settle at the post-settlement price; bob executed at open.
        assertEq(vault.balanceOf(carol), expected, "queued deposit priced like a direct deposit");
        assertEq(vault.balanceOf(carol), vault.balanceOf(bob));
        assertEq(vault.queuedDepositTokens(), 0);
        assertEq(vault.totalAssets(), 120e18);
    }

    function test_processDeposits_expiresOverCapAndContinues() public {
        vm.prank(admin);
        cap.setCapUSD(address(vault), 25_000e6); // 125 tokens
        _deposit(alice, 100e18);
        vm.prank(bob);
        uint256 big = vault.requestDeposit(30e18, bob); // does not fit (25 left)
        vm.prank(carol);
        uint256 small = vault.requestDeposit(20e18, carol);
        vm.expectEmit(true, false, false, true);
        emit CoveredCallVault.DepositRequestExpired(big);
        vault.processDeposits(10);
        assertEq(uint8(vault.queuedDeposit(big).status), uint8(CoveredCallVault.RequestStatus.EXPIRED));
        assertEq(uint8(vault.queuedDeposit(small).status), uint8(CoveredCallVault.RequestStatus.EXECUTED));
        assertEq(vault.balanceOf(carol), 20e18 * 1e6);
        assertEq(vault.queuedDepositTokens(), 30e18, "expired tokens stay refundable");
        uint256 before = stock.balanceOf(bob);
        vm.prank(bob);
        vault.cancelDeposit(big);
        assertEq(stock.balanceOf(bob) - before, 30e18);
        assertEq(vault.queuedDepositTokens(), 0);
        (uint256 pending,) = vault.queueLengths();
        assertEq(pending, 0);
    }

    function test_processDeposits_stopsWithoutPriceOrWhenPaused() public {
        vm.prank(bob);
        vault.requestDeposit(10e18, bob);
        priceSource.set(address(vault), PRICE, false);
        vault.processDeposits(10);
        assertEq(uint8(vault.queuedDeposit(0).status), uint8(CoveredCallVault.RequestStatus.QUEUED));
        assertEq(vault.depositQueueHead(), 0);
        priceSource.set(address(vault), PRICE, true);
        risk.setDepositsPaused(address(vault), true);
        vault.processDeposits(10);
        assertEq(vault.depositQueueHead(), 0);
        risk.setDepositsPaused(address(vault), false);
        vault.processDeposits(10);
        assertEq(vault.depositQueueHead(), 1);
        assertEq(vault.balanceOf(bob), 10e24);
    }

    function test_processDeposits_skipsCancelledEntries() public {
        vm.prank(bob);
        uint256 a = vault.requestDeposit(10e18, bob);
        vm.prank(carol);
        vault.requestDeposit(5e18, carol);
        vm.prank(bob);
        vault.cancelDeposit(a);
        vault.processDeposits(1); // the cancelled entry consumes the single op (T-18 bound)
        assertEq(vault.depositQueueHead(), 1);
        assertEq(vault.balanceOf(carol), 0);
        vault.processDeposits(1);
        assertEq(vault.depositQueueHead(), 2);
        assertEq(vault.balanceOf(carol), 5e24);
    }

    function test_processDeposits_stopsWhenCapFullInsteadOfExpiring() public {
        vm.prank(admin);
        cap.setCapUSD(address(vault), 20_000e6); // exactly 100 tokens at $200
        vm.prank(bob);
        vault.requestDeposit(10e18, bob);
        _deposit(alice, 100e18); // cap now fully used
        vault.processDeposits(10);
        assertEq(uint8(vault.queuedDeposit(0).status), uint8(CoveredCallVault.RequestStatus.QUEUED), "waits");
        assertEq(vault.depositQueueHead(), 0);
        vm.prank(alice);
        vault.withdraw(50e18, alice, alice); // headroom again
        vault.processDeposits(10);
        assertEq(uint8(vault.queuedDeposit(0).status), uint8(CoveredCallVault.RequestStatus.EXECUTED));
    }

    // ═════════════════════════════ redeem queue ═════════════════════════════

    function test_requestRedeem_revertsInIdle() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.VaultIsIdle.selector);
        vault.requestRedeem(1e24, alice);
    }

    function test_requestRedeem_escrowsShares() public {
        uint256 shares = _deposit(alice, 100e18);
        (uint256 sid,) = _open(K);
        _clear(sid, 100e18, 0);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.ZeroAmount.selector);
        vault.requestRedeem(0, alice);
        vm.prank(alice);
        uint256 rid = vault.requestRedeem(shares / 2, bob);
        assertEq(vault.balanceOf(alice), shares / 2);
        assertEq(vault.balanceOf(address(vault)), shares / 2);
        assertEq(vault.escrowedRedeemShares(), shares / 2);
        assertEq(vault.pendingRedeemAssets(), 50e18);
        // escrowed shares cannot be moved by alice
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, shares / 2, shares)
        );
        vault.transfer(bob, shares);
        CoveredCallVault.RedeemRequest memory r = vault.queuedRedeem(rid);
        assertEq(r.requester, alice);
        assertEq(r.receiver, bob);
        assertEq(r.shares, shares / 2);
    }

    function test_cancelRedeem() public {
        uint256 shares = _deposit(alice, 100e18);
        (uint256 sid,) = _open(K);
        _clear(sid, 100e18, 0);
        vm.prank(alice);
        uint256 rid = vault.requestRedeem(shares, alice);
        vm.prank(bob);
        vm.expectRevert(CoveredCallVault.NotRequester.selector);
        vault.cancelRedeem(rid);
        vm.prank(alice);
        vault.cancelRedeem(rid);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.escrowedRedeemShares(), 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CoveredCallVault.BadRequestStatus.selector, CoveredCallVault.RequestStatus.CANCELLED)
        );
        vault.cancelRedeem(rid);
    }

    function test_processRedeems_afterSettlementThenClaim() public {
        uint256 shares = _deposit(alice, 100e18);
        (uint256 sid,) = _open(K);
        _clear(sid, 100e18, 0);
        vm.prank(alice);
        vault.requestRedeem(shares, bob);
        vm.expectRevert(CoveredCallVault.VaultNotIdle.selector);
        vault.processRedeems(1);
        // ITM settlement: S = 231 → ppo = 21/231 ≈ 0.0909; payout = 9.09 tokens
        _settle(sid, 231e8, 1);
        uint256 payout = 100e18 * _ppo(231e8, K) / WAD;
        assertEq(vault.payoutOwed(), payout);
        assertEq(vault.balanceOf(address(vault)), 0, "escrow burned in settle");
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.withdrawalClaimable(bob), 100e18 - payout);
        assertEq(vault.withdrawalClaimableTotal(), 100e18 - payout);
        assertEq(vault.totalAssets(), 0);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NothingToClaim.selector);
        vault.claimWithdrawal(alice);
        uint256 before = stock.balanceOf(carol);
        vm.prank(bob);
        uint256 got = vault.claimWithdrawal(carol);
        assertEq(got, 100e18 - payout);
        assertEq(stock.balanceOf(carol) - before, got);
        assertEq(vault.withdrawalClaimableTotal(), 0);
    }

    function test_processRedeems_respectsLimitAndOpenExcludesPending() public {
        vm.prank(admin);
        vault.setMaxQueueOps(1, 1);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        (uint256 sid,) = _open(K);
        _clear(sid, 200e18, 0);
        vm.prank(alice);
        vault.requestRedeem(100e24, alice);
        vm.prank(bob);
        vault.requestRedeem(100e24, bob);
        _settle(sid, K, 1); // ATM → zero payout; processes only 1 redeem
        assertEq(vault.redeemQueueHead(), 1);
        assertEq(vault.escrowedRedeemShares(), 100e24);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.pendingRedeemAssets(), 100e18);
        // all remaining assets belong to bob's pending redeem: nothing to offer (D-009)
        vm.prank(auction);
        vm.expectRevert(CoveredCallVault.NothingToOffer.selector);
        vault.openSeries(SeriesKind.WEEKDAY, K, _expiry());
        // a fresh deposit is offerable; bob's pending redeem stays excluded
        _deposit(carol, 50e18);
        (uint256 sid2, uint256 offered) = _open(K);
        assertEq(offered, 50e18);
        assertEq(vault.series(sid2).offeredQty, 50e18);
        assertEq(vault.freeAssets(), 50e18);
        _clear(sid2, 50e18, 0);
        _settle(sid2, K, 1); // processes bob's redeem now
        assertEq(vault.redeemQueueHead(), 2);
        assertEq(vault.withdrawalClaimable(bob), 100e18);
    }

    // ═════════════════════════════ openSeries ═════════════════════════════

    function test_openSeries_happyPath() public {
        _deposit(alice, 100e18);
        uint64 exp = _expiry();
        vm.prank(admin);
        stock.stageMultiplier(2e18, exp + 1); // change after expiry is fine (D-026)
        vm.prank(auction);
        (uint256 id, uint256 offered) = vault.openSeries(SeriesKind.WEEKEND, K, exp);
        assertEq(id, 1);
        assertEq(offered, 100e18);
        assertEq(uint8(vault.state()), uint8(VaultState.AUCTION));
        assertEq(vault.currentSeriesId(), 1);
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(uint8(s.kind), uint8(SeriesKind.WEEKEND));
        assertEq(uint8(s.state), uint8(SeriesState.AUCTION));
        assertEq(s.strike, K);
        assertEq(s.expiry, exp);
        assertEq(s.offeredQty, 100e18);
        assertEq(s.multiplierAtOpen, 1e18);
        assertEq(opt.series(id).vault, address(vault));
        assertEq(opt.series(id).strike, K);
    }

    function test_openSeries_onlyAuctionHouse() public {
        _deposit(alice, 100e18);
        vm.expectRevert(CoveredCallVault.NotAuctionHouse.selector);
        vm.prank(alice);
        vault.openSeries(SeriesKind.WEEKDAY, K, _expiry());
    }

    function test_openSeries_reasons() public {
        _deposit(alice, 100e18);
        (bool ok, bytes32 reason) = vault.canOpenAuction(_expiry());
        assertTrue(ok);
        assertEq(reason, bytes32(0));

        (, reason) = vault.canOpenAuction(uint64(block.timestamp));
        assertEq(reason, "EXPIRY_PAST");
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.CannotOpen.selector, bytes32("EXPIRY_PAST")));
        vault.openSeries(SeriesKind.WEEKDAY, K, uint64(block.timestamp));

        risk.setAuctionsPaused(address(vault), true);
        (, reason) = vault.canOpenAuction(_expiry());
        assertEq(reason, "AUCTIONS_PAUSED");
        risk.setAuctionsPaused(address(vault), false);

        vm.prank(admin);
        stock.setOraclePaused(true);
        (, reason) = vault.canOpenAuction(_expiry());
        assertEq(reason, "ORACLE_PAUSED");
        vm.prank(admin);
        stock.setOraclePaused(false);

        vm.prank(admin);
        stock.stageMultiplier(2e18, _expiry()); // effectiveAt == expiry → inside series
        (, reason) = vault.canOpenAuction(_expiry());
        assertEq(reason, "MULTIPLIER_CHANGE");
        vm.prank(admin);
        stock.applyMultiplier();

        vm.prank(admin);
        vault.setSunset();
        (, reason) = vault.canOpenAuction(_expiry());
        assertEq(reason, "SUNSET");
    }

    function test_openSeries_notIdle() public {
        _deposit(alice, 100e18);
        _open(K);
        (, bytes32 reason) = vault.canOpenAuction(_expiry());
        assertEq(reason, "NOT_IDLE");
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.CannotOpen.selector, bytes32("NOT_IDLE")));
        vault.openSeries(SeriesKind.WEEKDAY, K, _expiry());
    }

    function test_openSeries_zeroStrikeAndNothingToOffer() public {
        vm.prank(auction);
        vm.expectRevert(CoveredCallVault.NothingToOffer.selector);
        vault.openSeries(SeriesKind.WEEKDAY, K, _expiry());
        _deposit(alice, 1e18);
        vm.prank(auction);
        vm.expectRevert(CoveredCallVault.ZeroStrike.selector);
        vault.openSeries(SeriesKind.WEEKDAY, 0, _expiry());
    }

    // ═════════════════════════════ skipSeries ═════════════════════════════

    function test_skipSeries() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotAuctionHouse.selector);
        vault.skipSeries(id);
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeries.selector, id + 1));
        vault.skipSeries(id + 1);
        vm.prank(auction);
        vault.skipSeries(id);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.SKIPPED));
        assertEq(vault.encumbered(), 0);
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.SKIPPED));
        vault.skipSeries(id);
        // vault reusable
        _deposit(bob, 1e18);
        (uint256 id2,) = _open(K);
        assertEq(id2, id + 1);
    }

    // ═════════════════════════════ mintSeries ═════════════════════════════

    function test_mintSeries_happyPath() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 offered) = _open(K);
        uint256 usdgBefore = usdg.balanceOf(auction);
        vm.expectEmit(true, false, false, true);
        emit CoveredCallVault.SeriesCleared(id, offered, 1_000e6);
        _clear(id, offered, 1_000e6);
        assertEq(uint8(vault.state()), uint8(VaultState.LIVE));
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.LIVE));
        assertEq(vault.series(id).filledQty, offered);
        assertEq(vault.encumbered(), offered);
        assertEq(vault.freeAssets(), 0);
        assertEq(usdgBefore - usdg.balanceOf(auction), 1_000e6);
        assertEq(usdg.balanceOf(address(vault)), 1_000e6);
        assertEq(vault.premiumClaimable(alice), 1_000e6);
        assertEq(vault.totalAssets(), 100e18, "premium is outside NAV");
    }

    function test_mintSeries_partialFillLeavesFree() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        _clear(id, 40e18, 0);
        assertEq(vault.encumbered(), 40e18);
        assertEq(vault.freeAssets(), 60e18);
    }

    function test_mintSeries_reverts() public {
        _deposit(alice, 100e18);
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeries.selector, 1));
        vault.mintSeries(1, 1, 0);
        (uint256 id, uint256 offered) = _open(K);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotAuctionHouse.selector);
        vault.mintSeries(id, 1, 0);
        vm.startPrank(auction);
        vm.expectRevert(CoveredCallVault.ZeroAmount.selector);
        vault.mintSeries(id, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.ExceedsOffered.selector, offered + 1, offered));
        vault.mintSeries(id, offered + 1, 0);
        vm.stopPrank();
        // a redeem request during the AUCTION window does NOT shrink coverage (D-040): the full offer clears
        vm.prank(alice);
        vault.requestRedeem(10e24, alice);
        assertEq(vault.freeAssets(), 90e18);
        // an issuer burn between open and clear does (I-1 re-check at clear)
        vm.prank(admin);
        stock.burn(address(vault), 30e18);
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.InsufficientCoverage.selector, offered, 70e18));
        vault.mintSeries(id, offered, 0);
        _clear(id, 70e18, 0);
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.LIVE));
        vault.mintSeries(id, 1, 0);
    }

    // ═════════════════════════════ premium ═════════════════════════════

    function test_premium_splitByShares() public {
        _deposit(alice, 100e18);
        _deposit(bob, 300e18);
        (uint256 id, uint256 filled) = _openAndClear(K, 4_000e6);
        assertEq(vault.premiumClaimable(alice), 1_000e6);
        assertEq(vault.premiumClaimable(bob), 3_000e6);
        // transfer after clearing: carol receives shares, not premium
        vm.prank(alice);
        vault.transfer(carol, 50e24);
        assertEq(vault.premiumClaimable(alice), 1_000e6);
        assertEq(vault.premiumClaimable(carol), 0);
        _settle(id, K, 1);
        // late depositor earns nothing from the past series
        _deposit(mm, 400e18);
        assertEq(vault.premiumClaimable(mm), 0);
        // second series: all four share
        (id, filled) = _openAndClear(K, 8_000e6);
        assertEq(vault.premiumClaimable(mm), 4_000e6);
        assertEq(vault.premiumClaimable(alice), 1_000e6 + 500e6);
        assertEq(vault.premiumClaimable(carol), 500e6);
        assertEq(vault.premiumClaimable(bob), 3_000e6 + 3_000e6);
        assertEq(filled, 800e18);
    }

    function test_claimPremium_transfersAndWorksWhilePausedOrHalted() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 1_000e6);
        risk.setDepositsPaused(address(vault), true);
        vm.prank(settlement);
        vault.haltSeries(id, "JUMP_GUARD");
        vm.prank(alice);
        uint256 got = vault.claimPremium(bob);
        assertEq(got, 1_000e6);
        assertEq(usdg.balanceOf(bob), 1_000e6);
        assertEq(vault.premiumClaimable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NothingToClaim.selector);
        vault.claimPremium(alice);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.ZeroAddress.selector);
        vault.claimPremium(address(0));
    }

    function test_premium_escrowedRedeemSharesExcluded() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        (uint256 id,) = _open(K);
        vm.prank(bob);
        vault.requestRedeem(100e24, bob); // during AUCTION: forfeits this series' premium (D-036)
        _clear(id, 100e18, 1_000e6);
        assertEq(vault.premiumClaimable(alice), 1_000e6);
        assertEq(vault.premiumClaimable(bob), 0);
        assertEq(vault.premiumClaimable(address(vault)), 0);
    }

    function test_mintSeries_revertsNoSharesForPremium() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        vm.prank(alice);
        vault.requestRedeem(100e24, alice);
        // all shares escrowed: a donation leaves 1 wei of rounding dust free while nobody is eligible for premium
        vm.prank(admin);
        stock.mint(address(vault), 10e18);
        uint256 free = vault.freeAssets();
        assertEq(free, 1);
        vm.prank(auction);
        vm.expectRevert(CoveredCallVault.NoSharesForPremium.selector);
        vault.mintSeries(id, free, 1e6);
        _clear(id, free, 0); // zero premium is fine
    }

    // ═════════════════════════════ mintOptions ═════════════════════════════

    function test_processRedeems_afterSkipWithAuctionTimeRequest() public {
        uint256 shares = _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        vm.prank(alice);
        vault.requestRedeem(shares, bob);
        vm.prank(auction);
        vault.skipSeries(id);
        vault.processRedeems(5); // IDLE after a skip: executes at the unchanged price
        assertEq(vault.withdrawalClaimable(bob), 100e18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_openSeries_processesOnlyMaxQueueOpsPerOpen() public {
        vm.prank(admin);
        vault.setMaxQueueOps(1, 50);
        _deposit(alice, 100e18);
        vm.prank(bob);
        vault.requestDeposit(10e18, bob);
        vm.prank(carol);
        vault.requestDeposit(20e18, carol);
        (, uint256 offered) = _open(K);
        assertEq(offered, 110e18, "only the first queued deposit executed at open");
        assertEq(vault.depositQueueHead(), 1);
        assertEq(vault.queuedDepositTokens(), 20e18);
    }

    function test_mintOptions() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.AUCTION));
        vault.mintOptions(id, mm, 1);
        _clear(id, 100e18, 0);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotAuctionHouse.selector);
        vault.mintOptions(id, mm, 1);
        vm.startPrank(auction);
        vm.expectRevert(CoveredCallVault.ZeroAmount.selector);
        vault.mintOptions(id, mm, 0);
        vault.mintOptions(id, mm, 60e18);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.ExceedsFilled.selector, 41e18, 40e18));
        vault.mintOptions(id, mm, 41e18);
        vm.stopPrank();
        assertEq(opt.balanceOf(mm, id), 60e18);
        assertEq(vault.series(id).mintedQty, 60e18);
        _settle(id, K, 1);
        _mintOptions(id, bob, 40e18); // still allowed after settlement (pull-based allocation)
        assertEq(vault.series(id).mintedQty, 100e18);
    }

    // ═════════════════════════════ settleSeries ═════════════════════════════

    function test_settle_otm() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(K, 1_000e6);
        uint256 priceBefore = _sharePrice();
        _settle(id, K - 1e8, 1);
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(uint8(s.state), uint8(SeriesState.SETTLED));
        assertEq(s.settlementPrice, K - 1e8);
        assertEq(s.settlementPath, 1);
        assertEq(s.payoutPerOption, 0);
        assertEq(vault.payoutOwed(), 0);
        assertEq(vault.encumbered(), 0);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        assertEq(_sharePrice(), priceBefore, "zero payout leaves the share price unchanged");
        assertEq(vault.totalAssets(), 100e18);
        assertTrue(opt.series(id).settled);
        assertEq(filled, 100e18);
    }

    function test_settle_atm_isZeroPayout() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        _settle(id, K, 1);
        assertEq(vault.series(id).payoutPerOption, 0);
    }

    function test_settle_itm() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(K, 0);
        uint256 priceBefore = _sharePrice();
        uint128 s = 252e8; // 20 % above strike → ppo = 42/252 = 1/6
        _settle(id, s, 3);
        uint256 ppo = _ppo(s, K);
        assertEq(vault.series(id).payoutPerOption, ppo);
        assertLt(ppo, WAD);
        assertEq(vault.payoutOwed(), filled * ppo / WAD);
        assertEq(vault.totalAssets(), 100e18 - filled * ppo / WAD);
        assertLt(_sharePrice(), priceBefore);
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.SETTLED));
        assertEq(opt.series(id).payoutPerOption, ppo);
    }

    function test_settle_resolvedPaths() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        vm.prank(settlement);
        vault.haltSeries(id, "NO_ORACLE_PATH");
        _settle(id, K, 4);
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.RESOLVED));
        _deposit(bob, 1e18);
        (id,) = _openAndClear(K, 0);
        vm.prank(settlement);
        vault.haltSeries(id, "JUMP_GUARD");
        _settle(id, K, 5);
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.RESOLVED));
        assertEq(vault.series(id).settlementPath, 5);
    }

    function test_settle_reverts() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotSettlement.selector);
        vault.settleSeries(id, K, 1);
        vm.startPrank(settlement);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeries.selector, id + 1));
        vault.settleSeries(id + 1, K, 1);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.AUCTION));
        vault.settleSeries(id, K, 1);
        vm.stopPrank();
        _clear(id, 100e18, 0);
        vm.startPrank(settlement);
        vm.expectRevert(CoveredCallVault.ZeroPrice.selector);
        vault.settleSeries(id, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.InvalidPath.selector, 0));
        vault.settleSeries(id, K, 0);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.InvalidPath.selector, 6));
        vault.settleSeries(id, K, 6);
        vault.settleSeries(id, K, 1);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.SETTLED));
        vault.settleSeries(id, K, 1);
        vm.stopPrank();
    }

    function test_settle_emitsNoStockTransfer() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        vm.prank(alice);
        vault.requestRedeem(10e24, alice);
        vm.prank(bob);
        vault.requestDeposit(5e18, bob);
        vm.recordLogs();
        _settle(id, 252e8, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stock)) {
                assertTrue(logs[i].topics[0] != transferSig, "settle must not move stock tokens (I-6)");
            }
        }
        // queues were processed inside settle
        assertEq(vault.redeemQueueHead(), 1);
        assertEq(vault.depositQueueHead(), 1);
        assertGt(vault.withdrawalClaimable(alice), 0);
        assertGt(vault.balanceOf(bob), 0);
    }

    function test_settle_fromHalted() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        vm.prank(settlement);
        vault.haltSeries(id, "NO_ORACLE_PATH");
        assertEq(uint8(vault.state()), uint8(VaultState.HALTED));
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.HALTED));
        _settle(id, K, 4);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        assertEq(vault.encumbered(), 0);
    }

    function test_halt_reverts() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _open(K);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotSettlement.selector);
        vault.haltSeries(id, "x");
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.AUCTION));
        vault.haltSeries(id, "x");
        _clear(id, 100e18, 0);
        vm.startPrank(settlement);
        vault.haltSeries(id, "x");
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.HALTED));
        vault.haltSeries(id, "x");
        vm.stopPrank();
        // halted: requestDeposit still allowed, direct deposit not
        vm.prank(bob);
        vault.requestDeposit(1e18, bob);
        vm.expectRevert(CoveredCallVault.VaultNotIdle.selector);
        _deposit(bob, 1e18);
    }

    function test_settle_shortfallScalesPayout() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(200e8, 0);
        _mintOptions(id, mm, filled);
        vm.prank(admin);
        stock.burn(address(vault), 90e18); // issuer action (SPEC §2)
        assertEq(vault.totalAssets(), 10e18);
        // S = 400 → ppo = 0.5 → payoutTotal 50 > available 10
        vm.expectEmit(true, false, false, true);
        emit CoveredCallVault.ShortfallRecorded(id, 40e18);
        _settle(id, 400e8, 1);
        uint256 ppo = vault.series(id).payoutPerOption;
        assertEq(ppo, 0.5e18 * 10e18 / 50e18);
        assertEq(vault.payoutOwed(), 10e18);
        assertEq(vault.totalShortfall(), 40e18);
        assertLe(vault.payoutOwed(), stock.balanceOf(address(vault)));
        vm.prank(mm);
        uint256 got = opt.claim(id, filled, mm);
        assertEq(got, 10e18);
        assertEq(vault.payoutOwed(), 0);
    }

    function test_totalAssets_saturates() public {
        _deposit(alice, 100e18);
        vm.prank(bob);
        vault.requestDeposit(50e18, bob);
        vm.prank(admin);
        stock.burn(address(vault), 120e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.freeAssets(), 0);
    }

    // ═════════════════════════════ payOptionClaim ═════════════════════════════

    function test_payOptionClaim_onlyOptionTokenAndState() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotOptionToken.selector);
        vault.payOptionClaim(id, alice, 1);
        vm.prank(address(opt));
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.WrongSeriesState.selector, SeriesState.LIVE));
        vault.payOptionClaim(id, alice, 1);
        _settle(id, K, 1);
        vm.startPrank(address(opt));
        vm.expectRevert(CoveredCallVault.ZeroAmount.selector);
        vault.payOptionClaim(id, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.ExceedsFilled.selector, 101e18, 100e18));
        vault.payOptionClaim(id, alice, 101e18);
        vm.stopPrank();
    }

    // ═════════════════════════════ admin ═════════════════════════════

    function test_sunset() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setSunset();
        vm.expectEmit(false, false, false, true);
        emit CoveredCallVault.VaultSunset();
        vm.prank(admin);
        vault.setSunset();
        assertTrue(vault.sunset());
        vm.prank(admin);
        vm.expectRevert(CoveredCallVault.VaultSunsetted.selector);
        vault.setSunset();
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.CannotOpen.selector, bytes32("SUNSET")));
        vault.openSeries(SeriesKind.WEEKDAY, K, _expiry());
        assertEq(vault.maxWithdraw(alice), 100e18);
    }

    function test_setMaxQueueOps() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setMaxQueueOps(1, 1);
        vm.startPrank(admin);
        vm.expectRevert(CoveredCallVault.OutOfBounds.selector);
        vault.setMaxQueueOps(0, 1);
        uint256 maxOps = vault.MAX_QUEUE_OPS(); // read outside expectRevert: a view call would be "the next call"
        vm.expectRevert(CoveredCallVault.OutOfBounds.selector);
        vault.setMaxQueueOps(1, maxOps + 1);
        vault.setMaxQueueOps(3, maxOps);
        vm.stopPrank();
        assertEq(maxOps, 100);
        assertEq(vault.maxQueueOpsPerOpen(), 3);
        assertEq(vault.maxQueueOpsPerSettle(), 100);
    }

    function test_views_queueLengths() public {
        vm.prank(bob);
        vault.requestDeposit(1e18, bob);
        vm.prank(bob);
        vault.requestDeposit(1e18, bob);
        (uint256 d, uint256 r) = vault.queueLengths();
        assertEq(d, 2);
        assertEq(r, 0);
        assertEq(vault.depositQueueLength(), 2);
        assertEq(vault.redeemQueueLength(), 0);
        vault.processDeposits(50);
        (d,) = vault.queueLengths();
        assertEq(d, 0);
    }
}
