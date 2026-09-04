// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenDeployLib} from "../script/TokenDeployLib.sol";
import {WRITE} from "../src/WRITE.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Vesting} from "../src/Vesting.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockLaunchpad} from "./mocks/MockLaunchpad.sol";

/// @dev Bare fixture for the pure-token suites (WRITE, both Vesting instances, PointsDistributor,
/// LiquidityEscrow, EmissionsController). They need no vault, auction or settlement state, so they do not pay
/// for `TokenBaseTest`'s full stack — but they still deploy through `TokenDeployLib`, so the wiring under test
/// is the wiring that ships.
abstract contract TokenUnitBaseTest is Test {
    MockUSDG internal usdg;
    MockAggregatorV3 internal usdgFeed;

    WRITE internal write;
    LiquidityEscrow internal escrow;
    EmissionsController internal emis;
    Vesting internal treasuryVesting;
    Vesting internal teamVesting;
    PointsDistributor internal points;
    WritePriceOracle internal wOracle;
    SafetyModule internal sm;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal teamMember = makeAddr("teamMember");

    uint256 internal constant START_TS = 1_788_344_808; // SPEC §0 reference timestamp
    uint64 internal constant EMISSIONS_DURATION = 4 * 365 days;
    uint256 internal constant SANITY_LOW_8 = 0.005e8;
    uint256 internal constant SANITY_HIGH_8 = 5.0e8;

    function setUp() public virtual {
        vm.warp(START_TS);
        usdg = new MockUSDG();
        usdgFeed = new MockAggregatorV3(8);
        usdgFeed.setRound(usdgFeed.roundId(1, uint64(block.timestamp)), 1e8, block.timestamp);

        vm.startPrank(admin);
        TokenDeployLib.Deployment memory d = TokenDeployLib.deploy(_params());
        vm.stopPrank();

        write = d.write;
        escrow = d.escrow;
        emis = d.emissions;
        treasuryVesting = d.treasuryVesting;
        teamVesting = d.teamVesting;
        points = d.points;
        wOracle = d.oracle;
        sm = d.safetyModule;

        vm.label(address(write), "WRITE");
        vm.label(address(escrow), "liquidityEscrow");
        vm.label(address(emis), "emissionsController");
        vm.label(address(treasuryVesting), "treasuryVesting");
        vm.label(address(teamVesting), "teamVesting");
        vm.label(address(points), "pointsDistributor");
    }

    function _params() internal view returns (TokenDeployLib.Params memory) {
        return TokenDeployLib.Params({
            owner: admin,
            treasury: treasury,
            usdg: address(usdg),
            usdgUsdFeed: address(usdgFeed),
            emissionsDuration: EMISSIONS_DURATION,
            sanityLow8: SANITY_LOW_8,
            sanityHigh8: SANITY_HIGH_8
        });
    }

    /// @dev Hands `to` WRITE out of the points bucket through a one-leaf round — the same path a real airdrop
    /// or bond grant takes. WRITE has no mint function, so this is the only way to fund an account.
    function _grantWrite(address to, uint256 amount, uint256 roundId) internal {
        bytes32 leaf = points.leafHash(roundId, 0, to, amount);
        vm.prank(admin);
        points.setRound(roundId, leaf, amount, uint64(block.timestamp), uint64(block.timestamp + 30 days));
        points.claim(roundId, 0, to, amount, new bytes32[](0));
    }
}
