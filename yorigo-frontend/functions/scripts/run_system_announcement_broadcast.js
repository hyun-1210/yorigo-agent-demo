#!/usr/bin/env node
"use strict";

/**
 * 전체 사용자 시스템 공지(푸시 + 인앱 알림함) 1회 발송.
 *
 * Usage:
 *   cd yorigo-frontend/functions
 *   node scripts/run_system_announcement_broadcast.js app_reinstall_2026_07
 *   node scripts/run_system_announcement_broadcast.js app_reinstall_2026_07 --dry-run
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

const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const dryRun = process.argv.includes("--dry-run");
const campaignId = args[0] || "app_reinstall_2026_07";

const {
  getSystemBroadcast,
  listSystemBroadcastCampaignIds,
} = require("../systemBroadcasts");
const { runSystemAnnouncementBroadcast } = require("../systemAnnouncementRunner");

(async () => {
  const config = getSystemBroadcast(campaignId);
  if (!config) {
    console.error(
      `[broadcast] Unknown campaign: ${campaignId}. Available: ${listSystemBroadcastCampaignIds().join(", ")}`
    );
    process.exitCode = 1;
    return;
  }

  console.log("[broadcast] campaign:", config);
  if (dryRun) {
    console.log("[broadcast] dry-run only — no messages sent.");
    return;
  }

  const serviceAccount = getServiceAccount();
  const admin = require("firebase-admin");
  if (admin.apps.length === 0) {
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
      projectId: serviceAccount.project_id,
    });
  }

  const db = admin.firestore();
  const startedAt = Date.now();
  const result = await runSystemAnnouncementBroadcast(
    db,
    admin.messaging(),
    admin.firestore.FieldValue,
    campaignId
  );
  const elapsedSec = ((Date.now() - startedAt) / 1000).toFixed(1);

  console.log(`[broadcast] DONE in ${elapsedSec}s`);
  console.log(JSON.stringify(result, null, 2));
})().catch((e) => {
  console.error("[broadcast] Failed:", e);
  process.exitCode = 1;
});
