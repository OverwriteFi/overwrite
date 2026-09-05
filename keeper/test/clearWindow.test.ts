import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { WEEKDAY, WEEKEND } from "../src/abi/index.js";
import {
  CLEAR_WARN_BEFORE,
  clearDeadline,
  clearSecondsLeft,
  clearWindowSeverity,
  retryOpenKind,
} from "../src/jobs/clearWindow.js";
import { AUCTION_DURATION, MON_1400, WEEK, weekStart } from "../src/time/epoch.js";

const utc = (iso: string): bigint => BigInt(Date.parse(iso) / 1000);
const GRACE = 3_600n; // AuctionHouse.clearGrace default (D-113 F-2)
const TOL = 7_200n; // AuctionHouse.openTolerance default

describe("clear window (REHEARSAL-1 S-1)", () => {
  const open = utc("2026-09-07T14:00:00Z"); // Monday 14:00
  const close = open + AUCTION_DURATION; // 14:15

  it("is ok right after the auction closes and warn inside the last 15 minutes", () => {
    assert.equal(clearDeadline(close, GRACE), utc("2026-09-07T15:15:00Z"));
    assert.equal(clearWindowSeverity(close, close, GRACE), "ok");
    assert.equal(clearWindowSeverity(close + 1_800n, close, GRACE), "ok");
    // exactly 15 minutes before the deadline is the first WARN second
    assert.equal(clearWindowSeverity(close + GRACE - CLEAR_WARN_BEFORE - 1n, close, GRACE), "ok");
    assert.equal(clearWindowSeverity(close + GRACE - CLEAR_WARN_BEFORE, close, GRACE), "warn");
    assert.equal(clearWindowSeverity(close + GRACE - 1n, close, GRACE), "warn");
  });

  it("is crit from the deadline on: the next clear skips the series", () => {
    assert.equal(clearWindowSeverity(close + GRACE, close, GRACE), "crit");
    assert.equal(clearWindowSeverity(close + 5n * 86_400n, close, GRACE), "crit");
    assert.equal(clearSecondsLeft(close + GRACE, close, GRACE), 0n);
    assert.equal(clearSecondsLeft(close, close, GRACE), GRACE);
  });

  it("does not warn before the auction has even closed", () => {
    assert.equal(clearWindowSeverity(open, close, GRACE), "ok");
  });

  it("honours a timelocked clearGrace: a 5-minute grace is warn from the close", () => {
    assert.equal(clearWindowSeverity(close, close, 300n), "warn");
    assert.equal(clearWindowSeverity(close + 300n, close, 300n), "crit");
  });
});

describe("re-open after a skip (D-046 allows it)", () => {
  const monday = weekStart(utc("2026-09-07T14:00:00Z")) + MON_1400;

  it("re-opens a WEEKDAY series skipped inside the Monday window", () => {
    // a skip at 14:20 (opened 14:00, closed 14:15, cleared late but inside the window)
    assert.equal(retryOpenKind(monday + 1_200n, TOL), WEEKDAY);
    // the last second of the window
    assert.equal(retryOpenKind(monday + TOL, TOL), WEEKDAY);
  });

  it("gives up once the Monday window has closed", () => {
    assert.equal(retryOpenKind(monday + TOL + 1n, TOL), null);
    // the rehearsal's case: Monday's auction skipped by a Friday 20:00 clear cannot re-open a WEEKDAY
    // series, but Friday 20:00 is already inside the weekend window, so the WEEKEND series opens instead
    assert.equal(retryOpenKind(utc("2026-09-11T20:00:00Z"), TOL), WEEKEND);
    assert.equal(retryOpenKind(utc("2026-09-11T19:30:00Z"), TOL), null);
  });

  it("re-opens a WEEKEND series skipped inside the Friday window", () => {
    assert.equal(retryOpenKind(utc("2026-09-11T20:30:00Z"), TOL), WEEKEND);
    assert.equal(retryOpenKind(utc("2026-09-11T23:40:00Z"), TOL), WEEKEND);
    assert.equal(retryOpenKind(utc("2026-09-11T23:40:01Z"), TOL), null);
    assert.equal(retryOpenKind(utc("2026-09-12T12:00:00Z"), TOL), null); // Saturday
  });

  it("uses the same tolerance the contract does", () => {
    const tight = 600n;
    assert.equal(retryOpenKind(monday + 601n, tight), null);
    assert.equal(retryOpenKind(monday + WEEK + 600n, tight), WEEKDAY);
  });
});
