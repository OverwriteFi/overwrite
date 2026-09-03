// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FeeRouterTest is Test {
    MockUSDG internal usdg;
    FeeRouter internal fr;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal ah = makeAddr("auctionHouse");
    address internal vault = makeAddr("vault");
    address internal other = makeAddr("other");

    function setUp() public {
        usdg = new MockUSDG();
        fr = new FeeRouter(address(usdg), admin, treasury);
        vm.prank(admin);
        fr.setAuctionHouse(ah);
        vm.prank(ah);
        fr.initVault(vault);
        vm.prank(ah);
        usdg.approve(address(fr), type(uint256).max); // the AuctionHouse constructor grants this (D-049)
    }

    /// @dev Models `AuctionHouse.clear`: the fee stays in the AuctionHouse, only the booking happens here.
    function _collect(uint256 seriesId, uint256 amount) internal {
        usdg.mint(ah, amount);
        vm.prank(ah);
        fr.collect(vault, seriesId, amount);
    }

    function test_constructor_andWiring() public {
        assertEq(fr.DEFAULT_FEE_BPS(), 1000);
        assertEq(fr.MAX_FEE_BPS(), 2000);
        assertEq(fr.treasury(), treasury);
        assertEq(fr.writePool(), address(0));
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(address(0), admin, treasury);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(address(usdg), admin, address(0));
        vm.prank(admin);
        vm.expectRevert(FeeRouter.AlreadySet.selector);
        fr.setAuctionHouse(other);
        FeeRouter fresh = new FeeRouter(address(usdg), admin, treasury);
        vm.prank(ah);
        vm.expectRevert(FeeRouter.NotAuctionHouse.selector);
        fresh.initVault(vault);
    }

    function test_initVault_setsDefaultOnce() public {
        assertTrue(fr.initialised(vault));
        assertEq(fr.feeBps(vault), 1000);
        vm.prank(admin);
        fr.setFeeBps(vault, 500);
        vm.prank(ah);
        fr.initVault(vault); // no-op
        assertEq(fr.feeBps(vault), 500, "second init does not reset");
        vm.prank(other);
        vm.expectRevert(FeeRouter.NotAuctionHouse.selector);
        fr.initVault(other);
        assertEq(fr.feeBps(other), 0, "uninitialised vault reads 0");
    }

    function test_collect_onlyAuctionHouseAndBooks() public {
        vm.prank(other);
        vm.expectRevert(FeeRouter.NotAuctionHouse.selector);
        fr.collect(vault, 1, 1);
        usdg.mint(ah, 10e6);
        vm.expectEmit(true, true, false, true);
        emit FeeRouter.FeeCollected(vault, 1, 10e6, IFeeRouter.FeeMode.USDG);
        vm.prank(ah);
        fr.collect(vault, 1, 10e6);
        _collect(2, 5e6);
        assertEq(fr.pending(vault), 15e6);
        assertEq(usdg.balanceOf(treasury), 0, "nothing forwarded yet");
        assertEq(usdg.balanceOf(address(fr)), 0, "the router never holds USDG");
        assertEq(usdg.balanceOf(ah), 15e6);
    }

    /// D-049: `flush` pulls from the AuctionHouse; a frozen router address is irrelevant, a revoked approval or
    /// a short AuctionHouse balance makes only `flush` revert and leaves `pending` intact.
    function test_flush_pullsFromAuctionHouse() public {
        _collect(1, 5e6);
        usdg.setFrozen(address(fr), true);
        fr.flush(vault);
        assertEq(usdg.balanceOf(treasury), 5e6);
        _collect(2, 5e6);
        vm.prank(ah);
        usdg.approve(address(fr), 0);
        vm.expectRevert();
        fr.flush(vault);
        assertEq(fr.pending(vault), 5e6, "booking survives a failed flush");
    }

    function test_flush_forwardsAndReverts() public {
        vm.expectRevert(FeeRouter.NothingToFlush.selector);
        fr.flush(vault);
        _collect(1, 15e6);
        vm.expectEmit(true, true, false, true);
        emit FeeRouter.FeeFlushed(vault, treasury, 15e6);
        vm.prank(other); // permissionless
        uint256 amount = fr.flush(vault);
        assertEq(amount, 15e6);
        assertEq(usdg.balanceOf(treasury), 15e6);
        assertEq(fr.pending(vault), 0);
    }

    /// @dev T-12: a frozen treasury breaks only `flush`; `collect` keeps working.
    function test_T12_frozenTreasuryBlocksOnlyFlush() public {
        _collect(1, 1e6);
        usdg.setFrozen(treasury, true);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.AccountFrozen.selector, treasury));
        fr.flush(vault);
        _collect(2, 1e6);
        assertEq(fr.pending(vault), 2e6);
        usdg.setFrozen(treasury, false);
        fr.flush(vault);
        assertEq(usdg.balanceOf(treasury), 2e6);
    }

    function test_setFeeBps_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeRouter.OutOfBounds.selector);
        fr.setFeeBps(vault, 2001);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.NotInitialised.selector, other));
        fr.setFeeBps(other, 100);
        vm.expectEmit(true, false, false, true);
        emit FeeRouter.ParameterChanged(vault, "feeBps", 1000, 0);
        fr.setFeeBps(vault, 0);
        assertEq(fr.feeBps(vault), 0);
        fr.setFeeBps(vault, 2000);
        vm.stopPrank();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        fr.setFeeBps(vault, 1);
    }

    function test_setTreasury() public {
        vm.prank(admin);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        fr.setTreasury(address(0));
        vm.prank(admin);
        fr.setTreasury(other);
        assertEq(fr.treasury(), other);
        _collect(1, 3e6);
        fr.flush(vault);
        assertEq(usdg.balanceOf(other), 3e6);
    }

    function test_writeMode_unreachableUntilLaunch() public {
        assertEq(uint256(fr.mode(vault)), uint256(IFeeRouter.FeeMode.USDG));
        assertEq(fr.writeBalance(vault), 0);
        vm.prank(admin);
        vm.expectRevert(FeeRouter.WriteNotLaunched.selector);
        fr.setFeeMode(vault, IFeeRouter.FeeMode.WRITE);
        vm.prank(admin);
        fr.setFeeMode(vault, IFeeRouter.FeeMode.USDG);
        vm.expectRevert(FeeRouter.WriteNotLaunched.selector);
        fr.depositWrite(vault, 1);
        vm.expectRevert(FeeRouter.WriteNotLaunched.selector);
        fr.withdrawWrite(vault, 1);
    }

    /// @dev Σ collected == Σ flushed + pending for any interleaving.
    function testFuzz_collectFlushConserves(uint256[8] memory amounts, uint8 flushMask) public {
        uint256 collected;
        uint256 flushed;
        for (uint256 i; i < 8; ++i) {
            uint256 a = bound(amounts[i], 0, 1e12);
            if (a > 0) {
                _collect(i, a);
                collected += a;
            }
            if ((flushMask >> i) & 1 == 1 && fr.pending(vault) > 0) {
                flushed += fr.flush(vault);
            }
        }
        assertEq(collected, flushed + fr.pending(vault));
        assertEq(usdg.balanceOf(treasury), flushed);
        assertEq(usdg.balanceOf(ah), fr.pending(vault), "pending fees sit in the AuctionHouse");
        assertEq(usdg.balanceOf(address(fr)), 0);
    }
}
