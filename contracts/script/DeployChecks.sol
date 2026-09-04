// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {DeployConfig} from "./Config.sol";
import {Deployed, VaultRecord} from "./Deployment.sol";

import {RiskModule} from "../src/RiskModule.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {BondManager} from "../src/BondManager.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {AuctionHouse} from "../src/AuctionHouse.sol";
import {CapController} from "../src/CapController.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {WRITE} from "../src/WRITE.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Vesting} from "../src/Vesting.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {VaultState} from "../src/Types.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @dev The error every guarded contract reverts. Declared here so the renounce sweep can recognise it by
/// selector across all fourteen without importing each contract's own copy.
error RenounceDisabled();

/// @title DeployChecks
/// @notice Every assertion a finished deployment must satisfy, in one place. `script/Deploy.s.sol` runs it at
/// the end of a deploy, `script/Verify.s.sol` runs it standalone against a system it did not deploy, and
/// `test/DeployLib.t.sol` and `test/DeployFork.t.sol` run it against the library output. One assertion set,
/// four callers: a wiring mistake cannot be true in one place and false in another.
library DeployChecks {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 private constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 private constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    uint24 private constant POOL_FEE = 500;

    /// @dev `view`: verification never changes anything, on any chain.
    function assertAll(DeployConfig memory c, Deployed memory d) internal view {
        assertLibrary(d);
        assertOwnership(d);
        assertTimelock(c, d);
        assertRoles(c, d);
        assertCoreWiring(d);
        assertVaults(c, d);
        assertParameters(c, d);
        assertPauseState(d);
        assertTokenLayer(c, d);
        assertDeployerPowerless(c, d);
    }

    // ───────────────────────────── library link ─────────────────────────────

    /// @dev D-058. Both oracle constructors already reject an unlinked or mis-linked TickMath, so this only
    /// re-checks that the address recorded in the deployment is the one this build is linked against.
    function assertLibrary(Deployed memory d) internal pure {
        require(TickMath.getSqrtRatioAtTick(0) == 2 ** 96, "tickMath: link");
        if (d.tickMath != address(0)) require(address(TickMath) == d.tickMath, "tickMath: address");
    }

    // ───────────────────────────── ownership ─────────────────────────────

    /// @notice Every owned contract is owned by the timelock, with no transfer half-finished. `Ownable2Step`
    /// means a pending owner would be a live takeover offer, so it must be zero.
    function assertOwnership(Deployed memory d) internal view {
        address[] memory owned = ownedContracts(d);
        for (uint256 i; i < owned.length; ++i) {
            require(Ownable2Step(owned[i]).owner() == d.timelock, "owner: not the timelock");
            require(Ownable2Step(owned[i]).pendingOwner() == address(0), "owner: transfer pending");
        }
    }

    /// @notice The fourteen owned contracts of a full deployment, or seven when the token layer is not part
    /// of it. The mocks are deliberately absent: they are testnet fixtures, not protocol contracts.
    function ownedContracts(Deployed memory d) internal pure returns (address[] memory owned) {
        bool token = d.write != address(0);
        owned = new address[](7 + d.vaults.length + (token ? 7 : 0));
        uint256 n;
        owned[n++] = d.riskModule;
        owned[n++] = d.optionToken;
        owned[n++] = d.bondManager;
        owned[n++] = d.feeRouter;
        owned[n++] = d.auctionHouse;
        owned[n++] = d.capController;
        owned[n++] = d.settlementOracle;
        for (uint256 i; i < d.vaults.length; ++i) {
            owned[n++] = d.vaults[i].vault;
        }
        if (token) {
            owned[n++] = d.liquidityEscrow;
            owned[n++] = d.emissionsController;
            owned[n++] = d.treasuryVesting;
            owned[n++] = d.teamVesting;
            owned[n++] = d.pointsDistributor;
            owned[n++] = d.writePriceOracle;
            owned[n++] = d.safetyModule;
        }
    }

    // ───────────────────────────── timelock ─────────────────────────────

    /// @notice SPEC §15 / D-003: `TimelockController(minDelay, [adminEOA], [adminEOA], address(0))`. The zero
    /// admin argument makes the timelock its own `DEFAULT_ADMIN_ROLE` holder, so no EOA can re-grant roles
    /// without going through the delay.
    function assertTimelock(DeployConfig memory c, Deployed memory d) internal view {
        TimelockController t = TimelockController(payable(d.timelock));
        require(t.getMinDelay() == c.gov.timelockMinDelay, "timelock: minDelay");
        require(t.hasRole(PROPOSER_ROLE, c.gov.admin), "timelock: admin is not proposer");
        require(t.hasRole(EXECUTOR_ROLE, c.gov.admin), "timelock: admin is not executor");
        require(t.hasRole(CANCELLER_ROLE, c.gov.admin), "timelock: admin is not canceller");
        require(t.hasRole(DEFAULT_ADMIN_ROLE, d.timelock), "timelock: does not self-administer");
        require(!t.hasRole(DEFAULT_ADMIN_ROLE, c.gov.admin), "timelock: admin holds DEFAULT_ADMIN_ROLE");
        require(!t.hasRole(EXECUTOR_ROLE, address(0)), "timelock: execution is open to anyone");
    }

    // ───────────────────────────── guardian and keeper ─────────────────────────────

    function assertRoles(DeployConfig memory c, Deployed memory d) internal view {
        RiskModule rm = RiskModule(d.riskModule);
        AuctionHouse ah = AuctionHouse(d.auctionHouse);
        bytes32 guardian = rm.GUARDIAN_ROLE();
        bytes32 keeper = ah.KEEPER_ROLE();

        for (uint256 i; i < c.gov.guardians.length; ++i) {
            require(rm.hasRole(guardian, c.gov.guardians[i]), "guardian: not granted");
        }
        require(ah.hasRole(keeper, c.gov.keeper), "keeper: not granted");
        // D-029: the hot guardian key must be distinct from the keeper's transaction key, so a compromised
        // keeper cannot also unpause itself. On a chain where one key wears every hat this is waived along
        // with the rest of the separation, and the deviation is reported instead.
        if (!c.gov.deployerIsAdmin) {
            require(!rm.hasRole(guardian, c.gov.keeper), "guardian: keeper key is also a guardian");
        }
        // No account holds DEFAULT_ADMIN_ROLE on either AccessControl contract: the owner is the admin.
        address[4] memory suspects = [d.timelock, c.gov.admin, d.deployer, c.gov.keeper];
        for (uint256 i; i < suspects.length; ++i) {
            require(!rm.hasRole(DEFAULT_ADMIN_ROLE, suspects[i]), "riskModule: DEFAULT_ADMIN_ROLE granted");
            require(!ah.hasRole(DEFAULT_ADMIN_ROLE, suspects[i]), "auctionHouse: DEFAULT_ADMIN_ROLE granted");
        }
    }

    // ───────────────────────────── core wiring ─────────────────────────────

    function assertCoreWiring(Deployed memory d) internal view {
        AuctionHouse ah = AuctionHouse(d.auctionHouse);
        require(BondManager(d.bondManager).auctionHouse() == d.auctionHouse, "bondManager: auctionHouse");
        require(FeeRouter(d.feeRouter).auctionHouse() == d.auctionHouse, "feeRouter: auctionHouse");
        require(RiskModule(d.riskModule).settlementOracle() == d.settlementOracle, "riskModule: settlementOracle");
        require(address(ah.priceSource()) == d.settlementOracle, "auctionHouse: priceSource still placeholder");
        require(
            address(CapController(d.capController).priceSource()) == d.settlementOracle,
            "capController: priceSource still placeholder"
        );
        require(address(ah.optionToken()) == d.optionToken, "auctionHouse: optionToken");
        require(address(ah.bondManager()) == d.bondManager, "auctionHouse: bondManager");
        require(address(ah.feeRouter()) == d.feeRouter, "auctionHouse: feeRouter");
        require(address(ah.usdg()) == d.usdg, "auctionHouse: usdg");
        require(address(BondManager(d.bondManager).usdg()) == d.usdg, "bondManager: usdg");
        require(address(FeeRouter(d.feeRouter).usdg()) == d.usdg, "feeRouter: usdg");

        SettlementOracle so = SettlementOracle(d.settlementOracle);
        require(address(so.riskModule()) == d.riskModule, "settlementOracle: riskModule");
        require(address(so.auctionHouse()) == d.auctionHouse, "settlementOracle: auctionHouse");
        require(address(so.usdgUsdFeed()) == d.usdgUsdFeed, "settlementOracle: usdgUsdFeed");
        require(AggregatorV3Interface(d.usdgUsdFeed).decimals() == 8, "usdgUsdFeed: decimals");
    }

    // ───────────────────────────── per vault ─────────────────────────────

    function assertVaults(DeployConfig memory c, Deployed memory d) internal view {
        require(d.vaults.length == c.vaults.length, "vaults: count");
        for (uint256 i; i < d.vaults.length; ++i) {
            _assertVault(d, i);
        }
    }

    function _assertVault(Deployed memory d, uint256 i) private view {
        VaultRecord memory r = d.vaults[i];
        CoveredCallVault v = CoveredCallVault(r.vault);

        // The seven immutables. None of these can be repaired after deployment (D-034, D-039).
        require(address(v.stock()) == r.stock, "vault: stock");
        require(address(v.usdg()) == d.usdg, "vault: usdg");
        require(address(v.optionToken()) == d.optionToken, "vault: optionToken");
        require(v.auctionHouse() == d.auctionHouse, "vault: auctionHouse");
        require(v.settlement() == d.settlementOracle, "vault: settlement");
        require(address(v.riskModule()) == d.riskModule, "vault: riskModule");
        require(address(v.capController()) == d.capController, "vault: capController");

        require(OptionToken(d.optionToken).vaultOf(r.stock) == r.vault, "optionToken: vaultOf");
        require(OptionToken(d.optionToken).isVault(r.vault), "optionToken: isVault");
        require(AuctionHouse(d.auctionHouse).isVault(r.vault), "auctionHouse: not registered");

        ISettlementOracle.VaultConfig memory vc = SettlementOracle(d.settlementOracle).vaultConfig(r.vault);
        require(vc.registered, "settlementOracle: not registered");
        require(address(vc.feed) == r.feed, "settlementOracle: feed");
        require(address(vc.pool) == r.pool, "settlementOracle: pool");
        require(vc.firstRound != 0, "settlementOracle: no first round");
        require(AggregatorV3Interface(r.feed).decimals() == 8, "feed: decimals");

        // SPEC §9.1: the pool is the 0.05 % tier and its pair is exactly {stock, USDG}, in either order.
        IUniswapV3Pool p = IUniswapV3Pool(r.pool);
        require(p.fee() == POOL_FEE, "pool: fee tier");
        bool token1 = p.token0() == d.usdg && p.token1() == r.stock;
        bool token0 = p.token0() == r.stock && p.token1() == d.usdg;
        require(token0 || token1, "pool: token pair");
        require(vc.stockIsToken1 == token1, "pool: cached orientation");
    }

    // ───────────────────────────── parameters ─────────────────────────────

    function assertParameters(DeployConfig memory c, Deployed memory d) internal view {
        CapController cap = CapController(d.capController);
        FeeRouter fr = FeeRouter(d.feeRouter);
        BondManager bm = BondManager(d.bondManager);

        // SPEC §12 / CLAUDE.md rule 6: FIXED at launch, with the SAFETY_MODULE path present but unwired.
        require(cap.capMode() == CapController.CapMode.FIXED, "cap: mode is not FIXED at launch");
        require(cap.k() == 5e18, "cap: k");
        require(address(cap.safetyModule()) == address(0), "cap: safetyModule set before the token launch");

        // SPEC §11: USDG mode only until the timelock wires the token (D-084).
        require(fr.treasury() == c.gov.treasury, "feeRouter: treasury");
        require(fr.writeToken() == address(0), "feeRouter: writeToken set");
        require(fr.priceOracle() == address(0), "feeRouter: priceOracle set");
        require(fr.writeDiscountBps() == 2000, "feeRouter: writeDiscountBps");
        require(fr.writeBurnShareBps() == 5000, "feeRouter: writeBurnShareBps");

        // SPEC §13 / D-011.
        require(bm.treasury() == c.gov.treasury, "bondManager: treasury");
        require(bm.bondAsset() == IBondManager.BondAsset.USDG, "bondManager: bondAsset");
        require(bm.writeToken() == address(0), "bondManager: writeToken set");
        require(bm.requiredAmount(IBondManager.BondKind.MM) == 25_000e6, "bondManager: MM bond");
        require(bm.requiredAmount(IBondManager.BondKind.CURATOR) == 10_000e6, "bondManager: curator bond");

        for (uint256 i; i < d.vaults.length; ++i) {
            address v = d.vaults[i].vault;
            require(cap.capUSD(v) == c.vaults[i].capUSD, "cap: capUSD");
            require(cap.capWeightBps(v) == 0, "cap: weight set before the switch");
            require(fr.feeBps(v) == c.vaults[i].feeBps, "feeRouter: feeBps");
            require(fr.mode(v) == IFeeRouter.FeeMode.USDG, "feeRouter: mode is not USDG");
            _assertOracleParams(c, d, i);
        }
    }

    function _assertOracleParams(DeployConfig memory c, Deployed memory d, uint256 i) private view {
        // `paramsAt` is versioned and `setOracleParams` takes effect at `block.timestamp + 1`, so the current
        // view is what a series opened from now on would snapshot (D-031).
        bytes32 want = keccak256(abi.encode(c.vaults[i].params));
        bytes32 got = keccak256(abi.encode(RiskModule(d.riskModule).currentParams(d.vaults[i].vault)));
        require(want == got, "riskModule: oracle params");
    }

    // ───────────────────────────── pause state ─────────────────────────────

    /// @notice A fresh deployment is unpaused and idle. `ALL` is the `address(0)` sentinel that dominates the
    /// per-vault flags (SPEC §15).
    function assertPauseState(Deployed memory d) internal view {
        RiskModule rm = RiskModule(d.riskModule);
        require(!rm.depositsPaused(rm.ALL()), "pause: global deposits paused");
        require(!rm.auctionsPaused(rm.ALL()), "pause: global auctions paused");
        for (uint256 i; i < d.vaults.length; ++i) {
            address v = d.vaults[i].vault;
            require(!rm.depositsPaused(v), "pause: vault deposits paused");
            require(!rm.auctionsPaused(v), "pause: vault auctions paused");
            require(CoveredCallVault(v).state() == VaultState.IDLE, "vault: not IDLE");
            require(!CoveredCallVault(v).sunset(), "vault: sunset");
            require(CoveredCallVault(v).currentSeriesId() == 0, "vault: has a series");
        }
    }

    // ───────────────────────────── token layer ─────────────────────────────

    function assertTokenLayer(DeployConfig memory c, Deployed memory d) internal view {
        if (d.write == address(0)) return;
        WRITE w = WRITE(d.write);
        require(w.totalSupply() == w.MAX_SUPPLY(), "write: supply");
        require(w.balanceOf(d.liquidityEscrow) == LiquidityEscrow(d.liquidityEscrow).allocation(), "escrow: funded");
        require(
            w.balanceOf(d.emissionsController) == EmissionsController(d.emissionsController).allocation(),
            "emissions: funded"
        );
        require(w.balanceOf(d.treasuryVesting) == Vesting(d.treasuryVesting).allocation(), "treasuryVesting: funded");
        require(w.balanceOf(d.teamVesting) == Vesting(d.teamVesting).allocation(), "teamVesting: funded");
        require(
            w.balanceOf(d.pointsDistributor) == PointsDistributor(d.pointsDistributor).allocation(), "points: funded"
        );
        // D-062: the treasury grant is structurally irrevocable, the team grant is not.
        require(!Vesting(d.treasuryVesting).allowRevocable(), "treasuryVesting: revocable");
        require(Vesting(d.teamVesting).allowRevocable(), "teamVesting: not revocable");

        EmissionsController em = EmissionsController(d.emissionsController);
        require(em.writeToken() == d.write, "emissions: writeToken");
        require(em.sink() == d.safetyModule, "emissions: sink");
        require(LiquidityEscrow(d.liquidityEscrow).writeToken() == d.write, "escrow: writeToken");
        require(Vesting(d.treasuryVesting).writeToken() == d.write, "treasuryVesting: writeToken");
        require(Vesting(d.teamVesting).writeToken() == d.write, "teamVesting: writeToken");
        require(PointsDistributor(d.pointsDistributor).writeToken() == d.write, "points: writeToken");

        WritePriceOracle wo = WritePriceOracle(d.writePriceOracle);
        require(wo.writeToken() == d.write, "writeOracle: writeToken");
        require(wo.sanityLow8() == c.token.sanityLow8, "writeOracle: sanityLow8");
        require(wo.sanityHigh8() == c.token.sanityHigh8, "writeOracle: sanityHigh8");
        // The launch venue is a governance decision, not a deploy step (D-063).
        require(wo.pool() == address(0), "writeOracle: pool already set");
        require(LiquidityEscrow(d.liquidityEscrow).pool() == address(0), "escrow: pool already set");

        SafetyModule sm = SafetyModule(d.safetyModule);
        require(sm.writeToken() == d.write, "safetyModule: writeToken");
        require(sm.emissions() == d.emissionsController, "safetyModule: emissions");
        require(address(sm.oracle()) == d.writePriceOracle, "safetyModule: oracle");
    }

    // ───────────────────────────── the point of the whole thing ─────────────────────────────

    /// @notice The deployer key created every contract and must be able to touch none of them (D-098, extended
    /// to the vault layer). On a chain where `deployerIsAdmin` is set the deployer also wears the governance
    /// hat, so only the timelock-role half is waived; owning nothing and holding no WRITE still hold.
    function assertDeployerPowerless(DeployConfig memory c, Deployed memory d) internal view {
        address[] memory owned = ownedContracts(d);
        for (uint256 i; i < owned.length; ++i) {
            require(Ownable2Step(owned[i]).owner() != d.deployer, "deployer: owns a contract");
        }
        require(
            !RiskModule(d.riskModule).hasRole(RiskModule(d.riskModule).GUARDIAN_ROLE(), d.deployer)
                || c.gov.deployerIsAdmin,
            "deployer: holds GUARDIAN_ROLE"
        );
        require(
            !AuctionHouse(d.auctionHouse).hasRole(AuctionHouse(d.auctionHouse).KEEPER_ROLE(), d.deployer)
                || c.gov.deployerIsAdmin,
            "deployer: holds KEEPER_ROLE"
        );
        if (d.write != address(0)) require(WRITE(d.write).balanceOf(d.deployer) == 0, "deployer: holds WRITE");
        if (c.gov.deployerIsAdmin) return;

        TimelockController t = TimelockController(payable(d.timelock));
        require(!t.hasRole(PROPOSER_ROLE, d.deployer), "deployer: timelock proposer");
        require(!t.hasRole(EXECUTOR_ROLE, d.deployer), "deployer: timelock executor");
        require(!t.hasRole(CANCELLER_ROLE, d.deployer), "deployer: timelock canceller");
        require(!t.hasRole(DEFAULT_ADMIN_ROLE, d.deployer), "deployer: timelock admin");
    }

    // ───────────────────────────── report ─────────────────────────────

    function report(DeployConfig memory c, Deployed memory d) internal {
        console2.log("");
        console2.log("=== overwrite deployment ===================================================");
        console2.log("  chain                ", d.label, d.chainId);
        console2.log("  deployer (powerless) ", d.deployer);
        console2.log("  TimelockController   ", d.timelock);
        console2.log("  timelock minDelay (s)", c.gov.timelockMinDelay);
        console2.log("  admin EOA            ", c.gov.admin);
        for (uint256 i; i < c.gov.guardians.length; ++i) {
            console2.log("  guardian             ", c.gov.guardians[i]);
        }
        console2.log("  keeper               ", c.gov.keeper);
        console2.log("  treasury             ", c.gov.treasury);
        console2.log("  ---------------------------------------------------------------------");
        console2.log("  TickMath (library)   ", d.tickMath);
        console2.log("  USDG                 ", d.usdg);
        console2.log("  USDG/USD feed        ", d.usdgUsdFeed);
        console2.log("  RiskModule           ", d.riskModule);
        console2.log("  OptionToken          ", d.optionToken);
        console2.log("  BondManager          ", d.bondManager);
        console2.log("  FeeRouter            ", d.feeRouter);
        console2.log("  AuctionHouse         ", d.auctionHouse);
        console2.log("  CapController        ", d.capController);
        console2.log("  SettlementOracle     ", d.settlementOracle);
        _reportVaults(d);
        _reportToken(d);
        _reportMocked(d);
        _reportDeviation(c);
        renounceSweep(d);
        console2.log("============================================================================");
    }

    function _reportVaults(Deployed memory d) private pure {
        for (uint256 i; i < d.vaults.length; ++i) {
            console2.log("  ---------------------------------------------------------------------");
            console2.log("  vault", d.vaults[i].symbol, d.vaults[i].vault);
            console2.log("    stock              ", d.vaults[i].stock);
            console2.log("    chainlink feed     ", d.vaults[i].feed);
            console2.log("    uniswap v3 pool    ", d.vaults[i].pool);
        }
    }

    function _reportToken(Deployed memory d) private pure {
        if (d.write == address(0)) {
            console2.log("  ---------------------------------------------------------------------");
            console2.log("  token layer          not part of this deployment");
            return;
        }
        console2.log("  ---------------------------------------------------------------------");
        console2.log("  WRITE                ", d.write);
        console2.log("  LiquidityEscrow      ", d.liquidityEscrow);
        console2.log("  EmissionsController  ", d.emissionsController);
        console2.log("  Vesting (treasury)   ", d.treasuryVesting);
        console2.log("  Vesting (team)       ", d.teamVesting);
        console2.log("  PointsDistributor    ", d.pointsDistributor);
        console2.log("  WritePriceOracle     ", d.writePriceOracle);
        console2.log("  SafetyModule         ", d.safetyModule);
    }

    function _reportMocked(Deployed memory d) private pure {
        console2.log("  ---------------------------------------------------------------------");
        if (d.mocked.length == 0) {
            console2.log("  mocked               nothing: every external address is real");
            return;
        }
        console2.log("  MOCKED -- these had no deployment on this chain (SPEC 1.8, D-014):");
        for (uint256 i; i < d.mocked.length; ++i) {
            console2.log("    -", d.mocked[i]);
        }
    }

    function _reportDeviation(DeployConfig memory c) private pure {
        if (!c.gov.deployerIsAdmin) return;
        console2.log("  ---------------------------------------------------------------------");
        console2.log("  TESTNET DEVIATION: the deployer key doubles as the admin EOA, guardian,");
        console2.log("  treasury and keeper, and the timelock delay is 0. On 4663 these are");
        console2.log("  separate keys and the delay is 48 h. The deployer still owns no contract");
        console2.log("  and holds no WRITE; only the timelock-role assertions are waived.");
    }

    /// @notice Warns about any owned contract whose ownership could still be renounced. After D-100 all
    /// fourteen are protected and this prints nothing, so it stands as a regression detector for the day a
    /// fifteenth owned contract is added without the override.
    /// @dev Probed with a **staticcall** from the owner, which can never mutate anything even in simulation.
    /// A guarded contract's override is `view` and reverts `RenounceDisabled()`, so the call fails with that
    /// selector; an unguarded one writes storage, so the same call fails with empty returndata. The two are
    /// told apart by the revert data, not by whether the call reverted.
    function renounceSweep(Deployed memory d) internal {
        address[] memory owned = ownedContracts(d);
        uint256 unguarded;
        for (uint256 i; i < owned.length; ++i) {
            vm.prank(d.timelock);
            (bool ok, bytes memory err) = owned[i].staticcall(abi.encodeWithSignature("renounceOwnership()"));
            bool guarded = !ok && err.length >= 4 && bytes4(err) == RenounceDisabled.selector;
            if (!guarded) {
                if (unguarded++ == 0) {
                    console2.log("  ---------------------------------------------------------------------");
                    console2.log("  WARN: renounceOwnership is not disabled on:");
                }
                console2.log("    -", owned[i]);
            }
        }
    }
}
