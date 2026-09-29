"use strict";

/**
 * Hot Recipe Groups — write/read helpers shared by:
 *   - onRecipeWriteUpdateGroup (Firestore trigger)
 *   - refreshRecipeGroupCounts (scheduled)
 *   - backfillRecipeGroups (HTTP)
 *
 * Storage shape:
 *   recipes/{recipeId}
 *     + canonicalDish: string  (display name, e.g. "김치찌개")
 *     + groupKey:      string  (sanitized doc id, last value WE counted)
 *
 *   recipe_groups/{groupKey}
 *     - name: string
 *     - count: number             (visible+completed recipes in this group)
 *     - recentCount: number       (subset whose completedAt is within RECENT_DAYS)
 *     - latestRecipeId: string
 *     - latestThumbnailUrl: string
 *     - latestCompletedAt: Timestamp | null
 *     - updatedAt: Timestamp
 *
 *   recipe_group_aliases/{titleHash}  (managed by recipeCanonicalize.js)
 */

const admin = require("firebase-admin");
const {
  MIN_GROUP_SIZE,
  RECENT_DAYS,
  GROUP_QUERY_LIMIT,
  BACKFILL_PAGE_SIZE,
} = require("./recipeGroupConfig");
const {
  pickRecipeTitle,
  extractCanonicalDish,
  canonicalKeyFromName,
} = require("./recipeCanonicalize");

const RECENT_MS = RECENT_DAYS * 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

function _isVisibleCompleted(data) {
  if (!data || typeof data !== "object") return false;
  if (data.isHidden === true) return false;
  return String(data.status || "").toLowerCase() === "completed";
}

function _toMillis(ts) {
  if (!ts) return 0;
  if (typeof ts.toMillis === "function") return ts.toMillis();
  if (ts instanceof Date) return ts.getTime();
  if (typeof ts === "number") return ts;
  return 0;
}

function _isRecent(completedAt, now) {
  const ms = _toMillis(completedAt);
  if (!ms) return false;
  const ref = now || Date.now();
  return ref - ms <= RECENT_MS;
}

function _pickThumbnailUrl(data) {
  if (!data || typeof data !== "object") return "";
  const source = data.source && typeof data.source === "object" ? data.source : {};
  const url =
    data.thumbnailUrlCropped ||
    data.thumbnailUrl ||
    data.thumbnailUrlLarge ||
    source.thumbnail ||
    "";
  return String(url || "").trim();
}

function _shallowEqualPlatformOnly(before, after) {
  // Detect whether the only change is on fields we don't care about for
  // grouping. Used to short-circuit unrelated trigger fires.
  return (
    pickRecipeTitle(before) === pickRecipeTitle(after) &&
    String((before || {}).status || "") === String((after || {}).status || "") &&
    Boolean((before || {}).isHidden) === Boolean((after || {}).isHidden) &&
    _toMillis((before || {}).completedAt) === _toMillis((after || {}).completedAt) &&
    (before || {}).canonicalDish === (after || {}).canonicalDish &&
    (before || {}).groupKey === (after || {}).groupKey
  );
}

// ---------------------------------------------------------------------------
// Group document mutations (transactional)
// ---------------------------------------------------------------------------

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} groupKey
 * @param {{name: string, recipeId: string, completedAt: any, thumbnailUrl: string, isRecent: boolean}} payload
 */
async function _incrementGroup(db, groupKey, payload) {
  if (!groupKey) return;
  const ref = db.collection("recipe_groups").doc(groupKey);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const cur = snap.exists ? snap.data() || {} : {};
    const count = (Number.isFinite(cur.count) ? cur.count : 0) + 1;
    const recentCount =
      (Number.isFinite(cur.recentCount) ? cur.recentCount : 0) +
      (payload.isRecent ? 1 : 0);
    const curLatestMs = _toMillis(cur.latestCompletedAt);
    const newLatestMs = _toMillis(payload.completedAt);
    const update = {
      name: payload.name || cur.name || "",
      count,
      recentCount,
      eligible: count >= MIN_GROUP_SIZE,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (newLatestMs >= curLatestMs) {
      update.latestRecipeId = payload.recipeId;
      update.latestCompletedAt = payload.completedAt || null;
      update.latestThumbnailUrl = payload.thumbnailUrl || cur.latestThumbnailUrl || "";
    }
    tx.set(ref, update, { merge: true });
  });
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} groupKey
 * @param {{recipeId: string, wasRecent: boolean}} payload
 */
