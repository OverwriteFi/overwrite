// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WRITE} from "../../src/WRITE.sol";
import {SafetyModule} from "../../src/SafetyModule.sol";
import {EmissionsController} from "../../src/EmissionsController.sol";

/// @dev Drives the SafetyModule under `fail_on_revert = true`, so every action early-returns on a guard rather
/// than reverting. Ghost counters record what the contract is supposed to have enforced, so the invariants can
/// check the enforcement rather than trusting it.
/// Two actions exist purely to make the interesting states reachable: `warpToUnstakeWindow`, because a blind
/// random walk lands inside a 3-day window 14 days out only ~0.3 % of the time and the share-burning path
/// would otherwise never execute; and `slashOverCap`, which deliberately attempts an illegal slash so the
/// 30 % cap is proven by the contract rather than restated by the handler's own `bound()`.
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

    // ───────────────────────────── ghosts ─────────────────────────────

    uint256 public calls;
    uint256 public stakes;
    uint256 public unstakes;
    uint256 public slashes;
    uint256 public claims;
    uint256 public donations;
    /// @notice Principal conservation: `stakedIn - unstakedOut - slashedOut == sm.totalStaked()`.
    uint256 public stakedIn;
    uint256 public unstakedOut;
    uint256 public slashedOut;
    /// @notice Attempts to slash above the 30 % cap, and how many the contract let through (must stay 0).
    uint256 public overCapAttempts;
    uint256 public overCapBreaches;

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

    // ───────────────────────────── actions ─────────────────────────────

    function stake(uint256 seed, uint256 amount) external count {
        address a = _actor(seed);
        if (sm.totalShares() != 0 && sm.totalStaked() == 0) return; // PoolInsolvent guard
        uint256 bal = write.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        if (sm.previewStake(amount) == 0) return;
        vm.prank(a);
        sm.stake(amount);
        stakedIn += amount;
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

    /// @dev Without this the fuzzer effectively never redeems: the window is 3 days wide, 14 days out, and
    /// `warp` draws from `[1 hour, 20 days]`. Measured at depth 4000, blind `unstake` succeeded 13/4096 times.
    function warpToUnstakeWindow(uint256 seed) external count {
        (uint64 opensAt,) = sm.unstakeWindow(_actor(seed));
        if (opensAt == 0 || block.timestamp >= opensAt) return;
        vm.warp(uint256(opensAt) + 1);
    }

    function unstake(uint256 seed) external count {
        address a = _actor(seed);
        (uint64 opensAt, uint64 closesAt) = sm.unstakeWindow(a);
        if (opensAt == 0) return;
        if (block.timestamp < opensAt || block.timestamp > closesAt) return;
        // A slash that landed after the request matured voids it (D-098). The contract enforces this; the
        // handler only avoids tripping fail_on_revert.
        if (opensAt <= sm.lastSlashAt()) return;

        uint256 before = write.balanceOf(a);
        vm.prank(a);
        sm.unstake();
        unstakedOut += write.balanceOf(a) - before;
        unstakes++;
    }

    function claimRewards(uint256 seed) external count {
        address a = _actor(seed);
        sm.poke();
        if (sm.pendingRewards(a) == 0) return;
        // The payout is capped at the surplus above principal, so a dust credit with nothing left to pay
        // reverts `ZeroAmount` by design (D-097); guard it rather than tripping fail_on_revert.
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
        if (!_slashIntervalElapsed()) return;

        uint256 cap = staked * sm.MAX_SLASH_BPS() / sm.BPS();
        if (cap == 0) return;
        uint256 amount = bound(amountSeed, 1, cap);
        uint256 floor_ = sm.MIN_RESIDUAL_STAKE();
        if (staked > floor_ && staked - amount < floor_) return;

        vm.prank(admin);
        sm.slash(amount, _actor(seed), "ipfs://invariant");
        slashedOut += amount;
        slashes++;
    }

    /// @dev Deliberately asks for more than 30 %. The contract must reject every one of these; if any succeeds
    /// the invariant catches it. Without this action the cap invariant would only restate the handler's
    /// own `bound()` and would still pass with the cap check deleted from the contract.
    function slashOverCap(uint256 amountSeed, uint256 seed) external count {
        uint256 staked = sm.totalStaked();
        if (staked == 0) return;
        if (!_slashIntervalElapsed()) return;

        uint256 cap = staked * sm.MAX_SLASH_BPS() / sm.BPS();
        if (cap + 1 > staked) return;
        uint256 amount = bound(amountSeed, cap + 1, staked);
        overCapAttempts++;
        vm.prank(admin);
        try sm.slash(amount, _actor(seed), "ipfs://over-cap") {
            overCapBreaches++; // must stay unreachable: the amount is above the cap
            slashedOut += amount;
        } catch {}
    }

    /// @dev A donation must not move the share price, expand anyone's credit, or become claimable.
    function donate(uint256 seed, uint256 amount) external count {
        address a = _actor(seed);
        uint256 bal = write.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(a);
        write.transfer(address(sm), amount);
        donations++;
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

    /// @notice Harvested credits plus the unharvested index movement — everything the module currently owes.
    function sumOwedRewards() external view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += sm.pendingRewards(actors[i]);
        }
    }

    function _slashIntervalElapsed() internal view returns (bool) {
        uint64 last = sm.lastSlashAt();
        return last == 0 || block.timestamp >= uint256(last) + sm.SLASH_INTERVAL();
    }
}
