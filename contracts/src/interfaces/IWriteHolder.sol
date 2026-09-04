// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Implemented by every contract WRITE mints into at genesis (SPEC §14, D-059, D-061).
/// `WRITE`'s constructor calls `allocation()` on each recipient and requires it to match the constant
/// it is about to mint, which makes "never into an EOA" structural: an EOA has no such function.
interface IWriteHolder {
    /// @return The exact amount of WRITE this contract is minted at genesis, 18 decimals.
    function allocation() external view returns (uint256);

    /// @notice One-shot wiring after the token exists (D-044, D-060).
    function setWriteToken(address write_) external;
}
