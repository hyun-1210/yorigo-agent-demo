"use strict";

/**
 * Canonical Korean dish-name extraction for recipe titles.
 *
 * Hybrid strategy:
 *   1) Rule/dictionary pass — strip noise/modifier tokens, then look for
 *      the longest matching base-dish keyword.
 *   2) Cache lookup in `recipe_group_aliases/{titleHash}`.
 *   3) LLM fallback — Google Gemini `generateContent` (JSON response mode).
 *
 * The result is a short Korean dish name like "김치찌개" or null if nothing
 * confident could be extracted (recipe is then excluded from grouping).
 *
 * Env vars:
 *   - GEMINI_API_KEY                 (required for LLM fallback)
 *   - RECIPE_CANONICAL_MODEL         (default: "gemini-2.5-flash")
 *   - RECIPE_CANONICAL_TIMEOUT_MS    (default: 8000)
 *
 * Used by:
 *   - `onRecipeWriteUpdateGroup` (incremental)
 *   - `refreshRecipeGroupCounts` (scheduled)
 *   - `backfillRecipeGroups`     (one-shot HTTP)
 */

const crypto = require("crypto");
const admin = require("firebase-admin");
const {
  TITLE_LLM_MAX_CHARS,
  CANONICAL_MAX_CHARS,
} = require("./recipeGroupConfig");
const { trackMixpanelEvent } = require("./mixpanelTracking");

// Cloud Functions 배치/트리거 호출은 특정 사용자 요청이 아니므로 고정 distinct_id 사용.
const _MIXPANEL_SYSTEM_DISTINCT_ID = "system_recipe_canonicalize";

// ---------------------------------------------------------------------------
// Dictionary
// ---------------------------------------------------------------------------

// Base dish names. Order does not matter; we sort by length-desc internally
// so longer matches win ("김치볶음밥" before "볶음밥").
const BASE_DISHES = [
  // 찌개/탕/국
  "김치찌개", "된장찌개", "순두부찌개", "부대찌개", "청국장찌개",
  "동태찌개", "꽃게탕", "갈비탕", "설렁탕", "곰탕", "삼계탕", "추어탕",
  "감자탕", "해장국", "선지해장국", "콩나물국", "콩나물국밥", "북엇국",
  "미역국", "떡국", "만둣국", "곰국", "육개장", "사골국", "어묵국",
  "오뎅탕", "매운탕", "닭볶음탕", "닭개장",
  // 볶음/구이/조림
  "제육볶음", "두루치기", "오징어볶음", "낙지볶음", "주꾸미볶음", "쭈꾸미볶음",
  "닭갈비", "춘천닭갈비", "찜닭", "안동찜닭", "닭한마리", "닭도리탕",
  "닭볶음", "불고기", "소불고기", "돼지불고기", "오삼불고기",
  "갈비찜", "소갈비찜", "돼지갈비찜", "갈비구이", "삼겹살", "오겹살",
  "목살구이", "고등어구이", "고등어조림", "갈치조림", "갈치구이",
  "장조림", "감자조림", "콩조림", "메추리알장조림",
  // 면/밥
  "비빔국수", "잔치국수", "칼국수", "바지락칼국수", "수제비",
  "비빔밥", "전주비빔밥", "돌솥비빔밥", "콩나물밥", "무밥", "굴밥",
  "김밥", "참치김밥", "충무김밥", "주먹밥", "유부초밥",
  "김치볶음밥", "새우볶음밥", "베이컨볶음밥", "잡채밥", "오므라이스",
  "카레라이스", "카레", "하이라이스", "리조또", "리조토", "필라프",
  "스파게티", "파스타", "알리오올리오", "까르보나라", "봉골레",
  "토마토파스타", "크림파스타", "로제파스타", "라구파스타", "오일파스타",
  "라면", "짜장라면", "비빔라면", "비빔면", "막국수", "냉면", "물냉면", "비빔냉면",
  "쫄면", "우동", "라멘", "쌀국수", "팟타이",
  // 분식/길거리
  "떡볶이", "국물떡볶이", "로제떡볶이", "치즈떡볶이", "기름떡볶이",
  "튀김", "오징어튀김", "새우튀김", "감자튀김", "치킨", "후라이드치킨",
  "양념치킨", "간장치킨", "마늘치킨", "파닭", "닭강정", "닭꼬치",
  "순대", "순대국", "순대국밥", "어묵", "오뎅",
  // 전/부침
  "감자전", "김치전", "파전", "해물파전", "녹두전", "부추전", "동그랑땡",
  "배추전", "호박전", "두부부침", "두부조림",
  // 잡채/나물/반찬
  "잡채", "콩나물무침", "시금치나물", "도라지무침", "오이무침", "무생채",
  "깍두기", "오이소박이", "겉절이", "배추김치", "총각김치",
  // 죽
  "전복죽", "호박죽", "팥죽", "닭죽", "흰죽", "깨죽", "야채죽", "참치죽",
  // 양식/일식/중식 한국식
  "돈까스", "돈가스", "치즈돈까스", "왕돈까스", "함박스테이크", "함박스택",
  "오므라이스", "그라탕", "그라탱", "리조또",
  "초밥", "스시", "회덮밥", "연어덮밥", "참치덮밥", "장어덮밥", "규동",
  "짜장면", "짬뽕", "탕수육", "마라탕", "마라샹궈", "양꼬치",
  "마파두부", "마라두부", "팔보채",
  // 디저트/베이킹
  "마들렌", "휘낭시에", "쿠키", "스콘", "브라우니", "마카롱",
  "치즈케이크", "초코케이크", "당근케이크", "티라미수", "푸딩",
  "크로플", "와플", "팬케이크", "도넛", "도너츠", "베이글",
  "식빵", "버터바", "약과", "꿀떡", "송편",
  // 음료
  "라떼", "아메리카노", "에이드", "스무디", "쉐이크", "수정과", "식혜",
  // 한 단어 음식 (자주 등장)
  "김치", "된장", "고추장", "비빔", "전골", "전복", "탕수",
];

