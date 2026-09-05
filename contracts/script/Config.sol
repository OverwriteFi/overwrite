// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {OracleParams} from "../src/Types.sol";

struct GovernanceCfg {
    uint256 timelockMinDelay; // 172 800 on 4663 (SPEC §15, D-003); 0 on a chain with one funded key
    address admin; // the hardware-wallet EOA: timelock proposer, executor and canceller
    address[] guardians; // GUARDIAN_ROLE on RiskModule; two holders on mainnet (D-012, D-029)
    address treasury;
    address keeper; // KEEPER_ROLE on AuctionHouse; the only caller of `openAuction` (D-028)
    bool deployerIsAdmin; // testnet-only: the deployer key doubles as the admin EOA
}

struct ExternalsCfg {
    address usdg;
    address usdgUsdFeed;
    address sequencerFeed; // 0 on both chains today: none is published for this chain (D-005)
    address priceSourcePlaceholder; // non-zero filler for two constructors, re-pointed in batch A
}

struct MockCfg {
    string tokenName;
    bool stockIsToken0; // pool orientation; the real NVDA/USDG pool has USDG as token0
    uint256 price8;
    uint128 liquidity;
}

struct VaultCfg {
    string symbol;
    string name;
    string shareSymbol;
    address stock;
    address feed;
    address pool;
    uint256 capUSD; // 6 dec; D-011 launch value 25 000e6
    uint16 feeBps;
    uint16 minStrikeWeekday;
    uint16 minStrikeWeekend;
    uint16 minReserveWeekday;
    uint16 minReserveWeekend;
    OracleParams params;
    MockCfg mock;
}

struct TokenCfg {
    bool deploy;
    uint64 emissionsDuration;
    uint256 sanityLow8;
    uint256 sanityHigh8;
}

struct DeployConfig {
    uint256 chainId;
    string label;
    string explorerUrl;
    string verifier;
    string verifierUrl;
    GovernanceCfg gov;
    ExternalsCfg ext;
    address tickMath;
    string optionTokenUri;
    VaultCfg[] vaults;
    TokenCfg token;
}

