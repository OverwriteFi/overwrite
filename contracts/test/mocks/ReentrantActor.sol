// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {AuctionHouse} from "../../src/AuctionHouse.sol";
import {BondManager} from "../../src/BondManager.sol";
import {CoveredCallVault} from "../../src/CoveredCallVault.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {IBondManager} from "../../src/interfaces/IBondManager.sol";

/// @dev A market maker / depositor contract whose ERC-1155 receive hook tries to re-enter the AuctionHouse and
/// the vault with calls that WOULD succeed outside the callback (it holds a refund, an allocation and shares
/// with claimable premium). Records the revert selector of every attempt (THREAT-MODEL T-16).
contract ReentrantActor is IERC1155Receiver {
    AuctionHouse public ah;
    CoveredCallVault public vault;
    BondManager public bm;
    uint256 public attempts;
    uint256 public successes;
    bytes4[] public selectors;

    constructor(AuctionHouse ah_, CoveredCallVault vault_, BondManager bm_, MockUSDG usdg, MockStockToken stock) {
        ah = ah_;
        vault = vault_;
        bm = bm_;
        usdg.approve(address(ah_), type(uint256).max);
        usdg.approve(address(bm_), type(uint256).max);
        stock.approve(address(vault_), type(uint256).max);
    }

    function post() external {
        bm.postBond(IBondManager.BondKind.MM);
    }

    function deposit(uint256 assets) external {
        vault.deposit(assets, address(this));
    }

    function bid(uint256 id, uint256 qty, uint256 price) external {
        ah.bid(id, qty, price);
    }

    /// @dev Generic passthrough so the test can prove the same calls succeed outside the callback.
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "exec failed");
        return ret;
    }

    function selectorCount() external view returns (uint256) {
        return selectors.length;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata) external returns (bytes4) {
        _try(address(ah), abi.encodeCall(ah.withdrawRefund, (address(this))));
        _try(address(ah), abi.encodeCall(ah.claimOptions, (id, address(this))));
        _try(address(vault), abi.encodeCall(vault.claimPremium, (address(this))));
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function _try(address target, bytes memory data) internal {
        attempts++;
        (bool ok, bytes memory ret) = target.call(data);
        if (ok) {
            successes++;
            selectors.push(bytes4(0));
        } else {
            selectors.push(ret.length >= 4 ? bytes4(ret) : bytes4(0xffffffff));
        }
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return iid == type(IERC1155Receiver).interfaceId;
    }
}
