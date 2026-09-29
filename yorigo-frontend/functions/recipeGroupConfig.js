"use strict";

// Group must contain at least this many recipes to be surfaced in the UI.
const MIN_GROUP_SIZE = 3;

// Recipes parsed within this many days count toward `recentCount`.
const RECENT_DAYS = 3;

// Cap on how many groups the scheduled refresh / list reads consider at once.
const GROUP_QUERY_LIMIT = 200;

// Backfill page size when scanning the recipes collection.
const BACKFILL_PAGE_SIZE = 300;

// Max characters of `title` we send to LLM. Avoids wasting tokens on captions.
const TITLE_LLM_MAX_CHARS = 120;

// Max length of a canonicalDish key. Longer extracts are rejected to avoid
// degenerate single-recipe groups.
const CANONICAL_MAX_CHARS = 24;

module.exports = {
  MIN_GROUP_SIZE,
  RECENT_DAYS,
  GROUP_QUERY_LIMIT,
  BACKFILL_PAGE_SIZE,
  TITLE_LLM_MAX_CHARS,
  CANONICAL_MAX_CHARS,
};
