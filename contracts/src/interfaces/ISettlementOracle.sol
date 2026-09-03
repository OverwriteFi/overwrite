// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "./IUniswapV3Pool.sol";
import {IStockToken} from "./IStockToken.sol";

/// @notice Settlement oracle surface (SPEC §9, §12, §16). Every number the keeper supplies is a hint that the
/// contract verifies on-chain (D-021, D-028); a wrong hint reverts, a policy failure falls through to the next path.
interface ISettlementOracle {
    /// @param refRoundId last valid Chainlink round with `updatedAt <= expiry` (0 = none, proven by the feed's
    ///        first round being after expiry); used by path 1, every TWAP bound and the resolution band.
    /// @param afterRoundId first Chainlink round with `updatedAt > expiry` (path 3); 0 = not attempted.
    /// @param afterPrevRoundId last round of the previous phase when `afterRoundId` is aggregator round 1.
    /// @param obsIndex index of the latest pool observation with `blockTimestamp <= expiry` (path 2, D-053); an
    ///        older index only under-counts the window and fails the path, it can never help.
    struct Hint {
        uint80 refRoundId;
        uint80 afterRoundId;
        uint80 afterPrevRoundId;
        uint16 obsIndex;
    }

    struct VaultConfig {
        AggregatorV3Interface feed;
        IUniswapV3Pool pool;
        IStockToken stock;
        bool stockIsToken1;
        uint8 stockDecimals;
        uint8 usdgDecimals;
        bool registered;
    }

    struct SeriesRecord {
        uint8 path; // 0 until settled / resolved
        bool halted;
        uint64 haltedAt;
        uint80 roundId; // Chainlink round used on paths 1, 3, 5
        uint128 price8;
        uint128 resolveRef; // resolution reference fixed at halt (D-022)
        bytes32 haltReason;
    }

    function settle(uint256 seriesId, Hint calldata hint) external;
    function halt(uint256 seriesId, Hint calldata hint) external;
    function resolveHalted(uint256 seriesId, uint128 price8, string calldata evidenceURI) external;
    function resolveHaltedByOracle(uint256 seriesId, uint80 roundId, uint80 prevRoundId) external;

    function previewSettle(uint256 seriesId, Hint calldata hint)
        external
        view
        returns (bool ok, uint256 price8, uint8 path, bytes32 reason);
    function canHalt(uint256 seriesId, Hint calldata hint) external view returns (bool ok, bytes32 reason);
    function canResolveByOracle(uint256 seriesId) external view returns (bool ok, uint64 unlockAt);
    function resolutionBand(uint256 seriesId) external view returns (uint256 lo, uint256 hi);
    function referencePrice(address vault) external view returns (uint256 price8, bytes32 source);
    function records(uint256 seriesId) external view returns (SeriesRecord memory);
    function vaultConfig(address vault) external view returns (VaultConfig memory);
}
