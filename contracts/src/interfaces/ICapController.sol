// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Deposit cap oracle (SPEC §12). Caps limit deposits only, never force withdrawals.
interface ICapController {
    /// @param vault the vault asking
    /// @param totalAssets that vault's current totalAssets() in raw stock units
    /// @return assets raw stock units that may still be deposited; 0 when the cap is reached
    /// @return priceOk false when no S_cap price is available (direct deposits revert, queue waits)
    function remainingDepositAssets(address vault, uint256 totalAssets)
        external
        view
        returns (uint256 assets, bool priceOk);
}
