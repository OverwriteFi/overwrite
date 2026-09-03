// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Performance-fee sink (SPEC §11, D-023). `collect` only books an internal balance; forwarding to the
/// treasury is the separate permissionless `flush`, so no fee-side revert can block `AuctionHouse.clear`.
interface IFeeRouter {
    enum FeeMode {
        USDG,
        WRITE
    }

    function feeBps(address vault) external view returns (uint16);
    function pending(address vault) external view returns (uint256);
    function mode(address vault) external view returns (FeeMode);
    function treasury() external view returns (address);
    function writeBalance(address vault) external view returns (uint256);

    function initVault(address vault) external;
    function collect(address vault, uint256 seriesId, uint256 amount) external;
    function flush(address vault) external returns (uint256 amount);
}
