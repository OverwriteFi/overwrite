// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet / test mock of USDG (SPEC §1.4, D-014): 6 decimals, open mint, plus the Paxos admin surface
/// (`paused()`, `isFrozen(address)`) so tests can model a frozen bidder or a paused token (THREAT-MODEL T-07.3, T-12).
contract MockUSDG is ERC20 {
    bool public paused;
    mapping(address account => bool) public isFrozen;

    error TokenPaused();
    error AccountFrozen(address account);

    constructor() ERC20("Mock Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setFrozen(address account, bool f) external {
        isFrozen[account] = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TokenPaused();
        if (isFrozen[from]) revert AccountFrozen(from);
        if (isFrozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }
}
