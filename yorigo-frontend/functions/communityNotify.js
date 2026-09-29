/**
 * 모임·챌린지 전용 인박스+FCM. index.js 알림 헬퍼를 건드리지 않는다.
 */
const admin = require("firebase-admin");

function sanitize(text, max = 180) {
  return String(text || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max);
}

async function getUserSummary(uid) {
  if (!uid) return { uid: "", name: "사용자", photoUrl: "" };
  try {
    const snap = await admin.firestore().collection("users").doc(uid).get();
    const data = snap.data() || {};
    const name =
      sanitize(data.name, 40) || sanitize(data.handle, 40) || "사용자";
    return { uid, name, photoUrl: sanitize(data.photoUrl, 500) };
  } catch (e) {
    console.error("[communityNotify] getUserSummary failed:", e);
    return { uid, name: "사용자", photoUrl: "" };
  }
}

async function notifyUser({
  targetUserId,
  type,
  actorId = "",
  actorName = "",
  message = "",
  meetupId = "",
  challengeId = "",
  eventKey = "",
  title = "요리고",
}) {
  if (!targetUserId || !type || !eventKey) return;
  if (targetUserId === actorId) return;

  const db = admin.firestore();
  const ref = db
    .collection("users")
    .doc(targetUserId)
    .collection("notifications")
    .doc(eventKey);
  const existing = await ref.get();
  if (existing.exists) return;

  await ref.set({
    notificationId: eventKey,
    type,
    actorId: actorId || "",
    actorName: sanitize(actorName, 40),
    actorPhotoUrl: "",
    reviewId: "",
    commentId: "",
    recipeId: "",
    meetupId: meetupId || "",
    challengeId: challengeId || "",
    targetUserId,
    message: sanitize(message),
    isRead: false,
    eventKey,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  try {
    const tokenSnap = await db
      .collection("users")
      .doc(targetUserId)
      .collection("fcmTokens")
      .get();
    const tokens = tokenSnap.docs
      .map((d) => d.id)
      .filter((t) => t && t.length > 20);
    if (tokens.length === 0) return;
    await admin.messaging().sendEachForMulticast({
      tokens,
      notification: {
        title: sanitize(title, 40) || "요리고",
        body: sanitize(message),
      },
      data: {
        type: type || "",
        meetupId: meetupId || "",
        challengeId: challengeId || "",
        actorId: actorId || "",
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
      android: {
        priority: "high",
        notification: { channelId: "yorigo_notifications" },
      },
    });
  } catch (e) {
    console.warn("[communityNotify] push failed:", e);
  }
}

module.exports = { getUserSummary, notifyUser, sanitize };
