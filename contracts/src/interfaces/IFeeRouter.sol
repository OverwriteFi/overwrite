// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Performance-fee sink (SPEC §11, D-023, D-049). `collect` only books an internal balance while the
/// USDG stays in the AuctionHouse; the permissionless `flush` pulls it to the treasury — or, in WRITE mode,
/// runs the WRITE conversion and rebates the USDG to the curator — so no fee-side transfer can block
/// `AuctionHouse.clear`.
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

    function writeToken() external view returns (address);
    function priceOracle() external view returns (address);
    function curatorOf(address vault) external view returns (address);
    function writeDiscountBps() external view returns (uint16);
    function writeBurnShareBps() external view returns (uint16);
    /// @notice The curator's prefunded WRITE credited to `vault`, drawn down by the WRITE fee path.
    function writeBalance(address vault) external view returns (uint256);

    function initVault(address vault) external;
    function collect(address vault, uint256 seriesId, uint256 amount) external;
    function flush(address vault) external returns (uint256 amount);

    function depositWrite(address vault, uint256 amount) external;
    function withdrawWrite(address vault, uint256 amount) external;
}
