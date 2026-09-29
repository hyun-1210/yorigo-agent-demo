/**
 * EXP/포인트 리워드 지급 (Cloud Functions, Firestore와 동일 리전 — 저지연/저비용).
 *
 * 왜 Python/Railway 백엔드가 아니라 여기인가:
 * - EXP는 화폐성/소비처가 없는 표시용 재화, 포인트도 아직 소비처가 없어(적립+랭킹만)
 *   오늘 시점에는 남용돼도 실질 피해가 없다. 그런데도 매번 Railway를 왕복하면
 *   레시피 조회/검색처럼 원래 네트워크 호출이 없던 경량 동작에 큰 지연·비용을
 *   추가하게 된다. Firestore와 같은 GCP 프로젝트에 있는 Cloud Functions가
 *   훨씬 빠르고(리전 내부 홉) 저렴하다(서버리스, 트래픽 없으면 비용 0에 수렴).
 *
 * 구매완료 "사진 인증"만은 예외로 Python 백엔드(services/rewards_service.py)가
 * 계속 담당한다 — Gemini Vision으로 스크린샷을 분석해야 하고, 그 결과를 신뢰할
 * 서버 컨텍스트가 이미 거기 있기 때문이다. 이 파일의 REWARD_CATALOG에도
 * points_purchase_photo_verified가 있지만 backendOnly로 표시해 클라이언트가
 * 직접 청구하지 못하게 막는다 — 스키마(원장/카운터/잔액 필드)는 두 구현이
 * 공유하므로 캡/필드명을 반드시 backend/services/rewards_service.py와
 * 동일하게 유지해야 한다.
 */

const functions = require("firebase-functions");
const admin = require("firebase-admin");

const REWARD_CATALOG = {
  // ---- EXP: 앱 사용 전반, 넓고 얕게 ----
  exp_recipe_viewed: { track: "exp", amount: 10, dailyLimit: 20 },
  exp_search: { track: "exp", amount: 10, dailyLimit: 10 },
  exp_fridge_ingredient_added: { track: "exp", amount: 10, dailyLimit: 10 },
  exp_follow: { track: "exp", amount: 10, dailyLimit: 5 },
  exp_session_start: { track: "exp", amount: 10, dailyLimit: 1 },
  exp_recipe_bookmarked: { track: "exp", amount: 10, dailyLimit: 10 },
  exp_cooking_started: { track: "exp", amount: 20, dailyLimit: 3 },
  exp_meal_calendar_used: { track: "exp", amount: 20, dailyLimit: 5 },
  exp_cooking_completed: { track: "exp", amount: 30, dailyLimit: 2 },
  exp_cooking_logged: { track: "exp", amount: 50, dailyLimit: 8 },
  exp_cooking_logged_text: { track: "exp", amount: 30, dailyLimit: 8 },
  exp_recipe_parsed: { track: "exp", amount: 30, dailyLimit: 5 },
  exp_recipe_registered: { track: "exp", amount: 50, dailyLimit: 3 },
  exp_profile_completed: { track: "exp", amount: 100, dailyLimit: 1 },
  exp_attendance: { track: "exp", amount: 20, dailyLimit: 1 },
  exp_streak_3: { track: "exp", amount: 30 },
  exp_streak_7: { track: "exp", amount: 70 },
  exp_streak_14: { track: "exp", amount: 150 },
  exp_streak_30: { track: "exp", amount: 300 },
  exp_like: { track: "exp", amount: 10, dailyLimit: 15 },
  exp_comment: { track: "exp", amount: 20, dailyLimit: 10 },
  exp_post_created: { track: "exp", amount: 40, dailyLimit: 3 },
  exp_post_created_short: { track: "exp", amount: 20, dailyLimit: 3 },
  exp_likes_10: { track: "exp", amount: 50 },
  exp_likes_30: { track: "exp", amount: 100 },
  exp_comments_5: { track: "exp", amount: 50 },
  exp_comments_15: { track: "exp", amount: 100 },
  exp_feedback: { track: "exp", amount: 80, dailyLimit: 2 },
  exp_recipe_shared: { track: "exp", amount: 20, dailyLimit: 3 },

  // ---- Points: 구매/플랫폼 (후하게) ----
  points_attendance: { track: "points", amount: 30, dailyLimit: 1, weeklyCapped: true, newAccountDampening: true },
  points_streak_7: { track: "points", amount: 100, newAccountDampening: true },
  points_streak_14: { track: "points", amount: 300, newAccountDampening: true },
  points_streak_30: { track: "points", amount: 1000, newAccountDampening: true },
  points_cart_add: { track: "points", amount: 50, dailyLimit: 10, weeklyCapped: true, newAccountDampening: true },
  points_purchase_self_report: { track: "points", amount: 300, dailyLimit: 5, weeklyCapped: true, newAccountDampening: true },
  // 실제 지출 증빙이 필요한 최고 배점 — Python 백엔드(Gemini Vision 검증)만 지급 가능.
  points_purchase_photo_verified: { track: "points", amount: 1500, dailyLimit: 3, weeklyCapped: false, newAccountDampening: false, backendOnly: true },

  // ---- Points: 커뮤니티 (구매 대비 낮지만 존재감 있게) ----
  points_like: { track: "points", amount: 20, dailyLimit: 15, weeklyCapped: true, newAccountDampening: true },
  points_comment: { track: "points", amount: 50, dailyLimit: 10, weeklyCapped: true, newAccountDampening: true },
  points_post_created: { track: "points", amount: 200, dailyLimit: 2, weeklyCapped: true, newAccountDampening: true },
  points_post_created_low_quality: { track: "points", amount: 30, dailyLimit: 2, weeklyCapped: true, newAccountDampening: true },
  points_post_popular: { track: "points", amount: 500, newAccountDampening: true },
};

