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

    /// @dev I-20: the 30 % cap is enforced by the contract, not by the handler. `slashOverCap` deliberately
    /// asks for more than the cap on every call; not one may succeed. Deleting `ExceedsSlashCap` from
    /// `SafetyModule.slash` fails this invariant, which the previous formulation (asserting on an amount the
    /// handler had already bounded below the cap) did not.
    function invariant_I20_slashCapIsEnforcedByTheContract() public view {
        assertEq(handler.overCapBreaches(), 0, "I-20: no slash above 30 % of totalStaked ever succeeded");
    }

    /// @dev I-21: shares and principal are zero together. A pool with shares but no assets would divide by
    /// zero on the next stake; a pool with assets but no shares would be unredeemable.
    function invariant_I21_sharesAndPrincipalVanishTogether() public view {
        if (sm.totalShares() == 0) assertEq(sm.totalStaked(), 0, "I-21: no orphaned principal");
        if (sm.totalStaked() == 0) assertEq(sm.totalShares(), 0, "I-21: no worthless shares");
    }

    /// @dev I-22: everything the module owes its stakers was funded by emissions actually pulled from the
    /// controller. Counts unharvested index movement too (`pendingRewards`, not `claimableRewards`), so a
    /// credit created outside `_accrue` cannot hide between harvests. The floored index over-credits by up to
    /// a wei per harvest (D-097), so the bound carries that slack rather than pretending it is exact --
    /// `calls()` is an upper bound on the number of harvests performed.
    function invariant_I22_rewardsNeverExceedEmissionsReleased() public view {
        uint256 owed = handler.sumOwedRewards() + sm.unallocatedRewards();
        assertLe(owed, emis.released() + handler.calls(), "I-22: rewards <= emitted + index dust");
    }

    /// @dev I-28: everything owed is covered by what the module holds above principal. The index drifts by at
    /// most a wei per harvest (D-097), so the bound carries that slack explicitly rather than hiding it.
    function invariant_I28_owedRewardsAreCoveredBySurplus() public view {
        assertLe(handler.sumOwedRewards(), sm.rewardSurplus() + handler.calls(), "I-28: owed <= surplus + dust");
    }

    /// @dev I-29: principal is conserved exactly. Every WRITE that entered as stake either still counts as
    /// principal, left through a redemption, or left through a slash — nothing else moves `totalStaked`.
    /// This is the property that would catch an unstake/slash accounting error, which I-17 and I-18 cannot.
    function invariant_I29_principalIsConserved() public view {
        assertEq(
            handler.stakedIn() - handler.unstakedOut() - handler.slashedOut(),
            sm.totalStaked(),
            "I-29: stakedIn - unstakedOut - slashedOut == totalStaked"
        );
    }

    /// @dev I-30: donations are inert. WRITE sent directly to the module raises its balance and therefore
    /// `rewardSurplus()`, but must never become anyone's credit -- that is what keeps the surplus a cap rather
    /// than a source. Stated against emissions released (plus the D-097 dust), so a donation that leaked into
    /// a credit would break it even though the balance grew.
    function invariant_I30_donationsCreateNoCredit() public view {
        assertLe(handler.sumOwedRewards(), emis.released() + handler.calls(), "I-30: a donation is not a reward");
        assertGe(handler.donations(), 0);
    }

    function afterInvariant() public {
        emit log_named_uint("calls", handler.calls());
        emit log_named_uint("stakes", handler.stakes());
        emit log_named_uint("unstakes", handler.unstakes());
        emit log_named_uint("slashes", handler.slashes());
        emit log_named_uint("reward claims", handler.claims());
        emit log_named_uint("donations", handler.donations());
        emit log_named_uint("over-cap slash attempts", handler.overCapAttempts());
    }

    /// @dev Deterministic proof the handler is not vacuous: the full lifecycle must be reachable.
    function test_handlerReachesEveryState() public {
        handler.stake(0, 1_000e18);
        handler.warp(10 days);
        handler.claimRewards(0);
        handler.donate(0, 1e18);
        handler.slashOverCap(0, 1); // before the real slash: it would otherwise hit the 14-day interval guard
        handler.slash(type(uint256).max, 1);
        handler.requestUnstake(0, type(uint256).max);
        handler.warpToUnstakeWindow(0);
        handler.unstake(0);

        assertGt(handler.stakes(), 0, "staked");
        assertGt(handler.slashes(), 0, "slashed");
        assertGt(handler.claims(), 0, "claimed rewards");
        assertGt(handler.donations(), 0, "donated");
        assertGt(handler.overCapAttempts(), 0, "attempted an over-cap slash");
        assertEq(handler.overCapBreaches(), 0, "and it was rejected");
        assertGt(handler.unstakes(), 0, "redeemed shares after the cooldown");
    }
}