async function _decrementGroup(db, groupKey, payload) {
  if (!groupKey) return;
  const ref = db.collection("recipe_groups").doc(groupKey);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return;
    const cur = snap.data() || {};
    const count = Math.max(0, (Number.isFinite(cur.count) ? cur.count : 0) - 1);
    const recentCount = Math.max(
      0,
      (Number.isFinite(cur.recentCount) ? cur.recentCount : 0) - (payload.wasRecent ? 1 : 0)
    );
    if (count === 0) {
      tx.delete(ref);
      return;
    }
    const update = {
      count,
      recentCount,
      eligible: count >= MIN_GROUP_SIZE,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    // If the removed recipe was the latest, clear it; the scheduled refresh
    // will repopulate from the recipes collection. (Doing the lookup here
    // would require an extra read inside the transaction.)
    if (cur.latestRecipeId === payload.recipeId) {
      update.latestRecipeId = "";
      update.latestThumbnailUrl = "";
      update.latestCompletedAt = null;
    }
    tx.set(ref, update, { merge: true });
  });
}

async function _maybeUpdateLatest(db, groupKey, payload) {
  if (!groupKey) return;
  const ref = db.collection("recipe_groups").doc(groupKey);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return;
    const cur = snap.data() || {};
    const curMs = _toMillis(cur.latestCompletedAt);
    const newMs = _toMillis(payload.completedAt);
    if (newMs <= curMs && cur.latestRecipeId !== payload.recipeId) return;
    tx.set(
      ref,
      {
        latestRecipeId: payload.recipeId,
        latestCompletedAt: payload.completedAt || null,
        latestThumbnailUrl: payload.thumbnailUrl || cur.latestThumbnailUrl || "",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  });
}

// ---------------------------------------------------------------------------
// Trigger: onRecipeWriteUpdateGroup
// ---------------------------------------------------------------------------

/**
 * Reconcile recipe_groups membership for a single recipe write.
 *
 * Idempotency strategy: each recipe carries a `groupKey` that records WHICH
 * group document we last counted it in. We only mutate counts when the
 * desired key differs from the recorded key. This makes the trigger safe to
 * run multiple times (including the secondary fire produced by our own
 * write of `groupKey`/`canonicalDish` back to the recipe).
 *
 * @param {{ before: FirebaseFirestore.DocumentSnapshot, after: FirebaseFirestore.DocumentSnapshot }} change
 * @param {string} recipeId
 */
async function onRecipeWriteReconcileGroup(change, recipeId) {
  const db = admin.firestore();
  const beforeExists = change.before && change.before.exists;
  const afterExists = change.after && change.after.exists;
  const before = beforeExists ? change.before.data() || {} : {};
  const after = afterExists ? change.after.data() || {} : {};

  // What is currently counted in recipe_groups for this recipe? Use the
  // doc's most recent `groupKey` — for deletes, `before.groupKey` is the
  // last value we wrote.
  const currentlyCounted = afterExists
    ? (after.groupKey || "").toString()
    : (before.groupKey || "").toString();
  const wasRecent = _isRecent(before.completedAt, Date.now());

  // Desired state for `after`.
  let desiredKey = "";
  let desiredName = "";
  let desiredCanonicalDish = (after.canonicalDish || "").toString().trim();

  if (afterExists && _isVisibleCompleted(after)) {
    const titleChanged = pickRecipeTitle(before) !== pickRecipeTitle(after);
    if (desiredCanonicalDish && !titleChanged) {
      desiredName = desiredCanonicalDish;
      desiredKey = canonicalKeyFromName(desiredName);
    } else {
      const title = pickRecipeTitle(after);
      const ex = await extractCanonicalDish(title, { db });
      desiredName = ex.name || "";
      desiredKey = ex.key || "";
      desiredCanonicalDish = desiredName;
    }
  }

  // Quick exit: nothing relevant changed AND the recipe is already
  // recorded in the right group. Just maybe refresh `latest*`.
  if (currentlyCounted === desiredKey && _shallowEqualPlatformOnly(before, after)) {
    if (desiredKey) {
      await _maybeUpdateLatest(db, desiredKey, {
        recipeId,
        completedAt: after.completedAt,
        thumbnailUrl: _pickThumbnailUrl(after),
      });
    }
    return { status: "noop" };
  }

  // Real reconciliation: decrement old group (if any) and/or increment new.
  if (currentlyCounted && currentlyCounted !== desiredKey) {
    await _decrementGroup(db, currentlyCounted, {
      recipeId,
      wasRecent,
    });
  }

  const isRecent = _isRecent(after.completedAt, Date.now());
  if (desiredKey && currentlyCounted !== desiredKey) {
    await _incrementGroup(db, desiredKey, {
      name: desiredName,
      recipeId,
      completedAt: after.completedAt,
      thumbnailUrl: _pickThumbnailUrl(after),
      isRecent,
    });
  } else if (desiredKey && currentlyCounted === desiredKey) {
    await _maybeUpdateLatest(db, desiredKey, {
      recipeId,
      completedAt: after.completedAt,
      thumbnailUrl: _pickThumbnailUrl(after),
    });
  }

  // Persist `canonicalDish`/`groupKey` on the recipe doc when they differ
  // from what we just decided. Only when the recipe still exists; avoid
  // resurrecting deleted docs. Same-value writes are skipped to prevent
  // self-trigger loops.
  if (afterExists) {
    const needRecipeWrite =
      (after.canonicalDish || "") !== (desiredCanonicalDish || "") ||
      (after.groupKey || "") !== (desiredKey || "");
    if (needRecipeWrite) {
      const update = {};
      update.canonicalDish = desiredCanonicalDish || admin.firestore.FieldValue.delete();
      update.groupKey = desiredKey || admin.firestore.FieldValue.delete();
      try {
        await change.after.ref.set(update, { merge: true });
      } catch (e) {
        console.warn(
          `[CF][recipe_groups] failed to persist groupKey on ${recipeId}:`,
          e && e.message ? e.message : e
        );
      }
    }
  }

  return { status: "reconciled", currentlyCounted, desiredKey };
}