const WEEKLY_POINTS_CAP = 12000;
const NEW_ACCOUNT_GRACE_DAYS = 3;
const NEW_ACCOUNT_DAMPENING_RATIO = 0.5;
const MAX_IDEMPOTENCY_KEY_LEN = 200;

const STREAK_ONLY_ACTIONS = new Set(["points_streak_7", "points_streak_14", "points_streak_30"]);
const STREAK_MILESTONES = { 7: "points_streak_7", 14: "points_streak_14", 30: "points_streak_30" };
const AUTHOR_MILESTONES = {
  exp_likes_10: { field: "likeCount", min: 10 },
  exp_likes_30: { field: "likeCount", min: 30 },
  exp_comments_5: { field: "commentCount", min: 5 },
  exp_comments_15: { field: "commentCount", min: 15 },
};
const STREAK_EXP_REQUIRED = {
  exp_streak_3: 3,
  exp_streak_7: 7,
  exp_streak_14: 14,
  exp_streak_30: 30,
};

function _kstDayKey(date) {
  const base = date || new Date();
  const kst = new Date(base.getTime() + 9 * 60 * 60 * 1000);
  return kst.toISOString().slice(0, 10);
}

function _shiftDayKey(dayKey, deltaDays) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(dayKey || ""));
  if (!match) return null;
  const dt = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  dt.setUTCDate(dt.getUTCDate() + deltaDays);
  return dt.toISOString().slice(0, 10);
}

function _attendanceDaySet(userData) {
  const days = new Set();
  const raw = userData && userData.attendanceDays;
  if (raw && typeof raw === "object") {
    for (const key of Object.keys(raw)) {
      if (/^\d{4}-\d{2}-\d{2}$/.test(key)) days.add(key);
    }
  }
  return days;
}

/** Flutter UserService.currentStreakFromAttendanceDays 와 동일 (KST, 오늘 없으면 어제부터). */
function _currentStreakFromAttendanceDays(daySet) {
  const days = daySet instanceof Set ? daySet : new Set();
  let cursor = _kstDayKey();
  if (!days.has(cursor)) {
    const yesterday = _shiftDayKey(cursor, -1);
    if (!yesterday) return 0;
    cursor = yesterday;
  }
  let streak = 0;
  while (days.has(cursor)) {
    streak += 1;
    const previous = _shiftDayKey(cursor, -1);
    if (!previous) break;
    cursor = previous;
  }
  return streak;
}

