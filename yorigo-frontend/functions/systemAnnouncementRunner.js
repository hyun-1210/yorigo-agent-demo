"use strict";

const { getSystemBroadcast } = require("./systemBroadcasts");

/**
 * @param {unknown} value
 * @returns {string}
 */
function sanitizeText(value) {
  if (value == null) return "";
  return String(value).replace(/\0/g, "").trim();
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} targetUserId
 * @param {string} eventKey
 */
async function notificationWithEventKeyExists(db, targetUserId, eventKey) {
  if (!targetUserId || !eventKey) return false;
  const notifRef = db
    .collection("users")
    .doc(targetUserId)
    .collection("notifications");
  const dupSnap = await notifRef.where("eventKey", "==", eventKey).limit(1).get();
  return !dupSnap.empty;
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {import("firebase-admin").firestore.FieldValue} FieldValue
 */
async function createNotificationOnce(db, FieldValue, params) {
  const {
    targetUserId,
    type,
    actorId = "",
    actorName = "",
    actorPhotoUrl = "",
    message = "",
    title = "",
    eventKey = "",
  } = params;
  if (!targetUserId || !type || !eventKey) return null;
  if (await notificationWithEventKeyExists(db, targetUserId, eventKey)) {
    return null;
  }

  const notifRef = db
    .collection("users")
    .doc(targetUserId)
    .collection("notifications");
  const docRef = notifRef.doc();
  const payload = {
    notificationId: docRef.id,
    type,
    actorId,
    actorName: sanitizeText(actorName),
    actorPhotoUrl: sanitizeText(actorPhotoUrl),
    reviewId: "",
    commentId: "",
    recipeId: "",
    targetUserId,
    message: sanitizeText(message),
    isRead: false,
    eventKey: sanitizeText(eventKey),
    createdAt: FieldValue.serverTimestamp(),
  };
  const sanitizedTitle = sanitizeText(title);
  if (sanitizedTitle) {
    payload.title = sanitizedTitle;
  }
  await docRef.set(payload);
  return docRef.id;
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {import("firebase-admin").messaging.Messaging} messaging
 */
async function sendPushToUser(db, messaging, targetUserId, payload) {
  if (!targetUserId) {
    return {
      ok: false,
      reason: "missing_target_user",
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  const tokenSnap = await db
    .collection("users")
    .doc(targetUserId)
    .collection("fcmTokens")
    .get();
  const tokens = tokenSnap.docs
    .map((d) => d.id)
    .filter((t) => !!t && t.length > 20);

  if (tokens.length === 0) {
    return {
      ok: false,
      reason: "no_tokens",
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }

  const message = {
    tokens,
    notification: {
      title: payload.title || "요리고",
      body: payload.body || "",
    },
    data: {
      type: payload.type || "",
      reviewId: "",
      commentId: "",
      recipeId: "",
      actorId: "",
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    android: {
      priority: "high",
      notification: { channelId: "yorigo_notifications" },
    },
    apns: {
      headers: {
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      payload: {
        aps: {
          sound: "default",
          badge: 1,
        },
      },
    },
  };

  const result = await messaging.sendEachForMulticast(message);
  const invalidTokens = [];
  if (result.failureCount > 0) {
    result.responses.forEach((r, idx) => {
      if (r.success) return;
      const code = r.error && r.error.code ? r.error.code : "";
      if (
        code.includes("registration-token-not-registered") ||
        code.includes("invalid-argument")
      ) {
        invalidTokens.push(tokens[idx]);
      }
    });
    if (invalidTokens.length > 0) {
      const batch = db.batch();
      invalidTokens.forEach((token) => {
        const ref = db
          .collection("users")
          .doc(targetUserId)
          .collection("fcmTokens")
          .doc(token);
        batch.delete(ref);
      });
      await batch.commit();
    }
  }

  return {
    ok: result.successCount > 0,
    reason: result.successCount > 0 ? "sent" : "all_failed",
    tokenCount: tokens.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  };
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {import("firebase-admin").messaging.Messaging} messaging
 * @param {import("firebase-admin").firestore.FieldValue} FieldValue
 * @param {{ campaignId: string, type: string, title: string, body: string }} config
 * @param {string} uid
 */
async function sendOneTimeSystemAnnouncementToUser(
  db,
  messaging,
  FieldValue,
  config,
  uid
) {
  const eventKey = `system_announcement:${config.campaignId}`;
  if (await notificationWithEventKeyExists(db, uid, eventKey)) {
    return { sent: false, skipped: true, pushOk: false, reason: "already_sent" };
  }

  const notificationId = await createNotificationOnce(db, FieldValue, {
    targetUserId: uid,
    type: config.type,
    actorId: "",
    actorName: "요리고",
    actorPhotoUrl: "",
    title: config.title,
    message: config.body,
    eventKey,
  });
  if (!notificationId) {
    return { sent: false, skipped: true, pushOk: false, reason: "already_sent" };
  }

  const pushResult = await sendPushToUser(db, messaging, uid, {
    type: config.type,
    title: config.title,
    body: config.body,
  });

  return {
    sent: true,
    skipped: false,
    pushOk: !!pushResult.ok,
    reason: pushResult.ok ? "sent" : pushResult.reason || "push_failed",
  };
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {import("firebase-admin").messaging.Messaging} messaging
 * @param {import("firebase-admin").firestore.FieldValue} FieldValue
 * @param {{ campaignId: string, type: string, title: string, body: string }} config
 */
async function broadcastSystemAnnouncementToAllUsers(
  db,
  messaging,
  FieldValue,
  config
) {
  let sent = 0;
  let skipped = 0;
  let failed = 0;
  let processed = 0;
  let pushSent = 0;
  let lastDoc = null;
  const pageSize = 200;
  const chunkSize = 25;

  while (true) {
    let query = db
      .collection("users")
      .orderBy(require("firebase-admin").firestore.FieldPath.documentId())
      .limit(pageSize);
    if (lastDoc) {
      query = query.startAfter(lastDoc);
    }

    const snap = await query.get();
    if (snap.empty) break;

    const uids = snap.docs.map((doc) => doc.id);
    for (let i = 0; i < uids.length; i += chunkSize) {
      const chunk = uids.slice(i, i + chunkSize);
      const results = await Promise.all(
        chunk.map(async (uid) => {
          try {
            return await sendOneTimeSystemAnnouncementToUser(
              db,
              messaging,
              FieldValue,
              config,
              uid
            );
          } catch (e) {
            console.error(`[system_announcement] user ${uid} failed:`, e);
            return { sent: false, skipped: false, pushOk: false, reason: "failed" };
          }
        })
      );

      results.forEach((result) => {
        processed += 1;
        if (result.sent) {
          sent += 1;
          if (result.pushOk) pushSent += 1;
        } else if (result.skipped) {
          skipped += 1;
        } else {
          failed += 1;
        }
      });
    }

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < pageSize) break;
  }

  return { sent, skipped, failed, processed, pushSent };
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {import("firebase-admin").messaging.Messaging} messaging
 * @param {import("firebase-admin").firestore.FieldValue} FieldValue
 * @param {string} campaignId
 */
async function runSystemAnnouncementBroadcast(db, messaging, FieldValue, campaignId) {
  const config = getSystemBroadcast(campaignId);
  if (!config) {
    throw new Error(`unsupported_campaign:${campaignId}`);
  }
  return broadcastSystemAnnouncementToAllUsers(
    db,
    messaging,
    FieldValue,
    config
  );
}

module.exports = {
  runSystemAnnouncementBroadcast,
  broadcastSystemAnnouncementToAllUsers,
  getSystemBroadcast,
};