// ---------------------------------------------------------------------------
// Scheduled refresh: recompute recentCount + drop empty groups
// ---------------------------------------------------------------------------

async function refreshAllGroups(opts = {}) {
  const db = admin.firestore();
  const limit = Number.isFinite(opts.limit) ? opts.limit : GROUP_QUERY_LIMIT;
  const cutoff = admin.firestore.Timestamp.fromMillis(
    Date.now() - RECENT_MS
  );

  const groupsSnap = await db.collection("recipe_groups").limit(limit).get();
  let processed = 0;
  let deleted = 0;
  let updated = 0;

  for (const groupDoc of groupsSnap.docs) {
    processed += 1;
    const groupKey = groupDoc.id;
    const cur = groupDoc.data() || {};
    const name = (cur.name || "").toString().trim();
    if (!name) continue;

    let recentCount = 0;
    try {
      const recentSnap = await db
        .collection("recipes")
        .where("groupKey", "==", groupKey)
        .where("isHidden", "==", false)
        .where("status", "==", "completed")
        .where("completedAt", ">=", cutoff)
        .count()
        .get();
      recentCount = recentSnap.data().count || 0;
    } catch (e) {
      console.warn(
        `[CF][recipe_groups] recent count failed for ${groupKey}:`,
        e && e.message ? e.message : e
      );
      continue;
    }

    let totalCount = 0;
    try {
      const totalSnap = await db
        .collection("recipes")
        .where("groupKey", "==", groupKey)
        .where("isHidden", "==", false)
        .where("status", "==", "completed")
        .count()
        .get();
      totalCount = totalSnap.data().count || 0;
    } catch (e) {
      console.warn(
        `[CF][recipe_groups] total count failed for ${groupKey}:`,
        e && e.message ? e.message : e
      );
      continue;
    }

    if (totalCount === 0) {
      await groupDoc.ref.delete();
      deleted += 1;
      continue;
    }

    // Refresh latest pointer if missing.
    let latest = {
      latestRecipeId: cur.latestRecipeId || "",
      latestCompletedAt: cur.latestCompletedAt || null,
      latestThumbnailUrl: cur.latestThumbnailUrl || "",
    };
    if (!latest.latestRecipeId) {
      try {
        const latestSnap = await db
          .collection("recipes")
          .where("groupKey", "==", groupKey)
          .where("isHidden", "==", false)
          .where("status", "==", "completed")
          .orderBy("completedAt", "desc")
          .limit(1)
          .get();
        if (!latestSnap.empty) {
          const doc = latestSnap.docs[0];
          const data = doc.data() || {};
          latest = {
            latestRecipeId: doc.id,
            latestCompletedAt: data.completedAt || null,
            latestThumbnailUrl: _pickThumbnailUrl(data),
          };
        }
      } catch (e) {
        console.warn(
          `[CF][recipe_groups] latest lookup failed for ${groupKey}:`,
          e && e.message ? e.message : e
        );
      }
    }

    await groupDoc.ref.set(
      {
        name,
        count: totalCount,
        recentCount,
        eligible: totalCount >= MIN_GROUP_SIZE,
        latestRecipeId: latest.latestRecipeId,
        latestCompletedAt: latest.latestCompletedAt,
        latestThumbnailUrl: latest.latestThumbnailUrl,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    updated += 1;
  }

  return { processed, updated, deleted };
}

// ---------------------------------------------------------------------------
// Backfill: scan all recipes and (re)build recipe_groups from scratch.
// ---------------------------------------------------------------------------

async function backfillAllGroups(opts = {}) {
  const db = admin.firestore();
  const useLlm = opts.useLlm !== false;
  const dryRun = opts.dryRun === true;
  const pageSize = Number.isFinite(opts.pageSize) ? opts.pageSize : BACKFILL_PAGE_SIZE;
  const maxRecipes = Number.isFinite(opts.maxRecipes) ? opts.maxRecipes : 0;

  // Aggregate in-memory then write per group.
  /** @type {Map<string, {name:string,count:number,recentCount:number,latestRecipeId:string,latestThumbnailUrl:string,latestCompletedAtMs:number,latestCompletedAt:any}>} */
  const groups = new Map();
  const recipeUpdates = []; // [{ ref, data }] queued recipe writes

  let totalScanned = 0;
  let totalCounted = 0;
  let lastDoc = null;
  const now = Date.now();

  // eslint-disable-next-line no-constant-condition
  while (true) {
    let q = db
      .collection("recipes")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(pageSize);
    if (lastDoc) q = q.startAfter(lastDoc.id);
    const snap = await q.get();
    if (snap.empty) break;
    lastDoc = snap.docs[snap.docs.length - 1];
    for (const doc of snap.docs) {
      totalScanned += 1;
      if (maxRecipes && totalScanned > maxRecipes) break;
      const data = doc.data() || {};
      if (!_isVisibleCompleted(data)) continue;
      const title = pickRecipeTitle(data);
      if (!title) continue;
      const ex = await extractCanonicalDish(title, { db, useLlm });
      if (!ex.key || !ex.name) continue;

      totalCounted += 1;
      const completedMs = _toMillis(data.completedAt);
      const isRecent = _isRecent(data.completedAt, now);
      const cur = groups.get(ex.key) || {
        name: ex.name,
        count: 0,
        recentCount: 0,
        latestRecipeId: "",
        latestThumbnailUrl: "",
        latestCompletedAtMs: 0,
        latestCompletedAt: null,
      };
      cur.count += 1;
      if (isRecent) cur.recentCount += 1;
      if (completedMs >= cur.latestCompletedAtMs) {
        cur.latestCompletedAtMs = completedMs;
        cur.latestCompletedAt = data.completedAt || null;
        cur.latestRecipeId = doc.id;
        cur.latestThumbnailUrl = _pickThumbnailUrl(data);
      }
      groups.set(ex.key, cur);

      if ((data.canonicalDish || "") !== ex.name || (data.groupKey || "") !== ex.key) {
        recipeUpdates.push({
          ref: doc.ref,
          data: { canonicalDish: ex.name, groupKey: ex.key },
        });
      }
    }
    if (snap.size < pageSize) break;
    if (maxRecipes && totalScanned >= maxRecipes) break;
  }

  if (dryRun) {
    return {
      dryRun: true,
      totalScanned,
      totalCounted,
      groupCount: groups.size,
      groups: Array.from(groups.entries())
        .map(([key, v]) => ({ key, name: v.name, count: v.count, recentCount: v.recentCount }))
        .sort((a, b) => b.count - a.count)
        .slice(0, 20),
    };
  }

  // Write recipe updates in batches.
  let batchCount = 0;
  let batch = db.batch();
  let recipeWritten = 0;
  for (const u of recipeUpdates) {
    batch.set(u.ref, u.data, { merge: true });
    batchCount += 1;
    recipeWritten += 1;
    if (batchCount >= 400) {
      await batch.commit();
      batch = db.batch();
      batchCount = 0;
    }
  }
  if (batchCount > 0) await batch.commit();

  // Write group docs (not batched — each is one set, simpler).
  let groupWritten = 0;
  for (const [key, v] of groups.entries()) {
    await db.collection("recipe_groups").doc(key).set(
      {
        name: v.name,
        count: v.count,
        recentCount: v.recentCount,
        eligible: v.count >= MIN_GROUP_SIZE,
        latestRecipeId: v.latestRecipeId,
        latestCompletedAt: v.latestCompletedAt,
        latestThumbnailUrl: v.latestThumbnailUrl,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    groupWritten += 1;
  }

  return {
    dryRun: false,
    totalScanned,
    totalCounted,
    groupCount: groups.size,
    recipeUpdatesWritten: recipeWritten,
    groupDocsWritten: groupWritten,
    minGroupSize: MIN_GROUP_SIZE,
  };
}

module.exports = {
  // trigger handler
  onRecipeWriteReconcileGroup,
  // scheduled handler
  refreshAllGroups,
  // backfill handler
  backfillAllGroups,
  // exposed for tests
  _internal: {
    _isVisibleCompleted,
    _isRecent,
    _pickThumbnailUrl,
  },
};
