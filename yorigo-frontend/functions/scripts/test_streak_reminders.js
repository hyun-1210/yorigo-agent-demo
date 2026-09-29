/**
 * streakReminders 순수 로직 단위 테스트.
 * 실행: node scripts/test_streak_reminders.js
 */
const assert = require("assert");
const {
  startOfKstDay,
  startOfKstWeekSunday,
  ymdKey,
  isKstSunday,
  normalizeStreakDayKey,
  extractAttendanceDayKeysFromUserData,
  computeDailyAttendanceStreakAtRisk,
  computeWeekAttendance,
  buildDailyStreakReminderMessage,
  buildWeeklyStreakReminderMessage,
  shouldSendWeeklyStreakReminder,
  koreanRoParticle,
} = require("../streakReminders");

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log("OK  " + name);
  } catch (e) {
    console.error("FAIL " + name);
    console.error(e);
    process.exitCode = 1;
  }
}

check("normalizeStreakDayKey pads months/days", () => {
  assert.strictEqual(normalizeStreakDayKey("2026-8-3"), "2026-08-03");
  assert.strictEqual(normalizeStreakDayKey("bad"), null);
});

check("startOfKstDay / ymdKey around KST midnight", () => {
  // 2026-08-02 15:30 UTC = 2026-08-03 00:30 KST
  const justAfterKstMidnight = new Date(Date.UTC(2026, 7, 2, 15, 30, 0));
  assert.strictEqual(ymdKey(startOfKstDay(justAfterKstMidnight)), "2026-08-03");

  // 2026-08-02 14:30 UTC = 2026-08-02 23:30 KST
  const justBeforeKstMidnight = new Date(Date.UTC(2026, 7, 2, 14, 30, 0));
  assert.strictEqual(ymdKey(startOfKstDay(justBeforeKstMidnight)), "2026-08-02");
});

check("startOfKstWeekSunday matches Sunday start", () => {
  // Wednesday 2026-08-05 KST
  const wed = new Date(Date.UTC(2026, 7, 4, 20, 0, 0)); // Aug 5 05:00 KST
  assert.strictEqual(ymdKey(startOfKstWeekSunday(wed)), "2026-08-02"); // Sunday
});

check("isKstSunday", () => {
  const sunday = new Date(Date.UTC(2026, 7, 1, 20, 0, 0)); // Aug 2 05:00 KST Sunday
  assert.strictEqual(isKstSunday(sunday), true);
  const monday = new Date(Date.UTC(2026, 7, 2, 20, 0, 0)); // Aug 3 05:00 KST Monday
  assert.strictEqual(isKstSunday(monday), false);
});

check("extractAttendanceDayKeysFromUserData nested + dotted", () => {
  const keys = extractAttendanceDayKeysFromUserData({
    attendanceDays: { "2026-08-01": true },
    "attendanceDays.2026-08-02": true,
  });
  assert.ok(keys.has("2026-08-01"));
  assert.ok(keys.has("2026-08-02"));
});

check("streak at risk counts yesterday chain when today missing", () => {
  const now = new Date(Date.UTC(2026, 7, 3, 9, 0, 0)); // Aug 3 18:00 KST
  const dayKeys = new Set(["2026-08-01", "2026-08-02"]);
  const result = computeDailyAttendanceStreakAtRisk(dayKeys, now);
  assert.strictEqual(result.hasTodayAttendance, false);
  assert.strictEqual(result.streakDays, 2);
  assert.strictEqual(result.todayKey, "2026-08-03");
});

check("streak zero when no yesterday attendance", () => {
  const now = new Date(Date.UTC(2026, 7, 3, 9, 0, 0));
  const dayKeys = new Set(["2026-07-30"]);
  const result = computeDailyAttendanceStreakAtRisk(dayKeys, now);
  assert.strictEqual(result.streakDays, 0);
  assert.strictEqual(result.hasTodayAttendance, false);
});

check("daily copy uses streak language only when streakDays >= 1", () => {
  const withStreak = buildDailyStreakReminderMessage({
    dayKey: "2026-08-03",
    uid: "u1",
    streakDays: 3,
  });
  assert.ok(withStreak.includes("연속"), withStreak);

  const noStreak = buildDailyStreakReminderMessage({
    dayKey: "2026-08-03",
    uid: "u1",
    streakDays: 0,
    fridgeIngredients: ["계란"],
  });
  assert.ok(!noStreak.includes("연속"), noStreak);
  assert.ok(noStreak.includes("계란"), noStreak);
});

check("weekly targeting requires week attendance and not today", () => {
  assert.strictEqual(
    shouldSendWeeklyStreakReminder({
      hasTodayAttendance: false,
      attendedDaysThisWeek: 2,
    }),
    true
  );
  assert.strictEqual(
    shouldSendWeeklyStreakReminder({
      hasTodayAttendance: true,
      attendedDaysThisWeek: 2,
    }),
    false
  );
  assert.strictEqual(
    shouldSendWeeklyStreakReminder({
      hasTodayAttendance: false,
      attendedDaysThisWeek: 0,
    }),
    false
  );
});

check("weekly copy mentions week count when attended", () => {
  const body = buildWeeklyStreakReminderMessage({
    weekStartKey: "2026-08-02",
    uid: "u1",
    attendedDaysThisWeek: 4,
  });
  assert.ok(body.includes("4"), body);
  assert.ok(body.includes("이번 주") || body.includes("주간"), body);
});

check("computeWeekAttendance sunday week window", () => {
  const now = new Date(Date.UTC(2026, 7, 5, 9, 0, 0)); // Wed Aug 5 18:00 KST
  const dayKeys = new Set(["2026-08-02", "2026-08-04", "2026-07-31"]);
  const week = computeWeekAttendance(dayKeys, now);
  assert.strictEqual(week.weekStartKey, "2026-08-02");
  assert.strictEqual(week.attendedDaysThisWeek, 2);
  assert.strictEqual(week.hasTodayAttendance, false);
});

check("korean particle", () => {
  assert.strictEqual(koreanRoParticle("계란"), "으로");
  assert.strictEqual(koreanRoParticle("사과"), "로");
});

console.log("\nPassed " + passed + " checks");
if (process.exitCode) {
  console.error("Some checks failed");
  process.exit(1);
}
