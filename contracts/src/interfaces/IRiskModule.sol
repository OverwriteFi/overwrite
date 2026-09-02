// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Guardian pause flags read by the vault (SPEC §15). Pauses never block withdrawals.
interface IRiskModule {
    function depositsPaused(address vault) external view returns (bool);
    function auctionsPaused(address vault) external view returns (bool);
}
