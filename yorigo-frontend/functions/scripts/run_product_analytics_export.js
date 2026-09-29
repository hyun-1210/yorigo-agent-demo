#!/usr/bin/env node

/* eslint-disable no-console */
async function main() {
  try {
    const { runProductAnalyticsExport } = require("../index");
    if (typeof runProductAnalyticsExport !== "function") {
      throw new Error("runProductAnalyticsExport is not available");
    }
    const result = await runProductAnalyticsExport();
    console.log(
      `[LocalRunner][product_analytics] Completed export for ${result?.count ?? 0} events.`
    );
  } catch (e) {
    console.error("[LocalRunner][product_analytics] Failed:", e);
    process.exitCode = 1;
  }
}

main();
