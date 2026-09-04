// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WRITE} from "../../src/WRITE.sol";
import {SafetyModule} from "../../src/SafetyModule.sol";
import {EmissionsController} from "../../src/EmissionsController.sol";

/// @dev Drives the SafetyModule under `fail_on_revert = true`, so every action early-returns on a guard
/// rather than reverting. Ghost counters record what the contract is supposed to have enforced, so the
/// invariants can check the enforcement rather than trusting it.
contract SafetyModuleHandler is Test {
    struct Deps {
        WRITE write;
        SafetyModule sm;
        EmissionsController emis;
        address admin;
    }

    WRITE public immutable write;
    SafetyModule public immutable sm;
    EmissionsController public immutable emis;
    address public immutable admin;

    address[4] public actors;

    // ghosts
    uint256 public calls;
    uint256 public stakes;
    uint256 public unstakes;
    uint256 public slashes;
    uint256 public claims;
    uint256 public maxSlashBpsSeen;
    uint256 public totalSlashed;

    modifier count() {
        calls++;
        _;
    }

    constructor(Deps memory d, address[4] memory actors_) {
        write = d.write;
        sm = d.sm;
        emis = d.emis;
        admin = d.admin;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function stake(uint256 seed, uint256 amount) external count {
        address a = _actor(seed);
        if (sm.totalShares() != 0 && sm.totalStaked() == 0) return; // PoolInsolvent guard
        uint256 bal = write.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        if (sm.previewStake(amount) == 0) return;
        vm.prank(a);
        sm.stake(amount);
        stakes++;
    }

    function requestUnstake(uint256 seed, uint256 sharesSeed) external count {
        address a = _actor(seed);
        uint256 have = sm.sharesOf(a);
        if (have == 0) return;
        vm.prank(a);
        sm.requestUnstake(bound(sharesSeed, 1, have));
    }

    function cancelUnstake(uint256 seed) external count {
        address a = _actor(seed);
        (uint64 opensAt,) = sm.unstakeWindow(a);
        if (opensAt == 0) return;
        vm.prank(a);
        sm.cancelUnstake();
    }

    function unstake(uint256 seed) external count {
        address a = _actor(seed);
        (uint64 opensAt, uint64 closesAt) = sm.unstakeWindow(a);
        if (opensAt == 0) return;
        // The contract enforces the window; the handler only avoids the revert under fail_on_revert.
        if (block.timestamp < opensAt) return;
        if (block.timestamp > closesAt) return;
        vm.prank(a);
        sm.unstake();
        unstakes++;
    }

    function claimRewards(uint256 seed) external count {
        address a = _actor(seed);
        sm.poke();
        if (sm.pendingRewards(a) == 0) return;
        // The payout is capped at the surplus above principal, so a dust credit with nothing left to pay
        // reverts `ZeroAmount` by design; guard it here rather than letting `fail_on_revert` trip.
        if (sm.rewardSurplus() == 0) return;
        vm.prank(a);
        sm.claimRewards();
        claims++;
    }

    function poke() external count {
        sm.poke();
    }

    function slash(uint256 amountSeed, uint256 seed) external count {
        uint256 staked = sm.totalStaked();
        if (staked == 0) return;
        uint64 last = sm.lastSlashAt();
        if (last != 0 && block.timestamp < uint256(last) + sm.SLASH_INTERVAL()) return;

        uint256 cap = staked * sm.MAX_SLASH_BPS() / sm.BPS();
        if (cap == 0) return;
        uint256 amount = bound(amountSeed, 1, cap);
        uint256 floor_ = sm.MIN_RESIDUAL_STAKE();
        if (staked > floor_ && staked - amount < floor_) return;

        uint256 bps = amount * sm.BPS() / staked;
        vm.prank(admin);
        sm.slash(amount, _actor(seed), "ipfs://invariant");
        if (bps > maxSlashBpsSeen) maxSlashBpsSeen = bps;
        totalSlashed += amount;
        slashes++;
    }

    function warp(uint256 dt) external count {
        vm.warp(block.timestamp + bound(dt, 1 hours, 20 days));
    }

    // ───────────────────────────── views for the invariants ─────────────────────────────

    function sumShares() external view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += sm.sharesOf(actors[i]);
        }
    }

    function sumClaimable() external view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += sm.claimableRewards(actors[i]);
        }
    }
}
