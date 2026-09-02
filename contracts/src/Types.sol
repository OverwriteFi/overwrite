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
