// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SeriesKind, SeriesState, VaultState} from "../Types.sol";
import {IOptionToken} from "./IOptionToken.sol";

/// @notice Vault surface used by AuctionHouse, SettlementOracle and OptionToken (SPEC §3, §4).
interface ICoveredCallVault {
    struct VaultSeries {
        SeriesKind kind;
        SeriesState state;
        uint8 settlementPath; // SPEC §6: 1 CL at/before expiry, 2 TWAP, 3 CL first-after, 4 timelock, 5 permissionless
        uint64 expiry;
        uint128 strike;
        uint128 offeredQty;
        uint128 filledQty;
        uint128 mintedQty;
        uint128 claimedQty;
        uint128 settlementPrice;
        uint128 payoutPerOption;
        uint256 multiplierAtOpen;
    }

    // AuctionHouse
    function openSeries(SeriesKind kind, uint128 strike, uint64 expiry)
        external
        returns (uint256 seriesId, uint256 offeredQty);
    function skipSeries(uint256 seriesId) external;
    function mintSeries(uint256 seriesId, uint256 filledQty, uint256 premiumNet) external;
    function mintOptions(uint256 seriesId, address to, uint256 qty) external;

    // SettlementOracle
    function settleSeries(uint256 seriesId, uint128 price8, uint8 path) external;
    function haltSeries(uint256 seriesId, bytes32 reason) external;

    // OptionToken
    function payOptionClaim(uint256 seriesId, address to, uint256 qty) external returns (uint256 tokens);

    // Views
    function auctionHouse() external view returns (address);
    function optionToken() external view returns (IOptionToken);
    function usdg() external view returns (IERC20);
    function state() external view returns (VaultState);
    function currentSeriesId() external view returns (uint256);
    function series(uint256 seriesId) external view returns (VaultSeries memory);
    function encumbered() external view returns (uint256);
    function freeAssets() external view returns (uint256);
    function payoutOwed() external view returns (uint256);
    function sunset() external view returns (bool);
    function canOpenAuction(uint64 expiry) external view returns (bool ok, bytes32 reason);
}
