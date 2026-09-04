// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WRITE} from "../../src/WRITE.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {BondManager} from "../../src/BondManager.sol";
import {WritePriceOracle} from "../../src/WritePriceOracle.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {IBondManager} from "../../src/interfaces/IBondManager.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";

/// @dev Drives the two paths the token layer added to already-deployed contracts: the FeeRouter's WRITE fee
/// mode and the BondManager's dual-asset ledger. `AuctionHandler` deliberately stays out of both (D-097), so
/// without this suite neither had any invariant coverage.
contract WriteFeeBondHandler is Test {
    struct Deps {
        WRITE write;
        MockUSDG usdg;
        FeeRouter fr;
        BondManager bm;
        WritePriceOracle oracle;
        MockUniswapV3Pool pool;
        address admin;
        address auctionHouse;
        address vault;
        address curator;
    }

    WRITE public immutable write;
    MockUSDG public immutable usdg;
    FeeRouter public immutable fr;
    BondManager public immutable bm;
    WritePriceOracle public immutable oracle;
    MockUniswapV3Pool public immutable pool;
    address public immutable admin;
    address public immutable auctionHouse;
    address public immutable vault;
    address public immutable curator;

    address[3] public mms;

    uint256 public calls;
    uint256 public collected;
    uint256 public flushed;
    uint256 public writeDeposited;
    uint256 public writeWithdrawn;
    uint256 public writeBurned;
    uint256 public writeToTreasury;
    uint256 public bondsPosted;
    uint256 public bondsWithdrawn;
    uint256 public migrations;
    int24 public tick;

    modifier count() {
        calls++;
        _;
    }

    constructor(Deps memory d, address[3] memory mms_, int24 tick_) {
        write = d.write;
        usdg = d.usdg;
        fr = d.fr;
        bm = d.bm;
        oracle = d.oracle;
        pool = d.pool;
        admin = d.admin;
        auctionHouse = d.auctionHouse;
        vault = d.vault;
        curator = d.curator;
        mms = mms_;
        tick = tick_;
    }

    // ───────────────────────────── FeeRouter ─────────────────────────────

    function collectFee(uint256 amountSeed) external count {
        uint256 amount = bound(amountSeed, 1e6, 10_000e6);
        usdg.mint(auctionHouse, amount);
        vm.prank(auctionHouse);
        fr.collect(vault, calls, amount);
        collected += amount;
    }

    function flush() external count {
        if (fr.pending(vault) == 0) return;
        uint256 supplyBefore = write.totalSupply();
        uint256 treasuryBefore = write.balanceOf(fr.treasury());
        uint256 amount = fr.flush(vault);
        flushed += amount;
        writeBurned += supplyBefore - write.totalSupply();
        writeToTreasury += write.balanceOf(fr.treasury()) - treasuryBefore;
    }

    function depositWrite(uint256 amountSeed) external count {
        if (fr.writeToken() == address(0) || fr.curatorOf(vault) == address(0)) return;
        uint256 bal = write.balanceOf(curator);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(curator);
        fr.depositWrite(vault, amount);
        writeDeposited += amount;
    }

    function withdrawWrite(uint256 amountSeed) external count {
        if (fr.writeToken() == address(0) || fr.curatorOf(vault) != curator) return;
        uint256 bal = fr.writeBalance(vault);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        // A booked fee stays reserved (D-098); the contract enforces it, the handler avoids the revert.
        if (fr.mode(vault) == IFeeRouter.FeeMode.WRITE && fr.pending(vault) != 0) {
            (uint256 needed, bool ok) = fr.previewWriteFee(fr.pending(vault));
            if (ok && bal - amount < needed) return;
        }
        vm.prank(curator);
        fr.withdrawWrite(vault, amount);
        writeWithdrawn += amount;
    }

    function setWriteMode(uint256 seed) external count {
        if (fr.writeToken() == address(0) || fr.priceOracle() == address(0)) return;
        IFeeRouter.FeeMode mode = seed % 2 == 0 ? IFeeRouter.FeeMode.WRITE : IFeeRouter.FeeMode.USDG;
        vm.prank(admin);
        fr.setFeeMode(vault, mode);
    }

    /// @dev Moves the WRITE price, so the fee path is exercised across a range of quotes and the oracle's
    /// out-of-band and no-price branches are both reachable.
    function movePrice(int256 tickSeed) external count {
        int24 next = int24(bound(tickSeed, int256(tick) - 60_000, int256(tick) + 60_000));
        pool.write(uint32(block.timestamp), next, 1e24);
        tick = next;
    }

    // ───────────────────────────── BondManager ─────────────────────────────

    function postBond(uint256 seed, uint256 assetSeed) external count {
        address mm = mms[seed % 3];
        IBondManager.BondAsset asset = assetSeed % 2 == 0 ? IBondManager.BondAsset.USDG : IBondManager.BondAsset.WRITE;
        if (!bm.assetAccepted(asset)) return;
        uint256 required = bm.requiredAmountOf(asset, IBondManager.BondKind.MM);
        if (required == 0) return;
        (uint256 have,, uint64 unlockAt) = bm.statusIn(mm, IBondManager.BondKind.MM, asset);
        if (unlockAt != 0 || have >= required) return;

        address token = bm.assetToken(asset);
        if (token == address(0)) return;
        uint256 owed = required - have;
        if (token == address(usdg) && usdg.balanceOf(mm) < owed) usdg.mint(mm, owed);
        if (token == address(write) && write.balanceOf(mm) < owed) return;

        vm.prank(mm);
        bm.postBondIn(IBondManager.BondKind.MM, asset);
        bondsPosted++;
    }

    function withdrawBond(uint256 seed, uint256 assetSeed) external count {
        address mm = mms[seed % 3];
        IBondManager.BondAsset asset = assetSeed % 2 == 0 ? IBondManager.BondAsset.USDG : IBondManager.BondAsset.WRITE;
        (uint256 have,, uint64 unlockAt) = bm.statusIn(mm, IBondManager.BondKind.MM, asset);
        if (have == 0) return;

        if (bm.assetAccepted(asset)) {
            if (unlockAt == 0) {
                vm.prank(mm);
                bm.requestWithdrawIn(IBondManager.BondKind.MM, asset);
                return;
            }
            if (block.timestamp < unlockAt) return;
        }
        vm.prank(mm);
        bm.withdrawBondIn(IBondManager.BondKind.MM, asset);
        bondsWithdrawn++;
    }

    function startMigration(uint256 graceSeed) external count {
        if (bm.migrationEndsAt() != 0 || bm.writeToken() == address(0)) return;
        if (bm.requiredAmountOf(IBondManager.BondAsset.WRITE, IBondManager.BondKind.MM) == 0) return;
        vm.prank(admin);
        bm.startMigration(uint64(bound(graceSeed, 1 days, 90 days)));
        migrations++;
    }

    function warp(uint256 dt) external count {
        vm.warp(block.timestamp + bound(dt, 1 hours, 20 days));
    }

    // ───────────────────────────── views ─────────────────────────────

    function sumBondLegs(IBondManager.BondAsset asset) external view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) {
            (uint256 amount,,) = bm.statusIn(mms[i], IBondManager.BondKind.MM, asset);
            total += amount;
        }
    }
}
