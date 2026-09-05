import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  FRI_1930,
  FRI_2130,
  MON_1400,
  SUN_2359,
  WEEK,
  inWeekdayOpenWindow,
  inWeekendOpenWindow,
  nextMonday1400,
  weekOffset,
  weekStart,
  weekendExpiryFor,
} from "../src/time/epoch.js";
import {
  CALENDAR_KNOWN_THROUGH,
  NYSE_EARLY_CLOSES,
  NYSE_HOLIDAYS,
  expiryCalendarNote,
  fridayCloseUtc,
  nyOffsetSeconds,
  sessionKind,
} from "../src/time/nyse.js";
import { DEFAULT_VARIANCE_PARAMS, sessionOn, varianceDays } from "../src/time/tradingTime.js";

const utc = (iso: string): bigint => BigInt(Date.parse(iso) / 1000);

describe("epoch weeks", () => {
  it("matches the AuctionHouse constants", () => {
    // Unix epoch 0 is a Thursday, so these offsets are measured from Thursday 00:00 UTC.
    assert.equal(weekOffset(utc("2026-09-07T14:00:00Z")), MON_1400);
    assert.equal(weekOffset(utc("2026-09-11T19:30:00Z")), FRI_1930);
    assert.equal(weekOffset(utc("2026-09-11T21:30:00Z")), FRI_2130);
    assert.equal(weekOffset(utc("2026-09-13T23:59:00Z")), SUN_2359);
    assert.equal(weekStart(utc("2026-09-07T14:00:00Z")), utc("2026-09-03T00:00:00Z"));
  });

  it("derives the weekend expiry from the Friday, not from the Monday", () => {
    // scheduledExpiry(WEEKEND, mondayTs) on chain returns a Sunday that has already passed, because
    // Monday is day 4 of its epoch week. Verified live: it answers 1788739140 for 1788789600.
    const monday = 1_788_789_600n;
    const naive = weekStart(monday) + SUN_2359;
    assert.ok(naive < monday, "the trap this helper exists to avoid");

    const fridayExpiry = fridayCloseUtc(weekStart(monday) + WEEK);
    const weekend = weekendExpiryFor(fridayExpiry);
    assert.equal(weekend, 1_789_343_940n);
    assert.ok(weekend > fridayExpiry, "the weekend expiry must follow its own weekday expiry");
    assert.equal(weekOffset(weekend), SUN_2359);
  });

  it("reproduces canOpen's two windows", () => {
    const tol = 7_200n;
    const monday = utc("2026-09-07T14:00:00Z");
    assert.ok(inWeekdayOpenWindow(monday, tol));
    assert.ok(inWeekdayOpenWindow(monday + 7_200n, tol));
    assert.ok(!inWeekdayOpenWindow(monday + 7_201n, tol));
    assert.ok(!inWeekdayOpenWindow(monday - 7_201n, tol));

    const weekendOpen = utc("2026-09-11T20:10:00Z");
    assert.ok(inWeekendOpenWindow(weekendOpen, tol));
    assert.ok(!inWeekendOpenWindow(utc("2026-09-11T19:00:00Z"), tol), "before Friday 19:40");
    assert.ok(
      !inWeekendOpenWindow(utc("2026-09-12T12:00:00Z"), tol),
      "a Saturday open must be impossible",
    );
  });

  it("nextMonday1400 is inclusive at the boundary", () => {
    const monday = utc("2026-09-07T14:00:00Z");
    assert.equal(nextMonday1400(monday), monday);
    assert.equal(nextMonday1400(monday + 1n), monday + WEEK);
  });
});

