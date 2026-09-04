// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @dev Chainlink proxy mock with phase-aware round ids (D-014). `getRoundData` reverts for unknown rounds like the
/// real proxy. Doubles as the sequencer-uptime feed (`answer` 0/1, `startedAt`) and the USDG/USD feed.
contract MockAggregatorV3 is AggregatorV3Interface {
    struct RoundData {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        bool set;
    }

    uint8 public decimals;
    uint80 public latestId;
    bool public dead; // every call reverts, models a removed / self-destructed feed
    mapping(uint80 => RoundData) internal _rounds;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function roundId(uint16 phase, uint64 agg) public pure returns (uint80) {
        return (uint80(phase) << 64) | uint80(agg);
    }

    function setRound(uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt) public {
        _rounds[id] = RoundData({answer: answer, startedAt: startedAt, updatedAt: updatedAt, set: true});
        if (id > latestId) latestId = id;
    }

    /// @dev Convenience: `startedAt == updatedAt`.
    function setRound(uint80 id, int256 answer, uint256 updatedAt) external {
        setRound(id, answer, updatedAt, updatedAt);
    }

    function setLatest(uint80 id) external {
        latestId = id;
    }

    function deleteRound(uint80 id) external {
        delete _rounds[id];
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setDead(bool d) external {
        dead = d;
    }

    function getRoundData(uint80 id)
        public
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (dead) revert("dead");
        RoundData memory r = _rounds[id];
        if (!r.set) revert("No data present");
        return (id, r.answer, r.startedAt, r.updatedAt, id);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return getRoundData(latestId);
    }
}
