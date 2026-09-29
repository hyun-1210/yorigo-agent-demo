#!/usr/bin/env node
"use strict";

/**
 * 핫한 레시피 묶음 백필 — 로컬 실행 (1회성).
 *
 * Usage:
 *   cd yorigo-frontend/functions
 *   node tools/run_backfill_local.js [--dry-run] [--no-llm] [--max=N]
 *
 * --dry-run   : 카운트만 집계, Firestore 에 쓰지 않음 (상위 20개 묶음 미리보기)
 * --no-llm    : 사전/규칙만 사용 (Gemini 호출 0회, 비용 0원)
 * --max=N     : 최대 N개 레시피만 스캔 (스모크 테스트용)
 *
 * 환경변수:
 *   GEMINI_API_KEY                  → functions/.env.yorigo-f7408 에서 자동 로딩
 *   FIREBASE_SERVICE_ACCOUNT_JSON   → backend/.env 에서 자동 로딩
 *                                     (값이 '{' 로 시작하면 JSON 자체로,
 *                                      아니면 파일 경로로 해석)
 */

const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const FUNCTIONS_DIR = path.resolve(HERE, "..");
const FRONTEND_DIR = path.resolve(FUNCTIONS_DIR, "..");
const REPO_ROOT = path.resolve(FRONTEND_DIR, "..");
const BACKEND_DIR = path.resolve(REPO_ROOT, "backend");

// ---- minimal .env loader (no dotenv dependency) -----------------------------
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

// ---- service account resolution --------------------------------------------
function getServiceAccount() {
  const env = (process.env.FIREBASE_SERVICE_ACCOUNT_JSON || "").trim();
  if (env) {
    if (env.startsWith("{")) {
      return JSON.parse(env);
    }
    const candidates = [
      env,
      path.resolve(process.cwd(), env),
      path.resolve(BACKEND_DIR, env),
    ];
    for (const p of candidates) {
      if (fs.existsSync(p)) {
        return JSON.parse(fs.readFileSync(p, "utf8"));
      }
    }
  }
  const fallback = path.join(BACKEND_DIR, "firebase-service-account.json");
  if (fs.existsSync(fallback)) {
    return JSON.parse(fs.readFileSync(fallback, "utf8"));
  }
  throw new Error(
    "Service account not found. Set FIREBASE_SERVICE_ACCOUNT_JSON or place file at backend/firebase-service-account.json"
  );
}

// ---- main -------------------------------------------------------------------
const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const useLlm = !args.includes("--no-llm");
const maxArg = args.find((a) => a.startsWith("--max="));
const maxRecipes = maxArg
  ? Number.parseInt(maxArg.slice("--max=".length), 10)
  : 0;

(async () => {
  const serviceAccount = getServiceAccount();
  const projectId = serviceAccount.project_id;

  console.log("[backfill] config:", {
    projectId,
    dryRun,
    useLlm,
    maxRecipes: maxRecipes || "(no limit)",
    geminiKey: process.env.GEMINI_API_KEY ? "SET" : "MISSING",
  });

  if (useLlm && !process.env.GEMINI_API_KEY) {
    console.warn(
      "[backfill] WARNING: --no-llm 안 줬는데 GEMINI_API_KEY 가 비어있음. " +
        "사전 매칭 실패한 레시피는 그루핑 안 됨."
    );
  }

  const admin = require("firebase-admin");
  if (admin.apps.length === 0) {
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
      projectId,
    });
  }

  const recipeGroups = require("../recipeGroups");
  const startedAt = Date.now();
  const result = await recipeGroups.backfillAllGroups({
    dryRun,
    useLlm,
    maxRecipes,
  });
  const elapsedSec = ((Date.now() - startedAt) / 1000).toFixed(1);

  console.log("[backfill] DONE in", elapsedSec, "s");
  console.log(JSON.stringify(result, null, 2));

  if (!dryRun) {
    console.log(
      "\n다음 단계: Firebase Console → Firestore → recipe_groups 컬렉션 확인. " +
        "count >= 5 인 묶음들이 보여야 함."
    );
  }
  process.exit(0);
})().catch((e) => {
  console.error("[backfill] FAILED:", e && e.stack ? e.stack : e);
  process.exit(1);
});
