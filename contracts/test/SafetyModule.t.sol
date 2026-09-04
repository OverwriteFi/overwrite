// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {CapController} from "../src/CapController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract SafetyModuleTest is TokenBaseTest {
    uint256 internal round = 1;

    function _fund(address who, uint256 amount) internal returns (uint256 shares) {
        return _stake(who, amount);
    }

    // ═════════════════════════════ construction / wiring ═════════════════════════════

    function test_constructor_wiring() public view {
        assertEq(sm.writeToken(), address(write));
        assertEq(sm.emissions(), address(emis));
        assertEq(address(sm.oracle()), address(wOracle));
        assertEq(sm.owner(), admin, "owner is the timelock");
        assertEq(emis.sink(), address(sm));
        assertEq(sm.COOLDOWN(), 14 days);
        assertEq(sm.CLAIM_WINDOW(), 3 days);
        assertEq(sm.MAX_SLASH_BPS(), 3000);
    }

    function test_constructor_revertsOnMiswiredOracle() public {
        WritePriceOracle wrong = new WritePriceOracle(address(usdg), address(usdg), address(usdgFeed), admin);
        vm.expectRevert(abi.encodeWithSelector(SafetyModule.Miswired.selector, bytes32("ORACLE_WRITE")));
        new SafetyModule(address(write), address(emis), address(wrong), admin);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SafetyModule.ZeroAddress.selector);
        new SafetyModule(address(0), address(emis), address(wOracle), admin);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(SafetyModule.RenounceDisabled.selector);
        sm.renounceOwnership();
    }

    // ═════════════════════════════ stake / unstake ═════════════════════════════

    function test_stake_firstStakerGetsOffsetShares() public {
        uint256 shares = _fund(staker1, 1_000e18);
        assertEq(shares, 1_000e18 * 1e6, "shares carry the 6-decimal offset");
        assertEq(sm.totalStaked(), 1_000e18);
        assertEq(sm.totalShares(), shares);
        assertEq(sm.stakedOf(staker1), 1_000e18);
    }

    function test_stake_revertsOnZero() public {
        vm.prank(staker1);
        vm.expectRevert(SafetyModule.ZeroAmount.selector);
        sm.stake(0);
    }

    /// @dev `totalStaked` is an accumulator, never `balanceOf`, so a donation cannot move the share price.
    function test_stake_donationDoesNotMoveSharePrice() public {
        _fund(staker1, 1_000e18);
        uint256 before = sm.previewStake(1e18);
        _grantWrite(address(this), 500e18, round++);
        write.transfer(address(sm), 500e18);
        assertEq(sm.previewStake(1e18), before, "donation is inert");
        assertEq(sm.totalStaked(), 1_000e18);
    }

    function test_stake_pricesSharesAfterSlash() public {
        _fund(staker1, 1_000e18);
        vm.prank(admin);
        sm.slash(300e18, shortfallReserve, "ipfs://evidence");
        assertEq(sm.totalStaked(), 700e18);

        uint256 shares = _fund(staker2, 700e18);
        // 700 WRITE buys the same share count staker1 got for 1000, since each share is worth 0.7 now.
        assertApproxEqRel(shares, 1_000e18 * 1e6, 1e12, "shares repriced pro-rata after the slash");
        assertApproxEqRel(sm.stakedOf(staker2), 700e18, 1e12);
    }

    function test_requestUnstake_setsCooldownAndKeepsSharesAtRisk() public {
        uint256 shares = _fund(staker1, 1_000e18);
        vm.prank(staker1);
        uint64 unlockAt = sm.requestUnstake(shares);

        assertEq(unlockAt, uint64(block.timestamp) + 14 days);
        assertEq(sm.totalShares(), shares, "shares stay in the pool while cooling down");
        assertEq(sm.totalStaked(), 1_000e18);
        (uint64 opensAt, uint64 closesAt) = sm.unstakeWindow(staker1);
        assertEq(opensAt, unlockAt);
        assertEq(closesAt, unlockAt + 3 days);
    }

    function test_requestUnstake_revertsAboveBalance() public {
        uint256 shares = _fund(staker1, 1_000e18);
        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(SafetyModule.InsufficientShares.selector, shares, shares + 1));
        sm.requestUnstake(shares + 1);
    }

    function test_unstake_revertsBeforeCooldown() public {
        uint256 shares = _fund(staker1, 1_000e18);
        vm.prank(staker1);
        uint64 unlockAt = sm.requestUnstake(shares);
        vm.warp(unlockAt - 1);
        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(SafetyModule.CooldownActive.selector, unlockAt));
        sm.unstake();
    }

    function test_unstake_revertsAfterClaimWindow() public {
        uint256 shares = _fund(staker1, 1_000e18);
        vm.prank(staker1);
        uint64 unlockAt = sm.requestUnstake(shares);
        vm.warp(uint256(unlockAt) + 3 days + 1);
        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(SafetyModule.ClaimWindowClosed.selector, unlockAt + 3 days));
        sm.unstake();
    }

    function test_unstake_succeedsInsideWindow() public {
        uint256 shares = _fund(staker1, 1_000e18);
        vm.prank(staker1);
        uint64 unlockAt = sm.requestUnstake(shares);
        vm.warp(uint256(unlockAt) + 1 days);

        vm.prank(staker1);
        uint256 assets = sm.unstake();
        assertApproxEqRel(assets, 1_000e18, 1e12);
        assertEq(sm.totalShares(), 0);
        assertEq(sm.totalStaked(), 0);
        assertEq(write.balanceOf(staker1), assets);
    }

    function test_unstake_revertsWithoutRequest() public {
        _fund(staker1, 1_000e18);
        vm.prank(staker1);
        vm.expectRevert(SafetyModule.NoCooldown.selector);
        sm.unstake();
    }

    function test_cancelUnstake_clearsRequest() public {
        uint256 shares = _fund(staker1, 1_000e18);
        vm.prank(staker1);
        sm.requestUnstake(shares);
        vm.prank(staker1);
        sm.cancelUnstake();
        (uint64 opensAt,) = sm.unstakeWindow(staker1);
        assertEq(opensAt, 0);
        vm.prank(staker1);
        vm.expectRevert(SafetyModule.NoCooldown.selector);
        sm.cancelUnstake();
    }

    /// @dev SPEC §14: stake in cooldown is still slashable, and the leaver bears the loss at exit.
    function test_cooldownStakeIsStillSlashable() public {
        uint256 shares = _fund(staker1, 1_000e18);
        vm.prank(staker1);
        uint64 unlockAt = sm.requestUnstake(shares);

        vm.prank(admin);
        sm.slash(300e18, shortfallReserve, "ipfs://mid-cooldown");

        vm.warp(uint256(unlockAt) + 1);
        vm.prank(staker1);
        uint256 assets = sm.unstake();
        assertApproxEqRel(assets, 700e18, 1e12, "the cooling-down staker took the slash");
    }

    /// @dev The 14-day cooldown dominates the 48 h timelock, so nobody can exit ahead of a queued slash.
    function test_cooldownDominatesTheTimelockDelay() public {
        assertGe(sm.COOLDOWN(), 48 hours * 7, "cooldown must dwarf the timelock delay");
    }

    // ═════════════════════════════ slashing (SPEC §14) ═════════════════════════════

    function test_slash_onlyOwner() public {
        _fund(staker1, 1_000e18);
        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, staker1));
        sm.slash(1e18, shortfallReserve, "ipfs://x");
    }

    function test_slash_revertsAboveThirtyPercent() public {
        _fund(staker1, 1_000e18);
        uint256 cap = 300e18;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SafetyModule.ExceedsSlashCap.selector, cap + 1, cap));
        sm.slash(cap + 1, shortfallReserve, "ipfs://x");
    }

    function test_slash_revertsWithinInterval() public {
        _fund(staker1, 1_000e18);
        vm.prank(admin);
        sm.slash(100e18, shortfallReserve, "ipfs://1");
        uint64 allowedAt = uint64(block.timestamp) + 14 days;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SafetyModule.SlashTooSoon.selector, allowedAt));
        sm.slash(1e18, shortfallReserve, "ipfs://2");

        vm.warp(allowedAt);
        vm.prank(admin);
        sm.slash(1e18, shortfallReserve, "ipfs://2");
    }

    function test_slash_reducesEveryStakerProRata() public {
        _fund(staker1, 600e18);
        _fund(staker2, 400e18);
        vm.prank(admin);
        sm.slash(300e18, shortfallReserve, "ipfs://x");

        assertApproxEqRel(sm.stakedOf(staker1), 420e18, 1e12, "60 % of the remaining 700");
        assertApproxEqRel(sm.stakedOf(staker2), 280e18, 1e12, "40 % of the remaining 700");
        assertEq(write.balanceOf(shortfallReserve), 300e18);
    }

    function test_slash_emitsEvidenceURI() public {
        _fund(staker1, 1_000e18);
        vm.expectEmit(true, false, false, true);
        emit SafetyModule.Slashed(shortfallReserve, 100e18, "ipfs://evidence");
        vm.prank(admin);
        sm.slash(100e18, shortfallReserve, "ipfs://evidence");
    }

    /// @dev A slash consumes principal only; the reward bucket must stay whole and payable.
    function test_slash_rewardsRemainPayable() public {
        _fund(staker1, 1_000e18);
        _warpWithOracles(7 days);
        sm.poke();
        uint256 owed = sm.pendingRewards(staker1);
        assertGt(owed, 0);

        vm.prank(admin);
        sm.slash(300e18, shortfallReserve, "ipfs://x");

        vm.prank(staker1);
        uint256 claimed = sm.claimRewards();
        assertApproxEqAbs(claimed, owed, 1e12, "rewards survive the slash");
        assertGe(write.balanceOf(address(sm)), sm.totalStaked() + sm.totalUnclaimedRewards(), "module stays solvent");
    }

    function test_slash_revertsOnZeroAndZeroRecipient() public {
        _fund(staker1, 1_000e18);
        vm.prank(admin);
        vm.expectRevert(SafetyModule.ZeroAmount.selector);
        sm.slash(0, shortfallReserve, "x");
        vm.prank(admin);
        vm.expectRevert(SafetyModule.ZeroAddress.selector);
        sm.slash(1e18, address(0), "x");
    }

    // ═════════════════════════════ emissions ═════════════════════════════

    function test_emissions_accrueProRata() public {
        _fund(staker1, 600e18);
        _fund(staker2, 400e18);
        uint256 t0 = block.timestamp;

        _warpWithOracles(7 days);
        sm.poke();

        uint256 expected = emis.rate() * (block.timestamp - t0);
        assertApproxEqRel(sm.pendingRewards(staker1) + sm.pendingRewards(staker2), expected, 1e12);
        assertApproxEqRel(sm.pendingRewards(staker1), expected * 6 / 10, 1e12);
        assertApproxEqRel(sm.pendingRewards(staker2), expected * 4 / 10, 1e12);
    }

    /// @dev The MasterChef bug, closed: emissions accruing while nobody is staked are parked, not handed to
    /// whoever stakes next.
    function test_emissions_unallocatedWhileNobodyStaked() public {
        uint256 t0 = block.timestamp;
        _warpWithOracles(7 days);
        sm.poke();

        uint256 parked = sm.unallocatedRewards();
        assertApproxEqRel(parked, emis.rate() * (block.timestamp - t0), 1e12);
        assertEq(sm.totalUnclaimedRewards(), 0);

        _fund(staker1, 1_000e18);
        assertEq(sm.pendingRewards(staker1), 0, "the first staker inherits no backlog");

        vm.prank(admin);
        sm.redirectUnallocated(treasury);
        assertEq(write.balanceOf(treasury), parked);
        assertEq(sm.unallocatedRewards(), 0);
    }

    function test_claimRewards_paysFromSurplusNotPrincipal() public {
        _fund(staker1, 1_000e18);
        _warpWithOracles(7 days);

        vm.prank(staker1);
        uint256 claimed = sm.claimRewards();
        assertGt(claimed, 0);
        assertEq(sm.totalStaked(), 1_000e18, "principal untouched");
        assertEq(write.balanceOf(staker1), claimed);
    }

    function test_claimRewards_revertsWithNothingOwed() public {
        _fund(staker1, 1_000e18);
        vm.prank(staker1);
        vm.expectRevert(SafetyModule.ZeroAmount.selector);
        sm.claimRewards();
    }

    /// @dev The stake asset is the reward asset: `totalStaked` must never be read off the balance.
    function test_totalStakedIsNeverTheBalance() public {
        _fund(staker1, 1_000e18);
        _warpWithOracles(7 days);
        sm.poke();
        assertGt(write.balanceOf(address(sm)), sm.totalStaked(), "rewards sit on top of principal");
    }

    function test_redirectUnallocated_onlyOwnerAndNonZero() public {
        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, staker1));
        sm.redirectUnallocated(treasury);
        vm.prank(admin);
        vm.expectRevert(SafetyModule.ZeroAmount.selector);
        sm.redirectUnallocated(treasury);
    }

    /// @dev Regression for a defect the CI-profile invariant run found. Credits come from a floored
    /// cumulative index, and `floor(s x A2 / P) - floor(s x A1 / P)` can exceed `floor(s x (A2 - A1) / P)` by
    /// one wei, so the sum of credits drifts a wei above `totalUnclaimedRewards` per harvest. Before the fix
    /// the last claimant's subtraction underflowed and their rewards were unreachable forever.
    function test_claimRewards_dustDriftNeverBricksTheLastClaimant() public {
        _fund(staker1, 1_000e18);
        _fund(staker2, 1_000e18);

        // Interleave accruals, a slash and further staking, which is what makes the index drift.
        _warpWithOracles(3 days);
        sm.poke();
        vm.prank(admin);
        sm.slash(300e18, shortfallReserve, "ipfs://x");
        _fund(staker1, 500e18);
        _warpWithOracles(3 days);
        sm.poke();
        _fund(staker2, 700e18);
        _warpWithOracles(3 days);
        sm.poke();

        uint256 principal = sm.totalStaked();
        vm.prank(staker1);
        sm.claimRewards();
        vm.prank(staker2);
        sm.claimRewards(); // must not revert

        assertGe(write.balanceOf(address(sm)), principal, "a reward claim never eats into staked principal");
        assertEq(sm.totalStaked(), principal, "principal untouched by claims");
    }

    /// @dev The payout is structurally bounded by what the module holds above principal.
    function test_rewardSurplusBoundsEveryClaim() public {
        _fund(staker1, 1_000e18);
        _warpWithOracles(7 days);
        sm.poke();
        uint256 surplus = sm.rewardSurplus();
        assertGt(surplus, 0);
        vm.prank(staker1);
        uint256 claimed = sm.claimRewards();
        assertLe(claimed, surplus, "never more than the surplus");
        assertEq(sm.rewardSurplus(), surplus - claimed);
    }

    // ═════════════════════════════ valueUSD (SPEC §12) ═════════════════════════════

    function test_valueUSD_sixDecimals() public {
        _fund(staker1, 1_000_000e18);
        uint256 price8 = _writePrice8();
        uint256 expected = 1_000_000e18 * price8 / 1e20;
        assertEq(sm.valueUSD(), expected);
        assertEq(sm.safetyModuleValueUSD(), expected, "the SPEC 12 alias is the same number");
        // The nominal $0.10 is only reachable to within a fraction of a bp on the tick grid (D-096), so
        // this is a sanity bound; the exact expectation above comes from the live price.
        assertApproxEqRel(sm.valueUSD(), 100_000e6, 1e14, "1 M WRITE at ~$0.10 is ~$100 000");
    }

    function test_valueUSD_returnsZeroWhenOracleUnavailable() public {
        _fund(staker1, 1_000_000e18);
        assertGt(sm.valueUSD(), 0);

        writePool.setDead(true);
        assertEq(sm.valueUSD(), 0, "fails closed without reverting");
        (uint256 value, bool ok) = sm.valueUSDView();
        assertEq(value, 0);
        assertFalse(ok);
    }

    /// @dev D-069's consequence: an unavailable price closes deposits through the *cap*, so the vault reverts
    /// with OpenZeppelin's max-deposit error, not `CapPriceUnavailable`.
    function test_valueUSD_zeroClosesDepositsViaTheCap() public {
        _fund(staker1, 1_000_000e18);
        _enableSafetyModuleCap(10_000);
        assertGt(vault.maxDeposit(alice), 0);

        writePool.setDead(true);
        assertEq(cap.vaultCapUSD(address(vault)), 0, "cap views stay readable");
        assertEq(vault.maxDeposit(alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1e18, 0));
        vault.deposit(1e18, alice);
    }

    function test_capController_tracksStakeAndPrice() public {
        _fund(staker1, 1_000_000e18);
        _enableSafetyModuleCap(10_000);

        uint256 expected = sm.valueUSD() * cap.k() / 1e18;
        assertEq(cap.vaultCapUSD(address(vault)), expected, "cap = k x safetyModuleValueUSD x weight");

        _fund(staker2, 1_000_000e18);
        assertApproxEqRel(cap.vaultCapUSD(address(vault)), expected * 2, 1e12, "cap follows the stake");
    }

    function test_setOracle_onlyOwnerAndAssertsToken() public {
        WritePriceOracle wrong = new WritePriceOracle(address(usdg), address(usdg), address(usdgFeed), admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SafetyModule.Miswired.selector, bytes32("ORACLE_WRITE")));
        sm.setOracle(address(wrong));

        WritePriceOracle fresh = new WritePriceOracle(address(write), address(usdg), address(usdgFeed), admin);
        vm.prank(admin);
        sm.setOracle(address(fresh));
        assertEq(address(sm.oracle()), address(fresh));
    }
}
