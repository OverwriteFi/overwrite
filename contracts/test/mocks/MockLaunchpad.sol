// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Stand-in for the launch venue `LiquidityEscrow` releases into. Deliberately exposes no `token0()` /
/// `token1()`, so it passes the escrow's raw-AMM guard (D-094) — which is exactly the distinction the guard
/// is drawing: a venue that accounts for a deposit, not a pool where a bare transfer is a donation.
contract MockLaunchpad {
    address public immutable writeToken;
    uint256 public received;

    constructor(address write_) {
        writeToken = write_;
    }

    /// @dev The escrow uses a plain `transfer`; a real launchpad would credit the deposit on its own books.
    function sync(uint256 amount) external {
        received += amount;
    }
}
