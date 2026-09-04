// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "../TokenUnitBase.t.sol";
import {SafetyModuleHandler} from "./SafetyModuleHandler.sol";

/// @dev Invariants for the staking, emissions and slashing accounting. Uses the light token fixture: no
/// vault, auction or settlement state is involved in any of these properties.
contract SafetyModuleInvariants is TokenUnitBaseTest {
    SafetyModuleHandler internal handler;
    address[4] internal stakers;

    function setUp() public override {
        super.setUp();

        stakers = [makeAddr("s1"), makeAddr("s2"), makeAddr("s3"), makeAddr("s4")];
        handler = new SafetyModuleHandler(
            SafetyModuleHandler.Deps({write: write, sm: sm, emis: emis, admin: admin}), stakers
        );

        for (uint256 i; i < 4; ++i) {
            _grantWrite(stakers[i], 10_000_000e18, i + 1);
            vm.prank(stakers[i]);
            write.approve(address(sm), type(uint256).max);
        }

        targetContract(address(handler));
    }

    /// @dev I-17: the share ledger is exactly the sum of its parts. Shares are non-transferable and never
    /// leave the ledger, so any drift is an accounting bug.
    function invariant_I17_sharesSumToTotalShares() public view {
        assertEq(handler.sumShares(), sm.totalShares(), "I-17: sum(sharesOf) == totalShares");
    }

    /// @dev I-18: the module is always solvent, and specifically a reward claim can never reach staked
    /// principal or the parked emissions. The stake asset is also the reward asset, so this is the property
    /// that keeps the two buckets apart. Stated against principal rather than against
    /// `totalUnclaimedRewards`, because the credit index drifts a wei above that counter per harvest — which
    /// is exactly why `claimRewards` caps its payout at `rewardSurplus()`.
    function invariant_I18_claimsNeverReachPrincipal() public view {
        uint256 reserved = sm.totalStaked() + sm.unallocatedRewards();
        assertGe(write.balanceOf(address(sm)), reserved, "I-18: balance >= principal + parked emissions");
    }

    /// @dev I-19: `totalStaked` is an accumulator, never the balance — otherwise emissions sitting in the
    /// contract would silently become slashable principal.
    function invariant_I19_totalStakedIsNotTheBalance() public view {
        if (sm.totalUnclaimedRewards() + sm.unallocatedRewards() > 0) {
            assertLt(sm.totalStaked(), write.balanceOf(address(sm)), "I-19: principal is tracked, not measured");
        }
    }

    /// @dev I-20: no single slash ever exceeded 30 % of the staked total (SPEC §14).
    function invariant_I20_slashNeverExceededTheCap() public view {
        assertLe(handler.maxSlashBpsSeen(), sm.MAX_SLASH_BPS(), "I-20: slash <= 30 % per event");
    }

    /// @dev I-21: shares and principal are zero together. A pool with shares but no assets would divide by
    /// zero on the next stake; a pool with assets but no shares would be unredeemable.
    function invariant_I21_sharesAndPrincipalVanishTogether() public view {
        if (sm.totalShares() == 0) assertEq(sm.totalStaked(), 0, "I-21: no orphaned principal");
        if (sm.totalStaked() == 0) assertEq(sm.totalShares(), 0, "I-21: no worthless shares");
    }

    /// @dev I-22: every claimed reward was funded by emissions actually pulled from the controller.
    function invariant_I22_rewardsNeverExceedEmissionsReleased() public view {
        uint256 credited = handler.sumClaimable() + sm.unallocatedRewards();
        assertLe(credited, emis.released(), "I-22: rewards are bounded by what was emitted");
    }

    /// @dev I-28: the credited-but-unclaimed total never exceeds what the module can actually pay. The index
    /// drift is bounded by roughly a wei per harvest, so this is the honest form of "rewards are funded".
    function invariant_I28_creditsAreCoveredBySurplus() public view {
        uint256 credited = handler.sumClaimable();
        assertLe(credited, sm.rewardSurplus() + handler.calls(), "I-28: credits <= surplus + index dust");
    }

    function afterInvariant() public {
        emit log_named_uint("calls", handler.calls());
        emit log_named_uint("stakes", handler.stakes());
        emit log_named_uint("unstakes", handler.unstakes());
        emit log_named_uint("slashes", handler.slashes());
        emit log_named_uint("reward claims", handler.claims());
        emit log_named_uint("max slash bps seen", handler.maxSlashBpsSeen());
    }

    /// @dev Deterministic proof the handler is not vacuous: the full lifecycle must be reachable.
    function test_handlerReachesEveryState() public {
        handler.stake(0, 1_000e18);
        handler.warp(10 days);
        handler.claimRewards(0);
        handler.requestUnstake(0, type(uint256).max);
        handler.slash(type(uint256).max, 1);
        handler.warp(15 days);
        handler.unstake(0);

        assertGt(handler.stakes(), 0, "staked");
        assertGt(handler.slashes(), 0, "slashed");
        assertGt(handler.claims(), 0, "claimed rewards");
        assertGt(handler.unstakes(), 0, "unstaked after the cooldown");
    }
}
