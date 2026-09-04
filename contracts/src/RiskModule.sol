// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRiskModule} from "./interfaces/IRiskModule.sol";
import {OracleParams} from "./Types.sol";

/// @title RiskModule
/// @notice Pause registry, halt registry, guardian role and versioned oracle parameters (SPEC §6, §9.6, §15;
/// D-005, D-012, D-029, D-031, D-050). The owner is the 48 h timelock: it sets parameters and guardians. The
/// two guardian keys can only pause and unpause new auctions and deposits, with no delay (invariant I-7: a
/// guardian call writes nothing but pause flags). Pauses never block withdrawals, claims, settlement or
/// resolution — the vault only reads `depositsPaused` / `auctionsPaused`.
/// Parameters are append-only versions per vault; `paramsAt(vault, auctionOpen)` selects the version in effect
/// when a series opened, so a change never touches a live series (D-031, THREAT-MODEL T-14).
contract RiskModule is Ownable2Step, AccessControl, IRiskModule {
    // ───────────────────────────── constants ─────────────────────────────

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Sentinel for "every vault" in the pause functions (SPEC §15).
    address public constant ALL = address(0);

    // Protocol bounds (SPEC §15: constants, not parameters; D-056 for the ones the SPEC left unstated).
    uint32 public constant WEEKDAY_MAX_STALE_MIN = 3_600;
    uint32 public constant WEEKDAY_MAX_STALE_MAX = 108_000; // 30 h
    uint32 public constant TWAP_GRACE_MIN = 300;
    uint32 public constant TWAP_GRACE_MAX = 3_600;
    uint16 public constant WEEKEND_TWAP_BOUND_MIN = 300;
    uint16 public constant WEEKEND_TWAP_BOUND_MAX = 1_500;
    uint16 public constant WEEKDAY_TWAP_BOUND_MIN = 100;
    uint16 public constant WEEKDAY_TWAP_BOUND_MAX = 500;
    uint128 public constant SWAP_NOTIONAL_MIN = 10_000e6;
    uint128 public constant SWAP_NOTIONAL_MAX = 10_000_000e6;
    uint16 public constant IMPACT_MIN = 10;
    uint16 public constant IMPACT_MAX = 500;
    uint8 public constant MIN_OBS_MIN = 1;
    uint8 public constant MIN_OBS_MAX = 16;
    uint16 public constant JUMP_MIN = 1_000;
    uint16 public constant JUMP_MAX = 5_000;
    uint32 public constant SEQUENCER_GRACE_MIN = 600;
    uint32 public constant SEQUENCER_GRACE_MAX = 86_400;
    uint16 public constant USDG_LOW_MIN = 9_000;
    uint16 public constant USDG_LOW_MAX = 9_999;
    uint16 public constant USDG_HIGH_MIN = 10_001;
    uint16 public constant USDG_HIGH_MAX = 11_000;
    uint32 public constant USDG_MAX_STALE_MIN = 3_600;
    uint32 public constant USDG_MAX_STALE_MAX = 288_000; // 80 h (THREAT-MODEL T-12.5)

    // ───────────────────────────── types ─────────────────────────────

    struct ParamsVersion {
        uint64 effectiveFrom;
        OracleParams params;
    }

    struct HaltRecord {
        uint256 seriesId;
        bytes32 reason;
        uint64 haltedAt;
    }

    // ───────────────────────────── storage ─────────────────────────────

    address public settlementOracle;
    bool public allDepositsPaused;
    bool public allAuctionsPaused;
    mapping(address vault => bool) public vaultDepositsPaused;
    mapping(address vault => bool) public vaultAuctionsPaused;
    mapping(address vault => ParamsVersion[]) internal _versions;
    mapping(address vault => HaltRecord) public lastHalt;
    mapping(address vault => uint256) public haltCount;

    // ───────────────────────────── errors / events ─────────────────────────────

    error ZeroAddress();
    error AlreadySet();
    error NotSettlementOracle();
    error NotGuardian();
    error OutOfBounds(bytes32 key);
    error RenounceDisabled();

    event Paused(address indexed vault, bytes32 indexed what, address indexed by);
    event Unpaused(address indexed vault, bytes32 indexed what, address indexed by);
    event VaultHalted(address indexed vault, uint256 indexed seriesId, bytes32 reason);
    event OracleParamsSet(address indexed vault, uint256 indexed version, uint64 effectiveFrom, OracleParams params);
    event SettlementOracleSet(address indexed oracle);

    constructor(address owner_) Ownable(owner_) {}

    // ───────────────────────────── modifiers ─────────────────────────────

    modifier onlyGuardianOrOwner() {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && msg.sender != owner()) revert NotGuardian();
        _;
    }

    modifier onlySettlementOracle() {
        if (msg.sender != settlementOracle) revert NotSettlementOracle();
        _;
    }

    // ═════════════════════════════ guardian (no delay) ═════════════════════════════

    /// @notice Pause deposits on `vault` or on every vault (`ALL`). Idempotent; either guardian or the owner.
    function pauseDeposits(address vault) external onlyGuardianOrOwner {
        if (vault == ALL) allDepositsPaused = true;
        else vaultDepositsPaused[vault] = true;
        emit Paused(vault, "DEPOSITS", msg.sender);
    }

    function unpauseDeposits(address vault) external onlyGuardianOrOwner {
        if (vault == ALL) allDepositsPaused = false;
        else vaultDepositsPaused[vault] = false;
        emit Unpaused(vault, "DEPOSITS", msg.sender);
    }

    /// @notice Pause new auctions on `vault` or on every vault (`ALL`). Live series still settle (SPEC §15).
    function pauseNewAuctions(address vault) external onlyGuardianOrOwner {
        if (vault == ALL) allAuctionsPaused = true;
        else vaultAuctionsPaused[vault] = true;
        emit Paused(vault, "AUCTIONS", msg.sender);
    }

    function unpauseNewAuctions(address vault) external onlyGuardianOrOwner {
        if (vault == ALL) allAuctionsPaused = false;
        else vaultAuctionsPaused[vault] = false;
        emit Unpaused(vault, "AUCTIONS", msg.sender);
    }

    // ═════════════════════════════ settlement oracle ═════════════════════════════

    /// @inheritdoc IRiskModule
    /// @dev Lifted by a normal `unpauseNewAuctions` once the halt has been reviewed (SPEC §9.6).
    function pauseNewAuctionsOnHalt(address vault, uint256 seriesId, bytes32 reason) external onlySettlementOracle {
        vaultAuctionsPaused[vault] = true;
        lastHalt[vault] = HaltRecord({seriesId: seriesId, reason: reason, haltedAt: uint64(block.timestamp)});
        haltCount[vault] += 1;
        emit Paused(vault, "AUCTIONS", msg.sender);
        emit VaultHalted(vault, seriesId, reason);
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice Set once (D-044 pattern): the oracle is deployed after the RiskModule because it holds this
    /// address as an immutable.
    function setSettlementOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        if (settlementOracle != address(0)) revert AlreadySet();
        settlementOracle = oracle;
        emit SettlementOracleSet(oracle);
    }

    /// @notice Grant or revoke `GUARDIAN_ROLE` (D-029: two holders). No account holds `DEFAULT_ADMIN_ROLE`.
    function setGuardian(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (enabled) _grantRole(GUARDIAN_ROLE, account);
        else _revokeRole(GUARDIAN_ROLE, account);
    }

    /// @notice Append a parameter version for `vault`, effective for series whose auction opens strictly after this
    /// second (D-031, D-053): a series opened in the same block keeps the previous version (invariant I-12).
    function setOracleParams(address vault, OracleParams calldata p) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        _validate(p);
        uint64 from = uint64(block.timestamp) + 1;
        _versions[vault].push(ParamsVersion({effectiveFrom: from, params: p}));
        emit OracleParamsSet(vault, _versions[vault].length - 1, from, p);
    }

    /// @notice Disabled: the owner is the timelock and the parameter setters must stay reachable (CLAUDE.md rule 5,
    /// D-057).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc IRiskModule
    function depositsPaused(address vault) external view returns (bool) {
        return allDepositsPaused || vaultDepositsPaused[vault];
    }

    /// @inheritdoc IRiskModule
    function auctionsPaused(address vault) external view returns (bool) {
        return allAuctionsPaused || vaultAuctionsPaused[vault];
    }

    /// @inheritdoc IRiskModule
    /// @dev Linear scan from the newest version: versions are appended only by the timelock, so the array is short.
    function paramsAt(address vault, uint64 timestamp) public view returns (OracleParams memory) {
        ParamsVersion[] storage vs = _versions[vault];
        for (uint256 i = vs.length; i > 0; --i) {
            if (vs[i - 1].effectiveFrom <= timestamp) return vs[i - 1].params;
        }
        return defaultParams();
    }

    /// @inheritdoc IRiskModule
    /// @dev Parameters a series opened in the next block would get (a version set in this block is included).
    function currentParams(address vault) external view returns (OracleParams memory) {
        return paramsAt(vault, uint64(block.timestamp) + 1);
    }

    function versionCount(address vault) external view returns (uint256) {
        return _versions[vault].length;
    }

    function versionAt(address vault, uint256 index) external view returns (ParamsVersion memory) {
        return _versions[vault][index];
    }

    /// @notice Protocol defaults (SPEC §9; D-001, D-005, D-010, D-015, D-017, D-019, D-025).
    function defaultParams() public pure returns (OracleParams memory p) {
        p.weekdayMaxStale = 93_600;
        p.twapGrace = 1_800;
        p.sequencerGrace = 3_600;
        p.usdgMaxStale = 93_600;
        p.weekendTwapBoundBps = 1_500;
        p.weekdayTwapBoundBps = 300;
        p.impactBps = 100;
        p.jumpBps = 3_000;
        p.usdgBandLowBps = 9_800;
        p.usdgBandHighBps = 10_200;
        p.minObservationsInWindow = 3;
        p.swapNotionalUSDG = 250_000e6;
        p.sequencerFeed = address(0);
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _validate(OracleParams calldata p) internal pure {
        if (p.weekdayMaxStale < WEEKDAY_MAX_STALE_MIN || p.weekdayMaxStale > WEEKDAY_MAX_STALE_MAX) {
            revert OutOfBounds("weekdayMaxStale");
        }
        if (p.twapGrace < TWAP_GRACE_MIN || p.twapGrace > TWAP_GRACE_MAX) revert OutOfBounds("twapGrace");
        if (p.weekendTwapBoundBps < WEEKEND_TWAP_BOUND_MIN || p.weekendTwapBoundBps > WEEKEND_TWAP_BOUND_MAX) {
            revert OutOfBounds("weekendTwapBoundBps");
        }
        if (p.weekdayTwapBoundBps < WEEKDAY_TWAP_BOUND_MIN || p.weekdayTwapBoundBps > WEEKDAY_TWAP_BOUND_MAX) {
            revert OutOfBounds("weekdayTwapBoundBps");
        }
        if (p.swapNotionalUSDG < SWAP_NOTIONAL_MIN || p.swapNotionalUSDG > SWAP_NOTIONAL_MAX) {
            revert OutOfBounds("swapNotionalUSDG");
        }
        if (p.impactBps < IMPACT_MIN || p.impactBps > IMPACT_MAX) revert OutOfBounds("impactBps");
        if (p.minObservationsInWindow < MIN_OBS_MIN || p.minObservationsInWindow > MIN_OBS_MAX) {
            revert OutOfBounds("minObservationsInWindow");
        }
        if (p.jumpBps < JUMP_MIN || p.jumpBps > JUMP_MAX) revert OutOfBounds("jumpBps");
        if (p.sequencerGrace < SEQUENCER_GRACE_MIN || p.sequencerGrace > SEQUENCER_GRACE_MAX) {
            revert OutOfBounds("sequencerGrace");
        }
        if (p.usdgBandLowBps < USDG_LOW_MIN || p.usdgBandLowBps > USDG_LOW_MAX) revert OutOfBounds("usdgBandLowBps");
        if (p.usdgBandHighBps < USDG_HIGH_MIN || p.usdgBandHighBps > USDG_HIGH_MAX) {
            revert OutOfBounds("usdgBandHighBps");
        }
        if (p.usdgMaxStale < USDG_MAX_STALE_MIN || p.usdgMaxStale > USDG_MAX_STALE_MAX) {
            revert OutOfBounds("usdgMaxStale");
        }
    }
}
