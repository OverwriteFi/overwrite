// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SeriesKind} from "../Types.sol";

/// @notice ERC-1155 option token, one id per series (SPEC §3, §6). Only the vault of the underlying mints/burns.
interface IOptionToken {
    struct SeriesInfo {
        address vault;
        address underlying;
        SeriesKind kind;
        bool settled;
        uint64 expiry;
        uint128 strike; // USD 8 dec per raw token (PER_TOKEN, SPEC §10.2)
        uint128 settlementPrice; // USD 8 dec, 0 until settled
        uint128 payoutPerOption; // raw token units per 1e18 options, < 1e18
        uint256 multiplierAtCreation; // uiMultiplier() snapshot, indexers only (SPEC §10.3)
    }

    function vaultOf(address underlying) external view returns (address);
    function isVault(address vault) external view returns (bool);
    function series(uint256 id) external view returns (SeriesInfo memory);
    function nextSeriesId() external view returns (uint256);

    function create(address underlying, SeriesKind kind, uint128 strike, uint64 expiry, uint256 multiplier)
        external
        returns (uint256 id);
    function mint(uint256 id, address to, uint256 qty) external;
    function burn(uint256 id, address from, uint256 qty) external;
    function markSettled(uint256 id, uint128 settlementPrice, uint128 payoutPerOption) external;
    function raisePayout(uint256 id, uint128 payoutPerOption) external;
    function claim(uint256 id, uint256 qty, address to) external returns (uint256 tokens);
}
