// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployConfig, VaultCfg} from "./Config.sol";
import {TokenDeployLib} from "./TokenDeployLib.sol";

import {RiskModule} from "../src/RiskModule.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {BondManager} from "../src/BondManager.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {AuctionHouse} from "../src/AuctionHouse.sol";
import {CapController} from "../src/CapController.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SeriesKind, OracleParams} from "../src/Types.sol";

/// @title VaultDeployLib
/// @notice The one description of how the vault layer is deployed and wired, in the order
/// `contracts/README.md` prescribes (D-044, D-049, D-050, D-054, D-058). `script/Deploy.s.sol`,
/// `test/DeployLib.t.sol` and `test/DeployFork.t.sol` all call it, so the script cannot drift from the
/// fixture the way it could while the ordering lived only in prose and in `test/SettlementBase.t.sol`.
///
/// @dev **Every contract is owned by the timelock from birth** (D-098, extended here to the vault layer).
/// The deploy is split so the deployer key never holds a privilege: it only calls `new`, and every
/// owner-gated setter is expressed as calldata for a `TimelockController.scheduleBatch`.
///
/// The wiring is a **calldata builder, not a sequence of calls**. That is deliberate: the timelock has to be
/// `msg.sender` of each setter, so tests that execute the very same `targets`/`payloads` arrays through a real
/// `TimelockController` exercise the production path exactly. There is no second, direct-call version of the
/// ordering to fall out of sync.
///
///   1. `deployCore` + `deployVaults` — deployer — everything `new`, owned by the timelock
///   2. `batchA`                      — TIMELOCK batch — all vault-layer wiring, plus `setWriteToken` x5
///   3. (`TokenDeployLib.deployStaking`) — deployer
///   4. `batchB`                      — TIMELOCK batch — `setSanityBand`, `setSink`
///
/// Ordering inside `batchA` is load-bearing and every constraint below is a constructor or setter assert, not
/// a preference:
///   - `bondManager.setAuctionHouse` and `feeRouter.setAuctionHouse` are one-shot (D-044) and both are
///     asserted by `AuctionHouse.registerVault`, so they come first.
///   - `riskModule.setSettlementOracle` is one-shot and `SettlementOracle.registerVault` asserts it.
///   - `auctionHouse.registerVault` must precede `settlementOracle.registerVault`, which asserts
///     `auctionHouse.isVault(vault)`.
///   - `capController.setCapUSD` is what makes a vault able to take a deposit at all: in FIXED mode a
///     `capUSD` of zero means no deposits (SPEC §12).
library VaultDeployLib {
    /// @dev `AuctionHouse.registerVault` seeds these floors itself, and `FeeRouter.initVault` seeds
    /// `feeBps = 1000`. A config that matches them produces no extra calls, which keeps the batch a human can
    /// read on a Ledger screen as short as it can be.
    uint16 internal constant SEEDED_STRIKE_WEEKDAY = 300;
    uint16 internal constant SEEDED_STRIKE_WEEKEND = 100;
    uint16 internal constant SEEDED_RESERVE_WEEKDAY = 10;
    uint16 internal constant SEEDED_RESERVE_WEEKEND = 3;
    uint16 internal constant SEEDED_FEE_BPS = 1000;

    struct Core {
        RiskModule riskModule;
        OptionToken optionToken;
        BondManager bondManager;
        FeeRouter feeRouter;
        AuctionHouse auctionHouse;
        CapController capController;
        SettlementOracle settlement;
    }

    // ───────────────────────────── stage 1: deployer ─────────────────────────────

    /// @notice The seven core contracts, in dependency order. `TickMath` must already be deployed and linked:
    /// `SettlementOracle`'s constructor reverts `Miswired("TICK_MATH")` otherwise (D-058).
    /// @dev `AuctionHouse` and `CapController` take `priceSourcePlaceholder` because the real source is the
    /// `SettlementOracle`, which needs the AuctionHouse in its own constructor. Both are re-pointed in
    /// `batchA`; until then the vault's `try/catch` on the cap read (D-041) keeps `maxDeposit` returning 0
    /// instead of reverting, and `capUSD` is 0 anyway, so no deposit is possible in the interval.
    function deployCore(DeployConfig memory c, address owner) internal returns (Core memory k) {
        k.riskModule = new RiskModule(owner);
        k.optionToken = new OptionToken(c.optionTokenUri, owner);
        k.bondManager = new BondManager(c.ext.usdg, owner, c.gov.treasury);
        k.feeRouter = new FeeRouter(c.ext.usdg, owner, c.gov.treasury);
        k.auctionHouse = new AuctionHouse(
            c.ext.usdg,
            address(k.bondManager),
            address(k.feeRouter),
            c.ext.priceSourcePlaceholder,
            address(k.optionToken),
            owner
        );
        k.capController = new CapController(owner, c.ext.priceSourcePlaceholder);
        k.settlement = new SettlementOracle(address(k.riskModule), address(k.auctionHouse), c.ext.usdgUsdFeed, owner);
    }

    /// @notice One `CoveredCallVault` per configured stock token. All seven cross-contract references are
    /// immutable, so the vault is the last thing deployed and can never be re-pointed afterwards (D-034).
    function deployVaults(DeployConfig memory c, Core memory k, address owner)
        internal
        returns (address[] memory vaults)
    {
        vaults = new address[](c.vaults.length);
        for (uint256 i; i < c.vaults.length; ++i) {
            vaults[i] = address(
                new CoveredCallVault(
                    CoveredCallVault.Config({
                        stock: c.vaults[i].stock,
                        usdg: c.ext.usdg,
                        optionToken: address(k.optionToken),
                        auctionHouse: address(k.auctionHouse),
                        settlement: address(k.settlement),
                        riskModule: address(k.riskModule),
                        capController: address(k.capController),
                        owner: owner,
                        name: c.vaults[i].name,
                        symbol: c.vaults[i].shareSymbol
                    })
                )
            );
        }
    }

    // ───────────────────────────── stage 2: timelock batch A ─────────────────────────────

    /// @notice Every owner-gated call that wires the system, as `(targets, payloads)` for one
    /// `scheduleBatch`. `TimelockController.executeBatch` runs them in array order, which is what makes the
    /// ordering above enforceable in a single governance action.
    /// @param write `address(0)` when the token layer is not part of this deployment, in which case the five
    /// `setWriteToken` calls are omitted and `DeployToken.s.sol` ships them later.
    function batchA(
        DeployConfig memory c,
        Core memory k,
        address[] memory vaults,
        TokenDeployLib.Holders memory h,
        address write
    ) internal pure returns (address[] memory targets, bytes[] memory payloads) {
        uint256 max = 8 + c.gov.guardians.length + 9 * vaults.length + (write == address(0) ? 0 : 5);
        targets = new address[](max);
        payloads = new bytes[](max);
        uint256 n;

        // One-shot back-references, both asserted by `registerVault` (D-044).
        (targets[n], payloads[n++]) =
        (address(k.bondManager), abi.encodeCall(BondManager.setAuctionHouse, (address(k.auctionHouse))));
        (targets[n], payloads[n++]) =
        (address(k.feeRouter), abi.encodeCall(FeeRouter.setAuctionHouse, (address(k.auctionHouse))));
        // One-shot, and asserted by `SettlementOracle.registerVault` (D-050).
        (targets[n], payloads[n++]) =
        (address(k.riskModule), abi.encodeCall(RiskModule.setSettlementOracle, (address(k.settlement))));

        for (uint256 g; g < c.gov.guardians.length; ++g) {
            (targets[n], payloads[n++]) =
            (address(k.riskModule), abi.encodeCall(RiskModule.setGuardian, (c.gov.guardians[g], true)));
        }
        (targets[n], payloads[n++]) =
        (address(k.auctionHouse), abi.encodeCall(AuctionHouse.setKeeper, (c.gov.keeper, true)));

        for (uint256 i; i < vaults.length; ++i) {
            n = _vaultCalls(c, k, vaults, i, targets, payloads, n);
        }

        // The real price source, once it exists (D-039, D-047, D-054).
        (targets[n], payloads[n++]) =
        (address(k.auctionHouse), abi.encodeCall(AuctionHouse.setPriceSource, (address(k.settlement))));
        (targets[n], payloads[n++]) =
        (address(k.capController), abi.encodeCall(CapController.setPriceSource, (address(k.settlement))));
        // ... and frozen in the same batch (audit G-1): from here on `S_ref` / `S_cap` can only change by redeploy.
        (targets[n], payloads[n++]) = (address(k.auctionHouse), abi.encodeCall(AuctionHouse.freezePriceSource, ()));
        (targets[n], payloads[n++]) = (address(k.capController), abi.encodeCall(CapController.freezePriceSource, ()));

        if (write != address(0)) {
            n = _writeTokenCalls(h, write, targets, payloads, n);
        }
        _trim(targets, payloads, n);
    }

    function _vaultCalls(
        DeployConfig memory c,
        Core memory k,
        address[] memory vaults,
        uint256 i,
        address[] memory targets,
        bytes[] memory payloads,
        uint256 n
    ) private pure returns (uint256) {
        VaultCfg memory cfg = c.vaults[i];
        address v = vaults[i];

        // Irreversible, one vault per underlying.
        (targets[n], payloads[n++]) =
        (address(k.optionToken), abi.encodeCall(OptionToken.registerVault, (cfg.stock, v)));
        // Needs both `setAuctionHouse` calls above; also calls `feeRouter.initVault`, seeding feeBps = 1000.
        (targets[n], payloads[n++]) = (address(k.auctionHouse), abi.encodeCall(AuctionHouse.registerVault, (v)));
        // Needs `setSettlementOracle` and the `registerVault` above; one-shot, with no re-point path (D-057).
        (targets[n], payloads[n++]) =
        (address(k.settlement), abi.encodeCall(SettlementOracle.registerVault, (v, cfg.feed, cfg.pool)));
        // Without this the vault accepts no deposits at all (SPEC §12).
        (targets[n], payloads[n++]) =
        (address(k.capController), abi.encodeCall(CapController.setCapUSD, (v, cfg.capUSD)));

        // Everything below is emitted only where the config differs from what the contracts already seeded.
        if (keccak256(abi.encode(cfg.params)) != keccak256(abi.encode(k.riskModule.defaultParams()))) {
            (targets[n], payloads[n++]) =
            (address(k.riskModule), abi.encodeCall(RiskModule.setOracleParams, (v, cfg.params)));
        }
        if (cfg.minStrikeWeekday != SEEDED_STRIKE_WEEKDAY) {
            (targets[n], payloads[n++]) =
            (
                address(k.auctionHouse),
                abi.encodeCall(AuctionHouse.setMinStrikeDistanceBps, (v, SeriesKind.WEEKDAY, cfg.minStrikeWeekday))
            );
        }
        if (cfg.minStrikeWeekend != SEEDED_STRIKE_WEEKEND) {
            (targets[n], payloads[n++]) =
            (
                address(k.auctionHouse),
                abi.encodeCall(AuctionHouse.setMinStrikeDistanceBps, (v, SeriesKind.WEEKEND, cfg.minStrikeWeekend))
            );
        }
        if (cfg.minReserveWeekday != SEEDED_RESERVE_WEEKDAY) {
            (targets[n], payloads[n++]) =
            (
                address(k.auctionHouse),
                abi.encodeCall(AuctionHouse.setMinReserveBpsOfSpot, (v, SeriesKind.WEEKDAY, cfg.minReserveWeekday))
            );
        }
        if (cfg.minReserveWeekend != SEEDED_RESERVE_WEEKEND) {
            (targets[n], payloads[n++]) =
            (
                address(k.auctionHouse),
                abi.encodeCall(AuctionHouse.setMinReserveBpsOfSpot, (v, SeriesKind.WEEKEND, cfg.minReserveWeekend))
            );
        }
        if (cfg.feeBps != SEEDED_FEE_BPS) {
            // Must follow `AuctionHouse.registerVault`: `setFeeBps` reverts `NotInitialised` before it.
            (targets[n], payloads[n++]) = (address(k.feeRouter), abi.encodeCall(FeeRouter.setFeeBps, (v, cfg.feeBps)));
        }
        return n;
    }

    /// @dev `TokenDeployLib.wireHolders` as calldata. Each `setWriteToken` asserts the holder already holds
    /// its declared `allocation()`, which the WRITE constructor minted in stage 1 (D-060, D-061).
    function _writeTokenCalls(
        TokenDeployLib.Holders memory h,
        address write,
        address[] memory targets,
        bytes[] memory payloads,
        uint256 n
    ) private pure returns (uint256) {
        address[5] memory holders = [
            address(h.escrow),
            address(h.emissions),
            address(h.treasuryVesting),
            address(h.teamVesting),
            address(h.points)
        ];
        for (uint256 i; i < 5; ++i) {
            // All five expose the identical `setWriteToken(address)` selector.
            (targets[n], payloads[n++]) = (holders[i], abi.encodeWithSignature("setWriteToken(address)", write));
        }
        return n;
    }

    // ───────────────────────────── stage 4: timelock batch B ─────────────────────────────

    /// @notice `TokenDeployLib.wireStaking` as calldata. The sanity band must exist before any pool can be
    /// attached to the oracle (D-066), and `setSink` is one-shot.
    function batchB(DeployConfig memory c, address writeOracle, address emissions, address safetyModule)
        internal
        pure
        returns (address[] memory targets, bytes[] memory payloads)
    {
        targets = new address[](2);
        payloads = new bytes[](2);
        targets[0] = writeOracle;
        payloads[0] = abi.encodeCall(WritePriceOracle.setSanityBand, (c.token.sanityLow8, c.token.sanityHigh8));
        targets[1] = emissions;
        payloads[1] = abi.encodeCall(EmissionsController.setSink, (safetyModule));
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Shortens both arrays to `n` in place. Assembly is the only way to resize a memory array, and the
    /// alternative is copying two arrays of `bytes` for no benefit.
    function _trim(address[] memory targets, bytes[] memory payloads, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(targets, n)
            mstore(payloads, n)
        }
    }

    /// @notice Zero values for a batch: no call in either batch is payable.
    function values(uint256 n) internal pure returns (uint256[] memory v) {
        v = new uint256[](n);
    }
}
