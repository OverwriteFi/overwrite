// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Price source that always reverts: models a dead Chainlink aggregator / `observe` OLD revert.
contract RevertingPriceSource is IPriceSource {
    function capPrice(address) external pure returns (uint256, bool) {
        revert("dead oracle");
    }
}

/// @dev ERC-1155 receiver that tries to re-enter the vault from the mint callback (THREAT-MODEL T-16).
contract ReentrantReceiver is IERC1155Receiver {
    CoveredCallVault public vault;
    bool public reentered;
    bytes public lastError;

    constructor(CoveredCallVault v) {
        vault = v;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        try vault.processRedeems(1) {
            reentered = true;
        } catch (bytes memory err) {
            lastError = err;
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId;
    }
}

/// @notice Threat-model regression tests, named `test_Txx_…` per THREAT-MODEL §6.
contract CoveredCallVaultThreatsTest is BaseTest {
    uint128 internal constant K = 210e8;

    // ───────────────────────────── T-18: queue griefing must never block settlement ─────────────────────────────

    function test_T18_cancelledEntriesDoNotBlockSettle() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        // attacker floods both queues with request+cancel pairs during LIVE
        uint256 n = 1_000;
        vm.startPrank(mm);
        for (uint256 i; i < n; ++i) {
            uint256 d = vault.requestDeposit(1, mm);
            vault.cancelDeposit(d);
        }
        vm.stopPrank();
        vm.prank(alice);
        uint256 someShares = vault.requestRedeem(1e6, alice);
        vm.startPrank(alice);
        vault.cancelRedeem(someShares);
        for (uint256 i; i < n; ++i) {
            uint256 r = vault.requestRedeem(1e6, alice);
            vault.cancelRedeem(r);
        }
        vm.stopPrank();
        // a real request behind the garbage
        vm.prank(bob);
        vault.requestDeposit(5e18, bob);

        uint256 gasBefore = gasleft();
        _settle(id, K, 1);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 3_000_000, "settle is bounded by maxQueueOpsPerSettle regardless of garbage");
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        // permissionless processing drains the garbage and reaches bob
        for (uint256 i; i < 25; ++i) {
            vault.processDeposits(100);
        }
        assertEq(uint8(vault.queuedDeposit(n).status), uint8(CoveredCallVault.RequestStatus.EXECUTED));
        assertEq(vault.balanceOf(bob), 5e24);
        vault.processRedeems(100);
        vault.processRedeems(100);
    }

    // ───────────────────────────── T-11: issuer actions ─────────────────────────────

    function test_T11_settleSucceedsWhileTokenPaused() public {
        _deposit(alice, 100e18);
        uint256 shares = vault.balanceOf(alice);
        (uint256 id, uint256 filled) = _openAndClear(K, 1_000e6);
        _mintOptions(id, mm, filled);
        vm.prank(alice);
        vault.requestRedeem(shares / 2, alice);
        vm.prank(admin);
        stock.setPaused(true);
        // settlement is pure bookkeeping: works while the stock token is paused
        _settle(id, 231e8, 1);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        assertGt(vault.withdrawalClaimable(alice), 0);
        // transfers are blocked by the issuer, premium (USDG) is not
        vm.prank(alice);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        vault.claimWithdrawal(alice);
        vm.prank(mm);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        opt.claim(id, filled, mm);
        vm.prank(alice);
        assertEq(vault.claimPremium(alice), 1_000e6);
        // after unpause everything is claimable
        vm.prank(admin);
        stock.setPaused(false);
        vm.prank(alice);
        vault.claimWithdrawal(alice);
        vm.prank(mm);
        opt.claim(id, filled, mm);
        assertEq(vault.payoutOwed(), 0);
    }

    function test_T11_mintSeriesRevertsAfterIssuerBurnBetweenOpenAndClear() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 offered) = _open(K);
        vm.prank(admin);
        stock.burn(address(vault), 1);
        vm.prank(auction);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.InsufficientCoverage.selector, offered, offered - 1));
        vault.mintSeries(id, offered, 0);
    }

    /// @dev The full T-11 loss path and its repair: an issuer burn haircuts the option holders at settlement,
    /// then the safety module's proceeds are injected and the survivors are paid at 100 % (SPEC §9.7 step 5, §14).
    function test_T11_injectCoverageRestoresFullPayout() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(200e8, 0);
        _mintOptions(id, mm, filled);
        vm.prank(admin);
        stock.burn(address(vault), 90e18); // issuer destroys 90 % of the collateral
        _settle(id, 400e8, 1);
        assertEq(vault.totalShortfall(), 40e18, "the shortfall is recorded, not swallowed");
        assertEq(vault.series(id).payoutPerOption, 0.1e18, "holders are haircut to 20 % of the true payout");

        uint256 need = vault.coverageNeeded(id);
        vm.startPrank(admin);
        stock.mint(admin, need); // proceeds of SafetyModule.slash, converted off-chain (SPEC §14)
        stock.approve(address(vault), need);
        vault.injectCoverage(id, need);
        vm.stopPrank();

        assertEq(vault.series(id).payoutPerOption, 0.5e18, "claims re-enabled at 100 %");
        assertLe(vault.payoutOwed(), stock.balanceOf(address(vault)), "I-2: payoutOwed backed again");
        vm.prank(mm);
        assertEq(opt.claim(id, filled, mm), 50e18, "the holder is made whole");
        assertEq(vault.totalShortfall(), 40e18, "the historical record of the loss is not erased");
    }

    // ───────────────────────────── T-12: settlement must not depend on an external oracle ─────────────────────────────

    function test_T12_settleSurvivesRevertingPriceSource() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        vm.prank(bob);
        vault.requestDeposit(5e18, bob);
        address dead = address(new RevertingPriceSource()); // deploy before the prank (a `new` would consume it)
        vm.prank(admin);
        cap.setPriceSource(dead);
        assertEq(vault.maxDeposit(bob), 0, "ERC-4626 max views never revert");
        assertEq(vault.maxMint(bob), 0);
        _settle(id, K, 1); // must not revert
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        assertEq(uint8(vault.queuedDeposit(0).status), uint8(CoveredCallVault.RequestStatus.QUEUED), "waits");
        // the vault can also re-open with a dead cap oracle: queued deposits simply wait
        (, uint256 offered) = _open(K);
        assertEq(offered, 100e18);
        uint256 openId = vault.currentSeriesId();
        vm.prank(auction);
        vault.skipSeries(openId);
        // direct deposits report the typed reason while the cap oracle is dead
        vm.prank(bob);
        vm.expectRevert(CoveredCallVault.CapPriceUnavailable.selector);
        vault.deposit(1e18, bob);
    }

    // ───────────────────────────── T-10: corporate actions ─────────────────────────────

    function test_T10_pastEffectiveAtDoesNotBlockOpen() public {
        _deposit(alice, 100e18);
        // AAPL on 2026-09-02: effectiveAt() == 1786720366 (past), multiplier already applied
        vm.prank(admin);
        stock.stageMultiplier(1000566080061092436, block.timestamp - 30 days);
        (bool ok, bytes32 reason) = vault.canOpenAuction(_expiry());
        assertTrue(ok, string(abi.encodePacked(reason)));
        vm.prank(admin);
        stock.stageMultiplier(2e18, block.timestamp); // effective now: already in force
        (ok,) = vault.canOpenAuction(_expiry());
        assertTrue(ok);
        vm.prank(admin);
        stock.stageMultiplier(2e18, block.timestamp + 1); // inside (now, expiry]
        (ok, reason) = vault.canOpenAuction(_expiry());
        assertFalse(ok);
        assertEq(reason, "MULTIPLIER_CHANGE");
        vm.prank(admin);
        stock.stageMultiplier(2e18, uint256(_expiry()) + 1); // after expiry
        (ok,) = vault.canOpenAuction(_expiry());
        assertTrue(ok);
    }

    // ───────────────────────────── T-14: state machine ─────────────────────────────

    function test_T14_settlePathMustMatchState() public {
        _deposit(alice, 100e18);
        (uint256 id,) = _openAndClear(K, 0);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.InvalidPath.selector, 4));
        vault.settleSeries(id, K, 4);
        vm.prank(settlement);
        vault.haltSeries(id, "NO_ORACLE_PATH");
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallVault.InvalidPath.selector, 3));
        vault.settleSeries(id, K, 3);
        _settle(id, K, 5);
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.RESOLVED));
    }

    // ───────────────────────────── T-09: share accounting ─────────────────────────────

    function test_T09_sharesCannotBeSentToVault() public {
        uint256 shares = _deposit(alice, 100e18);
        vm.startPrank(alice);
        vm.expectRevert(CoveredCallVault.CannotTransferToVault.selector);
        vault.transfer(address(vault), shares);
        vm.expectRevert(CoveredCallVault.CannotTransferToVault.selector);
        vault.deposit(1e18, address(vault));
        vm.expectRevert(CoveredCallVault.CannotTransferToVault.selector);
        vault.mint(1e24, address(vault));
        vm.expectRevert(CoveredCallVault.CannotTransferToVault.selector);
        vault.requestDeposit(1e18, address(vault));
        vm.stopPrank();
        (uint256 id,) = _open(K);
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.CannotTransferToVault.selector);
        vault.requestRedeem(1e24, address(vault));
        // the legitimate escrow path still works and is the only way shares reach the vault
        vm.prank(alice);
        vault.requestRedeem(1e24, alice);
        assertEq(vault.balanceOf(address(vault)), 1e24);
        assertEq(vault.escrowedRedeemShares(), 1e24);
        vm.prank(auction);
        vault.skipSeries(id);
    }

    function test_T09_selfAndZeroTransfersKeepPremiumIntact() public {
        _deposit(alice, 100e18);
        _openAndClear(K, 1_000e6);
        vm.startPrank(alice);
        vault.transfer(alice, 10e24);
        vault.transfer(bob, 0);
        vm.stopPrank();
        assertEq(vault.premiumClaimable(alice), 1_000e6);
        assertEq(vault.premiumClaimable(bob), 0);
    }

    // ───────────────────────────── T-16: ERC-1155 receiver reentrancy ─────────────────────────────

    function test_T16_reentrantReceiverCannotReenterVault() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(K, 0);
        ReentrantReceiver r = new ReentrantReceiver(vault);
        _mintOptions(id, address(r), filled);
        assertEq(opt.balanceOf(address(r), id), filled, "mint succeeded");
        assertFalse(r.reentered(), "reentrancy blocked");
        assertEq(bytes4(r.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    // ───────────────────────────── T-15: guardian and sunset scope ─────────────────────────────

    function test_T15_claimsAndQueueProcessingWorkWhilePausedAndSunset() public {
        _deposit(alice, 100e18);
        uint256 shares = vault.balanceOf(alice);
        (uint256 id, uint256 filled) = _openAndClear(K, 1_000e6);
        _mintOptions(id, mm, filled);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        vm.prank(admin);
        vault.setMaxQueueOps(1, 1);
        risk.setDepositsPaused(address(vault), true);
        risk.setAuctionsPaused(address(vault), true);
        vm.prank(admin);
        vault.setSunset();
        // settle still runs and executes the redeem; option holder and depositor can exit
        _settle(id, 231e8, 1);
        vault.processRedeems(10);
        vm.prank(alice);
        uint256 got = vault.claimWithdrawal(alice);
        assertGt(got, 0);
        vm.prank(alice);
        assertEq(vault.claimPremium(alice), 1_000e6);
        vm.prank(mm);
        assertGt(opt.claim(id, filled, mm), 0);
        assertEq(vault.payoutOwed(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    // ───────────────────────────── T-07.8: gas bounds ─────────────────────────────

    function test_T07_settleGasAtMaxQueueOps() public {
        uint256 maxOps = vault.MAX_QUEUE_OPS();
        vm.prank(admin);
        vault.setMaxQueueOps(maxOps, maxOps);
        _deposit(alice, 1_000e18);
        (uint256 id,) = _openAndClear(K, 1e6);
        for (uint256 i; i < maxOps; ++i) {
            address u = address(uint160(0xA000 + i));
            vm.prank(admin);
            stock.mint(u, 1e18);
            vm.startPrank(u);
            stock.approve(address(vault), type(uint256).max);
            vault.requestDeposit(1e18, u);
            vm.stopPrank();
            vm.prank(alice);
            vault.requestRedeem(1e24, address(uint160(0xB000 + i)));
        }
        uint256 gasBefore = gasleft();
        _settle(id, K, 1);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("settle gas at MAX_QUEUE_OPS x2", used);
        assertLt(used, 20_000_000, "must fit comfortably inside a 32M block");
        assertEq(vault.depositQueueHead(), maxOps);
        assertEq(vault.redeemQueueHead(), maxOps);
    }
}
