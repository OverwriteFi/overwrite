// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";

contract MockPriceSource is IPriceSource {
    mapping(address => uint256) public price8;
    mapping(address => bool) public ok;

    function set(address vault, uint256 p, bool ok_) external {
        price8[vault] = p;
        ok[vault] = ok_;
    }

    function capPrice(address vault) external view returns (uint256, bool) {
        return (price8[vault], ok[vault]);
    }
}
