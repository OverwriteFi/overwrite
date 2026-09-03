// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared enums for the Overwrite protocol (SPEC §4.4, §6).
enum SeriesKind {
    WEEKDAY,
    WEEKEND
}

enum VaultState {
    IDLE,
    AUCTION,
    LIVE,
    HALTED
}

enum SeriesState {
    NONE,
    AUCTION,
    SKIPPED,
    LIVE,
    SETTLED,
    HALTED,
    RESOLVED
}

/// @notice Oracle policy parameters (SPEC §6, §9; D-031). Stored as versions per vault in RiskModule and read
/// by SettlementOracle through `paramsAt(vault, auctionOpen)`, so a series is governed by the version in effect
/// when its auction opened. Packed into three storage slots.
struct OracleParams {
    uint32 weekdayMaxStale; // s, §9.2 (default 26 h)
    uint32 twapGrace; // s, §9.3 (default 1 800)
    uint32 sequencerGrace; // s, §9.1 (default 3 600)
    uint32 usdgMaxStale; // s, §9.5 (default 26 h)
    uint16 weekendTwapBoundBps; // §9.3 (default 1 500)
    uint16 weekdayTwapBoundBps; // §9.2 (default 300)
    uint16 impactBps; // §9.3 (default 100)
    uint16 jumpBps; // §9.1, D-025 (default 3 000)
    uint16 usdgBandLowBps; // §9.5 (default 9 800)
    uint16 usdgBandHighBps; // §9.5 (default 10 200)
    uint8 minObservationsInWindow; // §9.5, D-019 (default 3)
    uint128 swapNotionalUSDG; // §9.3 (default 250 000e6)
    address sequencerFeed; // §9.1, D-005 (default 0 = disabled)
}
