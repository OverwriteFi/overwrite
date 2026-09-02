// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISafetyModule} from "../../src/interfaces/ISafetyModule.sol";

contract MockSafetyModule is ISafetyModule {
    uint256 public valueUSD;

    function set(uint256 v) external {
        valueUSD = v;
    }
}