/// @title Config
/// @notice Reads `config/<chainId>.json` into `DeployConfig` and refuses a configuration the contracts would
/// reject on chain. Every address, cap and oracle parameter of a deployment lives in that file; nothing about
/// a chain is hard-coded in Solidity. The addresses a deploy creates are recorded in
/// `deployments/<chainId>.json`, not written back here, so this file stays a hand-maintained input with its
/// comments intact. The one exception is `tickMath`, which `script/deploy.sh` edits with a line-level `sed`
/// after `forge create`, because an external library's address has to be known before this script is
/// compiled; it is a flat key, so that edit is safe in a way `vm.writeJson` into `vaults[i]` is not.
/// @dev Fields are read one key at a time rather than `abi.decode`d out of `vm.parseJson`, because that path
/// requires the Solidity struct fields to be in alphabetical order and mis-assigns them silently otherwise.
/// The `cancellers` key of the JSON is documentation only until OQ-001 is decided (a second cold veto key,
/// which must never be a guardian key) and is deliberately not read here.
///
/// Bounds are checked against the same constants `RiskModule._validate` and the AuctionHouse enforce, so a
/// bad parameter fails before the first transaction rather than half way through a timelock batch.
library Config {
    using stdJson for string;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error MissingAddress(string key);
    error OutOfBounds(string key, uint256 value);
    error NoVaults();
    error DuplicateStock(address stock);
    error MainnetGovernance(string what);

    function path(uint256 chainId) internal pure returns (string memory) {
        return string.concat("config/", vm.toString(chainId), ".json");
    }

    // ───────────────────────────── read ─────────────────────────────

    function read(uint256 chainId) internal view returns (DeployConfig memory c) {
        string memory json = vm.readFile(path(chainId));

        c.chainId = json.readUint(".chainId");
        c.label = json.readString(".label");
        c.explorerUrl = json.readString(".explorer.url");
        c.verifier = json.readString(".explorer.verifier");
        c.verifierUrl = json.readString(".explorer.verifierUrl");
        c.tickMath = json.readAddress(".tickMath");
        c.optionTokenUri = json.readString(".optionTokenUri");
        c.gov = _readGov(json);
        c.ext = _readExt(json);
        c.token = _readToken(json);

        uint256 n = json.readUint(".vaultCount");
        c.vaults = new VaultCfg[](n);
        for (uint256 i; i < n; ++i) {
            c.vaults[i] = _readVault(json, i, c.ext.sequencerFeed);
        }
    }

    function _readGov(string memory json) private pure returns (GovernanceCfg memory g) {
        g.timelockMinDelay = json.readUint(".governance.timelockMinDelay");
        g.admin = json.readAddress(".governance.admin");
        g.guardians = json.readAddressArray(".governance.guardians");
        g.treasury = json.readAddress(".governance.treasury");
        g.keeper = json.readAddress(".governance.keeper");
        g.deployerIsAdmin = json.readBool(".governance.deployerIsAdmin");
    }

    function _readExt(string memory json) private pure returns (ExternalsCfg memory e) {
        e.usdg = json.readAddress(".external.usdg");
        e.usdgUsdFeed = json.readAddress(".external.usdgUsdFeed");
        e.sequencerFeed = json.readAddress(".external.sequencerFeed");
        e.priceSourcePlaceholder = json.readAddress(".external.priceSourcePlaceholder");
    }

    function _readToken(string memory json) private pure returns (TokenCfg memory t) {
        t.deploy = json.readBool(".token.deploy");
        t.emissionsDuration = uint64(json.readUint(".token.emissionsDuration"));
        t.sanityLow8 = json.readUint(".token.sanityLow8");
        t.sanityHigh8 = json.readUint(".token.sanityHigh8");
    }

    function _readVault(string memory json, uint256 i, address sequencerFeed) private pure returns (VaultCfg memory v) {
        string memory p = string.concat(".vaults[", vm.toString(i), "]");
        v.symbol = json.readString(string.concat(p, ".symbol"));
        v.name = json.readString(string.concat(p, ".name"));
        v.shareSymbol = json.readString(string.concat(p, ".shareSymbol"));
        v.stock = json.readAddress(string.concat(p, ".stock"));
        v.feed = json.readAddress(string.concat(p, ".feed"));
        v.pool = json.readAddress(string.concat(p, ".pool"));
        v.capUSD = json.readUint(string.concat(p, ".capUSD"));
        v.feeBps = uint16(json.readUint(string.concat(p, ".feeBps")));
        v.minStrikeWeekday = uint16(json.readUint(string.concat(p, ".minStrikeDistanceBpsWeekday")));
        v.minStrikeWeekend = uint16(json.readUint(string.concat(p, ".minStrikeDistanceBpsWeekend")));
        v.minReserveWeekday = uint16(json.readUint(string.concat(p, ".minReserveBpsOfSpotWeekday")));
        v.minReserveWeekend = uint16(json.readUint(string.concat(p, ".minReserveBpsOfSpotWeekend")));
        v.mock = _readMock(json, p);
        v.params = _readParams(json, p, sequencerFeed);
    }

    function _readMock(string memory json, string memory p) private pure returns (MockCfg memory m) {
        m.tokenName = json.readString(string.concat(p, ".mock.tokenName"));
        m.stockIsToken0 = json.readBool(string.concat(p, ".mock.stockIsToken0"));
        m.price8 = json.readUint(string.concat(p, ".mock.price8"));
        m.liquidity = uint128(json.readUint(string.concat(p, ".mock.liquidity")));
    }

    /// @dev `sequencerFeed` lives once under `external` rather than being repeated per vault, and is copied
    /// into every vault's parameter version here.
    function _readParams(string memory json, string memory p, address sequencerFeed)
        private
        pure
        returns (OracleParams memory o)
    {
        string memory q = string.concat(p, ".oracleParams");
        o.weekdayMaxStale = uint32(json.readUint(string.concat(q, ".weekdayMaxStale")));
        o.twapGrace = uint32(json.readUint(string.concat(q, ".twapGrace")));
        o.sequencerGrace = uint32(json.readUint(string.concat(q, ".sequencerGrace")));
        o.usdgMaxStale = uint32(json.readUint(string.concat(q, ".usdgMaxStale")));
        o.weekendTwapBoundBps = uint16(json.readUint(string.concat(q, ".weekendTwapBoundBps")));
        o.weekdayTwapBoundBps = uint16(json.readUint(string.concat(q, ".weekdayTwapBoundBps")));
        o.impactBps = uint16(json.readUint(string.concat(q, ".impactBps")));
        o.jumpBps = uint16(json.readUint(string.concat(q, ".jumpBps")));
        o.usdgBandLowBps = uint16(json.readUint(string.concat(q, ".usdgBandLowBps")));
        o.usdgBandHighBps = uint16(json.readUint(string.concat(q, ".usdgBandHighBps")));
        o.minObservationsInWindow = uint8(json.readUint(string.concat(q, ".minObservationsInWindow")));
        o.swapNotionalUSDG = uint128(json.readUint(string.concat(q, ".swapNotionalUSDG")));
        o.sequencerFeed = sequencerFeed;
    }

    // ───────────────────────────── validate ─────────────────────────────

    /// @notice Fails on anything the contracts would reject, plus the governance addresses a live chain must
    /// have. `mocked` says whether this chain may fill its external addresses with mocks; when it is false
    /// every external and per-vault address must already be real.
    function validate(DeployConfig memory c, bool mocked) internal pure {
        if (c.vaults.length == 0) revert NoVaults();
        if (c.gov.admin == address(0)) revert MissingAddress("governance.admin");
        if (c.gov.treasury == address(0)) revert MissingAddress("governance.treasury");
        if (c.gov.keeper == address(0)) revert MissingAddress("governance.keeper");
        if (c.gov.guardians.length == 0) revert MissingAddress("governance.guardians");
        for (uint256 i; i < c.gov.guardians.length; ++i) {
            if (c.gov.guardians[i] == address(0)) revert MissingAddress("governance.guardians[]");
        }
        if (c.ext.priceSourcePlaceholder == address(0)) revert MissingAddress("external.priceSourcePlaceholder");
        if (c.chainId == 4663) _validateMainnetGovernance(c);
        if (!mocked) {
            if (c.ext.usdg == address(0)) revert MissingAddress("external.usdg");
            if (c.ext.usdgUsdFeed == address(0)) revert MissingAddress("external.usdgUsdFeed");
        }
        _validateToken(c.token);
        for (uint256 i; i < c.vaults.length; ++i) {
            _validateVault(c.vaults[i], mocked);
            for (uint256 j; j < i; ++j) {
                // `OptionToken.registerVault` is one vault per underlying and irreversible.
                if (c.vaults[j].stock != address(0) && c.vaults[j].stock == c.vaults[i].stock) {
                    revert DuplicateStock(c.vaults[i].stock);
                }
            }
        }
    }

    /// @dev SPEC §15 / D-003 / D-029 pinned in code, not left to the operator's edit of the JSON (audit C-1): a 48 h
    /// delay, no deployer-as-admin deviation, exactly two guardian holders, and four pairwise-distinct keys.
    function _validateMainnetGovernance(DeployConfig memory c) private pure {
        if (c.gov.timelockMinDelay < 48 hours) revert MainnetGovernance("timelockMinDelay < 48h");
        if (c.gov.deployerIsAdmin) revert MainnetGovernance("deployerIsAdmin");
        if (c.gov.guardians.length != 2) revert MainnetGovernance("guardians != 2");
        address[4] memory keys = [c.gov.admin, c.gov.keeper, c.gov.guardians[0], c.gov.guardians[1]];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < i; ++j) {
                if (keys[i] == keys[j]) revert MainnetGovernance("admin, keeper and guardians must be distinct");
            }
        }
        if (c.gov.treasury == c.gov.keeper) revert MainnetGovernance("treasury == keeper");
    }

    function _validateToken(TokenCfg memory t) private pure {
        if (!t.deploy) return;
        // `WritePriceOracle.setSanityBand` and `EmissionsController`'s duration bound.
        if (t.sanityLow8 == 0 || t.sanityLow8 >= t.sanityHigh8) revert OutOfBounds("token.sanityLow8", t.sanityLow8);
        if (t.emissionsDuration < 365 days || t.emissionsDuration > 3650 days) {
            revert OutOfBounds("token.emissionsDuration", t.emissionsDuration);
        }
    }

    function _validateVault(VaultCfg memory v, bool mocked) private pure {
        if (!mocked) {
            if (v.stock == address(0)) revert MissingAddress("vaults[].stock");
            if (v.feed == address(0)) revert MissingAddress("vaults[].feed");
            if (v.pool == address(0)) revert MissingAddress("vaults[].pool");
        } else if (v.stock == address(0) && v.mock.price8 == 0) {
            revert OutOfBounds("vaults[].mock.price8", 0);
        }
        // FeeRouter.MAX_FEE_BPS and the AuctionHouse strike / reserve bounds (SPEC §7.2, §8.3, §11).
        if (v.feeBps > 2000) revert OutOfBounds("vaults[].feeBps", v.feeBps);
        if (v.minStrikeWeekday < 300 || v.minStrikeWeekday > 1500) {
            revert OutOfBounds("vaults[].minStrikeDistanceBpsWeekday", v.minStrikeWeekday);
        }
        if (v.minStrikeWeekend < 100 || v.minStrikeWeekend > 1000) {
            revert OutOfBounds("vaults[].minStrikeDistanceBpsWeekend", v.minStrikeWeekend);
        }
        if (v.minReserveWeekday < 1 || v.minReserveWeekday > 500) {
            revert OutOfBounds("vaults[].minReserveBpsOfSpotWeekday", v.minReserveWeekday);
        }
        if (v.minReserveWeekend < 1 || v.minReserveWeekend > 500) {
            revert OutOfBounds("vaults[].minReserveBpsOfSpotWeekend", v.minReserveWeekend);
        }
        _validateParams(v.params);
    }

    /// @dev The bounds of `RiskModule._validate`, repeated so a bad value fails before broadcasting.
    function _validateParams(OracleParams memory o) private pure {
        if (o.weekdayMaxStale < 3600 || o.weekdayMaxStale > 108_000) {
            revert OutOfBounds("weekdayMaxStale", o.weekdayMaxStale);
        }
        if (o.twapGrace < 300 || o.twapGrace > 3600) revert OutOfBounds("twapGrace", o.twapGrace);
        if (o.sequencerGrace < 600 || o.sequencerGrace > 86_400) {
            revert OutOfBounds("sequencerGrace", o.sequencerGrace);
        }
        if (o.usdgMaxStale < 3600 || o.usdgMaxStale > 288_000) revert OutOfBounds("usdgMaxStale", o.usdgMaxStale);
        if (o.weekendTwapBoundBps < 300 || o.weekendTwapBoundBps > 1500) {
            revert OutOfBounds("weekendTwapBoundBps", o.weekendTwapBoundBps);
        }
        if (o.weekdayTwapBoundBps < 100 || o.weekdayTwapBoundBps > 500) {
            revert OutOfBounds("weekdayTwapBoundBps", o.weekdayTwapBoundBps);
        }
        if (o.impactBps < 10 || o.impactBps > 500) revert OutOfBounds("impactBps", o.impactBps);
        if (o.jumpBps < 1000 || o.jumpBps > 5000) revert OutOfBounds("jumpBps", o.jumpBps);
        if (o.usdgBandLowBps < 9000 || o.usdgBandLowBps > 9999) {
            revert OutOfBounds("usdgBandLowBps", o.usdgBandLowBps);
        }
        if (o.usdgBandHighBps < 10_001 || o.usdgBandHighBps > 11_000) {
            revert OutOfBounds("usdgBandHighBps", o.usdgBandHighBps);
        }
        if (o.minObservationsInWindow < 1 || o.minObservationsInWindow > 16) {
            revert OutOfBounds("minObservationsInWindow", o.minObservationsInWindow);
        }
        if (o.swapNotionalUSDG < 10_000e6 || o.swapNotionalUSDG > 10_000_000e6) {
            revert OutOfBounds("swapNotionalUSDG", o.swapNotionalUSDG);
        }
    }
}
