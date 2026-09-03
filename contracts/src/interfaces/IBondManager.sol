// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Curator and market-maker bonds (SPEC §13, D-030). Locks are by participation: the AuctionHouse
/// locks a bidder's bond on its first bid in a series and releases it at clear (no fill) or after settlement.
interface IBondManager {
    enum BondKind {
        CURATOR,
        MM
    }

    function hasActiveMMBond(address account) external view returns (bool);
    function activeLocks(address account) external view returns (uint256);
    function isLocked(address account, uint256 seriesId) external view returns (bool);
    function requiredAmount(BondKind kind) external view returns (uint256);
    function status(address account, BondKind kind)
        external
        view
        returns (uint256 amount, address asset, uint64 unlockAt);

    function postBond(BondKind kind) external returns (uint256 posted);
    function requestWithdraw(BondKind kind) external returns (uint64 unlockAt);
    function cancelWithdraw(BondKind kind) external;
    function withdrawBond(BondKind kind) external returns (uint256 amount);

    function lock(address holder, uint256 seriesId) external;
    function unlock(address holder, uint256 seriesId) external;
}
