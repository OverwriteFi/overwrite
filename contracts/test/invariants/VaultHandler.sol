// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoveredCallVault} from "../../src/CoveredCallVault.sol";
import {OptionToken} from "../../src/OptionToken.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockRiskModule} from "../mocks/MockRiskModule.sol";
import {ICoveredCallVault} from "../../src/interfaces/ICoveredCallVault.sol";
import {SeriesKind, SeriesState, VaultState} from "../../src/Types.sol";

/// @dev Stateful fuzzing handler. Every action is guarded so it never reverts (fail_on_revert = true).
/// Ghost variables record the facts the invariants check.
contract VaultHandler is Test {
    CoveredCallVault public vault;
    OptionToken public opt;
    MockStockToken public stock;
    MockUSDG public usdg;
    MockRiskModule public risk;
    address public admin;
    address public auction;
    address public settlement;

    address[] public actors;
    uint256[] public seriesIds;
    uint256[] public depositRequestIds;
    uint256[] public redeemRequestIds;

    // ghosts
    uint256 public settles;
    uint256 public zeroPayoutSettles;
    uint256 public zeroPayoutPriceDrops;
    uint256 public nonSettlePriceDrops;
    uint256 public premiumAccrued;
    uint256 public premiumClaimed;
    uint256 public donated;
    uint256 public calls;

    uint256 internal constant WAD = 1e18;

    constructor(
        CoveredCallVault vault_,
        OptionToken opt_,
        MockStockToken stock_,
        MockUSDG usdg_,
        MockRiskModule risk_,
        address admin_,
        address auction_,
        address settlement_,
        address[] memory actors_
    ) {
        vault = vault_;
        opt = opt_;
        stock = stock_;
        usdg = usdg_;
        risk = risk_;
        admin = admin_;
        auction = auction_;
        settlement = settlement_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            vm.prank(actors_[i]);
            stock.approve(address(vault), type(uint256).max);
        }
        vm.prank(auction);
        usdg.approve(address(vault), type(uint256).max);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function seriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function sharePrice() public view returns (uint256) {
        return vault.convertToAssets(WAD);
    }

    /// @dev SPEC I-8 (relaxed to non-decreasing because of rounding): outside settlement the price never falls.
    modifier trackPrice() {
        uint256 before = sharePrice();
        _;
        if (sharePrice() < before) nonSettlePriceDrops++;
        calls++;
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(admin);
        stock.mint(who, amount);
    }

    // ───────────────────────────── ERC-4626 ─────────────────────────────

    function deposit(uint256 seed, uint256 amount) external trackPrice {
        address a = _actor(seed);
        uint256 max = vault.maxDeposit(a);
        if (max == 0) return;
        amount = bound(amount, 1, max < 1_000e18 ? max : 1_000e18);
        _fund(a, amount);
        vm.prank(a);
        vault.deposit(amount, a);
    }

    function mintShares(uint256 seed, uint256 shares) external trackPrice {
        address a = _actor(seed);
        uint256 max = vault.maxMint(a);
        if (max == 0) return;
        shares = bound(shares, 1, max < 1_000e24 ? max : 1_000e24);
        uint256 assets = vault.previewMint(shares);
        _fund(a, assets);
        vm.prank(a);
        vault.mint(shares, a);
    }

    function withdraw(uint256 seed, uint256 amount) external trackPrice {
        address a = _actor(seed);
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        vault.withdraw(amount, a, a);
    }

    function redeem(uint256 seed, uint256 shares) external trackPrice {
        address a = _actor(seed);
        uint256 max = vault.maxRedeem(a);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(a);
        vault.redeem(shares, a, a);
    }

    // ───────────────────────────── queues ─────────────────────────────

    function requestDeposit(uint256 seed, uint256 amount) external trackPrice {
        address a = _actor(seed);
        if (vault.sunset() || risk.depositsPaused(address(vault))) return;
        amount = bound(amount, 1, 1_000e18);
        _fund(a, amount);
        vm.prank(a);
        uint256 id = vault.requestDeposit(amount, a);
        depositRequestIds.push(id);
    }

    function cancelDeposit(uint256 seed) external trackPrice {
        if (depositRequestIds.length == 0) return;
        uint256 id = depositRequestIds[seed % depositRequestIds.length];
        CoveredCallVault.DepositRequest memory r = vault.queuedDeposit(id);
        if (r.status != CoveredCallVault.RequestStatus.QUEUED && r.status != CoveredCallVault.RequestStatus.EXPIRED) {
            return;
        }
        vm.prank(r.requester);
        vault.cancelDeposit(id);
    }

    function processDeposits(uint256 n) external trackPrice {
        if (vault.state() != VaultState.IDLE) return;
        vault.processDeposits(bound(n, 1, 10));
    }

    function requestRedeem(uint256 seed, uint256 shares) external trackPrice {
        address a = _actor(seed);
        if (vault.state() == VaultState.IDLE) return;
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        uint256 id = vault.requestRedeem(shares, a);
        redeemRequestIds.push(id);
    }

    function cancelRedeem(uint256 seed) external trackPrice {
        if (redeemRequestIds.length == 0) return;
        uint256 id = redeemRequestIds[seed % redeemRequestIds.length];
        CoveredCallVault.RedeemRequest memory r = vault.queuedRedeem(id);
        if (r.status != CoveredCallVault.RequestStatus.QUEUED) return;
        vm.prank(r.requester);
        vault.cancelRedeem(id);
    }

    function processRedeems(uint256 n) external trackPrice {
        if (vault.state() != VaultState.IDLE) return;
        vault.processRedeems(bound(n, 1, 10));
    }

    function claimWithdrawal(uint256 seed) external trackPrice {
        address a = _actor(seed);
        if (vault.withdrawalClaimable(a) == 0) return;
        vm.prank(a);
        vault.claimWithdrawal(a);
    }

    // ───────────────────────────── series lifecycle ─────────────────────────────

    function openSeries(uint256 strikeSeed, uint256 expiryDelta, uint256 kindSeed) external trackPrice {
        uint64 expiry = uint64(block.timestamp + bound(expiryDelta, 1 hours, 7 days));
        (bool ok,) = vault.canOpenAuction(expiry);
        if (!ok) return;
        uint256 ta = vault.totalAssets();
        uint256 pending = vault.pendingRedeemAssets();
        if (ta <= pending) return;
        uint128 strike = uint128(bound(strikeSeed, 1e8, 1_000e8));
        SeriesKind kind = kindSeed % 2 == 0 ? SeriesKind.WEEKDAY : SeriesKind.WEEKEND;
        vm.prank(auction);
        (uint256 id,) = vault.openSeries(kind, strike, expiry);
        seriesIds.push(id);
    }

    function skipSeries() external trackPrice {
        if (vault.state() != VaultState.AUCTION) return;
        uint256 id = vault.currentSeriesId(); // read before prank: a view call would consume it
        vm.prank(auction);
        vault.skipSeries(id);
    }

    function mintSeries(uint256 qtySeed, uint256 premiumSeed) external trackPrice {
        if (vault.state() != VaultState.AUCTION) return;
        uint256 id = vault.currentSeriesId();
        uint256 offered = vault.series(id).offeredQty;
        uint256 free = vault.freeAssets();
        uint256 maxQty = offered < free ? offered : free;
        if (maxQty == 0 || vault.totalSupply() == vault.balanceOf(address(vault))) {
            vm.prank(auction);
            vault.skipSeries(id);
            return;
        }
        uint256 qty = bound(qtySeed, 1, maxQty);
        uint256 premium = bound(premiumSeed, 0, 1_000_000e6);
        usdg.mint(auction, premium);
        vm.prank(auction);
        vault.mintSeries(id, qty, premium);
        premiumAccrued += premium;
    }

    function mintOptions(uint256 seed, uint256 qtySeed) external trackPrice {
        if (seriesIds.length == 0) return;
        uint256 id = seriesIds[seed % seriesIds.length];
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        if (s.state == SeriesState.AUCTION || s.state == SeriesState.SKIPPED || s.state == SeriesState.NONE) return;
        uint256 remaining = uint256(s.filledQty) - s.mintedQty;
        if (remaining == 0) return;
        uint256 qty = bound(qtySeed, 1, remaining);
        vm.prank(auction);
        vault.mintOptions(id, _actor(seed), qty);
    }

    function settle(uint256 priceSeed, uint256 pathSeed) external {
        VaultState st = vault.state();
        if (st != VaultState.LIVE && st != VaultState.HALTED) return;
        uint256 id = vault.currentSeriesId();
        uint256 strike = vault.series(id).strike;
        // half to double the strike; ~1/3 of draws land at or below the strike
        uint128 price = uint128(bound(priceSeed, strike / 2 + 1, strike * 2));
        uint8 path = uint8(bound(pathSeed, 1, 5));
        uint256 before = sharePrice();
        vm.prank(settlement);
        vault.settleSeries(id, price, path);
        settles++;
        if (vault.series(id).payoutPerOption == 0) {
            zeroPayoutSettles++;
            if (sharePrice() < before) zeroPayoutPriceDrops++;
        }
        calls++;
    }

    function halt() external trackPrice {
        if (vault.state() != VaultState.LIVE) return;
        uint256 id = vault.currentSeriesId();
        vm.prank(settlement);
        vault.haltSeries(id, "NO_ORACLE_PATH");
    }

    function claimOption(uint256 seed, uint256 qtySeed) external trackPrice {
        if (seriesIds.length == 0) return;
        uint256 id = seriesIds[seed % seriesIds.length];
        if (!opt.series(id).settled) return;
        address a = _actor(seed);
        uint256 bal = opt.balanceOf(a, id);
        if (bal == 0) return;
        uint256 qty = bound(qtySeed, 1, bal);
        vm.prank(a);
        opt.claim(id, qty, a);
    }

    function claimPremium(uint256 seed) external trackPrice {
        address a = _actor(seed);
        if (vault.premiumClaimable(a) == 0) return;
        vm.prank(a);
        premiumClaimed += vault.claimPremium(a);
    }

    // ───────────────────────────── environment ─────────────────────────────

    function donate(uint256 amount) external trackPrice {
        amount = bound(amount, 1, 10e18);
        _fund(address(vault), amount);
        donated += amount;
    }

    function togglePause(uint256 seed) external trackPrice {
        if (seed % 2 == 0) {
            risk.setDepositsPaused(address(vault), !risk.depositsPaused(address(vault)));
        } else {
            risk.setAuctionsPaused(address(vault), !risk.auctionsPaused(address(vault)));
        }
    }

    function warp(uint256 delta) external trackPrice {
        vm.warp(block.timestamp + bound(delta, 1, 1 days));
    }
}
