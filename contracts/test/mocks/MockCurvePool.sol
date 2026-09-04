// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A pool exposing Curve's `coins(uint256)` shape rather than Uniswap's `token0()/token1()`. Used to
/// prove `LiquidityEscrow.setPool` recognises more than one AMM layout (D-098): a bare `transfer` into any of
/// them is a donation the next swap takes.
contract MockCurvePool {
    address[2] internal _coins;

    constructor(address a, address b) {
        _coins = [a, b];
    }

    function coins(uint256 i) external view returns (address) {
        return _coins[i];
    }
}
