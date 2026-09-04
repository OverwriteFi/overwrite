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
/// deploy first knowing nothing about WRITE, WRITE's constructor mints to them while asserting each one's
/// declared `allocation()` (D-061), and only then does `setWriteToken` wire them back. On mainnet the five
/// `setWriteToken` calls go out as a single `TimelockController.scheduleBatch` before any WRITE can move.
/// Every call below must be made by `Params.owner`, which is also the owner of every deployed contract.
/// The launchpad pool is deliberately not touched here: seeding it is environment-specific, so
/// `escrow.setPool` / `escrow.fundAll` / `oracle.setPool` are the caller's next step.
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

    function deploy(Params memory p) internal returns (Deployment memory d) {
        // 1. The five holders. None of them knows the token yet.
        d.escrow = new LiquidityEscrow(p.owner);
        d.emissions = new EmissionsController(p.owner, p.emissionsDuration);
        d.treasuryVesting = new Vesting(p.owner, 200_000_000e18, false); // treasury: never revocable
        d.teamVesting = new Vesting(p.owner, 150_000_000e18, true); // team: revocable by the timelock
        d.points = new PointsDistributor(p.owner, p.treasury);

        // 2. The token. Its constructor mints the whole fixed supply into those five and asserts that each
        //    one declares exactly the allocation it is about to receive — which is what makes minting into an
        //    EOA impossible.
        d.write = new WRITE(
            WRITE.Holders({
                liquidity: address(d.escrow),
                emissions: address(d.emissions),
                treasuryVesting: address(d.treasuryVesting),
                teamVesting: address(d.teamVesting),
                points: address(d.points)
            })
        );

        // 3. Wire the token back into each holder (one `scheduleBatch` on mainnet).
        address write_ = address(d.write);
        d.escrow.setWriteToken(write_);
        d.emissions.setWriteToken(write_);
        d.treasuryVesting.setWriteToken(write_);
        d.teamVesting.setWriteToken(write_);
        d.points.setWriteToken(write_);

        // 4. The shared price oracle. The sanity band must exist before a pool can be attached (D-066).
        d.oracle = new WritePriceOracle(write_, p.usdg, p.usdgUsdFeed, p.owner);
        d.oracle.setSanityBand(p.sanityLow8, p.sanityHigh8);

        // 5. The safety module, whose constructor asserts both back-references, then the emissions sink.
        d.safetyModule = new SafetyModule(write_, address(d.emissions), address(d.oracle), p.owner);
        d.emissions.setSink(address(d.safetyModule));
    }
}
