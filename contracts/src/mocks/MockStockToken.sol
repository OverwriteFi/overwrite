// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Testnet / test mock of a Robinhood stock token (SPEC §1.2, D-014): ERC-20 18 dec with the
/// ERC-8056 scaled-UI fields and the issuer flags, all owner-settable. Raw balances never change.
contract MockStockToken is ERC20, Ownable {
    uint256 public uiMultiplier = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;
    bool public oraclePaused;
    bool public paused;

    error TokenPaused();

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAt);

    constructor(string memory name_, string memory symbol_, address owner_) ERC20(name_, symbol_) Ownable(owner_) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @dev Issuer power (SPEC §1.2): burns any balance; used to simulate a shortfall.
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
    }

    function setOraclePaused(bool p) external onlyOwner {
        oraclePaused = p;
    }

    function stageMultiplier(uint256 newMultiplier, uint256 effectiveAt_) external onlyOwner {
        newUIMultiplier = newMultiplier;
        effectiveAt = effectiveAt_;
        emit UIMultiplierUpdated(uiMultiplier, newMultiplier, effectiveAt_);
    }

    function applyMultiplier() external onlyOwner {
        uiMultiplier = newUIMultiplier;
        effectiveAt = 0;
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return balanceOf(account) * uiMultiplier / 1e18;
    }

    function totalSupplyUI() external view returns (uint256) {
        return totalSupply() * uiMultiplier / 1e18;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TokenPaused();
        super._update(from, to, value);
    }
}
