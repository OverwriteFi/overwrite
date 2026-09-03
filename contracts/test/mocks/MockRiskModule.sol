// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {OracleParams} from "../../src/Types.sol";

contract MockRiskModule is IRiskModule {
    mapping(address => bool) public depositsPaused;
    mapping(address => bool) public auctionsPaused;
    address public settlementOracle;
    uint256 public haltCalls;

    function setDepositsPaused(address vault, bool p) external {
        depositsPaused[vault] = p;
    }

    function setAuctionsPaused(address vault, bool p) external {
        auctionsPaused[vault] = p;
    }

    function setSettlementOracle(address o) external {
        settlementOracle = o;
    }

    function paramsAt(address, uint64) external pure returns (OracleParams memory) {
        return _defaults();
    }

    function currentParams(address) external pure returns (OracleParams memory) {
        return _defaults();
    }

    function pauseNewAuctionsOnHalt(address vault, uint256, bytes32) external {
        auctionsPaused[vault] = true;
        haltCalls++;
    }

    function _defaults() internal pure returns (OracleParams memory p) {
        p.weekdayMaxStale = 93_600;
        p.twapGrace = 1_800;
        p.sequencerGrace = 3_600;
        p.usdgMaxStale = 93_600;
        p.weekendTwapBoundBps = 1_500;
        p.weekdayTwapBoundBps = 300;
        p.impactBps = 100;
        p.jumpBps = 3_000;
        p.usdgBandLowBps = 9_800;
        p.usdgBandHighBps = 10_200;
        p.minObservationsInWindow = 3;
        p.swapNotionalUSDG = 250_000e6;
    }
}
