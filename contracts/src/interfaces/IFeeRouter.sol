// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Performance-fee sink (SPEC §11, D-023, D-049). `collect` only books an internal balance while the
/// USDG stays in the AuctionHouse; the permissionless `flush` pulls it to the treasury, so no fee-side transfer
/// can block `AuctionHouse.clear`.
interface IFeeRouter {
    enum FeeMode {
        USDG,
        WRITE
    }

    function usdg() external view returns (IERC20);
    function auctionHouse() external view returns (address);
    function feeBps(address vault) external view returns (uint16);
    function pending(address vault) external view returns (uint256);
    function mode(address vault) external view returns (FeeMode);
    function treasury() external view returns (address);
    function writeBalance(address vault) external view returns (uint256);

    function initVault(address vault) external;
    function collect(address vault, uint256 seriesId, uint256 amount) external;
    function flush(address vault) external returns (uint256 amount);
}
