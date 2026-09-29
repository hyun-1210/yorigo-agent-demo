#!/usr/bin/env node
"use strict";

/**
 * 최적화 백필 — 로컬 실행 (admin SDK 사용, HTTPS 함수 호출 불필요).
 *
 * Tasks:
 *   - saveCount     : recipes.saveCount / monthlySaves / weeklySaves 누락분 0 으로 백필.
 *                     "방법 A" 인덱스 쿼리 (orderBy saveCount/monthlySaves) 가 누락 doc 을
 *                     결과에서 빠뜨리지 않도록 함.
 *   - savedRecipes  : users/{uid}/savedRecipes/{rid} 미니 doc 백필. Hybrid denormalization
 *                     이전에 저장된 옛 데이터를 빠른 경로(_tryFastSavedRecipesEmit) 가
 *                     쓸 수 있게 채운다.
 *
 * Usage:
 *   cd yorigo-frontend/functions
 *   node tools/run_optimization_backfills.js --task=saveCount [--dry-run]
 *   node tools/run_optimization_backfills.js --task=savedRecipes [--dry-run] [--user-id=<uid>]
 *   node tools/run_optimization_backfills.js --task=savedRecipes [--start-after-user-id=<uid>]
 *
 * savedRecipes 는 users 전체 stream 대신 페이지 단위로 처리한다 (gRPC 300s 타임아웃 방지).
 * 중간에 끊기면 출력된 start-after-user-id 로 이어서 실행.
 *
 * 환경변수:
 *   FIREBASE_SERVICE_ACCOUNT_JSON   → backend/.env 또는 functions/.env 에서 자동 로딩
 *                                     (값이 '{' 로 시작하면 JSON 자체로,
 *                                      아니면 파일 경로로 해석)
 *   fallback: backend/firebase-service-account.json
 */

const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const FUNCTIONS_DIR = path.resolve(HERE, "..");
const FRONTEND_DIR = path.resolve(FUNCTIONS_DIR, "..");
const REPO_ROOT = path.resolve(FRONTEND_DIR, "..");
const BACKEND_DIR = path.resolve(REPO_ROOT, "backend");

function loadEnvFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return false;
  const content = fs.readFileSync(filePath, "utf8");
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (!process.env[key]) process.env[key] = val;
  }
  return true;
}

loadEnvFile(path.join(FUNCTIONS_DIR, ".env.yorigo-f7408"));
loadEnvFile(path.join(FUNCTIONS_DIR, ".env"));
loadEnvFile(path.join(BACKEND_DIR, ".env"));

function getServiceAccount() {
  const env = (process.env.FIREBASE_SERVICE_ACCOUNT_JSON || "").trim();
  if (env) {
    if (env.startsWith("{")) return JSON.parse(env);
    const candidates = [
      env,
      path.resolve(process.cwd(), env),
      path.resolve(BACKEND_DIR, env),
    ];
    for (const p of candidates) {
      if (fs.existsSync(p)) return JSON.parse(fs.readFileSync(p, "utf8"));
    }
  }
  const fallback = path.join(BACKEND_DIR, "firebase-service-account.json");
  if (fs.existsSync(fallback)) return JSON.parse(fs.readFileSync(fallback, "utf8"));
  throw new Error(
    "Service account not found. Set FIREBASE_SERVICE_ACCOUNT_JSON or place file at backend/firebase-service-account.json"
  );
}

const args = process.argv.slice(2);
const taskArg = args.find((a) => a.startsWith("--task="));
const task = taskArg ? taskArg.slice("--task=".length) : null;
const dryRun = args.includes("--dry-run");
const userIdArg = args.find((a) => a.startsWith("--user-id="));
const userIdFilter = userIdArg ? userIdArg.slice("--user-id=".length) : null;
const startAfterArg = args.find((a) => a.startsWith("--start-after-user-id="));
const startAfterUserId = startAfterArg
  ? startAfterArg.slice("--start-after-user-id=".length)
  : null;
const pageSizeArg = args.find((a) => a.startsWith("--page-size="));
const USER_PAGE_SIZE = pageSizeArg
  ? Math.max(10, Number.parseInt(pageSizeArg.slice("--page-size=".length), 10) || 50)
  : 50;

if (!task || !["saveCount", "savedRecipes"].includes(task)) {
  console.error(
    "Usage: node tools/run_optimization_backfills.js --task=<saveCount|savedRecipes> [--dry-run] [--user-id=<uid>] [--start-after-user-id=<uid>] [--page-size=50]"
  );
  process.exit(1);
}

