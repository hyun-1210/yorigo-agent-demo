#!/usr/bin/env python3
"""Firestore 레시피 타임스탬프(start_sec) 미작업 현황 + CDN URL(timestamp_jobs) 교차 분석.

판정:
  - 타임스탬프 완료: steps가 있고 모든 step에 start_sec 존재
  - 부분: 일부 step만 start_sec
  - 미작업: steps는 있으나 start_sec가 하나도 없음
  - CDN: timestamp_jobs.cdnVideoUrl / cdnAudioUrl (레시피 문서에는 보통 없음)

Run: python analytics/analyze_recipe_timestamp_cdn.py
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
OUT = ROOT / "analytics" / "recipe_timestamp_cdn_snapshot.json"

sys.path.insert(0, str(BACKEND))
os.chdir(BACKEND)

from services.firebase_service import get_firebase_service  # noqa: E402
from firebase_admin import firestore  # noqa: E402


YT_PATTERNS = (
    re.compile(r"[?&]v=([a-zA-Z0-9_-]+)"),
    re.compile(r"youtube\.com/shorts/([a-zA-Z0-9_-]+)"),
    re.compile(r"youtu\.be/([a-zA-Z0-9_-]+)"),
)
IG_RE = re.compile(r"instagram\.com/(?:reel|reels|p|tv)/([A-Za-z0-9_-]+)", re.I)
TK_RE = re.compile(r"/video/(\d+)")


def _cdn_host(url: str) -> Optional[str]:
    u = (url or "").strip()
    if not u.startswith("http"):
        return None
    try:
        return urlparse(u).netloc.lower() or None
    except Exception:
        return None


def _cdn_family(host: Optional[str]) -> str:
    if not host:
        return "none"
    h = host.lower()
    if "googlevideo.com" in h:
        return "yt_googlevideo"
    if "ytimg.com" in h or "ggpht.com" in h:
        return "yt_other"
    if "cdninstagram.com" in h or "fbcdn.net" in h or "instagram.com" in h:
        return "ig_cdn"
    if "tiktokcdn" in h or "tiktokv.com" in h or "musical.ly" in h:
        return "tt_cdn"
    if "byteoversea" in h or "ibyteimg" in h:
        return "tt_cdn"
    return "other"


def detect_platform(source: Dict[str, Any], source_url: str, source_key: str = "") -> str:
    plat = (source.get("platform") or "").strip().lower()
    url = (source_url or "").lower()
    sk = (source_key or "").lower()
    if plat in ("youtube", "instagram", "tiktok", "naver", "blog"):
        return plat
    if sk.startswith("youtube:") or "youtube.com" in url or "youtu.be" in url:
        return "youtube"
    if sk.startswith("instagram:") or "instagram.com" in url:
        return "instagram"
    if sk.startswith("tiktok:") or "tiktok.com" in url:
        return "tiktok"
    if "blog.naver" in url or "naver.com" in url:
        return "naver"
    if plat:
        return plat
    return "unknown"


def derive_source_key(platform: str, source_url: str, existing: str = "") -> str:
    if existing and ":" in existing:
        return existing
    url = source_url or ""
    if platform == "instagram":
        m = IG_RE.search(url)
        return f"instagram:{m.group(1)}" if m else existing or ""
    if platform == "tiktok":
        m = TK_RE.search(url)
        return f"tiktok:{m.group(1)}" if m else existing or ""
    if platform == "youtube":
        for pat in YT_PATTERNS:
            m = pat.search(url)
            if m:
                return f"youtube:{m.group(1)}"
        return existing or ""
    return existing or ""


def classify_steps(steps: Any) -> Tuple[str, int, int]:
    """(ts_status, step_count, steps_with_ts)."""
    if not isinstance(steps, list) or not steps:
        return "no_steps", 0, 0
    n = len(steps)
    with_ts = sum(
        1
        for s in steps
        if isinstance(s, dict) and s.get("start_sec") is not None
    )
    if with_ts == 0:
        return "none", n, 0
    if with_ts >= n:
        return "complete", n, with_ts
    return "partial", n, with_ts


def load_timestamp_jobs(db: Any) -> Dict[str, Dict[str, Any]]:
    """sourceKey -> job summary."""
    jobs: Dict[str, Dict[str, Any]] = {}
    fields = [
        "platform",
        "url",
        "sourceKey",
        "status",
        "cdnVideoUrl",
        "cdnAudioUrl",
        "attempts",
        "error",
        "createdAt",
        "updatedAt",
        "durationSec",
    ]
    n = 0
    for snap in db.collection("timestamp_jobs").select(fields).stream():
        n += 1
        data = snap.to_dict() or {}
        sk = (data.get("sourceKey") or "").strip()
        if not sk:
            # doc id: youtube_xxx / instagram_xxx
            did = snap.id
            if did.startswith("youtube_"):
                sk = "youtube:" + did[len("youtube_") :]
            elif did.startswith("instagram_"):
                sk = "instagram:" + did[len("instagram_") :]
            elif did.startswith("tiktok_"):
                sk = "tiktok:" + did[len("tiktok_") :]
            else:
                sk = did
        video = (data.get("cdnVideoUrl") or "").strip()
        audio = (data.get("cdnAudioUrl") or "").strip()
        host = _cdn_host(video)
        jobs[sk] = {
            "id": snap.id,
            "platform": (data.get("platform") or "").lower(),
            "status": data.get("status") or "unknown",
            "has_cdn_video": bool(video),
            "has_cdn_audio": bool(audio),
            "cdn_host": host,
            "cdn_family": _cdn_family(host),
            "attempts": int(data.get("attempts") or 0),
            "error": (data.get("error") or "")[:200] or None,
            "duration_sec": data.get("durationSec"),
        }
        if n % 2000 == 0:
            print(f"  timestamp_jobs loaded: {n}", flush=True)
    print(f"  timestamp_jobs total: {n} unique_keys={len(jobs)}", flush=True)
    return jobs


def main() -> None:
    print("=" * 70)
    print("Recipe timestamp + CDN coverage audit")
    print("=" * 70, flush=True)

    get_firebase_service()
    db = firestore.client()

    print("[1/3] Loading timestamp_jobs...", flush=True)
    jobs = load_timestamp_jobs(db)

    job_status = Counter(j["status"] for j in jobs.values())
    job_plat = Counter(j["platform"] or "unknown" for j in jobs.values())
    job_cdn = Counter()
    for j in jobs.values():
        key = f"{j['platform']}|{'cdn' if j['has_cdn_video'] else 'no_cdn'}|{j['status']}"
        job_cdn[key] += 1

    print("[2/3] Streaming recipes (projected fields)...", flush=True)
    recipe_fields = [
        "status",
        "isHidden",
        "sourceKey",
        "sourceUrl",
        "source",
        "recipe.steps",
        "recipe.title",
        "createdAt",
        "updatedAt",
    ]

    totals = Counter()
    by_platform = defaultdict(Counter)  # platform -> ts_status counts
    by_status_doc = defaultdict(Counter)  # firestore status -> ts_status
    # completed + video platforms focus
    focus = defaultdict(Counter)  # platform -> buckets

    # no-ts breakdown vs jobs/cdn
    no_ts = {
        "total": 0,
        "by_platform": Counter(),
        "by_doc_status": Counter(),
        "job": Counter(),  # none / pending / processing / done / failed / unknown
        "cdn_video": Counter(),  # has / missing (among those with job)
        "cdn_family": Counter(),
        "no_job_by_platform": Counter(),
        "has_job_has_cdn": Counter(),  # platform
        "has_job_no_cdn": Counter(),
        "partial_by_platform": Counter(),
    }

    # samples for inspection
    samples: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    SAMPLE_LIMIT = 8

    n = 0
    completed_video = 0
    for snap in db.collection("recipes").select(recipe_fields).stream():
        n += 1
        data = snap.to_dict() or {}
        doc_status = (data.get("status") or "unknown").lower()
        hidden = bool(data.get("isHidden"))
        source = data.get("source") if isinstance(data.get("source"), dict) else {}
        source_url = (
            (source.get("url") if isinstance(source, dict) else None)
            or data.get("sourceUrl")
            or ""
        )
        source_key_raw = (
            data.get("sourceKey")
            or (source.get("sourceKey") if isinstance(source, dict) else None)
            or ""
        )
        platform = detect_platform(source or {}, str(source_url), str(source_key_raw))
        source_key = derive_source_key(platform, str(source_url), str(source_key_raw or ""))

        recipe = data.get("recipe") if isinstance(data.get("recipe"), dict) else {}
        steps = recipe.get("steps") if isinstance(recipe, dict) else None
        ts_status, step_n, with_ts = classify_steps(steps)

        totals["recipes"] += 1
        totals[f"doc_status:{doc_status}"] += 1
        totals[f"ts:{ts_status}"] += 1
        if hidden:
            totals["hidden"] += 1
        by_platform[platform][ts_status] += 1
        by_status_doc[doc_status][ts_status] += 1

        is_video = platform in ("youtube", "instagram", "tiktok")
        is_focus = doc_status == "completed" and is_video and step_n > 0
        if is_focus:
            completed_video += 1
            focus[platform][ts_status] += 1
            focus["__all__"][ts_status] += 1

            job = jobs.get(source_key) if source_key else None
            if ts_status in ("none", "partial"):
                bucket = "no_ts" if ts_status == "none" else "partial"
                if ts_status == "none":
                    no_ts["total"] += 1
                    no_ts["by_platform"][platform] += 1
                    no_ts["by_doc_status"][doc_status] += 1
                    if job:
                        no_ts["job"][job["status"]] += 1
                        if job["has_cdn_video"]:
                            no_ts["cdn_video"]["has"] += 1
                            no_ts["cdn_family"][job["cdn_family"]] += 1
                            no_ts["has_job_has_cdn"][platform] += 1
                        else:
                            no_ts["cdn_video"]["missing"] += 1
                            no_ts["has_job_no_cdn"][platform] += 1
                    else:
                        no_ts["job"]["no_job"] += 1
                        no_ts["no_job_by_platform"][platform] += 1
                else:
                    no_ts["partial_by_platform"][platform] += 1

                sample_key = f"{bucket}|{platform}|{'cdn' if (job and job['has_cdn_video']) else ('job_no_cdn' if job else 'no_job')}"
                if len(samples[sample_key]) < SAMPLE_LIMIT:
                    samples[sample_key].append(
                        {
                            "recipe_id": snap.id,
                            "source_key": source_key,
                            "title": (recipe.get("title") if recipe else None),
                            "url": source_url[:120] if source_url else None,
                            "steps": step_n,
                            "steps_with_ts": with_ts,
                            "ts_status": ts_status,
                            "job_status": job["status"] if job else None,
                            "has_cdn_video": bool(job and job["has_cdn_video"]),
                            "has_cdn_audio": bool(job and job["has_cdn_audio"]),
                            "cdn_host": job["cdn_host"] if job else None,
                            "cdn_family": job["cdn_family"] if job else None,
                            "job_error": job["error"] if job else None,
                        }
                    )

        if n % 5000 == 0:
            print(f"  recipes scanned: {n}", flush=True)

    print(f"  recipes total scanned: {n}", flush=True)

    # Job-only summary for video platforms (useful even if recipe already done)
    jobs_summary = {
        "total": len(jobs),
        "by_status": dict(job_status),
        "by_platform": dict(job_plat),
        "by_platform_cdn_status": dict(job_cdn),
        "with_cdn_video": sum(1 for j in jobs.values() if j["has_cdn_video"]),
        "with_cdn_audio": sum(1 for j in jobs.values() if j["has_cdn_audio"]),
        "cdn_family": dict(Counter(j["cdn_family"] for j in jobs.values() if j["has_cdn_video"])),
        "pending_or_processing_with_cdn": sum(
            1
            for j in jobs.values()
            if j["status"] in ("pending", "processing") and j["has_cdn_video"]
        ),
        "pending_or_processing_without_cdn": sum(
            1
            for j in jobs.values()
            if j["status"] in ("pending", "processing") and not j["has_cdn_video"]
        ),
        "failed_with_cdn": sum(
            1 for j in jobs.values() if j["status"] == "failed" and j["has_cdn_video"]
        ),
        "failed_without_cdn": sum(
            1 for j in jobs.values() if j["status"] == "failed" and not j["has_cdn_video"]
        ),
        "done_with_cdn": sum(
            1 for j in jobs.values() if j["status"] == "done" and j["has_cdn_video"]
        ),
        "done_without_cdn": sum(
            1 for j in jobs.values() if j["status"] == "done" and not j["has_cdn_video"]
        ),
    }

    # Active queue by platform + cdn
    active_queue: Dict[str, Any] = {}
    for plat in ("youtube", "instagram", "tiktok"):
        subset = [j for j in jobs.values() if j["platform"] == plat and j["status"] in ("pending", "processing")]
        active_queue[plat] = {
            "active": len(subset),
            "with_cdn_video": sum(1 for j in subset if j["has_cdn_video"]),
            "without_cdn_video": sum(1 for j in subset if not j["has_cdn_video"]),
            "with_cdn_audio": sum(1 for j in subset if j["has_cdn_audio"]),
        }

    # Cross: completed video recipes without ts, but job is done (possible write-back miss)
    done_job_but_no_ts = 0
    for plat_counter in ():
        pass

    # Recompute done-job-but-recipe-still-none from samples path — scan focus keys via second pass too heavy;
    # track during main loop instead — add quick recount from no_ts job counter
    done_job_but_no_ts = int(no_ts["job"].get("done", 0))

    focus_out = {k: dict(v) for k, v in focus.items()}
    by_platform_out = {k: dict(v) for k, v in by_platform.items()}
    by_status_out = {k: dict(v) for k, v in by_status_doc.items()}

    snapshot = {
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "definitions": {
            "ts_complete": "all steps have start_sec",
            "ts_partial": "some but not all steps have start_sec",
            "ts_none": "steps exist but no start_sec",
            "ts_no_steps": "recipe.steps missing/empty",
            "focus_set": "status==completed AND platform in youtube|instagram|tiktok AND steps>0",
            "cdn": "timestamp_jobs.cdnVideoUrl / cdnAudioUrl matched by sourceKey",
        },
        "recipes_scanned": n,
        "totals": dict(totals),
        "by_platform_ts": by_platform_out,
        "by_doc_status_ts": by_status_out,
        "focus_completed_video_with_steps": {
            "total": completed_video,
            "by_ts_status": focus_out.get("__all__", {}),
            "by_platform": {k: v for k, v in focus_out.items() if k != "__all__"},
        },
        "no_timestamp_focus": {
            "total": no_ts["total"],
            "by_platform": dict(no_ts["by_platform"]),
            "job_status": dict(no_ts["job"]),
            "among_with_job_cdn_video": dict(no_ts["cdn_video"]),
            "cdn_family_when_has_cdn": dict(no_ts["cdn_family"]),
            "no_job_by_platform": dict(no_ts["no_job_by_platform"]),
            "has_job_has_cdn_by_platform": dict(no_ts["has_job_has_cdn"]),
            "has_job_no_cdn_by_platform": dict(no_ts["has_job_no_cdn"]),
            "partial_by_platform": dict(no_ts["partial_by_platform"]),
            "done_job_but_recipe_still_none": done_job_but_no_ts,
        },
        "timestamp_jobs": jobs_summary,
        "active_queue_by_platform": active_queue,
        "samples": {k: v for k, v in samples.items()},
    }

    # Rates
    focus_all = focus_out.get("__all__", {})
    focus_total = sum(focus_all.values()) or 1
    snapshot["rates"] = {
        "focus_ts_complete_pct": round(100.0 * focus_all.get("complete", 0) / focus_total, 2),
        "focus_ts_partial_pct": round(100.0 * focus_all.get("partial", 0) / focus_total, 2),
        "focus_ts_none_pct": round(100.0 * focus_all.get("none", 0) / focus_total, 2),
        "no_ts_with_cdn_pct_of_no_ts": round(
            100.0 * no_ts["cdn_video"].get("has", 0) / max(no_ts["total"], 1), 2
        ),
        "no_ts_with_job_pct_of_no_ts": round(
            100.0
            * (no_ts["total"] - no_ts["job"].get("no_job", 0))
            / max(no_ts["total"], 1),
            2,
        ),
    }

    OUT.write_text(json.dumps(snapshot, indent=2, ensure_ascii=False), encoding="utf-8")
    print("[3/3] Wrote", OUT, flush=True)
    print(json.dumps({
        "recipes_scanned": n,
        "focus_completed_video_with_steps": snapshot["focus_completed_video_with_steps"],
        "no_timestamp_focus": snapshot["no_timestamp_focus"],
        "timestamp_jobs": {
            "total": jobs_summary["total"],
            "by_status": jobs_summary["by_status"],
            "with_cdn_video": jobs_summary["with_cdn_video"],
            "active_queue_by_platform": active_queue,
        },
        "rates": snapshot["rates"],
    }, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
