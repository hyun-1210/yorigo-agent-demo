#!/usr/bin/env node

/* eslint-disable no-console */
async function main() {
  try {
    const { runRecipeAnalyticsExport } = require("../index");
    if (typeof runRecipeAnalyticsExport !== "function") {
      throw new Error("runRecipeAnalyticsExport is not available");
    }
    const result = await runRecipeAnalyticsExport();
    console.log(
      `[LocalRunner][recipe_analytics] Completed export for ${result?.count ?? 0} recipes.`
    );
  } catch (e) {
    console.error("[LocalRunner][recipe_analytics] Failed:", e);
    process.exitCode = 1;
  }
}

main();
