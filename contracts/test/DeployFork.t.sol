// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployHarness} from "./DeployHarness.t.sol";

import {Config, DeployConfig} from "../script/Config.sol";
import {Deployed} from "../script/Deployment.sol";
import {DeployChecks} from "../script/DeployChecks.sol";

/// @notice Runs the deploy library against a **fork of a real chain** and asserts the same wiring the local
/// `DeployLibTest` asserts, through the same `DeployChecks`. That is the point: `script/Deploy.s.sol` cannot
/// drift from the fixture, because both are the same library and both are checked by the same assertions,
/// once in a clean EVM and once against live chain state.
///
/// @dev Which chain is forked comes from `DEPLOY_FORK_RPC_URL`, and the config is picked by the fork's own
/// chain id, so the same test covers both chains:
///
///   forge test --match-path test/DeployFork.t.sol -vv \
///     DEPLOY_FORK_RPC_URL=<an RPC for 4663 or 46630>
///
/// Against **46630** it runs today and exercises the mock path end to end on live chain state (real block
/// numbers, real timestamps, real gas), which a clean-EVM test cannot.
///
/// Against **4663** it is the real integration test SPEC §1.8 calls the primary test path: the config names
/// no mocks, so the deploy runs against the actual USDG, the actual NVDA stock token, the actual Chainlink
/// feed and the actual Uniswap v3 0.05 % pool, and `SettlementOracle.registerVault` probes the real feed's
/// earliest round (D-057). `ROBINHOOD_RPC_URL` is empty in `.env` today, so that half is waiting on an
/// archive-capable mainnet RPC rather than on any code here. On 4663 the config also still carries placeholder
/// governance addresses, so the test substitutes its own (`_config`) exactly as it does on 46630 — what is
/// being verified is the wiring against real externals, not the key custody.
///
/// With no `DEPLOY_FORK_RPC_URL` set the test skips cleanly, so `forge test` stays green on a machine with no
/// RPC configured. A skip is visible in the run summary; it is never a silent pass.
contract DeployForkTest is DeployHarness {
    bool internal skipped;

    function setUp() public override {
        string memory url = vm.envOr("DEPLOY_FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            skipped = true;
            return;
        }
        vm.createSelectFork(url);
        // Deliberately no `vm.warp`: the fork's own timestamp is the point, and `MockDeployLib` seeds its
        // history backwards from it.
    }

    /// @notice The whole system, deployed and wired against the fork, then checked assertion for assertion.
    function test_forkDeployMatchesTheFixture() public {
        if (skipped) {
            vm.skip(true);
            return;
        }
        DeployConfig memory c = _config();
        assertEq(c.chainId, block.chainid, "config/<chainid>.json does not match the forked chain");

        Deployed memory d = _deploy(c);
        DeployChecks.assertAll(c, d);
        DeployChecks.report(c, d);
    }

    /// @dev The fork's chain id chooses the config, so 4663 reads the real addresses and 46630 the mocked
    /// ones. Governance is overridden to five distinct keys for the same reason as in `DeployLibTest`: it is
    /// the strict shape, under which `assertDeployerPowerless` runs in full.
    function _config() internal view override returns (DeployConfig memory c) {
        c = Config.read(block.chainid);
        c.gov.admin = admin;
        c.gov.guardians = new address[](2);
        c.gov.guardians[0] = guardianHot;
        c.gov.guardians[1] = guardianCold;
        c.gov.keeper = keeper;
        c.gov.treasury = treasury;
        c.gov.deployerIsAdmin = false;
        c.gov.timelockMinDelay = 0; // a test cannot wait 48 h; the delay does not change the wiring
    }
}
