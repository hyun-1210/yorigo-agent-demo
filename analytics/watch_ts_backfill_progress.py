#!/usr/bin/env python3
"""백필(enqueueSource=backfill_v1)로 올라간 timestamp_jobs의 실제 진행/성공률을 확인.

job.status==done 은 타임스탬프가 실제로 생성됐는지와 무관하게 찍히므로
(complete_job이 성공/실패를 구분하지 않는 알려진 구조적 한계), 이 스크립트는
job 문서의 status 분포뿐 아니라 각 done job에 대해 대응하는 recipe 문서를
찾아 실제 start_sec 유무까지 교차 확인한다.

Run: python analytics/watch_ts_backfill_progress.py
"""

from __future__ import annotations

import json
import os
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
sys.path.insert(0, str(BACKEND))
os.chdir(BACKEND)

from firebase_admin import firestore  # noqa: E402
from google.cloud.firestore_v1 import FieldFilter  # noqa: E402
from services.firebase_service import get_firebase_service  # noqa: E402


def _has_ts(steps) -> tuple:
    if not isinstance(steps, list) or not steps:
        return "no_steps", 0
    n = len(steps)
    w = sum(1 for s in steps if isinstance(s, dict) and s.get("start_sec") is not None)
    if w == 0:
        return "none", n
    if w >= n:
        return "complete", n
    return "partial", n


def main() -> None:
    get_firebase_service()
    db = firestore.client()

    fields = [
        "platform",
        "status",
        "error",
        "attempts",
        "sourceKey",
        "recipeId",
        "cdnVideoUrl",
        "updatedAt",
    ]
    jobs = []
    for snap in (
        db.collection("timestamp_jobs")
        .where(filter=FieldFilter("enqueueSource", "==", "backfill_v1"))
        .select(fields)
        .stream()
    ):
        d = snap.to_dict() or {}
        d["_id"] = snap.id
        jobs.append(d)

    print(f"backfill jobs total: {len(jobs)}")
    by_status = Counter(j.get("status") for j in jobs)
    by_platform = Counter(j.get("platform") for j in jobs)
    print("by_status:", dict(by_status))
    print("by_platform:", dict(by_platform))

    failed = [j for j in jobs if j.get("status") == "failed"]
    err_bucket = Counter()
    for j in failed:
        e = (j.get("error") or "").lower()
        if "budget" in e:
            b = "budget_exceeded"
        elif "max_attempts" in e:
            b = "max_attempts"
        elif "cookie" in e:
            b = "cookie"
        elif "impersonate" in e:
            b = "impersonate"
        else:
            b = (j.get("error") or "none")[:60]
        err_bucket[b] += 1
    print("failed_error_buckets:", dict(err_bucket))

    done = [j for j in jobs if j.get("status") == "done"]
    print(f"\nChecking real writeback for {len(done)} done backfill jobs...")
    real_ts = 0
    false_done = 0
    no_recipe_found = 0
    checked = 0
    for j in done:
        rid = j.get("recipeId")
        sk = j.get("sourceKey")
        d = None
        if rid:
            snap = db.collection("recipes").document(rid).get()
            if snap.exists:
                d = snap.to_dict() or {}
        if d is None and sk:
            q = list(
                db.collection("recipes")
                .where(filter=FieldFilter("sourceKey", "==", sk))
                .select(["recipe.steps", "isHidden", "status"])
                .limit(5)
                .stream()
            )
            candidates = [s.to_dict() or {} for s in q]
            candidates = [c for c in candidates if not c.get("isHidden")] or candidates
            d = candidates[0] if candidates else None
        checked += 1
        if d is None:
            no_recipe_found += 1
            continue
        steps = ((d.get("recipe") or {}).get("steps") or [])
        status, n = _has_ts(steps)
        if status == "complete":
            real_ts += 1
        elif status == "partial":
            real_ts += 1  # 부분 성공도 진전으로 카운트
        else:
            false_done += 1

    print(f"checked={checked} real_success(complete/partial)={real_ts} "
          f"false_done(no ts written)={false_done} no_recipe_found={no_recipe_found}")

    if checked:
        rate = round(100.0 * real_ts / checked, 1)
        print(f"real success rate among done jobs: {rate}%")


if __name__ == "__main__":
    main()