// Modifier / noise tokens to strip before matching. Order doesn't matter.
const MODIFIER_TOKENS = [
  // 부재료/단백질 수식어
  "돼지", "소고기", "쇠고기", "닭", "닭고기", "참치", "꽁치", "고등어",
  "오징어", "낙지", "주꾸미", "쭈꾸미", "새우", "조개", "해물", "해산물",
  "달걀", "계란", "두부", "치즈", "감자", "고구마", "버섯", "양배추",
  "양파", "대파", "쪽파", "마늘", "고추", "베이컨", "햄", "참기름",
  // 스타일/평가 수식어
  "간단", "초간단", "찐", "진짜", "진짜진짜", "정통", "오리지널",
  "황금", "황금레시피", "꿀", "꿀맛", "기본", "정석", "원조", "엄마표",
  "할머니표", "이모표", "아빠표", "집밥", "자취", "자취생", "혼밥",
  "1인", "일인", "이인", "가족", "캠핑", "다이어트", "비건", "건강",
  "고급", "고급진", "근본", "리얼", "최강", "최고", "최애",
  // 셰프/유튜버 이름
  "백종원", "이연복", "정호영", "임지호", "최현석", "이혜정", "강레오",
  "박준우", "쉽게따라하는", "쉽게", "따라하기", "따라하는",
  // 매운맛 수식어
  "매운", "매콤", "매콤한", "안매운", "순한", "달콤", "달콤한", "고소한", "담백한",
  // 조리 수식어
  "에어프라이어", "에프", "전자레인지", "전레", "오븐", "후라이팬", "프라이팬",
  "압력솥", "냄비", "노오븐", "노밀가루", "노버터", "노에그",
  // 시간 수식어
  "10분", "5분", "15분", "20분", "30분", "1시간", "초간단", "30초",
  // 형태/기타
  "레시피", "만들기", "만드는법", "만드는방법", "비법", "비법공개", "공개",
  "꿀팁", "팁", "후기", "리뷰", "도전", "챌린지", "asmr", "ASMR",
  "맛집", "맛있는", "맛있게", "신상", "신메뉴", "응용", "변형",
  "황금비율", "비율", "레시피공개",
  // 영어 noise
  "recipe", "recipes", "korean", "easy", "quick", "best", "homemade",
  "simple", "yummy", "tasty", "delicious",
];

const _BASE_BY_LENGTH_DESC = [...new Set(BASE_DISHES)]
  .sort((a, b) => b.length - a.length);

// Build a regex once that strips modifier tokens from a title (whole tokens
// only — we still leave compound dish names intact because dish names are
// matched separately).
const _MODIFIER_REGEX = (() => {
  if (MODIFIER_TOKENS.length === 0) return null;
  const escaped = MODIFIER_TOKENS
    .map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .sort((a, b) => b.length - a.length);
  return new RegExp(`(${escaped.join("|")})`, "gi");
})();

