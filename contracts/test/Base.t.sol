// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {CapController} from "../src/CapController.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {MockRiskModule} from "./mocks/MockRiskModule.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {MockSafetyModule} from "./mocks/MockSafetyModule.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";

/// @dev Shared fixture: one NVDA-like vault wired to mocks; AuctionHouse and Settlement are plain addresses.
abstract contract BaseTest is Test {
    MockStockToken internal stock;
    MockUSDG internal usdg;
    MockRiskModule internal risk;
    MockPriceSource internal priceSource;
    MockSafetyModule internal safetyModule;
    CapController internal cap;
    OptionToken internal opt;
    CoveredCallVault internal vault;

    address internal admin = makeAddr("admin");
    address internal auction = makeAddr("auctionHouse");
    address internal settlement = makeAddr("settlement");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal mm = makeAddr("marketMaker");

    uint256 internal constant PRICE = 200e8; // $200 per token, 8 dec
    uint256 internal constant BIG_CAP = 1e18; // 1e12 USD in 6 dec: effectively uncapped
    uint256 internal constant START_TS = 1_788_344_808; // SPEC §0 reference timestamp
    uint256 internal constant WAD = 1e18;

    function setUp() public virtual {
        vm.warp(START_TS);
        stock = new MockStockToken("Mock NVDA", "NVDA", admin);
        usdg = new MockUSDG();
        risk = new MockRiskModule();
        priceSource = new MockPriceSource();
        safetyModule = new MockSafetyModule();
        cap = new CapController(admin, address(priceSource));
        opt = new OptionToken("", admin);
        vault = new CoveredCallVault(
            CoveredCallVault.Config({
                stock: address(stock),
                usdg: address(usdg),
                optionToken: address(opt),
                auctionHouse: auction,
                settlement: settlement,
                riskModule: address(risk),
                capController: address(cap),
                owner: admin,
                name: "Overwrite NVDA",
                symbol: "owNVDA"
            })
        );
        vm.startPrank(admin);
        opt.registerVault(address(stock), address(vault));
        cap.setCapUSD(address(vault), BIG_CAP);
        vm.stopPrank();
        priceSource.set(address(vault), PRICE, true);

        address[4] memory users = [alice, bob, carol, mm];
        for (uint256 i; i < users.length; ++i) {
            vm.prank(admin);
            stock.mint(users[i], 1_000_000e18);
            vm.prank(users[i]);
            stock.approve(address(vault), type(uint256).max);
        }
        usdg.mint(auction, 1e15);
        vm.prank(auction);
        usdg.approve(address(vault), type(uint256).max);

        vm.label(address(vault), "vault");
        vm.label(address(opt), "optionToken");
        vm.label(address(stock), "stock");
        vm.label(address(usdg), "usdg");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit(assets, user);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 5 days);
    }

    function _open(uint128 strike) internal returns (uint256 id, uint256 offered) {
        vm.prank(auction);
        (id, offered) = vault.openSeries(SeriesKind.WEEKDAY, strike, _expiry());
    }

    function _clear(uint256 id, uint256 filled, uint256 premium) internal {
        vm.prank(auction);
        vault.mintSeries(id, filled, premium);
    }

    function _openAndClear(uint128 strike, uint256 premium) internal returns (uint256 id, uint256 filled) {
        (id, filled) = _open(strike);
        _clear(id, filled, premium);
    }

    function _settle(uint256 id, uint128 price, uint8 path) internal {
        vm.prank(settlement);
        vault.settleSeries(id, price, path);
    }

    function _mintOptions(uint256 id, address to, uint256 qty) internal {
        vm.prank(auction);
        vault.mintOptions(id, to, qty);
    }

    function _sharePrice() internal view returns (uint256) {
        return vault.convertToAssets(WAD);
    }

    function _ppo(uint256 s, uint256 k) internal pure returns (uint256) {
        return s > k ? (s - k) * WAD / s : 0;
    }
}
