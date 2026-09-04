// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenUnitBaseTest} from "./TokenUnitBase.t.sol";
import {WRITE} from "../src/WRITE.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Vesting} from "../src/Vesting.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract WRITETest is TokenUnitBaseTest {
    /// @dev A fresh, unwired set of holders for constructor-failure cases.
    function _freshHolders() internal returns (WRITE.Holders memory h) {
        h.liquidity = address(new LiquidityEscrow(admin));
        h.emissions = address(new EmissionsController(admin, EMISSIONS_DURATION));
        h.treasuryVesting = address(new Vesting(admin, 200_000_000e18, false));
        h.teamVesting = address(new Vesting(admin, 150_000_000e18, true));
        h.points = address(new PointsDistributor(admin, treasury));
    }

    // ═════════════════════════════ supply and distribution ═════════════════════════════

    function test_constructor_mintsExactSupplyToTheFiveHolders() public view {
        assertEq(write.totalSupply(), 1_000_000_000e18);
        assertEq(write.balanceOf(address(escrow)), 250_000_000e18);
        assertEq(write.balanceOf(address(emis)), 300_000_000e18);
        assertEq(write.balanceOf(address(treasuryVesting)), 200_000_000e18);
        assertEq(write.balanceOf(address(teamVesting)), 150_000_000e18);
        assertEq(write.balanceOf(address(points)), 100_000_000e18);
    }

    function test_constructor_allocationsSumToMaxSupply() public view {
        uint256 sum = write.LIQUIDITY_ALLOCATION() + write.EMISSIONS_ALLOCATION() + write.TREASURY_ALLOCATION()
            + write.TEAM_ALLOCATION() + write.POINTS_ALLOCATION();
        assertEq(sum, write.MAX_SUPPLY());
    }

    function test_metadata() public view {
        assertEq(write.name(), "Overwrite");
        assertEq(write.symbol(), "WRITE");
        assertEq(write.decimals(), 18);
    }

    /// @dev The `allocation()` handshake is what makes minting into an EOA impossible (D-061): an EOA has no
    /// such function, so the call reverts rather than silently sending 250 M WRITE to a typo.
    function test_constructor_revertsOnEOARecipient() public {
        WRITE.Holders memory h = _freshHolders();
        h.liquidity = makeAddr("someEOA");
        vm.expectRevert();
        new WRITE(h);
    }

    function test_constructor_revertsOnAllocationMismatch() public {
        WRITE.Holders memory h = _freshHolders();
        // A Vesting sized for the team bucket sitting in the treasury slot.
        address wrongSize = address(new Vesting(admin, 150_000_000e18, false));
        h.treasuryVesting = wrongSize;
        vm.expectRevert(
            abi.encodeWithSelector(WRITE.AllocationMismatch.selector, wrongSize, 200_000_000e18, 150_000_000e18)
        );
        new WRITE(h);
    }

    function test_constructor_revertsOnDuplicateHolder() public {
        WRITE.Holders memory h = _freshHolders();
        h.teamVesting = h.treasuryVesting;
        vm.expectRevert(abi.encodeWithSelector(WRITE.DuplicateHolder.selector, h.treasuryVesting));
        new WRITE(h);
    }

    function test_constructor_revertsOnZeroAddress() public {
        WRITE.Holders memory h = _freshHolders();
        h.points = address(0);
        vm.expectRevert(WRITE.ZeroAddress.selector);
        new WRITE(h);
    }

    // ═════════════════════════════ no mint, no owner ═════════════════════════════

    /// @dev There is no way to increase supply after deployment: no `mint`, no `owner`, no pause.
    function test_noMintOrOwnerSelectorsExist() public {
        address t = address(write);
        (bool okMint,) = t.call(abi.encodeWithSignature("mint(address,uint256)", alice, 1e18));
        assertFalse(okMint, "no mint(address,uint256)");
        (bool okOwner,) = t.call(abi.encodeWithSignature("owner()"));
        assertFalse(okOwner, "no owner()");
        (bool okPause,) = t.call(abi.encodeWithSignature("pause()"));
        assertFalse(okPause, "no pause()");
    }

    // ═════════════════════════════ burn / permit ═════════════════════════════

    function test_burn_reducesTotalSupply() public {
        _grantWrite(alice, 1_000e18, 1);
        vm.prank(alice);
        write.burn(400e18);
        assertEq(write.balanceOf(alice), 600e18);
        assertEq(write.totalSupply(), 1_000_000_000e18 - 400e18);
    }

    function test_burnFrom_spendsAllowance() public {
        _grantWrite(alice, 1_000e18, 1);
        vm.prank(alice);
        write.approve(bob, 250e18);
        vm.prank(bob);
        write.burnFrom(alice, 250e18);
        assertEq(write.totalSupply(), 1_000_000_000e18 - 250e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        write.burnFrom(alice, 1);
    }

    function test_permit_setsAllowance() public {
        uint256 pk = 0xA11CE;
        address owner_ = vm.addr(pk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner_,
                bob,
                500e18,
                write.nonces(owner_),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", write.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        write.permit(owner_, bob, 500e18, deadline, v, r, s);
        assertEq(write.allowance(owner_, bob), 500e18);
        assertEq(write.nonces(owner_), 1);
    }

    function test_permit_revertsOnExpiredDeadline() public {
        uint256 pk = 0xA11CE;
        address owner_ = vm.addr(pk);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, bytes32(uint256(1)));
        vm.expectRevert();
        write.permit(owner_, bob, 1e18, deadline, v, r, s);
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    function testFuzz_burn_totalSupplyNeverExceedsMaxSupply(uint256 amount) public {
        _grantWrite(alice, 1_000e18, 1);
        amount = bound(amount, 0, 1_000e18);
        if (amount > 0) {
            vm.prank(alice);
            write.burn(amount);
        }
        assertLe(write.totalSupply(), write.MAX_SUPPLY(), "supply is monotonically non-increasing");
        assertEq(write.totalSupply(), 1_000_000_000e18 - amount);
    }

    function testFuzz_transfersConserveSupply(uint256 amount, uint256 toSeed) public {
        // House style bounds rather than assumes, so no run is ever discarded.
        address to = address(uint160(bound(toSeed, 1, type(uint160).max)));
        _grantWrite(alice, 1_000e18, 1);
        amount = bound(amount, 0, 1_000e18);
        uint256 supplyBefore = write.totalSupply();
        vm.prank(alice);
        write.transfer(to, amount);
        assertEq(write.totalSupply(), supplyBefore);
    }
}
