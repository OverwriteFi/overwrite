// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BondManager} from "../src/BondManager.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BondManagerTest is Test {
    MockUSDG internal usdg;
    BondManager internal bm;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal ah = makeAddr("auctionHouse");
    address internal mm = makeAddr("mm");
    address internal other = makeAddr("other");

    IBondManager.BondKind internal constant MM = IBondManager.BondKind.MM;
    IBondManager.BondKind internal constant CURATOR = IBondManager.BondKind.CURATOR;
    uint256 internal constant MM_BOND = 25_000e6;
    uint256 internal constant CURATOR_BOND = 10_000e6;

    function setUp() public {
        usdg = new MockUSDG();
        bm = new BondManager(address(usdg), admin, treasury);
        vm.prank(admin);
        bm.setAuctionHouse(ah);
        usdg.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdg.approve(address(bm), type(uint256).max);
    }

    function _post() internal {
        vm.prank(mm);
        bm.postBond(MM);
    }

    // ───────────────────────────── constructor / wiring ─────────────────────────────

    function test_constructor_defaults() public view {
        assertEq(bm.requiredAmount(MM), MM_BOND);
        assertEq(bm.requiredAmount(CURATOR), CURATOR_BOND);
        assertEq(bm.BOND_COOLDOWN(), 7 days);
        assertEq(bm.treasury(), treasury);
        assertEq(bm.auctionHouse(), ah);
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(BondManager.ZeroAddress.selector);
        new BondManager(address(0), admin, treasury);
        vm.expectRevert(BondManager.ZeroAddress.selector);
        new BondManager(address(usdg), admin, address(0));
    }

    function test_setAuctionHouse_onceOnly() public {
        vm.prank(admin);
        vm.expectRevert(BondManager.AlreadySet.selector);
        bm.setAuctionHouse(other);
        BondManager fresh = new BondManager(address(usdg), admin, treasury);
        vm.prank(admin);
        vm.expectRevert(BondManager.ZeroAddress.selector);
        fresh.setAuctionHouse(address(0));
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        fresh.setAuctionHouse(ah);
        // lock reverts while unset
        vm.prank(ah);
        vm.expectRevert(BondManager.NotAuctionHouse.selector);
        fresh.lock(mm, 1);
    }

    // ───────────────────────────── postBond ─────────────────────────────

    function test_postBond_happy() public {
        vm.expectEmit(true, false, false, true);
        emit BondManager.BondPosted(mm, MM, address(usdg), MM_BOND);
        vm.prank(mm);
        uint256 posted = bm.postBond(MM);
        assertEq(posted, MM_BOND);
        assertEq(usdg.balanceOf(address(bm)), MM_BOND);
        (uint256 amount, address asset, uint64 unlockAt) = bm.status(mm, MM);
        assertEq(amount, MM_BOND);
        assertEq(asset, address(usdg));
        assertEq(unlockAt, 0);
        assertTrue(bm.hasActiveMMBond(mm));
        assertFalse(bm.hasActiveMMBond(other));
    }

    function test_postBond_alreadyBondedReverts() public {
        _post();
        vm.prank(mm);
        vm.expectRevert(BondManager.AlreadyBonded.selector);
        bm.postBond(MM);
    }

    function test_postBond_topsUpAfterRequirementRaised() public {
        _post();
        vm.prank(admin);
        bm.setRequiredAmount(MM, 30_000e6);
        assertFalse(bm.hasActiveMMBond(mm), "below new requirement");
        vm.prank(mm);
        uint256 posted = bm.postBond(MM);
        assertEq(posted, 5_000e6);
        assertTrue(bm.hasActiveMMBond(mm));
    }

    function test_postBond_revertsWhileWithdrawalPending() public {
        _post();
        vm.prank(mm);
        bm.requestWithdraw(MM);
        vm.prank(mm);
        vm.expectRevert(BondManager.WithdrawalPending.selector);
        bm.postBond(MM);
    }

    function test_postBond_curatorIndependentOfMM() public {
        vm.prank(mm);
        bm.postBond(CURATOR);
        assertFalse(bm.hasActiveMMBond(mm));
        (uint256 amount,,) = bm.status(mm, CURATOR);
        assertEq(amount, CURATOR_BOND);
    }

    function test_postBond_withoutFundsReverts() public {
        vm.prank(other);
        vm.expectRevert();
        bm.postBond(MM);
    }

    // ───────────────────────────── withdraw flow ─────────────────────────────

    function test_requestWithdraw_happyAndInactive() public {
        _post();
        uint64 expected = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, false, false, true);
        emit BondManager.BondWithdrawRequested(mm, MM, address(usdg), expected);
        vm.prank(mm);
        uint64 unlockAt = bm.requestWithdraw(MM);
        assertEq(unlockAt, expected);
        assertFalse(bm.hasActiveMMBond(mm), "pending withdrawal is not active");
    }

    /// D-049: MM participation locks gate the MM bond only; the curator bond of the same account is unaffected.
    function test_locks_gateMMBondOnly() public {
        _post();
        vm.prank(mm);
        bm.postBond(CURATOR);
        vm.prank(ah);
        bm.lock(mm, 1);
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Locked.selector, 1));
        bm.requestWithdraw(MM);
        vm.prank(mm);
        uint64 unlockAt = bm.requestWithdraw(CURATOR);
        vm.warp(unlockAt);
        vm.prank(mm);
        assertEq(bm.withdrawBond(CURATOR), CURATOR_BOND);
        assertTrue(bm.hasActiveMMBond(mm), "MM bond untouched");
    }

    function test_requestWithdraw_reverts() public {
        vm.prank(mm);
        vm.expectRevert(BondManager.NoBond.selector);
        bm.requestWithdraw(MM);
        _post();
        vm.prank(mm);
        bm.requestWithdraw(MM);
        vm.prank(mm);
        vm.expectRevert(BondManager.WithdrawalPending.selector);
        bm.requestWithdraw(MM);
    }

    function test_requestWithdraw_revertsWhileLocked() public {
        _post();
        vm.prank(ah);
        bm.lock(mm, 7);
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Locked.selector, 1));
        bm.requestWithdraw(MM);
    }

    function test_cancelWithdraw() public {
        _post();
        vm.prank(mm);
        vm.expectRevert(BondManager.NoWithdrawalPending.selector);
        bm.cancelWithdraw(MM);
        vm.prank(mm);
        bm.requestWithdraw(MM);
        vm.prank(mm);
        bm.cancelWithdraw(MM);
        assertTrue(bm.hasActiveMMBond(mm));
        (,, uint64 unlockAt) = bm.status(mm, MM);
        assertEq(unlockAt, 0);
    }

    function test_withdrawBond_cooldownAndLocks() public {
        _post();
        vm.prank(mm);
        vm.expectRevert(BondManager.NoWithdrawalPending.selector);
        bm.withdrawBond(MM);
        vm.prank(mm);
        uint64 unlockAt = bm.requestWithdraw(MM);
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSelector(BondManager.CooldownActive.selector, unlockAt));
        bm.withdrawBond(MM);
        vm.warp(unlockAt);
        // a lock added after the request (only possible if the bond is re-activated) blocks the withdrawal
        vm.prank(ah);
        bm.lock(mm, 1);
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Locked.selector, 1));
        bm.withdrawBond(MM);
        vm.prank(ah);
        bm.unlock(mm, 1);
        uint256 before = usdg.balanceOf(mm);
        vm.expectEmit(true, false, false, true);
        emit BondManager.BondWithdrawn(mm, MM, address(usdg), MM_BOND);
        vm.prank(mm);
        uint256 amount = bm.withdrawBond(MM);
        assertEq(amount, MM_BOND);
        assertEq(usdg.balanceOf(mm) - before, MM_BOND);
        (uint256 left,, uint64 u) = bm.status(mm, MM);
        assertEq(left, 0);
        assertEq(u, 0);
        assertFalse(bm.hasActiveMMBond(mm));
    }

    // ───────────────────────────── locks ─────────────────────────────

    function test_lock_unlock_onlyAuctionHouseAndIdempotent() public {
        vm.prank(other);
        vm.expectRevert(BondManager.NotAuctionHouse.selector);
        bm.lock(mm, 1);
        vm.prank(other);
        vm.expectRevert(BondManager.NotAuctionHouse.selector);
        bm.unlock(mm, 1);

        vm.startPrank(ah);
        vm.expectEmit(true, true, false, true);
        emit BondManager.BondLocked(mm, 1);
        bm.lock(mm, 1);
        bm.lock(mm, 1); // no-op
        bm.lock(mm, 2);
        assertEq(bm.activeLocks(mm), 2);
        assertTrue(bm.isLocked(mm, 1));
        vm.expectEmit(true, true, false, true);
        emit BondManager.BondUnlocked(mm, 1);
        bm.unlock(mm, 1);
        bm.unlock(mm, 1); // no-op
        bm.unlock(mm, 3); // never locked: no-op
        assertEq(bm.activeLocks(mm), 1);
        assertFalse(bm.isLocked(mm, 1));
        assertTrue(bm.isLocked(mm, 2));
        vm.stopPrank();
    }

    // ───────────────────────────── slashing ─────────────────────────────

    function test_slashBond_happyAndBounds() public {
        _post();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        bm.slashBond(mm, MM, 1, "uri");
        vm.prank(admin);
        vm.expectRevert(BondManager.ZeroAmount.selector);
        bm.slashBond(mm, MM, 0, "uri");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BondManager.ExceedsBond.selector, MM_BOND + 1, MM_BOND));
        bm.slashBond(mm, MM, MM_BOND + 1, "uri");

        vm.expectEmit(true, false, false, true);
        emit BondManager.BondSlashed(mm, MM, address(usdg), 5_000e6, "ipfs://evidence");
        vm.prank(admin);
        bm.slashBond(mm, MM, 5_000e6, "ipfs://evidence");
        assertEq(usdg.balanceOf(treasury), 5_000e6);
        (uint256 amount,,) = bm.status(mm, MM);
        assertEq(amount, 20_000e6);
        assertFalse(bm.hasActiveMMBond(mm), "slashed below requirement");
        // top up restores eligibility
        vm.prank(mm);
        assertEq(bm.postBond(MM), 5_000e6);
        assertTrue(bm.hasActiveMMBond(mm));
    }

    // ───────────────────────────── admin ─────────────────────────────

    function test_setters() public {
        vm.startPrank(admin);
        vm.expectRevert(BondManager.ZeroAmount.selector);
        bm.setRequiredAmount(MM, 0);
        vm.expectEmit(true, false, false, true);
        emit BondManager.ParameterChanged(address(bm), "requiredAmountMM", MM_BOND, 1e6);
        bm.setRequiredAmount(MM, 1e6);
        bm.setRequiredAmount(CURATOR, 2e6);
        assertEq(bm.requiredAmount(CURATOR), 2e6);
        vm.expectRevert(BondManager.ZeroAddress.selector);
        bm.setTreasury(address(0));
        bm.setTreasury(other);
        assertEq(bm.treasury(), other);
        vm.stopPrank();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        bm.setRequiredAmount(MM, 1);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    /// @dev Top-up arithmetic: after any sequence of requirement changes the posted amount equals the requirement.
    function testFuzz_postBond_topUpExact(uint256 req1, uint256 req2) public {
        req1 = bound(req1, 1, 500_000e6);
        req2 = bound(req2, 1, 500_000e6);
        vm.prank(admin);
        bm.setRequiredAmount(MM, req1);
        vm.prank(mm);
        uint256 p1 = bm.postBond(MM);
        assertEq(p1, req1);
        vm.prank(admin);
        bm.setRequiredAmount(MM, req2);
        (uint256 amount,,) = bm.status(mm, MM);
        if (req2 > req1) {
            vm.prank(mm);
            uint256 p2 = bm.postBond(MM);
            assertEq(p2, req2 - req1);
            (amount,,) = bm.status(mm, MM);
            assertEq(amount, req2);
        } else {
            vm.prank(mm);
            vm.expectRevert(BondManager.AlreadyBonded.selector);
            bm.postBond(MM);
            assertEq(amount, req1);
        }
        assertTrue(bm.hasActiveMMBond(mm));
        assertEq(usdg.balanceOf(address(bm)), amount, "contract holds exactly the bond");
    }

    /// @dev Slashing never moves more than the bond and always lands in the treasury.
    function testFuzz_slash_conserves(uint256 amount) public {
        _post();
        amount = bound(amount, 1, MM_BOND);
        vm.prank(admin);
        bm.slashBond(mm, MM, amount, "");
        (uint256 left,,) = bm.status(mm, MM);
        assertEq(left + amount, MM_BOND);
        assertEq(usdg.balanceOf(treasury), amount);
        assertEq(usdg.balanceOf(address(bm)), left);
        assertEq(bm.hasActiveMMBond(mm), left >= MM_BOND);
    }
}