// recipes/{rid} 본문 → 미니 doc 카드 필드 추출. functions/index.js 의
// _buildSavedRecipeMiniPatch 와 동일한 규칙.
function pickMiniCreatorField(source, after, key) {
  const fromSource = source && source[key];
  if (typeof fromSource === "string" && fromSource.trim()) {
    return fromSource.trim();
  }
  const top = after && after[key];
  if (typeof top === "string" && top.trim()) {
    return top.trim();
  }
  return null;
}

function buildSavedRecipeMiniPatch(after) {
  const recipeBody =
    (after && typeof after.recipe === "object" && after.recipe) || {};
  const ingredients = Array.isArray(recipeBody.ingredients)
    ? recipeBody.ingredients
    : [];
  const steps = Array.isArray(recipeBody.steps) ? recipeBody.steps : [];
  let totalMinutes = 0;
  for (const s of steps) {
    if (s && typeof s.est_minutes === "number") {
      totalMinutes += Math.floor(s.est_minutes);
    }
  }
  const calories =
    typeof (after && after.calories) === "number" ? after.calories : 0;
  const source =
    (after && typeof after.source === "object" && after.source) || {};
  return {
    title: (after && after.title) || null,
    thumbnailUrl: (after && after.thumbnailUrl) || null,
    thumbnailUrlLarge: (after && after.thumbnailUrlLarge) || null,
    thumbnailUrlCropped: (after && after.thumbnailUrlCropped) || null,
    sourcePlatform: source.platform || null,
    sourceUrl: (after && after.sourceUrl) || null,
    sourceUploader: pickMiniCreatorField(source, after, "uploader"),
    sourceChannel: pickMiniCreatorField(source, after, "channel"),
    status: (after && after.status) || null,
    isHidden: (after && after.isHidden) === true,
    calories,
    ingredientCount: ingredients.length,
    totalMinutes,
  };
}

function miniDocNeedsCreatorBackfill(mini) {
  const u = mini && mini.sourceUploader;
  const c = mini && mini.sourceChannel;
  const hasU = typeof u === "string" && u.trim();
  const hasC = typeof c === "string" && c.trim();
  return !hasU && !hasC;
}

function creatorFieldsPatchFromRecipe(r) {
  const patch = buildSavedRecipeMiniPatch(r);
  const out = {};
  if (patch.sourceUploader) out.sourceUploader = patch.sourceUploader;
  if (patch.sourceChannel) out.sourceChannel = patch.sourceChannel;
  return out;
}

async function runSaveCountBackfill(db) {
  let scanned = 0;
  let missingSaveCount = 0;
  let missingMonthlySaves = 0;
  let missingWeeklySaves = 0;
  let updated = 0;
  const stream = db
    .collection("recipes")
    .select("saveCount", "monthlySaves", "weeklySaves")
    .stream();
  let batch = db.batch();
  let batchCount = 0;
  const BATCH_LIMIT = 400;
  for await (const doc of stream) {
    scanned += 1;
    const data = doc.data() || {};
    const patch = {};
    if (data.saveCount === undefined || data.saveCount === null) {
      patch.saveCount = 0;
      missingSaveCount += 1;
    }
    if (data.monthlySaves === undefined || data.monthlySaves === null) {
      patch.monthlySaves = 0;
      missingMonthlySaves += 1;
    }
    if (data.weeklySaves === undefined || data.weeklySaves === null) {
      patch.weeklySaves = 0;
      missingWeeklySaves += 1;
    }
    if (Object.keys(patch).length === 0) continue;
    updated += 1;
    if (!dryRun) {
      batch.update(doc.ref, patch);
      batchCount += 1;
      if (batchCount >= BATCH_LIMIT) {
        await batch.commit();
        batch = db.batch();
        batchCount = 0;
      }
    }
  }
  if (!dryRun && batchCount > 0) await batch.commit();
  return {
    scanned,
    missingSaveCount,
    missingMonthlySaves,
    missingWeeklySaves,
    updated,
  };
}

function collectSavedAtMap(userData) {
  const savedAtMap =
    userData.savedAt && typeof userData.savedAt === "object"
      ? Object.assign({}, userData.savedAt)
      : {};
  for (const [k, v] of Object.entries(userData)) {
    if (k.startsWith("savedAt.") && v) savedAtMap[k.substring(8)] = v;
  }
  return savedAtMap;
}

