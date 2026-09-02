// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice S_cap price provider (SPEC §12): Chainlink latest if < 80 h old, else the 30-min TWAP.
/// Implemented by SettlementOracle; mocked until it ships (D-039).
interface IPriceSource {
    /// @return price8 USD per one raw stock token, 8 decimals
    /// @return ok false when neither source is available
    function capPrice(address vault) external view returns (uint256 price8, bool ok);
}
