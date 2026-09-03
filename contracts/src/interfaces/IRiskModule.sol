// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleParams} from "../Types.sol";

/// @notice Guardian pause flags read by the vault (SPEC §15), the versioned oracle parameters read by
/// SettlementOracle (SPEC §6, D-031) and the halt hook (SPEC §9.6). Pauses never block withdrawals.
interface IRiskModule {
    function depositsPaused(address vault) external view returns (bool);
    function auctionsPaused(address vault) external view returns (bool);

    /// @notice Parameters in effect for a series whose auction opened at `timestamp` (latest version with
    /// `effectiveFrom <= timestamp`; protocol defaults when none).
    function paramsAt(address vault, uint64 timestamp) external view returns (OracleParams memory);
    function currentParams(address vault) external view returns (OracleParams memory);
    function settlementOracle() external view returns (address);

    /// @notice Called by SettlementOracle when a series halts (SPEC §9.6): pauses new auctions on `vault`.
    function pauseNewAuctionsOnHalt(address vault, uint256 seriesId, bytes32 reason) external;
}
