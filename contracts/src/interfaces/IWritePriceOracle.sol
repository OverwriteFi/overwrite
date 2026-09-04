// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Governance-configured WRITE/USD source shared by SafetyModule and FeeRouter (D-064, D-065).
/// Every view follows `IPriceSource.capPrice`'s never-reverting `(value, ok)` shape: a bad or missing
/// source is reported, never thrown, so no consumer has to wrap the call in a try/catch.
/// Rounding lives here (D-065), so no consumer repeats the 18/8/6-decimal bridge.
interface IWritePriceOracle {
    /// @notice Source that produced the last quote: 0 = none, 1 = Chainlink, 2 = pool TWAP.
    function writeToken() external view returns (address);

    /// @return price8 USD per WRITE, 8 decimals. @return ok false when no source qualifies.
    function writePrice() external view returns (uint256 price8, bool ok);

    /// @notice USD value of `writeWei` WRITE, 6 decimals, rounded DOWN (conservative for a deposit cap).
    function usdValueOfWrite(uint256 writeWei) external view returns (uint256 usd6, bool ok);

    /// @notice WRITE needed to pay `usd6` USD, 18 decimals, rounded UP (the protocol's favour).
    function writeForUSD(uint256 usd6) external view returns (uint256 writeWei, bool ok);

    /// @notice Diagnostic twin of `writePrice`: why a quote failed and which source answered.
    function previewPrice() external view returns (uint256 price8, bytes32 reason, uint8 source);
}
