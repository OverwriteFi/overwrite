// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Config, DeployConfig} from "../script/Config.sol";
import {Deployed, VaultRecord} from "../script/Deployment.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {MockDeployLib} from "../script/MockDeployLib.sol";
import {VaultDeployLib} from "../script/VaultDeployLib.sol";
import {TokenDeployLib} from "../script/TokenDeployLib.sol";

import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {RiskModule} from "../src/RiskModule.sol";
import {CapController} from "../src/CapController.sol";
import {AuctionHouse} from "../src/AuctionHouse.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice The shared harness for the deploy-layer tests: it runs `MockDeployLib`, `VaultDeployLib` and
/// `TokenDeployLib` through all four stages and executes both timelock batches through a real
/// `TimelockController`, exactly as `script/Deploy.s.sol` does.
///
/// @dev It lives in its own fixture because two suites need it: `DeployLib.t.sol`, which runs it locally on
/// every `forge test`, and `DeployFork.t.sol`, which runs the same code against a forked chain. Duplicating it
/// would reintroduce the drift the deploy layer exists to prevent.
///
/// The batches are executed through the timelock rather than by pranking the owner, because that is what
/// happens on chain: `bondManager.setAuctionHouse` and friends see the timelock as `msg.sender`, and
/// `executeBatch` runs the calls in array order, so a mis-ordered batch fails here for the same reason it
/// would fail on mainnet.
abstract contract DeployHarness is Test {
    /// @dev SPEC §0 reference timestamp, matching the other fixtures. The mocks seed two days of history, so
    /// the clock cannot start at 1.
    uint256 internal constant START_TS = 1_788_344_808;
    uint256 internal constant TESTNET = 46_630;
    uint256 internal constant MAINNET = 4663;
    /// @dev A chain id nothing deploys to, used by the address-book round-trip test for a scratch file.
    uint256 internal constant ROUNDTRIP = 31_337;

    address internal admin = makeAddr("adminEOA");
    address internal guardianHot = makeAddr("guardianHot");
    address internal guardianCold = makeAddr("guardianCold");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");

    function setUp() public virtual {
        vm.warp(START_TS);
    }

    // ───────────────────────────── the whole system ─────────────────────────────
    // ───────────────────────────── harness ─────────────────────────────

    /// @dev The 46630 config with governance split across five distinct keys, which is the mainnet shape.
    function _config() internal view virtual returns (DeployConfig memory c) {
        c = Config.read(TESTNET);
        c.gov.admin = admin;
        c.gov.guardians = new address[](2);
        c.gov.guardians[0] = guardianHot;
        c.gov.guardians[1] = guardianCold;
        c.gov.keeper = keeper;
        c.gov.treasury = treasury;
        c.gov.deployerIsAdmin = false;
    }

    /// @dev Split across three helpers only because holding every stage's locals at once is stack-too-deep
    /// with `via_ir` off.
    function _deploy(DeployConfig memory c) internal returns (Deployed memory d) {
        (VaultDeployLib.Core memory k, address[] memory vaults, TimelockController t, string[] memory mocked) =
            _stage1(c);
        TokenDeployLib.Holders memory h = TokenDeployLib.deployHolders(_tokenParams(c, address(t)));
        address write = address(TokenDeployLib.deployToken(h));

        _batchA(c, k, vaults, t, h, write);
        d = _record(c, k, vaults, t, h, write);
        d.mocked = mocked;
        _stage3and4(c, t, h, write, d);
    }

    function _batchA(
        DeployConfig memory c,
        VaultDeployLib.Core memory k,
        address[] memory vaults,
        TimelockController t,
        TokenDeployLib.Holders memory h,
        address write
    ) internal {
        (address[] memory targets, bytes[] memory payloads) = VaultDeployLib.batchA(c, k, vaults, h, write);
        _execute(t, c.gov.admin, targets, payloads, keccak256("overwrite.deploy.batchA"));
    }

    function _stage3and4(
        DeployConfig memory c,
        TimelockController t,
        TokenDeployLib.Holders memory h,
        address write,
        Deployed memory d
    ) internal {
        (WritePriceOracle wo, SafetyModule sm) = TokenDeployLib.deployStaking(_tokenParams(c, address(t)), h, write);
        (address[] memory targets, bytes[] memory payloads) =
            VaultDeployLib.batchB(c, address(wo), address(h.emissions), address(sm));
        _execute(t, c.gov.admin, targets, payloads, keccak256("overwrite.deploy.batchB"));
        d.writePriceOracle = address(wo);
        d.safetyModule = address(sm);
    }

    function _stage1(DeployConfig memory c)
        internal
        returns (VaultDeployLib.Core memory k, address[] memory vaults, TimelockController t, string[] memory mocked)
    {
        mocked = MockDeployLib.deployMissing(c);
        address[] memory one = new address[](1);
        one[0] = c.gov.admin;
        // minDelay 0: a test cannot wait 48 h, and the delay does not change the resulting wiring.
        t = new TimelockController(0, one, one, address(0));
        k = VaultDeployLib.deployCore(c, address(t));
        vaults = VaultDeployLib.deployVaults(c, k, address(t));
    }

    function _execute(
        TimelockController t,
        address proposer,
        address[] memory targets,
        bytes[] memory payloads,
        bytes32 salt
    ) internal {
        uint256[] memory values = VaultDeployLib.values(targets.length);
        vm.prank(proposer);
        t.scheduleBatch(targets, values, payloads, bytes32(0), salt, 0);
        vm.prank(proposer);
        t.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _record(
        DeployConfig memory c,
        VaultDeployLib.Core memory k,
        address[] memory vaults,
        TimelockController t,
        TokenDeployLib.Holders memory h,
        address write
    ) internal view returns (Deployed memory d) {
        d.chainId = c.chainId;
        d.label = c.label;
        d.deployedAt = block.timestamp;
        d.deployer = address(this);
        d.timelock = address(t);
        d.tickMath = address(TickMath); // the address forge deployed and linked for this run
        d.usdg = c.ext.usdg;
        d.usdgUsdFeed = c.ext.usdgUsdFeed;
        d.riskModule = address(k.riskModule);
        d.optionToken = address(k.optionToken);
        d.bondManager = address(k.bondManager);
        d.feeRouter = address(k.feeRouter);
        d.auctionHouse = address(k.auctionHouse);
        d.capController = address(k.capController);
        d.settlementOracle = address(k.settlement);
        d.write = write;
        d.liquidityEscrow = address(h.escrow);
        d.emissionsController = address(h.emissions);
        d.treasuryVesting = address(h.treasuryVesting);
        d.teamVesting = address(h.teamVesting);
        d.pointsDistributor = address(h.points);
        d.vaults = new VaultRecord[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            d.vaults[i] = VaultRecord({
                symbol: c.vaults[i].symbol,
                vault: vaults[i],
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

    function _emptyHolders() internal pure returns (TokenDeployLib.Holders memory h) {}

    function _emptyCore() internal pure returns (VaultDeployLib.Core memory k) {}

    function _indexOf(address[] memory targets, bytes[] memory payloads, address target, bytes4 selector)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == target && bytes4(payloads[i]) == selector) return i;
        }
        return 0;
    }
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}