function _dayKey(date) {
  const d = date || new Date();
  return d.toISOString().slice(0, 10); // UTC YYYY-MM-DD — backend rewards_service.py의 _day_key와 동일 규칙
}

/** ISO-8601 주차 문자열 (예: "2026-W03"). Python datetime.isocalendar()와 동일 알고리즘. */
function _weekKey(date) {
  const base = date || new Date();
  const d = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate()));
  const dayNum = d.getUTCDay() || 7; // Mon=1..Sun=7
  d.setUTCDate(d.getUTCDate() + 4 - dayNum); // 해당 주의 목요일로 이동
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const weekNo = Math.ceil((((d.getTime() - yearStart.getTime()) / 86400000) + 1) / 7);
  return `${d.getUTCFullYear()}-W${String(weekNo).padStart(2, "0")}`;
}

/** 레벨 N 도달 누적 EXP. Flutter/backend와 동일. */
function expRequiredForLevel(level) {
  if (level <= 1) return 0;
  const n = level - 1;
  return Math.round(50 * Math.pow(n, 1.38));
}

function levelForExp(totalExp) {
  if (totalExp <= 0) return 1;
  let lo = 1;
  let hi = 8;
  while (expRequiredForLevel(hi) <= totalExp) {
    hi *= 2;
    if (hi > 100000) break;
  }
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (expRequiredForLevel(mid) <= totalExp) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

/**
 * 행동에 대한 EXP/포인트를 단일 Firestore 트랜잭션 안에서 지급한다.
 * (중복 체크 → 일일/주간 한도 체크 → 원장 기록 → 잔액 갱신)
 * backend/services/rewards_service.py의 RewardsService.award()와 동일 로직/스키마.
 */
async function awardReward(uid, action, { idempotencyKey, sourceRef, amountOverride } = {}) {
  const config = REWARD_CATALOG[action];
  if (!config) {
    return { granted: false, reason: "unknown_action" };
  }
  if (config.backendOnly) {
    return { granted: false, reason: "backend_only_action" };
  }
  if (!idempotencyKey) {
    return { granted: false, reason: "missing_idempotency_key" };
  }
  // Firestore 문서 ID는 '/'를 포함할 수 없다 — 클라이언트가 URL/경로를 key에
  // 넣어도 트랜잭션이 깨지지 않도록 치환한다.
  const safeIdempotencyKey = String(idempotencyKey).replace(/\//g, "_").slice(0, MAX_IDEMPOTENCY_KEY_LEN);

  const now = new Date();
  const dKey = _dayKey(now);
  const wKey = _weekKey(now);
  const baseAmount = typeof amountOverride === "number" && amountOverride >= 0 ? amountOverride : config.amount;

  const db = admin.firestore();
  const userRef = db.collection("users").doc(uid);
  const counterRef = userRef.collection("daily_action_counters").doc(dKey);
  const ledgerCol = userRef.collection(config.track === "exp" ? "exp_ledger" : "points_ledger");
  const ledgerRef = ledgerCol.doc(safeIdempotencyKey);
  const weeklyRef = config.weeklyCapped ? userRef.collection("weekly_point_counters").doc(wKey) : null;

  return db.runTransaction(async (tx) => {
    const ledgerSnap = await tx.get(ledgerRef);
    if (ledgerSnap.exists) {
      return { granted: false, track: config.track, reason: "duplicate" };
    }

    const milestone = AUTHOR_MILESTONES[action];
    if (milestone) {
      if (!sourceRef) {
        return { granted: false, track: config.track, reason: "missing_source_ref" };
      }
      const reviewSnap = await tx.get(db.collection("reviews").doc(sourceRef));
      let sourceSnap = reviewSnap.exists ? reviewSnap : null;
      if (!sourceSnap) {
        const postSnap = await tx.get(db.collection("board_posts").doc(sourceRef));
        sourceSnap = postSnap.exists ? postSnap : null;
      }
      if (!sourceSnap) {
        return { granted: false, track: config.track, reason: "source_not_found" };
      }
      const sourceData = sourceSnap.data() || {};
      const authorId = String(sourceData.userId || sourceData.authorId || "");
      if (authorId !== uid) {
        return { granted: false, track: config.track, reason: "not_author" };
      }
      const count = Number(sourceData[milestone.field] || 0);
      if (count < milestone.min) {
        return { granted: false, track: config.track, reason: "milestone_not_reached" };
      }
    }

    const counterSnap = await tx.get(counterRef);
    const counterData = counterSnap.exists ? counterSnap.data() || {} : {};
    const currentCount = Number(counterData[action] || 0);
    if (config.dailyLimit != null && currentCount >= config.dailyLimit) {
      return { granted: false, track: config.track, reason: "daily_limit_reached" };
    }

    let weeklyTotal = 0;
    if (weeklyRef) {
      const weeklySnap = await tx.get(weeklyRef);
      weeklyTotal = Number((weeklySnap.exists ? weeklySnap.data() : {}).total || 0);
      if (weeklyTotal >= WEEKLY_POINTS_CAP) {
        return { granted: false, track: config.track, reason: "weekly_cap_reached" };
      }
    }

    const userSnap = await tx.get(userRef);
    const userData = userSnap.exists ? userSnap.data() || {} : {};

    const streakNeed = STREAK_EXP_REQUIRED[action];
    if (streakNeed) {
      const days = _attendanceDaySet(userData);
      days.add(_kstDayKey(now));
      if (_currentStreakFromAttendanceDays(days) < streakNeed) {
        return { granted: false, track: config.track, reason: "streak_not_reached" };
      }
    }

    let finalAmount = baseAmount;
    if (config.newAccountDampening) {
      const createdAt = userData.createdAt;
      if (createdAt && typeof createdAt.toDate === "function") {
        const ageDays = (now.getTime() - createdAt.toDate().getTime()) / 86400000;
        if (ageDays < NEW_ACCOUNT_GRACE_DAYS) {
          finalAmount = Math.max(1, Math.round(baseAmount * NEW_ACCOUNT_DAMPENING_RATIO));
        }
      }
    }

    if (weeklyRef) {
      const remaining = WEEKLY_POINTS_CAP - weeklyTotal;
      finalAmount = Math.max(0, Math.min(finalAmount, remaining));
      if (finalAmount <= 0) {
        return { granted: false, track: config.track, reason: "weekly_cap_reached" };
      }
    }

    tx.set(ledgerRef, {
      action,
      amount: finalAmount,
      track: config.track,
      status: "confirmed",
      sourceRef: sourceRef || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.set(counterRef, { [action]: currentCount + 1 }, { merge: true });
    if (weeklyRef) {
      tx.set(weeklyRef, { total: weeklyTotal + finalAmount }, { merge: true });
    }

    if (config.track === "exp") {
      const newExp = Number(userData.expTotal || 0) + finalAmount;
      const newLevel = levelForExp(newExp);
      tx.set(userRef, {
        expTotal: newExp,
        level: newLevel,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      return { granted: true, track: "exp", amount: finalAmount, balance: newExp, level: newLevel };
    }

    const newBalance = Number(userData.pointsBalance || 0) + finalAmount;
    const newLifetime = Number(userData.pointsLifetimeEarned || 0) + finalAmount;
    tx.set(userRef, {
      pointsBalance: newBalance,
      pointsLifetimeEarned: newLifetime,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { granted: true, track: "points", amount: finalAmount, balance: newBalance };
  });
}

function _requireAuth(context) {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError("unauthenticated", "로그인이 필요합니다");
  }
  return context.auth.uid;
}

// App Check: 현재 Flutter 앱에 App Check가 연결되어 있지 않은데(또는 debug 토큰 미등록),
// callable이 App Check 토큰을 거절하면 auth는 유효해도 지급이 전부 실패한다.
// 리워드 지급은 auth(uid)만으로 충분하므로 enforceAppCheck는 끈다.
const _callableOpts = { enforceAppCheck: false };

/** 일반 행동 리워드 청구. data = { action, idempotencyKey, sourceRef? } */
const claimReward = functions.runWith(_callableOpts).https.onCall(async (data, context) => {
  const uid = _requireAuth(context);
  const action = typeof data?.action === "string" ? data.action.trim() : "";
  const idempotencyKey = typeof data?.idempotencyKey === "string"
    ? data.idempotencyKey.trim().slice(0, MAX_IDEMPOTENCY_KEY_LEN)
    : "";
  const sourceRef = typeof data?.sourceRef === "string" ? data.sourceRef.trim().slice(0, 200) : undefined;

  if (!action || !REWARD_CATALOG[action]) {
    throw new functions.https.HttpsError("invalid-argument", `unknown action: ${action}`);
  }
  if (STREAK_ONLY_ACTIONS.has(action)) {
    throw new functions.https.HttpsError("invalid-argument", "use claimAttendance for streak bonuses");
  }
  if (REWARD_CATALOG[action].backendOnly) {
    throw new functions.https.HttpsError("permission-denied", "이 행동은 서버에서만 지급할 수 있어요");
  }
  if (!idempotencyKey) {
    throw new functions.https.HttpsError("invalid-argument", "idempotencyKey is required");
  }

  // 클라이언트 amountOverride는 무시한다. 지급액은 카탈로그만 따른다.
  const result = await awardReward(uid, action, { idempotencyKey, sourceRef });
  console.log(
    JSON.stringify({
      event: "claimReward",
      uid,
      action,
      granted: result.granted,
      reason: result.reason || null,
      amount: result.amount || 0,
    }),
  );
  return result;
});

/** 일일 출석 + (streakDays가 7/14/30이면) 연속출석 마일스톤 보너스. data = { streakDays } */
const claimAttendance = functions.runWith(_callableOpts).https.onCall(async (data, context) => {
  const uid = _requireAuth(context);
  const streakDaysRaw = Number(data?.streakDays);
  const streakDays = Number.isFinite(streakDaysRaw) && streakDaysRaw > 0 ? Math.floor(streakDaysRaw) : 1;

  const dKey = _dayKey(new Date());
  const attendanceResult = await awardReward(uid, "points_attendance", {
    idempotencyKey: `attendance:${uid}:${dKey}`,
  });

  // 출석이 이미 지급된 상태(duplicate)여도 마일스톤은 별도 idempotency로
  // 재시도해야 한다 — 첫 호출에서 출석만 성공하고 마일스톤이 실패한 경우 복구.
  let milestoneResult = null;
  const milestoneAction = STREAK_MILESTONES[streakDays];
  if (milestoneAction) {
    milestoneResult = await awardReward(uid, milestoneAction, {
      idempotencyKey: `${milestoneAction}:${uid}:${dKey}`,
      sourceRef: String(streakDays),
    });
  }

  console.log(
    JSON.stringify({
      event: "claimAttendance",
      uid,
      streakDays,
      granted: attendanceResult.granted,
      reason: attendanceResult.reason || null,
      amount: attendanceResult.amount || 0,
      milestoneGranted: milestoneResult?.granted === true,
      milestoneAmount: milestoneResult?.amount || 0,
    }),
  );
  return {
    ...attendanceResult,
    streakDays,
    milestoneGranted: milestoneResult?.granted === true,
    milestoneAmount: milestoneResult?.amount || 0,
  };
});

module.exports = {
  REWARD_CATALOG,
  expRequiredForLevel,
  levelForExp,
  awardReward,
  claimReward,
  claimAttendance,
};
