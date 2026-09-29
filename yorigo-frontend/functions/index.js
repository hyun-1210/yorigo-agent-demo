const crypto = require("crypto");
const functions = require("firebase-functions");
const admin = require("firebase-admin");
const sharp = require("sharp");
const { google } = require("googleapis");
const { trackMixpanelEvent } = require("./mixpanelTracking");

admin.initializeApp();
const db = admin.firestore();

const rewards = require("./rewards");
exports.claimReward = rewards.claimReward;
exports.claimAttendance = rewards.claimAttendance;

// 모임·챌린지 callable: 배포 전까지 비활성.
// const communitySocial = require("./communitySocial");
// exports.joinMeetup = communitySocial.joinMeetup;
// exports.leaveMeetup = communitySocial.leaveMeetup;
// exports.confirmOpenClass = communitySocial.confirmOpenClass;
// exports.joinChallenge = communitySocial.joinChallenge;
// exports.leaveChallenge = communitySocial.leaveChallenge;
// exports.submitChallengeProof = communitySocial.submitChallengeProof;

/** @param {number} v @param {number} d */
function _envFloat(name, d) {
  const raw = (process.env[name] || "").toString().trim();
  if (!raw) return d;
  const n = Number.parseFloat(raw);
  return Number.isFinite(n) ? n : d;
}

const RECIPE_THUMB_CROP_SCALE_X = () => _envFloat("RECIPE_THUMBNAIL_CROP_SCALE_X", 3.2);
const RECIPE_THUMB_CROP_SCALE_Y = () => _envFloat("RECIPE_THUMBNAIL_CROP_SCALE_Y", 1.28);
const INSTAGRAM_TARGET_ASPECT_RATIO = 4 / 5;
const SEASONAL_INDEX_LIMIT = 300;
const INGREDIENT_INDEX_LIMIT = 400;
const CHEF_INDEX_LIMIT = 60;
const CHEF_ALLOWLIST = new Set(require("./data/chef_tags_ko.json"));
const {
  getSectionRules,
  refreshCmsSectionRules,
  isManualIndexKey,
} = require("./homeSectionRules");
const {
  loadOverrides,
  rebuildHomeSectionIndex,
  rebuildProgramHomeSectionIndexes,
  syncHomeSectionIndexForRecipe,
  normalizeOverridesDoc,
  buildSectionRecipeIds,
  writeSectionIndex,
  _isVisibleCompletedRecipe: _isVisibleCompletedHomeRecipe,
} = require("./homeSectionIndex");
const streakReminders = require("./streakReminders");
const SEASONAL_KEYWORDS = {
  1: ["꼬막", "대구", "더덕", "우엉", "방어", "한라봉", "굴", "시금치", "배추", "무", "명태"],
  2: ["봄동", "시금치", "멍게", "가자미", "딸기", "취나물", "삼치", "냉이", "달래", "도미", "미나리"],
  3: ["냉이", "달래", "쑥", "주꾸미", "꽃게", "도다리", "매생이", "씀바귀", "딸기", "바지락", "문어"],
  4: ["죽순", "두릅", "미더덕", "바지락", "멍게", "참나물", "키조개", "쑥갓", "주꾸미", "갑오징어", "도다리"],
  5: ["매실", "미나리", "전복", "병어", "고사리", "참다랑어", "장어", "죽순", "부추", "오이", "주꾸미", "키조개", "갑오징어", "참돔"],
  6: ["감자", "참외", "한치", "농어", "복분자", "옥수수", "가지", "애호박", "민어", "매실", "다슬기"],
  7: ["수박", "옥수수", "복숭아", "갈치", "전복", "성게", "토마토", "자두", "오징어", "삼치", "민어"],
  8: ["포도", "자두", "민어", "전복", "토마토", "고추", "복숭아", "수박", "갈치", "전어", "가지"],
  9: ["고구마", "대하", "꽃게", "사과", "배", "송이버섯", "전어", "무화과", "토란", "고등어", "버섯"],
  10: ["무", "배추", "굴", "꽁치", "고등어", "홍시", "전어", "유자", "대하", "낙지", "버섯"],
  11: ["유자", "배추", "굴", "홍합", "과메기", "귤", "방어", "꼬막", "고등어", "시금치", "대하"],
  12: ["대게", "아귀", "명태", "한라봉", "귤", "과메기", "방어", "꼬막", "홍합", "대구", "배추"],
};

/** @param {FirebaseFirestore.DocumentData | undefined} data */
function _isYoutubeRecipe(data) {
  if (!data || typeof data !== "object") return false;
  const source = typeof data.source === "object" && data.source ? data.source : {};
  const platform = String(source.platform || data.platform || "").toLowerCase();
  if (platform.includes("youtube")) return true;
  const sourceUrl = String(data.sourceUrl || source.url || "").toLowerCase();
  if (sourceUrl.includes("youtube.com") || sourceUrl.includes("youtu.be")) return true;
  const t = String(
    data.thumbnailUrl || data.thumbnailUrlLarge || source.thumbnail || ""
  ).toLowerCase();
  return t.includes("ytimg.com");
}

/** @param {FirebaseFirestore.DocumentData | undefined} data */
function _pickSourceUrlForCrop(data) {
  if (!data || typeof data !== "object") return "";
  const source = typeof data.source === "object" && data.source ? data.source : {};
  const st = String(source.thumbnail || "").trim();
  const stLow = st.toLowerCase();
  if (st && (stLow.includes("ytimg.com") || stLow.includes("youtube.com/vi/"))) return st;
  for (const key of ["thumbnailUrl", "thumbnailUrlLarge"]) {
    const u = String(data[key] || "").trim();
    const low = u.toLowerCase();
    if (u && (low.includes("ytimg.com") || low.includes("youtube.com/vi/"))) return u;
  }
  return String(
    data.thumbnailUrlLarge || data.thumbnailUrl || source.thumbnail || ""
  ).trim();
}

/** @param {FirebaseFirestore.DocumentData | undefined} data */
function _isInstagramRecipe(data) {
  if (!data || typeof data !== "object") return false;
  const source = typeof data.source === "object" && data.source ? data.source : {};
  const platform = String(source.platform || data.platform || "").toLowerCase();
  if (platform.includes("instagram")) return true;
  const sourceUrl = String(data.sourceUrl || source.url || "").toLowerCase();
  if (sourceUrl.includes("instagram.com") || sourceUrl.includes("instagr.am")) return true;
  const t = String(
    data.thumbnailUrlLarge || data.thumbnailUrl || source.thumbnail || ""
  ).toLowerCase();
  return t.includes("instagram.com") || t.includes("cdninstagram.com");
}

/** @param {FirebaseFirestore.DocumentData | undefined} data */
function _pickInstagramThumbnailSource(data) {
  if (!data || typeof data !== "object") return "";
  const source = typeof data.source === "object" && data.source ? data.source : {};
  const large = String(data.thumbnailUrlLarge || "").trim();
  if (large) return large;
  const card = String(data.thumbnailUrl || "").trim();
  if (card) return card;
  return String(source.thumbnail || "").trim();
}

/** @param {number} width @param {number} height */
function _centerAspectCropBounds(width, height, targetRatio) {
  const w = width;
  const h = height;
  if (w < 2 || h < 2) return null;
  const ratio = w / h;
  let cropW = w;
  let cropH = h;
  if (ratio < targetRatio) {
    cropH = Math.max(1, Math.min(h, Math.round(w / targetRatio)));
  } else if (ratio > targetRatio) {
    cropW = Math.max(1, Math.min(w, Math.round(h * targetRatio)));
  }
  const left = Math.max(0, Math.min(w - cropW, Math.round((w - cropW) / 2)));
  const top = Math.max(0, Math.min(h - cropH, Math.round((h - cropH) / 2)));
  return { left, top, width: cropW, height: cropH };
}

/**
 * @param {FirebaseFirestore.DocumentData | undefined} before
 * @param {FirebaseFirestore.DocumentData | undefined} after
 */
function _shouldSkipInstagramCroppedWork(before, after) {
  const cropped = String((after || {}).thumbnailUrlCropped || "").trim();
  if (!cropped) return false;
  const srcBefore = _pickInstagramThumbnailSource(before);
  const srcAfter = _pickInstagramThumbnailSource(after);
  if (srcBefore !== srcAfter) return false;
  return true;
}

/**
 * @param {FirebaseFirestore.DocumentData | undefined} before
 * @param {FirebaseFirestore.DocumentData | undefined} after
 */
function _shouldSkipCroppedWork(before, after) {
  const cropped = String((after || {}).thumbnailUrlCropped || "").trim();
  if (!cropped) return false;
  const srcBefore = _pickSourceUrlForCrop(before);
  const srcAfter = _pickSourceUrlForCrop(after);
  if (srcBefore !== srcAfter) return false;
  return true;
}

/**
 * 백엔드(PIL)와 동일한 고정 비율 크롭 박스.
 * @returns {{ left: number, top: number, width: number, height: number } | null}
 */
function _fixedScaleCropBounds(width, height, scaleX, scaleY) {
  const w = width;
  const h = height;
  if (w < 2 || h < 2) return null;
  const sx = scaleX > 1 ? scaleX : 1;
  const sy = scaleY > 1 ? scaleY : 1;
  if (sx <= 1 && sy <= 1) return null;
  const cropW = Math.max(1, Math.min(w, Math.round(w / sx)));
  const cropH = Math.max(1, Math.min(h, Math.round(h / sy)));
  if (cropW >= w && cropH >= h) return null;
  const left = Math.max(0, Math.min(w - cropW, Math.round((w - cropW) / 2)));
  const top = Math.max(0, Math.min(h - cropH, Math.round((h - cropH) / 2)));
  return { left, top, width: cropW, height: cropH };
}

/**
 * @param {string} bucketName
 * @param {string} objectPath
 * @param {string} token
 */
function _buildDownloadUrl(bucketName, objectPath, token) {
  const enc = encodeURIComponent(objectPath).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  return `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${enc}?alt=media&token=${token}`;
}

/** @param {string} raw */
function _parseUrlLoosely(raw) {
  const t = String(raw || "").trim();
  if (!t) return null;
  try {
    return new URL(t);
  } catch (_) {}
  try {
    return new URL(`https://${t}`);
  } catch (_) {}
  return null;
}

/** @param {string} raw */
function _unwrapNaverLink(raw) {
  const parsed = _parseUrlLoosely(raw);
  if (!parsed) return String(raw || "").trim();
  const host = parsed.hostname.toLowerCase();
  if (!host.includes("link.naver.com")) return parsed.toString();
  for (const key of ["url", "u", "targetUrl", "target"]) {
    const value = parsed.searchParams.get(key);
    if (!value) continue;
    try {
      return decodeURIComponent(value);
    } catch (_) {
      return value;
    }
  }
  return parsed.toString();
}

/** @param {string} sourceUrl */
function _normalizeSourceUrl(sourceUrl) {
  const raw = String(sourceUrl || "").trim();
  if (!raw) return raw;

  let parsed = _parseUrlLoosely(raw);
  if (!parsed) return raw;

  let host = parsed.hostname.toLowerCase();
  let segments = parsed.pathname.split("/").filter(Boolean);
  const qp = {};
  for (const [k, v] of parsed.searchParams.entries()) {
    qp[k] = v;
  }

  if (host.includes("youtu.be")) {
    if (segments.length) qp.v = segments[0];
    host = "www.youtube.com";
    segments = ["watch"];
  }

  if (host.includes("youtube.com")) {
    let videoId = qp.v || "";
    if (!videoId && segments.length >= 2) {
      const first = segments[0];
      if (first === "shorts" || first === "embed" || first === "live") {
        videoId = segments[1];
      }
    }
    if (videoId) {
      return `https://www.youtube.com/watch?v=${encodeURIComponent(videoId)}`;
    }
  }

  if (host.includes("instagram.com")) {
    if (segments.length >= 2) {
      const first = segments[0];
      if (first === "reel" || first === "reels" || first === "p" || first === "tv") {
        return `https://www.instagram.com/${first}/${encodeURIComponent(segments[1])}/`;
      }
    }
  }

  if (host.includes("tiktok.com")) {
    let id = "";
    for (let i = 0; i < segments.length - 1; i += 1) {
      if (segments[i] === "video") {
        id = segments[i + 1];
        break;
      }
    }
    if (id) return `https://www.tiktok.com/video/${encodeURIComponent(id)}`;
  }

  if (host.includes("link.naver.com") || host.includes("blog.naver.com") || raw.toLowerCase().includes("naver.me")) {
    const unwrapped = _unwrapNaverLink(raw);
    const unwrappedParsed = _parseUrlLoosely(unwrapped);
    if (unwrappedParsed) {
      host = unwrappedParsed.hostname.toLowerCase();
      segments = unwrappedParsed.pathname.split("/").filter(Boolean);
      for (const key of Object.keys(qp)) delete qp[key];
      for (const [k, v] of unwrappedParsed.searchParams.entries()) {
        qp[k] = v;
      }
      parsed = unwrappedParsed;
    }
  }

  if (host.includes("blog.naver.com")) {
    let blogId = "";
    let logNo = "";
    const qBlogId = String(qp.blogId || "");
    const qLogNo = String(qp.logNo || "");
    if (qBlogId && /^\d+$/.test(qLogNo)) {
      blogId = qBlogId;
      logNo = qLogNo;
    } else if (segments.length === 2 && /^\d+$/.test(segments[1])) {
      blogId = segments[0];
      logNo = segments[1];
    }
    if (blogId && logNo) {
      return `https://m.blog.naver.com/${encodeURIComponent(blogId)}/${encodeURIComponent(logNo)}`;
    }
  }

  const filtered = [];
  for (const [k, v] of parsed.searchParams.entries()) {
    const low = k.toLowerCase();
    if (low.startsWith("utm_")) continue;
    if (low === "feature" || low === "si" || low === "fbclid" || low === "igshid") continue;
    filtered.push([k, v]);
  }
  const fallback = new URL(parsed.toString());
  fallback.protocol = "https:";
  fallback.hostname = host;
  fallback.search = "";
  for (const [k, v] of filtered) {
    fallback.searchParams.append(k, v);
  }
  return fallback.toString();
}

/** @param {string} sourceUrl */
function _buildSourceKey(sourceUrl) {
  const normalized = _normalizeSourceUrl(sourceUrl);
  if (!normalized) return null;
  const parsed = _parseUrlLoosely(normalized);
  if (!parsed) return null;
  const host = parsed.hostname.toLowerCase();
  const segments = parsed.pathname.split("/").filter(Boolean);

  if (host.includes("youtube.com")) {
    const videoId = parsed.searchParams.get("v") || "";
    if (videoId) return `youtube:${videoId}`;
    if (segments.length >= 2) {
      const first = segments[0];
      if (first === "shorts" || first === "embed" || first === "live") {
        return `youtube:${segments[1]}`;
      }
    }
  }

  if (host.includes("instagram.com") && segments.length >= 2) {
    const first = segments[0];
    if (first === "reel" || first === "reels" || first === "p" || first === "tv") {
      return `instagram:${segments[1]}`;
    }
  }

  if (host.includes("tiktok.com")) {
    for (let i = 0; i < segments.length - 1; i += 1) {
      if (segments[i] === "video") return `tiktok:${segments[i + 1]}`;
    }
  }

  if (host.includes("blog.naver.com") && segments.length === 2 && /^\d+$/.test(segments[1])) {
    return `naver_blog:${segments[0]}__${segments[1]}`;
  }
  return null;
}

/** @param {FirebaseFirestore.DocumentData | undefined} data */
function _buildRecipeSourcePatch(data) {
  const recipe = (data && typeof data === "object") ? data : {};
  const source = (recipe.source && typeof recipe.source === "object") ? recipe.source : {};
  const sourceUrlTop = String(recipe.sourceUrl || "").trim();
  const sourceUrlNested = String(source.url || "").trim();
  const sourceUrlRaw = sourceUrlTop || sourceUrlNested;
  if (!sourceUrlRaw) return null;

  const normalized = _normalizeSourceUrl(sourceUrlRaw);
  const nextSourceKey = _buildSourceKey(normalized);
  const currentSourceKey = recipe.sourceKey == null ? null : String(recipe.sourceKey);
  const patch = {};

  if (sourceUrlTop !== normalized) patch.sourceUrl = normalized;
  if (sourceUrlNested !== normalized) patch["source.url"] = normalized;
  if (currentSourceKey !== nextSourceKey) patch.sourceKey = nextSourceKey;
  return Object.keys(patch).length ? patch : null;
}

/**
 * YouTube 레시피 문서에 `thumbnailUrlCropped` 가 없거나 썸네일 소스가 바뀐 뒤면 Storage에 올리고 Firestore를 갱신합니다.
 * @param {string} recipeId
 * @param {FirebaseFirestore.DocumentData} after
 */
