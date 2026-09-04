// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {Config, DeployConfig} from "./Config.sol";
import {Deployment, Deployed, VaultRecord} from "./Deployment.sol";
import {DeployChecks} from "./DeployChecks.sol";
import {MockDeployLib} from "./MockDeployLib.sol";
import {VaultDeployLib} from "./VaultDeployLib.sol";
import {TokenDeployLib} from "./TokenDeployLib.sol";

import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {Vesting} from "../src/Vesting.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Deploy
/// @notice One command deploys the whole system, in the order `contracts/README.md` prescribes, through the
/// same `VaultDeployLib` / `TokenDeployLib` / `MockDeployLib` that `test/DeployLib.t.sol` and
/// `test/DeployFork.t.sol` call. Everything chain-specific comes from `config/<chainId>.json`.
///
/// @dev **The deployer key only ever calls `new`.** Every contract takes the `TimelockController` as its
/// `owner_`, so there is no ownership transfer and nothing to renounce; all the wiring is a timelock batch.
/// The four stages are:
///
///   1. `run()`        — deployer — mocks (where the config address is zero), the timelock, the seven core
///                       contracts, one vault per configured stock token, and the five WRITE holders + WRITE
///   2. BATCH A        — TIMELOCK — every wiring setter, plus `setWriteToken` x5
///   3. `runStage3()`  — deployer — WritePriceOracle and SafetyModule
///   4. BATCH B        — TIMELOCK — `setSanityBand`, `setSink`
///
/// Where `governance.timelockMinDelay` is 0 and the broadcaster is the admin EOA, `run()` schedules and
/// executes both batches itself and completes all four stages in one command. Where the delay is 48 h it stops
/// after stage 1 and prints the exact `scheduleBatch` / `executeBatch` calldata for a Ledger; `runStage3()`
/// does the same for batch B once batch A has executed. `docs/RUNBOOK.md` is the mainnet procedure.
///
/// **No private key is read here.** `vm.startBroadcast()` takes no argument, so the signer comes from the
/// command line and the same script works with `--ledger` and with `--private-key` (CLAUDE.md rule 1).
///
///   forge script script/Deploy.s.sol:Deploy --sig "run()" --rpc-url robinhood --broadcast --slow \
///     --libraries src/libraries/TickMath.sol:TickMath:0xTHE_DEPLOYED_ADDRESS --ledger
///
/// `TickMath` cannot be deployed here: an external library's address is resolved at compile time, so it must
/// exist before this script is compiled. `script/deploy.sh` deploys it, records it in the config and passes
/// `--libraries`; the run refuses to start if the config and the linked address disagree (D-058).
///
/// Nothing is held in contract storage: `DeployConfig` and `Deployed` both contain dynamically sized arrays,
/// which solc cannot copy from memory to storage, so the stages pass one `Built` struct between them instead.
contract Deploy is Script {
    /// @dev Deterministic, so a Ledger flow can be rehearsed and the queued operation id recomputed at will.
    bytes32 internal constant SALT_A = keccak256("overwrite.deploy.batchA");
    bytes32 internal constant SALT_B = keccak256("overwrite.deploy.batchB");

    struct Built {
        VaultDeployLib.Core core;
        TokenDeployLib.Holders holders;
        address[] vaults;
        string[] mocked;
        TimelockController timelock;
    }

    // ───────────────────────────── stages 1 and 2 ─────────────────────────────

    function run() external {
        (DeployConfig memory c, string[] memory carried) = _load();
        Deployed memory d = Deployment.fromConfig(c, msg.sender);
        Built memory b = _stage1(c, d, carried);

        _record(c, d, b);
        _writeRecord(d);

        (address[] memory targets, bytes[] memory payloads) =
            VaultDeployLib.batchA(c, b.core, b.vaults, b.holders, d.write);
        if (!_governanceIsUs(c, d.deployer)) {
            _printBatch("A", targets, payloads, SALT_A, c.gov.timelockMinDelay);
            console2.log("Wrote", Deployment.path(d.chainId));
            console2.log("After batch A executes, run: --sig 'runStage3()'");
            return;
        }
        _runBatch(b.timelock, c, targets, payloads, SALT_A);
        _stage3and4(c, d, b);
    }

    function _stage1(DeployConfig memory c, Deployed memory d, string[] memory carried)
        internal
        returns (Built memory b)
    {
        vm.startBroadcast();
        b.mocked = MockDeployLib.deployMissing(c);
        // Nothing left to deploy means a previous run already mocked these; the record must still say so.
        if (b.mocked.length == 0) b.mocked = carried;
        b.timelock = new TimelockController(c.gov.timelockMinDelay, _one(c.gov.admin), _one(c.gov.admin), address(0));
        b.core = VaultDeployLib.deployCore(c, address(b.timelock));
        b.vaults = VaultDeployLib.deployVaults(c, b.core, address(b.timelock));
        if (c.token.deploy) {
            b.holders = TokenDeployLib.deployHolders(_tokenParams(c, address(b.timelock)));
            d.write = address(TokenDeployLib.deployToken(b.holders));
        }
        // Testnet convenience only, and only where the deployer is also the mock tokens' owner.
        if (b.mocked.length != 0 && c.gov.admin == d.deployer) MockDeployLib.mintStockFloat(c, d.deployer);
        vm.stopBroadcast();
    }

    // ───────────────────────────── stages 3 and 4 ─────────────────────────────

    /// @notice For a chain with a real delay: run once batch A has executed. Reads back the address book
    /// stage 1 wrote, so it needs no arguments.
    function runStage3() external {
        (DeployConfig memory c,) = _load();
        Deployed memory d = Deployment.read(c.chainId);
        require(d.write != address(0), "token layer is not part of this deployment");
        require(EmissionsController(d.emissionsController).writeToken() == d.write, "batch A has not executed");

        Built memory b;
        b.timelock = TimelockController(payable(d.timelock));
        b.holders = TokenDeployLib.Holders({
            escrow: LiquidityEscrow(d.liquidityEscrow),
            emissions: EmissionsController(d.emissionsController),
            treasuryVesting: Vesting(d.treasuryVesting),
            teamVesting: Vesting(d.teamVesting),
            points: PointsDistributor(d.pointsDistributor)
        });
        _stage3and4(c, d, b);
    }

    function _stage3and4(DeployConfig memory c, Deployed memory d, Built memory b) internal {
        vm.startBroadcast();
        (WritePriceOracle wo, SafetyModule sm) =
            TokenDeployLib.deployStaking(_tokenParams(c, address(b.timelock)), b.holders, d.write);
        vm.stopBroadcast();

        d.writePriceOracle = address(wo);
        d.safetyModule = address(sm);
        _writeRecord(d);

        (address[] memory targets, bytes[] memory payloads) =
            VaultDeployLib.batchB(c, address(wo), d.emissionsController, address(sm));
        if (!_governanceIsUs(c, d.deployer)) {
            _printBatch("B", targets, payloads, SALT_B, c.gov.timelockMinDelay);
            console2.log("Wrote", Deployment.path(d.chainId));
            console2.log("After batch B executes, verify the whole system with:");
            console2.log("  forge script script/Verify.s.sol:Verify --sig 'run()' --rpc-url <alias>");
            return;
        }
        _runBatch(b.timelock, c, targets, payloads, SALT_B);

        DeployChecks.assertAll(c, d);
        DeployChecks.report(c, d);
        console2.log("");
        if (_writesAllowed()) console2.log("Wrote", Deployment.path(d.chainId));
    }

    // ───────────────────────────── timelock ─────────────────────────────

    /// @notice True when this run can drive governance itself: the delay is zero and the broadcaster is the
    /// admin EOA that holds PROPOSER and EXECUTOR. On 4663 both halves are false by construction.
    function _governanceIsUs(DeployConfig memory c, address deployer) internal pure returns (bool) {
        return c.gov.timelockMinDelay == 0 && c.gov.admin == deployer;
    }

    function _runBatch(
        TimelockController t,
        DeployConfig memory c,
        address[] memory targets,
        bytes[] memory payloads,
        bytes32 salt
    ) internal {
        uint256[] memory values = VaultDeployLib.values(targets.length);
        vm.startBroadcast();
        t.scheduleBatch(targets, values, payloads, bytes32(0), salt, c.gov.timelockMinDelay);
        t.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();
    }

    /// @dev Prints the batch as a numbered list of (target, calldata) plus the two encoded governance calls.
    /// A Ledger signs `scheduleBatch` blind, so this list is what a human reconciles the device against.
    function _printBatch(
        string memory name,
        address[] memory targets,
        bytes[] memory payloads,
        bytes32 salt,
        uint256 delay
    ) internal pure {
        uint256[] memory values = VaultDeployLib.values(targets.length);
        console2.log("");
        console2.log("=== TIMELOCK BATCH", name, "===============================================");
        console2.log("  calls:", targets.length);
        for (uint256 i; i < targets.length; ++i) {
            console2.log("  --", i, targets[i]);
            console2.logBytes(payloads[i]);
        }
        console2.log("");
        console2.log("  scheduleBatch calldata:");
        console2.logBytes(
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, delay))
        );
        console2.log("");
        console2.log("  executeBatch calldata (after the delay):");
        console2.logBytes(
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), salt))
        );
        console2.log("============================================================================");
    }

    // ───────────────────────────── config and records ─────────────────────────────

    /// @return c the chain's config, with any mock this chain already deployed filled in
    /// @return carried what a previous deployment of this chain recorded as mocked, so a re-run that reuses
    /// those mocks still reports them as mocks rather than as real externals
    function _load() internal view returns (DeployConfig memory c, string[] memory carried) {
        c = Config.read(block.chainid);
        require(c.chainId == block.chainid, "config: chainId does not match the RPC");
        // Decided from the untouched config, before any address is filled in below.
        bool mocked = _anyMocked(c);
        Config.validate(c, mocked);
        require(c.tickMath != address(0), "tickMath: not deployed -- use script/deploy.sh, not forge directly");
        require(address(TickMath) == c.tickMath, "tickMath: --libraries does not match config.tickMath");
        if (mocked) carried = _reuseMocks(c);
    }

    /// @dev A chain may mock exactly what it has no deployment for, and the config says which that is by
    /// leaving the address zero. On 4663 nothing is zero, so nothing may be mocked.
    function _anyMocked(DeployConfig memory c) internal pure returns (bool) {
        if (c.ext.usdg == address(0) || c.ext.usdgUsdFeed == address(0)) return true;
        for (uint256 i; i < c.vaults.length; ++i) {
            if (c.vaults[i].stock == address(0) || c.vaults[i].feed == address(0)) return true;
            if (c.vaults[i].pool == address(0)) return true;
        }
        return false;
    }

    /// @notice Fills the config's zero addresses from a previous deployment of this chain, so a re-run reuses
    /// the mocks it already deployed instead of deploying a second set.
    /// @dev The address book is the source, not the config: `vm.writeJson` cannot address an array element,
    /// so writing the mocks back into `config/<chainId>.json` is not possible without corrupting it (see
    /// `Deployment`). Matching is by symbol rather than by position, so reordering `vaults` in the config can
    /// never silently point a vault at the wrong stock token. To force a fresh set of mocks, delete
    /// `deployments/<chainId>.json`.
    function _reuseMocks(DeployConfig memory c) internal view returns (string[] memory carried) {
        if (!vm.isFile(Deployment.path(c.chainId))) return carried;
        Deployed memory prev = Deployment.read(c.chainId);
        if (prev.chainId != c.chainId) return carried;
        carried = prev.mocked;

        if (c.ext.usdg == address(0)) c.ext.usdg = prev.usdg;
        if (c.ext.usdgUsdFeed == address(0)) c.ext.usdgUsdFeed = prev.usdgUsdFeed;
        for (uint256 i; i < c.vaults.length; ++i) {
            for (uint256 j; j < prev.vaults.length; ++j) {
                if (keccak256(bytes(c.vaults[i].symbol)) != keccak256(bytes(prev.vaults[j].symbol))) continue;
                if (c.vaults[i].stock == address(0)) c.vaults[i].stock = prev.vaults[j].stock;
                if (c.vaults[i].feed == address(0)) c.vaults[i].feed = prev.vaults[j].feed;
                if (c.vaults[i].pool == address(0)) c.vaults[i].pool = prev.vaults[j].pool;
                break;
            }
        }
    }

    /// @dev A dry run must leave `config/` and `deployments/` alone. The addresses a simulation produces
    /// exist only inside it, and recording them would make the next real run link against, and claim to have
    /// deployed, contracts that were never sent.
    function _writesAllowed() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function _writeRecord(Deployed memory d) internal {
        if (!_writesAllowed()) {
            console2.log("dry run: not writing", Deployment.path(d.chainId));
            return;
        }
        Deployment.write(d);
    }

    function _record(DeployConfig memory c, Deployed memory d, Built memory b) internal pure {
        d.timelock = address(b.timelock);
        d.usdg = c.ext.usdg;
        d.usdgUsdFeed = c.ext.usdgUsdFeed;
        d.riskModule = address(b.core.riskModule);
        d.optionToken = address(b.core.optionToken);
        d.bondManager = address(b.core.bondManager);
        d.feeRouter = address(b.core.feeRouter);
        d.auctionHouse = address(b.core.auctionHouse);
        d.capController = address(b.core.capController);
        d.settlementOracle = address(b.core.settlement);
        d.mocked = b.mocked;
        if (c.token.deploy) {
            d.liquidityEscrow = address(b.holders.escrow);
            d.emissionsController = address(b.holders.emissions);
            d.treasuryVesting = address(b.holders.treasuryVesting);
            d.teamVesting = address(b.holders.teamVesting);
            d.pointsDistributor = address(b.holders.points);
        }
        d.vaults = new VaultRecord[](b.vaults.length);
        for (uint256 i; i < b.vaults.length; ++i) {
            d.vaults[i] = VaultRecord({
                symbol: c.vaults[i].symbol,
                vault: b.vaults[i],
                stock: c.vaults[i].stock,
                feed: c.vaults[i].feed,
                pool: c.vaults[i].pool
            });
        }
    }

    function _tokenParams(DeployConfig memory c, address owner) internal pure returns (TokenDeployLib.Params memory) {
        return TokenDeployLib.Params({
            owner: owner,
            treasury: c.gov.treasury,
            usdg: c.ext.usdg,
            usdgUsdFeed: c.ext.usdgUsdFeed,
            emissionsDuration: c.token.emissionsDuration,
            sanityLow8: c.token.sanityLow8,
            sanityHigh8: c.token.sanityHigh8
        });
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }
}
