/**
 * Production Firestore에 program_* home_section_index 단일 패스 rebuild.
 *
 * 사용:
 *   node scripts/run_rebuild_programs.js --sa ../../backend/firebase-service-account.json --dry-run
 *   node scripts/run_rebuild_programs.js --sa ../../backend/firebase-service-account.json
 */
const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");
const { rebuildProgramHomeSectionIndexes } = require("../homeSectionIndex");

function parseArgs(argv) {
  const out = { sa: null, dryRun: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--dry-run") out.dryRun = true;
    else if (a === "--sa") out.sa = argv[++i];
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.sa) {
    console.error("Usage: node scripts/run_rebuild_programs.js --sa <sa.json> [--dry-run]");
    process.exit(2);
  }
  const saPath = path.resolve(args.sa);
  if (!fs.existsSync(saPath)) {
    console.error("SA missing:", saPath);
    process.exit(2);
  }
  const sa = JSON.parse(fs.readFileSync(saPath, "utf8"));
  if (!admin.apps.length) {
    admin.initializeApp({
      credential: admin.credential.cert(sa),
      projectId: sa.project_id,
    });
  }
  const db = admin.firestore();
  console.log(
    JSON.stringify(
      {
        projectId: sa.project_id,
        dryRun: args.dryRun,
        startedAt: new Date().toISOString(),
      },
      null,
      2
    )
  );

  const started = Date.now();
  const result = await rebuildProgramHomeSectionIndexes(db, { dryRun: args.dryRun });
  const elapsedMs = Date.now() - started;
  console.log(
    JSON.stringify(
      {
        ok: true,
        elapsedMs,
        ...result,
      },
      null,
      2
    )
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