async function ensureYoutubeCroppedThumbnailForRecipe(recipeId, after) {
  if (!_isYoutubeRecipe(after)) return { status: "skipped_not_youtube" };

  const sourceUrl = _pickSourceUrlForCrop(after);
  if (!sourceUrl) return { status: "skipped_no_source" };

  const resp = await fetch(sourceUrl, { redirect: "follow", signal: AbortSignal.timeout(25000) });
  if (!resp.ok || !resp.body) return { status: "skipped_download" };
  const buf = Buffer.from(await resp.arrayBuffer());
  if (!buf.length) return { status: "skipped_download" };

  let meta;
  try {
    meta = await sharp(buf).metadata();
  } catch (e) {
    console.warn("[CF][recipe_thumb] decode failed:", e);
    return { status: "skipped_decode" };
  }
  const iw = meta.width || 0;
  const ih = meta.height || 0;
  const bounds = _fixedScaleCropBounds(iw, ih, RECIPE_THUMB_CROP_SCALE_X(), RECIPE_THUMB_CROP_SCALE_Y());
  if (!bounds) return { status: "skipped_no_crop" };

  let jpeg;
  try {
    jpeg = await sharp(buf)
      .extract(bounds)
      .jpeg({ quality: 90 })
      .toBuffer();
  } catch (e) {
    console.warn("[CF][recipe_thumb] crop failed:", e);
    return { status: "error", detail: String(e && e.message ? e.message : e) };
  }

  const bucket = admin.storage().bucket();
  const bucketName = bucket.name;
  const objectPath = `recipe_thumbnails/cropped/${recipeId}_cropped.jpg`;
  const token = crypto.randomUUID();
  const downloadUrl = _buildDownloadUrl(bucketName, objectPath, token);
  const file = bucket.file(objectPath);
  await file.save(jpeg, {
    contentType: "image/jpeg",
    resumable: false,
    metadata: {
      metadata: {
        firebaseStorageDownloadTokens: token,
        variant: "cropped",
        sourceUrl,
        recipeId,
      },
    },
  });

  await db.collection("recipes").doc(recipeId).update({
    thumbnailUrlCropped: downloadUrl,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { status: "updated", thumbnailUrlCropped: downloadUrl };
}

/**
 * Instagram 레시피 문서의 썸네일을 4:5 중앙 크롭으로 저장합니다.
 * @param {string} recipeId
 * @param {FirebaseFirestore.DocumentData} after
 */
async function ensureInstagramCroppedThumbnailForRecipe(recipeId, after) {
  if (!_isInstagramRecipe(after)) return { status: "skipped_not_instagram" };

  const sourceUrl = _pickInstagramThumbnailSource(after);
  if (!sourceUrl) return { status: "skipped_no_source" };

  const resp = await fetch(sourceUrl, { redirect: "follow", signal: AbortSignal.timeout(25000) });
  if (!resp.ok || !resp.body) return { status: "skipped_download" };
  const buf = Buffer.from(await resp.arrayBuffer());
  if (!buf.length) return { status: "skipped_download" };

  let meta;
  try {
    meta = await sharp(buf).metadata();
  } catch (e) {
    console.warn("[CF][instagram_thumb] decode failed:", e);
    return { status: "skipped_decode" };
  }
  const iw = meta.width || 0;
  const ih = meta.height || 0;
  const bounds = _centerAspectCropBounds(iw, ih, INSTAGRAM_TARGET_ASPECT_RATIO);
  if (!bounds) return { status: "skipped_no_crop" };

  let jpeg;
  try {
    jpeg = await sharp(buf)
      .extract(bounds)
      .jpeg({ quality: 90 })
      .toBuffer();
  } catch (e) {
    console.warn("[CF][instagram_thumb] crop failed:", e);
    return { status: "error", detail: String(e && e.message ? e.message : e) };
  }

  const bucket = admin.storage().bucket();
  const bucketName = bucket.name;
  const objectPath = `recipe_thumbnails/cropped/${recipeId}_cropped.jpg`;
  const token = crypto.randomUUID();
  const downloadUrl = _buildDownloadUrl(bucketName, objectPath, token);
  const file = bucket.file(objectPath);
  await file.save(jpeg, {
    contentType: "image/jpeg",
    resumable: false,
    metadata: {
      metadata: {
        firebaseStorageDownloadTokens: token,
        variant: "instagram_4x5_cropped",
        sourceUrl,
        recipeId,
      },
    },
  });

  await db.collection("recipes").doc(recipeId).update({
    thumbnailUrlCropped: downloadUrl,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { status: "updated", thumbnailUrlCropped: downloadUrl };
}

/**
 * If a document is created without `isHidden` (or with null), normalize to `false`.
 * We intentionally do nothing when `isHidden` is already `false` or `true`.
 */
async function normalizeIsHiddenFalseOnCreate(snap) {
  const data = snap.data() || {};

  // Field missing => data has no own property. Null => explicitly set to null.
  const hasIsHidden = Object.prototype.hasOwnProperty.call(data, "isHidden");
  const isHidden = data.isHidden;

  if (!hasIsHidden || isHidden === null) {
    await snap.ref.update({ isHidden: false });
  }
}

exports.onRecipeCreateNormalizeIsHidden = functions
  .firestore
  .document("recipes/{recipeId}")
  .onCreate(async (snap) => {
    try {
      await normalizeIsHiddenFalseOnCreate(snap);
    } catch (e) {
      console.error("[CF][recipes] normalize isHidden failed:", e);
    }
  });

exports.onReviewCreateNormalizeIsHidden = functions
  .firestore
  .document("reviews/{reviewId}")
  .onCreate(async (snap) => {
    try {
      await normalizeIsHiddenFalseOnCreate(snap);
    } catch (e) {
      console.error("[CF][reviews] normalize isHidden failed:", e);
    }
  });

exports.onCommentCreateNormalizeIsHidden = functions
  .firestore
  .document("reviews/{reviewId}/comments/{commentId}")
  .onCreate(async (snap) => {
    try {
      await normalizeIsHiddenFalseOnCreate(snap);
    } catch (e) {
      console.error("[CF][comments] normalize isHidden failed:", e);
    }
  });

function _sanitizeText(v) {
  return (v || "").toString().trim();
}

function _recipeTitle(data) {
  if (!data || typeof data !== "object") return "";
  const nested = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  return _sanitizeText(nested.title || data.title || nested.name || data.name).toLowerCase();
}

function _isVisibleCompletedRecipe(data) {
  if (!data || typeof data !== "object") return false;
  if (data.isHidden === true) return false;
  return String(data.status || "").toLowerCase() === "completed";
}

function _matchedSeasonalMonths(data) {
  if (!_isVisibleCompletedRecipe(data)) return [];
  const title = _recipeTitle(data);
  if (!title) return [];
  const months = [];
  for (const [monthStr, keywords] of Object.entries(SEASONAL_KEYWORDS)) {
    if (keywords.some((kw) => title.includes(kw.toLowerCase()))) {
      months.push(Number(monthStr));
    }
  }
  return months;
}

async function _syncSeasonalIndexForRecipe(recipeId, beforeData, afterData) {
  const beforeMonths = new Set(_matchedSeasonalMonths(beforeData));
  const afterMonths = new Set(_matchedSeasonalMonths(afterData));
  const impacted = new Set([...beforeMonths, ...afterMonths]);
  if (impacted.size === 0) return;

  await Promise.all(
    [...impacted].map(async (month) => {
      const docRef = db.collection("seasonal_recipe_index").doc(String(month));
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(docRef);
        const data = snap.exists ? (snap.data() || {}) : {};
        const current = Array.isArray(data.recipeIds) ? data.recipeIds : [];
        const sanitized = current
          .map((id) => _sanitizeText(id))
          .filter((id) => !!id && id !== recipeId);
        const next = afterMonths.has(month) ? [recipeId, ...sanitized] : sanitized;
        tx.set(
          docRef,
          {
            month,
            recipeIds: next.slice(0, SEASONAL_INDEX_LIMIT),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      });
    })
  );
}

function _normalizeIngredientKey(name) {
  return _sanitizeText(name).toLowerCase().replace(/\s+/g, " ");
}

function _ingredientIndexDocId(normalizedKey) {
  if (!normalizedKey) return "";
  let docId = normalizedKey.replace(/\//g, "__").replace(/\.\./g, "_");
  if (docId.length > 500) {
    docId = `h_${crypto.createHash("sha256").update(normalizedKey).digest("hex").slice(0, 40)}`;
  }
  return docId;
}

function _extractIngredientKeysFromRecipe(data) {
  if (!_isVisibleCompletedRecipe(data)) return [];
  const nested = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
  const ingredients = Array.isArray(nested.ingredients) ? nested.ingredients : [];
  const keys = new Set();
  for (const ing of ingredients) {
    if (!ing || typeof ing !== "object") continue;
    const key = _normalizeIngredientKey(ing.item || "");
    if (key) keys.add(key);
  }
  return [...keys];
}

async function _syncIngredientIndexForRecipe(recipeId, beforeData, afterData) {
  const beforeKeys = new Set(_extractIngredientKeysFromRecipe(beforeData));
  const afterKeys = new Set(_extractIngredientKeysFromRecipe(afterData));
  const impacted = new Set([...beforeKeys, ...afterKeys]);
  if (impacted.size === 0) return;

  await Promise.all(
    [...impacted].map(async (ingredientKey) => {
      const docId = _ingredientIndexDocId(ingredientKey);
      if (!docId) return;
      const docRef = db.collection("ingredient_recipe_index").doc(docId);
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(docRef);
        const data = snap.exists ? (snap.data() || {}) : {};
        const current = Array.isArray(data.recipeIds) ? data.recipeIds : [];
        const sanitized = current
          .map((id) => _sanitizeText(id))
          .filter((id) => !!id && id !== recipeId);
        const next = afterKeys.has(ingredientKey) ? [recipeId, ...sanitized] : sanitized;
        tx.set(
          docRef,
          {
            ingredientKey,
            recipeIds: next.slice(0, INGREDIENT_INDEX_LIMIT),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      });
    })
  );
}

function _extractChefTagFromRecipe(data) {
  if (!data || typeof data !== "object") return "";
  const direct = _sanitizeText(data.chefTag);
  if (direct && CHEF_ALLOWLIST.has(direct)) return direct;
  const tags = data.tags;
  if (Array.isArray(tags) && tags.length > 0) {
    const first = _sanitizeText(tags[0]);
    if (first && CHEF_ALLOWLIST.has(first)) return first;
  }
  return "";
}

async function _syncChefIndexForRecipe(recipeId, beforeData, afterData) {
  const beforeChef = _extractChefTagFromRecipe(beforeData);
  const afterChef = _extractChefTagFromRecipe(afterData);
  const impacted = new Set([beforeChef, afterChef].filter(Boolean));
  if (impacted.size === 0) return;

  await Promise.all(
    [...impacted].map(async (chefName) => {
      const shouldInclude =
        _isVisibleCompletedRecipe(afterData) && afterChef === chefName;
      const docRef = db.collection("chef_recipe_index").doc(chefName);
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(docRef);
        const data = snap.exists ? snap.data() || {} : {};
        const current = Array.isArray(data.recipeIds) ? data.recipeIds : [];
        const sanitized = current
          .map((id) => _sanitizeText(id))
          .filter((id) => !!id && id !== recipeId);
        const next = shouldInclude ? [recipeId, ...sanitized] : sanitized;
        const limited = next.slice(0, CHEF_INDEX_LIMIT);
        tx.set(
          docRef,
          {
            chefName,
            recipeIds: limited,
            count: limited.length,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      });
    })
  );
}

async function _syncHomeSectionIndexForRecipe(recipeId, beforeData, afterData, isNewRecipe = false) {
  await refreshCmsSectionRules(db);
  await syncHomeSectionIndexForRecipe(db, recipeId, beforeData, afterData, isNewRecipe);
}

async function getUserSummary(uid) {
  if (!uid) {
    return { uid: "", name: "사용자", photoUrl: "" };
  }
  try {
    const userSnap = await db.collection("users").doc(uid).get();
    const data = userSnap.data() || {};
    const name = _sanitizeText(data.name) || _sanitizeText(data.handle) || "사용자";
    return {
      uid,
      name,
      photoUrl: _sanitizeText(data.photoUrl),
    };
  } catch (e) {
    console.error("[CF] getUserSummary failed:", e);
    return { uid, name: "사용자", photoUrl: "" };
  }
}

async function _notificationWithEventKeyExists(targetUserId, eventKey) {
  if (!targetUserId || !eventKey) return false;
  const notifRef = db.collection("users").doc(targetUserId).collection("notifications");
  const dupSnap = await notifRef.where("eventKey", "==", eventKey).limit(1).get();
  return !dupSnap.empty;
}

async function createNotification({
  targetUserId,
  type,
  actorId,
  actorName,
  actorPhotoUrl,
  reviewId = "",
  commentId = "",
  recipeId = "",
  message = "",
  title = "",
  eventKey = "",
  screen = "",
  skipDedupeCheck = false,
}) {
  if (!targetUserId || !type) return null;

  const notifRef = db.collection("users").doc(targetUserId).collection("notifications");

  // Short dedupe window for repeated client retries/toggles.
  // createNotificationOnce()가 호출 전에 이미 eventKey 존재 여부를 조회했다면(skipDedupeCheck)
  // 동일한 eventKey 쿼리를 여기서 또 실행하지 않는다 (중복 read 제거).
  if (eventKey && !skipDedupeCheck) {
    try {
      const dupSnap = await notifRef
        .where("eventKey", "==", eventKey)
        .orderBy("createdAt", "desc")
        .limit(1)
        .get();
      if (!dupSnap.empty) {
        const last = dupSnap.docs[0].data() || {};
        const createdAt = last.createdAt && last.createdAt.toDate ? last.createdAt.toDate() : null;
        if (createdAt && Date.now() - createdAt.getTime() < 120000) {
          return null;
        }
      }
    } catch (e) {
      console.warn("[CF] dedupe check failed:", e);
    }
  }

  const docRef = notifRef.doc();
  const payload = {
    notificationId: docRef.id,
    type,
    actorId: actorId || "",
    actorName: _sanitizeText(actorName),
    actorPhotoUrl: _sanitizeText(actorPhotoUrl),
    reviewId: reviewId || "",
    commentId: commentId || "",
    recipeId: recipeId || "",
    targetUserId,
    message: _sanitizeText(message),
    isRead: false,
    eventKey: _sanitizeText(eventKey),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  const sanitizedTitle = _sanitizeText(title);
  if (sanitizedTitle) {
    payload.title = sanitizedTitle;
  }
  const sanitizedScreen = _sanitizeText(screen);
  if (sanitizedScreen) {
    payload.screen = sanitizedScreen;
  }
  await docRef.set(payload);

  return docRef.id;
}

/**
 * Create an in-app notification only once per user for a stable eventKey.
 * @returns {Promise<string|null>}
 */
async function createNotificationOnce({
  targetUserId,
  type,
  actorId,
  actorName,
  actorPhotoUrl,
  reviewId = "",
  commentId = "",
  recipeId = "",
  message = "",
  title = "",
  eventKey = "",
  screen = "",
}) {
  if (!targetUserId || !type || !eventKey) return null;
  if (await _notificationWithEventKeyExists(targetUserId, eventKey)) {
    return null;
  }
  // 위에서 이미 eventKey 존재 여부를 확인했으므로 createNotification 내부의
  // 동일 eventKey 재조회(dedupe query)는 건너뛴다 (read 1회 절약).
  return createNotification({
    targetUserId,
    type,
    actorId,
    actorName,
    actorPhotoUrl,
    reviewId,
    commentId,
    recipeId,
    message,
    title,
    eventKey,
    screen,
    skipDedupeCheck: true,
  });
}

/**
 * @param {string} targetUserId
 * @param {object} payload
 * @param {{ tokens?: string[] }=} options - tokens를 미리 알고 있으면(예: 배치 작업에서
 *   collectionGroup('fcmTokens')를 이미 읽은 경우) 넘겨서 fcmTokens 재조회를 생략한다.
 */
async function sendPushToUser(targetUserId, payload, options = {}) {
  if (!targetUserId) {
    return {
      ok: false,
      reason: "missing_target_user",
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
      invalidTokens: [],
    };
  }
  try {
    let tokens;
    if (Array.isArray(options.tokens)) {
      tokens = options.tokens.filter((t) => !!t && t.length > 20);
    } else {
      const tokenSnap = await db
        .collection("users")
        .doc(targetUserId)
        .collection("fcmTokens")
        .get();

      tokens = tokenSnap.docs
        .map((d) => d.id)
        .filter((t) => !!t && t.length > 20);
    }

    if (tokens.length === 0) {
      return {
        ok: false,
        reason: "no_tokens",
        tokenCount: 0,
        successCount: 0,
        failureCount: 0,
        invalidTokens: [],
      };
    }

    const message = {
      tokens,
      notification: {
        title: payload.title || "요리고",
        body: payload.body || "",
      },
      data: {
        type: payload.type || "",
        reviewId: payload.reviewId || "",
        commentId: payload.commentId || "",
        recipeId: payload.recipeId || "",
        actorId: payload.actorId || "",
        screen: payload.screen || "",
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
      android: {
        priority: "high",
        notification: { channelId: "yorigo_notifications" },
      },
      apns: {
        headers: {
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
    };

    const result = await admin.messaging().sendEachForMulticast(message);
    const invalidTokens = [];
    const errorCodes = [];
    if (result.failureCount > 0) {
      result.responses.forEach((r, idx) => {
        if (!r.success) {
          const code = r.error && r.error.code ? r.error.code : "";
          if (code) errorCodes.push(code);
          if (code.includes("registration-token-not-registered") || code.includes("invalid-argument")) {
            invalidTokens.push(tokens[idx]);
          }
        }
      });

      if (invalidTokens.length > 0) {
        const batch = db.batch();
        invalidTokens.forEach((token) => {
          const ref = db.collection("users").doc(targetUserId).collection("fcmTokens").doc(token);
          batch.delete(ref);
        });
        await batch.commit();
      }
    }
    return {
      ok: result.successCount > 0,
      reason: result.successCount > 0 ? "sent" : "all_failed",
      tokenCount: tokens.length,
      successCount: result.successCount,
      failureCount: result.failureCount,
      invalidTokens,
      errorCodes: Array.from(new Set(errorCodes)).slice(0, 10),
    };
  } catch (e) {
    console.error("[CF] sendPushToUser failed:", e);
    return {
      ok: false,
      reason: "exception",
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
      invalidTokens: [],
      error: _truncateText(String(e && e.message ? e.message : e), 500),
    };
  }
}

exports.onUserFcmTokenWriteEnforceSingleOwner = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore.document("users/{uid}/fcmTokens/{tokenId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists) return null;
    const ownerUid = context.params.uid;
    const tokenId = context.params.tokenId || "";
    const tokenDoc = change.after.data() || {};
    const token = String(tokenDoc.token || tokenId || "").trim();
    if (!token || token.length < 20) return null;

    try {
      const dupSnap = await db
        .collectionGroup("fcmTokens")
        .where("token", "==", token)
        .get();
      if (dupSnap.empty) return null;

      let batch = db.batch();
      let batchCount = 0;
      const commits = [];
      for (const doc of dupSnap.docs) {
        const parent = doc.ref.parent.parent;
        const uid = parent && parent.id ? parent.id : "";
        if (!uid || uid === ownerUid) continue;
        batch.delete(doc.ref);
        batchCount += 1;
        if (batchCount >= 400) {
          commits.push(batch.commit());
          batch = db.batch();
          batchCount = 0;
        }
      }
      if (batchCount > 0) commits.push(batch.commit());
      if (commits.length > 0) await Promise.all(commits);
      return null;
    } catch (e) {
      console.error(`[CF][fcm_token_dedupe] owner=${ownerUid} failed:`, e);
      return null;
    }
  });

function _sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function _seoulDateParts(date = new Date()) {
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const parts = formatter.formatToParts(date);
  const year = parts.find((p) => p.type === "year")?.value || "";
  const month = parts.find((p) => p.type === "month")?.value || "";
  const day = parts.find((p) => p.type === "day")?.value || "";
  const dateKey = `${year}-${month}-${day}`;
  return { year, month, day, dateKey };
}

function _normalizeSlotList(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((v) => String(v || "").trim())
    .filter((v) => !!v);
}

function _inferCompletedSlotsFromLegacy(meals, completedRecipes) {
  const legacyIds = _normalizeSlotList(completedRecipes);
  if (legacyIds.length === 0) return [];

  const inferred = [];
  for (const mealType of ["breakfast", "lunch", "dinner"]) {
    const list = Array.isArray(meals[mealType]) ? meals[mealType] : [];
    for (let i = 0; i < list.length; i += 1) {
      const recipeId = String(list[i] || "").trim();
      if (!recipeId) continue;
      const idx = legacyIds.indexOf(recipeId);
      if (idx !== -1) {
        inferred.push(`${mealType}_${i}`);
        legacyIds.splice(idx, 1);
      }
    }
  }
  return inferred;
}

function _mealReminderCopy(mealType, recipeTitles) {
  const mealNames = {
    breakfast: "아침",
    lunch: "점심",
    dinner: "저녁",
  };
  const mealName = mealNames[mealType] || "식사";
  const first = _sanitizeText(recipeTitles[0]) || "오늘의 레시피";
  if (recipeTitles.length <= 1) {
    return {
      title: `${mealName} 요리할 시간이에요`,
      body: `오늘 ${mealName}은 ${first}! 지금 시작하면 딱 좋아요.`,
    };
  }
  return {
    title: `${mealName} 준비, 지금 시작해볼까요?`,
    body: `오늘 ${mealName}에 ${first} 외 ${recipeTitles.length - 1}개가 기다리고 있어요.`,
  };
}

const _MEAL_PLAN_MEAL_TYPES = new Set(["breakfast", "lunch", "dinner"]);

/**
 * @param {string} targetUserId
 * @param {string} mealType
 * @param {string[]} pendingTitles
 * @param {string} targetRecipeId
 * @param {string} eventKey
 */
async function _sendMealPlanReminderToUser({
  targetUserId,
  mealType,
  pendingTitles,
  targetRecipeId,
  eventKey,
}) {
  if (!targetUserId || !_MEAL_PLAN_MEAL_TYPES.has(mealType) || pendingTitles.length === 0) {
    return { sent: false, reason: "invalid_input" };
  }

  const copy = _mealReminderCopy(mealType, pendingTitles);
  const notificationId = await createNotificationOnce({
    targetUserId,
    type: `meal_plan_${mealType}_reminder`,
    actorId: "system",
    actorName: "요리고",
    recipeId: targetRecipeId || "",
    message: copy.body,
    title: copy.title,
    eventKey,
  });
  if (!notificationId) {
    return { sent: false, reason: "deduped" };
  }

  const pushResult = await sendPushToUser(targetUserId, {
    type: `meal_plan_${mealType}_reminder`,
    title: copy.title,
    body: copy.body,
    recipeId: targetRecipeId || "",
    actorId: "system",
  });

  return {
    sent: true,
    notificationId,
    pushOk: !!pushResult.ok,
    pushResult,
  };
}

/**
 * @param {string} uid
 * @returns {Promise<{ recipeId: string, title: string }|null>}
 */
async function _pickRandomRecipeForUser(uid) {
  const userSnap = await db.collection("users").doc(uid).get();
  const savedRaw = userSnap.exists ? userSnap.data()?.savedRecipes : null;
  const savedIds = Array.isArray(savedRaw)
    ? savedRaw.map((v) => String(v || "").trim()).filter((v) => !!v)
    : [];

  if (savedIds.length > 0) {
    const shuffled = savedIds.sort(() => Math.random() - 0.5);
    for (const recipeId of shuffled) {
      const recipeSnap = await db.collection("recipes").doc(recipeId).get();
      if (!recipeSnap.exists) continue;
      const data = recipeSnap.data() || {};
      const title = _sanitizeText(data.title || data.name || data.recipeName);
      if (title) return { recipeId, title };
    }
  }

  const publicSnap = await db
    .collection("recipes")
    .where("status", "==", "completed")
    .where("isHidden", "==", false)
    .limit(50)
    .get();
  if (publicSnap.empty) return null;

  const docs = publicSnap.docs.sort(() => Math.random() - 0.5);
  for (const doc of docs) {
    const data = doc.data() || {};
    const title = _sanitizeText(data.title || data.name || data.recipeName);
    if (title) return { recipeId: doc.id, title };
  }
  return null;
}

/**
 * @param {string} uid
 * @param {string} dateKey
 * @param {string} mealType
 * @param {string} recipeId
 * @param {string} recipeTitle
 */
async function _upsertAdminTestMealPlanSlot(uid, dateKey, mealType, recipeId, recipeTitle) {
  const ref = db.collection("users").doc(uid).collection("mealPlans").doc(dateKey);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() || {} : {};
    const meals =
      data && typeof data.meals === "object" && data.meals ? { ...data.meals } : {};
    meals[mealType] = [recipeId];

    const recipeTitles =
      data && typeof data.recipeTitles === "object" && data.recipeTitles
        ? { ...data.recipeTitles }
        : {};
    recipeTitles[recipeId] = recipeTitle;

    const startedSlots = _normalizeSlotList(data.startedSlots).filter(
      (slotId) => !slotId.startsWith(`${mealType}_`)
    );
    const completedSlots = _normalizeSlotList(data.completedSlots).filter(
      (slotId) => !slotId.startsWith(`${mealType}_`)
    );

    const payload = {
      dateKey,
      meals,
      recipeTitles,
      startedSlots,
      completedSlots,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      adminTestMealReminderAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (!snap.exists) {
      payload.createdAt = admin.firestore.FieldValue.serverTimestamp();
    }
    tx.set(ref, payload, { merge: true });
  });
}

async function sendMealPlanReminderForMealType(mealType) {
  const { dateKey } = _seoulDateParts();
  const snap = await db.collectionGroup("mealPlans").where("dateKey", "==", dateKey).get();
  if (snap.empty) {
    console.log(`[CF][meal_reminder] ${mealType} ${dateKey}: no meal plans`);
    return { scanned: 0, sent: 0 };
  }

  let sent = 0;
  let scanned = 0;
  for (const doc of snap.docs) {
    scanned += 1;
    const userRef = doc.ref.parent.parent;
    const targetUserId = userRef ? userRef.id : "";
    if (!targetUserId) continue;

    const data = doc.data() || {};
    const meals = data && typeof data.meals === "object" && data.meals ? data.meals : {};
    const mealRecipesRaw = Array.isArray(meals[mealType]) ? meals[mealType] : [];
    const mealRecipes = mealRecipesRaw
      .map((v) => String(v || "").trim())
      .filter((v) => !!v);
    if (mealRecipes.length === 0) continue;

    const startedSlots = new Set(_normalizeSlotList(data.startedSlots));
    let completedSlots = _normalizeSlotList(data.completedSlots);
    if (completedSlots.length === 0) {
      completedSlots = _inferCompletedSlotsFromLegacy(meals, data.completedRecipes);
    }
    const completedSlotSet = new Set(completedSlots);

    const recipeTitlesMap =
      data && typeof data.recipeTitles === "object" && data.recipeTitles
        ? data.recipeTitles
        : {};
    const pendingTitles = [];
    const pendingRecipeIds = [];

    for (let i = 0; i < mealRecipes.length; i += 1) {
      const slotId = `${mealType}_${i}`;
      if (startedSlots.has(slotId) || completedSlotSet.has(slotId)) continue;
      const recipeId = mealRecipes[i];
      pendingRecipeIds.push(recipeId);
      pendingTitles.push(_sanitizeText(recipeTitlesMap[recipeId]) || "레시피");
    }

    if (pendingTitles.length === 0) continue;
    const targetRecipeId = pendingRecipeIds[0] || "";

    const eventKey = `meal_plan_reminder:${mealType}:${dateKey}`;
    const result = await _sendMealPlanReminderToUser({
      targetUserId,
      mealType,
      pendingTitles,
      targetRecipeId,
      eventKey,
    });
    if (result.sent) sent += 1;
  }

  console.log(`[CF][meal_reminder] ${mealType} ${dateKey}: scanned=${scanned}, sent=${sent}`);
  return { scanned, sent };
}

exports.sendBreakfastMealPlanReminder = functions
  .pubsub.schedule("0 8 * * *")
  .timeZone("Asia/Seoul")
  .onRun(async () => {
    try {
      return await sendMealPlanReminderForMealType("breakfast");
    } catch (e) {
      console.error("[CF][meal_reminder] breakfast failed:", e);
      throw e;
    }
  });

exports.sendLunchMealPlanReminder = functions
  .pubsub.schedule("30 11 * * *")
  .timeZone("Asia/Seoul")
  .onRun(async () => {
    try {
      return await sendMealPlanReminderForMealType("lunch");
    } catch (e) {
      console.error("[CF][meal_reminder] lunch failed:", e);
      throw e;
    }
  });

exports.sendDinnerMealPlanReminder = functions
  .pubsub.schedule("0 17 * * *")
  .timeZone("Asia/Seoul")
  .onRun(async () => {
    try {
      return await sendMealPlanReminderForMealType("dinner");
    } catch (e) {
      console.error("[CF][meal_reminder] dinner failed:", e);
      throw e;
    }
  });

const {
  startOfKstDay,
  ymdKey,
  isKstSunday,
  extractAttendanceDayKeysFromUserData,
  computeDailyAttendanceStreakAtRisk,
  computeWeekAttendance,
  shortenReminderLabel,
  extractFridgeIngredientNames,
  extractFridgeRecipeTitle,
  buildDailyStreakReminderMessage,
  buildWeeklyStreakReminderMessage,
  shouldSendWeeklyStreakReminder,
} = streakReminders;

/**
 * 전역 트렌딩 레시피 제목 1개. 잡 시작 시 한 번만 읽고 공유.
 * @returns {Promise<string>}
 */
async function _loadSharedTrendingRecipeTitle() {
  try {
    const sectionKeys = ['moment_dinner', 'quick_10min', 'comfort_bowl'];
    for (const sectionKey of sectionKeys) {
      const indexSnap = await db.collection('home_section_index').doc(sectionKey).get();
      if (!indexSnap.exists) continue;
      const rawIds = indexSnap.data()?.recipeIds;
      if (!Array.isArray(rawIds) || rawIds.length === 0) continue;
      for (const rawId of rawIds.slice(0, 8)) {
        const recipeId = String(rawId || '').trim();
        if (!recipeId) continue;
        const recipeSnap = await db.collection('recipes').doc(recipeId).get();
        if (!recipeSnap.exists) continue;
        const data = recipeSnap.data() || {};
        if (!_isVisibleCompletedRecipe(data)) continue;
        const title = shortenReminderLabel(
          data.title || data.name || data.recipeName || ''
        );
        if (title) return title;
      }
    }
  } catch (e) {
    console.warn('[CF][daily_streak_reminder] shared trending title failed:', e);
  }
  return '';
}

/**
 * @param {string} uid
 * @param {string} dayKey
 * @param {{ trendingTitle?: string }=} shared
 * @param {object=} preFetchedUserData - 호출자가 이미 users/{uid}를 읽었다면 재조회를 생략.
 * @param {string[]=} preFetchedTokens - collectionGroup('fcmTokens') 결과를 재사용해 조회 생략.
 * @returns {Promise<{sent: boolean, skipped: boolean, pushOk: boolean, reason?: string}>}
 */
async function _sendDailyStreakReminderToUser(uid, dayKey, shared = {}, preFetchedUserData = null, preFetchedTokens = null) {
  const userData = preFetchedUserData || (await db.collection('users').doc(uid).get()).data() || {};

  // 비용: attendanceDays만 사용 (유저별 activeUsers 쿼리 제거).
  // 앱 open 시 updateLastAccessed가 attendanceDays를 기록한다.
  const dayKeys = extractAttendanceDayKeysFromUserData(userData);
  if (dayKeys.has(dayKey)) {
    return { sent: false, skipped: true, pushOk: false, reason: 'already_attended_today' };
  }

  const { streakDays, hasTodayAttendance } = computeDailyAttendanceStreakAtRisk(
    dayKeys
  );
  if (hasTodayAttendance) {
    return { sent: false, skipped: true, pushOk: false, reason: 'already_attended_today' };
  }

  const fridgeIngredients = extractFridgeIngredientNames(userData);
  const recipeTitle = extractFridgeRecipeTitle(userData);
  const body = buildDailyStreakReminderMessage({
    dayKey,
    uid,
    streakDays,
    fridgeIngredients,
    recipeTitle,
    trendingTitle: shared.trendingTitle || '',
  });

  const eventKey = "daily_streak_reminder:" + dayKey;
  const notificationId = await createNotificationOnce({
    targetUserId: uid,
    type: 'daily_streak_reminder',
    actorId: 'system',
    actorName: '요리고',
    message: body,
    title: '출석 알림',
    eventKey,
    screen: 'streak_calendar',
  });
  if (!notificationId) {
    return { sent: false, skipped: true, pushOk: false, reason: 'already_sent_today' };
  }

  const pushResult = await sendPushToUser(
    uid,
    {
      type: 'daily_streak_reminder',
      title: '출석 알림',
      body,
      screen: 'streak_calendar',
    },
    { tokens: preFetchedTokens || undefined }
  );

  return {
    sent: true,
    skipped: false,
    pushOk: !!pushResult.ok,
    reason: pushResult.ok ? 'sent' : ("push_" + (pushResult.reason || "failed")),
  };
}

/**
 * @param {string} uid
 * @param {string} weekStartKey
 * @param {object=} preFetchedUserData - 호출자가 이미 users/{uid}를 읽었다면 재조회를 생략.
 * @param {string[]=} preFetchedTokens - collectionGroup('fcmTokens') 결과를 재사용해 조회 생략.
 * @returns {Promise<{sent: boolean, skipped: boolean, pushOk: boolean, reason?: string}>}
 */
async function _sendWeeklyStreakReminderToUser(uid, weekStartKey, preFetchedUserData = null, preFetchedTokens = null) {
  const userData = preFetchedUserData || (await db.collection('users').doc(uid).get()).data() || {};
  const dayKeys = extractAttendanceDayKeysFromUserData(userData);
  const week = computeWeekAttendance(dayKeys);
  if (week.weekStartKey !== weekStartKey) {
    // 방어: 호출 시점과 주키가 어긋나면 스킵
    return { sent: false, skipped: true, pushOk: false, reason: 'week_key_mismatch' };
  }
  if (!shouldSendWeeklyStreakReminder(week)) {
    return {
      sent: false,
      skipped: true,
      pushOk: false,
      reason: week.hasTodayAttendance ? 'already_attended_today' : 'no_week_attendance',
    };
  }

  const body = buildWeeklyStreakReminderMessage({
    weekStartKey,
    uid,
    attendedDaysThisWeek: week.attendedDaysThisWeek,
  });

  const eventKey = "weekly_streak_reminder:" + weekStartKey;
  const notificationId = await createNotificationOnce({
    targetUserId: uid,
    type: 'weekly_streak_reminder',
    actorId: 'system',
    actorName: '요리고',
    message: body,
    title: '주간 출석 알림',
    eventKey,
    screen: 'streak_calendar',
  });
  if (!notificationId) {
    return { sent: false, skipped: true, pushOk: false, reason: 'already_sent_this_week' };
  }

  const pushResult = await sendPushToUser(
    uid,
    {
      type: 'weekly_streak_reminder',
      title: '주간 출석 알림',
      body,
      screen: 'streak_calendar',
    },
    { tokens: preFetchedTokens || undefined }
  );

  return {
    sent: true,
    skipped: false,
    pushOk: !!pushResult.ok,
    reason: pushResult.ok ? 'sent' : ("push_" + (pushResult.reason || "failed")),
  };
}

exports.sendDailyWeeklyStreakReminders = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .pubsub.schedule('every day 18:00')
  .timeZone('Asia/Seoul')
  .onRun(async () => {
    const now = new Date();
    const dayKey = ymdKey(startOfKstDay(now));
    const weekStartKey = ymdKey(streakReminders.startOfKstWeekSunday(now));
    const runWeekly = isKstSunday(now);
    try {
      // 푸시 가능한 유저만 대상. 전체 users 스캔보다 fcmTokens가 맞고 싸다.
      const tokenSnap = await db.collectionGroup('fcmTokens').get();
      // uid별 토큰을 미리 모아둔다. daily/weekly 발송 시 fcmTokens 서브컬렉션을
      // 각각 다시 조회하지 않고 이 맵을 재사용한다 (일요일 기준 유저당 read 2회 → 0회 절감).
      const tokensByUid = new Map();
      tokenSnap.docs.forEach((doc) => {
        const userRef = doc.ref.parent.parent;
        if (userRef && userRef.id) {
          if (!tokensByUid.has(userRef.id)) tokensByUid.set(userRef.id, []);
          tokensByUid.get(userRef.id).push(doc.id);
        }
      });

      const uids = Array.from(tokensByUid.keys());
      if (uids.length === 0) {
        console.log('[CF][streak_reminder] No target users');
        return {
          dayKey,
          weekStartKey,
          runWeekly,
          daily: { sent: 0, skipped: 0, failed: 0, pushOk: 0, pushFailed: 0 },
          weekly: { sent: 0, skipped: 0, failed: 0, pushOk: 0, pushFailed: 0 },
        };
      }

      const trendingTitle = await _loadSharedTrendingRecipeTitle();
      const shared = { trendingTitle };

      const daily = { sent: 0, skipped: 0, failed: 0, pushOk: 0, pushFailed: 0 };
      const weekly = { sent: 0, skipped: 0, failed: 0, pushOk: 0, pushFailed: 0 };

      const chunkSize = 25;
      for (let i = 0; i < uids.length; i += chunkSize) {
        const chunk = uids.slice(i, i + chunkSize);
        const results = await Promise.all(
          chunk.map(async (uid) => {
            try {
              // users/{uid}는 daily/weekly에서 공통으로 필요 → 여기서 한 번만 읽어 공유한다.
              const userSnap = await db.collection('users').doc(uid).get();
              const userData = userSnap.data() || {};
              const tokens = tokensByUid.get(uid) || [];

              const dailyResult = await _sendDailyStreakReminderToUser(
                uid,
                dayKey,
                shared,
                userData,
                tokens
              );
              let weeklyResult = {
                sent: false,
                skipped: true,
                pushOk: false,
                reason: 'not_sunday',
              };
              if (runWeekly) {
                weeklyResult = await _sendWeeklyStreakReminderToUser(
                  uid,
                  weekStartKey,
                  userData,
                  tokens
                );
              }
              return { dailyResult, weeklyResult };
            } catch (e) {
              console.error("[CF][streak_reminder] user " + uid + " failed:", e);
              return {
                dailyResult: {
                  sent: false,
                  skipped: false,
                  pushOk: false,
                  reason: 'failed',
                },
                weeklyResult: {
                  sent: false,
                  skipped: false,
                  pushOk: false,
                  reason: 'failed',
                },
              };
            }
          })
        );

        results.forEach(({ dailyResult, weeklyResult }) => {
          if (dailyResult.sent) {
            daily.sent += 1;
            if (dailyResult.pushOk) daily.pushOk += 1;
            else daily.pushFailed += 1;
          } else if (dailyResult.skipped) daily.skipped += 1;
          else daily.failed += 1;

          if (!runWeekly) return;
          if (weeklyResult.sent) {
            weekly.sent += 1;
            if (weeklyResult.pushOk) weekly.pushOk += 1;
            else weekly.pushFailed += 1;
          } else if (weeklyResult.skipped) weekly.skipped += 1;
          else weekly.failed += 1;
        });
      }

      console.log(
        "[CF][streak_reminder] done day=" +
          dayKey +
          " weekly=" +
          runWeekly +
          " daily(sent=" +
          daily.sent +
          ",pushOk=" +
          daily.pushOk +
          ",pushFailed=" +
          daily.pushFailed +
          ",skipped=" +
          daily.skipped +
          ",failed=" +
          daily.failed +
          ") weekly(sent=" +
          weekly.sent +
          ",pushOk=" +
          weekly.pushOk +
          ",pushFailed=" +
          weekly.pushFailed +
          ",skipped=" +
          weekly.skipped +
          ",failed=" +
          weekly.failed +
          ") trending=" +
          (trendingTitle || "-")
      );
      return { dayKey, weekStartKey, runWeekly, daily, weekly, trendingTitle };
    } catch (e) {
      console.error('[CF][streak_reminder] job failed:', e);
      throw e;
    }
  });

exports.onReviewLikeNotification = functions
  .firestore
  .document("reviews/{reviewId}")
  .onUpdate(async (change, context) => {
    try {
      const before = change.before.data() || {};
      const after = change.after.data() || {};

      const beforeLikedBy = Array.isArray(before.likedBy) ? before.likedBy : [];
      const afterLikedBy = Array.isArray(after.likedBy) ? after.likedBy : [];
      if (afterLikedBy.length <= beforeLikedBy.length) return;

      const newLikers = afterLikedBy.filter((uid) => !beforeLikedBy.includes(uid));
      if (newLikers.length === 0) return;

      const targetUserId = _sanitizeText(after.userId);
      if (!targetUserId) return;

      const reviewId = context.params.reviewId;
      for (const actorId of newLikers) {
        if (!actorId || actorId === targetUserId) continue;
        const actor = await getUserSummary(actorId);
        const message = `${actor.name}님이 회원님의 리뷰를 좋아합니다.`;
        await createNotification({
          targetUserId,
          type: "review_like",
          actorId,
          actorName: actor.name,
          actorPhotoUrl: actor.photoUrl,
          reviewId,
          message,
          eventKey: `review_like:${reviewId}:${actorId}`,
        });
        await sendPushToUser(targetUserId, {
          type: "review_like",
          title: "새로운 좋아요",
          body: message,
          reviewId,
          actorId,
        });
      }
    } catch (e) {
      console.error("[CF] onReviewLikeNotification failed:", e);
    }
  });

exports.onCommentCreateNotification = functions
  .firestore
  .document("reviews/{reviewId}/comments/{commentId}")
  .onCreate(async (snap, context) => {
    try {
      const comment = snap.data() || {};
      const actorId = _sanitizeText(comment.userId);
      const reviewId = context.params.reviewId;
      const commentId = context.params.commentId;
      const parentCommentId = _sanitizeText(comment.parentCommentId);

      if (parentCommentId) {
        const parentCommentSnap = await db
          .collection("reviews")
          .doc(reviewId)
          .collection("comments")
          .doc(parentCommentId)
          .get();
        const parentComment = parentCommentSnap.data() || {};
        const parentOwnerId = _sanitizeText(parentComment.userId);
        if (!parentOwnerId || !actorId || actorId === parentOwnerId) return;

        const actor = await getUserSummary(actorId);
        const message = `${actor.name}님이 회원님의 댓글에 답글을 남겼습니다.`;
        await createNotification({
          targetUserId: parentOwnerId,
          type: "comment_reply",
          actorId,
          actorName: actor.name,
          actorPhotoUrl: actor.photoUrl,
          reviewId,
          commentId,
          message,
          eventKey: `comment_reply:${commentId}:${actorId}:${parentCommentId}`,
        });
        await sendPushToUser(parentOwnerId, {
          type: "comment_reply",
          title: "새로운 답글",
          body: message,
          reviewId,
          commentId,
          actorId,
        });
        return;
      }

      const reviewSnap = await db.collection("reviews").doc(reviewId).get();
      const review = reviewSnap.data() || {};
      const reviewOwnerId = _sanitizeText(review.userId);
      if (!reviewOwnerId || !actorId || actorId === reviewOwnerId) return;

      const actor = await getUserSummary(actorId);
      const message = `${actor.name}님이 회원님의 리뷰에 댓글을 남겼습니다.`;
      await createNotification({
        targetUserId: reviewOwnerId,
        type: "review_comment",
        actorId,
        actorName: actor.name,
        actorPhotoUrl: actor.photoUrl,
        reviewId,
        commentId,
        message,
        eventKey: `review_comment:${commentId}:${actorId}`,
      });
      await sendPushToUser(reviewOwnerId, {
        type: "review_comment",
        title: "새로운 댓글",
        body: message,
        reviewId,
        commentId,
        actorId,
      });
    } catch (e) {
      console.error("[CF] onCommentCreateNotification failed:", e);
    }
  });

exports.onReviewHiddenNotification = functions
  .firestore
  .document("reviews/{reviewId}")
  .onUpdate(async (change, context) => {
    try {
      const before = change.before.data() || {};
      const after = change.after.data() || {};
      const wasHidden = !!before.isHidden;
      const isHidden = !!after.isHidden;
      if (wasHidden || !isHidden) return;

      const targetUserId = _sanitizeText(after.userId);
      if (!targetUserId) return;

      const message = "회원님의 리뷰가 운영 정책에 따라 숨김 처리되었습니다.";
      await createNotification({
        targetUserId,
        type: "review_hidden",
        actorId: "system",
        actorName: "요리고 운영팀",
        reviewId: context.params.reviewId,
        message,
        eventKey: `review_hidden:${context.params.reviewId}`,
      });
      await sendPushToUser(targetUserId, {
        type: "review_hidden",
        title: "리뷰 숨김 안내",
        body: message,
        reviewId: context.params.reviewId,
        actorId: "system",
      });
    } catch (e) {
      console.error("[CF] onReviewHiddenNotification failed:", e);
    }
  });

exports.onCommentHiddenNotification = functions
  .firestore
  .document("reviews/{reviewId}/comments/{commentId}")
  .onUpdate(async (change, context) => {
    try {
      const before = change.before.data() || {};
      const after = change.after.data() || {};
      const wasHidden = !!before.isHidden;
      const isHidden = !!after.isHidden;
      if (wasHidden || !isHidden) return;

      const targetUserId = _sanitizeText(after.userId);
      if (!targetUserId) return;

      const reviewId = context.params.reviewId;
      const commentId = context.params.commentId;
      const message = "회원님의 댓글이 운영 정책에 따라 숨김 처리되었습니다.";
      await createNotification({
        targetUserId,
        type: "comment_hidden",
        actorId: "system",
        actorName: "요리고 운영팀",
        reviewId,
        commentId,
        message,
        eventKey: `comment_hidden:${commentId}`,
      });
      await sendPushToUser(targetUserId, {
        type: "comment_hidden",
        title: "댓글 숨김 안내",
        body: message,
        reviewId,
        commentId,
        actorId: "system",
      });
    } catch (e) {
      console.error("[CF] onCommentHiddenNotification failed:", e);
    }
  });

exports.onReviewDeleteNotification = functions
  .firestore
  .document("reviews/{reviewId}")
  .onDelete(async (snap, context) => {
    try {
      const review = snap.data() || {};
      const targetUserId = _sanitizeText(review.userId);
      if (!targetUserId) return;
      // Skip self-deletes; only notify when admin/system removed the review.
      if (review.deletedBy === "self") return;

      const message = "회원님의 리뷰가 삭제 처리되었습니다.";
      await createNotification({
        targetUserId,
        type: "review_deleted",
        actorId: "system",
        actorName: "요리고 운영팀",
        reviewId: context.params.reviewId,
        message,
        eventKey: `review_deleted:${context.params.reviewId}`,
      });
      await sendPushToUser(targetUserId, {
        type: "review_deleted",
        title: "리뷰 삭제 안내",
        body: message,
        reviewId: context.params.reviewId,
        actorId: "system",
      });
    } catch (e) {
      console.error("[CF] onReviewDeleteNotification failed:", e);
    }
  });

exports.onCommentDeleteNotification = functions
  .firestore
  .document("reviews/{reviewId}/comments/{commentId}")
  .onDelete(async (snap, context) => {
    try {
      const comment = snap.data() || {};
      const targetUserId = _sanitizeText(comment.userId);
      if (!targetUserId) return;
      // Skip self-deletes; only notify when admin/system removed the comment.
      if (comment.deletedBy === "self") return;

      const reviewId = context.params.reviewId;
      const commentId = context.params.commentId;
      const message = "회원님의 댓글이 삭제 처리되었습니다.";
      await createNotification({
        targetUserId,
        type: "comment_deleted",
        actorId: "system",
        actorName: "요리고 운영팀",
        reviewId,
        commentId,
        message,
        eventKey: `comment_deleted:${commentId}`,
      });
      await sendPushToUser(targetUserId, {
        type: "comment_deleted",
        title: "댓글 삭제 안내",
        body: message,
        reviewId,
        commentId,
        actorId: "system",
      });
    } catch (e) {
      console.error("[CF] onCommentDeleteNotification failed:", e);
    }
  });

exports.onCommentLikeNotification = functions
  .firestore
  .document("reviews/{reviewId}/comments/{commentId}")
  .onUpdate(async (change, context) => {
    try {
      const before = change.before.data() || {};
      const after = change.after.data() || {};

      const beforeLikedBy = Array.isArray(before.likedBy) ? before.likedBy : [];
      const afterLikedBy = Array.isArray(after.likedBy) ? after.likedBy : [];
      if (afterLikedBy.length <= beforeLikedBy.length) return;

      const newLikers = afterLikedBy.filter((uid) => !beforeLikedBy.includes(uid));
      if (newLikers.length === 0) return;

      const targetUserId = _sanitizeText(after.userId);
      if (!targetUserId) return;

      const reviewId = context.params.reviewId;
      const commentId = context.params.commentId;
      for (const actorId of newLikers) {
        if (!actorId || actorId === targetUserId) continue;
        const actor = await getUserSummary(actorId);
        const message = `${actor.name}님이 회원님의 댓글을 좋아합니다.`;
        await createNotification({
          targetUserId,
          type: "comment_like",
          actorId,
          actorName: actor.name,
          actorPhotoUrl: actor.photoUrl,
          reviewId,
          commentId,
          message,
          eventKey: `comment_like:${commentId}:${actorId}`,
        });
        await sendPushToUser(targetUserId, {
          type: "comment_like",
          title: "새로운 좋아요",
          body: message,
          reviewId,
          commentId,
          actorId,
        });
      }
    } catch (e) {
      console.error("[CF] onCommentLikeNotification failed:", e);
    }
  });

exports.onFollowCreateNotification = functions
  .firestore
  .document("follows/{followId}")
  .onCreate(async (snap, context) => {
    try {
      const data = snap.data() || {};
      const actorId = _sanitizeText(data.followerId);
      const targetUserId = _sanitizeText(data.followingId);
      if (!actorId || !targetUserId || actorId === targetUserId) return;

      const actor = await getUserSummary(actorId);
      const message = `${actor.name}님이 회원님을 팔로우했습니다.`;
      await createNotification({
        targetUserId,
        type: "follow",
        actorId,
        actorName: actor.name,
        actorPhotoUrl: actor.photoUrl,
        message,
        eventKey: `follow:${context.params.followId}`,
      });
      await sendPushToUser(targetUserId, {
        type: "follow",
        title: "새로운 팔로워",
        body: message,
        actorId,
      });
    } catch (e) {
      console.error("[CF] onFollowCreateNotification failed:", e);
    }
  });

exports.onAdminMealReminderTestRequest = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore
  .document("users/{uid}/mealReminderTestRequests/{requestId}")
  .onCreate(async (snap, context) => {
    const uid = _sanitizeText(context.params.uid);
    const requestId = _sanitizeText(context.params.requestId);
    if (!uid || !requestId) return;

    try {
      const claimed = await db.runTransaction(async (tx) => {
        const ref = snap.ref;
        const cur = await tx.get(ref);
        if (!cur.exists) return false;
        const data = cur.data() || {};
        const status = _sanitizeText(data.status);
        if (status === "processing" || status === "sent") return false;
        tx.set(ref, {
          status: "processing",
          processingAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return true;
      });
      if (!claimed) return;

      const data = snap.data() || {};
      const mealType = _sanitizeText(data.mealType);
      if (!_MEAL_PLAN_MEAL_TYPES.has(mealType)) {
        await snap.ref.set({
          status: "failed",
          reason: "invalid_meal_type",
          failedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return;
      }

      const picked = await _pickRandomRecipeForUser(uid);
      if (!picked) {
        await snap.ref.set({
          status: "failed",
          reason: "no_recipe_available",
          failedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return;
      }

      const { dateKey } = _seoulDateParts();
      await _upsertAdminTestMealPlanSlot(
        uid,
        dateKey,
        mealType,
        picked.recipeId,
        picked.title
      );

      const eventKey = `meal_plan_reminder_test:${mealType}:${requestId}`;
      const reminderResult = await _sendMealPlanReminderToUser({
        targetUserId: uid,
        mealType,
        pendingTitles: [picked.title],
        targetRecipeId: picked.recipeId,
        eventKey,
      });

      if (!reminderResult.sent) {
        await snap.ref.set({
          status: "failed",
          reason: reminderResult.reason || "reminder_not_sent",
          recipeId: picked.recipeId,
          recipeTitle: picked.title,
          dateKey,
          mealType,
          failedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return;
      }

      await snap.ref.set({
        status: "sent",
        recipeId: picked.recipeId,
        recipeTitle: picked.title,
        dateKey,
        mealType,
        pushOk: !!reminderResult.pushOk,
        pushResult: reminderResult.pushResult || null,
        sentAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      console.log(
        `[CF][meal_reminder_test] uid=${uid} meal=${mealType} ` +
        `recipe=${picked.recipeId} pushOk=${!!reminderResult.pushOk}`
      );
    } catch (e) {
      console.error("[CF][meal_reminder_test] failed:", e);
      await snap.ref.set({
        status: "failed",
        error: _truncateText(String(e && e.message ? e.message : e), 500),
        failedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  });

exports.onAdminPushDebugRequest = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore
  .document("users/{uid}/pushDebugRequests/{requestId}")
  .onCreate(async (snap, context) => {
    const uid = _sanitizeText(context.params.uid);
    const requestId = _sanitizeText(context.params.requestId);
    if (!uid || !requestId) return;

    try {
      const claimed = await db.runTransaction(async (tx) => {
        const ref = snap.ref;
        const cur = await tx.get(ref);
        if (!cur.exists) return false;
        const data = cur.data() || {};
        const status = _sanitizeText(data.status);
        if (status === "processing" || status === "sent") return false;
        tx.set(ref, {
          status: "processing",
          processingAt: admin.firestore.FieldValue.serverTimestamp(),
          eventId: _sanitizeText(context.eventId),
        }, { merge: true });
        return true;
      });
      if (!claimed) return;

      const data = snap.data() || {};
      const delaySecondsRaw = Number(data.delaySeconds || 30);
      const delaySeconds = Number.isFinite(delaySecondsRaw)
        ? Math.min(120, Math.max(5, Math.trunc(delaySecondsRaw)))
        : 30;

      await _sleep(delaySeconds * 1000);

      const body = `요리고 관리자 푸시 테스트 알림입니다. (${delaySeconds}초 지연)`;

      const pushResult = await sendPushToUser(uid, {
        type: "admin_push_debug",
        title: "푸시 테스트",
        body,
      });

      if (!pushResult.ok) {
        await snap.ref.set({
          status: "failed",
          reason: pushResult.reason || "unknown",
          pushResult,
          failedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return;
      }

      await createNotification({
        targetUserId: uid,
        type: "admin_push_debug",
        actorId: "",
        actorName: "Yorigo 시스템",
        actorPhotoUrl: "",
        message: body,
        eventKey: `admin_push_debug:${requestId}`,
      });

      await snap.ref.set({
        status: "sent",
        pushResult,
        sentAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    } catch (e) {
      console.error("[CF] onAdminPushDebugRequest failed:", e);
      await snap.ref.set({
        status: "failed",
        error: _truncateText(String(e && e.message ? e.message : e), 500),
        failedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  });

const {
  getSystemBroadcast,
} = require("./systemBroadcasts");
const {
  runSystemAnnouncementBroadcast,
} = require("./systemAnnouncementRunner");

/**
 * @param {{ campaignId: string, type: string, title: string, body: string }} config
 * @param {string} uid
 * @returns {Promise<{ sent: boolean, skipped: boolean, pushOk: boolean, reason?: string }>}
 */
async function _sendOneTimeSystemAnnouncementToUser(config, uid) {
  const eventKey = `system_announcement:${config.campaignId}`;
  if (await _notificationWithEventKeyExists(uid, eventKey)) {
    return { sent: false, skipped: true, pushOk: false, reason: "already_sent" };
  }

  const notificationId = await createNotificationOnce({
    targetUserId: uid,
    type: config.type,
    actorId: "",
    actorName: "요리고",
    actorPhotoUrl: "",
    title: config.title,
    message: config.body,
    eventKey,
  });

  if (!notificationId) {
    return { sent: false, skipped: true, pushOk: false, reason: "already_sent" };
  }

  const pushResult = await sendPushToUser(uid, {
    type: config.type,
    title: config.title,
    body: config.body,
  });

  return {
    sent: true,
    skipped: false,
    pushOk: !!pushResult.ok,
    reason: pushResult.ok ? "sent" : pushResult.reason || "push_failed",
  };
}

/**
 * @param {{ campaignId: string, type: string, title: string, body: string }} config
 */
async function _broadcastSystemAnnouncementToAllUsers(config) {
  let sent = 0;
  let skipped = 0;
  let failed = 0;
  let processed = 0;
  let pushSent = 0;
  let lastDoc = null;
  const pageSize = 200;
  const chunkSize = 25;

  while (true) {
    let query = db
      .collection("users")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(pageSize);
    if (lastDoc) {
      query = query.startAfter(lastDoc);
    }

    const snap = await query.get();
    if (snap.empty) break;

    const uids = snap.docs.map((doc) => doc.id);
    for (let i = 0; i < uids.length; i += chunkSize) {
      const chunk = uids.slice(i, i + chunkSize);
      const results = await Promise.all(
        chunk.map(async (uid) => {
          try {
            return await _sendOneTimeSystemAnnouncementToUser(config, uid);
          } catch (e) {
            console.error(`[CF][system_announcement] user ${uid} failed:`, e);
            return { sent: false, skipped: false, pushOk: false, reason: "failed" };
          }
        })
      );

      results.forEach((result) => {
        processed += 1;
        if (result.sent) {
          sent += 1;
          if (result.pushOk) pushSent += 1;
        } else if (result.skipped) {
          skipped += 1;
        } else {
          failed += 1;
        }
      });
    }

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < pageSize) break;
  }

  return { sent, skipped, failed, processed, pushSent };
}

exports.onAdminBroadcastRequest = functions
  .runWith({ timeoutSeconds: 540, memory: "1GB" })
  .firestore.document("adminBroadcastRequests/{campaignId}")
  .onCreate(async (snap, context) => {
    const campaignId = _sanitizeText(context.params.campaignId);
    const data = snap.data() || {};
    const requestedBy = _sanitizeText(data.requestedBy);
    const status = _sanitizeText(data.status);

    if (!campaignId || status !== "queued") {
      await snap.ref.set({
        status: "failed",
        reason: "invalid_request",
        failedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
    }

    const broadcastConfig = getSystemBroadcast(campaignId);
    if (!broadcastConfig) {
      await snap.ref.set({
        status: "failed",
        reason: "unsupported_campaign",
        failedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
    }

    try {
      const claimed = await db.runTransaction(async (tx) => {
        const ref = snap.ref;
        const cur = await tx.get(ref);
        if (!cur.exists) return false;
        const curData = cur.data() || {};
        if (_sanitizeText(curData.status) !== "queued") return false;
        tx.set(ref, {
          status: "processing",
          processingAt: admin.firestore.FieldValue.serverTimestamp(),
          requestedBy,
        }, { merge: true });
        return true;
      });
      if (!claimed) return;

      const result = await runSystemAnnouncementBroadcast(
        db,
        admin.messaging(),
        admin.firestore.FieldValue,
        campaignId
      );

      await snap.ref.set({
        status: "completed",
        result,
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      console.log(
        `[CF][system_announcement] campaign=${campaignId} ` +
        `processed=${result.processed} sent=${result.sent} ` +
        `pushSent=${result.pushSent} skipped=${result.skipped} failed=${result.failed}`
      );
    } catch (e) {
      console.error("[CF][system_announcement] broadcast failed:", e);
      await snap.ref.set({
        status: "failed",
        error: _truncateText(String(e && e.message ? e.message : e), 500),
        failedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  });

exports.runSystemAnnouncementBroadcast = async function runSystemAnnouncementBroadcastExport(
  campaignId
) {
  return runSystemAnnouncementBroadcast(
    db,
    admin.messaging(),
    admin.firestore.FieldValue,
    campaignId
  );
};

function _truncateText(value, maxLen = 400) {
  const text = _sanitizeText(value);
  if (text.length <= maxLen) return text;
  return `${text.slice(0, maxLen)}...`;
}

async function createDeveloperModerationAlert({
  eventType,
  reviewId = "",
  commentId = "",
  reportId = "",
  reason = "",
  targetUserId = "",
  reporterId = "",
  payload = {},
}) {
  try {
    await db.collection("moderation_alerts").add({
      eventType: _sanitizeText(eventType),
      reviewId: _sanitizeText(reviewId),
      commentId: _sanitizeText(commentId),
      reportId: _sanitizeText(reportId),
      reason: _truncateText(reason, 500),
      targetUserId: _sanitizeText(targetUserId),
      reporterId: _sanitizeText(reporterId),
      payload: payload || {},
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    console.error("[CF] createDeveloperModerationAlert failed:", e);
  }
}

async function runReviewCookingValidationLLM({
  reviewId,
  comment,
  imageUrl,
  recipeTitle,
}) {
  const apiKey = _sanitizeText(process.env.OPENAI_API_KEY);
  if (!apiKey) {
    return {
      skipped: true,
      verdict: "unknown",
      confidence: 0,
      reason: "OPENAI_API_KEY not configured",
      model: "",
      usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0 },
    };
  }

  const model = _sanitizeText(process.env.REVIEW_MODERATION_MODEL) || "gpt-4o-mini";
  const timeoutMsRaw = Number.parseInt(process.env.REVIEW_MODERATION_TIMEOUT_MS || "12000", 10);
  const timeoutMs = Number.isFinite(timeoutMsRaw) ? Math.max(3000, timeoutMsRaw) : 12000;

  const prompt = [
    "You are validating whether a user review post belongs to a cooking community.",
    "Be lenient and allow normal food/cooking/kitchen/dining images and text.",
    "Reject only clearly strange or unrelated uploads (e.g., random selfies, pets, cars, violence, explicit sexual content, spam ads, totally non-food scenes).",
    "Return strict JSON only with keys: verdict, confidence, reason.",
    "verdict must be one of: accepted, rejected, uncertain.",
  ].join("\n");

  const textPayload = [
    `reviewId: ${reviewId || ""}`,
    `recipeTitle: ${_truncateText(recipeTitle, 150)}`,
    `comment: ${_truncateText(comment, 700)}`,
    `hasImageUrl: ${imageUrl ? "yes" : "no"}`,
  ].join("\n");

  const userContent = [{ type: "text", text: textPayload }];
  if (imageUrl) {
    userContent.push({
      type: "image_url",
      image_url: { url: imageUrl, detail: "low" },
    });
  }

  const body = {
    model,
    temperature: 0,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: prompt },
      { role: "user", content: userContent },
    ],
  };

  const abortController = new AbortController();
  const timer = setTimeout(() => abortController.abort(), timeoutMs);

  try {
    const resp = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
      signal: abortController.signal,
    });

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`openai_status_${resp.status}: ${_truncateText(errText, 600)}`);
    }

    const json = await resp.json();
    const content = json?.choices?.[0]?.message?.content;
    const parsed = JSON.parse(content || "{}");
    const verdictRaw = _sanitizeText(parsed.verdict).toLowerCase();
    const verdict =
      verdictRaw === "accepted" || verdictRaw === "rejected" || verdictRaw === "uncertain"
        ? verdictRaw
        : "uncertain";
    const confidenceNum = Number(parsed.confidence);
    const confidence = Number.isFinite(confidenceNum)
      ? Math.max(0, Math.min(1, confidenceNum))
      : 0;
    const reason = _truncateText(parsed.reason || "no reason", 500);
    const usageRaw = json?.usage || {};

    return {
      skipped: false,
      verdict,
      confidence,
      reason,
      model,
      usage: {
        inputTokens: Number(usageRaw.prompt_tokens || 0),
        outputTokens: Number(usageRaw.completion_tokens || 0),
        totalTokens: Number(usageRaw.total_tokens || 0),
      },
    };
  } finally {
    clearTimeout(timer);
  }
}

exports.onReportCreateAutoModeration = functions
  .firestore
  .document("reports/{reportId}")
  .onCreate(async (snap, context) => {
    const reportId = context.params.reportId;
    const report = snap.data() || {};

    try {
      const type = _sanitizeText(report.type);
      const targetId = _sanitizeText(report.targetId);
      const reviewId = _sanitizeText(report.reviewId);
      const reporterId = _sanitizeText(report.reporterId);
      const reason = _sanitizeText(report.reason);
      const description = _sanitizeText(report.description);
      const targetUrl = _sanitizeText(report.targetUrl);
      const reporterEmail = _sanitizeText(report.reporterEmail);

      if (!type) return;
      // recipe_url 신고는 URL 자체가 식별자라 targetId 가 비어 있을 수 있음.
      if (!targetId && type !== "recipe_url") return;

      // 자동 모더레이션 비활성화 (Option A):
      // - 대상 게시물 자동 숨김 X
      // - 신고 상태 자동 'resolved' 덮어쓰기 X
      // 신고는 클라이언트가 생성한 'pending' 상태 그대로 두고, 관리자가
      // /admin-reports 화면에서 직접 검토/처리한다. (대시보드 알림만 발송)
      let targetUserId = "";
      let resolvedReviewId = reviewId;

      if (type === "review") {
        resolvedReviewId = targetId;
        const targetSnap = await db.collection("reviews").doc(targetId).get();
        if (targetSnap.exists) {
          targetUserId = _sanitizeText((targetSnap.data() || {}).userId);
        }
      } else if (type === "comment") {
        if (!reviewId) {
          throw new Error("missing reviewId for comment report");
        }
        const targetSnap = await db
          .collection("reviews").doc(reviewId)
          .collection("comments").doc(targetId)
          .get();
        if (targetSnap.exists) {
          targetUserId = _sanitizeText((targetSnap.data() || {}).userId);
        }
      } else if (type === "recipe") {
        const targetSnap = await db.collection("recipes").doc(targetId).get();
        if (targetSnap.exists) {
          targetUserId = _sanitizeText((targetSnap.data() || {}).userId);
        }
      } else if (type === "recipe_url") {
        // URL 기반 신고: 대상 사용자 자동 매칭 X (admin 이 URL 로 카드 검색).
        targetUserId = "";
      } else {
        throw new Error(`unsupported report type: ${type}`);
      }

      await createDeveloperModerationAlert({
        eventType: "report_created",
        reviewId: resolvedReviewId,
        commentId: type === "comment" ? targetId : "",
        reportId,
        reason: `${reason} ${description}`.trim(),
        targetUserId,
        reporterId,
        payload: {
          type,
          targetId,
          reviewId: resolvedReviewId,
          reason,
          description,
          targetUrl,
          reporterEmail,
        },
      });
    } catch (e) {
      console.error("[CF] onReportCreateAutoModeration failed:", e);
    }
  });

exports.onReviewCreateLLMModeration = functions
  .firestore
  .document("reviews/{reviewId}")
  .onCreate(async (snap, context) => {
    const reviewId = context.params.reviewId;
    const review = snap.data() || {};

    try {
      if (review.isHidden === true) return;

      const comment = _sanitizeText(review.comment);
      const recipeTitle = _sanitizeText(review.recipeTitle);
      const photoUrl = _sanitizeText(review.photoUrl);
      const photoUrls = Array.isArray(review.photoUrls) ? review.photoUrls : [];
      const fallbackImage = photoUrls
        .map((v) => _sanitizeText(v))
        .find((v) => !!v);
      const imageUrl = photoUrl || fallbackImage || "";

      const llm = await runReviewCookingValidationLLM({
        reviewId,
        comment,
        imageUrl,
        recipeTitle,
      });

      const autoHideEligible =
        !llm.skipped && llm.verdict === "rejected" && llm.confidence >= 0.45;
      const usage = llm.usage || { inputTokens: 0, outputTokens: 0, totalTokens: 0 };
      trackMixpanelEvent(
        _sanitizeText(review.userId) || reviewId,
        "llm_review_moderation",
        {
          review_id: reviewId,
          skipped: !!llm.skipped,
          verdict: llm.verdict,
          confidence: llm.confidence,
          model: llm.model,
          has_image: !!imageUrl,
          auto_hidden: autoHideEligible,
          llm_input_tokens: usage.inputTokens,
          llm_output_tokens: usage.outputTokens,
          llm_total_tokens: usage.totalTokens,
        }
      ).catch(() => {});

      const moderationMeta = {
        verdict: llm.verdict,
        confidence: llm.confidence,
        reason: llm.reason,
        model: llm.model,
        checkedAt: admin.firestore.FieldValue.serverTimestamp(),
        skipped: !!llm.skipped,
      };

      // auto-hide only for confident rejection; uncertain stays visible.
      if (autoHideEligible) {
        await snap.ref.update({
          isHidden: true,
          hiddenAt: admin.firestore.FieldValue.serverTimestamp(),
          hiddenReason: "auto_llm_non_cooking",
          hiddenBy: "auto_llm",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          llmModeration: moderationMeta,
        });

        await createDeveloperModerationAlert({
          eventType: "llm_auto_hidden",
          reviewId,
          reason: llm.reason,
          targetUserId: _sanitizeText(review.userId),
          payload: {
            confidence: llm.confidence,
            verdict: llm.verdict,
            model: llm.model,
            hasImage: !!imageUrl,
            commentPreview: _truncateText(comment, 300),
          },
        });
      } else {
        await snap.ref.set(
          {
            llmModeration: moderationMeta,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
    } catch (e) {
      console.error("[CF] onReviewCreateLLMModeration failed:", e);
      try {
        await snap.ref.set(
          {
            llmModeration: {
              verdict: "error",
              confidence: 0,
              reason: _truncateText(e?.message || String(e), 500),
              checkedAt: admin.firestore.FieldValue.serverTimestamp(),
              skipped: true,
            },
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      } catch (inner) {
        console.error("[CF] onReviewCreateLLMModeration error write failed:", inner);
      }
    }
  });

/**
 * 레시피 문서가 생기거나 갱신될 때 YouTube면 `thumbnailUrlCropped` 를 서버에서 보장합니다.
 * - 동일 소스 URL에 이미 크롭이 있으면 재실행(무한 루프)을 건너뜁니다.
 * - Blaze 요금제 + 외부 URL fetch(YouTube 썸네일)에 Functions 네트워크 권한이 필요합니다.
 */
exports.onRecipeWriteEnsureYoutubeCroppedThumbnail = functions
  .runWith({ timeoutSeconds: 120, memory: "512MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;
    const recipeId = context.params.recipeId;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.data() || {};

    try {
      if (_shouldSkipCroppedWork(before, after)) return;
      const result = await ensureYoutubeCroppedThumbnailForRecipe(recipeId, after);
      if (result.status && result.status !== "updated" && result.status !== "skipped_not_youtube") {
        console.log(`[CF][recipe_thumb] ${recipeId} -> ${result.status}`, result.detail || "");
      }
    } catch (e) {
      console.error(`[CF][recipe_thumb] ${recipeId} failed:`, e);
    }
  });

const USER_ANALYTICS_HEADERS = [
  "No.",
  "UID",
  "Username",
  "Signed Up",
  "Last Active",
  "Bookmarked",
  "Newly Parsed",
  "Reviews Written",
  "Cooking Sessions",
  "Likes Received",
  "Items bought",
  "Total Expenditure",
  "Purchase Sessions",
  "In-Progress Session",
  "Avg Portion",
  "Coupang",
  "Kurly",
];

const RECIPE_ANALYTICS_HEADERS = [
  "No.",
  "Recipe ID",
  "Recipe Name",
  "Platform",
  "Link",
  "Used OCR",
  "Ingredients",
  "Steps",
  "Tags",
  "Categories",
  "Views",
  "Bookmarked Users",
  "Reviews",
  "Error Reports",
  "Purchase",
];

const PRODUCT_ANALYTICS_HEADERS = [
  "No.",
  "Checked At",
  "UID",
  "Ingredient Name",
  "Platform Product Name",
  "Marketplace",
  "Checked",
  "Price",
  "Package Size",
  "Package Unit",
  "Unit Price",
  "Category",
  "Product ID",
  "Product URL",
  "Original URL",
  "Deeplink URL",
  "Rating",
  "Reviews",
  "Match Score",
];

function _asDate(value) {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof value.toDate === "function") {
    try {
      return value.toDate();
    } catch (e) {
      return null;
    }
  }
  return null;
}

function _formatDateTimeForSheet(value) {
  const d = _asDate(value);
  if (!d) return "";
  const f = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
  return f.format(d).replace(" ", " ");
}

function _toNumber(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const cleaned = value.replace(/[^\d.-]/g, "");
    const n = Number.parseFloat(cleaned);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

function _extractPurchasePricesFromUserDoc(data) {
  const explicitTotal = _toNumber(data.purchaseTotalPrice);
  const explicitCoupang = _toNumber(data.purchaseTotalPriceCoupang);
  const explicitKurly = _toNumber(data.purchaseTotalPriceKurly);

  if (explicitTotal > 0 || explicitCoupang > 0 || explicitKurly > 0) {
    return {
      total: explicitTotal,
      coupang: explicitCoupang,
      kurly: explicitKurly,
    };
  }

  const fridge = data.fridgeData && typeof data.fridgeData === "object"
    ? data.fridgeData
    : {};
  const ingredients = Array.isArray(fridge.ingredients) ? fridge.ingredients : [];
  let coupang = 0;
  let kurly = 0;
  let total = 0;

  for (const raw of ingredients) {
    if (!raw || typeof raw !== "object") continue;
    const price = _toNumber(
      raw.productPrice ||
      raw.price ||
      raw.purchasedPrice ||
      raw.lastPurchasedPrice ||
      raw.totalPrice
    );
    if (price <= 0) continue;

    total += price;
    const marketplace = String(raw.marketplace || "").toLowerCase();
    if (marketplace.includes("coupang")) {
      coupang += price;
    } else if (marketplace.includes("kurly") || marketplace.includes("marketkurly")) {
      kurly += price;
    }
  }

  return { total, coupang, kurly };
}

async function _countCompletedParsedRecipesByUser() {
  const map = new Map();
  const stream = db.collection("recipes").select("userId", "status").stream();

  for await (const doc of stream) {
    const data = doc.data() || {};
    const uid = String(data.userId || "").trim();
    if (!uid) continue;
    const status = String(data.status || "").toLowerCase();
    if (status !== "completed") continue;
    map.set(uid, (map.get(uid) || 0) + 1);
  }

  return map;
}

async function _countReviewsAndLikesByUser() {
  const reviewCountByUser = new Map();
  const likeCountByUser = new Map();
  const stream = db.collection("reviews").select("userId", "likeCount").stream();

  for await (const doc of stream) {
    const data = doc.data() || {};
    const uid = String(data.userId || "").trim();
    if (!uid) continue;

    reviewCountByUser.set(uid, (reviewCountByUser.get(uid) || 0) + 1);

    const likes = _toNumber(data.likeCount);
    if (likes > 0) {
      likeCountByUser.set(uid, (likeCountByUser.get(uid) || 0) + likes);
    } else if (!likeCountByUser.has(uid)) {
      likeCountByUser.set(uid, 0);
    }
  }

  return { reviewCountByUser, likeCountByUser };
}

async function _writeValuesToSheet({
  spreadsheetId,
  sheetName,
  values,
}) {
  if (!spreadsheetId) {
    return;
  }

  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/spreadsheets"],
  });
  const client = await auth.getClient();
  const sheets = google.sheets({ version: "v4", auth: client });

  await sheets.spreadsheets.values.clear({
    spreadsheetId,
    range: `${sheetName}!A2:Z`,
  });

  await sheets.spreadsheets.values.update({
    spreadsheetId,
    range: `${sheetName}!A2`,
    valueInputOption: "RAW",
    requestBody: {
      majorDimension: "ROWS",
      values,
    },
  });
}

async function _writeUserAnalyticsToSheet(values) {
  const runtimeConfig = typeof functions.config === "function" ? functions.config() : {};
  const analyticsConfig = runtimeConfig && runtimeConfig.user_analytics
    ? runtimeConfig.user_analytics
    : {};
  const spreadsheetId = String(
    process.env.USER_ANALYTICS_SHEET_ID || analyticsConfig.sheet_id || "13B3PhDEVINmCLipb9DAA8CswAE8Yr4it9aQHAXyYoE0"
  ).trim();
  const sheetName = String(
    process.env.USER_ANALYTICS_SHEET_NAME || analyticsConfig.sheet_name || "UserAnalytics"
  ).trim();

  if (!spreadsheetId) {
    console.warn("[CF][user_analytics] USER_ANALYTICS_SHEET_ID is not set. Skipping.");
    return;
  }

  await _writeValuesToSheet({
    spreadsheetId,
    sheetName,
    values,
  });
}

async function runUserAnalyticsExport() {
  const usersSnap = await db.collection("users").get();
  const parsedRecipeCounts = await _countCompletedParsedRecipesByUser();
  const { reviewCountByUser, likeCountByUser } = await _countReviewsAndLikesByUser();

  const rows = [];
  for (const doc of usersSnap.docs) {
    const data = doc.data() || {};
    const uid = doc.id;
    const username = String(data.name || data.handle || data.username || "").trim();
    const signedUp = _formatDateTimeForSheet(data.createdAt);
    const lastActive = _formatDateTimeForSheet(
      data.lastAccessedAt || data.updatedAt || data.createdAt
    );
    const bookmarkedRecipes = Array.isArray(data.savedRecipes)
      ? data.savedRecipes.length
      : 0;
    const parsedRecipeVideos = parsedRecipeCounts.get(uid) || 0;
    const reviewsWritten = reviewCountByUser.get(uid) || _toNumber(data.reviewCount);
    const cookingDone = _toNumber(data.cookingButtonClickCount);
    const likesReceived = likeCountByUser.get(uid) || 0;
    const itemsBoughtTotal = _toNumber(data.itemsBoughtTotalCount);
    const purchaseSessions = _toNumber(data.purchaseCount);
    const hasInProgressSession = data.hasInProgressPurchaseSession === true;
    const purchasedRecipeServingsTotal = _toNumber(data.purchasedRecipeServingsTotal);
    const purchasedRecipeCountTotal = _toNumber(data.purchasedRecipeCountTotal);
    const avgPortionPerRecipe = purchasedRecipeCountTotal > 0
      ? purchasedRecipeServingsTotal / purchasedRecipeCountTotal
      : 0;
    const prices = _extractPurchasePricesFromUserDoc(data);

    rows.push({
      uid,
      row: [
        0,
        uid,
        username,
        signedUp,
        lastActive,
        bookmarkedRecipes,
        parsedRecipeVideos,
        reviewsWritten,
        cookingDone,
        likesReceived,
        itemsBoughtTotal,
        Math.round(prices.total),
        purchaseSessions,
        hasInProgressSession ? "TRUE" : "FALSE",
        Number(avgPortionPerRecipe.toFixed(2)),
        Math.round(prices.coupang),
        Math.round(prices.kurly),
      ],
      sortDate: _asDate(data.createdAt)?.getTime() || 0,
    });
  }

  rows.sort((a, b) => a.sortDate - b.sortDate);
  const finalValues = [USER_ANALYTICS_HEADERS];
  rows.forEach((r, idx) => {
    r.row[0] = idx + 1;
    finalValues.push(r.row);
  });

  await _writeUserAnalyticsToSheet(finalValues);
  console.log(`[CF][user_analytics] Exported ${rows.length} users.`);
  return { count: rows.length };
}

function _formatListForSheet(value) {
  if (Array.isArray(value)) {
    return value
      .map((v) => String(v || "").trim())
      .filter((v) => !!v)
      .join(", ");
  }
  if (typeof value === "string") {
    return value.trim();
  }
  return "";
}

function _formatCategoriesForSheet(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return _formatListForSheet(value);
  }

  const parts = [];
  for (const [k, v] of Object.entries(value)) {
    const key = String(k || "").trim();
    if (!key) continue;
    const listText = _formatListForSheet(v);
    if (listText) {
      parts.push(`${key}: ${listText}`);
    }
  }
  return parts.join(" | ");
}

function _usedOcrFromSubStage(data) {
  const subStage = String(data && data.sub_stage ? data.sub_stage : "")
    .trim()
    .toLowerCase();
  if (!subStage) return false;
  return subStage.includes("ocr");
}

async function _countBookmarkedUsersByRecipe() {
  const map = new Map();
  const stream = db.collection("users").select("savedRecipes").stream();
  for await (const doc of stream) {
    const data = doc.data() || {};
    const saved = Array.isArray(data.savedRecipes) ? data.savedRecipes : [];
    const unique = new Set(saved.map((v) => String(v || "").trim()).filter((v) => !!v));
    for (const recipeId of unique) {
      map.set(recipeId, (map.get(recipeId) || 0) + 1);
    }
  }
  return map;
}

async function _countReviewsByRecipe() {
  const map = new Map();
  const stream = db.collection("reviews").select("recipeId").stream();
  for await (const doc of stream) {
    const data = doc.data() || {};
    const recipeId = String(data.recipeId || "").trim();
    if (!recipeId) continue;
    map.set(recipeId, (map.get(recipeId) || 0) + 1);
  }
  return map;
}

async function _countRecipeReportsByRecipe() {
  const map = new Map();
  const stream = db.collection("recipe_reports").select("recipeId").stream();
  for await (const doc of stream) {
    const data = doc.data() || {};
    const recipeId = String(data.recipeId || "").trim();
    if (!recipeId) continue;
    map.set(recipeId, (map.get(recipeId) || 0) + 1);
  }
  return map;
}

async function _writeRecipeAnalyticsToSheet(values) {
  const runtimeConfig = typeof functions.config === "function" ? functions.config() : {};
  const recipeConfig = runtimeConfig && runtimeConfig.recipe_analytics
    ? runtimeConfig.recipe_analytics
    : {};
  const spreadsheetId = String(
    process.env.RECIPE_ANALYTICS_SHEET_ID ||
      process.env.USER_ANALYTICS_SHEET_ID ||
      recipeConfig.sheet_id ||
      "13B3PhDEVINmCLipb9DAA8CswAE8Yr4it9aQHAXyYoE0"
  ).trim();
  const sheetName = String(
    process.env.RECIPE_ANALYTICS_SHEET_NAME ||
      recipeConfig.sheet_name ||
      "RecipeAnalytics"
  ).trim();

  if (!spreadsheetId) {
    console.warn("[CF][recipe_analytics] RECIPE_ANALYTICS_SHEET_ID is not set. Skipping.");
    return;
  }

  await _writeValuesToSheet({
    spreadsheetId,
    sheetName,
    values,
  });
}

async function _writeProductAnalyticsToSheet(values) {
  const runtimeConfig = typeof functions.config === "function" ? functions.config() : {};
  const productConfig = runtimeConfig && runtimeConfig.product_analytics
    ? runtimeConfig.product_analytics
    : {};
  const spreadsheetId = String(
    process.env.PRODUCT_ANALYTICS_SHEET_ID ||
      process.env.USER_ANALYTICS_SHEET_ID ||
      productConfig.sheet_id ||
      "13B3PhDEVINmCLipb9DAA8CswAE8Yr4it9aQHAXyYoE0"
  ).trim();
  const sheetName = String(
    process.env.PRODUCT_ANALYTICS_SHEET_NAME ||
      productConfig.sheet_name ||
      "product"
  ).trim();

  if (!spreadsheetId) {
    console.warn("[CF][product_analytics] PRODUCT_ANALYTICS_SHEET_ID is not set. Skipping.");
    return;
  }

  await _writeValuesToSheet({
    spreadsheetId,
    sheetName,
    values,
  });
}

async function runRecipeAnalyticsExport() {
  const [recipesSnap, bookmarkedUsersByRecipe, reviewsByRecipe, reportsByRecipe] = await Promise.all([
    db.collection("recipes").get(),
    _countBookmarkedUsersByRecipe(),
    _countReviewsByRecipe(),
    _countRecipeReportsByRecipe(),
  ]);

  const rows = [];
  for (const doc of recipesSnap.docs) {
    const data = doc.data() || {};
    const recipeId = doc.id;
    const source = data.source && typeof data.source === "object" ? data.source : {};
    const recipe = data.recipe && typeof data.recipe === "object" ? data.recipe : {};
    const ingredients = Array.isArray(recipe.ingredients) ? recipe.ingredients : [];
    const steps = Array.isArray(recipe.steps) ? recipe.steps : [];
    const platform = String(source.platform || data.platform || "").trim().toLowerCase();
    const link = String(data.sourceUrl || source.url || "").trim();
    const usedOcr = _usedOcrFromSubStage(data);
    const title = String(data.title || recipe.name || source.title || "").trim();
    const tags = _formatListForSheet(data.tags || source.tags || []);
    const categories = _formatCategoriesForSheet(data.categories || source.categories || {});

    rows.push({
      row: [
        0,
        recipeId,
        title,
        platform,
        link,
        usedOcr ? "Yes" : "No",
        ingredients.length,
        steps.length,
        tags,
        categories,
        _toNumber(data.viewCount),
        bookmarkedUsersByRecipe.get(recipeId) || 0,
        reviewsByRecipe.get(recipeId) || 0,
        reportsByRecipe.get(recipeId) || 0,
        _toNumber(data.purchaseOccasionCount),
      ],
      sortDate:
        _asDate(data.createdAt)?.getTime() ||
        _asDate(data.completedAt)?.getTime() ||
        0,
    });
  }

  rows.sort((a, b) => a.sortDate - b.sortDate);
  const finalValues = [RECIPE_ANALYTICS_HEADERS];
  rows.forEach((r, idx) => {
    r.row[0] = idx + 1;
    finalValues.push(r.row);
  });

  await _writeRecipeAnalyticsToSheet(finalValues);
  console.log(`[CF][recipe_analytics] Exported ${rows.length} recipes.`);
  return { count: rows.length };
}

async function runProductAnalyticsExport() {
  // 신규 체크 이벤트는 GCS 시그널만 남긴다. 이 export는 레거시
  // users/*/product_check_events 문서가 있을 때만 값이 있다.
  const stream = db.collectionGroup("product_check_events").stream();
  const rows = [];

  for await (const doc of stream) {
    const data = doc.data() || {};
    const uidFromPath = doc.ref && doc.ref.parent && doc.ref.parent.parent
      ? String(doc.ref.parent.parent.id || "").trim()
      : "";
    const uid = String(data.userId || uidFromPath).trim();
    const ingredientName = String(data.ingredientName || "").trim();
    const checked = data.checked === true;

    rows.push({
      row: [
        0,
        _formatDateTimeForSheet(data.createdAt),
        uid,
        ingredientName,
        String(data.platformProductName || "").trim(),
        String(data.marketplace || "").trim(),
        checked ? "TRUE" : "FALSE",
        _toNumber(data.price),
        _toNumber(data.packageSize),
        String(data.packageUnit || "").trim(),
        _toNumber(data.unitPrice),
        String(data.category || "").trim(),
        String(data.productId || "").trim(),
        String(data.productUrl || "").trim(),
        String(data.originalUrl || "").trim(),
        String(data.deeplinkUrl || "").trim(),
        _toNumber(data.rating),
        _toNumber(data.reviews),
        _toNumber(data.matchScore),
      ],
      sortDate: _asDate(data.createdAt)?.getTime() || 0,
    });
  }

  rows.sort((a, b) => a.sortDate - b.sortDate);
  const finalValues = [PRODUCT_ANALYTICS_HEADERS];
  rows.forEach((r, idx) => {
    r.row[0] = idx + 1;
    finalValues.push(r.row);
  });

  await _writeProductAnalyticsToSheet(finalValues);
  console.log(`[CF][product_analytics] Exported ${rows.length} events.`);
  return { count: rows.length };
}

// Google Sheets 정기 내보내기는 사용하지 않아 비활성화했다.
// 수동 실행 함수는 운영 점검/일회성 백필을 위해 유지한다.
exports.runUserAnalyticsExport = runUserAnalyticsExport;

exports.runRecipeAnalyticsExport = runRecipeAnalyticsExport;

exports.runProductAnalyticsExport = runProductAnalyticsExport;

exports.onRecipeWriteEnsureInstagramCroppedThumbnail = functions
  .runWith({ timeoutSeconds: 120, memory: "512MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;
    const recipeId = context.params.recipeId;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.data() || {};

    try {
      if (_shouldSkipInstagramCroppedWork(before, after)) return;
      const result = await ensureInstagramCroppedThumbnailForRecipe(recipeId, after);
      if (result.status && result.status !== "updated" && result.status !== "skipped_not_instagram") {
        console.log(`[CF][instagram_thumb] ${recipeId} -> ${result.status}`, result.detail || "");
      }
    } catch (e) {
      console.error(`[CF][instagram_thumb] ${recipeId} failed:`, e);
    }
  });

exports.onRecipeWriteNormalizeSourceKey = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists) return null;
    const recipeId = context.params.recipeId;
    const after = change.after.data() || {};
    const patch = _buildRecipeSourcePatch(after);
    if (!patch) return null;
    try {
      await change.after.ref.set(patch, { merge: true });
      return { status: "updated", recipeId };
    } catch (e) {
      console.error(`[CF][sourceKey] ${recipeId} failed:`, e);
      return null;
    }
  });

exports.onRecipeWriteSyncSeasonalIndex = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    const recipeId = context.params.recipeId;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.exists ? change.after.data() || {} : {};
    try {
      await _syncSeasonalIndexForRecipe(recipeId, before, after);
    } catch (e) {
      console.error(`[CF][seasonal_index] ${recipeId} failed:`, e);
    }
  });

exports.onRecipeWriteSyncIngredientIndex = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    const recipeId = context.params.recipeId;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.exists ? change.after.data() || {} : {};
    try {
      await _syncIngredientIndexForRecipe(recipeId, before, after);
    } catch (e) {
      console.error(`[CF][ingredient_index] ${recipeId} failed:`, e);
    }
  });

exports.onRecipeWriteSyncChefIndex = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    const recipeId = context.params.recipeId;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.exists ? change.after.data() || {} : {};
    try {
      await _syncChefIndexForRecipe(recipeId, before, after);
    } catch (e) {
      console.error(`[CF][chef_index] ${recipeId} failed:`, e);
    }
  });

exports.onRecipeWriteSyncHomeSectionIndex = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    const recipeId = context.params.recipeId;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.exists ? change.after.data() || {} : {};
    try {
      await _syncHomeSectionIndexForRecipe(recipeId, before, after, !change.before.exists);
    } catch (e) {
      console.error(`[CF][home_section_index] ${recipeId} failed:`, e);
    }
  });

// ---------------------------------------------------------------------------
// 홈 섹션 큐레이션 (관리자 pin/block + rebuild)
// POST https://us-central1-yorigo-f7408.cloudfunctions.net/adminHomeSectionCuration
// Body: { "action": "pin"|"unpin"|"block"|"unblock"|"rebuild"|"rebuild_programs"|"get",
//         "sectionKey": "...", "recipeId": "...", "dryRun": true|false }
// ---------------------------------------------------------------------------

async function _verifyAdminBearer(req) {
  const authHeader = (req.headers.authorization || "").toString();
  if (!authHeader.startsWith("Bearer ")) {
    return { error: { status: 401, body: { error: "missing_bearer_token" } } };
  }
  const idToken = authHeader.substring("Bearer ".length).trim();
  let decoded;
  try {
    decoded = await admin.auth().verifyIdToken(idToken);
  } catch (e) {
    return {
      error: {
        status: 401,
        body: { error: "invalid_token", detail: String((e && e.message) || e) },
      },
    };
  }
  const email = decoded && decoded.email ? String(decoded.email) : "";
  const emailVerified = !!(decoded && decoded.email_verified);
  if (!email || !emailVerified) {
    return { error: { status: 403, body: { error: "email_not_verified" } } };
  }
  const adminSnap = await db.collection("admin_emails").doc(email).get();
  const adminActive = adminSnap.exists && (adminSnap.data() || {}).active === true;
  if (!adminActive) {
    return { error: { status: 403, body: { error: "not_admin" } } };
  }
  return { email };
}

async function _assertSectionKey(sectionKey) {
  const key = _sanitizeText(sectionKey);
  if (!key) return null;
  if (getSectionRules()[key]) return key;
  if (isManualIndexKey(key) && key.startsWith("poster_")) return key;
  const cmsSnap = await db.collection("home_cms_sections").doc(key).get();
  if (cmsSnap.exists) return key;
  const indexSnap = await db.collection("home_section_index").doc(key).get();
  if (indexSnap.exists) return key;
  return null;
}

async function _validateRecipeForCuration(recipeId) {
  const id = _sanitizeText(recipeId);
  if (!id) return { ok: false, reason: "invalid_recipe_id" };
  const snap = await db.collection("recipes").doc(id).get();
  if (!snap.exists) return { ok: false, reason: "recipe_not_found" };
  const data = snap.data() || {};
  if (!_isVisibleCompletedHomeRecipe(data)) {
    return { ok: false, reason: "recipe_not_visible_completed" };
  }
  return { ok: true, id, data };
}

async function _mutateHomeSectionOverrides(sectionKey, mutator, updatedBy) {
  const ref = db.collection("home_section_overrides").doc(sectionKey);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = normalizeOverridesDoc(snap.exists ? snap.data() : {});
    const next = mutator({ ...current });
    tx.set(
      ref,
      {
        sectionKey,
        pinnedIds: next.pinnedIds,
        blockedIds: next.blockedIds,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedBy,
      },
      { merge: true }
    );
  });
}

function _removeIdFromList(list, recipeId) {
  const id = _sanitizeText(recipeId);
  return list.filter((x) => _sanitizeText(x) !== id);
}

function _appendUniqueId(list, recipeId) {
  const id = _sanitizeText(recipeId);
  if (!id) return list;
  return [..._removeIdFromList(list, id), id];
}

exports.adminHomeSectionCuration = functions
  .runWith({ timeoutSeconds: 540, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== "POST") {
        res.status(405).json({ error: "method_not_allowed" });
        return;
      }
      const auth = await _verifyAdminBearer(req);
      if (auth.error) {
        res.status(auth.error.status).json(auth.error.body);
        return;
      }
      const body = typeof req.body === "object" && req.body ? req.body : {};
      const action = _sanitizeText(body.action).toLowerCase();
      await refreshCmsSectionRules(db);
      const sectionKey = await _assertSectionKey(body.sectionKey);

      if (action === "list_cms") {
        const [posterSnap, sectionSnap] = await Promise.all([
          db.collection("home_cms_posters").get(),
          db.collection("home_cms_sections").get(),
        ]);
        res.status(200).json({
          ok: true,
          action,
          posters: posterSnap.docs.map((d) => ({ id: d.id, ...(d.data() || {}) })),
          sections: sectionSnap.docs.map((d) => ({ sectionKey: d.id, ...(d.data() || {}) })),
        });
        return;
      }

      if (action === "rebuild") {
        const targetKey = body.sectionKey ? sectionKey : null;
        if (body.sectionKey && !targetKey) {
          res.status(400).json({ error: "invalid_section_key" });
          return;
        }
        const counts = await rebuildHomeSectionIndex(db, targetKey || undefined);
        res.status(200).json({ ok: true, action, counts });
        return;
      }

      if (action === "rebuild_programs") {
        const dryRun = body.dryRun === true || body.dry_run === true;
        const result = await rebuildProgramHomeSectionIndexes(db, { dryRun });
        res.status(200).json({
          ok: true,
          action,
          dryRun: result.dryRun,
          scannedRecipes: result.scannedRecipes,
          counts: result.counts,
        });
        return;
      }

      if (action === "get") {
        if (!sectionKey) {
          res.status(400).json({ error: "invalid_section_key" });
          return;
        }
        const overrides = await loadOverrides(db, sectionKey);
        const indexSnap = await db.collection("home_section_index").doc(sectionKey).get();
        const indexData = indexSnap.exists ? indexSnap.data() || {} : {};
        const recipeIds = Array.isArray(indexData.recipeIds) ? indexData.recipeIds : [];
        res.status(200).json({
          ok: true,
          sectionKey,
          overrides,
          recipeIds,
          count: recipeIds.length,
        });
        return;
      }

      if (!sectionKey) {
        res.status(400).json({ error: "invalid_section_key" });
        return;
      }

      const recipeId = _sanitizeText(body.recipeId);
      if (!recipeId) {
        res.status(400).json({ error: "invalid_recipe_id" });
        return;
      }

      if (action === "pin") {
        const valid = await _validateRecipeForCuration(recipeId);
        if (!valid.ok) {
          res.status(400).json({ error: valid.reason });
          return;
        }
        await _mutateHomeSectionOverrides(
          sectionKey,
          (cur) => ({
            pinnedIds: _appendUniqueId(cur.pinnedIds, recipeId),
            blockedIds: _removeIdFromList(cur.blockedIds, recipeId),
          }),
          auth.email
        );
        const ids = await buildSectionRecipeIds(db, sectionKey);
        await writeSectionIndex(db, sectionKey, ids);
        res.status(200).json({ ok: true, action, sectionKey, recipeId, count: ids.length });
        return;
      }

      if (action === "unpin") {
        await _mutateHomeSectionOverrides(
          sectionKey,
          (cur) => ({
            pinnedIds: _removeIdFromList(cur.pinnedIds, recipeId),
            blockedIds: cur.blockedIds,
          }),
          auth.email
        );
        const ids = await buildSectionRecipeIds(db, sectionKey);
        await writeSectionIndex(db, sectionKey, ids);
        res.status(200).json({ ok: true, action, sectionKey, recipeId, count: ids.length });
        return;
      }

      if (action === "block") {
        const snap = await db.collection("recipes").doc(recipeId).get();
        if (!snap.exists) {
          res.status(400).json({ error: "recipe_not_found" });
          return;
        }
        await _mutateHomeSectionOverrides(
          sectionKey,
          (cur) => ({
            pinnedIds: _removeIdFromList(cur.pinnedIds, recipeId),
            blockedIds: _appendUniqueId(cur.blockedIds, recipeId),
          }),
          auth.email
        );
        const ids = await buildSectionRecipeIds(db, sectionKey);
        await writeSectionIndex(db, sectionKey, ids);
        res.status(200).json({ ok: true, action, sectionKey, recipeId, count: ids.length });
        return;
      }

      if (action === "unblock") {
        await _mutateHomeSectionOverrides(
          sectionKey,
          (cur) => ({
            pinnedIds: cur.pinnedIds,
            blockedIds: _removeIdFromList(cur.blockedIds, recipeId),
          }),
          auth.email
        );
        const ids = await buildSectionRecipeIds(db, sectionKey);
        await writeSectionIndex(db, sectionKey, ids);
        res.status(200).json({ ok: true, action, sectionKey, recipeId, count: ids.length });
        return;
      }

      res.status(400).json({ error: "invalid_action" });
    } catch (e) {
      console.error("[CF][adminHomeSectionCuration] failed:", e);
      res.status(500).json({
        error: "internal",
        detail: String((e && e.message) || e),
      });
    }
  });

// ---------------------------------------------------------------------------
// 레시피 가격 추정 (recipes/{id}.priceTier / estimatedCostPerServing 등)
// ingredient_unit_prices 를 사용해 1인분 원가 계산 → 가격대 분류.
// ---------------------------------------------------------------------------
let recipeCost = null;
try {
  recipeCost = require("./recipeCost");
} catch (e) {
  console.warn("[CF][recipeCost] module not found; cost functions disabled:", e && e.message ? e.message : e);
}

exports.onRecipeWriteCalculateCost = functions
  .runWith({ timeoutSeconds: 120, memory: "256MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    if (!recipeCost || typeof recipeCost.onRecipeWriteReconcileCost !== "function") {
      return null;
    }
    const recipeId = context.params.recipeId;
    try {
      const result = await recipeCost.onRecipeWriteReconcileCost(change, recipeId);
      if (result && result.status && result.status !== "updated") {
        console.log(`[CF][recipeCost] ${recipeId} -> ${result.status}`);
      }
    } catch (e) {
      console.error(`[CF][recipeCost] ${recipeId} failed:`, e);
    }
  });

exports.recalculateAllRecipeCosts = functions
  .runWith({ timeoutSeconds: 540, memory: "1GB" })
  .pubsub.schedule("every monday 04:00")
  .timeZone("Asia/Seoul")
  .onRun(async () => {
    if (!recipeCost || typeof recipeCost.recalculateAllRecipeCosts !== "function") {
      console.warn("[CF][recipeCost][cron] skipped: module unavailable");
      return { status: "skipped", reason: "recipeCost_module_unavailable" };
    }
    try {
      const result = await recipeCost.recalculateAllRecipeCosts();
      console.log("[CF][recipeCost][cron]", result);
      return result;
    } catch (e) {
      console.error("[CF][recipeCost][cron] failed:", e);
      throw e;
    }
  });

// 어드민 1회성 백필. 호출:
//   curl -X POST "https://<region>-<project>.cloudfunctions.net/backfillRecipeCosts" \
//        -H "Authorization: Bearer <admin-id-token>" \
//        -H "Content-Type: application/json" \
//        -d '{"pageSize": 200}'
exports.backfillRecipeCosts = functions
  .runWith({ timeoutSeconds: 540, memory: "1GB" })
  .https.onRequest(async (req, res) => {
    try {
      if (!recipeCost || typeof recipeCost.recalculateAllRecipeCosts !== "function") {
        res.status(503).json({
          error: "recipe_cost_module_unavailable",
          detail: "recipeCost module is not deployed in functions codebase",
        });
        return;
      }
      if (req.method !== "POST") {
        res.status(405).json({ error: "method_not_allowed" });
        return;
      }
      const authHeader = (req.headers.authorization || "").toString();
      if (!authHeader.startsWith("Bearer ")) {
        res.status(401).json({ error: "missing_bearer_token" });
        return;
      }
      const idToken = authHeader.substring("Bearer ".length).trim();
      let decoded;
      try {
        decoded = await admin.auth().verifyIdToken(idToken);
      } catch (e) {
        res.status(401).json({
          error: "invalid_token",
          detail: String(e && e.message || e),
        });
        return;
      }
      const email = decoded && decoded.email ? String(decoded.email) : "";
      const emailVerified = !!(decoded && decoded.email_verified);
      if (!email || !emailVerified) {
        res.status(403).json({ error: "email_not_verified" });
        return;
      }
      const adminSnap = await db.collection("admin_emails").doc(email).get();
      const adminActive = adminSnap.exists && (adminSnap.data() || {}).active === true;
      if (!adminActive) {
        res.status(403).json({ error: "not_admin" });
        return;
      }
      const body = (typeof req.body === "object" && req.body) ? req.body : {};
      const result = await recipeCost.recalculateAllRecipeCosts({
        pageSize: Number.isFinite(body.pageSize) ? body.pageSize : 200,
        maxRecipes: Number.isFinite(body.maxRecipes) ? body.maxRecipes : 0,
      });
      res.status(200).json(result);
    } catch (e) {
      console.error("[CF][recipeCost] backfill failed:", e);
      res.status(500).json({
        error: "internal",
        detail: String(e && e.message || e),
      });
    }
  });

// ---------------------------------------------------------------------------
// 핫한 레시피 (recipe_groups) — 같은 기본 요리명으로 묶인 그룹 카운트 유지
// ---------------------------------------------------------------------------
const recipeGroups = require("./recipeGroups");

exports.onRecipeWriteUpdateGroup = functions
  .runWith({ timeoutSeconds: 120, memory: "512MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    const recipeId = context.params.recipeId;
    try {
      await recipeGroups.onRecipeWriteReconcileGroup(change, recipeId);
    } catch (e) {
      console.error(`[CF][recipe_groups] ${recipeId} failed:`, e);
    }
  });

// 매 6시간마다 모든 recipe_groups 의 recentCount/totalCount/latest 를 다시 계산.
// onWrite 트리거만으로는 시간이 지나서 "최근 3일 내" 에서 빠지는 변화를 잡을 수 없음.
exports.refreshRecipeGroupCounts = functions
  .runWith({ timeoutSeconds: 540, memory: "512MB" })
  .pubsub.schedule("every 6 hours")
  .timeZone("Asia/Seoul")
  .onRun(async () => {
    try {
      const result = await recipeGroups.refreshAllGroups();
      console.log("[CF][recipe_groups] refresh:", result);
      return result;
    } catch (e) {
      console.error("[CF][recipe_groups] refresh failed:", e);
      throw e;
    }
  });

// 1회성 백필. 호출 예:
//   curl -X POST "https://<region>-<project>.cloudfunctions.net/backfillRecipeGroups" \
//        -H "Authorization: Bearer <admin-id-token>" \
//        -H "Content-Type: application/json" \
//        -d '{"dryRun": true}'
//
// dryRun=true 면 카운트만 집계하고 Firestore 에 쓰지 않음 (상위 20개 묶음 미리보기 반환).
// useLlm=false 면 사전/규칙만 사용 (백필 비용 0).
exports.backfillRecipeGroups = functions
  .runWith({ timeoutSeconds: 540, memory: "1GB" })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== "POST") {
        res.status(405).json({ error: "method_not_allowed" });
        return;
      }

      const authHeader = (req.headers.authorization || "").toString();
      if (!authHeader.startsWith("Bearer ")) {
        res.status(401).json({ error: "missing_bearer_token" });
        return;
      }
      const idToken = authHeader.substring("Bearer ".length).trim();
      let decoded;
      try {
        decoded = await admin.auth().verifyIdToken(idToken);
      } catch (e) {
        res.status(401).json({ error: "invalid_token", detail: String(e && e.message || e) });
        return;
      }

      const email = decoded && decoded.email ? String(decoded.email) : "";
      const emailVerified = !!(decoded && decoded.email_verified);
      if (!email || !emailVerified) {
        res.status(403).json({ error: "email_not_verified" });
        return;
      }
      const adminSnap = await db.collection("admin_emails").doc(email).get();
      const adminActive = adminSnap.exists && (adminSnap.data() || {}).active === true;
      if (!adminActive) {
        res.status(403).json({ error: "not_admin" });
        return;
      }

      const body = (typeof req.body === "object" && req.body) ? req.body : {};
      const result = await recipeGroups.backfillAllGroups({
        dryRun: body.dryRun === true,
        useLlm: body.useLlm !== false,
        pageSize: Number.isFinite(body.pageSize) ? body.pageSize : undefined,
        maxRecipes: Number.isFinite(body.maxRecipes) ? body.maxRecipes : undefined,
      });
      res.status(200).json(result);
    } catch (e) {
      console.error("[CF][recipe_groups] backfill failed:", e);
      res.status(500).json({ error: "internal", detail: String(e && e.message || e) });
    }
  });

// ---------------------------------------------------------------------------
// users/{uid}/savedRecipes/{rid} 서브컬렉션 미니 doc 동기화.
// 본문(recipes/{rid}) 변경 시 카드 표시용 필드들(title/thumbnail/calories/
// ingredientCount/totalMinutes/categories/tags 등)을 모든 저장 유저의 미니 doc 에 propagate 한다.
// 미니 doc 은 카드 N+1 read 제거용 denormalization 사본.
function _pickMiniCreatorField(source, after, key) {
  const fromSource = source && source[key];
  if (typeof fromSource === "string" && fromSource.trim()) {
    return fromSource.trim();
  }
  const top = after && after[key];
  if (typeof top === "string" && top.trim()) {
    return top.trim();
  }
  return null;
}

function _miniDocNeedsCreatorBackfill(mini) {
  const u = mini && mini.sourceUploader;
  const c = mini && mini.sourceChannel;
  const hasU = typeof u === "string" && u.trim();
  const hasC = typeof c === "string" && c.trim();
  return !hasU && !hasC;
}

function _miniDocNeedsCategoriesBackfill(mini) {
  const c = mini && mini.categories;
  return !c || typeof c !== "object" || !Object.keys(c).length;
}

function _miniDocNeedsFilterFieldsBackfill(mini) {
  return _miniDocNeedsCreatorBackfill(mini) || _miniDocNeedsCategoriesBackfill(mini);
}

function _creatorFieldsPatchFromRecipe(r) {
  const patch = _buildSavedRecipeMiniPatch(r);
  const out = {};
  if (patch.sourceUploader) out.sourceUploader = patch.sourceUploader;
  if (patch.sourceChannel) out.sourceChannel = patch.sourceChannel;
  return out;
}

/** Flutter RecipeSocialCounts.viewCountFromSource 와 동일. play_count 우선. */
function _intFromSocial(raw) {
  if (typeof raw === "number" && Number.isFinite(raw)) return Math.floor(raw);
  if (typeof raw === "string") {
    const digits = raw.replace(/[^0-9]/g, "");
    if (!digits) return null;
    const n = parseInt(digits, 10);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function _sourceViewCountFrom(source) {
  if (!source || typeof source !== "object") return null;
  for (const key of [
    "play_count",
    "playCount",
    "view_count",
    "videoViewCount",
    "views",
    "viewCount",
  ]) {
    const n = _intFromSocial(source[key]);
    if (n != null && n >= 0) return n;
  }
  for (const nestedKey of ["statistics", "stats", "engagement"]) {
    const nested = source[nestedKey];
    if (!nested || typeof nested !== "object") continue;
    const found = _sourceViewCountFrom(nested);
    if (found != null) return found;
  }
  return null;
}

function _buildSavedRecipeMiniPatch(after) {
  const recipeBody = (after && typeof after.recipe === "object" && after.recipe) || {};
  const ingredients = Array.isArray(recipeBody.ingredients) ? recipeBody.ingredients : [];
  const steps = Array.isArray(recipeBody.steps) ? recipeBody.steps : [];
  let totalMinutes = 0;
  for (const s of steps) {
    if (s && typeof s.est_minutes === "number") {
      totalMinutes += Math.floor(s.est_minutes);
    }
  }
  const calories = typeof (after && after.calories) === "number" ? after.calories : 0;
  const source = (after && typeof after.source === "object" && after.source) || {};
  const categories =
    after && typeof after.categories === "object" && after.categories
      ? after.categories
      : null;
  const tags = Array.isArray(after && after.tags) ? after.tags : null;
  const saveCount =
    after && typeof after.saveCount === "number" ? Math.max(0, after.saveCount) : 0;
  const sourceViewCount = _sourceViewCountFrom(source);
  return {
    title: (after && after.title) || null,
    thumbnailUrl: (after && after.thumbnailUrl) || null,
    thumbnailUrlLarge: (after && after.thumbnailUrlLarge) || null,
    thumbnailUrlCropped: (after && after.thumbnailUrlCropped) || null,
    sourcePlatform: source.platform || null,
    sourceUrl: (after && after.sourceUrl) || null,
    sourceUploader: _pickMiniCreatorField(source, after, "uploader"),
    sourceChannel: _pickMiniCreatorField(source, after, "channel"),
    status: (after && after.status) || null,
    isHidden: (after && after.isHidden) === true,
    calories,
    ingredientCount: ingredients.length,
    totalMinutes,
    categories,
    tags,
    saveCount,
    ...(sourceViewCount != null ? { sourceViewCount } : {}),
    socialSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

exports.syncSavedRecipeMiniDocs = functions
  .runWith({ timeoutSeconds: 300, memory: "256MB" })
  .firestore.document("recipes/{recipeId}")
  .onWrite(async (change, context) => {
    const recipeId = context.params.recipeId;
    const beforeExists = change.before.exists;
    const afterExists = change.after.exists;
    const before = beforeExists ? change.before.data() : null;
    const after = afterExists ? change.after.data() : null;

    // 삭제: 미니 doc 모두 제거.
    if (!afterExists) {
      try {
        const snap = await db
          .collectionGroup("savedRecipes")
          .where("recipeId", "==", recipeId)
          .get();
        if (snap.empty) return null;
        const batches = [];
        let batch = db.batch();
        let count = 0;
        for (const doc of snap.docs) {
          batch.delete(doc.ref);
          count += 1;
          if (count >= 400) {
            batches.push(batch.commit());
            batch = db.batch();
            count = 0;
          }
        }
        if (count > 0) batches.push(batch.commit());
        await Promise.all(batches);
      } catch (e) {
        console.error("[CF][syncSavedRecipeMiniDocs] delete propagation failed:", e);
      }
      return null;
    }

    // 생성: 신규 recipe — saveRecipe 클라가 동시에 미니 doc 도 만들 거라 별도 전파 불필요.
    if (!beforeExists) return null;

    // 업데이트: 카드 필드에 영향이 있는 변경인지 검사.
    const relevant = [
      "title",
      "thumbnailUrl",
      "thumbnailUrlLarge",
      "thumbnailUrlCropped",
      "calories",
      "status",
      "isHidden",
      "sourceUrl",
      "source",
      "recipe",
      "uploader",
      "channel",
      "categories",
      "tags",
    ];
    let changed = false;
    for (const k of relevant) {
      const a = before ? before[k] : undefined;
      const b = after ? after[k] : undefined;
      if (JSON.stringify(a) !== JSON.stringify(b)) {
        changed = true;
        break;
      }
    }
    if (!changed) return null;

    const patch = _buildSavedRecipeMiniPatch(after);
    try {
      const snap = await db
        .collectionGroup("savedRecipes")
        .where("recipeId", "==", recipeId)
        .get();
      if (snap.empty) return null;
      let batch = db.batch();
      let count = 0;
      const batches = [];
      for (const doc of snap.docs) {
        batch.update(doc.ref, patch);
        count += 1;
        if (count >= 400) {
          batches.push(batch.commit());
          batch = db.batch();
          count = 0;
        }
      }
      if (count > 0) batches.push(batch.commit());
      await Promise.all(batches);
    } catch (e) {
      console.error("[CF][syncSavedRecipeMiniDocs] update propagation failed:", e);
    }
    return null;
  });

// ---------------------------------------------------------------------------
// 옛 유저(서브컬렉션 미니 doc 없음)의 savedRecipes 배열 → 미니 doc 백필.
// /users/{uid}/savedRecipes/{rid} 가 비어있는 동안에는 클라 빠른 경로가
// 폴백되어 옛 N+1 path 로 떨어진다. 한 번 백필하면 다음 진입부터 빠른 경로.
//
// 호출:
//   curl -X POST "https://<region>-<project>.cloudfunctions.net/backfillSavedRecipesSubcollection" \
//        -H "Authorization: Bearer <admin-id-token>" \
//        -H "Content-Type: application/json" \
//        -d '{"dryRun": true}'
//   body 옵션:
//     dryRun?: boolean   – 기본 false. true 면 write 안 함.
//     userId?: string    – 특정 유저만 처리. 미지정 시 모든 유저.
exports.backfillSavedRecipesSubcollection = functions
  .runWith({ timeoutSeconds: 540, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== "POST") {
        res.status(405).json({ error: "method_not_allowed" });
        return;
      }
      const authHeader = (req.headers.authorization || "").toString();
      if (!authHeader.startsWith("Bearer ")) {
        res.status(401).json({ error: "missing_bearer_token" });
        return;
      }
      const idToken = authHeader.substring("Bearer ".length).trim();
      let decoded;
      try {
        decoded = await admin.auth().verifyIdToken(idToken);
      } catch (e) {
        res.status(401).json({ error: "invalid_token", detail: String(e && e.message || e) });
        return;
      }
      const email = decoded && decoded.email ? String(decoded.email) : "";
      const emailVerified = !!(decoded && decoded.email_verified);
      if (!email || !emailVerified) {
        res.status(403).json({ error: "email_not_verified" });
        return;
      }
      const adminSnap = await db.collection("admin_emails").doc(email).get();
      const adminActive = adminSnap.exists && (adminSnap.data() || {}).active === true;
      if (!adminActive) {
        res.status(403).json({ error: "not_admin" });
        return;
      }

      const body = (typeof req.body === "object" && req.body) ? req.body : {};
      const dryRun = body.dryRun === true;
      const userIdFilter = typeof body.userId === "string" ? body.userId : null;

      let usersScanned = 0;
      let usersWithSavedRecipes = 0;
      let miniDocsCreated = 0;
      let miniDocsUpdated = 0;
      let miniDocsSkipped = 0;
      let recipesMissing = 0;
      let errors = 0;

      const usersQuery = userIdFilter
        ? db.collection("users")
            .where(admin.firestore.FieldPath.documentId(), "==", userIdFilter)
        : db.collection("users");

      const userStream = usersQuery.stream();

      for await (const userDoc of userStream) {
        usersScanned += 1;
        const userData = userDoc.data() || {};
        const savedRecipes = Array.isArray(userData.savedRecipes)
          ? userData.savedRecipes.filter((x) => typeof x === "string" && x)
          : [];
        if (!savedRecipes.length) continue;
        usersWithSavedRecipes += 1;

        const savedAtMap = (userData.savedAt && typeof userData.savedAt === "object")
          ? userData.savedAt
          : {};
        // dot-notation key 도 함께 (savedAt.${recipeId})
        for (const [k, v] of Object.entries(userData)) {
          if (k.startsWith("savedAt.") && v) savedAtMap[k.substring(8)] = v;
        }

        for (const recipeId of savedRecipes) {
          try {
            const miniRef = db
              .collection("users")
              .doc(userDoc.id)
              .collection("savedRecipes")
              .doc(recipeId);
            const miniSnap = await miniRef.get();
            const recipeDoc = await db.collection("recipes").doc(recipeId).get();
            if (!recipeDoc.exists) {
              recipesMissing += 1;
              continue;
            }
            const r = recipeDoc.data() || {};
            if (miniSnap.exists) {
              if (!_miniDocNeedsFilterFieldsBackfill(miniSnap.data() || {})) {
                miniDocsSkipped += 1;
                continue;
              }
              const fullPatch = _buildSavedRecipeMiniPatch(r);
              const patch = {};
              if (_miniDocNeedsCreatorBackfill(miniSnap.data() || {})) {
                Object.assign(patch, _creatorFieldsPatchFromRecipe(r));
              }
              if (_miniDocNeedsCategoriesBackfill(miniSnap.data() || {})) {
                if (fullPatch.categories) patch.categories = fullPatch.categories;
                if (fullPatch.tags) patch.tags = fullPatch.tags;
              }
              if (!Object.keys(patch).length) {
                miniDocsSkipped += 1;
                continue;
              }
              if (!dryRun) {
                await miniRef.set(patch, { merge: true });
              }
              miniDocsUpdated += 1;
              continue;
            }
            const patch = _buildSavedRecipeMiniPatch(r);
            const mini = Object.assign({}, patch, {
              recipeId,
              createdAt: r.createdAt || null,
              savedAt: savedAtMap[recipeId] || r.createdAt || admin.firestore.FieldValue.serverTimestamp(),
            });
            if (!dryRun) {
              await miniRef.set(mini);
            }
            miniDocsCreated += 1;
          } catch (e) {
            errors += 1;
            console.error(`[CF][backfillSavedRecipesSubcollection] uid=${userDoc.id} rid=${recipeId} failed:`, e);
          }
        }
      }

      res.status(200).json({
        usersScanned,
        usersWithSavedRecipes,
        miniDocsCreated,
        miniDocsUpdated,
        miniDocsSkipped,
        recipesMissing,
        errors,
        dryRun,
        userIdFilter,
      });
    } catch (e) {
      console.error("[CF][backfillSavedRecipesSubcollection] failed:", e);
      res.status(500).json({ error: "internal", detail: String(e && e.message || e) });
    }
  });

// ---------------------------------------------------------------------------
// saveCount / monthlySaves 필드 백필.
// 옛 recipe doc 들은 saveCount/monthlySaves 필드가 없을 수 있어
// `orderBy('saveCount').limit(10)` 같은 인덱스 쿼리에 안 잡힌다.
// 필드 없는 doc 만 0 으로 채워서 인덱스에 포함되도록 한다 (기존 카운트 유지).
//
// 호출:
//   curl -X POST "https://<region>-<project>.cloudfunctions.net/backfillSaveCountFields" \
//        -H "Authorization: Bearer <admin-id-token>" \
//        -H "Content-Type: application/json" \
//        -d '{"dryRun": true}'
exports.backfillSaveCountFields = functions
  .runWith({ timeoutSeconds: 540, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== "POST") {
        res.status(405).json({ error: "method_not_allowed" });
        return;
      }
      const authHeader = (req.headers.authorization || "").toString();
      if (!authHeader.startsWith("Bearer ")) {
        res.status(401).json({ error: "missing_bearer_token" });
        return;
      }
      const idToken = authHeader.substring("Bearer ".length).trim();
      let decoded;
      try {
        decoded = await admin.auth().verifyIdToken(idToken);
      } catch (e) {
        res.status(401).json({ error: "invalid_token", detail: String(e && e.message || e) });
        return;
      }
      const email = decoded && decoded.email ? String(decoded.email) : "";
      const emailVerified = !!(decoded && decoded.email_verified);
      if (!email || !emailVerified) {
        res.status(403).json({ error: "email_not_verified" });
        return;
      }
      const adminSnap = await db.collection("admin_emails").doc(email).get();
      const adminActive = adminSnap.exists && (adminSnap.data() || {}).active === true;
      if (!adminActive) {
        res.status(403).json({ error: "not_admin" });
        return;
      }

      const body = (typeof req.body === "object" && req.body) ? req.body : {};
      const dryRun = body.dryRun === true;

      let scanned = 0;
      let missingSaveCount = 0;
      let missingMonthlySaves = 0;
      let updated = 0;

      const stream = db.collection("recipes")
        .select("saveCount", "monthlySaves", "weeklySaves")
        .stream();

      let batch = db.batch();
      let batchCount = 0;
      const BATCH_LIMIT = 400;

      for await (const doc of stream) {
        scanned += 1;
        const data = doc.data() || {};
        const patch = {};
        if (data.saveCount === undefined || data.saveCount === null) {
          patch.saveCount = 0;
          missingSaveCount += 1;
        }
        if (data.monthlySaves === undefined || data.monthlySaves === null) {
          patch.monthlySaves = 0;
          missingMonthlySaves += 1;
        }
        if (data.weeklySaves === undefined || data.weeklySaves === null) {
          patch.weeklySaves = 0;
        }
        if (Object.keys(patch).length === 0) continue;

        if (!dryRun) {
          batch.update(doc.ref, patch);
          batchCount += 1;
          updated += 1;
          if (batchCount >= BATCH_LIMIT) {
            await batch.commit();
            batch = db.batch();
            batchCount = 0;
          }
        } else {
          updated += 1;
        }
      }

      if (!dryRun && batchCount > 0) {
        await batch.commit();
      }

      res.status(200).json({
        scanned,
        missingSaveCount,
        missingMonthlySaves,
        updated,
        dryRun,
      });
    } catch (e) {
      console.error("[CF][backfillSaveCountFields] failed:", e);
      res.status(500).json({ error: "internal", detail: String(e && e.message || e) });
    }
  });

// ---------------------------------------------------------------------------
// sourceKey / sourceUrl 정규화 백필.
// 레거시 recipe 문서에서 sourceKey 누락 또는 sourceUrl 비정규화 상태를 배치 업데이트.
//
// 호출:
//   curl -X POST "https://<region>-<project>.cloudfunctions.net/backfillRecipeSourceKeys" \
//        -H "Authorization: Bearer <admin-id-token>" \
//        -H "Content-Type: application/json" \
//        -d '{"dryRun": true, "pageSize": 300, "maxRecipes": 3000}'
// body 옵션:
//   dryRun?: boolean      - 기본 false
//   pageSize?: number     - 기본 300 (최대 500)
//   maxRecipes?: number   - 기본 0(제한 없음)
//   startAfterId?: string - 문서 ID 기준 커서(이어달리기)
exports.backfillRecipeSourceKeys = functions
  .runWith({ timeoutSeconds: 540, memory: "1GB" })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== "POST") {
        res.status(405).json({ error: "method_not_allowed" });
        return;
      }
      const authHeader = (req.headers.authorization || "").toString();
      if (!authHeader.startsWith("Bearer ")) {
        res.status(401).json({ error: "missing_bearer_token" });
        return;
      }
      const idToken = authHeader.substring("Bearer ".length).trim();
      let decoded;
      try {
        decoded = await admin.auth().verifyIdToken(idToken);
      } catch (e) {
        res.status(401).json({ error: "invalid_token", detail: String(e && e.message || e) });
        return;
      }
      const email = decoded && decoded.email ? String(decoded.email) : "";
      const emailVerified = !!(decoded && decoded.email_verified);
      if (!email || !emailVerified) {
        res.status(403).json({ error: "email_not_verified" });
        return;
      }
      const adminSnap = await db.collection("admin_emails").doc(email).get();
      const adminActive = adminSnap.exists && (adminSnap.data() || {}).active === true;
      if (!adminActive) {
        res.status(403).json({ error: "not_admin" });
        return;
      }

      const body = (typeof req.body === "object" && req.body) ? req.body : {};
      const dryRun = body.dryRun === true;
      const pageSizeRaw = Number(body.pageSize);
      const pageSize = Number.isFinite(pageSizeRaw)
        ? Math.max(50, Math.min(500, Math.floor(pageSizeRaw)))
        : 300;
      const maxRecipesRaw = Number(body.maxRecipes);
      const maxRecipes = Number.isFinite(maxRecipesRaw) && maxRecipesRaw > 0
        ? Math.floor(maxRecipesRaw)
        : 0;
      let cursor = typeof body.startAfterId === "string" && body.startAfterId.trim()
        ? body.startAfterId.trim()
        : "";

      let scanned = 0;
      let withSourceUrl = 0;
      let candidates = 0;
      let updated = 0;
      let normalizedUrlUpdates = 0;
      let nestedUrlUpdates = 0;
      let sourceKeyUpdates = 0;
      let errors = 0;
      let hasMore = false;

      let writeBatch = db.batch();
      let writeCount = 0;
      const WRITE_LIMIT = 400;

      while (true) {
        let q = db.collection("recipes")
          .orderBy(admin.firestore.FieldPath.documentId())
          .limit(pageSize);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) {
          hasMore = false;
          break;
        }

        for (const doc of snap.docs) {
          scanned += 1;
          cursor = doc.id;
          try {
            const data = doc.data() || {};
            const source = (data.source && typeof data.source === "object") ? data.source : {};
            const sourceUrlTop = String(data.sourceUrl || "").trim();
            const sourceUrlNested = String(source.url || "").trim();
            if (sourceUrlTop || sourceUrlNested) withSourceUrl += 1;

            const patch = _buildRecipeSourcePatch(data);
            if (!patch) continue;

            candidates += 1;
            if (Object.prototype.hasOwnProperty.call(patch, "sourceUrl")) normalizedUrlUpdates += 1;
            if (Object.prototype.hasOwnProperty.call(patch, "source.url")) nestedUrlUpdates += 1;
            if (Object.prototype.hasOwnProperty.call(patch, "sourceKey")) sourceKeyUpdates += 1;

            if (!dryRun) {
              writeBatch.set(doc.ref, patch, { merge: true });
              writeCount += 1;
              if (writeCount >= WRITE_LIMIT) {
                await writeBatch.commit();
                writeBatch = db.batch();
                writeCount = 0;
              }
            }
            updated += 1;
          } catch (e) {
            errors += 1;
            console.error(`[CF][backfillRecipeSourceKeys] ${doc.id} failed:`, e);
          }

          if (maxRecipes > 0 && scanned >= maxRecipes) {
            hasMore = true;
            break;
          }
        }

        if (maxRecipes > 0 && scanned >= maxRecipes) break;
        if (snap.size < pageSize) {
          hasMore = false;
          break;
        }
      }

      if (!dryRun && writeCount > 0) {
        await writeBatch.commit();
      }

      res.status(200).json({
        scanned,
        withSourceUrl,
        candidates,
        updated,
        normalizedUrlUpdates,
        nestedUrlUpdates,
        sourceKeyUpdates,
        errors,
        dryRun,
        pageSize,
        maxRecipes,
        hasMore,
        nextCursor: hasMore ? cursor : null,
      });
    } catch (e) {
      console.error("[CF][backfillRecipeSourceKeys] failed:", e);
      res.status(500).json({ error: "internal", detail: String(e && e.message || e) });
    }
  });