async function backfillUserSavedRecipes(db, admin, uid, userData) {
  const savedRecipes = Array.isArray(userData.savedRecipes)
    ? userData.savedRecipes.filter((x) => typeof x === "string" && x)
    : [];
  if (!savedRecipes.length) {
    return {
      miniDocsCreated: 0,
      miniDocsUpdated: 0,
      miniDocsSkipped: 0,
      recipesMissing: 0,
      errors: 0,
    };
  }

  const savedAtMap = collectSavedAtMap(userData);
  let miniDocsCreated = 0;
  let miniDocsUpdated = 0;
  let miniDocsSkipped = 0;
  let recipesMissing = 0;
  let errors = 0;

  const CHUNK = 20;
  for (let i = 0; i < savedRecipes.length; i += CHUNK) {
    const chunk = savedRecipes.slice(i, i + CHUNK);
    const miniRefs = chunk.map((recipeId) =>
      db.collection("users").doc(uid).collection("savedRecipes").doc(recipeId)
    );

    let miniSnaps;
    try {
      miniSnaps = await db.getAll(...miniRefs);
    } catch (e) {
      errors += chunk.length;
      console.error(`[savedRecipes] uid=${uid} mini getAll failed:`, e.message || e);
      continue;
    }

    const missingRecipeIds = [];
    const creatorBackfillRecipeIds = [];
    for (let j = 0; j < chunk.length; j++) {
      const recipeId = chunk[j];
      if (!miniSnaps[j].exists) {
        missingRecipeIds.push(recipeId);
      } else if (miniDocNeedsCreatorBackfill(miniSnaps[j].data() || {})) {
        creatorBackfillRecipeIds.push(recipeId);
      } else {
        miniDocsSkipped += 1;
      }
    }

    const allRecipeIds = [
      ...new Set([...missingRecipeIds, ...creatorBackfillRecipeIds]),
    ];
    if (!allRecipeIds.length) continue;

    const recipeRefs = allRecipeIds.map((recipeId) =>
      db.collection("recipes").doc(recipeId)
    );
    let recipeSnaps;
    try {
      recipeSnaps = await db.getAll(...recipeRefs);
    } catch (e) {
      errors += allRecipeIds.length;
      console.error(`[savedRecipes] uid=${uid} recipe getAll failed:`, e.message || e);
      continue;
    }

    const recipeById = new Map();
    for (let j = 0; j < allRecipeIds.length; j++) {
      recipeById.set(allRecipeIds[j], recipeSnaps[j]);
    }

    let batch = db.batch();
    let batchCount = 0;
    const BATCH_LIMIT = 400;

    for (const recipeId of missingRecipeIds) {
      const recipeSnap = recipeById.get(recipeId);
      if (!recipeSnap || !recipeSnap.exists) {
        recipesMissing += 1;
        continue;
      }
      const r = recipeSnap.data() || {};
      const patch = buildSavedRecipeMiniPatch(r);
      const mini = Object.assign({}, patch, {
        recipeId,
        createdAt: r.createdAt || null,
        savedAt:
          savedAtMap[recipeId] ||
          r.createdAt ||
          admin.firestore.FieldValue.serverTimestamp(),
      });
      miniDocsCreated += 1;
      if (!dryRun) {
        const miniRef = db
          .collection("users")
          .doc(uid)
          .collection("savedRecipes")
          .doc(recipeId);
        batch.set(miniRef, mini);
        batchCount += 1;
        if (batchCount >= BATCH_LIMIT) {
          await batch.commit();
          batch = db.batch();
          batchCount = 0;
        }
      }
    }

    for (const recipeId of creatorBackfillRecipeIds) {
      const recipeSnap = recipeById.get(recipeId);
      if (!recipeSnap || !recipeSnap.exists) {
        recipesMissing += 1;
        continue;
      }
      const r = recipeSnap.data() || {};
      const creatorPatch = creatorFieldsPatchFromRecipe(r);
      if (!Object.keys(creatorPatch).length) {
        miniDocsSkipped += 1;
        continue;
      }
      miniDocsUpdated += 1;
      if (!dryRun) {
        const miniRef = db
          .collection("users")
          .doc(uid)
          .collection("savedRecipes")
          .doc(recipeId);
        batch.set(miniRef, creatorPatch, { merge: true });
        batchCount += 1;
        if (batchCount >= BATCH_LIMIT) {
          await batch.commit();
          batch = db.batch();
          batchCount = 0;
        }
      }
    }
    if (!dryRun && batchCount > 0) await batch.commit();
  }

  return { miniDocsCreated, miniDocsUpdated, miniDocsSkipped, recipesMissing, errors };
}

