// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployHarness} from "./DeployHarness.t.sol";

import {Config, DeployConfig} from "../script/Config.sol";
import {Deployment, Deployed} from "../script/Deployment.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {MockDeployLib} from "../script/MockDeployLib.sol";
import {VaultDeployLib} from "../script/VaultDeployLib.sol";

import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {RiskModule} from "../src/RiskModule.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20Like} from "./DeployHarness.t.sol";

/// @notice Runs the real deploy library end to end and asserts the wiring with the same `DeployChecks` the
/// script and the fork test use. This is what stops `script/Deploy.s.sol` from drifting away from the system
/// `test/SettlementBase.t.sol` exercises: the ordering, the batch contents and the assertions all have exactly
/// one definition, and this test executes them on every `forge test`.
contract DeployLibTest is DeployHarness {
    /// @notice The mainnet shape: the deployer, the admin EOA, both guardians, the keeper and the treasury are
    /// five distinct keys, so `assertDeployerPowerless` runs in full. Only `minDelay` is 0, because a test
    /// cannot wait 48 h and the delay changes nothing about the resulting wiring.
    function test_deployAndWire_deployerEndsPowerless() public {
        DeployConfig memory c = _config();
        Deployed memory d = _deploy(c);
        DeployChecks.assertAll(c, d);
        DeployChecks.report(c, d);

        // The deployer here is this test contract; it created everything and can touch none of it.
        assertEq(CoveredCallVault(d.vaults[0].vault).owner(), d.timelock, "vault owner");
        assertTrue(d.deployer != d.timelock, "deployer is not the timelock");
    }

    /// @notice The config as it actually ships: one key wearing every governance hat, which is the documented
    /// 46630 deviation. `assertAll` must still pass, and the deployer must still own nothing.
    function test_deployAndWire_testnetShapeStillPasses() public {
        DeployConfig memory c = Config.read(TESTNET);
        assertTrue(c.gov.deployerIsAdmin, "config/46630.json should declare the deviation");
        Deployed memory d = _deploy(c);
        DeployChecks.assertAll(c, d);
    }

    /// @notice Every vault the config asks for is created, wired and priced. The second vault is the pool
    /// orientation no other fixture builds: the stock is `token0`, which is the `OracleMath.quotePrice8`
    /// branch and the SPEC §9.3 depth inequality of D-052.
    function test_bothPoolOrientationsPriceCorrectly() public {
        DeployConfig memory c = _config();
        Deployed memory d = _deploy(c);
        assertEq(d.vaults.length, 2, "two vaults");

        SettlementOracle oracle = SettlementOracle(d.settlementOracle);
        for (uint256 i; i < d.vaults.length; ++i) {
            ISettlementOracle.VaultConfig memory vc = oracle.vaultConfig(d.vaults[i].vault);
            assertEq(vc.stockIsToken1, !c.vaults[i].mock.stockIsToken0, "orientation");

            (uint256 price8, bool ok) = oracle.capPrice(d.vaults[i].vault);
            assertTrue(ok, "cap price unavailable");
            // The achievable tick prices land a fraction of a basis point off the nominal target (D-096).
            assertApproxEqRel(price8, c.vaults[i].mock.price8, 1e14, "price at the seeded tick");
        }
        assertTrue(c.vaults[0].mock.stockIsToken0 != c.vaults[1].mock.stockIsToken0, "both orientations covered");
    }

    /// @notice A deposit works the moment the four stages are done: the cap is set, the price source is the
    /// real oracle, and nothing is paused. This is the end-to-end proof that the batch actually wired things,
    /// rather than that every getter happens to return what we expected.
    function test_vaultAcceptsADepositRightAfterTheHandover() public {
        DeployConfig memory c = _config();
        Deployed memory d = _deploy(c);
        CoveredCallVault vault = CoveredCallVault(d.vaults[0].vault);

        address alice = makeAddr("alice");
        // `mintStockFloat` mints once per vault, so the prank has to last for more than one call.
        vm.startPrank(c.gov.admin); // the mock tokens are owned by the governance EOA
        MockDeployLib.mintStockFloat(c, alice);
        vm.stopPrank();

        assertGt(vault.maxDeposit(alice), 0, "cap headroom");
        vm.startPrank(alice);
        IERC20Like(d.vaults[0].stock).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e18, alice);
        vm.stopPrank();
        assertGt(shares, 0, "shares minted");
        assertEq(vault.totalAssets(), 100e18, "assets in");
    }

    // ───────────────────────────── the batch is load-bearing ─────────────────────────────

    /// @notice `SettlementOracle.registerVault` asserts `auctionHouse.isVault(vault)`, so the batch cannot be
    /// reordered. Running only the prefix up to (but not including) `auctionHouse.registerVault` and then
    /// jumping to the oracle registration fails, which is the property that makes a single ordered batch the
    /// right shape for this deployment.
    function test_batchOrderIsLoadBearing() public {
        DeployConfig memory c = _config();
        (VaultDeployLib.Core memory k, address[] memory vaults, TimelockController t,) = _stage1(c);
        (address[] memory targets, bytes[] memory payloads) =
            VaultDeployLib.batchA(c, k, vaults, _emptyHolders(), address(0));

        uint256 oracleRegister =
            _indexOf(targets, payloads, address(k.settlement), SettlementOracle.registerVault.selector);
        assertGt(oracleRegister, 0, "oracle registration is in the batch");

        address[] memory one = new address[](1);
        bytes[] memory onePayload = new bytes[](1);
        uint256[] memory values = VaultDeployLib.values(1);
        one[0] = targets[oracleRegister];
        onePayload[0] = payloads[oracleRegister];
        bytes32 salt = keccak256("out-of-order");

        // Scheduling anything is always allowed; it is execution that has to fail.
        vm.prank(c.gov.admin);
        t.scheduleBatch(one, values, onePayload, bytes32(0), salt, 0);
        vm.prank(c.gov.admin);
        vm.expectRevert(); // Miswired("RISK_MODULE_ORACLE") -- nothing before it in the batch has run
        t.executeBatch(one, values, onePayload, bytes32(0), salt);
    }

    /// @notice `config/4663.json` ships with placeholder governance addresses on purpose, so a mainnet deploy
    /// cannot start before a human has filled in the Ledger EOA, the guardians, the treasury and the keeper.
    function test_mainnetConfigRefusesPlaceholderGovernance() public {
        DeployConfig memory c = Config.read(MAINNET);
        assertEq(c.gov.timelockMinDelay, 48 hours, "mainnet delay");
        assertFalse(c.gov.deployerIsAdmin, "mainnet has no deviation");
        vm.expectRevert(abi.encodeWithSelector(Config.MissingAddress.selector, "governance.admin"));
        this.validate(c);
    }

    /// @notice Audit C-1: the 48 h / four-key shape is refused by `validate`, not merely written in the runbook.
    function test_mainnetConfigRefusesWeakGovernance() public {
        DeployConfig memory c = _filledMainnet();
        this.validate(c); // the intended shape passes
        c.gov.timelockMinDelay = 48 hours - 1;
        vm.expectRevert(abi.encodeWithSelector(Config.MainnetGovernance.selector, "timelockMinDelay < 48h"));
        this.validate(c);
        c = _filledMainnet();
        c.gov.deployerIsAdmin = true;
        vm.expectRevert(abi.encodeWithSelector(Config.MainnetGovernance.selector, "deployerIsAdmin"));
        this.validate(c);
        c = _filledMainnet();
        c.gov.guardians = new address[](1);
        c.gov.guardians[0] = guardianHot;
        vm.expectRevert(abi.encodeWithSelector(Config.MainnetGovernance.selector, "guardians != 2"));
        this.validate(c);
        c = _filledMainnet();
        c.gov.keeper = guardianHot;
        vm.expectRevert(
            abi.encodeWithSelector(Config.MainnetGovernance.selector, "admin, keeper and guardians must be distinct")
        );
        this.validate(c);
    }

    function _filledMainnet() internal view returns (DeployConfig memory c) {
        c = Config.read(MAINNET);
        c.gov.admin = admin;
        c.gov.keeper = keeper;
        c.gov.treasury = treasury;
        c.gov.guardians = new address[](2);
        c.gov.guardians[0] = guardianHot;
        c.gov.guardians[1] = guardianCold;
    }

    /// @notice The mainnet config names real externals, so nothing on 4663 may be mocked.
    function test_mainnetConfigNamesRealExternals() public view {
        DeployConfig memory c = Config.read(MAINNET);
        assertEq(c.ext.usdg, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "USDG");
        assertEq(c.ext.usdgUsdFeed, 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2, "USDG/USD");
        assertEq(c.vaults[0].stock, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, "NVDA");
        assertEq(c.vaults[0].pool, 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3, "NVDA/USDG 0.05 %");
        assertEq(c.ext.sequencerFeed, address(0), "D-005: no uptime feed on this chain");
    }

    /// @notice The mainnet batch A is exactly the calls docs/RUNBOOK.md says a Ledger will be asked to
    /// schedule. The runbook quotes this number so the operator can sanity-check the device against it before
    /// blind-signing, so it has to be pinned: adding a vault or a guardian changes it, and the runbook with it.
    function test_mainnetBatchAIsTheSizeTheRunbookQuotes() public {
        DeployConfig memory c = Config.read(MAINNET);
        c.gov.admin = admin;
        c.gov.keeper = keeper;
        c.gov.treasury = treasury;
        c.gov.guardians = new address[](2);
        c.gov.guardians[0] = guardianHot;
        c.gov.guardians[1] = guardianCold;

        VaultDeployLib.Core memory k;
        k.riskModule = new RiskModule(admin); // batchA reads `defaultParams()` off it
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault");

        (address[] memory targets,) = VaultDeployLib.batchA(c, k, vaults, _emptyHolders(), makeAddr("write"));
        assertEq(targets.length, 19, "docs/RUNBOOK.md quotes 19 calls for the shipped 4663 config");

        // Without the token layer the five setWriteToken calls are not emitted.
        (address[] memory noToken,) = VaultDeployLib.batchA(c, k, vaults, _emptyHolders(), address(0));
        assertEq(noToken.length, 14, "vault layer alone");
    }

    // ───────────────────────────── the address book ─────────────────────────────

    /// @notice The address book round-trips, `mocked` included. That list is the record of which externals
    /// this chain had no deployment for, and `script/Deploy.s.sol` reads it back to reuse those mocks instead
    /// of deploying a second set, so a reader that silently dropped it would make a re-run believe the chain
    /// had never been mocked at all.
    function test_addressBookRoundTrips() public {
        Deployed memory d = _record(
            _config(), _emptyCore(), new address[](0), TimelockController(payable(admin)), _emptyHolders(), address(0)
        );
        d.chainId = ROUNDTRIP; // a chain id nothing else writes, so the file is ours to create and remove
        d.mocked = new string[](2);
        d.mocked[0] = "USDG";
        d.mocked[1] = "NVDA/USDG 0.05% pool";

        Deployment.write(d);
        Deployed memory back = Deployment.read(ROUNDTRIP);
        assertEq(back.mocked.length, 2, "mocked list length");
        assertEq(back.mocked[0], "USDG", "mocked[0]");
        assertEq(back.mocked[1], "NVDA/USDG 0.05% pool", "mocked[1]");
        assertEq(back.timelock, d.timelock, "timelock");
        assertEq(back.riskModule, d.riskModule, "riskModule");

        // The mainnet shape: nothing mocked, so the array is empty and must still read back cleanly.
        d.mocked = new string[](0);
        Deployment.write(d);
        assertEq(Deployment.read(ROUNDTRIP).mocked.length, 0, "empty mocked list");

        vm.removeFile(Deployment.path(ROUNDTRIP));
    }

    /// @dev External so `vm.expectRevert` sees the revert of the call rather than of the test body.
    function validate(DeployConfig memory c) external pure {
        Config.validate(c, false);
    }
}
