// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RiskModule} from "../src/RiskModule.sol";
import {OracleParams} from "../src/Types.sol";

/// @dev RiskModule unit + fuzz tests (SPEC §15, I-7; D-029, D-031, D-050, D-056; THREAT-MODEL T-13, T-14, T-15).
contract RiskModuleTest is Test {
    RiskModule internal rm;
    address internal admin = makeAddr("admin");
    address internal hot = makeAddr("guardianHot");
    address internal cold = makeAddr("guardianCold");
    address internal oracle = makeAddr("oracle");
    address internal vaultA = makeAddr("vaultA");
    address internal vaultB = makeAddr("vaultB");
    address internal rando = makeAddr("rando");
    address internal constant ALL = address(0);

    function setUp() public {
        vm.warp(1_788_344_808);
        rm = new RiskModule(admin);
        vm.mockCall(oracle, abi.encodeWithSignature("riskModule()"), abi.encode(address(rm))); // C-3 back-pointer
        vm.startPrank(admin);
        rm.setSettlementOracle(oracle);
        rm.setGuardian(hot, true);
        rm.setGuardian(cold, true);
        vm.stopPrank();
    }

    function _p() internal view returns (OracleParams memory) {
        return rm.defaultParams();
    }

    // ───────────────────────────── wiring ─────────────────────────────

    function test_constructor_ownerIsTimelockAddress() public view {
        assertEq(rm.owner(), admin);
        assertEq(rm.settlementOracle(), oracle);
    }

    function test_setSettlementOracle_onceOnly() public {
        vm.prank(admin);
        vm.expectRevert(RiskModule.AlreadySet.selector);
        rm.setSettlementOracle(rando);
        RiskModule fresh = new RiskModule(admin);
        vm.prank(admin);
        vm.expectRevert(RiskModule.ZeroAddress.selector);
        fresh.setSettlementOracle(address(0));
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        fresh.setSettlementOracle(oracle);
        // C-3: an oracle wired to another RiskModule is refused
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RiskModule.Miswired.selector, bytes32("ORACLE_RISK_MODULE")));
        fresh.setSettlementOracle(oracle);
    }

    function test_setGuardian_grantRevoke() public {
        assertTrue(rm.hasRole(rm.GUARDIAN_ROLE(), hot));
        vm.prank(admin);
        rm.setGuardian(hot, false);
        assertFalse(rm.hasRole(rm.GUARDIAN_ROLE(), hot));
        vm.prank(hot);
        vm.expectRevert(RiskModule.NotGuardian.selector);
        rm.pauseDeposits(vaultA);
        vm.prank(admin);
        vm.expectRevert(RiskModule.ZeroAddress.selector);
        rm.setGuardian(address(0), true);
    }

    /// T-13 analogue: nobody holds DEFAULT_ADMIN_ROLE, so roles cannot be granted around the timelock.
    function test_T13_noRoleAdminExists() public {
        assertFalse(rm.hasRole(rm.DEFAULT_ADMIN_ROLE(), admin));
        bytes32 role = rm.GUARDIAN_ROLE();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0))
        );
        rm.grantRole(role, rando);
    }

    // ───────────────────────────── guardian scope (T-15, I-7) ─────────────────────────────

    function test_T15_guardianCannotCallAnySetter() public {
        OracleParams memory p = _p();
        address[2] memory gs = [hot, cold];
        for (uint256 i; i < gs.length; ++i) {
            vm.startPrank(gs[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, gs[i]));
            rm.setOracleParams(vaultA, p);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, gs[i]));
            rm.setGuardian(rando, true);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, gs[i]));
            rm.setSettlementOracle(rando);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, gs[i]));
            rm.transferOwnership(gs[i]);
            vm.expectRevert(RiskModule.NotSettlementOracle.selector);
            rm.pauseNewAuctionsOnHalt(vaultA, 1, "X");
            vm.stopPrank();
        }
    }

    function test_T15_randoCannotPause() public {
        vm.prank(rando);
        vm.expectRevert(RiskModule.NotGuardian.selector);
        rm.pauseNewAuctions(vaultA);
    }

    /// I-7: a guardian call writes at most one storage slot, and only a pause flag. Checked with vm.record and
    /// by asserting every non-flag getter is unchanged.
    function test_I7_guardianTouchesOnlyPauseFlags() public {
        OracleParams memory p0 = _p();
        vm.prank(admin);
        rm.setOracleParams(vaultA, p0);
        bytes32 paramsBefore = keccak256(abi.encode(rm.currentParams(vaultA)));
        uint256 versionsBefore = rm.versionCount(vaultA);

        // learn the four flag slots by writing each flag once
        bytes32[4] memory flagSlots;
        flagSlots[0] = _writtenSlot(hot, abi.encodeCall(rm.pauseDeposits, (ALL)));
        flagSlots[1] = _writtenSlot(hot, abi.encodeCall(rm.pauseNewAuctions, (ALL)));
        flagSlots[2] = _writtenSlot(hot, abi.encodeCall(rm.pauseDeposits, (vaultA)));
        flagSlots[3] = _writtenSlot(hot, abi.encodeCall(rm.pauseNewAuctions, (vaultA)));

        bytes[8] memory calls = [
            abi.encodeCall(rm.unpauseDeposits, (ALL)),
            abi.encodeCall(rm.unpauseNewAuctions, (ALL)),
            abi.encodeCall(rm.unpauseDeposits, (vaultA)),
            abi.encodeCall(rm.unpauseNewAuctions, (vaultA)),
            abi.encodeCall(rm.pauseDeposits, (vaultA)),
            abi.encodeCall(rm.pauseNewAuctions, (vaultA)),
            abi.encodeCall(rm.pauseDeposits, (ALL)),
            abi.encodeCall(rm.pauseNewAuctions, (ALL))
        ];
        for (uint256 i; i < calls.length; ++i) {
            bytes32 slot = _writtenSlot(i % 2 == 0 ? hot : cold, calls[i]);
            bool known;
            for (uint256 j; j < 4; ++j) {
                if (slot == flagSlots[j]) known = true;
            }
            assertTrue(known, "I-7: wrote a non-flag slot");
        }
        assertEq(keccak256(abi.encode(rm.currentParams(vaultA))), paramsBefore, "params untouched");
        assertEq(rm.versionCount(vaultA), versionsBefore, "versions untouched");
        assertEq(rm.settlementOracle(), oracle);
        assertEq(rm.owner(), admin);
        assertTrue(rm.hasRole(rm.GUARDIAN_ROLE(), hot));
        assertTrue(rm.hasRole(rm.GUARDIAN_ROLE(), cold));
    }

    function _writtenSlot(address who, bytes memory data) internal returns (bytes32 slot) {
        vm.record();
        vm.prank(who);
        (bool ok,) = address(rm).call(data);
        assertTrue(ok, "guardian call failed");
        (, bytes32[] memory writes) = vm.accesses(address(rm));
        assertEq(writes.length, 1, "I-7: exactly one slot written");
        slot = writes[0];
    }

    // ───────────────────────────── pause semantics ─────────────────────────────

    function test_pause_allDominatesVault() public {
        vm.prank(hot);
        rm.pauseDeposits(ALL);
        assertTrue(rm.depositsPaused(vaultA));
        assertTrue(rm.depositsPaused(vaultB));
        vm.prank(cold);
        rm.unpauseDeposits(vaultA); // no effect while ALL is paused
        assertTrue(rm.depositsPaused(vaultA));
        vm.prank(cold);
        rm.unpauseDeposits(ALL);
        assertFalse(rm.depositsPaused(vaultA));
    }

    function test_pause_unpauseAllKeepsVaultFlags() public {
        vm.startPrank(hot);
        rm.pauseNewAuctions(vaultA);
        rm.pauseNewAuctions(ALL);
        rm.unpauseNewAuctions(ALL);
        vm.stopPrank();
        assertTrue(rm.auctionsPaused(vaultA), "vault flag survives");
        assertFalse(rm.auctionsPaused(vaultB));
    }

    /// D-029: either guardian can undo the other's pause; the owner can too.
    function test_pause_eitherGuardianUnpauses() public {
        vm.prank(hot);
        rm.pauseDeposits(vaultA);
        vm.prank(cold);
        rm.unpauseDeposits(vaultA);
        assertFalse(rm.depositsPaused(vaultA));
        vm.prank(cold);
        rm.pauseNewAuctions(vaultA);
        vm.prank(admin);
        rm.unpauseNewAuctions(vaultA);
        assertFalse(rm.auctionsPaused(vaultA));
    }

    function test_pause_idempotentAndEvents() public {
        vm.expectEmit(true, true, true, true);
        emit RiskModule.Paused(vaultA, "DEPOSITS", hot);
        vm.prank(hot);
        rm.pauseDeposits(vaultA);
        vm.prank(hot);
        rm.pauseDeposits(vaultA); // no revert
        assertTrue(rm.depositsPaused(vaultA));
    }

    // ───────────────────────────── halt hook ─────────────────────────────

    function test_pauseNewAuctionsOnHalt_onlyOracle_andRegistry() public {
        vm.prank(rando);
        vm.expectRevert(RiskModule.NotSettlementOracle.selector);
        rm.pauseNewAuctionsOnHalt(vaultA, 7, "NO_ORACLE_PATH");
        vm.expectEmit(true, true, true, true);
        emit RiskModule.VaultHalted(vaultA, 7, "NO_ORACLE_PATH");
        vm.prank(oracle);
        rm.pauseNewAuctionsOnHalt(vaultA, 7, "NO_ORACLE_PATH");
        assertTrue(rm.auctionsPaused(vaultA));
        assertFalse(rm.auctionsPaused(vaultB));
        (uint256 sid, bytes32 reason, uint64 at) = rm.lastHalt(vaultA);
        assertEq(sid, 7);
        assertEq(reason, bytes32("NO_ORACLE_PATH"));
        assertEq(at, uint64(block.timestamp));
        assertEq(rm.haltCount(vaultA), 1);
        vm.prank(hot);
        rm.unpauseNewAuctions(vaultA);
        assertFalse(rm.auctionsPaused(vaultA));
    }

    // ───────────────────────────── parameters ─────────────────────────────

    function test_defaultsMatchSpec() public view {
        OracleParams memory p = rm.defaultParams();
        assertEq(p.weekdayMaxStale, 26 hours);
        assertEq(p.twapGrace, 1_800);
        assertEq(p.sequencerGrace, 3_600);
        assertEq(p.usdgMaxStale, 26 hours);
        assertEq(p.weekendTwapBoundBps, 1_500);
        assertEq(p.weekdayTwapBoundBps, 300);
        assertEq(p.impactBps, 100);
        assertEq(p.jumpBps, 3_000);
        assertEq(p.usdgBandLowBps, 9_800);
        assertEq(p.usdgBandHighBps, 10_200);
        assertEq(p.minObservationsInWindow, 3);
        assertEq(p.swapNotionalUSDG, 250_000e6);
        assertEq(p.sequencerFeed, address(0));
        assertEq(keccak256(abi.encode(rm.paramsAt(vaultA, 0))), keccak256(abi.encode(p)), "no version => defaults");
    }

    function test_setOracleParams_onlyOwner_zeroVault() public {
        OracleParams memory p = _p();
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        rm.setOracleParams(vaultA, p);
        vm.prank(admin);
        vm.expectRevert(RiskModule.ZeroAddress.selector);
        rm.setOracleParams(address(0), p);
    }

    function test_paramsAt_versioning() public {
        uint64 t0 = uint64(block.timestamp);
        OracleParams memory p1 = _p();
        p1.jumpBps = 2_000;
        OracleParams memory p2 = _p();
        p2.jumpBps = 4_000;
        vm.prank(admin);
        rm.setOracleParams(vaultA, p1);
        vm.warp(t0 + 1 days);
        vm.prank(admin);
        rm.setOracleParams(vaultA, p2);
        assertEq(rm.versionCount(vaultA), 2);
        assertEq(rm.paramsAt(vaultA, t0 - 1).jumpBps, 3_000, "before first version: defaults");
        assertEq(rm.paramsAt(vaultA, t0).jumpBps, 3_000, "same second as version 0 keeps the old params (I-12)");
        assertEq(rm.paramsAt(vaultA, t0 + 1).jumpBps, 2_000);
        assertEq(rm.paramsAt(vaultA, t0 + 1 days).jumpBps, 2_000);
        assertEq(rm.paramsAt(vaultA, t0 + 1 days + 1).jumpBps, 4_000);
        assertEq(rm.paramsAt(vaultA, t0 + 30 days).jumpBps, 4_000);
        assertEq(rm.currentParams(vaultA).jumpBps, 4_000);
        assertEq(rm.paramsAt(vaultB, t0 + 30 days).jumpBps, 3_000, "other vault untouched");
        RiskModule.ParamsVersion memory v = rm.versionAt(vaultA, 1);
        assertEq(v.effectiveFrom, t0 + 1 days + 1);
    }

    function testFuzz_paramsAt_picksLatestNotAfter(uint8 n, uint64 query) public {
        n = uint8(bound(n, 1, 8));
        uint64 t0 = uint64(block.timestamp);
        for (uint256 i; i < n; ++i) {
            OracleParams memory p = _p();
            p.jumpBps = uint16(1_000 + i * 100);
            vm.warp(t0 + i * 1 hours);
            vm.prank(admin);
            rm.setOracleParams(vaultA, p);
        }
        query = uint64(bound(query, t0 - 1, t0 + 24 hours));
        uint16 expected = 3_000;
        for (uint256 i; i < n; ++i) {
            if (t0 + i * 1 hours < query) expected = uint16(1_000 + i * 100);
        }
        assertEq(rm.paramsAt(vaultA, query).jumpBps, expected);
    }

    /// T-14: every parameter is bounded; a value just outside either bound reverts with the field name.
    function test_T14_parameterBoundsEnforced() public {
        _expectOut("weekdayMaxStale", _with("weekdayMaxStale", 3_599));
        _expectOut("weekdayMaxStale", _with("weekdayMaxStale", 108_001));
        _expectOut("twapGrace", _with("twapGrace", 299));
        _expectOut("twapGrace", _with("twapGrace", 3_601));
        _expectOut("weekendTwapBoundBps", _with("weekendTwapBoundBps", 299));
        _expectOut("weekendTwapBoundBps", _with("weekendTwapBoundBps", 1_501));
        _expectOut("weekdayTwapBoundBps", _with("weekdayTwapBoundBps", 99));
        _expectOut("weekdayTwapBoundBps", _with("weekdayTwapBoundBps", 501));
        _expectOut("swapNotionalUSDG", _with("swapNotionalUSDG", 10_000e6 - 1));
        _expectOut("swapNotionalUSDG", _with("swapNotionalUSDG", 10_000_000e6 + 1));
        _expectOut("impactBps", _with("impactBps", 9));
        _expectOut("impactBps", _with("impactBps", 501));
        _expectOut("minObservationsInWindow", _with("minObservationsInWindow", 0));
        _expectOut("minObservationsInWindow", _with("minObservationsInWindow", 17));
        _expectOut("jumpBps", _with("jumpBps", 999));
        _expectOut("jumpBps", _with("jumpBps", 5_001));
        _expectOut("sequencerGrace", _with("sequencerGrace", 599));
        _expectOut("sequencerGrace", _with("sequencerGrace", 86_401));
        _expectOut("usdgBandLowBps", _with("usdgBandLowBps", 8_999));
        _expectOut("usdgBandLowBps", _with("usdgBandLowBps", 10_000));
        _expectOut("usdgBandHighBps", _with("usdgBandHighBps", 10_000));
        _expectOut("usdgBandHighBps", _with("usdgBandHighBps", 11_001));
        _expectOut("usdgMaxStale", _with("usdgMaxStale", 3_599));
        _expectOut("usdgMaxStale", _with("usdgMaxStale", 288_001));
        // extremes inside the bounds succeed
        OracleParams memory lo = _p();
        lo.weekdayMaxStale = 3_600;
        lo.twapGrace = 300;
        lo.weekendTwapBoundBps = 300;
        lo.weekdayTwapBoundBps = 100;
        lo.swapNotionalUSDG = 10_000e6;
        lo.impactBps = 10;
        lo.minObservationsInWindow = 1;
        lo.jumpBps = 1_000;
        lo.sequencerGrace = 600;
        lo.usdgBandLowBps = 9_000;
        lo.usdgBandHighBps = 10_001;
        lo.usdgMaxStale = 3_600;
        lo.sequencerFeed = rando;
        vm.prank(admin);
        rm.setOracleParams(vaultA, lo);
        assertEq(rm.currentParams(vaultA).sequencerFeed, rando);
    }

    function testFuzz_T14_jumpBpsBound(uint16 v) public {
        OracleParams memory p = _with("jumpBps", v);
        vm.prank(admin);
        if (v < 1_000 || v > 5_000) {
            vm.expectRevert(abi.encodeWithSelector(RiskModule.OutOfBounds.selector, bytes32("jumpBps")));
        }
        rm.setOracleParams(vaultA, p);
    }

    function _with(bytes32 key, uint256 v) internal view returns (OracleParams memory p) {
        p = _p();
        if (key == "weekdayMaxStale") p.weekdayMaxStale = uint32(v);
        else if (key == "twapGrace") p.twapGrace = uint32(v);
        else if (key == "weekendTwapBoundBps") p.weekendTwapBoundBps = uint16(v);
        else if (key == "weekdayTwapBoundBps") p.weekdayTwapBoundBps = uint16(v);
        else if (key == "swapNotionalUSDG") p.swapNotionalUSDG = uint128(v);
        else if (key == "impactBps") p.impactBps = uint16(v);
        else if (key == "minObservationsInWindow") p.minObservationsInWindow = uint8(v);
        else if (key == "jumpBps") p.jumpBps = uint16(v);
        else if (key == "sequencerGrace") p.sequencerGrace = uint32(v);
        else if (key == "usdgBandLowBps") p.usdgBandLowBps = uint16(v);
        else if (key == "usdgBandHighBps") p.usdgBandHighBps = uint16(v);
        else if (key == "usdgMaxStale") p.usdgMaxStale = uint32(v);
    }

    function _expectOut(bytes32 key, OracleParams memory p) internal {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RiskModule.OutOfBounds.selector, key));
        rm.setOracleParams(vaultA, p);
    }

    // ───────────────────────────── real 48 h timelock (D-003, D-031) ─────────────────────────────

    function test_timelock48h_parameterChange() public {
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        TimelockController tl = new TimelockController(48 hours, proposers, proposers, address(0));
        vm.prank(admin);
        rm.transferOwnership(address(tl));
        // accept through the timelock (two-step ownership)
        bytes memory accept = abi.encodeCall(rm.acceptOwnership, ());
        vm.prank(admin);
        tl.schedule(address(rm), 0, accept, bytes32(0), bytes32("s1"), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        tl.execute(address(rm), 0, accept, bytes32(0), bytes32("s1"));
        assertEq(rm.owner(), address(tl));

        // parameter change: not before 48 h, applies only to later timestamps (I-12)
        OracleParams memory p = _p();
        p.weekdayMaxStale = 1 hours;
        bytes memory data = abi.encodeCall(rm.setOracleParams, (vaultA, p));
        uint64 seriesOpen = uint64(block.timestamp);
        vm.prank(admin);
        tl.schedule(address(rm), 0, data, bytes32(0), bytes32("s2"), 48 hours);
        vm.warp(block.timestamp + 47 hours);
        vm.prank(admin);
        vm.expectRevert();
        tl.execute(address(rm), 0, data, bytes32(0), bytes32("s2"));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(admin);
        tl.execute(address(rm), 0, data, bytes32(0), bytes32("s2"));
        assertEq(rm.currentParams(vaultA).weekdayMaxStale, 1 hours, "new series use 1 h");
        assertEq(rm.paramsAt(vaultA, seriesOpen).weekdayMaxStale, 26 hours, "I-12: series opened before keep 26 h");
        // the guardian is untouched by the ownership move and the admin EOA lost direct access
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        rm.setOracleParams(vaultA, p);
        vm.prank(hot);
        rm.pauseDeposits(vaultA);
        assertTrue(rm.depositsPaused(vaultA));
    }
}
