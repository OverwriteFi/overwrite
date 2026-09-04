// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Linear WRITE emissions to a single sink, the SafetyModule (SPEC §14, D-074, D-076).
/// Emissions are PULLED by the sink, never pushed: the stake asset is also the reward asset, so a push
/// would force `balanceOf`-based reward accounting and let a slash silently consume unclaimed rewards.
interface IEmissionsController {
    function writeToken() external view returns (address);
    function sink() external view returns (address);
    function rate() external view returns (uint256);
    function startTime() external view returns (uint64);
    function endTime() external view returns (uint64);
    function lastAccrual() external view returns (uint64);
    function released() external view returns (uint256);

    /// @notice WRITE accrued since `lastAccrual`, capped at `endTime` and at the undistributed balance.
    function accrued() external view returns (uint256);

    /// @notice Transfers `accrued()` to the sink and advances the checkpoint. Sink only.
    function claim() external returns (uint256 amount);
}

/// @notice Reverse wiring assert used by `EmissionsController.setSink` (D-080): the candidate sink must
/// already point back at this controller and at the same token.
interface ISafetyModuleWiring {
    function emissions() external view returns (address);
    function writeToken() external view returns (address);
}
