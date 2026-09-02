// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Post-token safety module value feed used by CapController.SAFETY_MODULE mode (SPEC §12, §14).
interface ISafetyModule {
    /// @return USD value of staked WRITE, 6 decimals
    function valueUSD() external view returns (uint256);
}
