// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SettlementBaseTest} from "./SettlementBase.t.sol";
import {CapController} from "../src/CapController.sol";
import {TokenDeployLib} from "../script/TokenDeployLib.sol";
import {WRITE} from "../src/WRITE.sol";
import {LiquidityEscrow} from "../src/LiquidityEscrow.sol";
import {EmissionsController} from "../src/EmissionsController.sol";
import {Vesting} from "../src/Vesting.sol";
import {PointsDistributor} from "../src/PointsDistributor.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {SafetyModule} from "../src/SafetyModule.sol";
import {OracleMath} from "../src/libraries/OracleMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockUniswapV3Pool} from "../src/mocks/MockUniswapV3Pool.sol";
import {MockLaunchpad} from "./mocks/MockLaunchpad.sol";

/// @dev Full stack (real RiskModule, SettlementOracle, AuctionHouse, vault) plus the whole WRITE token layer,
/// deployed through `script/TokenDeployLib.sol` so this fixture cannot drift from the real deployment.
/// The real safety module is named `sm`: `Base.t.sol` already declares `MockSafetyModule safetyModule`, which
/// stays constructed and unused so `CapControllerTest` keeps its isolation.
/// The WRITE/USDG pool is created with address-sorted tokens exactly as Uniswap would, and the tick is derived
/// by binary search over the production math rather than hardcoded — a hardcoded tick is wrong by tens of
/// ticks and prices WRITE a little off the nominal figure, so every price expectation is taken from the live
/// oracle instead (D-096).
abstract contract TokenBaseTest is SettlementBaseTest {
    WRITE internal write;
    LiquidityEscrow internal escrow;
    EmissionsController internal emis;
    Vesting internal treasuryVesting;
    Vesting internal teamVesting;
    PointsDistributor internal points;
    WritePriceOracle internal wOracle;
    SafetyModule internal sm;
    MockUniswapV3Pool internal writePool;
    MockLaunchpad internal launchpad;

    address internal curator = makeAddr("curator");
    address internal staker1 = makeAddr("staker1");
    address internal staker2 = makeAddr("staker2");
    address internal teamMember = makeAddr("teamMember");
    address internal shortfallReserve = makeAddr("shortfallReserve");

    uint256 internal constant WRITE_PRICE_8 = 0.1e8; // nominal launch price, $0.10
    uint256 internal constant SANITY_LOW_8 = 0.005e8;
    uint256 internal constant SANITY_HIGH_8 = 5.0e8;
    uint64 internal constant EMISSIONS_DURATION = 4 * 365 days;
    uint24 internal constant WRITE_POOL_FEE = 500;
    uint128 internal constant WRITE_POOL_LIQ = 1e24; // clears the 250 000 USDG / 1 % depth rule comfortably
    uint256 internal constant STAKE_1 = 60_000_000e18;
    uint256 internal constant STAKE_2 = 40_000_000e18;

    int24 internal writeTick;

    function setUp() public virtual override {
        super.setUp();

        TokenDeployLib.Params memory p = TokenDeployLib.Params({
            owner: admin,
            treasury: treasury,
            usdg: address(usdg),
            usdgUsdFeed: address(usdgFeed),
            emissionsDuration: EMISSIONS_DURATION,
            sanityLow8: SANITY_LOW_8,
            sanityHigh8: SANITY_HIGH_8
        });

        vm.startPrank(admin);
        TokenDeployLib.Deployment memory d = TokenDeployLib.deploy(p);
        vm.stopPrank();

        write = d.write;
        escrow = d.escrow;
        emis = d.emissions;
        treasuryVesting = d.treasuryVesting;
        teamVesting = d.teamVesting;
        points = d.points;
        wOracle = d.oracle;
        sm = d.safetyModule;

        _createWritePool();
        launchpad = new MockLaunchpad(address(write));

        vm.startPrank(admin);
        escrow.setPool(address(launchpad));
        escrow.fundAll();
        wOracle.setPool(address(writePool));
        vm.stopPrank();

        vm.label(address(write), "WRITE");
        vm.label(address(sm), "safetyModule");
        vm.label(address(wOracle), "writePriceOracle");
        vm.label(address(emis), "emissionsController");
        vm.label(address(writePool), "writePool");
        vm.label(address(points), "pointsDistributor");
    }

    // ───────────────────────────── pool helpers (D-096) ─────────────────────────────

    /// @dev Creates the WRITE/USDG pool with address-sorted tokens, exactly as Uniswap v3 would, and seeds an
    /// observation history long enough to answer the configured TWAP window.
    function _createWritePool() internal {
        bool writeIsToken1 = address(write) > address(usdg);
        address t0 = writeIsToken1 ? address(usdg) : address(write);
        address t1 = writeIsToken1 ? address(write) : address(usdg);
        writeTick = _tickForWritePrice(WRITE_PRICE_8, writeIsToken1);

        uint32 start = uint32(block.timestamp - 2 days);
        writePool = new MockUniswapV3Pool(t0, t1, WRITE_POOL_FEE, writeTick, WRITE_POOL_LIQ, start);
        for (uint256 t = start + 1 hours; t <= block.timestamp; t += 1 hours) {
            writePool.write(uint32(t), writeTick, WRITE_POOL_LIQ);
        }
    }

    /// @dev The 8-decimal price the pool math actually produces at `tick`.
    function _priceAtTick(int24 tick, bool writeIsToken1) internal pure returns (uint256) {
        return OracleMath.quotePrice8(TickMath.getSqrtRatioAtTick(tick), writeIsToken1, 18, 6);
    }

    /// @dev Binary search over the production math for the tick closest to `target8`. `quotePrice8` is
    /// monotonic in tick: decreasing when WRITE is token1, increasing when it is token0.
    function _tickForWritePrice(uint256 target8, bool writeIsToken1) internal view returns (int24) {
        int256 lo = -600_000;
        int256 hi = 600_000;
        while (hi - lo > 1) {
            int256 mid = lo + (hi - lo) / 2;
            uint256 p = _priceAtTick(int24(mid), writeIsToken1);
            bool goHigher = writeIsToken1 ? (p > target8) : (p < target8);
            if (goHigher) lo = mid;
            else hi = mid;
        }
        return int24(lo);
    }

    /// @dev The live oracle price. Every downstream expectation is derived from this, never from the nominal
    /// $0.10, because the achievable tick prices WRITE a fraction of a basis point off (D-096).
    function _writePrice8() internal view returns (uint256 price8) {
        bool ok;
        (price8, ok) = wOracle.writePrice();
        assertTrue(ok, "write price unavailable");
    }

    /// @dev Moves the pool to a new price and extends its history so the window stays answerable.
    function _setWritePrice(uint256 target8) internal {
        int24 tick = _tickForWritePrice(target8, wOracle.writeIsToken1());
        writeTick = tick;
        writePool.write(uint32(block.timestamp), tick, WRITE_POOL_LIQ);
        vm.warp(block.timestamp + wOracle.twapWindow() + 1);
        writePool.write(uint32(block.timestamp), tick, WRITE_POOL_LIQ);
        _refreshWriteOracle();
    }

    /// @dev After a long warp both oracle legs need attention: the USDG/USD feed goes stale after 80 h and
    /// the pool needs an observation inside the window.
    function _refreshWriteOracle() internal {
        _usdgFresh();
        writePool.write(uint32(block.timestamp), writeTick, WRITE_POOL_LIQ);
    }

    /// @dev Warps forward and keeps every oracle leg answerable, which a bare `vm.warp` would not.
    function _warpWithOracles(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        _refreshWriteOracle();
        _feedRoundAt(block.timestamp - 30 minutes, PRICE);
    }

    // ───────────────────────────── token helpers ─────────────────────────────

    /// @dev Funds `to` with WRITE out of the points bucket via a single-leaf round, which is also how a real
    /// bond grant reaches an MM. Keeps the fixture free of any mint path (WRITE has none).
    function _grantWrite(address to, uint256 amount, uint256 roundId) internal {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = points.leafHash(roundId, 0, to, amount);
        vm.prank(admin);
        points.setRound(roundId, leaves[0], amount, uint64(block.timestamp), uint64(block.timestamp + 30 days));
        bytes32[] memory proof = new bytes32[](0);
        points.claim(roundId, 0, to, amount, proof);
    }

    /// @dev Simulates buying WRITE on the launch venue. Stakers get their tokens from the market float, not
    /// from the airdrop bucket — `_grantWrite` models the airdrop and bond-grant path, which is a different
    /// and much smaller source.
    function _buyWrite(address to, uint256 amount) internal {
        vm.prank(address(launchpad));
        write.transfer(to, amount);
    }

    function _stake(address who, uint256 amount) internal returns (uint256 shares) {
        _buyWrite(who, amount);
        vm.startPrank(who);
        write.approve(address(sm), type(uint256).max);
        shares = sm.stake(amount);
        vm.stopPrank();
    }

    /// @dev Switches the CapController to the post-token formula: cap = k x safetyModuleValueUSD x weight.
    function _enableSafetyModuleCap(uint256 weightBps) internal {
        vm.startPrank(admin);
        cap.setSafetyModule(address(sm));
        cap.setCapWeightBps(address(vault), weightBps);
        cap.setCapMode(CapController.CapMode.SAFETY_MODULE);
        vm.stopPrank();
    }
}
