// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "../TokenUnitBase.t.sol";
import {TokenDistributionHandler} from "./TokenDistributionHandler.sol";
import {MockLaunchpad} from "../mocks/MockLaunchpad.sol";

/// @dev Invariants for the three genesis-funded distribution contracts: WRITE's fixed supply, the
/// PointsDistributor's reserve accounting across rounds, and the LiquidityEscrow's release bound. Together
/// with `VestingInvariants` and `SafetyModuleInvariants` this gives every contract in the layer the invariant
/// coverage CLAUDE.md rule 2 requires.
contract TokenDistributionInvariants is TokenUnitBaseTest {
    TokenDistributionHandler internal handler;
    MockLaunchpad internal launchpad;
    address[4] internal claimants;
    uint256[4] internal amounts;

    function setUp() public override {
        super.setUp();
        launchpad = new MockLaunchpad(address(write));
        vm.prank(admin);
        escrow.setPool(address(launchpad));

        claimants = [makeAddr("c1"), makeAddr("c2"), makeAddr("c3"), makeAddr("c4")];
        amounts = [uint256(1_000e18), 2_000e18, 3_000e18, 4_000e18];

        handler = new TokenDistributionHandler(
            TokenDistributionHandler.Deps({
                write: write, points: points, escrow: escrow, admin: admin, pool: address(launchpad)
            }),
            claimants,
            amounts
        );
        targetContract(address(handler));
    }

    /// @dev I-31: supply is fixed at genesis and can only ever fall, by exactly what was burned. There is no
    /// mint function, so this is the property that would catch one being introduced.
    function invariant_I31_supplyOnlyEverFallsByWhatWasBurned() public view {
        assertEq(write.totalSupply(), write.MAX_SUPPLY() - handler.totalBurned(), "I-31: supply == max - burned");
        assertLe(write.totalSupply(), write.MAX_SUPPLY());
    }

    /// @dev I-32: the four points buckets partition the allocation exactly, in every interleaving of
    /// `setRound`, `claim` and `sweep`.
    function invariant_I32_pointsBucketsPartitionTheAllocation() public view {
        assertEq(
            points.paidOut() + points.sweptTotal() + points.outstanding() + points.unreserved(),
            points.allocation(),
            "I-32: paidOut + swept + outstanding + unreserved == allocation"
        );
    }

    /// @dev I-33: what the distributor still owes is covered by what it still holds. Derived from the
    /// `allocation` immutable, so a donation cannot paper over a shortfall.
    function invariant_I33_outstandingClaimsAreFunded() public view {
        assertGe(write.balanceOf(address(points)), points.outstanding(), "I-33: live rounds stay funded");
    }

    /// @dev I-34: no round ever distributes more than it reserved, so an over-issuing root is confined.
    function invariant_I34_noRoundOverpays() public view {
        assertLe(handler.sumRoundClaimed(), handler.sumRoundAmounts(), "I-34: claimed <= reserved, per round set");
        assertEq(points.paidOut(), handler.sumRoundClaimed(), "I-34: paidOut is the sum of round claims");
    }

    /// @dev I-35: the escrow releases at most its allocation, and only ever to the one destination.
    function invariant_I35_escrowNeverOverReleases() public view {
        assertLe(escrow.released(), escrow.allocation(), "I-35: released <= allocation");
        assertEq(
            write.balanceOf(address(escrow)), escrow.allocation() - escrow.released(), "I-35: the remainder is held"
        );
        assertEq(write.balanceOf(address(launchpad)), escrow.released(), "I-35: everything released reached the pool");
    }

    function afterInvariant() public {
        emit log_named_uint("calls", handler.calls());
        emit log_named_uint("rounds opened", handler.roundsOpened());
        emit log_named_uint("claims", handler.claimsMade());
        emit log_named_uint("sweeps", handler.sweeps());
        emit log_named_uint("escrow fundings", handler.funds());
        emit log_named_uint("burns", handler.burns());
    }

    /// @dev Deterministic proof the handler is not vacuous.
    function test_handlerReachesEveryState() public {
        handler.openRound(10 days);
        handler.claim(1, 0);
        handler.fundPool(1_000e18);
        handler.burn(0, 1e18);
        handler.donate(0, 1e18);
        handler.warp(30 days);
        handler.sweep(1);

        assertGt(handler.roundsOpened(), 0, "opened a round");
        assertGt(handler.claimsMade(), 0, "claimed");
        assertGt(handler.sweeps(), 0, "swept");
        assertGt(handler.funds(), 0, "funded the pool");
        assertGt(handler.burns(), 0, "burned");
    }
}
