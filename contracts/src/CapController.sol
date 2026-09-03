// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICapController} from "./interfaces/ICapController.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {ISafetyModule} from "./interfaces/ISafetyModule.sol";

/// @title CapController
/// @notice Deposit caps (SPEC §12, CLAUDE.md rule 6). Two modes behind a timelocked switch:
///  - FIXED: `capUSD[vault]` (6-dec USD) per vault, launch value 25 000 USDG (D-011).
///  - SAFETY_MODULE: `globalCap = k × safetyModule.valueUSD()`, per-vault share `capWeightBps`,
///    optionally still ceilinged by `capUSD[vault]`.
/// Caps limit deposits only; they never force withdrawals.
contract CapController is Ownable2Step, ICapController {
    enum CapMode {
        FIXED,
        SAFETY_MODULE
    }

    uint256 public constant K_MIN = 1e18;
    uint256 public constant K_MAX = 20e18;
    uint256 public constant BPS = 1e4;

    CapMode public capMode;
    IPriceSource public priceSource;
    ISafetyModule public safetyModule;
    uint256 public k = 5e18; // WAD, D-011
    uint256 public totalWeightBps;
    mapping(address vault => uint256) public capUSD; // 6 dec
    mapping(address vault => uint256) public capWeightBps;

    error ZeroAddress();
    error OutOfBounds();
    error SafetyModuleNotSet();
    error WeightsExceedTotal();

    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    constructor(address owner_, address priceSource_) Ownable(owner_) {
        if (priceSource_ == address(0)) revert ZeroAddress();
        priceSource = IPriceSource(priceSource_);
    }

    // ───────────────────────────── timelock setters ─────────────────────────────

    /// @dev Temporary exception to "all cross-contract references are immutable" (D-039): the real
    /// price source is SettlementOracle, which does not exist yet.
    function setPriceSource(address src) external onlyOwner {
        if (src == address(0)) revert ZeroAddress();
        emit ParameterChanged(address(this), "priceSource", uint160(address(priceSource)), uint160(src));
        priceSource = IPriceSource(src);
    }

    /// @dev Clearing the module while SAFETY_MODULE mode is active would make every cap read revert
    /// (blocking deposits, queue processing, `openSeries`); switch to FIXED first.
    function setSafetyModule(address sm) external onlyOwner {
        if (sm == address(0) && capMode == CapMode.SAFETY_MODULE) revert SafetyModuleNotSet();
        emit ParameterChanged(address(this), "safetyModule", uint160(address(safetyModule)), uint160(sm));
        safetyModule = ISafetyModule(sm);
    }

    function setCapMode(CapMode mode) external onlyOwner {
        if (mode == CapMode.SAFETY_MODULE && address(safetyModule) == address(0)) revert SafetyModuleNotSet();
        emit ParameterChanged(address(this), "capMode", uint256(capMode), uint256(mode));
        capMode = mode;
    }

    function setK(uint256 k_) external onlyOwner {
        if (k_ < K_MIN || k_ > K_MAX) revert OutOfBounds();
        emit ParameterChanged(address(this), "k", k, k_);
        k = k_;
    }

    function setCapUSD(address vault, uint256 usd6) external onlyOwner {
        emit ParameterChanged(vault, "capUSD", capUSD[vault], usd6);
        capUSD[vault] = usd6;
    }

    function setCapWeightBps(address vault, uint256 bps) external onlyOwner {
        uint256 old = capWeightBps[vault];
        uint256 newTotal = totalWeightBps - old + bps;
        if (newTotal > BPS) revert WeightsExceedTotal();
        totalWeightBps = newTotal;
        capWeightBps[vault] = bps;
        emit ParameterChanged(vault, "capWeightBps", old, bps);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice Effective USD cap (6 dec) for a vault under the current mode. In FIXED mode `capUSD == 0`
    /// means "no deposits"; in SAFETY_MODULE mode it means "no extra ceiling" (the weight alone applies).
    function vaultCapUSD(address vault) public view returns (uint256) {
        if (capMode == CapMode.FIXED) return capUSD[vault];
        uint256 globalCap = Math.mulDiv(safetyModule.valueUSD(), k, 1e18);
        uint256 cap = Math.mulDiv(globalCap, capWeightBps[vault], BPS);
        uint256 ceiling = capUSD[vault];
        if (ceiling != 0 && ceiling < cap) cap = ceiling;
        return cap;
    }

    /// @inheritdoc ICapController
    /// @dev SPEC §12: `(totalAssets + assets) × S_cap / 1e18 ≤ capUSD × 1e2`, rearranged to raw units, floored.
    function remainingDepositAssets(address vault, uint256 totalAssets)
        external
        view
        returns (uint256 assets, bool priceOk)
    {
        (uint256 price8, bool ok) = priceSource.capPrice(vault);
        if (!ok || price8 == 0) return (0, false);
        uint256 cap6 = vaultCapUSD(vault);
        // usedUSD6 = totalAssets(18 dec) × price8 / 1e18 / 1e2, rounded UP so the cap can never be exceeded by dust
        uint256 used6 = Math.mulDiv(totalAssets, price8, 1e20, Math.Rounding.Ceil);
        if (used6 >= cap6) return (0, true);
        assets = Math.mulDiv(cap6 - used6, 1e20, price8);
        return (assets, true);
    }
}
