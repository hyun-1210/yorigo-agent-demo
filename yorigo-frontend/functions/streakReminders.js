/**
 * 출석(스트릭) 리마인드 — 순수 로직.
 * Cloud Functions 스케줄러와 단위 테스트에서 공유한다.
 */

const DAY_MS = 24 * 60 * 60 * 1000;
const KST_OFFSET_MS = 9 * 60 * 60 * 1000;

/**
 * @param {Date} date
 * @returns {Date} KST 달력일 00:00을 UTC Date로 표현
 */
function startOfKstDay(date) {
  const kst = new Date(date.getTime() + KST_OFFSET_MS);
  return new Date(Date.UTC(kst.getUTCFullYear(), kst.getUTCMonth(), kst.getUTCDate()));
}

/**
 * 앱 프로필 주간 UI와 동일: 일요일 시작.
 * @param {Date} date
 * @returns {Date}
 */
function startOfKstWeekSunday(date) {
  const dayStart = startOfKstDay(date);
  const weekday = dayStart.getUTCDay(); // 0=Sun
  return new Date(dayStart.getTime() - weekday * DAY_MS);
}

/**
 * @param {Date} date
 * @returns {string} YYYY-MM-DD
 */
function ymdKey(date) {
  return date.toISOString().slice(0, 10);
}

/**
 * @param {Date=} now
 * @returns {boolean} KST 기준 일요일
 */
function isKstSunday(now = new Date()) {
  return startOfKstDay(now).getUTCDay() === 0;
}

/**
 * @param {string} raw
 * @returns {string | null}
 */
