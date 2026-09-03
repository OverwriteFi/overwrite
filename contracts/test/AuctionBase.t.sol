// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {CapController} from "../src/CapController.sol";
import {AuctionHouse} from "../src/AuctionHouse.sol";
import {BondManager} from "../src/BondManager.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {MockRiskModule} from "./mocks/MockRiskModule.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {MockSafetyModule} from "./mocks/MockSafetyModule.sol";
import {IAuctionHouse} from "../src/interfaces/IAuctionHouse.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";

/// @dev Fixture with the real AuctionHouse, BondManager and FeeRouter wired to one NVDA-like vault. The vault's
/// `auctionHouse` is immutable, so the AuctionHouse is deployed first. Time starts at Monday 14:00 UTC.
abstract contract AuctionBaseTest is Test {
    MockStockToken internal stock;
    MockUSDG internal usdg;
    MockRiskModule internal risk;
    MockPriceSource internal priceSource;
    MockSafetyModule internal safetyModule;
    CapController internal cap;
    OptionToken internal opt;
    CoveredCallVault internal vault;
    BondManager internal bm;
    FeeRouter internal fr;
    AuctionHouse internal ah;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal settlement = makeAddr("settlement");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mm1 = makeAddr("mm1");
    address internal mm2 = makeAddr("mm2");
    address internal mm3 = makeAddr("mm3");
    address internal mm4 = makeAddr("mm4");

    uint256 internal constant PRICE = 200e8; // $200 per token, 8 dec
    uint256 internal constant BIG_CAP = 1e18;
    uint256 internal constant START_TS = 1_788_344_808; // SPEC §0 reference timestamp (Wed 2026-09-02)
    uint256 internal constant MONDAY_1400 = 1_788_789_600; // first Monday 14:00 UTC after START_TS
    uint256 internal constant WAD = 1e18;
    uint256 internal constant WEEK = 604_800;
    uint256 internal constant BOND = 25_000e6;
    uint256 internal constant MM_USDG = 10_000_000e6;
    uint16 internal constant DIST = 800;
    uint128 internal constant RESERVE = 1e6; // 1 USDG per option
    uint128 internal constant K_DEFAULT = 216e8; // 200 × 1.08 lands on the 0.5 grid exactly

    function setUp() public virtual {
        vm.warp(START_TS);
        stock = new MockStockToken("Mock NVDA", "NVDA", admin);
        usdg = new MockUSDG();
        risk = new MockRiskModule();
        priceSource = new MockPriceSource();
        safetyModule = new MockSafetyModule();
        cap = new CapController(admin, address(priceSource));
        opt = new OptionToken("", admin);
        bm = new BondManager(address(usdg), admin, treasury);
        fr = new FeeRouter(address(usdg), admin, treasury);
        ah = new AuctionHouse(address(usdg), address(bm), address(fr), address(priceSource), admin);
        vault = new CoveredCallVault(
            CoveredCallVault.Config({
                stock: address(stock),
                usdg: address(usdg),
                optionToken: address(opt),
                auctionHouse: address(ah),
                settlement: settlement,
                riskModule: address(risk),
                capController: address(cap),
                owner: admin,
                name: "Overwrite NVDA",
                symbol: "owNVDA"
            })
        );
        vm.startPrank(admin);
        bm.setAuctionHouse(address(ah));
        fr.setAuctionHouse(address(ah));
        opt.registerVault(address(stock), address(vault));
        cap.setCapUSD(address(vault), BIG_CAP);
        ah.registerVault(address(vault));
        ah.setKeeper(keeper, true);
        vm.stopPrank();
        priceSource.set(address(vault), PRICE, true);

        address[2] memory depositors = [alice, bob];
        for (uint256 i; i < depositors.length; ++i) {
            vm.prank(admin);
            stock.mint(depositors[i], 1_000_000e18);
            vm.prank(depositors[i]);
            stock.approve(address(vault), type(uint256).max);
        }
        _fundMM(mm1);
        _fundMM(mm2);
        _fundMM(mm3);
        _fundMM(mm4);

        vm.label(address(vault), "vault");
        vm.label(address(opt), "optionToken");
        vm.label(address(ah), "auctionHouse");
        vm.label(address(bm), "bondManager");
        vm.label(address(fr), "feeRouter");
        vm.label(address(stock), "stock");
        vm.label(address(usdg), "usdg");
        vm.warp(MONDAY_1400);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _fundMM(address mm) internal {
        usdg.mint(mm, MM_USDG);
        vm.startPrank(mm);
        usdg.approve(address(bm), type(uint256).max);
        usdg.approve(address(ah), type(uint256).max);
        bm.postBond(IBondManager.BondKind.MM);
        vm.stopPrank();
    }

    function _newMM(string memory name) internal returns (address mm) {
        mm = makeAddr(name);
        _fundMM(mm);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit(assets, user);
    }

    function _fridayExpiry() internal view returns (uint64) {
        return ah.scheduledExpiry(SeriesKind.WEEKDAY, uint64(block.timestamp));
    }

    function _sundayExpiry() internal view returns (uint64) {
        return ah.scheduledExpiry(SeriesKind.WEEKEND, uint64(block.timestamp));
    }

    function _open(uint16 dist, uint128 reserve) internal returns (uint256 id) {
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        id = ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, dist, reserve);
    }

    function _openDefault() internal returns (uint256 id) {
        return _open(DIST, RESERVE);
    }

    function _openWeekend(uint16 dist, uint128 reserve) internal returns (uint256 id) {
        uint64 exp = _sundayExpiry();
        vm.prank(keeper);
        id = ah.openAuction(address(vault), SeriesKind.WEEKEND, exp, dist, reserve);
    }

    function _bid(address mm, uint256 id, uint256 qty, uint256 price) internal returns (uint256 bidId) {
        vm.prank(mm);
        bidId = ah.bid(id, qty, price);
    }

    function _close(uint256 id) internal {
        uint64 c = ah.auctions(id).auctionClose;
        if (block.timestamp < c) vm.warp(c);
    }

    function _clear(uint256 id) internal returns (uint256 cp, uint256 filled, uint256 gross, uint256 fee) {
        _close(id);
        return ah.clear(id);
    }

    /// @dev Warps to expiry if needed and settles on path 1 (the SettlementOracle is a plain address here).
    function _settle(uint256 id, uint128 price) internal {
        uint64 e = vault.series(id).expiry;
        if (block.timestamp < e) vm.warp(e);
        vm.prank(settlement);
        vault.settleSeries(id, price, 1);
    }

    function _escrow(uint256 qty, uint256 price) internal pure returns (uint256) {
        return qty * price / WAD;
    }

    /// @dev Next Monday 14:00 UTC strictly after `t`.
    function _nextMonday1400(uint256 t) internal view returns (uint256 m) {
        m = t - (t % WEEK) + ah.MON_1400();
        if (m <= t) m += WEEK;
    }
}
