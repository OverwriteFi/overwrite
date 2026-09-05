// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {TokenDeployLib} from "./TokenDeployLib.sol";
import {WRITE} from "../src/WRITE.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DeployToken
/// @notice Deploys the WRITE token layer. Uses the same `TokenDeployLib` as `test/TokenBase.t.sol`, so what
/// ships is what the tests exercise.
/// @dev Two entry points, because the wiring between them belongs to the timelock (D-098). **The deployer key
/// never owns anything**: every contract is constructed with the timelock as owner, so the deployer only ever
/// calls `new`. Each entry point prints the `scheduleBatch` targets and calldata that governance executes next.
///
///   forge script script/DeployToken.s.sol:DeployToken --sig "run()" \
///     --rpc-url robinhood --broadcast \
///     --libraries src/libraries/TickMath.sol:TickMath:0xTHE_DEPLOYED_ADDRESS
///
/// `TickMath` must already be deployed and linked — `WritePriceOracle` carries a link placeholder and its
/// constructor reverts `Miswired("TICK_MATH")` if the address is missing or wrong (D-058).
///
/// After batch 1 executes, run the second entry point with the addresses printed by the first:
///
///   forge script script/DeployToken.s.sol:DeployToken \
///     --sig "runStaking(address,address)" <WRITE> <EmissionsController> \
///     --rpc-url robinhood --broadcast --libraries ...
///
/// Environment-specific and therefore manual, after batch 2: `escrow.setPool(launchpad)` + `escrow.fundAll()`,
/// seeding the WRITE/USDG pool and raising its observation cardinality, `oracle.setPool(...)`, and
/// `oracle.setSequencerFeed(...)`. Then, when governance chooses: the treasury and team vesting schedules,
/// `CapController.setSafetyModule` + `setCapWeightBps` + `setCapMode(SAFETY_MODULE)`, the FeeRouter WRITE mode,
/// and the four-call BondManager migration.
contract DeployToken is Script {
    /// @dev `TIMELOCK_ADDRESS` must be the 48 h timelock, not any address that happens to be in the env (audit C-5):
    /// every token-layer contract and 700 M WRITE would otherwise be owned by an undelayed key with the script's own
    /// ownership asserts passing.
    function _timelock() internal view returns (address t) {
        t = vm.envAddress("TIMELOCK_ADDRESS");
        require(t.code.length != 0, "TIMELOCK_ADDRESS has no code");
        require(TimelockController(payable(t)).getMinDelay() >= 48 hours, "TIMELOCK_ADDRESS is not the 48 h timelock");
    }

    function _params() internal view returns (TokenDeployLib.Params memory) {
        return TokenDeployLib.Params({
            owner: _timelock(),
            treasury: vm.envAddress("TREASURY_ADDRESS"),
            usdg: vm.envAddress("USDG_ADDRESS"),
            usdgUsdFeed: vm.envAddress("USDG_USD_FEED"),
            emissionsDuration: 4 * 365 days,
            sanityLow8: vm.envOr("WRITE_SANITY_LOW_8", uint256(0.005e8)),
            sanityHigh8: vm.envOr("WRITE_SANITY_HIGH_8", uint256(5.0e8))
        });
    }

    /// @notice Stage 1: the five holders and the token. Nothing is wired, and the deployer owns nothing.
    function run() external returns (TokenDeployLib.Holders memory h, WRITE write) {
        TokenDeployLib.Params memory p = _params();

        vm.startBroadcast();
        h = TokenDeployLib.deployHolders(p);
        write = TokenDeployLib.deployToken(h);
        vm.stopBroadcast();

        _assertMinted(h, write);
        _assertOwnedBy(p.owner, h);

        console2.log("WRITE               ", address(write));
        console2.log("LiquidityEscrow     ", address(h.escrow));
        console2.log("EmissionsController ", address(h.emissions));
        console2.log("Vesting (treasury)  ", address(h.treasuryVesting));
        console2.log("Vesting (team)      ", address(h.teamVesting));
        console2.log("PointsDistributor   ", address(h.points));
        console2.log("");
        console2.log("TIMELOCK BATCH 1 -- scheduleBatch these five, then re-run with runStaking:");
        _logCall(address(h.escrow), abi.encodeCall(h.escrow.setWriteToken, (address(write))));
        _logCall(address(h.emissions), abi.encodeCall(h.emissions.setWriteToken, (address(write))));
        _logCall(address(h.treasuryVesting), abi.encodeCall(h.treasuryVesting.setWriteToken, (address(write))));
        _logCall(address(h.teamVesting), abi.encodeCall(h.teamVesting.setWriteToken, (address(write))));
        _logCall(address(h.points), abi.encodeCall(h.points.setWriteToken, (address(write))));
    }

    /// @notice Stage 3: the oracle and the safety module. Requires batch 1 to have executed.
    function runStaking(address write, address emissions) external returns (WritePriceOracle oracle, SafetyModule sm) {
        TokenDeployLib.Params memory p = _params();
        require(EmissionsController(emissions).writeToken() == write, "batch 1 has not executed");

        TokenDeployLib.Holders memory h;
        h.emissions = EmissionsController(emissions);

        vm.startBroadcast();
        (oracle, sm) = TokenDeployLib.deployStaking(p, h, write);
        vm.stopBroadcast();

        require(Ownable(address(oracle)).owner() == p.owner, "oracle owner");
        require(Ownable(address(sm)).owner() == p.owner, "module owner");
        require(sm.emissions() == emissions && sm.writeToken() == write, "module wiring");

        console2.log("WritePriceOracle    ", address(oracle));
        console2.log("SafetyModule        ", address(sm));
        console2.log("");
        console2.log("TIMELOCK BATCH 2 -- scheduleBatch these two:");
        _logCall(address(oracle), abi.encodeCall(oracle.setSanityBand, (p.sanityLow8, p.sanityHigh8)));
        _logCall(emissions, abi.encodeCall(EmissionsController.setSink, (address(sm))));
        console2.log("");
        console2.log("Then, manually: escrow.setPool + fundAll; seed the pool; oracle.setPool;");
        console2.log("oracle.setSequencerFeed; the two vesting schedules; the CapController switch.");
    }

    // ───────────────────────────── asserts ─────────────────────────────

    /// @dev Fails the deployment rather than leaving a mis-minted token layer on chain (D-049).
    function _assertMinted(TokenDeployLib.Holders memory h, WRITE write) internal view {
        require(write.totalSupply() == write.MAX_SUPPLY(), "supply");
        require(write.balanceOf(address(h.escrow)) == h.escrow.allocation(), "escrow funded");
        require(write.balanceOf(address(h.emissions)) == h.emissions.allocation(), "emissions funded");
        require(write.balanceOf(address(h.treasuryVesting)) == h.treasuryVesting.allocation(), "treasury funded");
        require(write.balanceOf(address(h.teamVesting)) == h.teamVesting.allocation(), "team funded");
        require(write.balanceOf(address(h.points)) == h.points.allocation(), "points funded");
        require(!h.treasuryVesting.allowRevocable(), "treasury must be irrevocable");
        require(h.teamVesting.allowRevocable(), "team must be revocable");
    }

    /// @dev The point of the staged deploy: the deployer must hold no privilege over anything it just created.
    function _assertOwnedBy(address timelock, TokenDeployLib.Holders memory h) internal view {
        require(Ownable(address(h.escrow)).owner() == timelock, "escrow owner");
        require(Ownable(address(h.emissions)).owner() == timelock, "emissions owner");
        require(Ownable(address(h.treasuryVesting)).owner() == timelock, "treasury owner");
        require(Ownable(address(h.teamVesting)).owner() == timelock, "team owner");
        require(Ownable(address(h.points)).owner() == timelock, "points owner");
    }

    function _logCall(address target, bytes memory data) internal pure {
        console2.log("  target", target);
        console2.logBytes(data);
    }
}