async function runSavedRecipesBackfill(db, admin) {
  let usersScanned = 0;
  let usersWithSavedRecipes = 0;
  let miniDocsCreated = 0;
  let miniDocsUpdated = 0;
  let miniDocsSkipped = 0;
  let recipesMissing = 0;
  let errors = 0;
  let lastUserId = startAfterUserId || null;

  if (userIdFilter) {
    const userDoc = await db.collection("users").doc(userIdFilter).get();
    if (!userDoc.exists) {
      throw new Error(`user not found: ${userIdFilter}`);
    }
    usersScanned = 1;
    const userData = userDoc.data() || {};
    const savedRecipes = Array.isArray(userData.savedRecipes)
      ? userData.savedRecipes.filter((x) => typeof x === "string" && x)
      : [];
    if (savedRecipes.length) usersWithSavedRecipes = 1;
    const result = await backfillUserSavedRecipes(
      db,
      admin,
      userDoc.id,
      userData
    );
    miniDocsCreated += result.miniDocsCreated;
    miniDocsUpdated += result.miniDocsUpdated;
    miniDocsSkipped += result.miniDocsSkipped;
    recipesMissing += result.recipesMissing;
    errors += result.errors;
    return {
      usersScanned,
      usersWithSavedRecipes,
      miniDocsCreated,
      miniDocsUpdated,
      miniDocsSkipped,
      recipesMissing,
      errors,
      lastUserId: userDoc.id,
    };
  }

  // users 전체 stream 은 gRPC 300s 에 걸릴 수 있어 페이지 단위로 처리한다.
  while (true) {
    let query = db
      .collection("users")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(USER_PAGE_SIZE);
    if (lastUserId) {
      query = query.startAfter(lastUserId);
    }

    const page = await query.get();
    if (page.empty) break;

    for (const userDoc of page.docs) {
      usersScanned += 1;
      lastUserId = userDoc.id;
      const userData = userDoc.data() || {};
      const savedRecipes = Array.isArray(userData.savedRecipes)
        ? userData.savedRecipes.filter((x) => typeof x === "string" && x)
        : [];
      if (!savedRecipes.length) continue;

      usersWithSavedRecipes += 1;
      const result = await backfillUserSavedRecipes(
        db,
        admin,
        userDoc.id,
        userData
      );
      miniDocsCreated += result.miniDocsCreated;
      miniDocsUpdated += result.miniDocsUpdated;
      miniDocsSkipped += result.miniDocsSkipped;
      recipesMissing += result.recipesMissing;
      errors += result.errors;
    }

    console.log(
      `[savedRecipes] progress: usersScanned=${usersScanned} ` +
        `withSaved=${usersWithSavedRecipes} created=${miniDocsCreated} ` +
        `updated=${miniDocsUpdated} skipped=${miniDocsSkipped} lastUserId=${lastUserId}`
    );

    if (page.size < USER_PAGE_SIZE) break;
  }

  return {
    usersScanned,
    usersWithSavedRecipes,
    miniDocsCreated,
    miniDocsUpdated,
    miniDocsSkipped,
    recipesMissing,
    errors,
    lastUserId,
    resumeHint: lastUserId
      ? `node tools/run_optimization_backfills.js --task=savedRecipes --start-after-user-id=${lastUserId}`
      : null,
  };
}

(async () => {
  const serviceAccount = getServiceAccount();
  const admin = require("firebase-admin");
  if (admin.apps.length === 0) {
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
      projectId: serviceAccount.project_id,
    });
  }
  const db = admin.firestore();
  console.log("[backfill] config:", {
    task,
    dryRun,
    userIdFilter,
    startAfterUserId,
    userPageSize: USER_PAGE_SIZE,
    projectId: serviceAccount.project_id,
  });
  const startedAt = Date.now();
  let result;
  if (task === "saveCount") {
    result = await runSaveCountBackfill(db);
  } else {
    result = await runSavedRecipesBackfill(db, admin);
  }
  const elapsedSec = ((Date.now() - startedAt) / 1000).toFixed(1);
  console.log(`[backfill] DONE in ${elapsedSec}s`);
  console.log(JSON.stringify(result, null, 2));
  process.exit(0);
})().catch((e) => {
  console.error("[backfill] FAILED:", e && e.stack ? e.stack : e);
  process.exit(1);
});
