// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "./TokenUnitBase.t.sol";
import {TokenDeployLib} from "../script/TokenDeployLib.sol";
import {Vesting} from "../src/Vesting.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {MockCurvePool} from "./mocks/MockCurvePool.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockLaunchpad} from "./mocks/MockLaunchpad.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Guards added by the independent review of this phase (D-098), plus the privileged-caller and
/// error-branch coverage that review found missing. Everything here is on the five holders; the staking side
/// lives in `TokenLayerGuards.t.sol`.
contract TokenHolderGuardsTest is TokenUnitBaseTest {
    uint64 internal constant VEST_DURATION = 1095 days;
    uint64 internal constant TEAM_CLIFF = 365 days;

    // ═════════════════════════════ the staged deploy owns nothing (D-098) ═════════════════════════════

    /// @dev The deployer key must never hold a privilege over what it just created. The earlier shape had it
    /// own all seven contracts until the timelock's `acceptOwnership` cleared a 48 h delay, which would have
    /// let one hot key move 700 M WRITE and misdirect the 300 M emissions stream irreversibly.
    function test_stagedDeploy_deployerHoldsNoPrivilege() public {
        address deployer = makeAddr("deployer");
        address timelock = makeAddr("timelock");
        TokenDeployLib.Params memory p = _params();
        p.owner = timelock;

        vm.startPrank(deployer);
        TokenDeployLib.Holders memory h = TokenDeployLib.deployHolders(p);
        TokenDeployLib.deployToken(h);
        vm.stopPrank();

        assertEq(Ownable(address(h.escrow)).owner(), timelock);
        assertEq(Ownable(address(h.emissions)).owner(), timelock);
        assertEq(Ownable(address(h.treasuryVesting)).owner(), timelock);
        assertEq(Ownable(address(h.teamVesting)).owner(), timelock);
        assertEq(Ownable(address(h.points)).owner(), timelock);

        // Every lever the deployer would need to take the supply is closed to it.
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer);
        vm.startPrank(deployer);
        vm.expectRevert(denied);
        h.escrow.setPool(address(1));
        vm.expectRevert(denied);
        h.treasuryVesting.reallocateUnallocated(deployer, 1);
        vm.expectRevert(denied);
        h.emissions.setSink(deployer);
        vm.expectRevert(denied);
        h.points.setRound(1, bytes32(uint256(1)), 1, uint64(block.timestamp), uint64(block.timestamp + 1));
        vm.stopPrank();
    }

    // ═════════════════════════════ Vesting ═════════════════════════════

    /// @dev D-091 recorded a guard against a proposal that unlocks a grant instantly, but `cliff == duration`
    /// and `start + cliff == now` both slipped through and vested the whole amount in the creating block.
    function test_createSchedule_cannotBeFullyVestedOnCreation() public {
        vm.warp(block.timestamp + 400 days);
        uint64 start = uint64(block.timestamp - 365 days);
        vm.prank(admin);
        vm.expectRevert(Vesting.InvalidSchedule.selector);
        teamVesting.createSchedule(teamMember, start, 365 days, 365 days, 1_000e18, true);
    }

    function test_createSchedule_rejectsCliffEqualToDuration() public {
        vm.prank(admin);
        vm.expectRevert(Vesting.InvalidSchedule.selector);
        teamVesting.createSchedule(teamMember, uint64(block.timestamp), VEST_DURATION, VEST_DURATION, 1e18, true);
    }

    function test_createSchedule_rejectsATermShorterThanTheMinimum() public {
        uint64 minTerm = teamVesting.MIN_REMAINING_TERM();
        vm.prank(admin);
        vm.expectRevert(Vesting.InvalidSchedule.selector);
        teamVesting.createSchedule(teamMember, uint64(block.timestamp), 0, minTerm - 1, 1e18, true);
    }

    /// @dev Before any grant exists the "unallocated pool" is the whole bucket, so this would be a drain
    /// rather than the re-granting path it is meant to be.
    function test_reallocateUnallocated_blockedUntilAScheduleExists() public {
        vm.prank(admin);
        vm.expectRevert(Vesting.NoSchedulesYet.selector);
        treasuryVesting.reallocateUnallocated(treasury, 1e18);

        vm.prank(admin);
        treasuryVesting.createSchedule(treasury, uint64(block.timestamp), 0, VEST_DURATION, 100_000_000e18, false);
        vm.prank(admin);
        treasuryVesting.reallocateUnallocated(treasury, 1e18);
        assertEq(write.balanceOf(treasury), 1e18);
    }

    function test_vesting_unknownScheduleReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Vesting.UnknownSchedule.selector, uint256(0)));
        teamVesting.releasable(0);
    }

    function test_vesting_setWriteTokenErrorBranches() public {
        Vesting fresh = new Vesting(admin, 1_000e18, true);
        vm.startPrank(admin);
        vm.expectRevert(Vesting.ZeroAddress.selector);
        fresh.setWriteToken(address(0));
        vm.expectRevert(abi.encodeWithSelector(Vesting.NotAContract.selector, alice));
        fresh.setWriteToken(alice);
        vm.expectRevert(abi.encodeWithSelector(Vesting.Underfunded.selector, 0, 1_000e18));
        fresh.setWriteToken(address(write));
        vm.stopPrank();
    }

    /// @dev A rotated grant must not keep showing against the previous beneficiary.
    function test_acceptBeneficiary_dropsTheIdFromTheOldIndex() public {
        vm.prank(admin);
        uint256 id =
            teamVesting.createSchedule(teamMember, uint64(block.timestamp), TEAM_CLIFF, VEST_DURATION, 1e18, true);
        assertEq(teamVesting.idsOf(teamMember).length, 1);

        vm.prank(teamMember);
        teamVesting.proposeBeneficiary(id, alice);
        vm.prank(alice);
        teamVesting.acceptBeneficiary(id);

        assertEq(teamVesting.idsOf(teamMember).length, 0, "dropped from the old beneficiary");
        assertEq(teamVesting.idsOf(alice).length, 1, "and added to the new one");
    }

    // ═════════════════════════════ LiquidityEscrow ═════════════════════════════

    /// @dev T-25: 25 % of supply is one `fund` call away, so every shape where a bare `transfer` is a donation
    /// must be rejected at configuration time -- Uniswap's `token0()/token1()`, Curve's `coins(uint256)`, and
    /// the two addresses that have code but expose no pair getter at all (the escrow itself and the token),
    /// which a shape probe alone would wave through.
    function test_T25_setPoolRejectsEveryRawAmmShape() public {
        MockUniswapV3Pool uni =
            new MockUniswapV3Pool(address(usdg), address(write), 500, 0, 1e18, uint32(block.timestamp));
        MockCurvePool curve = new MockCurvePool(address(usdg), address(write));

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.PoolIsRawAmm.selector, address(uni)));
        escrow.setPool(address(uni));
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.PoolIsRawAmm.selector, address(curve)));
        escrow.setPool(address(curve));
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.PoolIsRawAmm.selector, address(escrow)));
        escrow.setPool(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(LiquidityEscrow.PoolIsRawAmm.selector, address(write)));
        escrow.setPool(address(write));
        vm.stopPrank();

        assertEq(escrow.pool(), address(0), "nothing was accepted");
    }

    function test_setPool_rejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LiquidityEscrow.ZeroAddress.selector);
        escrow.setPool(address(0));
    }

    /// @dev The launchpad's own bookkeeping is what distinguishes it from a raw pool.
    function test_fund_reachesTheLaunchpadAndIsAccountedFor() public {
        MockLaunchpad launchpad = new MockLaunchpad(address(write));
        vm.startPrank(admin);
        escrow.setPool(address(launchpad));
        escrow.fund(1_000e18);
        vm.stopPrank();
        launchpad.sync(1_000e18);
        assertEq(launchpad.received(), 1_000e18);
        assertEq(write.balanceOf(address(launchpad)), 1_000e18);
    }

    // ═════════════════════════════ PointsDistributor ═════════════════════════════

    function test_setRound_errorBranches() public {
        uint64 start = uint64(block.timestamp);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundUnset.selector, uint256(1)));
        points.setRound(1, bytes32(0), 1e18, start, start + 1 days);
        vm.expectRevert(PointsDistributor.ZeroAmount.selector);
        points.setRound(1, bytes32(uint256(1)), 0, start, start + 1 days);
        vm.stopPrank();
    }

    function test_sweep_revertsOnAnUnsetRound() public {
        vm.expectRevert(abi.encodeWithSelector(PointsDistributor.RoundUnset.selector, uint256(42)));
        points.sweep(42);
    }

    function test_points_setWriteTokenAlreadySet() public {
        vm.prank(admin);
        vm.expectRevert(PointsDistributor.AlreadySet.selector);
        points.setWriteToken(address(write));
    }

    // ═════════════════════════════ EmissionsController ═════════════════════════════

    function test_emissions_boundaryDurationsAreAccepted() public {
        EmissionsController lo = new EmissionsController(admin, lo_MIN());
        EmissionsController hi = new EmissionsController(admin, 3650 days);
        assertEq(lo.endTime() - lo.startTime(), lo_MIN());
        assertEq(hi.endTime() - hi.startTime(), 3650 days);
    }

    function lo_MIN() internal view returns (uint64) {
        return emis.MIN_DURATION();
    }

    function test_emissions_setWriteTokenAlreadySet() public {
        vm.prank(admin);
        vm.expectRevert(EmissionsController.AlreadySet.selector);
        emis.setWriteToken(address(write));
    }

    // ═════════════════════════════ unauthorised callers (rule 5) ═════════════════════════════

    /// @dev Every `onlyOwner` entry point on the holders, called by a stranger.
    function test_privilegedFunctionsRejectAStranger() public {
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);

        vm.expectRevert(denied);
        escrow.setWriteToken(address(write));
        vm.expectRevert(denied);
        escrow.fundAll();

        vm.expectRevert(denied);
        emis.setWriteToken(address(write));
        vm.expectRevert(denied);
        emis.setSink(alice);
        vm.expectRevert(denied);
        emis.setRate(1);

        vm.expectRevert(denied);
        teamVesting.setWriteToken(address(write));
        vm.expectRevert(denied);
        teamVesting.reallocateUnallocated(alice, 1);

        vm.expectRevert(denied);
        points.setWriteToken(address(write));
        vm.expectRevert(denied);
        points.setTreasury(alice);

        vm.stopPrank();
    }
}
