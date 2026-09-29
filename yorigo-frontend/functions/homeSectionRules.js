/**
 * 홈 트렌드 섹션 필터 규칙 — functions/data/home_section_rules.json 단일 진실.
 * Dart _filterForSection 과 동일한 판정을 CF/backfill 에서 재사용한다.
 */

const JSON_SECTION_RULES = require("./data/home_section_rules.json");

/** JSON 폴백. 테스트/구버전 호환 export. */
const SECTION_RULES = JSON_SECTION_RULES;

const CMS_RULES_TTL_MS = 5 * 60 * 1000;
/** @type {Record<string, object>|null} */
let _cmsRules = null;
let _cmsRulesAt = 0;

function getSectionRules() {
  if (_cmsRules && Date.now() - _cmsRulesAt < CMS_RULES_TTL_MS) {
    return _cmsRules;
  }
  return _cmsRules || JSON_SECTION_RULES;
}

function hasMatchRules(matchRules) {
  if (!matchRules || typeof matchRules !== "object") return false;
  const keys = [
    "anyTags",
    "titleKeywords",
    "sourceKeywords",
    "menuTypes",
    "timeMaxMinutes",
    "maxIngredients",
    "proteinMin",
    "fatMax",
    "caloriesMax",
  ];
  return keys.some((k) => {
    const v = matchRules[k];
    if (Array.isArray(v)) return v.length > 0;
    return v != null && v !== "";
  });
}

/**
 * Firestore `home_cms_sections` 의 matchRules 를 읽어 활성 규칙 캐시를 갱신.
 * 문서가 없거나 실패하면 JSON 폴백.
 * @param {FirebaseFirestore.Firestore} db
 */
async function refreshCmsSectionRules(db) {
  try {
    const snap = await db.collection("home_cms_sections").get();
    if (!snap.empty) {
      const merged = { ...JSON_SECTION_RULES };
      snap.forEach((doc) => {
        const data = doc.data() || {};
        if (data.enabled === false) {
          delete merged[doc.id];
          return;
        }
        if (hasMatchRules(data.matchRules)) {
          merged[doc.id] = data.matchRules;
        }
      });
      _cmsRules = merged;
      _cmsRulesAt = Date.now();
      return _cmsRules;
    }
  } catch (e) {
    console.error("[homeSectionRules] cms load failed:", e);
  }
  _cmsRules = JSON_SECTION_RULES;
  _cmsRulesAt = Date.now();
  return _cmsRules;
}

function invalidateCmsSectionRules() {
  _cmsRules = null;
  _cmsRulesAt = 0;
}

function isManualIndexKey(sectionKey) {
  const key = _sanitizeText(sectionKey);
  if (!key) return true;
  if (key.startsWith("poster_")) return true;
  return !getSectionRules()[key];
}

function _sanitizeText(v) {
  return (v || "").toString().trim();
}

function _recipeTitle(data) {
  if (!data || typeof data !== "object") return "";
  const nested = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  return _sanitizeText(nested.title || data.title || nested.name || data.name);
}

/**
 * sourceKeywords 매칭용 텍스트.
 * 출처 필드 + 레시피 제목 + URL 까지 넉넉히 본다 (클라 ProgramSectionKeywords 와 동일).
 */
function _sourceText(data) {
  if (!data || typeof data !== "object") return "";
  const source = data.source && typeof data.source === "object" ? data.source : {};
  const nested = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  return [
    source.title,
    source.uploader,
    source.channel,
    data.uploader,
    data.channel,
    nested.title || data.title || nested.name || data.name,
    data.sourceUrl || source.url || source.sourceUrl,
  ]
    .map((value) => _sanitizeText(value))
    .filter((value) => !!value)
    .join(" ");
}

function _platformOf(data) {
  const src = data && data.source;
  if (src && typeof src === "object") {
    return _sanitizeText(src.platform).toLowerCase();
  }
  return "";
}

function _llmEstimate(data) {
  const nutrition = data && data.nutrition;
  if (!nutrition || typeof nutrition !== "object") return null;
  const est = nutrition.llm_estimate;
  return est && typeof est === "object" ? est : null;
}

