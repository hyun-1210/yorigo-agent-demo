/**
 * home_section_index 빌드 — 규칙 매칭 + home_section_overrides(pin/block) 병합.
 */

const admin = require("firebase-admin");
const {
  getSectionRules,
  isManualIndexKey,
  matchedHomeSectionKeys,
  matchesSectionRuleForKey,
  sectionLimit,
  sectionSortBy,
} = require("./homeSectionRules");

const PAGE_SIZE = 300;

function _sanitizeText(v) {
  return (v || "").toString().trim();
}

function _sanitizeIdList(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  const seen = new Set();
  for (const item of raw) {
    const id = _sanitizeText(item);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

function _isVisibleCompletedRecipe(data) {
  if (!data || typeof data !== "object") return false;
  if (data.isHidden === true) return false;
  return _sanitizeText(data.status).toLowerCase() === "completed";
}

function _llmEstimate(data) {
  const nutrition = data && data.nutrition;
  if (!nutrition || typeof nutrition !== "object") return null;
  const est = nutrition.llm_estimate;
  return est && typeof est === "object" ? est : null;
}

function _numAsDouble(v) {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number.parseFloat(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function _parsedAtScore(data) {
  for (const key of ["completedAt", "createdAt"]) {
    const value = data && data[key];
    if (!value) continue;
    if (typeof value.toDate === "function") {
      return value.toDate().getTime();
    }
    if (value instanceof Date) return value.getTime();
  }
  return 0;
}

function _proteinScore(data) {
  const est = _llmEstimate(data);
  if (!est) return -1;
  return _numAsDouble(est.protein_g) ?? -1;
}

function normalizeOverridesDoc(data) {
  const doc = data && typeof data === "object" ? data : {};
  return {
    pinnedIds: _sanitizeIdList(doc.pinnedIds),
    blockedIds: _sanitizeIdList(doc.blockedIds),
  };
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sectionKey
 */
async function loadOverrides(db, sectionKey) {
  const snap = await db.collection("home_section_overrides").doc(sectionKey).get();
  return normalizeOverridesDoc(snap.exists ? snap.data() : {});
}

/**
 * pin > block > rule 순으로 포함 여부 판정.
 */
function shouldIncludeRecipe(recipeId, data, sectionKey, overrides) {
  const id = _sanitizeText(recipeId);
  if (!id) return false;
  if (isManualIndexKey(sectionKey)) {
    return new Set(overrides.pinnedIds).has(id);
  }
  const pinned = new Set(overrides.pinnedIds);
  const blocked = new Set(overrides.blockedIds);
  if (pinned.has(id)) return true;
  if (blocked.has(id)) return false;
  if (!data || !_isVisibleCompletedRecipe(data)) return false;
  return matchesSectionRuleForKey(data, sectionKey);
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sectionKey
 */
async function buildSectionRecipeIds(db, sectionKey) {
  if (isManualIndexKey(sectionKey)) {
    const overrides = await loadOverrides(db, sectionKey);
    const indexSnap = await db.collection("home_section_index").doc(sectionKey).get();
    const current = _sanitizeIdList(
      indexSnap.exists ? (indexSnap.data() || {}).recipeIds : []
    );
    const blocked = new Set(overrides.blockedIds);
    const pinned = overrides.pinnedIds.filter((id) => !blocked.has(id));
    const rest = current.filter(
      (id) => !blocked.has(id) && !pinned.includes(id)
    );
    return [...pinned, ...rest].slice(0, sectionLimit(sectionKey));
  }

  const overrides = await loadOverrides(db, sectionKey);
  const blocked = new Set(overrides.blockedIds);
  const pinnedSet = new Set(overrides.pinnedIds);

  const ruleMatched = [];
  let lastDoc = null;

  while (true) {
    let query = db.collection("recipes").orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE_SIZE);
    if (lastDoc) query = query.startAfter(lastDoc);
    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      const data = doc.data() || {};
      const rid = doc.id;
      if (!_isVisibleCompletedRecipe(data)) continue;
      if (blocked.has(rid)) continue;
      if (pinnedSet.has(rid)) continue;
      if (!matchesSectionRuleForKey(data, sectionKey)) continue;
      ruleMatched.push({
        id: rid,
        parsed: _parsedAtScore(data),
        protein: _proteinScore(data),
      });
    }
    lastDoc = snap.docs[snap.docs.length - 1];
  }

  return _mergePinnedAndRuleMatched(db, overrides, ruleMatched, sectionKey);
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sectionKey
 * @param {string[]} recipeIds
 */
async function writeSectionIndex(db, sectionKey, recipeIds) {
  const ids = _sanitizeIdList(recipeIds);
  await db.collection("home_section_index").doc(sectionKey).set(
    {
      sectionKey,
      recipeIds: ids,
      count: ids.length,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  return ids;
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} [sectionKey] — 없으면 전체 섹션
 */
async function rebuildHomeSectionIndex(db, sectionKey) {
  const keys = sectionKey
    ? [_sanitizeText(sectionKey)]
    : Object.keys(getSectionRules());
  const results = {};
  for (const key of keys) {
    if (!key) continue;
    const ids = await buildSectionRecipeIds(db, key);
    await writeSectionIndex(db, key, ids);
    results[key] = ids.length;
  }
  return results;
}

/** TV/프로그램 섹션 키만 (`program_*`). */
function programSectionKeys() {
  return Object.keys(getSectionRules())
    .filter((key) => key.startsWith("program_"))
    .sort();
}

/**
 * pin 유효성 검사 후 pin + ruleMatched 를 limit 까지 병합한다.
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ pinnedIds: string[], blockedIds: string[] }} overrides
 * @param {{ id: string, parsed: number, protein: number }[]} ruleMatched
 * @param {string} sectionKey
 */
async function _mergePinnedAndRuleMatched(db, overrides, ruleMatched, sectionKey) {
  const blocked = new Set(overrides.blockedIds);
  const limit = sectionLimit(sectionKey);
  const sortBy = sectionSortBy(sectionKey);
  const matched = [...ruleMatched];

  if (sortBy === "proteinDesc") {
    matched.sort((a, b) => b.protein - a.protein || b.parsed - a.parsed);
  } else {
    matched.sort((a, b) => b.parsed - a.parsed);
  }

  const validPinned = [];
  for (const pid of overrides.pinnedIds) {
    if (blocked.has(pid)) continue;
    const snap = await db.collection("recipes").doc(pid).get();
    if (!snap.exists) continue;
    const data = snap.data() || {};
    if (!_isVisibleCompletedRecipe(data)) continue;
    validPinned.push(pid);
  }

  const pinnedUsed = new Set(validPinned);
  const merged = [
    ...validPinned,
    ...matched.map((x) => x.id).filter((id) => !pinnedUsed.has(id)),
  ];
  return merged.slice(0, limit);
}

/**
 * program_* 섹션만 recipes 를 **한 번** 스캔해 인덱스를 채운다.
 * overrides 는 읽기만 하며, dryRun=true 이면 쓰기 없이 counts 만 반환한다.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ dryRun?: boolean }} [options]
 * @returns {Promise<{ counts: Record<string, number>, dryRun: boolean, scannedRecipes: number }>}
 */
async function rebuildProgramHomeSectionIndexes(db, options = {}) {
  const dryRun = !!(options && options.dryRun);
  const keys = programSectionKeys();
  const counts = {};
  for (const key of keys) counts[key] = 0;
  if (keys.length === 0) {
    return { counts, dryRun, scannedRecipes: 0 };
  }

  /** @type {Map<string, { pinnedIds: string[], blockedIds: string[] }>} */
  const overridesByKey = new Map();
  /** @type {Map<string, Set<string>>} */
  const blockedByKey = new Map();
  /** @type {Map<string, Set<string>>} */
  const pinnedByKey = new Map();
  /** @type {Map<string, { id: string, parsed: number, protein: number }[]>} */
  const matchedByKey = new Map();

  for (const key of keys) {
    const overrides = await loadOverrides(db, key);
    overridesByKey.set(key, overrides);
    blockedByKey.set(key, new Set(overrides.blockedIds));
    pinnedByKey.set(key, new Set(overrides.pinnedIds));
    matchedByKey.set(key, []);
  }

  let scannedRecipes = 0;
  let lastDoc = null;
  while (true) {
    let query = db
      .collection("recipes")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(PAGE_SIZE);
    if (lastDoc) query = query.startAfter(lastDoc);
    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      scannedRecipes += 1;
      const data = doc.data() || {};
      const rid = doc.id;
      if (!_isVisibleCompletedRecipe(data)) continue;

      for (const key of keys) {
        if (blockedByKey.get(key).has(rid)) continue;
        if (pinnedByKey.get(key).has(rid)) continue;
        if (!matchesSectionRuleForKey(data, key)) continue;
        matchedByKey.get(key).push({
          id: rid,
          parsed: _parsedAtScore(data),
          protein: _proteinScore(data),
        });
      }
    }
    lastDoc = snap.docs[snap.docs.length - 1];
  }

  for (const key of keys) {
    const ids = await _mergePinnedAndRuleMatched(
      db,
      overridesByKey.get(key),
      matchedByKey.get(key),
      key
    );
    counts[key] = ids.length;
    if (!dryRun) {
      await writeSectionIndex(db, key, ids);
    }
  }

  return { counts, dryRun, scannedRecipes };
}

/**
 * 레시피 1건 변경 시 영향받는 섹션 인덱스 증분 갱신.
 * @param {boolean} isNewRecipe - true면 방금 최초 생성된 레시피(recipes/{id} onCreate).
 *   Firestore 문서 ID는 add()로 자동 채번되므로, 생성 이전에는 그 어떤 관리자도
 *   이 recipeId를 pinnedIds/blockedIds에 넣어둘 수 없었다. 따라서 신규 생성 건은
 *   home_section_overrides 컬렉션 전체를 읽을 필요가 없고, 규칙 매칭 섹션만 보면 된다.
 */
async function syncHomeSectionIndexForRecipe(db, recipeId, beforeData, afterData, isNewRecipe = false) {
  const rid = _sanitizeText(recipeId);
  if (!rid) return;

  const beforeKeys = new Set(
    _isVisibleCompletedRecipe(beforeData) ? matchedHomeSectionKeys(beforeData) : []
  );
  const afterKeys = new Set(
    _isVisibleCompletedRecipe(afterData) ? matchedHomeSectionKeys(afterData) : []
  );

  let overridesBySectionKey = new Map();
  let impacted;
  if (isNewRecipe) {
    // 신규 레시피는 어떤 섹션에도 pin/block 되어 있을 수 없음 → overrides 전체 스캔 생략.
    impacted = afterKeys;
  } else {
    const overrideSnaps = await db.collection("home_section_overrides").get();
    overrideSnaps.docs.forEach((doc) => {
      overridesBySectionKey.set(doc.id, normalizeOverridesDoc(doc.data()));
    });
    impacted = new Set([...beforeKeys, ...afterKeys, ...overridesBySectionKey.keys()]);
  }

  for (const sectionKey of impacted) {
    if (isManualIndexKey(sectionKey)) continue;
    // overrides는 위에서 이미 한 번에 읽어둔 맵을 재사용한다 (섹션당 재조회 제거).
    const overrides = overridesBySectionKey.get(sectionKey) || normalizeOverridesDoc({});
    const pinned = new Set(overrides.pinnedIds);
    const blocked = new Set(overrides.blockedIds);
    const isPinned = pinned.has(rid);
    const isBlocked = blocked.has(rid);

    const ruleBefore = beforeKeys.has(sectionKey);
    const ruleAfter = afterKeys.has(sectionKey);
    const shouldIncludeAfter = isPinned || (!isBlocked && ruleAfter);
    const wasIncludedBefore = isPinned || (!isBlocked && ruleBefore);

    if (!wasIncludedBefore && !shouldIncludeAfter) continue;

    const limit = sectionLimit(sectionKey);
    const docRef = db.collection("home_section_index").doc(sectionKey);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const data = snap.exists ? snap.data() || {} : {};
      let current = _sanitizeIdList(data.recipeIds);

      if (isPinned && shouldIncludeAfter) {
        current = [rid, ...current.filter((id) => id !== rid)];
      } else if (shouldIncludeAfter) {
        current = [rid, ...current.filter((id) => id !== rid)];
      } else {
        current = current.filter((id) => id !== rid);
      }

      for (const pid of overrides.pinnedIds) {
        if (pid === rid || blocked.has(pid)) continue;
        if (!current.includes(pid)) {
          current = [pid, ...current];
        }
      }

      const pinnedOrder = overrides.pinnedIds.filter((pid) => current.includes(pid));
      const rest = current.filter((id) => !pinnedOrder.includes(id));
      const next = [...pinnedOrder, ...rest].slice(0, limit);

      tx.set(
        docRef,
        {
          sectionKey,
          recipeIds: next,
          count: next.length,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });
  }
}

module.exports = {
  PAGE_SIZE,
  normalizeOverridesDoc,
  loadOverrides,
  shouldIncludeRecipe,
  buildSectionRecipeIds,
  writeSectionIndex,
  rebuildHomeSectionIndex,
  programSectionKeys,
  rebuildProgramHomeSectionIndexes,
  syncHomeSectionIndexForRecipe,
  _isVisibleCompletedRecipe,
};