// Strip emoji / symbol noise so the LLM and dictionary see clean text.
const _NOISE_CHARS_REGEX = /[\p{Emoji_Presentation}\p{Extended_Pictographic}#@*~`"'_\-+=<>{}\[\]\\/|:;!?,.()·•★☆♥♡✨🔥]+/gu;

// ---------------------------------------------------------------------------
// Public helpers
// ---------------------------------------------------------------------------

function pickRecipeTitle(data) {
  if (!data || typeof data !== "object") return "";
  const nested = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  const source = data.source && typeof data.source === "object" ? data.source : {};
  const raw =
    nested.title ||
    data.title ||
    nested.name ||
    data.name ||
    source.title ||
    "";
  return String(raw || "").trim();
}

function _normalizeForMatch(title) {
  if (!title) return "";
  let s = String(title);
  s = s.replace(_NOISE_CHARS_REGEX, " ");
  s = s.toLowerCase();
  s = s.replace(/\s+/g, " ").trim();
  return s;
}

function _ruleBasedExtract(title) {
  const cleaned = _normalizeForMatch(title);
  if (!cleaned) return null;
  const compact = cleaned.replace(/\s+/g, "");

  // Strip modifier tokens.
  let stripped = cleaned;
  if (_MODIFIER_REGEX) {
    stripped = stripped.replace(_MODIFIER_REGEX, " ").replace(/\s+/g, " ").trim();
  }
  const strippedCompact = stripped.replace(/\s+/g, "");

  // Longest-match against base dish dictionary on both stripped + raw cleaned
  // text (so "베이컨김치볶음밥" still matches "김치볶음밥" even if "베이컨" was
  // not in the modifier list). compact 비교로 "두부 부침" → "두부부침" 도 잡는다.
  for (const dish of _BASE_BY_LENGTH_DESC) {
    if (!dish) continue;
    const needle = dish.toLowerCase();
    if (
      stripped.includes(needle) ||
      cleaned.includes(needle) ||
      strippedCompact.includes(needle) ||
      compact.includes(needle)
    ) {
      return dish;
    }
  }
  return null;
}

function _aliasDocId(title) {
  const norm = _normalizeForMatch(title);
  if (!norm) return "";
  return crypto.createHash("sha1").update(norm).digest("hex").slice(0, 32);
}

// `canonicalDish` is also used as the recipe_groups doc id. Firestore
// disallows '/' and a few other characters, and keys longer than ~1500 bytes
// fail. We trim and replace.
function canonicalKeyFromName(name) {
  if (!name) return "";
  let key = String(name).trim();
  if (!key) return "";
  if (key.length > CANONICAL_MAX_CHARS) {
    key = key.slice(0, CANONICAL_MAX_CHARS);
  }
  key = key
    .replace(/[\/.#\[\]*\u0000-\u001F]/g, "_")
    .replace(/\s+/g, "_");
  return key;
}

// ---------------------------------------------------------------------------
// LLM fallback
// ---------------------------------------------------------------------------

async function _llmExtractDish(title) {
  const apiKey = (process.env.GEMINI_API_KEY || "").trim();
  if (!apiKey) return null;
  if (!title) return null;

  const model =
    (process.env.RECIPE_CANONICAL_MODEL || "").trim() || "gemini-2.5-flash";
  const timeoutMsRaw = Number.parseInt(
    process.env.RECIPE_CANONICAL_TIMEOUT_MS || "8000",
    10
  );
  const timeoutMs = Number.isFinite(timeoutMsRaw)
    ? Math.max(2000, timeoutMsRaw)
    : 8000;

  const systemPrompt = [
    "너는 한국어 요리 제목에서 '기본 요리명'만 1개 추출하는 분류기다.",
    "규칙:",
    "- 부재료/수식어/조리도구/광고문구/이모지/유튜버 이름/시간/난이도 표현은 모두 제거.",
    "- 가능한 한 이미 알려진 한국식 요리명을 짧게 반환 (예: '김치찌개', '된장찌개', '제육볶음', '닭갈비', '비빔국수').",
    "- 요리명을 자신있게 추출할 수 없거나, 너무 일반적인 단어(예: 음식, 요리)만 남으면 dish 를 빈 문자열로 반환.",
    "- 답은 한국어로. 영어/중국어 dish 는 가능한 한 한국식 표기로 변환.",
    "- 출력은 반드시 JSON 한 줄: {\"dish\": \"...\"}",
  ].join("\n");

  const truncated = String(title).slice(0, TITLE_LLM_MAX_CHARS);

  const body = {
    systemInstruction: { parts: [{ text: systemPrompt }] },
    contents: [
      { role: "user", parts: [{ text: `title: ${truncated}` }] },
    ],
    generationConfig: {
      temperature: 0,
      responseMimeType: "application/json",
      responseSchema: {
        type: "OBJECT",
        properties: { dish: { type: "STRING" } },
        required: ["dish"],
      },
    },
  };

  const url =
    "https://generativelanguage.googleapis.com/v1beta/models/" +
    encodeURIComponent(model) +
    ":generateContent?key=" +
    encodeURIComponent(apiKey);

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    if (!resp.ok) {
      const txt = await resp.text();
      console.warn(
        "[CF][canonicalize] gemini http",
        resp.status,
        txt.slice(0, 300)
      );
      return null;
    }
    const json = await resp.json();
    _trackCanonicalizeUsage(json);
    const candidates = (json && json.candidates) || [];
    const parts =
      candidates[0] && candidates[0].content && candidates[0].content.parts
        ? candidates[0].content.parts
        : [];
    const content = parts.map((p) => (p && p.text) || "").join("").trim();
    if (!content) return null;
    let parsed = {};
    try {
      parsed = JSON.parse(content);
    } catch (_) {
      return null;
    }
    const dish = String(parsed.dish || "").trim();
    if (!dish) return null;
    if (dish.length > CANONICAL_MAX_CHARS) return null;
    return dish;
  } catch (e) {
    console.warn(
      "[CF][canonicalize] gemini error:",
      e && e.message ? e.message : e
    );
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// Gemini 응답의 usageMetadata를 Mixpanel로 fire-and-forget 전송 (실패해도 무시).
function _trackCanonicalizeUsage(json) {
  const usage = (json && json.usageMetadata) || null;
  if (!usage) return;
  const inputTokens = Number(usage.promptTokenCount || 0);
  const outputTokens = Number(usage.candidatesTokenCount || 0);
  const thinkingTokens = Number(usage.thoughtsTokenCount || 0);
  if (!inputTokens && !outputTokens && !thinkingTokens) return;
  trackMixpanelEvent(_MIXPANEL_SYSTEM_DISTINCT_ID, "llm_recipe_canonicalize", {
    llm_input_tokens: inputTokens,
    llm_output_tokens: outputTokens,
    llm_thinking_tokens: thinkingTokens,
    llm_total_tokens: inputTokens + outputTokens + thinkingTokens,
  }).catch(() => {});
}

// ---------------------------------------------------------------------------
// Main entry point used by triggers/backfill.
// ---------------------------------------------------------------------------

/**
 * Extract a canonical dish name for a recipe title.
 *
 * Returns `{ name: string, key: string, source: "rule"|"cache"|"llm"|"none" }`
 * with `name` empty when no confident extraction is possible.
 *
 * @param {string} title
 * @param {{ db?: FirebaseFirestore.Firestore, useLlm?: boolean }} [opts]
 */
async function extractCanonicalDish(title, opts = {}) {
  const trimmed = String(title || "").trim();
  if (!trimmed) {
    return { name: "", key: "", source: "none" };
  }

  // 1. Rule-based.
  const rule = _ruleBasedExtract(trimmed);
  if (rule) {
    return { name: rule, key: canonicalKeyFromName(rule), source: "rule" };
  }

  // 2. Alias cache lookup.
  const aliasId = _aliasDocId(trimmed);
  const db = opts.db || admin.firestore();
  let aliasDocRef = null;
  if (aliasId) {
    aliasDocRef = db.collection("recipe_group_aliases").doc(aliasId);
    try {
      const snap = await aliasDocRef.get();
      if (snap.exists) {
        const data = snap.data() || {};
        const cachedName = String(data.name || "").trim();
        if (cachedName) {
          return {
            name: cachedName,
            key: canonicalKeyFromName(cachedName),
            source: "cache",
          };
        }
        // Cached "no match" — skip the LLM unless the cache is stale.
        if (data.miss === true) {
          return { name: "", key: "", source: "cache" };
        }
      }
    } catch (e) {
      console.warn("[CF][canonicalize] alias get failed:", e && e.message ? e.message : e);
    }
  }

  // 3. LLM fallback (opt-out via opts.useLlm === false).
  if (opts.useLlm === false) {
    return { name: "", key: "", source: "none" };
  }

  const llm = await _llmExtractDish(trimmed);

  if (aliasDocRef) {
    try {
      await aliasDocRef.set(
        {
          title: trimmed.slice(0, 200),
          name: llm || "",
          miss: !llm,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    } catch (e) {
      console.warn("[CF][canonicalize] alias write failed:", e && e.message ? e.message : e);
    }
  }

  if (!llm) return { name: "", key: "", source: "none" };
  return { name: llm, key: canonicalKeyFromName(llm), source: "llm" };
}

module.exports = {
  pickRecipeTitle,
  extractCanonicalDish,
  canonicalKeyFromName,
  // Exposed for tests / backfill scripts.
  _ruleBasedExtract,
  _normalizeForMatch,
  BASE_DISHES,
  MODIFIER_TOKENS,
};
