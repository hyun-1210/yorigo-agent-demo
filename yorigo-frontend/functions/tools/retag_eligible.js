#!/usr/bin/env node
"use strict";

/**
 * MIN_GROUP_SIZE 가 바뀌었을 때 기존 recipe_groups 도큐먼트의 `eligible`
 * 필드만 빠르게 재계산. 캔노니컬라이즈 / 카운팅 / Gemini 호출 안 함.
 *
 * Usage:
 *   cd yorigo-frontend/functions
 *   node tools/retag_eligible.js [--dry-run]
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
  if (fs.existsSync(fallback)) {
    return JSON.parse(fs.readFileSync(fallback, "utf8"));
  }
  throw new Error(
    "Service account not found. Set FIREBASE_SERVICE_ACCOUNT_JSON or place file at backend/firebase-service-account.json"
  );
}

const dryRun = process.argv.includes("--dry-run");

(async () => {
  const { MIN_GROUP_SIZE } = require("../recipeGroupConfig");
  const serviceAccount = getServiceAccount();
  const admin = require("firebase-admin");
  if (admin.apps.length === 0) {
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
      projectId: serviceAccount.project_id,
    });
  }
  const db = admin.firestore();

  console.log("[retag] project:", serviceAccount.project_id);
  console.log("[retag] MIN_GROUP_SIZE =", MIN_GROUP_SIZE);
  console.log("[retag] dryRun =", dryRun);

  const snap = await db.collection("recipe_groups").get();
  let scanned = 0;
  let toFlip = 0;
  let promoted = 0;
  let demoted = 0;

  let batch = db.batch();
  let batchCount = 0;
  let written = 0;

  for (const doc of snap.docs) {
    scanned += 1;
    const cur = doc.data() || {};
    const count = Number.isFinite(cur.count) ? cur.count : 0;
    const desired = count >= MIN_GROUP_SIZE;
    const before = cur.eligible === true;
    if (desired === before) continue;

    toFlip += 1;
    if (desired && !before) promoted += 1;
    if (!desired && before) demoted += 1;

    if (!dryRun) {
      batch.set(
        doc.ref,
        {
          eligible: desired,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      batchCount += 1;
      written += 1;
      if (batchCount >= 400) {
        await batch.commit();
        batch = db.batch();
        batchCount = 0;
      }
    }
  }
  if (!dryRun && batchCount > 0) await batch.commit();

  console.log("[retag] DONE");
  console.log(
    JSON.stringify(
      {
        scanned,
        toFlip,
        promoted,
        demoted,
        written,
        dryRun,
      },
      null,
      2
    )
  );

  process.exit(0);
})().catch((e) => {
  console.error("[retag] FAILED:", e && e.stack ? e.stack : e);
  process.exit(1);
});
