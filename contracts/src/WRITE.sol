// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {IWriteHolder} from "./interfaces/IWriteHolder.sol";

/// @title WRITE
/// @notice The protocol token (SPEC §14, CLAUDE.md rule 7). Fixed supply of 1 000 000 000, minted once in
/// this constructor directly into the five distribution contracts. There is no mint function, no owner, no
/// pause and no `ERC20Votes`: after deployment the supply is immutable and nobody has privileged control.
/// @dev The five amounts are `constant` here rather than constructor arguments (D-059), so the split is
/// verifiable from the verified source and a deploy script cannot fat-finger it. Every recipient must answer
/// `IWriteHolder.allocation()` with the exact amount it is about to receive (D-061), which rejects a plain
/// EOA (no such function) and, more usefully, a contract wired into the wrong bucket. It is a wiring check,
/// NOT a security boundary: a hostile contract — or an EIP-7702 delegated account whose delegate implements
/// `allocation()` — can return the right number and then do anything. The addresses are chosen by the
/// deployer, so the real guarantee is "each recipient declares the exact bucket it is about to receive".
/// Utility is safety-module staking, bonds, the fee discount and burn, and governance — never revenue
/// share (CLAUDE.md rule 7).
contract WRITE is ERC20, ERC20Burnable, ERC20Permit {
    // ───────────────────────────── constants (SPEC §14, docs/TOKENOMICS.md) ─────────────────────────────

    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;
    uint256 public constant LIQUIDITY_ALLOCATION = 250_000_000e18;
    uint256 public constant EMISSIONS_ALLOCATION = 300_000_000e18;
    uint256 public constant TREASURY_ALLOCATION = 200_000_000e18;
    uint256 public constant TEAM_ALLOCATION = 150_000_000e18;
    uint256 public constant POINTS_ALLOCATION = 100_000_000e18;

    // ───────────────────────────── types ─────────────────────────────

    /// @param liquidity LiquidityEscrow, releases only into the launchpad pool
    /// @param emissions EmissionsController, the SafetyModule's 4-year linear source
    /// @param treasuryVesting Vesting instance that cannot accept a revocable schedule
    /// @param teamVesting Vesting instance whose schedules the timelock may revoke
    /// @param points PointsDistributor, the airdrop and bond-grant Merkle rounds
    struct Holders {
        address liquidity;
        address emissions;
        address treasuryVesting;
        address teamVesting;
        address points;
    }

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error DuplicateHolder(address holder);
    error AllocationMismatch(address holder, uint256 expected, uint256 declared);
    error SupplyMismatch(uint256 minted, uint256 expected);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(Holders memory h) ERC20("Overwrite", "WRITE") ERC20Permit("Overwrite") {
        address[5] memory to = [h.liquidity, h.emissions, h.treasuryVesting, h.teamVesting, h.points];
        uint256[5] memory amounts =
            [LIQUIDITY_ALLOCATION, EMISSIONS_ALLOCATION, TREASURY_ALLOCATION, TEAM_ALLOCATION, POINTS_ALLOCATION];

        uint256 total;
        for (uint256 i; i < 5; ++i) {
            address holder = to[i];
            if (holder == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (to[j] == holder) revert DuplicateHolder(holder);
            }
            // Reverts for an EOA (no such function) and for a contract wired to the wrong bucket (D-061).
            uint256 declared = IWriteHolder(holder).allocation();
            if (declared != amounts[i]) revert AllocationMismatch(holder, amounts[i], declared);

            total += amounts[i];
            _mint(holder, amounts[i]);
        }
        // Unreachable while the five amounts are `constant`; kept so a future edit to them cannot ship a
        // supply that does not sum to MAX_SUPPLY.
        if (total != MAX_SUPPLY) revert SupplyMismatch(total, MAX_SUPPLY);
    }
}
