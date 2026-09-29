const functions = require("firebase-functions");
const admin = require("firebase-admin");
const logic = require("./communitySocialLogic");
const { getUserSummary, notifyUser } = require("./communityNotify");

const _callableOpts = {
  enforceAppCheck: false,
  timeoutSeconds: 30,
  memory: "256MB",
};

function db() {
  return admin.firestore();
}

function requireAuth(context) {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError("unauthenticated", "로그인이 필요합니다");
  }
  return context.auth.uid;
}

function asString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function httpsError(code, message) {
  throw new functions.https.HttpsError(code, message);
}

const JOIN_REASONS = {
  not_found: "모임을 찾을 수 없어요",
  cancelled: "취소된 모임이에요",
  hidden: "숨겨진 모임이에요",
  invalid_time: "모임 시간이 올바르지 않아요",
  past: "이미 시작된 모임이에요",
  full: "정원이 가득 찼어요",
};

const CHALLENGE_REASONS = {
  not_found: "챌린지를 찾을 수 없어요",
  cancelled: "취소된 챌린지예요",
  hidden: "숨겨진 챌린지예요",
  invalid_time: "챌린지 기간이 올바르지 않아요",
  upcoming: "아직 시작 전이에요",
  ended: "이미 끝난 챌린지예요",
};

const PROOF_REASONS = {
  not_found: "챌린지를 찾을 수 없어요",
  not_member: "참여 중인 챌린지가 아니에요",
  duplicate_review: "이미 인증에 쓴 기록이에요",
  review_not_found: "요리 기록을 찾을 수 없어요",
  not_owner: "내 요리 기록만 인증할 수 있어요",
  hidden_review: "숨긴 기록은 인증에 쓸 수 없어요",
  photo_required: "사진이 있는 기록으로 인증해 주세요",
  cooked_out_of_range: "챌린지 기간 안의 요리 날짜여야 해요",
  created_out_of_range: "챌린지 기간 안에 남긴 기록이어야 해요",
};

