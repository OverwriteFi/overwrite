// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployConfig} from "./Config.sol";

struct VaultRecord {
    string symbol;
    address vault;
    address stock;
    address feed;
    address pool;
}

struct Deployed {
    uint256 chainId;
    string label;
    uint256 deployedAt;
    address deployer;
    address timelock;
    address tickMath;
    address usdg;
    address usdgUsdFeed;
    address riskModule;
    address optionToken;
    address bondManager;
    address feeRouter;
    address auctionHouse;
    address capController;
    address settlementOracle;
    VaultRecord[] vaults;
    address write;
    address liquidityEscrow;
    address emissionsController;
    address treasuryVesting;
    address teamVesting;
    address pointsDistributor;
    address writePriceOracle;
    address safetyModule;
    string[] mocked;
}

/// @title Deployment
/// @notice The address book a deployment produces: `deployments/<chainId>.json`. `script/Verify.s.sol` reads
/// it back so the verification runs standalone against a system it did not deploy, and `script/Deploy.s.sol`
/// reads it back to reuse the mocks it already deployed instead of deploying a second set.
///
/// This is the only file a deploy writes. `config/<chainId>.json` is a hand-maintained input and is never
/// written to: `vm.writeJson` cannot address an array element at all -- `.vaults[0].stock` and
/// `$.vaults[0].stock` both create a literal top-level key of that name, leaving the real entry untouched, so
/// a write-back would quietly convince the next run that nothing had been deployed.
/// @dev The JSON is assembled by string concatenation rather than `vm.serialize*`. That is a deliberate
/// trade: the file is a flat address book, hand-building it keeps the key order stable and readable in a diff,
/// and it guarantees nothing 32 bytes wide ever lands in a committed file. The repo's `.githooks/pre-commit`
/// blocks any staged file containing `0x` followed by 64 hex characters, so a transaction hash or a timelock
/// salt written here would make the deployment uncommittable.
library Deployment {
    using stdJson for string;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function path(uint256 chainId) internal pure returns (string memory) {
        return string.concat("deployments/", vm.toString(chainId), ".json");
    }

    // ───────────────────────────── write ─────────────────────────────

    function write(Deployed memory d) internal {
        vm.writeFile(path(d.chainId), string.concat(_head(d), _external(d), _core(d), _tail(d)));
    }

    /// @dev Split from `write` only because the concatenation of every section at once is stack-too-deep with
    /// `via_ir` off.
    function _head(Deployed memory d) private pure returns (string memory) {
        return string.concat(
            "{\n",
            _kv("chainId", vm.toString(d.chainId)),
            _kvs("label", d.label),
            _kv("deployedAt", vm.toString(d.deployedAt)),
            _kvs("deployer", vm.toString(d.deployer)),
            _kvs("timelock", vm.toString(d.timelock)),
            _kvs("tickMath", vm.toString(d.tickMath))
        );
    }

    function _tail(Deployed memory d) private pure returns (string memory) {
        return string.concat(
            _vaults(d),
            _token(d),
            _mocked(d),
            _kv("mockedCount", vm.toString(d.mocked.length)),
            _kv("vaultCount", vm.toString(d.vaults.length), true),
            "}\n"
        );
    }

    function _external(Deployed memory d) private pure returns (string memory) {
        return string.concat(
            '  "external": {\n',
            "  ",
            _kvs("usdg", vm.toString(d.usdg)),
            "  ",
            _kvs("usdgUsdFeed", vm.toString(d.usdgUsdFeed), true),
            "  },\n"
        );
    }

    function _core(Deployed memory d) private pure returns (string memory) {
        return string.concat(
            '  "core": {\n',
            "  ",
            _kvs("riskModule", vm.toString(d.riskModule)),
            "  ",
            _kvs("optionToken", vm.toString(d.optionToken)),
            "  ",
            _kvs("bondManager", vm.toString(d.bondManager)),
            "  ",
            _kvs("feeRouter", vm.toString(d.feeRouter)),
            "  ",
            _kvs("auctionHouse", vm.toString(d.auctionHouse)),
            "  ",
            _kvs("capController", vm.toString(d.capController)),
            "  ",
            _kvs("settlementOracle", vm.toString(d.settlementOracle), true),
            "  },\n"
        );
    }

    function _token(Deployed memory d) private pure returns (string memory) {
        return string.concat(
            '  "token": {\n',
            "  ",
            _kvs("write", vm.toString(d.write)),
            "  ",
            _kvs("liquidityEscrow", vm.toString(d.liquidityEscrow)),
            "  ",
            _kvs("emissionsController", vm.toString(d.emissionsController)),
            "  ",
            _kvs("treasuryVesting", vm.toString(d.treasuryVesting)),
            "  ",
            _kvs("teamVesting", vm.toString(d.teamVesting)),
            "  ",
            _kvs("pointsDistributor", vm.toString(d.pointsDistributor)),
            "  ",
            _kvs("writePriceOracle", vm.toString(d.writePriceOracle)),
            "  ",
            _kvs("safetyModule", vm.toString(d.safetyModule), true),
            "  },\n"
        );
    }

    function _vaults(Deployed memory d) private pure returns (string memory out) {
        out = '  "vaults": [\n';
        for (uint256 i; i < d.vaults.length; ++i) {
            VaultRecord memory v = d.vaults[i];
            out = string.concat(
                out,
                "    {",
                ' "symbol": "',
                v.symbol,
                '",',
                ' "vault": "',
                vm.toString(v.vault),
                '",',
                ' "stock": "',
                vm.toString(v.stock),
                '",',
                ' "feed": "',
                vm.toString(v.feed),
                '",',
                ' "pool": "',
                vm.toString(v.pool),
                '" }',
                i + 1 == d.vaults.length ? "\n" : ",\n"
            );
        }
        out = string.concat(out, "  ],\n");
    }

    /// @dev The literal record of what had no real deployment on this chain and was mocked instead.
    function _mocked(Deployed memory d) private pure returns (string memory out) {
        out = '  "mocked": [';
        for (uint256 i; i < d.mocked.length; ++i) {
            out = string.concat(out, i == 0 ? '"' : ', "', d.mocked[i], '"');
        }
        out = string.concat(out, "],\n");
    }

    function _kv(string memory k, string memory v) private pure returns (string memory) {
        return _kv(k, v, false);
    }

    function _kv(string memory k, string memory v, bool last) private pure returns (string memory) {
        return string.concat('  "', k, '": ', v, last ? "\n" : ",\n");
    }

    function _kvs(string memory k, string memory v) private pure returns (string memory) {
        return _kvs(k, v, false);
    }

    function _kvs(string memory k, string memory v, bool last) private pure returns (string memory) {
        return string.concat('  "', k, '": "', v, '"', last ? "\n" : ",\n");
    }

    // ───────────────────────────── read ─────────────────────────────

    function read(uint256 chainId) internal view returns (Deployed memory d) {
        string memory json = vm.readFile(path(chainId));
        d.chainId = json.readUint(".chainId");
        d.label = json.readString(".label");
        d.deployedAt = json.readUint(".deployedAt");
        d.deployer = json.readAddress(".deployer");
        d.timelock = json.readAddress(".timelock");
        d.tickMath = json.readAddress(".tickMath");
        d.usdg = json.readAddress(".external.usdg");
        d.usdgUsdFeed = json.readAddress(".external.usdgUsdFeed");
        d.riskModule = json.readAddress(".core.riskModule");
        d.optionToken = json.readAddress(".core.optionToken");
        d.bondManager = json.readAddress(".core.bondManager");
        d.feeRouter = json.readAddress(".core.feeRouter");
        d.auctionHouse = json.readAddress(".core.auctionHouse");
        d.capController = json.readAddress(".core.capController");
        d.settlementOracle = json.readAddress(".core.settlementOracle");
        _readToken(json, d);

        // `readStringArray` on an empty JSON array is not worth the risk, and the count is written for
        // exactly this reason: on a chain that mocked nothing the array is never touched.
        uint256 m = json.readUint(".mockedCount");
        d.mocked = m == 0 ? new string[](0) : json.readStringArray(".mocked");

        uint256 n = json.readUint(".vaultCount");
        d.vaults = new VaultRecord[](n);
        for (uint256 i; i < n; ++i) {
            string memory p = string.concat(".vaults[", vm.toString(i), "]");
            d.vaults[i] = VaultRecord({
                symbol: json.readString(string.concat(p, ".symbol")),
                vault: json.readAddress(string.concat(p, ".vault")),
                stock: json.readAddress(string.concat(p, ".stock")),
                feed: json.readAddress(string.concat(p, ".feed")),
                pool: json.readAddress(string.concat(p, ".pool"))
            });
        }
    }

    function _readToken(string memory json, Deployed memory d) private pure {
        d.write = json.readAddress(".token.write");
        d.liquidityEscrow = json.readAddress(".token.liquidityEscrow");
        d.emissionsController = json.readAddress(".token.emissionsController");
        d.treasuryVesting = json.readAddress(".token.treasuryVesting");
        d.teamVesting = json.readAddress(".token.teamVesting");
        d.pointsDistributor = json.readAddress(".token.pointsDistributor");
        d.writePriceOracle = json.readAddress(".token.writePriceOracle");
        d.safetyModule = json.readAddress(".token.safetyModule");
    }

    /// @notice Seeds the immutable half of the record from the config, so a caller only fills in addresses.
    function fromConfig(DeployConfig memory c, address deployer) internal view returns (Deployed memory d) {
        d.chainId = c.chainId;
        d.label = c.label;
        d.deployedAt = block.timestamp;
        d.deployer = deployer;
        d.tickMath = c.tickMath;
    }
}
