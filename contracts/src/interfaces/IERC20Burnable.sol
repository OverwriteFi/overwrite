// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The burn surface of WRITE (OpenZeppelin `ERC20Burnable`), used by the FeeRouter WRITE fee path to
/// destroy its burn share (SPEC §11, D-011). Declared here so consumers need not import the full token.
interface IERC20Burnable {
    function burn(uint256 value) external;
}
