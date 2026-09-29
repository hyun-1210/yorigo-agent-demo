#!/usr/bin/env node
"use strict";

/**
 * 핫한 레시피 묶음 현황 점검 (read-only).
 *
 * Usage:
 *   cd yorigo-frontend/functions
 *   node tools/inspect_recipe_groups.js
 *
 * 출력:
 *  - 전체 그룹 / eligible(>=5) 그룹 개수
 *  - count 분포 히스토그램
 *  - eligible 그룹 상위 30개 (recentCount desc, count desc)
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

function bucketLabel(count, minSize) {
  const elig = (n) => (n >= minSize ? " (eligible)" : "");
  if (count <= 0) return "0";
  if (count === 1) return "1" + elig(1);
  if (count === 2) return "2" + elig(2);
  if (count === 3) return "3" + elig(3);
  if (count === 4) return "4" + elig(4);
  if (count <= 9) return "5-9" + elig(5);
  if (count <= 19) return "10-19" + elig(10);
  if (count <= 49) return "20-49" + elig(20);
  return "50+ (eligible)";
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
  const { MIN_GROUP_SIZE } = require("../recipeGroupConfig");

  console.log("[inspect] project:", serviceAccount.project_id);
  console.log("[inspect] MIN_GROUP_SIZE =", MIN_GROUP_SIZE);
  console.log("[inspect] reading recipe_groups ...");

  const snap = await db.collection("recipe_groups").get();
  const groups = snap.docs.map((d) => ({ id: d.id, ...d.data() }));

  const total = groups.length;
  const eligible = groups.filter((g) => g.eligible === true);
  const ineligible = groups.filter((g) => g.eligible !== true);

  // ---- distribution ----------------------------------------------------------
  const buckets = new Map();
  for (const g of groups) {
    const label = bucketLabel(g.count || 0, MIN_GROUP_SIZE);
    buckets.set(label, (buckets.get(label) || 0) + 1);
  }
  const elig = (n) => (n >= MIN_GROUP_SIZE ? " (eligible)" : "");
  const bucketOrder = [
    "0",
    "1" + elig(1),
    "2" + elig(2),
    "3" + elig(3),
    "4" + elig(4),
    "5-9" + elig(5),
    "10-19" + elig(10),
    "20-49" + elig(20),
    "50+ (eligible)",
  ];

  console.log("\n=== summary ===");
  console.log(`total groups                  : ${total}`);
  console.log(`eligible (count>=${MIN_GROUP_SIZE})           : ${eligible.length}`);
  console.log(`below threshold               : ${ineligible.length}`);

  console.log("\n=== count distribution ===");
  for (const label of bucketOrder) {
    const n = buckets.get(label) || 0;
    if (n === 0) continue;
    const bar = "#".repeat(Math.min(40, n));
    console.log(`  ${label.padEnd(28)} | ${String(n).padStart(4)} ${bar}`);
  }

  // ---- top eligible groups ---------------------------------------------------
  eligible.sort((a, b) => {
    const r = (b.recentCount || 0) - (a.recentCount || 0);
    if (r !== 0) return r;
    return (b.count || 0) - (a.count || 0);
  });

  console.log("\n=== top eligible groups (recentCount desc, count desc) ===");
  console.log(
    "  rank | recent | count | name".padEnd(60) + " | groupKey"
  );
  console.log("  " + "-".repeat(78));
  const topN = Math.min(30, eligible.length);
  for (let i = 0; i < topN; i++) {
    const g = eligible[i];
    const rank = String(i + 1).padStart(4);
    const recent = String(g.recentCount || 0).padStart(6);
    const cnt = String(g.count || 0).padStart(5);
    const name = String(g.name || "(no name)").padEnd(20);
    console.log(
      `  ${rank} | ${recent} | ${cnt} | ${name} | ${g.groupKey || g.id}`
    );
  }

  if (eligible.length === 0) {
    console.log(
      "\n[inspect] WARNING: 5개 이상 묶음이 0개입니다. 백필이 제대로 돌았는지, " +
        "MIN_GROUP_SIZE 가 맞는지 확인하세요."
    );
  }

  process.exit(0);
})().catch((e) => {
  console.error("[inspect] FAILED:", e && e.stack ? e.stack : e);
  process.exit(1);
});
