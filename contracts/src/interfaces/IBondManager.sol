// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Curator and market-maker bonds (SPEC §13, D-030). Locks are by participation: the AuctionHouse
/// locks a bidder's bond on its first bid in a series and releases it at clear (no fill) or after settlement.
/// Post-token the required asset migrates from USDG to WRITE with a grace period during which both satisfy
/// the requirement (D-007); a holder keeps one independent bond leg per asset, so migration can never strand
/// a posted bond.
interface IBondManager {
    enum BondKind {
        CURATOR,
        MM
    }

    /// @notice The asset a bond leg is posted in. `USDG` is the launch asset; `WRITE` arrives post-token.
    enum BondAsset {
        USDG,
        WRITE
    }

    function usdg() external view returns (IERC20);
    function writeToken() external view returns (address);
    function auctionHouse() external view returns (address);
    function bondAsset() external view returns (BondAsset);
    function previousAsset() external view returns (BondAsset);
    function migrationEndsAt() external view returns (uint64);

    /// @notice True while `account` holds a qualifying bond of `kind` in any currently accepted asset.
    function isBonded(address account, BondKind kind) external view returns (bool);
    function hasActiveMMBond(address account) external view returns (bool);
    function activeLocks(address account) external view returns (uint256);
    function isLocked(address account, uint256 seriesId) external view returns (bool);

    /// @notice Requirement for `kind` in the currently required asset.
    function requiredAmount(BondKind kind) external view returns (uint256);
    function requiredAmountOf(BondAsset asset, BondKind kind) external view returns (uint256);
    function assetToken(BondAsset asset) external view returns (address);
    function assetAccepted(BondAsset asset) external view returns (bool);

    function status(address account, BondKind kind)
        external
        view
        returns (uint256 amount, address asset, uint64 unlockAt);
    function statusIn(address account, BondKind kind, BondAsset asset)
        external
        view
        returns (uint256 amount, address token, uint64 unlockAt);

    function postBond(BondKind kind) external returns (uint256 posted);
    function requestWithdraw(BondKind kind) external returns (uint64 unlockAt);
    function cancelWithdraw(BondKind kind) external;
    function withdrawBond(BondKind kind) external returns (uint256 amount);

    function postBondIn(BondKind kind, BondAsset asset) external returns (uint256 posted);
    function requestWithdrawIn(BondKind kind, BondAsset asset) external returns (uint64 unlockAt);
    function cancelWithdrawIn(BondKind kind, BondAsset asset) external;
    function withdrawBondIn(BondKind kind, BondAsset asset) external returns (uint256 amount);

    function lock(address holder, uint256 seriesId) external;
    function unlock(address holder, uint256 seriesId) external;
}