function normalizeStreakDayKey(raw) {
  const match = String(raw || "").trim().match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) {
    return null;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

/**
 * @param {Record<string, unknown>} userData
 * @returns {Set<string>}
 */
function extractAttendanceDayKeysFromUserData(userData) {
  const dayKeys = new Set();
  const attendanceDays = userData && userData.attendanceDays;
  if (attendanceDays && typeof attendanceDays === "object") {
    Object.keys(attendanceDays).forEach((key) => {
      const normalized = normalizeStreakDayKey(key);
      if (normalized) dayKeys.add(normalized);
    });
  }

  const prefix = "attendanceDays.";
  Object.keys(userData || {}).forEach((key) => {
    if (!key.startsWith(prefix)) return;
    const normalized = normalizeStreakDayKey(key.slice(prefix.length));
    if (normalized) dayKeys.add(normalized);
  });
  return dayKeys;
}

/**
 * @param {Set<string>} dayKeys
 * @param {Date=} now
 * @returns {{ streakDays: number, hasTodayAttendance: boolean, todayKey: string }}
 */
function computeDailyAttendanceStreakAtRisk(dayKeys, now = new Date()) {
  const todayStart = startOfKstDay(now);
  const todayKey = ymdKey(todayStart);
  const hasTodayAttendance = dayKeys.has(todayKey);

  let streakDays = 0;
  let cursor = hasTodayAttendance
    ? new Date(todayStart.getTime())
    : new Date(todayStart.getTime() - DAY_MS);
  while (true) {
    const key = ymdKey(cursor);
    if (!dayKeys.has(key)) break;
    streakDays += 1;
    cursor = new Date(cursor.getTime() - DAY_MS);
  }

  return { streakDays, hasTodayAttendance, todayKey };
}

/**
 * @param {Set<string>} dayKeys
 * @param {Date=} now
 * @returns {{ weekStartKey: string, attendedDaysThisWeek: number, hasTodayAttendance: boolean }}
 */
function computeWeekAttendance(dayKeys, now = new Date()) {
  const todayStart = startOfKstDay(now);
  const todayKey = ymdKey(todayStart);
  const weekStart = startOfKstWeekSunday(now);
  const weekStartKey = ymdKey(weekStart);

  let attendedDaysThisWeek = 0;
  for (let i = 0; i < 7; i += 1) {
    const key = ymdKey(new Date(weekStart.getTime() + i * DAY_MS));
    if (dayKeys.has(key)) attendedDaysThisWeek += 1;
  }

  return {
    weekStartKey,
    attendedDaysThisWeek,
    hasTodayAttendance: dayKeys.has(todayKey),
  };
}

/**
 * @param {string} raw
 * @param {number} maxLen
 * @returns {string}
 */
function shortenReminderLabel(raw, maxLen = 12) {
  const text = String(raw || "").trim().replace(/\s+/g, " ");
  if (!text) return "";
  if (text.length <= maxLen) return text;
  return `${text.slice(0, Math.max(1, maxLen - 1))}…`;
}

/**
 * @param {string} word
 * @returns {string}
 */
function koreanRoParticle(word) {
  const text = shortenReminderLabel(word, 64);
  if (!text) return "로";
  const ch = text[text.length - 1];
  const code = ch.charCodeAt(0);
  if (code < 0xac00 || code > 0xd7a3) return "로";
  const jong = (code - 0xac00) % 28;
  if (jong === 0 || jong === 8) return "로";
  return "으로";
}

/**
 * @param {string} dayKey
 * @param {string} uid
 * @param {number} modulo
 * @returns {number}
 */
function reminderRotationIndex(dayKey, uid, modulo) {
  if (!modulo || modulo <= 0) return 0;
  const seed = `${dayKey}:${uid || ""}`;
  let hash = 0;
  for (let i = 0; i < seed.length; i += 1) {
    hash = (hash * 31 + seed.charCodeAt(i)) >>> 0;
  }
  return hash % modulo;
}

/**
 * @param {Record<string, unknown>} userData
 * @returns {string[]}
 */
function extractFridgeIngredientNames(userData) {
  const fridge =
    userData && typeof userData.fridgeData === "object" && userData.fridgeData
      ? userData.fridgeData
      : {};
  const ingredients = Array.isArray(fridge.ingredients) ? fridge.ingredients : [];
  const names = [];
  const seen = new Set();
  for (const raw of ingredients) {
    if (!raw || typeof raw !== "object") continue;
    const name = shortenReminderLabel(
      raw.item || raw.name || raw.ingredientName || raw.displayName || ""
    );
    if (!name) continue;
    const key = name.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    names.push(name);
    if (names.length >= 2) break;
  }
  return names;
}

/**
 * @param {Record<string, unknown>} userData
 * @returns {string}
 */
function extractFridgeRecipeTitle(userData) {
  const fridge =
    userData && typeof userData.fridgeData === "object" && userData.fridgeData
      ? userData.fridgeData
      : {};
  const recipes = Array.isArray(fridge.recipes) ? fridge.recipes : [];
  for (const raw of recipes) {
    if (!raw || typeof raw !== "object") continue;
    const title = shortenReminderLabel(
      raw.recipeName || raw.title || raw.name || ""
    );
    if (title) return title;
  }
  return "";
}

/**
 * 일일 출석 리마인드 본문.
 * streakDays >= 1 일 때만 "연속 출석" 카피 사용.
 * @param {{
 *   dayKey: string,
 *   uid: string,
 *   streakDays?: number,
 *   fridgeIngredients?: string[],
 *   recipeTitle?: string,
 *   trendingTitle?: string,
 * }} opts
 * @returns {string}
 */
function buildDailyStreakReminderMessage(opts) {
  const dayKey = String((opts && opts.dayKey) || "").trim();
  const uid = String((opts && opts.uid) || "").trim();
  const streakDays = Number(opts && opts.streakDays) || 0;
  const fridgeIngredients = Array.isArray(opts && opts.fridgeIngredients)
    ? opts.fridgeIngredients.filter((v) => !!String(v || "").trim())
    : [];
  const recipeTitle = shortenReminderLabel(opts && opts.recipeTitle);
  const trendingTitle = shortenReminderLabel(opts && opts.trendingTitle);

  if (streakDays >= 1) {
    const streakTemplates = [
      `연속 출석 ${streakDays}일 · 오늘도 출석해서 기록을 이어가세요`,
      `연속 ${streakDays}일째예요 · 출석하고 스트릭을 지키세요`,
      `출석 ${streakDays}일 연속 중 · 오늘 한 번만 더 이어가세요`,
    ];
    return streakTemplates[reminderRotationIndex(dayKey, uid, streakTemplates.length)];
  }

  if (fridgeIngredients.length > 0) {
    const joined = fridgeIngredients.slice(0, 2).join("·");
    const ro = koreanRoParticle(fridgeIngredients[fridgeIngredients.length - 1]);
    const fridgeTemplates = [
      `냉장고 속 ${joined}${ro} 만들 수 있어요 · 출석하고 확인하세요`,
      `집에 있는 ${joined}${ro} 뭐가 나올까요? · 출석하고 찾아보세요`,
      `남은 ${joined}${ro} 한 끼 · 출석하고 레시피를 받아가세요`,
    ];
    return fridgeTemplates[reminderRotationIndex(dayKey, uid, fridgeTemplates.length)];
  }

  if (recipeTitle) {
    const recipeTemplates = [
      `오늘 뭐 먹지? · 출석하고 「${recipeTitle}」 추천을 받아가세요`,
      `저녁 고민 끝 · 출석하고 「${recipeTitle}」 레시피를 확인하세요`,
      `오늘 뭐 만들지 고르기 · 출석하고 「${recipeTitle}」부터 시작하세요`,
    ];
    return recipeTemplates[reminderRotationIndex(dayKey, uid, recipeTemplates.length)];
  }

  if (trendingTitle) {
    const trendingTemplates = [
      `지금 뜨는 「${trendingTitle}」 숏폼이 도착했어요 · 출석하고 구경하세요`,
      `지금 핫한 「${trendingTitle}」 · 출석하고 바로 보세요`,
      `오늘자 「${trendingTitle}」 숏폼 · 출석하고 스크롤해보세요`,
    ];
    return trendingTemplates[
      reminderRotationIndex(dayKey, uid, trendingTemplates.length)
    ];
  }

  const fallbackTemplates = [
    "오늘 뭐 먹지? · 출석하고 오늘의 추천 레시피를 받아가세요",
    "저녁 고민 끝 · 출석하고 오늘 레시피를 확인하세요",
    "오늘 뭐 만들지 고르기 · 출석하고 시작하세요",
    "냉장고 속 재료로 만들 수 있는 레시피 · 출석하고 확인하세요",
    "집에 있는 재료로 뭐가 나올까요? · 출석하고 찾아보세요",
    "남은 재료로 한 끼 · 출석하고 레시피를 받아가세요",
    "지금 뜨는 숏폼 레시피가 도착했어요 · 출석 도장부터 찍고 구경하세요",
    "지금 핫한 레시피 모음 · 출석하고 바로 보세요",
    "오늘자 숏폼 레시피 · 출석하고 스크롤해보세요",
  ];
  return fallbackTemplates[
    reminderRotationIndex(dayKey, uid, fallbackTemplates.length)
  ];
}

/**
 * 주간 출석 리마인드 본문. 이번 주 출석이 1일 이상일 때만 주간 연속/이어가기 카피.
 * @param {{
 *   weekStartKey: string,
 *   uid: string,
 *   attendedDaysThisWeek: number,
 * }} opts
 * @returns {string}
 */
function buildWeeklyStreakReminderMessage(opts) {
  const weekStartKey = String((opts && opts.weekStartKey) || "").trim();
  const uid = String((opts && opts.uid) || "").trim();
  const attended = Number(opts && opts.attendedDaysThisWeek) || 0;

  if (attended >= 1) {
    const templates = [
      `이번 주 출석 ${attended}일 · 오늘도 출석해서 주간 기록을 이어가세요`,
      `이번 주 ${attended}일 출석했어요 · 출석하고 한 주를 채워보세요`,
      `주간 출석 ${attended}일째 · 오늘 출석하면 기록이 더 탄탄해져요`,
    ];
    return templates[reminderRotationIndex(weekStartKey, uid, templates.length)];
  }

  const fallback = [
    "이번 주 출석을 시작해보세요 · 출석하고 주간 기록을 열어보세요",
    "주간 출석 도장을 찍을 시간이에요 · 출석하고 캘린더를 확인해보세요",
    "이번 주 아직 출석 전이에요 · 출석하고 요리를 시작해보세요",
  ];
  return fallback[reminderRotationIndex(weekStartKey, uid, fallback.length)];
}

/**
 * 주간 알림 발송 대상인가.
 * - 오늘 미출석
 * - 이번 주 출석 1일 이상 (이어갈 주간 기록이 있을 때)
 * @param {{ hasTodayAttendance: boolean, attendedDaysThisWeek: number }} week
 * @returns {boolean}
 */
function shouldSendWeeklyStreakReminder(week) {
  if (!week) return false;
  if (week.hasTodayAttendance) return false;
  return (Number(week.attendedDaysThisWeek) || 0) >= 1;
}

module.exports = {
  DAY_MS,
  KST_OFFSET_MS,
  startOfKstDay,
  startOfKstWeekSunday,
  ymdKey,
  isKstSunday,
  normalizeStreakDayKey,
  extractAttendanceDayKeysFromUserData,
  computeDailyAttendanceStreakAtRisk,
  computeWeekAttendance,
  shortenReminderLabel,
  koreanRoParticle,
  reminderRotationIndex,
  extractFridgeIngredientNames,
  extractFridgeRecipeTitle,
  buildDailyStreakReminderMessage,
  buildWeeklyStreakReminderMessage,
  shouldSendWeeklyStreakReminder,
};
