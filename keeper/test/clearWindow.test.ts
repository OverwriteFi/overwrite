import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { WEEKDAY, WEEKEND } from "../src/abi/index.js";
import {
  CLEAR_WARN_BEFORE,
  clearDeadline,
  clearSecondsLeft,
  clearWindowSeverity,
  retryOpenKind,
  scheduledOpenKind,
  weekdayOpenDue,
  weekendOpenAt,
  weekendOpenDue,
} from "../src/jobs/clearWindow.js";
import { AUCTION_DURATION, MON_1400, WEEK, weekStart } from "../src/time/epoch.js";
import { fridayCloseUtc } from "../src/time/nyse.js";

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

describe("the scheduled open (SPEC §5: tolerance is for lateness only)", () => {
  const monday = utc("2026-09-07T14:00:00Z");

  it("WEEKDAY is due at Monday 14:00:00 UTC, not one second before", () => {
    assert.ok(!weekdayOpenDue(monday - 1n, TOL));
    assert.ok(weekdayOpenDue(monday, TOL));
    assert.ok(weekdayOpenDue(monday + 30n, TOL));
  });

  it("WEEKDAY is not due in the early half of the contract's ± window (the 46630 demo opened at 12:00)", () => {
    assert.ok(!weekdayOpenDue(utc("2026-09-07T12:00:18Z"), TOL));
    assert.ok(!weekdayOpenDue(utc("2026-09-07T13:59:59Z"), TOL));
    assert.equal(scheduledOpenKind(utc("2026-09-07T12:00:18Z"), TOL, 0n), null);
  });

  it("WEEKDAY stays due up to openTolerance late, then stops", () => {
    assert.ok(weekdayOpenDue(monday + TOL, TOL));
    assert.ok(!weekdayOpenDue(monday + TOL + 1n, TOL));
    assert.ok(!weekdayOpenDue(utc("2026-09-08T14:00:00Z"), TOL)); // Tuesday
  });

  it("WEEKEND is due 600 s after the weekday expiry, not at the window's 19:40 start", () => {
    const fridayExpiry = utc("2026-09-11T20:00:00Z"); // EDT close
    const at = weekendOpenAt(utc("2026-09-11T19:45:00Z"), fridayExpiry);
    assert.equal(at, utc("2026-09-11T20:10:00Z"));
    assert.ok(!weekendOpenDue(utc("2026-09-11T19:40:00Z"), TOL, at));
    assert.ok(!weekendOpenDue(utc("2026-09-11T20:09:59Z"), TOL, at));
    assert.ok(weekendOpenDue(utc("2026-09-11T20:10:00Z"), TOL, at));
    assert.equal(scheduledOpenKind(utc("2026-09-11T20:10:00Z"), TOL, at), WEEKEND);
    assert.equal(scheduledOpenKind(utc("2026-09-11T20:05:00Z"), TOL, at), null);
  });

  it("WEEKEND in a week with no weekday series opens 600 s after the Friday close, DST-aware", () => {
    // EDT week: 16:00 ET = 20:00 UTC
    const edt = weekendOpenAt(utc("2026-09-11T12:00:00Z"), null);
    assert.equal(edt, utc("2026-09-11T20:10:00Z"));
    // EST week: 16:00 ET = 21:00 UTC
    const est = weekendOpenAt(utc("2026-11-06T12:00:00Z"), null);
    assert.equal(est, utc("2026-11-06T21:10:00Z"));
    assert.equal(est, fridayCloseUtc(weekStart(utc("2026-11-06T12:00:00Z"))) + 600n);
  });

  it("a previous week's weekday expiry does not anchor this week's weekend open", () => {
    const lastWeek = utc("2026-09-04T20:00:00Z");
    assert.equal(weekendOpenAt(utc("2026-09-11T12:00:00Z"), lastWeek), utc("2026-09-11T20:10:00Z"));
  });

  it("WEEKEND stops being due when the contract window closes; a Saturday is never due", () => {
    const at = utc("2026-09-11T20:10:00Z");
    assert.ok(weekendOpenDue(utc("2026-09-11T23:40:00Z"), TOL, at));
    assert.ok(!weekendOpenDue(utc("2026-09-11T23:40:01Z"), TOL, at));
    assert.ok(!weekendOpenDue(utc("2026-09-12T12:00:00Z"), TOL, at));
  });
});

describe("re-open after a skip (D-046 allows it; only worth it with bids)", () => {
  const monday = weekStart(utc("2026-09-07T14:00:00Z")) + MON_1400;

  it("never re-opens an empty book, in any window", () => {
    assert.equal(retryOpenKind(monday + 1_200n, TOL, 0), null);
    assert.equal(retryOpenKind(utc("2026-09-11T20:30:00Z"), TOL, 0), null);
  });

  it("re-opens a WEEKDAY series with bids skipped inside the Monday window", () => {
    // a skip at 14:20 (opened 14:00, closed 14:15, cleared late but inside the window)
    assert.equal(retryOpenKind(monday + 1_200n, TOL, 1), WEEKDAY);
    // the last second of the window
    assert.equal(retryOpenKind(monday + TOL, TOL, 3), WEEKDAY);
  });

  it("gives up once the Monday window has closed", () => {
    assert.equal(retryOpenKind(monday + TOL + 1n, TOL, 2), null);
    // the rehearsal's case: Monday's auction skipped by a Friday 20:00 clear cannot re-open a WEEKDAY
    // series, but Friday 20:00 is already inside the weekend window, so the WEEKEND series opens instead
    assert.equal(retryOpenKind(utc("2026-09-11T20:00:00Z"), TOL, 2), WEEKEND);
    assert.equal(retryOpenKind(utc("2026-09-11T19:30:00Z"), TOL, 2), null);
  });

  it("re-opens a WEEKEND series with bids skipped inside the Friday window", () => {
    assert.equal(retryOpenKind(utc("2026-09-11T20:30:00Z"), TOL, 1), WEEKEND);
    assert.equal(retryOpenKind(utc("2026-09-11T23:40:00Z"), TOL, 1), WEEKEND);
    assert.equal(retryOpenKind(utc("2026-09-11T23:40:01Z"), TOL, 1), null);
    assert.equal(retryOpenKind(utc("2026-09-12T12:00:00Z"), TOL, 1), null); // Saturday
  });

  it("uses the same tolerance the contract does", () => {
    const tight = 600n;
    assert.equal(retryOpenKind(monday + 601n, tight, 1), null);
    assert.equal(retryOpenKind(monday + WEEK + 600n, tight, 1), WEEKDAY);
  });
});
