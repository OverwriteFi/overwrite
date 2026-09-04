// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {TokenDeployLib} from "./TokenDeployLib.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title DeployToken
/// @notice Deploys the WRITE token layer and hands it to the timelock. Uses the same `TokenDeployLib` as
/// `test/TokenBase.t.sol`, so what ships is what the tests exercise.
/// @dev Run after the vault layer exists (README deployment order). `TickMath` must already be deployed and
/// linked — `WritePriceOracle` carries a link placeholder and its constructor reverts `Miswired("TICK_MATH")`
/// if the address is missing or wrong (D-058):
///
///   forge script script/DeployToken.s.sol:DeployToken \
///     --rpc-url robinhood --broadcast \
///     --libraries src/libraries/TickMath.sol:TickMath:0xTHE_DEPLOYED_ADDRESS
///
/// The deployer owns everything during wiring and then transfers ownership to the timelock; the timelock must
/// call `acceptOwnership()` on each contract to complete the handover (Ownable2Step). Three steps stay
/// manual because they depend on the launch venue, and they are listed at the end of the run:
///   1. `escrow.setPool(launchpad)` then `escrow.fundAll()`
///   2. seed the WRITE/USDG pool and `pool.increaseObservationCardinalityNext(65535)`
///   3. `oracle.setPool(writeUsdgPool)`
/// Then, when governance chooses: `cap.setSafetyModule` + `setCapWeightBps` + `setCapMode(SAFETY_MODULE)`,
/// `fr.setWriteToken` + `setPriceOracle` + `setCurator`, and the BondManager migration.
contract DeployToken is Script {
    function run() external returns (TokenDeployLib.Deployment memory d) {
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address usdg = vm.envAddress("USDG_ADDRESS");
        address usdgUsdFeed = vm.envAddress("USDG_USD_FEED");
        uint256 sanityLow8 = vm.envOr("WRITE_SANITY_LOW_8", uint256(0.005e8));
        uint256 sanityHigh8 = vm.envOr("WRITE_SANITY_HIGH_8", uint256(5.0e8));

        vm.startBroadcast();
        address deployer = msg.sender;

        d = TokenDeployLib.deploy(
            TokenDeployLib.Params({
                owner: deployer, // wiring needs a signer; ownership moves to the timelock below
                treasury: treasury,
                usdg: usdg,
                usdgUsdFeed: usdgUsdFeed,
                emissionsDuration: 4 * 365 days,
                sanityLow8: sanityLow8,
                sanityHigh8: sanityHigh8
            })
        );

        _assertWiring(d);

        Ownable2Step(address(d.escrow)).transferOwnership(timelock);
        Ownable2Step(address(d.emissions)).transferOwnership(timelock);
        Ownable2Step(address(d.treasuryVesting)).transferOwnership(timelock);
        Ownable2Step(address(d.teamVesting)).transferOwnership(timelock);
        Ownable2Step(address(d.points)).transferOwnership(timelock);
        Ownable2Step(address(d.oracle)).transferOwnership(timelock);
        Ownable2Step(address(d.safetyModule)).transferOwnership(timelock);

        vm.stopBroadcast();

        _report(d, timelock);
    }

    /// @dev Fails the deployment rather than leaving a half-wired token layer on chain (D-049).
    function _assertWiring(TokenDeployLib.Deployment memory d) internal view {
        require(d.write.totalSupply() == d.write.MAX_SUPPLY(), "supply");
        require(d.write.balanceOf(address(d.escrow)) == d.escrow.allocation(), "escrow funded");
        require(d.write.balanceOf(address(d.emissions)) == d.emissions.allocation(), "emissions funded");
        require(d.write.balanceOf(address(d.treasuryVesting)) == d.treasuryVesting.allocation(), "treasury funded");
        require(d.write.balanceOf(address(d.teamVesting)) == d.teamVesting.allocation(), "team funded");
        require(d.write.balanceOf(address(d.points)) == d.points.allocation(), "points funded");

        require(d.escrow.writeToken() == address(d.write), "escrow wired");
        require(d.emissions.writeToken() == address(d.write), "emissions wired");
        require(d.treasuryVesting.writeToken() == address(d.write), "treasury wired");
        require(d.teamVesting.writeToken() == address(d.write), "team wired");
        require(d.points.writeToken() == address(d.write), "points wired");

        require(!d.treasuryVesting.allowRevocable(), "treasury must be irrevocable");
        require(d.teamVesting.allowRevocable(), "team must be revocable");

        require(d.emissions.sink() == address(d.safetyModule), "emissions sink");
        require(d.safetyModule.emissions() == address(d.emissions), "module emissions");
        require(d.safetyModule.writeToken() == address(d.write), "module token");
        require(address(d.safetyModule.oracle()) == address(d.oracle), "module oracle");
        require(d.oracle.writeToken() == address(d.write), "oracle token");
        require(d.oracle.sanityHigh8() != 0, "sanity band");
    }

    function _report(TokenDeployLib.Deployment memory d, address timelock) internal pure {
        console2.log("WRITE               ", address(d.write));
        console2.log("LiquidityEscrow     ", address(d.escrow));
        console2.log("EmissionsController ", address(d.emissions));
        console2.log("Vesting (treasury)  ", address(d.treasuryVesting));
        console2.log("Vesting (team)      ", address(d.teamVesting));
        console2.log("PointsDistributor   ", address(d.points));
        console2.log("WritePriceOracle    ", address(d.oracle));
        console2.log("SafetyModule        ", address(d.safetyModule));
        console2.log("");
        console2.log("Next, from the timelock:");
        console2.log(" 1. acceptOwnership() on all seven contracts", timelock);
        console2.log(" 2. escrow.setPool(launchpad); escrow.fundAll()");
        console2.log(" 3. seed the WRITE/USDG pool; increaseObservationCardinalityNext(65535)");
        console2.log(" 4. oracle.setPool(writeUsdgPool)");
        console2.log(" 5. cap.setSafetyModule + setCapWeightBps + setCapMode(SAFETY_MODULE)");
        console2.log(" 6. fr.setWriteToken + setPriceOracle + setCurator + setFeeMode");
        console2.log(" 7. bm.setWriteToken + setRequiredAmountFor x2 + startMigration");
    }
}
