// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WRITE} from "../src/WRITE.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Vesting} from "../src/Vesting.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SafetyModule} from "../src/SafetyModule.sol";

/// @title TokenDeployLib
/// @notice The one description of how the WRITE token layer is deployed and wired. `script/DeployToken.s.sol`
/// and `test/TokenBase.t.sol` both call it, so the fixture cannot drift from the real deployment.
/// @dev Resolves the mint-into-contracts circularity with the house set-once idiom (D-060): the five holders
/// deploy first knowing nothing about WRITE, WRITE's constructor mints to them while checking each one's
/// declared `allocation()` (D-061), and only then does `setWriteToken` wire them back.
///
/// **Every contract is owned by the timelock from birth** (D-098). The deploy is split into four stages so
/// that the deployer key never holds a privilege at any point: it only calls `new`, and each wiring stage is a
/// `TimelockController.scheduleBatch` executed by governance. An earlier shape had the deployer own all seven
/// contracts until the timelock's `acceptOwnership` cleared a 48 h delay, which would have left one hot key
/// able to move 700 M WRITE and to misdirect the 300 M emissions stream irreversibly via `setSink`.
///
/// Stage ordering is forced by the constructor asserts (D-063): `SafetyModule` checks
/// `emissions.writeToken() == write`, so stage 3 cannot run until stage 2 has executed.
///
///   1. `deployHolders`  — deployer — five holders, owned by the timelock
///      `deployToken`    — deployer — WRITE mints the whole supply into them
///   2. `wireHolders`    — TIMELOCK batch — `setWriteToken` x5
///   3. `deployStaking`  — deployer — WritePriceOracle and SafetyModule, owned by the timelock
///   4. `wireStaking`    — TIMELOCK batch — `setSanityBand`, `setSink`
///
/// The launchpad pool is deliberately not touched here: seeding it is environment-specific, so
/// `escrow.setPool` / `escrow.fundAll` / `oracle.setPool` are governance's next steps.
library TokenDeployLib {
    struct Params {
        address owner; // the 48 h TimelockController (CLAUDE.md rule 5)
        address treasury;
        address usdg;
        address usdgUsdFeed;
        uint64 emissionsDuration; // 4 years at launch
        uint256 sanityLow8; // WRITE/USD validity band, 8 decimals (D-066)
        uint256 sanityHigh8;
    }

    struct Holders {
        LiquidityEscrow escrow;
        EmissionsController emissions;
        Vesting treasuryVesting;
        Vesting teamVesting;
        PointsDistributor points;
    }

    struct Deployment {
        WRITE write;
        LiquidityEscrow escrow;
        EmissionsController emissions;
        Vesting treasuryVesting;
        Vesting teamVesting;
        PointsDistributor points;
        WritePriceOracle oracle;
        SafetyModule safetyModule;
    }

    // ───────────────────────────── stage 1: deployer ─────────────────────────────

    function deployHolders(Params memory p) internal returns (Holders memory h) {
        h.escrow = new LiquidityEscrow(p.owner);
        h.emissions = new EmissionsController(p.owner, p.emissionsDuration);
        h.treasuryVesting = new Vesting(p.owner, 200_000_000e18, false); // treasury: never revocable
        h.teamVesting = new Vesting(p.owner, 150_000_000e18, true); // team: revocable by the timelock
        h.points = new PointsDistributor(p.owner, p.treasury);
    }

    /// @dev Mints the whole fixed supply into the five holders, checking that each declares exactly the
    /// allocation it is about to receive.
    function deployToken(Holders memory h) internal returns (WRITE write) {
        write = new WRITE(
            WRITE.Holders({
                liquidity: address(h.escrow),
                emissions: address(h.emissions),
                treasuryVesting: address(h.treasuryVesting),
                teamVesting: address(h.teamVesting),
                points: address(h.points)
            })
        );
    }

    // ───────────────────────────── stage 2: timelock batch ─────────────────────────────

    /// @dev Must be executed by `Params.owner`. On mainnet these five calls go out as one `scheduleBatch`.
    function wireHolders(Holders memory h, address write) internal {
        h.escrow.setWriteToken(write);
        h.emissions.setWriteToken(write);
        h.treasuryVesting.setWriteToken(write);
        h.teamVesting.setWriteToken(write);
        h.points.setWriteToken(write);
    }

    // ───────────────────────────── stage 3: deployer ─────────────────────────────

    /// @dev Requires stage 2: `SafetyModule`'s constructor asserts `emissions.writeToken() == write`.
    function deployStaking(Params memory p, Holders memory h, address write)
        internal
        returns (WritePriceOracle oracle, SafetyModule sm)
    {
        oracle = new WritePriceOracle(write, p.usdg, p.usdgUsdFeed, p.owner);
        sm = new SafetyModule(write, address(h.emissions), address(oracle), p.owner);
    }

    // ───────────────────────────── stage 4: timelock batch ─────────────────────────────

    /// @dev Must be executed by `Params.owner`. The sanity band must exist before a pool can be attached.
    function wireStaking(Params memory p, Holders memory h, WritePriceOracle oracle, SafetyModule sm) internal {
        oracle.setSanityBand(p.sanityLow8, p.sanityHigh8);
        h.emissions.setSink(address(sm));
    }

    // ───────────────────────────── all four, for tests ─────────────────────────────

    /// @notice Runs every stage in one call. Only usable where the caller *is* `Params.owner` — that is the
    /// test fixture, which pranks the timelock. The real deployment uses the stages, because there the
    /// deployer and the timelock are different keys and the deployer must never hold a privilege.
    function deploy(Params memory p) internal returns (Deployment memory d) {
        Holders memory h = deployHolders(p);
        d.write = deployToken(h);
        wireHolders(h, address(d.write));
        (d.oracle, d.safetyModule) = deployStaking(p, h, address(d.write));
        wireStaking(p, h, d.oracle, d.safetyModule);

        d.escrow = h.escrow;
        d.emissions = h.emissions;
        d.treasuryVesting = h.treasuryVesting;
        d.teamVesting = h.teamVesting;
        d.points = h.points;
    }
}
