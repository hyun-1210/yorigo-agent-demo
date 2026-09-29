/**
 * communitySocialLogic 순수 로직 단위 테스트.
 * 실행: node scripts/test_community_social_logic.js
 */
const assert = require("assert");
const {
  generateInviteCode,
  normalizeInviteCode,
  INVITE_CHARSET,
  isPaidOpenClass,
  isMeetupJoinable,
  isChallengeJoinable,
  longestConsecutiveRun,
  evaluateChallengeProof,
  kstDayKey,
} = require("../communitySocialLogic");

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

check("invite code charset has no 0 O 1 I", () => {
  assert.strictEqual(INVITE_CHARSET.includes("0"), false);
  assert.strictEqual(INVITE_CHARSET.includes("O"), false);
  assert.strictEqual(INVITE_CHARSET.includes("1"), false);
  assert.strictEqual(INVITE_CHARSET.includes("I"), false);
});

check("generateInviteCode is 6 chars from charset", () => {
  const code = generateInviteCode(() => 0);
  assert.strictEqual(code.length, 6);
  for (const ch of code) assert.ok(INVITE_CHARSET.includes(ch));
});

check("normalizeInviteCode uppercases and strips junk", () => {
  assert.strictEqual(normalizeInviteCode(" ab-c2 "), "ABC2");
  assert.strictEqual(normalizeInviteCode("hello!"), "HELL");
});

check("paid open class only when kind and price", () => {
  assert.strictEqual(isPaidOpenClass({ kind: "open_class", priceKrw: 25000 }), true);
  assert.strictEqual(isPaidOpenClass({ kind: "open_class", priceKrw: 0 }), false);
  assert.strictEqual(isPaidOpenClass({ kind: "small_group", priceKrw: 1000 }), false);
});

const future = new Date(Date.now() + 24 * 60 * 60 * 1000);
const past = new Date(Date.now() - 24 * 60 * 60 * 1000);

check("meetup join rejects full / past / cancelled", () => {
  assert.strictEqual(
    isMeetupJoinable({
      cancelled: false,
      isHidden: false,
      startsAt: future,
      memberCount: 2,
      capacity: 8,
    }).ok,
    true,
  );
  assert.strictEqual(
    isMeetupJoinable({
      cancelled: false,
      isHidden: false,
      startsAt: future,
      memberCount: 8,
      capacity: 8,
    }).reason,
    "full",
  );
  assert.strictEqual(
    isMeetupJoinable({
      cancelled: false,
      isHidden: false,
      startsAt: past,
      memberCount: 1,
      capacity: 8,
    }).reason,
    "past",
  );
  assert.strictEqual(
    isMeetupJoinable({
      cancelled: true,
      isHidden: false,
      startsAt: future,
      memberCount: 1,
      capacity: 8,
    }).reason,
    "cancelled",
  );
});

check("challenge window uses KST day keys", () => {
  const startsAt = new Date("2026-09-01T00:00:00+09:00");
  const endsAt = new Date("2026-09-07T23:59:59+09:00");
  const challenge = { cancelled: false, isHidden: false, startsAt, endsAt };
  assert.strictEqual(
    isChallengeJoinable(challenge, new Date("2026-09-01T01:00:00+09:00")).ok,
    true,
  );
  assert.strictEqual(
    isChallengeJoinable(challenge, new Date("2026-08-31T23:00:00+09:00")).reason,
    "upcoming",
  );
  assert.strictEqual(
    isChallengeJoinable(challenge, new Date("2026-09-08T00:30:00+09:00")).reason,
    "ended",
  );
});

check("longest consecutive run", () => {
  assert.strictEqual(longestConsecutiveRun([]), 0);
  assert.strictEqual(longestConsecutiveRun(["2026-09-01"]), 1);
  assert.strictEqual(
    longestConsecutiveRun(["2026-09-01", "2026-09-02", "2026-09-03"]),
    3,
  );
  assert.strictEqual(
    longestConsecutiveRun(["2026-09-01", "2026-09-03", "2026-09-04"]),
    2,
  );
});

check("same-day three proofs do not complete consecutive_days=3", () => {
  const challenge = {
    kind: "friend",
    proofMode: "consecutive_days",
    requiredProofCount: 3,
    startsAt: new Date("2026-09-01T00:00:00+09:00"),
    endsAt: new Date("2026-09-07T23:59:59+09:00"),
  };
  const review = {
    userId: "u1",
    isHidden: false,
    cookedAt: new Date("2026-09-02T12:00:00+09:00"),
    createdAt: new Date("2026-09-02T13:00:00+09:00"),
  };
  const first = evaluateChallengeProof({
    challenge,
    participant: { proofCount: 0, proofDayKeys: [] },
    review,
    uid: "u1",
    existingProof: null,
  });
  assert.strictEqual(first.ok, true);
  assert.strictEqual(first.completed, false);
  const secondSameDay = evaluateChallengeProof({
    challenge,
    participant: { proofCount: 2, proofDayKeys: ["2026-09-02"] },
    review,
    uid: "u1",
    existingProof: null,
  });
  assert.strictEqual(secondSameDay.completed, false);
});

check("official proof requires photo and in-range createdAt", () => {
  const challenge = {
    kind: "official",
    proofMode: "count",
    requiredProofCount: 1,
    startsAt: new Date("2026-09-01T00:00:00+09:00"),
    endsAt: new Date("2026-09-07T23:59:59+09:00"),
  };
  const noPhoto = evaluateChallengeProof({
    challenge,
    participant: { proofCount: 0, proofDayKeys: [] },
    review: {
      userId: "u1",
      isHidden: false,
      photoUrls: [],
      cookedAt: new Date("2026-09-02T12:00:00+09:00"),
      createdAt: new Date("2026-09-02T13:00:00+09:00"),
    },
    uid: "u1",
  });
  assert.strictEqual(noPhoto.reason, "photo_required");

  const oldCreated = evaluateChallengeProof({
    challenge,
    participant: { proofCount: 0, proofDayKeys: [] },
    review: {
      userId: "u1",
      isHidden: false,
      photoUrls: ["https://x"],
      cookedAt: new Date("2026-09-02T12:00:00+09:00"),
      createdAt: new Date("2026-08-01T13:00:00+09:00"),
    },
    uid: "u1",
  });
  assert.strictEqual(oldCreated.reason, "created_out_of_range");
});

check("kstDayKey around midnight", () => {
  assert.strictEqual(kstDayKey(new Date("2026-09-01T00:30:00+09:00")), "2026-09-01");
  assert.strictEqual(kstDayKey(new Date("2026-08-31T23:30:00+09:00")), "2026-08-31");
});

if (!process.exitCode) {
  console.log(`All ${passed} checks passed`);
}