describe("NYSE close in UTC", () => {
  it("matches the deployed scheduledExpiry for the reference week", () => {
    // auctionHouse.scheduledExpiry(WEEKDAY, 1788789600) returns 1789156800 on chain.
    assert.equal(fridayCloseUtc(weekStart(1_788_789_600n) + WEEK), 1_789_156_800n);
  });

  it("tracks both 2026 DST transitions and keeps every expiry inside the contract band", () => {
    const fridays = [
      "2026-03-13",
      "2026-03-06", // side of the 8 Mar transition
      "2026-09-11",
      "2026-10-30",
      "2026-11-06", // side of the 1 Nov transition
      "2026-04-03",
      "2026-06-19",
      "2026-07-03",
      "2026-11-27",
      "2026-12-25",
      "2027-01-01",
      "2027-03-26",
      "2027-06-18",
      "2027-12-24",
    ];
    for (const d of fridays) {
      const t = fridayCloseUtc(utc(`${d}T00:00:00Z`) - 86_400n);
      const off = weekOffset(t);
      assert.ok(
        off >= FRI_1930 && off <= FRI_2130,
        `${d} expiry at offset ${off} is outside [FRI_1930, FRI_2130]`,
      );
      assert.ok(
        off === 158_400n || off === 162_000n,
        `${d} must be 20:00 (EDT) or 21:00 (EST) UTC, got ${off}`,
      );
    }
  });

  it("reports the exact US offsets", () => {
    assert.equal(nyOffsetSeconds(1_789_156_800n), -14_400, "EDT");
    assert.equal(nyOffsetSeconds(1_793_998_800n), -18_000, "EST");
  });

  it("classifies holidays and half-days without moving the expiry", () => {
    const goodFriday = fridayCloseUtc(utc("2026-04-03T00:00:00Z") - 86_400n);
    assert.equal(sessionKind(goodFriday), "holiday");
    assert.match(String(expiryCalendarNote(goodFriday)), /full NYSE closure/);

    const blackFriday = fridayCloseUtc(utc("2026-11-27T00:00:00Z") - 86_400n);
    assert.equal(sessionKind(blackFriday), "early-close");
    assert.match(String(expiryCalendarNote(blackFriday)), /13:00 ET early close/);

    const normal = fridayCloseUtc(utc("2026-09-11T00:00:00Z") - 86_400n);
    assert.equal(expiryCalendarNote(normal), null);
  });

  it("has a well-formed, in-range calendar table", () => {
    for (const d of [...NYSE_HOLIDAYS, ...NYSE_EARLY_CLOSES]) {
      assert.match(d, /^20\d\d-\d\d-\d\d$/);
      assert.ok(d <= CALENDAR_KNOWN_THROUGH, `${d} is past the declared coverage end`);
    }
    assert.equal(new Set(NYSE_HOLIDAYS).size, NYSE_HOLIDAYS.length, "no duplicate holidays");
  });
});

describe("variance time", () => {
  it("skips weekends and holidays when enumerating sessions", () => {
    assert.equal(sessionOn(utc("2026-09-12T00:00:00Z")), null, "Saturday");
    assert.equal(sessionOn(utc("2026-09-13T00:00:00Z")), null, "Sunday");
    assert.equal(sessionOn(utc("2026-04-03T00:00:00Z")), null, "Good Friday");
    assert.ok(sessionOn(utc("2026-09-11T00:00:00Z")), "a normal Friday");
  });

  it("prices an early close as roughly half a session", () => {
    const day = utc("2026-11-27T00:00:00Z");
    const full = varianceDays(utc("2026-11-30T14:30:00Z"), utc("2026-11-30T21:00:00Z"));
    const half = varianceDays(day + 14n * 3600n + 30n * 60n, day + 18n * 3600n);
    assert.ok(
      full > 0.9 && full < 1.05,
      `a full session should be ~1.0 variance-days, got ${full}`,
    );
    assert.ok(half > 0.4 && half < 0.6, `a 13:00 ET close should be ~0.54, got ${half}`);
  });

  it("gives the weekend far less variance than the trading week it follows", () => {
    // This is the whole point: Fri 16:10 ET -> Sun 23:59 UTC is 2.16 calendar days and zero sessions.
    // 14 Sep 2026 is an ordinary Monday; 7 Sep is Labor Day, covered separately below.
    const weekday = varianceDays(utc("2026-09-14T14:00:00Z"), utc("2026-09-18T20:00:00Z"));
    const weekend = varianceDays(utc("2026-09-18T20:10:00Z"), utc("2026-09-20T23:59:00Z"));

    assert.ok(
      weekday > 4.5 && weekday < 6.5,
      `Mon 14:00 -> Fri close should be ~5.5 sessions, got ${weekday}`,
    );
    assert.ok(
      weekend <= DEFAULT_VARIANCE_PARAMS.weekendVarianceDays + 1e-9,
      `a weekend carries at most one weekend gap, got ${weekend}`,
    );
    assert.ok(weekend < weekday / 10, "the weekend must be a small fraction of the weekday series");
  });

  it("counts a holiday week as one session lighter, and still sees the long-weekend gap", () => {
    // Labor Day 2026 falls on Monday 7 September, so that week has four sessions, not five. The gap
    // before Tuesday's open spans four idle days and must still be counted: a one-day lookback when
    // enumerating sessions dropped it, which is what this case pins down.
    const holidayWeek = varianceDays(utc("2026-09-07T14:00:00Z"), utc("2026-09-11T20:00:00Z"));
    const normalWeek = varianceDays(utc("2026-09-14T14:00:00Z"), utc("2026-09-18T20:00:00Z"));

    assert.ok(
      holidayWeek < normalWeek,
      "a four-session week must carry less variance than a five-session one",
    );
    assert.ok(holidayWeek > 4.5, `the long-weekend gap must be counted, got ${holidayWeek}`);
  });

  it("is zero for a reversed or empty interval", () => {
    const t = utc("2026-09-09T15:00:00Z");
    assert.equal(varianceDays(t, t), 0);
    assert.equal(varianceDays(t + 3600n, t), 0);
  });
});