async function joinMeetupHandler(data, context) {
  const uid = requireAuth(context);
  const meetupId = asString(data && data.meetupId);
  if (!meetupId) httpsError("invalid-argument", "모임 ID가 필요해요");

  const meetupRef = db().collection("meetups").doc(meetupId);
  const attendeeRef = meetupRef.collection("attendees").doc(uid);
  const actor = await getUserSummary(uid);
  let hostId = "";

  await db().runTransaction(async (tx) => {
    const meetupSnap = await tx.get(meetupRef);
    if (!meetupSnap.exists) httpsError("not-found", JOIN_REASONS.not_found);
    const meetup = meetupSnap.data() || {};
    hostId = String(meetup.hostId || "");
    if (hostId === uid) httpsError("already-exists", "호스트는 이미 참여 중이에요");
    if (logic.isPaidOpenClass(meetup)) {
      httpsError("failed-precondition", "유료 클래스는 신청 후 호스트 수락이 필요해요");
    }
    const gate = logic.isMeetupJoinable(meetup, new Date());
    if (!gate.ok) httpsError("failed-precondition", JOIN_REASONS[gate.reason] || "참여할 수 없어요");
    const attendeeSnap = await tx.get(attendeeRef);
    if (attendeeSnap.exists) httpsError("already-exists", "이미 참여 중이에요");
    tx.set(attendeeRef, {
      uid,
      name: actor.name,
      role: "member",
      status: "joined",
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.update(meetupRef, {
      memberCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  await notifyUser({
    targetUserId: hostId,
    type: "meetup_join",
    actorId: uid,
    actorName: actor.name,
    message: `${actor.name}님이 모임에 참여했어요`,
    meetupId,
    eventKey: `meetup_join_${meetupId}_${uid}`,
    title: "모임 참여",
  });
  return { ok: true };
}

async function leaveMeetupHandler(data, context) {
  const uid = requireAuth(context);
  const meetupId = asString(data && data.meetupId);
  if (!meetupId) httpsError("invalid-argument", "모임 ID가 필요해요");

  const meetupRef = db().collection("meetups").doc(meetupId);
  const attendeeRef = meetupRef.collection("attendees").doc(uid);

  await db().runTransaction(async (tx) => {
    const meetupSnap = await tx.get(meetupRef);
    if (!meetupSnap.exists) httpsError("not-found", JOIN_REASONS.not_found);
    const meetup = meetupSnap.data() || {};
    if (meetup.hostId === uid) {
      httpsError("failed-precondition", "호스트는 모임을 취소해야 해요");
    }
    const attendeeSnap = await tx.get(attendeeRef);
    if (!attendeeSnap.exists) httpsError("not-found", "참여 중이 아니에요");
    const status = String((attendeeSnap.data() || {}).status || "");
    tx.delete(attendeeRef);
    if (status === "joined") {
      tx.update(meetupRef, {
        memberCount: admin.firestore.FieldValue.increment(-1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });
  return { ok: true };
}

async function confirmOpenClassHandler(data, context) {
  const uid = requireAuth(context);
  const meetupId = asString(data && data.meetupId);
  const targetUid = asString(data && data.targetUid);
  if (!meetupId || !targetUid) {
    httpsError("invalid-argument", "모임과 신청자가 필요해요");
  }

  const meetupRef = db().collection("meetups").doc(meetupId);
  const attendeeRef = meetupRef.collection("attendees").doc(targetUid);

  await db().runTransaction(async (tx) => {
    const meetupSnap = await tx.get(meetupRef);
    if (!meetupSnap.exists) httpsError("not-found", JOIN_REASONS.not_found);
    const meetup = meetupSnap.data() || {};
    if (meetup.hostId !== uid) httpsError("permission-denied", "호스트만 수락할 수 있어요");
    if (!logic.isPaidOpenClass(meetup)) {
      httpsError("failed-precondition", "신청 수락이 필요한 클래스가 아니에요");
    }
    const gate = logic.isMeetupJoinable(meetup, new Date());
    if (!gate.ok) httpsError("failed-precondition", JOIN_REASONS[gate.reason] || "수락할 수 없어요");
    const attendeeSnap = await tx.get(attendeeRef);
    if (!attendeeSnap.exists) httpsError("not-found", "신청 내역이 없어요");
    const attendee = attendeeSnap.data() || {};
    if (attendee.status !== "applied") {
      httpsError("failed-precondition", "이미 처리된 신청이에요");
    }
    tx.update(attendeeRef, { status: "joined" });
    tx.update(meetupRef, {
      memberCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  await notifyUser({
    targetUserId: targetUid,
    type: "meetup_confirmed",
    actorId: uid,
    actorName: (await getUserSummary(uid)).name,
    message: "오픈 클래스 신청이 수락되었어요",
    meetupId,
    eventKey: `meetup_confirmed_${meetupId}_${targetUid}`,
    title: "신청 수락",
  });
  return { ok: true };
}

async function resolveChallengeRef(data) {
  const inviteCode = logic.normalizeInviteCode(asString(data && data.inviteCode));
  let challengeId = asString(data && data.challengeId);
  if (inviteCode) {
    if (inviteCode.length !== 6) {
      httpsError("invalid-argument", "초대코드가 올바르지 않아요");
    }
    const codeSnap = await db().collection("challenge_invite_codes").doc(inviteCode).get();
    if (!codeSnap.exists) httpsError("not-found", "초대코드를 찾을 수 없어요");
    challengeId = asString((codeSnap.data() || {}).challengeId);
  }
  if (!challengeId) httpsError("invalid-argument", "챌린지 ID가 필요해요");
  return db().collection("challenges").doc(challengeId);
}

async function joinChallengeHandler(data, context) {
  const uid = requireAuth(context);
  const inviteCode = logic.normalizeInviteCode(asString(data && data.inviteCode));
  const challengeRef = await resolveChallengeRef(data);
  const actor = await getUserSummary(uid);
  let createdBy = "";
  let kind = "";
  const challengeId = challengeRef.id;

  await db().runTransaction(async (tx) => {
    const challengeSnap = await tx.get(challengeRef);
    if (!challengeSnap.exists) httpsError("not-found", CHALLENGE_REASONS.not_found);
    const challenge = challengeSnap.data() || {};
    kind = String(challenge.kind || "");
    createdBy = String(challenge.createdBy || "");
    if (kind === "friend" && !inviteCode) {
      httpsError("permission-denied", "친구 챌린지는 초대코드가 필요해요");
    }
    if (kind === "friend" && inviteCode && challenge.inviteCode !== inviteCode) {
      httpsError("not-found", "초대코드를 찾을 수 없어요");
    }
    const gate = logic.isChallengeJoinable(challenge, new Date());
    if (!gate.ok) {
      httpsError("failed-precondition", CHALLENGE_REASONS[gate.reason] || "참여할 수 없어요");
    }
    const participantRef = challengeRef.collection("participants").doc(uid);
    const participantSnap = await tx.get(participantRef);
    if (participantSnap.exists) httpsError("already-exists", "이미 참여 중이에요");
    const membershipRef = db()
      .collection("users")
      .doc(uid)
      .collection("challengeMemberships")
      .doc(challengeId);
    tx.set(participantRef, {
      uid,
      status: "joined",
      proofCount: 0,
      proofDayKeys: [],
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.set(membershipRef, {
      kind,
      status: "joined",
      endsAt: challenge.endsAt || null,
    });
    tx.update(challengeRef, {
      participantCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  if (kind === "friend") {
    await notifyUser({
      targetUserId: createdBy,
      type: "challenge_join",
      actorId: uid,
      actorName: actor.name,
      message: `${actor.name}님이 친구 챌린지에 참여했어요`,
      challengeId,
      eventKey: `challenge_join_${challengeId}_${uid}`,
      title: "챌린지 참여",
    });
  }
  return { ok: true, challengeId };
}

async function leaveChallengeHandler(data, context) {
  const uid = requireAuth(context);
  const challengeId = asString(data && data.challengeId);
  if (!challengeId) httpsError("invalid-argument", "챌린지 ID가 필요해요");
  const challengeRef = db().collection("challenges").doc(challengeId);
  const participantRef = challengeRef.collection("participants").doc(uid);
  const membershipRef = db()
    .collection("users")
    .doc(uid)
    .collection("challengeMemberships")
    .doc(challengeId);

  await db().runTransaction(async (tx) => {
    const challengeSnap = await tx.get(challengeRef);
    if (!challengeSnap.exists) httpsError("not-found", CHALLENGE_REASONS.not_found);
    const challenge = challengeSnap.data() || {};
    if (challenge.createdBy === uid) {
      httpsError("failed-precondition", "만든 사람은 챌린지를 취소해야 해요");
    }
    const participantSnap = await tx.get(participantRef);
    if (!participantSnap.exists) httpsError("not-found", "참여 중이 아니에요");
    tx.delete(participantRef);
    tx.delete(membershipRef);
    tx.update(challengeRef, {
      participantCount: admin.firestore.FieldValue.increment(-1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { ok: true };
}

async function submitChallengeProofHandler(data, context) {
  const uid = requireAuth(context);
  const challengeId = asString(data && data.challengeId);
  const reviewId = asString(data && data.reviewId);
  if (!challengeId || !reviewId) {
    httpsError("invalid-argument", "챌린지와 요리 기록이 필요해요");
  }

  const challengeRef = db().collection("challenges").doc(challengeId);
  const participantRef = challengeRef.collection("participants").doc(uid);
  const proofRef = challengeRef.collection("proofs").doc(reviewId);
  const reviewRef = db().collection("reviews").doc(reviewId);
  const membershipRef = db()
    .collection("users")
    .doc(uid)
    .collection("challengeMemberships")
    .doc(challengeId);

  let kind = "";
  let createdBy = "";
  let completed = false;

  await db().runTransaction(async (tx) => {
    const challengeSnap = await tx.get(challengeRef);
    const participantSnap = await tx.get(participantRef);
    const proofSnap = await tx.get(proofRef);
    const reviewSnap = await tx.get(reviewRef);
    if (!challengeSnap.exists) httpsError("not-found", PROOF_REASONS.not_found);
    const challenge = challengeSnap.data() || {};
    kind = String(challenge.kind || "");
    createdBy = String(challenge.createdBy || "");
    const gate = logic.isChallengeJoinable(challenge, new Date());
    if (!gate.ok) {
      httpsError("failed-precondition", CHALLENGE_REASONS[gate.reason] || "인증할 수 없어요");
    }
    const result = logic.evaluateChallengeProof({
      challenge,
      participant: participantSnap.exists ? participantSnap.data() : null,
      review: reviewSnap.exists ? { id: reviewSnap.id, ...reviewSnap.data() } : null,
      uid,
      existingProof: proofSnap.exists ? proofSnap.data() : null,
    });
    if (!result.ok) {
      httpsError("failed-precondition", PROOF_REASONS[result.reason] || "인증할 수 없어요");
    }
    completed = result.completed;
    tx.set(proofRef, {
      uid,
      reviewId,
      cookedAt: reviewSnap.data().cookedAt || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.update(participantRef, {
      proofCount: result.nextProofCount,
      proofDayKeys: result.nextDayKeys,
      status: completed ? "completed" : "joined",
    });
    tx.set(
      membershipRef,
      {
        kind,
        status: completed ? "completed" : "joined",
        endsAt: challenge.endsAt || null,
      },
      { merge: true },
    );
  });

  if (kind === "friend") {
    const actor = await getUserSummary(uid);
    await notifyUser({
      targetUserId: createdBy,
      type: "challenge_proof",
      actorId: uid,
      actorName: actor.name,
      message: `${actor.name}님이 챌린지를 인증했어요`,
      challengeId,
      eventKey: `challenge_proof_${challengeId}_${reviewId}`,
      title: "챌린지 인증",
    });
  }
  return { ok: true, completed };
}

const joinMeetup = functions.runWith(_callableOpts).https.onCall(joinMeetupHandler);
const leaveMeetup = functions.runWith(_callableOpts).https.onCall(leaveMeetupHandler);
const confirmOpenClass = functions
  .runWith(_callableOpts)
  .https.onCall(confirmOpenClassHandler);
const joinChallenge = functions.runWith(_callableOpts).https.onCall(joinChallengeHandler);
const leaveChallenge = functions.runWith(_callableOpts).https.onCall(leaveChallengeHandler);
const submitChallengeProof = functions
  .runWith(_callableOpts)
  .https.onCall(submitChallengeProofHandler);

module.exports = {
  joinMeetup,
  leaveMeetup,
  confirmOpenClass,
  joinChallenge,
  leaveChallenge,
  submitChallengeProof,
};
