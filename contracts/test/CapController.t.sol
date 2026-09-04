// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {CapController} from "../src/CapController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CapControllerTest is BaseTest {
    address internal v = makeAddr("someVault");

    function setUp() public override {
        super.setUp();
        priceSource.set(v, PRICE, true);
        vm.prank(admin);
        cap.setCapUSD(v, 25_000e6); // D-011 launch value
    }

    function test_constructor_revertsZeroPriceSource() public {
        vm.expectRevert(CapController.ZeroAddress.selector);
        new CapController(admin, address(0));
    }

    /// @dev Matches the other thirteen owned contracts (D-100). An ownerless CapController would freeze
    /// `capUSD` for every vault forever and make the FIXED -> SAFETY_MODULE switch of CLAUDE.md rule 6
    /// unreachable.
    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(CapController.RenounceDisabled.selector);
        cap.renounceOwnership();
        // a non-owner is still rejected by `onlyOwner` first, so ownership cannot be dropped by anyone
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cap.renounceOwnership();
        assertEq(cap.owner(), admin, "the timelock still owns the cap controller");
    }

    // ───────────────────────────── FIXED ─────────────────────────────

    function test_fixed_remainingMath() public view {
        // 100 tokens × $200 = $20 000 used of $25 000 → $5 000 / $200 = 25 tokens
        (uint256 assets, bool ok) = cap.remainingDepositAssets(v, 100e18);
        assertTrue(ok);
        assertEq(assets, 25e18);
        (assets, ok) = cap.remainingDepositAssets(v, 0);
        assertEq(assets, 125e18);
    }

    function test_fixed_zeroWhenAtOrOverCap() public view {
        (uint256 assets, bool ok) = cap.remainingDepositAssets(v, 125e18);
        assertTrue(ok);
        assertEq(assets, 0);
        (assets, ok) = cap.remainingDepositAssets(v, 1_000e18);
        assertTrue(ok);
        assertEq(assets, 0);
    }

    function test_priceUnavailable() public {
        priceSource.set(v, PRICE, false);
        (uint256 assets, bool ok) = cap.remainingDepositAssets(v, 0);
        assertFalse(ok);
        assertEq(assets, 0);
        priceSource.set(v, 0, true);
        (assets, ok) = cap.remainingDepositAssets(v, 0);
        assertFalse(ok);
    }

    function testFuzz_fixed_neverExceedsCap(uint256 totalAssets, uint256 price8, uint256 capUsd) public {
        totalAssets = bound(totalAssets, 0, 1e30);
        price8 = bound(price8, 1, 1e14);
        capUsd = bound(capUsd, 0, 1e18);
        priceSource.set(v, price8, true);
        vm.prank(admin);
        cap.setCapUSD(v, capUsd);
        (uint256 assets, bool ok) = cap.remainingDepositAssets(v, totalAssets);
        assertTrue(ok);
        if (totalAssets * price8 / 1e20 >= capUsd) {
            assertEq(assets, 0, "already at or over cap: no headroom");
        } else {
            // SPEC §12 deposit check: (totalAssets + assets) × price8 / 1e18 ≤ capUSD × 1e2
            assertLe((totalAssets + assets) * price8 / 1e18, capUsd * 1e2);
        }
    }

    // ───────────────────────────── SAFETY_MODULE ─────────────────────────────

    function test_setCapMode_requiresSafetyModule() public {
        vm.prank(admin);
        vm.expectRevert(CapController.SafetyModuleNotSet.selector);
        cap.setCapMode(CapController.CapMode.SAFETY_MODULE);
    }

    function _enableSafetyModule(uint256 smValue, uint256 weightBps) internal {
        safetyModule.set(smValue);
        vm.startPrank(admin);
        cap.setSafetyModule(address(safetyModule));
        cap.setCapMode(CapController.CapMode.SAFETY_MODULE);
        cap.setCapWeightBps(v, weightBps);
        vm.stopPrank();
    }

    function test_safetyModule_math() public {
        // k = 5, sm value 100 000 → global 500 000; weight 50 % → 250 000; ceiling 25 000 → 25 000
        _enableSafetyModule(100_000e6, 5_000);
        assertEq(cap.vaultCapUSD(v), 25_000e6);
        vm.prank(admin);
        cap.setCapUSD(v, 0); // no ceiling
        assertEq(cap.vaultCapUSD(v), 250_000e6);
        vm.prank(admin);
        cap.setK(2e18);
        assertEq(cap.vaultCapUSD(v), 100_000e6);
        (uint256 assets,) = cap.remainingDepositAssets(v, 0);
        assertEq(assets, 500e18); // 100 000 / 200
    }

    function test_setSafetyModule_zeroRejectedInSafetyModuleMode() public {
        _enableSafetyModule(100_000e6, 10_000);
        vm.startPrank(admin);
        vm.expectRevert(CapController.SafetyModuleNotSet.selector);
        cap.setSafetyModule(address(0));
        cap.setCapMode(CapController.CapMode.FIXED);
        cap.setSafetyModule(address(0)); // allowed once FIXED
        vm.stopPrank();
        assertEq(address(cap.safetyModule()), address(0));
    }

    function test_switchBackToFixed() public {
        _enableSafetyModule(100_000e6, 10_000);
        vm.prank(admin);
        cap.setCapMode(CapController.CapMode.FIXED);
        assertEq(cap.vaultCapUSD(v), 25_000e6);
    }

    // ───────────────────────────── setters ─────────────────────────────

    function test_setK_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(CapController.OutOfBounds.selector);
        cap.setK(1e18 - 1);
        vm.expectRevert(CapController.OutOfBounds.selector);
        cap.setK(20e18 + 1);
        cap.setK(20e18);
        assertEq(cap.k(), 20e18);
        vm.stopPrank();
    }

    function test_setCapWeightBps_sumBound() public {
        vm.startPrank(admin);
        cap.setCapWeightBps(v, 6_000);
        vm.expectRevert(CapController.WeightsExceedTotal.selector);
        cap.setCapWeightBps(makeAddr("v2"), 4_001);
        cap.setCapWeightBps(makeAddr("v2"), 4_000);
        assertEq(cap.totalWeightBps(), 10_000);
        cap.setCapWeightBps(v, 1_000); // lowering frees room
        assertEq(cap.totalWeightBps(), 5_000);
        vm.stopPrank();
    }

    function test_setPriceSource() public {
        vm.startPrank(admin);
        vm.expectRevert(CapController.ZeroAddress.selector);
        cap.setPriceSource(address(0));
        cap.setPriceSource(address(0xBEEF));
        assertEq(address(cap.priceSource()), address(0xBEEF));
        vm.stopPrank();
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(alice);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(err);
        cap.setPriceSource(address(1));
        vm.expectRevert(err);
        cap.setSafetyModule(address(1));
        vm.expectRevert(err);
        cap.setCapMode(CapController.CapMode.FIXED);
        vm.expectRevert(err);
        cap.setK(2e18);
        vm.expectRevert(err);
        cap.setCapUSD(v, 1);
        vm.expectRevert(err);
        cap.setCapWeightBps(v, 1);
        vm.stopPrank();
    }
}
