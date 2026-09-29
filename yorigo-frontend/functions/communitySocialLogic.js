/**
 * 모임·챌린지 순수 로직. Cloud Functions와 단위 테스트가 공유한다.
 */

const INVITE_CHARSET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const KST_OFFSET_MS = 9 * 60 * 60 * 1000;

function toDate(value) {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof value.toDate === "function") {
    try {
      return value.toDate();
    } catch (_) {
      return null;
    }
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(value);
  }
  if (typeof value === "string") {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }
  return null;
}

function kstDayKey(value) {
  const date = toDate(value);
  if (!date) return null;
  const kst = new Date(date.getTime() + KST_OFFSET_MS);
  const y = kst.getUTCFullYear();
  const m = String(kst.getUTCMonth() + 1).padStart(2, "0");
  const d = String(kst.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function generateInviteCode(randomInt) {
  const pick =
    typeof randomInt === "function"
      ? randomInt
      : () => Math.floor(Math.random() * INVITE_CHARSET.length);
  let out = "";
  for (let i = 0; i < 6; i += 1) {
    const idx = Math.abs(Number(pick(i))) % INVITE_CHARSET.length;
    out += INVITE_CHARSET[idx];
  }
  return out;
}

function normalizeInviteCode(raw) {
  const upper = String(raw || "")
    .trim()
    .toUpperCase();
  let out = "";
  for (const ch of upper) {
    if (INVITE_CHARSET.includes(ch)) out += ch;
  }
  return out;
}

function isPaidOpenClass(meetup) {
  return (
    meetup &&
    meetup.kind === "open_class" &&
    Number(meetup.priceKrw) > 0
  );
}

function isMeetupJoinable(meetup, now = new Date()) {
  if (!meetup) return { ok: false, reason: "not_found" };
  if (meetup.cancelled === true) return { ok: false, reason: "cancelled" };
  if (meetup.isHidden === true) return { ok: false, reason: "hidden" };
  const startsAt = toDate(meetup.startsAt);
  if (!startsAt) return { ok: false, reason: "invalid_time" };
  if (startsAt.getTime() <= toDate(now).getTime()) {
    return { ok: false, reason: "past" };
  }
  const memberCount = Number(meetup.memberCount) || 0;
  const capacity = Number(meetup.capacity) || 0;
  if (capacity < 2 || memberCount >= capacity) {
    return { ok: false, reason: "full" };
  }
  return { ok: true };
}

function isChallengeJoinable(challenge, now = new Date()) {
  if (!challenge) return { ok: false, reason: "not_found" };
  if (challenge.cancelled === true) return { ok: false, reason: "cancelled" };
  if (challenge.isHidden === true) return { ok: false, reason: "hidden" };
  const nowKey = kstDayKey(now);
  const startKey = kstDayKey(challenge.startsAt);
  const endKey = kstDayKey(challenge.endsAt);
  if (!nowKey || !startKey || !endKey) return { ok: false, reason: "invalid_time" };
  if (nowKey < startKey) return { ok: false, reason: "upcoming" };
  if (nowKey > endKey) return { ok: false, reason: "ended" };
  return { ok: true };
}

function isDateInChallengeWindow(value, challenge) {
  const key = kstDayKey(value);
  const startKey = kstDayKey(challenge && challenge.startsAt);
  const endKey = kstDayKey(challenge && challenge.endsAt);
  if (!key || !startKey || !endKey) return false;
  return key >= startKey && key <= endKey;
}

function longestConsecutiveRun(dayKeys) {
  const unique = [...new Set((dayKeys || []).filter(Boolean))].sort();
  if (unique.length === 0) return 0;
  let best = 1;
  let run = 1;
  for (let i = 1; i < unique.length; i += 1) {
    const prev = new Date(`${unique[i - 1]}T00:00:00.000Z`);
    const cur = new Date(`${unique[i]}T00:00:00.000Z`);
    const diffDays = Math.round((cur.getTime() - prev.getTime()) / 86400000);
    if (diffDays === 1) {
      run += 1;
      if (run > best) best = run;
    } else {
      run = 1;
    }
  }
  return best;
}

function reviewHasPhoto(review) {
  if (!review) return false;
  const urls = Array.isArray(review.photoUrls) ? review.photoUrls : [];
  if (urls.some((u) => String(u || "").trim())) return true;
  return Boolean(String(review.photoUrl || "").trim());
}

function evaluateChallengeProof({
  challenge,
  participant,
  review,
  uid,
  existingProof,
}) {
  if (!challenge) return { ok: false, reason: "not_found" };
  if (!participant) return { ok: false, reason: "not_member" };
  if (existingProof) return { ok: false, reason: "duplicate_review" };
  if (!review) return { ok: false, reason: "review_not_found" };
  if (review.userId !== uid) return { ok: false, reason: "not_owner" };
  if (review.isHidden === true) return { ok: false, reason: "hidden_review" };
  if (challenge.kind === "official" && !reviewHasPhoto(review)) {
    return { ok: false, reason: "photo_required" };
  }
  if (!isDateInChallengeWindow(review.cookedAt, challenge)) {
    return { ok: false, reason: "cooked_out_of_range" };
  }
  if (!isDateInChallengeWindow(review.createdAt, challenge)) {
    return { ok: false, reason: "created_out_of_range" };
  }

  const required = Math.max(1, Number(challenge.requiredProofCount) || 1);
  const mode = challenge.proofMode === "consecutive_days" ? "consecutive_days" : "count";
  const dayKey = kstDayKey(review.cookedAt);
  const prevDays = Array.isArray(participant.proofDayKeys)
    ? participant.proofDayKeys.filter(Boolean)
    : [];
  const nextDays = dayKey && !prevDays.includes(dayKey) ? [...prevDays, dayKey] : [...prevDays];
  const nextCount = (Number(participant.proofCount) || 0) + 1;
  const completed =
    mode === "consecutive_days"
      ? longestConsecutiveRun(nextDays) >= required
      : nextCount >= required;

  return {
    ok: true,
    nextProofCount: nextCount,
    nextDayKeys: nextDays.slice(-required),
    completed,
  };
}

module.exports = {
  INVITE_CHARSET,
  toDate,
  kstDayKey,
  generateInviteCode,
  normalizeInviteCode,
  isPaidOpenClass,
  isMeetupJoinable,
  isChallengeJoinable,
  isDateInChallengeWindow,
  longestConsecutiveRun,
  reviewHasPhoto,
  evaluateChallengeProof,
};
