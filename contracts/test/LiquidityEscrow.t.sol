// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "./TokenUnitBase.t.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {MockLaunchpad} from "./mocks/MockLaunchpad.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LiquidityEscrowTest is TokenUnitBaseTest {
    MockLaunchpad internal launchpad;

    function setUp() public override {
        super.setUp();
        launchpad = new MockLaunchpad(address(write));
    }

    // ═════════════════════════════ wiring ═════════════════════════════

    function test_allocationAndFunding() public view {
        assertEq(escrow.allocation(), 250_000_000e18);
        assertEq(escrow.writeToken(), address(write));
        assertEq(write.balanceOf(address(escrow)), 250_000_000e18);
        assertEq(escrow.released(), 0);
    }

    function test_setWriteToken_onceOnly() public {
        vm.prank(admin);
        vm.expectRevert(LiquidityEscrow.AlreadySet.selector);
        escrow.setWriteToken(address(write));
    }

    function test_setWriteToken_revertsWhenUnderfunded() public {
        LiquidityEscrow fresh = new LiquidityEscrow(admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.Underfunded.selector, 0, 250_000_000e18));
        fresh.setWriteToken(address(write));
    }

    // ═════════════════════════════ pool guard (D-094) ═════════════════════════════

    function test_setPool_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        escrow.setPool(address(launchpad));
    }

    function test_setPool_revertsOnEOA() public {
        address eoa = makeAddr("eoa");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.NotAContract.selector, eoa));
        escrow.setPool(eoa);
    }

    /// @dev A bare `transfer` of 250 M WRITE into a v3 pool is a donation the next swap takes — 25 % of supply
    /// gone in one block. `onlyOwner` does not help, because the timelock is the one making the typo.
    function test_setPool_revertsOnRawAmmPool() public {
        MockUniswapV3Pool raw =
            new MockUniswapV3Pool(address(usdg), address(write), 500, 0, 1e18, uint32(block.timestamp));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.PoolIsRawAmm.selector, address(raw)));
        escrow.setPool(address(raw));
    }

    /// @dev The guard only fires for a pool actually holding WRITE; an unrelated pair is a plain contract.
    function test_setPool_acceptsAPoolNotHoldingWrite() public {
        MockUniswapV3Pool unrelated =
            new MockUniswapV3Pool(address(usdg), address(usdgFeed), 500, 0, 1e18, uint32(block.timestamp));
        vm.prank(admin);
        escrow.setPool(address(unrelated));
        assertEq(escrow.pool(), address(unrelated));
    }

    function test_setPool_repointableUntilFirstFundThenFrozen() public {
        MockLaunchpad other = new MockLaunchpad(address(write));
        vm.startPrank(admin);
        escrow.setPool(address(launchpad));
        escrow.setPool(address(other));
        assertEq(escrow.pool(), address(other));

        escrow.fund(1e18);
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.PoolFrozen.selector, 1e18));
        escrow.setPool(address(launchpad));
        vm.stopPrank();
    }

    // ═════════════════════════════ funding ═════════════════════════════

    function test_fund_onlyOwnerAndOnlyToPool() public {
        vm.prank(admin);
        escrow.setPool(address(launchpad));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        escrow.fund(1e18);

        vm.prank(admin);
        escrow.fund(1_000e18);
        assertEq(write.balanceOf(address(launchpad)), 1_000e18, "the only legal destination");
        assertEq(escrow.released(), 1_000e18);
    }

    function test_fund_revertsBeforePoolSet() public {
        vm.prank(admin);
        vm.expectRevert(LiquidityEscrow.PoolNotSet.selector);
        escrow.fund(1e18);
    }

    function test_fund_revertsOnZero() public {
        vm.prank(admin);
        escrow.setPool(address(launchpad));
        vm.prank(admin);
        vm.expectRevert(LiquidityEscrow.ZeroAmount.selector);
        escrow.fund(0);
    }

    function test_fundAll_drainsTheAllocation() public {
        vm.startPrank(admin);
        escrow.setPool(address(launchpad));
        escrow.fundAll();
        vm.stopPrank();
        assertEq(write.balanceOf(address(launchpad)), 250_000_000e18);
        assertEq(write.balanceOf(address(escrow)), 0);
        assertEq(escrow.released(), escrow.allocation());
    }

    function test_fund_cannotExceedAllocation() public {
        vm.startPrank(admin);
        escrow.setPool(address(launchpad));
        escrow.fundAll();
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityEscrow.ExceedsAllocation.selector, 250_000_000e18 + 1, 250_000_000e18)
        );
        escrow.fund(1);
        vm.stopPrank();
    }

    // ═════════════════════════════ no escape hatches (SPEC §15) ═════════════════════════════

    function test_noRescuePathExists() public {
        address t = address(escrow);
        string[4] memory sigs =
            ["rescue(address,uint256)", "sweep(address)", "transferTo(address,uint256)", "execute(address,bytes)"];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = t.call(abi.encodeWithSignature(sigs[i], address(write), uint256(1)));
            assertFalse(ok, "no escape hatch may exist");
        }
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(LiquidityEscrow.RenounceDisabled.selector);
        escrow.renounceOwnership();
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    function testFuzz_fund_neverExceedsAllocation(uint256[4] memory amounts) public {
        vm.prank(admin);
        escrow.setPool(address(launchpad));
        uint256 cap = escrow.allocation();
        uint256 sent;
        for (uint256 i; i < 4; ++i) {
            uint256 a = bound(amounts[i], 1, 100_000_000e18);
            if (sent + a > cap) {
                // The case the test is named for: the contract must reject it, not the harness.
                // README:75 -- read `cap` into a local, or the view call consumes the prank.
                bytes memory err = abi.encodeWithSelector(LiquidityEscrow.ExceedsAllocation.selector, sent + a, cap);
                vm.prank(admin);
                vm.expectRevert(err);
                escrow.fund(a);
                continue;
            }
            vm.prank(admin);
            escrow.fund(a);
            sent += a;
        }
        assertEq(escrow.released(), sent);
        assertLe(escrow.released(), escrow.allocation());
        assertEq(write.balanceOf(address(launchpad)), sent);
        assertEq(write.balanceOf(address(escrow)), escrow.allocation() - sent);
    }
}
