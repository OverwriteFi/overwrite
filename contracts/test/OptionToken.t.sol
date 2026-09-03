// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {SeriesKind} from "../src/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract OptionTokenTest is BaseTest {
    address internal underlying2 = makeAddr("underlying2");
    address internal fakeVault = makeAddr("fakeVault");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        opt.registerVault(underlying2, fakeVault);
    }

    function _createFake() internal returns (uint256 id) {
        vm.prank(fakeVault);
        id = opt.create(underlying2, SeriesKind.WEEKEND, 210e8, uint64(block.timestamp + 1 days), 1e18);
    }

    // ───────────────────────────── registerVault ─────────────────────────────

    function test_registerVault_storesMapping() public view {
        assertEq(opt.vaultOf(address(stock)), address(vault));
        assertTrue(opt.isVault(address(vault)));
        assertEq(opt.vaultOf(underlying2), fakeVault);
    }

    function test_registerVault_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        opt.registerVault(makeAddr("x"), makeAddr("y"));
    }

    function test_registerVault_revertsOnDuplicateUnderlying() public {
        vm.expectRevert(abi.encodeWithSelector(OptionToken.VaultAlreadyRegistered.selector, address(stock)));
        vm.prank(admin);
        opt.registerVault(address(stock), makeAddr("other"));
    }

    function test_registerVault_revertsOnZero() public {
        vm.startPrank(admin);
        vm.expectRevert(OptionToken.ZeroAddress.selector);
        opt.registerVault(address(0), fakeVault);
        vm.expectRevert(OptionToken.ZeroAddress.selector);
        opt.registerVault(makeAddr("u"), address(0));
        vm.stopPrank();
    }

    // ───────────────────────────── create ─────────────────────────────

    function test_create_storesFieldsAndIncrementsId() public {
        uint256 id1 = _createFake();
        uint256 id2 = _createFake();
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(opt.nextSeriesId(), 3);
        IOptionToken.SeriesInfo memory s = opt.series(id1);
        assertEq(s.vault, fakeVault);
        assertEq(s.underlying, underlying2);
        assertEq(uint8(s.kind), uint8(SeriesKind.WEEKEND));
        assertEq(s.strike, 210e8);
        assertEq(s.expiry, uint64(block.timestamp + 1 days));
        assertEq(s.multiplierAtCreation, 1e18);
        assertFalse(s.settled);
        assertEq(s.payoutPerOption, 0);
    }

    function test_create_revertsForNonVault() public {
        vm.expectRevert(OptionToken.NotVault.selector);
        vm.prank(alice);
        opt.create(underlying2, SeriesKind.WEEKDAY, 1e8, 1, 1e18);
        // the real vault cannot create for another underlying either
        vm.expectRevert(OptionToken.NotVault.selector);
        vm.prank(address(vault));
        opt.create(underlying2, SeriesKind.WEEKDAY, 1e8, 1, 1e18);
    }

    // ───────────────────────────── mint / burn / markSettled ─────────────────────────────

    function test_mint_onlySeriesVault() public {
        uint256 id = _createFake();
        vm.prank(fakeVault);
        opt.mint(id, mm, 5e18);
        assertEq(opt.balanceOf(mm, id), 5e18);
        assertEq(opt.totalSupply(id), 5e18);

        vm.expectRevert(OptionToken.NotVault.selector);
        vm.prank(address(vault));
        opt.mint(id, mm, 1);
        vm.expectRevert(OptionToken.NotVault.selector);
        vm.prank(mm);
        opt.mint(id, mm, 1);
    }

    function test_mint_revertsUnknownSeriesAndZero() public {
        vm.expectRevert(abi.encodeWithSelector(OptionToken.UnknownSeries.selector, 99));
        vm.prank(fakeVault);
        opt.mint(99, mm, 1);
        uint256 id = _createFake();
        vm.expectRevert(OptionToken.ZeroQty.selector);
        vm.prank(fakeVault);
        opt.mint(id, mm, 0);
    }

    function test_burn_onlySeriesVault() public {
        uint256 id = _createFake();
        vm.startPrank(fakeVault);
        opt.mint(id, mm, 5e18);
        opt.burn(id, mm, 2e18);
        vm.stopPrank();
        assertEq(opt.balanceOf(mm, id), 3e18);
        vm.expectRevert(OptionToken.NotVault.selector);
        vm.prank(mm);
        opt.burn(id, mm, 1);
        vm.expectRevert(OptionToken.ZeroQty.selector);
        vm.prank(fakeVault);
        opt.burn(id, mm, 0);
    }

    function test_markSettled_onceOnlyByVault() public {
        uint256 id = _createFake();
        vm.expectRevert(OptionToken.NotVault.selector);
        vm.prank(alice);
        opt.markSettled(id, 220e8, 1e17);
        vm.prank(fakeVault);
        opt.markSettled(id, 220e8, 1e17);
        IOptionToken.SeriesInfo memory s = opt.series(id);
        assertTrue(s.settled);
        assertEq(s.settlementPrice, 220e8);
        assertEq(s.payoutPerOption, 1e17);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.AlreadySettled.selector, id));
        vm.prank(fakeVault);
        opt.markSettled(id, 1, 1);
    }

    // ───────────────────────────── claim ─────────────────────────────

    function test_claim_revertsBeforeSettlement() public {
        uint256 id = _createFake();
        vm.prank(fakeVault);
        opt.mint(id, mm, 1e18);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.NotSettled.selector, id));
        vm.prank(mm);
        opt.claim(id, 1e18, mm);
    }

    function test_claim_revertsUnknownZeroQtyZeroTo() public {
        vm.expectRevert(abi.encodeWithSelector(OptionToken.UnknownSeries.selector, 7));
        opt.claim(7, 1, mm);
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(210e8, 1_000e6);
        _mintOptions(id, mm, filled);
        _settle(id, 231e8, 1);
        vm.startPrank(mm);
        vm.expectRevert(OptionToken.ZeroQty.selector);
        opt.claim(id, 0, mm);
        vm.expectRevert(OptionToken.ZeroAddress.selector);
        opt.claim(id, 1, address(0));
        vm.stopPrank();
    }

    function test_claim_burnsAndPaysFromVault() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(200e8, 1_000e6);
        _mintOptions(id, mm, filled);
        uint128 s = 250e8;
        _settle(id, s, 1);
        uint256 ppo = _ppo(s, 200e8); // 0.2e18
        uint256 expectTokens = filled * ppo / WAD;
        assertEq(vault.payoutOwed(), expectTokens);

        uint256 before = stock.balanceOf(mm);
        vm.prank(mm);
        uint256 got = opt.claim(id, filled, mm);
        assertEq(got, expectTokens);
        assertEq(stock.balanceOf(mm) - before, expectTokens);
        assertEq(opt.totalSupply(id), 0);
        assertEq(vault.payoutOwed(), 0);
        assertEq(vault.series(id).claimedQty, filled);
    }

    function test_claim_partialAndByTransferee() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(200e8, 0);
        _mintOptions(id, mm, filled);
        _settle(id, 250e8, 2);
        vm.prank(mm);
        opt.safeTransferFrom(mm, bob, id, filled / 2, "");
        vm.prank(bob);
        uint256 gotBob = opt.claim(id, filled / 2, carol);
        vm.prank(mm);
        uint256 gotMm = opt.claim(id, filled - filled / 2, mm);
        assertEq(stock.balanceOf(carol) - 1_000_000e18, gotBob);
        assertEq(gotBob + gotMm, filled * _ppo(250e8, 200e8) / WAD);
        assertEq(vault.payoutOwed(), 0);
    }

    function test_claim_nonHolderReverts() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(200e8, 0);
        _mintOptions(id, mm, filled);
        _settle(id, 250e8, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 0, 1, id));
        opt.claim(id, 1, bob);
    }

    function test_claim_otmBurnsAndPaysZero() public {
        _deposit(alice, 100e18);
        (uint256 id, uint256 filled) = _openAndClear(200e8, 0);
        _mintOptions(id, mm, filled);
        _settle(id, 190e8, 1);
        vm.prank(mm);
        uint256 got = opt.claim(id, filled, mm);
        assertEq(got, 0);
        assertEq(opt.balanceOf(mm, id), 0);
    }
}
