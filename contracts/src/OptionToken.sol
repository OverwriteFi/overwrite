// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOptionToken} from "./interfaces/IOptionToken.sol";
import {ICoveredCallVault} from "./interfaces/ICoveredCallVault.sol";
import {SeriesKind} from "./Types.sol";

/// @title OptionToken
/// @notice ERC-1155 covered-call options, one id per series (SPEC §3, §6, §9.7, D-012, D-024).
/// Ids are an incrementing counter; (vault, underlying, kind, strike, expiry) are stored per id.
/// Only the registered vault of an underlying can create series and mint/burn its ids. Holders
/// call `claim` after settlement; the token burns and asks the vault to pay out stock tokens.
contract OptionToken is ERC1155Supply, Ownable2Step, IOptionToken {
    uint256 public nextSeriesId = 1;
    mapping(address underlying => address vault) public vaultOf;
    mapping(address vault => bool) public isVault;
    mapping(uint256 id => SeriesInfo) internal _series;

    error ZeroAddress();
    error VaultAlreadyRegistered(address underlying);
    error NotVault();
    error UnknownSeries(uint256 id);
    error AlreadySettled(uint256 id);
    error NotSettled(uint256 id);
    error ZeroQty();

    event VaultRegistered(address indexed underlying, address indexed vault);
    event SeriesCreated(
        uint256 indexed id,
        address indexed vault,
        address indexed underlying,
        SeriesKind kind,
        uint128 strike,
        uint64 expiry,
        uint256 multiplierAtCreation
    );
    event SeriesSettled(uint256 indexed id, uint128 settlementPrice, uint128 payoutPerOption);
    event OptionClaimed(
        uint256 indexed seriesId, address indexed holder, address indexed to, uint256 qty, uint256 tokens
    );

    constructor(string memory uri_, address owner_) ERC1155(uri_) Ownable(owner_) {}

    // ───────────────────────────── admin (timelock) ─────────────────────────────

    /// @notice One vault per underlying, irreversible. Called by the deploy script / factory via the timelock.
    function registerVault(address underlying, address vault) external onlyOwner {
        if (underlying == address(0) || vault == address(0)) revert ZeroAddress();
        if (vaultOf[underlying] != address(0)) revert VaultAlreadyRegistered(underlying);
        vaultOf[underlying] = vault;
        isVault[vault] = true;
        emit VaultRegistered(underlying, vault);
    }

    // ───────────────────────────── vault-only ─────────────────────────────

    modifier onlySeriesVault(uint256 id) {
        address v = _series[id].vault;
        if (v == address(0)) revert UnknownSeries(id);
        if (msg.sender != v) revert NotVault();
        _;
    }

    function create(address underlying, SeriesKind kind, uint128 strike, uint64 expiry, uint256 multiplier)
        external
        returns (uint256 id)
    {
        if (vaultOf[underlying] != msg.sender) revert NotVault();
        id = nextSeriesId++;
        _series[id] = SeriesInfo({
            vault: msg.sender,
            underlying: underlying,
            kind: kind,
            settled: false,
            expiry: expiry,
            strike: strike,
            settlementPrice: 0,
            payoutPerOption: 0,
            multiplierAtCreation: multiplier
        });
        emit SeriesCreated(id, msg.sender, underlying, kind, strike, expiry, multiplier);
    }

    function mint(uint256 id, address to, uint256 qty) external onlySeriesVault(id) {
        if (qty == 0) revert ZeroQty();
        _mint(to, id, qty, "");
    }

    function burn(uint256 id, address from, uint256 qty) external onlySeriesVault(id) {
        if (qty == 0) revert ZeroQty();
        _burn(from, id, qty);
    }

    function markSettled(uint256 id, uint128 settlementPrice, uint128 payoutPerOption) external onlySeriesVault(id) {
        SeriesInfo storage s = _series[id];
        if (s.settled) revert AlreadySettled(id);
        s.settled = true;
        s.settlementPrice = settlementPrice;
        s.payoutPerOption = payoutPerOption;
        emit SeriesSettled(id, settlementPrice, payoutPerOption);
    }

    // ───────────────────────────── holders ─────────────────────────────

    /// @notice Burn `qty` options of a settled series and receive the stock-token payout (SPEC §9.7 step 4).
    /// No expiry on claims. Payout may be zero (OTM); the burn still happens.
    function claim(uint256 id, uint256 qty, address to) external returns (uint256 tokens) {
        SeriesInfo storage s = _series[id];
        if (s.vault == address(0)) revert UnknownSeries(id);
        if (!s.settled) revert NotSettled(id);
        if (qty == 0) revert ZeroQty();
        if (to == address(0)) revert ZeroAddress();
        _burn(msg.sender, id, qty);
        tokens = ICoveredCallVault(s.vault).payOptionClaim(id, to, qty);
        emit OptionClaimed(id, msg.sender, to, qty, tokens);
    }

    // ───────────────────────────── views ─────────────────────────────

    function series(uint256 id) external view returns (SeriesInfo memory) {
        return _series[id];
    }
}
