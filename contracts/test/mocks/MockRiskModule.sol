// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";

contract MockRiskModule is IRiskModule {
    mapping(address => bool) public depositsPaused;
    mapping(address => bool) public auctionsPaused;

    function setDepositsPaused(address vault, bool p) external {
        depositsPaused[vault] = p;
    }

    function setAuctionsPaused(address vault, bool p) external {
        auctionsPaused[vault] = p;
    }
}