function _numAsDouble(v) {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number.parseFloat(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function _getTotalMinutes(data) {
  const nested = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  const steps = nested.steps;
  if (!Array.isArray(steps)) return 0;
  let total = 0;
  for (const step of steps) {
    if (!step || typeof step !== "object") continue;
    const m = _numAsDouble(step.est_minutes);
    if (m != null && m > 0) total += m;
  }
  return total;
}

function _ingredientCount(data) {
  const nested = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  const ingredients = nested.ingredients;
  return Array.isArray(ingredients) ? ingredients.length : 0;
}

function _normalizeTagToken(raw) {
  return _sanitizeText(raw).replace(/[\u200B-\u200D\uFEFF]/g, "");
}

function _tagListsFromRecipe(data) {
  const nested = data && data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  const source = data && data.source && typeof data.source === "object" ? data.source : {};
  return [data && data.tags, data && data.occasionTags, nested.tags, nested.occasionTags, source.tags, source.occasionTags];
}

function _matchesAnyTag(data, allowed) {
  const allowedSet = new Set(allowed.map((t) => _normalizeTagToken(t).toLowerCase()));
  for (const raw of _tagListsFromRecipe(data)) {
    if (!Array.isArray(raw)) continue;
    for (const t of raw) {
      const token = _normalizeTagToken(t).toLowerCase();
      if (token && allowedSet.has(token)) return true;
    }
  }
  return false;
}

function _matchesTitleKeyword(data, keywords) {
  const title = _recipeTitle(data).toLowerCase();
  if (!title) return false;
  for (const k of keywords) {
    if (k && title.includes(String(k).toLowerCase())) return true;
  }
  return false;
}

function _matchesSourceKeyword(data, keywords) {
  const sourceText = _sourceText(data).toLowerCase();
  if (!sourceText) return false;
  for (const k of keywords) {
    if (k && sourceText.includes(String(k).toLowerCase())) return true;
  }
  return false;
}

function _matchesAnyCategoryValue(data, keys, allowed) {
  const categories = data.categories;
  if (!categories || typeof categories !== "object") return false;
  const allowedLower = allowed.map((a) => String(a).toLowerCase());
  for (const key of keys) {
    const val = categories[key];
    if (val == null) continue;
    const values = Array.isArray(val) ? val : [val];
    for (const v of values) {
      const s = String(v).toLowerCase();
      if (allowedLower.some((a) => s.includes(a) || a.includes(s))) return true;
    }
  }
  return false;
}

function _isSectionActive(rule) {
  const until = rule.activeUntil;
  if (!until) return true;
  const end = new Date(`${until}T23:59:59+09:00`);
  return Number.isFinite(end.getTime()) && Date.now() <= end.getTime();
}

function _matchesSectionRule(data, rule) {
  if (!_isSectionActive(rule)) return false;

  const platform = _platformOf(data);
  if (Array.isArray(rule.excludePlatforms) && rule.excludePlatforms.includes(platform)) {
    return false;
  }
  if (rule.platformFilter && platform !== rule.platformFilter) return false;

  if (rule.timeMaxMinutes != null && _getTotalMinutes(data) > rule.timeMaxMinutes) {
    return false;
  }
  if (rule.proteinMin != null) {
    const protein = _numAsDouble(_llmEstimate(data)?.protein_g);
    if (protein == null || protein < rule.proteinMin) return false;
  }
  if (rule.fatMax != null) {
    const fat = _numAsDouble(_llmEstimate(data)?.fat_g);
    if (fat == null || fat > rule.fatMax) return false;
  }
  if (rule.maxIngredients != null && _ingredientCount(data) > rule.maxIngredients) {
    return false;
  }
  if (rule.menuTypes != null && !_matchesAnyCategoryValue(data, ["menu_type"], rule.menuTypes)) {
    return false;
  }

  const hasTagFilter = Array.isArray(rule.anyTags) && rule.anyTags.length > 0;
  const hasTitleFilter = Array.isArray(rule.titleKeywords) && rule.titleKeywords.length > 0;
  const hasSourceFilter =
    Array.isArray(rule.sourceKeywords) && rule.sourceKeywords.length > 0;
  if (hasTagFilter || hasTitleFilter || hasSourceFilter) {
    const tagOk = hasTagFilter && _matchesAnyTag(data, rule.anyTags);
    const titleOk = hasTitleFilter && _matchesTitleKeyword(data, rule.titleKeywords);
    const sourceOk =
      hasSourceFilter && _matchesSourceKeyword(data, rule.sourceKeywords);
    if (!tagOk && !titleOk && !sourceOk) return false;
  }

  if (
    Array.isArray(rule.excludeTitleKeywords) &&
    rule.excludeTitleKeywords.length > 0 &&
    _matchesTitleKeyword(data, rule.excludeTitleKeywords)
  ) {
    return false;
  }

  return true;
}

/** recipe 가 속하는 home_section_index 키 목록 */
function matchedHomeSectionKeys(data) {
  if (!data || typeof data !== "object") return [];
  const keys = [];
  for (const [sectionKey, rule] of Object.entries(getSectionRules())) {
    if (_matchesSectionRule(data, rule)) keys.push(sectionKey);
  }
  return keys;
}

/** 단일 섹션 규칙 매칭 */
function matchesSectionRuleForKey(data, sectionKey) {
  const rule = getSectionRules()[sectionKey];
  if (!rule) return false;
  return _matchesSectionRule(data, rule);
}

function sectionLimit(sectionKey) {
  const rule = getSectionRules()[sectionKey];
  if (!rule) return 60;
  return typeof rule.limit === "number" ? rule.limit : 60;
}

function sectionSortBy(sectionKey) {
  const rule = getSectionRules()[sectionKey];
  if (!rule) return "parsedAtDesc";
  return rule.sortBy || "parsedAtDesc";
}

module.exports = {
  SECTION_RULES,
  getSectionRules,
  refreshCmsSectionRules,
  invalidateCmsSectionRules,
  isManualIndexKey,
  hasMatchRules,
  matchedHomeSectionKeys,
  matchesSectionRuleForKey,
  sectionLimit,
  sectionSortBy,
};
