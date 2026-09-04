// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoveredCallVault} from "../../src/CoveredCallVault.sol";
import {OptionToken} from "../../src/OptionToken.sol";
import {CapController} from "../../src/CapController.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockRiskModule} from "../mocks/MockRiskModule.sol";
import {MockPriceSource} from "../mocks/MockPriceSource.sol";
import {ICoveredCallVault} from "../../src/interfaces/ICoveredCallVault.sol";
import {SeriesKind, SeriesState, VaultState} from "../../src/Types.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @dev Actor contract that tries to re-enter the vault from the ERC-1155 mint callback (T-16).
contract ReenteringActor is IERC1155Receiver {
    CoveredCallVault internal vault;
    uint256 public reentrySuccesses;

    constructor(CoveredCallVault v) {
        vault = v;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        try vault.processRedeems(1) {
            reentrySuccesses++;
        } catch {}
        try vault.claimPremium(address(this)) {
            reentrySuccesses++;
        } catch {}
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

/// @dev Stateful fuzzing handler. Every action is guarded so it never reverts (fail_on_revert = true).
/// Ghost variables record the facts the invariants check. Covers THREAT-MODEL §6 external actors:
/// issuer (burn, pause), guardian (pauses), timelock (sunset, queue bounds, caps), a reentrant receiver.
contract VaultHandler is Test {
    CoveredCallVault public vault;
    OptionToken public opt;
    CapController public cap;
    MockStockToken public stock;
    MockUSDG public usdg;
    MockRiskModule public risk;
    MockPriceSource public priceSource;
    address public admin;
    address public auction;
    address public settlement;
    ReenteringActor public reenterer;

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
    uint256 public issuerBurned;
    uint256 public shortfalls;
    uint256 public injections;
    uint256 public injected;
    uint256 public fullRestores;
    uint256 public expiredRequests;
    uint256 public calls;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant PRICE = 200e8;

    constructor(
        CoveredCallVault vault_,
        OptionToken opt_,
        CapController cap_,
        MockStockToken stock_,
        MockUSDG usdg_,
        MockRiskModule risk_,
        MockPriceSource priceSource_,
        address admin_,
        address auction_,
        address settlement_,
        address[] memory actors_
    ) {
        vault = vault_;
        opt = opt_;
        cap = cap_;
        stock = stock_;
        usdg = usdg_;
        risk = risk_;
        priceSource = priceSource_;
        admin = admin_;
        auction = auction_;
        settlement = settlement_;
        actors = actors_;
        reenterer = new ReenteringActor(vault_);
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
    /// Issuer burns are excluded: they are the one external event allowed to lower NAV.
    modifier trackPrice() {
        uint256 before = sharePrice();
        _;
        if (sharePrice() < before) nonSettlePriceDrops++;
        calls++;
    }

    /// @dev Mirrors `injectCoverage`'s maths in plain arithmetic so the handler can skip a draw the contract
    /// would reject. `rem` and the payouts are well under 2^128, so nothing here overflows.
    function _previewInject(uint256 id, uint256 tokens, uint256 need) internal view returns (uint256) {
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        uint256 rem = s.filledQty - s.claimedQty;
        uint256 owedNow = rem * s.payoutPerOption / WAD;
        uint256 full = uint256(s.settlementPrice - s.strike) * WAD / s.settlementPrice;
        uint256 budget = tokens < need ? tokens : need;
        uint256 ppoNew = budget == need ? full : s.payoutPerOption + budget * WAD / rem;
        return rem * ppoNew / WAD - owedNow;
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(admin);
        stock.mint(who, amount);
    }

    function _tokenPaused() internal view returns (bool) {
        return stock.paused();
    }

    // ───────────────────────────── ERC-4626 ─────────────────────────────

    function deposit(uint256 seed, uint256 amount) external trackPrice {
        if (_tokenPaused()) return;
        address a = _actor(seed);
        uint256 max = vault.maxDeposit(a);
        if (max == 0) return;
        amount = bound(amount, 1, max < 1_000e18 ? max : 1_000e18);
        _fund(a, amount);
        vm.prank(a);
        vault.deposit(amount, a);
    }

    function mintShares(uint256 seed, uint256 shares) external trackPrice {
        if (_tokenPaused()) return;
        address a = _actor(seed);
        uint256 max = vault.maxMint(a);
        if (max == 0) return;
        shares = bound(shares, 1, max < 1_000e24 ? max : 1_000e24);
        uint256 assets = vault.previewMint(shares);
        if (assets == 0) return;
        _fund(a, assets);
        vm.prank(a);
        vault.mint(shares, a);
    }

    function withdraw(uint256 seed, uint256 amount) external trackPrice {
        if (_tokenPaused()) return;
        address a = _actor(seed);
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        vault.withdraw(amount, a, a);
    }

    function redeem(uint256 seed, uint256 shares) external trackPrice {
        if (_tokenPaused()) return;
        address a = _actor(seed);
        uint256 max = vault.maxRedeem(a);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(a);
        vault.redeem(shares, a, a);
    }

    /// @dev Share transfers between actors (incl. self and zero-value) exercise the premium hook (T-09.5).
    function transferShares(uint256 seed, uint256 toSeed, uint256 shares) external trackPrice {
        address from = _actor(seed);
        address to = _actor(toSeed);
        uint256 bal = vault.balanceOf(from);
        shares = bal == 0 ? 0 : bound(shares, 0, bal);
        vm.prank(from);
        vault.transfer(to, shares);
    }

    // ───────────────────────────── queues ─────────────────────────────

    function requestDeposit(uint256 seed, uint256 amount) external trackPrice {
        if (_tokenPaused()) return;
        address a = _actor(seed);
        if (vault.sunset() || risk.depositsPaused(address(vault))) return;
        amount = bound(amount, 1, 1_000e18);
        _fund(a, amount);
        vm.prank(a);
        uint256 id = vault.requestDeposit(amount, a);
        depositRequestIds.push(id);
    }

    function cancelDeposit(uint256 seed) external trackPrice {
        if (_tokenPaused()) return;
        if (depositRequestIds.length == 0) return;
        uint256 id = depositRequestIds[seed % depositRequestIds.length];
        CoveredCallVault.DepositRequest memory r = vault.queuedDeposit(id);
        if (r.status != CoveredCallVault.RequestStatus.QUEUED && r.status != CoveredCallVault.RequestStatus.EXPIRED) {
            return;
        }
        if (r.status == CoveredCallVault.RequestStatus.EXPIRED) expiredRequests++;
        vm.prank(r.requester);
        vault.cancelDeposit(id);
    }

    /// @dev T-18: flood the queues with request+cancel pairs.
    function massCancel(uint256 seed, uint256 count) external trackPrice {
        if (_tokenPaused()) return;
        address a = _actor(seed);
        count = bound(count, 1, 20);
        bool canDeposit = !vault.sunset() && !risk.depositsPaused(address(vault));
        bool canRedeem = vault.state() != VaultState.IDLE && vault.balanceOf(a) >= 1e6;
        if (canDeposit) _fund(a, count);
        vm.startPrank(a);
        for (uint256 i; i < count; ++i) {
            if (canDeposit) {
                uint256 d = vault.requestDeposit(1, a);
                vault.cancelDeposit(d);
            }
            if (canRedeem) {
                uint256 r = vault.requestRedeem(1e6, a);
                vault.cancelRedeem(r);
            }
        }
        vm.stopPrank();
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
        if (_tokenPaused()) return;
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
        uint256 available = vault.totalAssets();
        uint256 maxQty = offered < available ? offered : available;
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
        address to = seed % 5 == 0 ? address(reenterer) : _actor(seed);
        vm.prank(auction);
        vault.mintOptions(id, to, qty);
    }

    function settle(uint256 priceSeed, uint256 pathSeed) external {
        VaultState st = vault.state();
        if (st != VaultState.LIVE && st != VaultState.HALTED) return;
        uint256 id = vault.currentSeriesId();
        uint256 strike = vault.series(id).strike;
        // half to double the strike; ~1/3 of draws land at or below the strike
        uint128 price = uint128(bound(priceSeed, strike / 2 + 1, strike * 2));
        uint8 path = st == VaultState.HALTED ? uint8(bound(pathSeed, 4, 5)) : uint8(bound(pathSeed, 1, 3));
        uint256 before = sharePrice();
        uint256 shortBefore = vault.totalShortfall();
        vm.prank(settlement);
        vault.settleSeries(id, price, path);
        settles++;
        if (vault.totalShortfall() > shortBefore) shortfalls++;
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
        if (_tokenPaused()) return;
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

    // ───────────────────────────── external actors: issuer, guardian, timelock ─────────────────────────────

    function donate(uint256 amount) external trackPrice {
        if (_tokenPaused()) return;
        amount = bound(amount, 1, 10e18);
        _fund(address(vault), amount);
        donated += amount;
    }

    /// @dev Issuer burns part of the vault's NAV (SPEC §2, §9.7 step 5). Bounded to `totalAssets()` so tokens
    /// already owed (payouts, executed redeems, queued deposits) stay backed; burning those would be a plain
    /// issuer default that no accounting can absorb. The only action allowed to lower the share price outside
    /// settlement, so it is not wrapped in trackPrice.
    function issuerBurn(uint256 amount) external {
        if (_tokenPaused()) return;
        uint256 bal = vault.totalAssets();
        if (bal == 0) return;
        amount = bound(amount, 1, bal / 10 + 1);
        if (amount > bal) amount = bal;
        vm.prank(admin);
        stock.burn(address(vault), amount);
        issuerBurned += amount;
        calls++;
    }

    function issuerPauseToggle() external trackPrice {
        bool next = !stock.paused(); // read before prank: a view call would consume it
        vm.prank(admin);
        stock.setPaused(next);
    }

    function togglePause(uint256 seed) external trackPrice {
        if (seed % 2 == 0) {
            risk.setDepositsPaused(address(vault), !risk.depositsPaused(address(vault)));
        } else {
            risk.setAuctionsPaused(address(vault), !risk.auctionsPaused(address(vault)));
        }
    }

    function sunsetVault() external trackPrice {
        if (vault.sunset()) return;
        vm.prank(admin);
        vault.setSunset();
    }

    /// @dev The timelock covers a recorded shortfall with stock tokens bought using slashed WRITE (SPEC §14).
    /// The amount runs up to twice what is needed, so partial injections, exact restores and the overshoot
    /// clamp are all reachable. Wrapped in `trackPrice`, which asserts the injection never moves the share
    /// price: coverage belongs to option holders, never to depositors.
    function injectCoverage(uint256 seed, uint256 tokenSeed) external trackPrice {
        if (_tokenPaused()) return;
        if (seriesIds.length == 0) return;
        uint256 id = seriesIds[seed % seriesIds.length];
        uint256 need = vault.coverageNeeded(id);
        if (need == 0) return;
        uint256 amount = bound(tokenSeed, 1, need * 2);
        // an amount too small to move the rate by one wei reverts, and `fail_on_revert` is on
        if (_previewInject(id, amount, need) == 0) return;

        _fund(admin, amount);
        vm.prank(admin);
        stock.approve(address(vault), amount);
        uint256 before = stock.balanceOf(admin);
        vm.prank(admin);
        vault.injectCoverage(id, amount);

        injections++;
        injected += before - stock.balanceOf(admin);
        if (vault.coverageNeeded(id) == 0) fullRestores++;
    }

    function setMaxQueueOps(uint256 a, uint256 b) external trackPrice {
        uint256 maxOps = vault.MAX_QUEUE_OPS();
        vm.prank(admin);
        vault.setMaxQueueOps(bound(a, 1, maxOps), bound(b, 1, maxOps));
    }

    /// @dev Cap between 0 and ~5x the current NAV so EXPIRED / cap-full / no-price paths are all reachable.
    function setCap(uint256 capSeed, uint256 priceOkSeed) external trackPrice {
        uint256 navUsd6 = vault.totalAssets() * PRICE / 1e20;
        uint256 newCap = bound(capSeed, 0, navUsd6 * 5 + 100_000e6);
        vm.prank(admin);
        cap.setCapUSD(address(vault), newCap);
        priceSource.set(address(vault), PRICE, priceOkSeed % 4 != 0);
    }

    function warp(uint256 delta) external trackPrice {
        vm.warp(block.timestamp + bound(delta, 1, 1 days));
    }
}
