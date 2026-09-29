#!/usr/bin/env node

/* eslint-disable no-console */
async function main() {
  try {
    const { runUserAnalyticsExport } = require("../index");
    if (typeof runUserAnalyticsExport !== "function") {
      throw new Error("runUserAnalyticsExport is not available");
    }
    const result = await runUserAnalyticsExport();
    console.log(
      `[LocalRunner][user_analytics] Completed export for ${result?.count ?? 0} users.`
    );
  } catch (e) {
    console.error("[LocalRunner][user_analytics] Failed:", e);
    process.exitCode = 1;
  }
}

main();
