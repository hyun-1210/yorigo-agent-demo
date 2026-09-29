#!/usr/bin/env python3
"""기존 레시피의 카드 칩·상황 태그·한줄소개만 다시 쓴다.

영상 재파싱·영양 재계산은 하지 않는다. 원문은 recipes.parseArtifacts 또는
parseInputs.calls 를 쓰고, 둘 다 없으면 건너뛴다.

기본 엔진은 Gemini. DEEPSEEK_API_KEY가 있으면 Gemini 실패 시에만 폴백한다.
TAG_CHARACTER_ENGINE=deepseek 로 순서를 뒤집을 수 있다.

Mac mini에서 실행:
  python scripts/backfill_tags_taglines.py --limit 20
  python scripts/backfill_tags_taglines.py --apply --workers 3
  python scripts/backfill_tags_taglines.py --apply --force   # 이미 chips_v2 인 것도 다시
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
os.chdir(BACKEND)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from dotenv import load_dotenv

load_dotenv(BACKEND / ".env")

from google.cloud.firestore import DELETE_FIELD, SERVER_TIMESTAMP

from services.firebase_service import get_firebase_service
from services.llm_service import LLMService
from services.recipe_service import RecipeService

CHECKPOINT = BACKEND / "scripts" / "_backfill_tags_checkpoint.json"
PAGE_SIZE = 200
MIN_RAW_CHARS_DEFAULT = 20


def _svc() -> RecipeService:
    return RecipeService(llm_service=LLMService())


def _merge_calls(calls: Any) -> Tuple[str, str, str]:
    title = desc = spoken = ""
    if not isinstance(calls, list):
        return title, desc, spoken
    for call in calls:
        if not isinstance(call, dict):
            continue
        t = str(call.get("title") or "").strip()
        d = str(call.get("description") or "").strip()
        cap = str(call.get("captions") or "").strip()
        if t and len(t) > len(title):
            title = t
        if d and len(d) > len(desc):
            desc = d
        if cap and len(cap) > len(spoken):
            spoken = cap
    return title, desc, spoken


def _raw_from_docs(
    data: Dict[str, Any], pin: Optional[Dict[str, Any]]
) -> Tuple[str, str, str, int]:
    artifacts = data.get("parseArtifacts")
    desc = captions = whisper = ocr = pin_title = ""
    if isinstance(artifacts, dict):
        desc = str(artifacts.get("description") or "").strip()
        captions = str(artifacts.get("captions") or "").strip()
        whisper = str(artifacts.get("whisper") or "").strip()
        ocr = str(artifacts.get("ocr") or "").strip()
    if isinstance(pin, dict):
        pin_title, pin_desc, pin_spoken = _merge_calls(pin.get("calls"))
        if not desc:
            desc = pin_desc
        if not captions:
            captions = pin_spoken
    spoken_parts = [p for p in (captions, whisper, ocr) if p]
    spoken = "\n".join(spoken_parts)
    n = len(desc) + len(spoken)
    return pin_title, desc, spoken, n


def _load_checkpoint() -> Dict[str, Any]:
    if not CHECKPOINT.exists():
        return {}
    try:
        return json.loads(CHECKPOINT.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_checkpoint(payload: Dict[str, Any]) -> None:
    payload["updatedAt"] = datetime.now(timezone.utc).isoformat()
    CHECKPOINT.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def _build_update(
    svc: RecipeService,
    data: Dict[str, Any],
    char: Dict[str, Any],
) -> Dict[str, Any]:
    tags = list(char.get("tags") or [])
    occasions = list(char.get("occasion_tags") or [])
    tagline = str(char.get("tagline") or "").strip()[:80]
    products = char.get("mentioned_products") or []
    rating = str(char.get("nutrition_rating") or "A")
    if rating not in {"A", "B", "C"}:
        rating = "A"
    chef_tag = svc.extract_chef_tag(tags)
    source = data.get("source")
    source = dict(source) if isinstance(source, dict) else {}
    source["tags"] = tags
    source["occasionTags"] = occasions
    source["tagline"] = tagline
    source["mentionedProducts"] = products
    source["nutrition_rating"] = rating
    update: Dict[str, Any] = {
        "tags": tags,
        "occasionTags": occasions,
        "tagline": tagline,
        "mentionedProducts": products if isinstance(products, list) else [],
        "nutrition_rating": rating,
        "source": source,
        "tagPipelineVersion": RecipeService.TAG_PIPELINE_VERSION,
        "tagBackfilledAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    }
    update["chefTag"] = chef_tag if chef_tag else DELETE_FIELD
    return update


def _enrich_one(
    svc: RecipeService,
    recipe_id: str,
    data: Dict[str, Any],
    pin: Optional[Dict[str, Any]],
    min_raw: int,
) -> Dict[str, Any]:
    rec = data.get("recipe") if isinstance(data.get("recipe"), dict) else {}
    src = data.get("source") if isinstance(data.get("source"), dict) else {}
    pin_title, desc, spoken, n_raw = _raw_from_docs(data, pin)
    title = str(
        rec.get("name") or data.get("title") or src.get("title") or pin_title or ""
    ).strip()
    if n_raw < min_raw:
        return {"id": recipe_id, "ok": False, "skip": "no_raw", "raw_chars": n_raw, "title": title}
    cats = data.get("categories") or src.get("categories") or {}
    t0 = time.perf_counter()
    char = svc._enrich_recipe_character(
        recipe=rec,
        title=title,
        description=desc,
        transcript=spoken,
        tags_raw=list(data.get("tags") or src.get("tags") or []),
        uploader=str(src.get("uploader") or ""),
        channel=str(src.get("channel") or ""),
        nutrition=data.get("nutrition"),
        categories=cats if isinstance(cats, dict) else {},
    )
    ms = int((time.perf_counter() - t0) * 1000)
    return {
        "id": recipe_id,
        "ok": True,
        "title": title,
        "raw_chars": n_raw,
        "chips": char.get("tags") or [],
        "occasions": char.get("occasion_tags") or [],
        "tagline": char.get("tagline") or "",
        "ms": ms,
        "update": _build_update(svc, data, char),
    }


def _iter_pages(db: Any, start_after_id: str = ""):
    col = db.collection("recipes").order_by("__name__")
    last_snap = None
    if start_after_id:
        last_snap = db.collection("recipes").document(start_after_id).get()
        if not last_snap.exists:
            last_snap = None
    while True:
        q = col.limit(PAGE_SIZE)
        if last_snap is not None:
            q = q.start_after(last_snap)
        snaps = list(q.stream())
        if not snaps:
            return
        yield snaps
        last_snap = snaps[-1]


def _eligible(
    recipe_id: str,
    data: Dict[str, Any],
    args: argparse.Namespace,
    version: str,
    stats: Dict[str, int],
) -> bool:
    stats["seen"] += 1
    if data.get("isHidden") is True:
        stats["skip_hidden"] += 1
        return False
    if (data.get("status") or "") != "completed":
        stats["skip_status"] += 1
        return False
    if not args.force and str(data.get("tagPipelineVersion") or "") == version:
        stats["skip_version"] += 1
        return False
    return True


def _attempted(stats: Dict[str, int]) -> int:
    return stats["ok"] + stats["fail"] + stats["skip_no_raw"]


def main() -> int:
    parser = argparse.ArgumentParser(description="카드 칩·상황 태그·한줄소개 백필")
    parser.add_argument("--apply", action="store_true", help="Firestore에 실제로 쓴다")
    parser.add_argument("--force", action="store_true", help="chips_v2 문서도 다시 돌린다")
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--limit", type=int, default=0, help="처리 시도 상한 (0=전부)")
    parser.add_argument("--min-raw-chars", type=int, default=MIN_RAW_CHARS_DEFAULT)
    parser.add_argument("--recipe-id", action="append", default=[], help="특정 id만")
    parser.add_argument("--resume", action="store_true", help="체크포인트 last_id 다음부터")
    args = parser.parse_args()

    fb = get_firebase_service()
    db = fb.db
    if db is None:
        raise RuntimeError("Firestore unavailable")
    if not (os.getenv("DEEPSEEK_API_KEY") or os.getenv("GEMINI_API_KEY")):
        raise RuntimeError("DEEPSEEK_API_KEY or GEMINI_API_KEY missing")

    svc = _svc()
    checkpoint = _load_checkpoint()
    stats = {
        "seen": 0,
        "ok": 0,
        "wrote": 0,
        "skip_hidden": 0,
        "skip_status": 0,
        "skip_version": 0,
        "skip_no_raw": 0,
        "fail": 0,
    }
    start_after = checkpoint.get("last_id") or "" if args.resume else ""
    version = RecipeService.TAG_PIPELINE_VERSION
    cap = args.limit if args.limit else 10**9
    print(
        f"[backfill] apply={args.apply} force={args.force} workers={args.workers} "
        f"limit={args.limit or 'all'} resume_after={start_after or '-'} version={version}",
        flush=True,
    )

    def collect(snaps: List[Any]) -> Tuple[List[Tuple[str, Dict[str, Any]]], str]:
        batch: List[Tuple[str, Dict[str, Any]]] = []
        last_considered = ""
        for snap in snaps:
            if _attempted(stats) + len(batch) >= cap:
                break
            last_considered = snap.id
            data = snap.to_dict() or {}
            if _eligible(snap.id, data, args, version, stats):
                batch.append((snap.id, data))
        return batch, last_considered

    if args.recipe_id:
        refs = [db.collection("recipes").document(i) for i in args.recipe_id]
        items: List[Tuple[str, Dict[str, Any]]] = []
        for snap in db.get_all(refs):
            if not snap.exists:
                print(f"  missing {snap.id}", flush=True)
                continue
            data = snap.to_dict() or {}
            if _eligible(snap.id, data, args, version, stats):
                items.append((snap.id, data))
        _run_batch(db, svc, items, args, stats, checkpoint)
        print(f"[backfill] done {stats}", flush=True)
        return 0 if stats["fail"] == 0 else 1

    for snaps in _iter_pages(db, start_after):
        if _attempted(stats) >= cap:
            break
        batch, last_considered = collect(snaps)
        if batch:
            _run_batch(db, svc, batch, args, stats, checkpoint)
        if last_considered:
            checkpoint["last_id"] = last_considered
        checkpoint["stats"] = stats
        _save_checkpoint(checkpoint)
        print(f"[backfill] page last={last_considered or snaps[-1].id} {stats}", flush=True)
        if _attempted(stats) >= cap:
            break

    print(f"[backfill] done {stats}", flush=True)
    return 0 if stats["fail"] == 0 else 1


def _run_batch(
    db: Any,
    svc: RecipeService,
    items: List[Tuple[str, Dict[str, Any]]],
    args: argparse.Namespace,
    stats: Dict[str, int],
    checkpoint: Dict[str, Any],
) -> None:
    if not items:
        return
    pin_refs = [db.collection("parseInputs").document(rid) for rid, _ in items]
    pins = {s.id: (s.to_dict() or {}) for s in db.get_all(pin_refs) if s.exists}

    def work(pair: Tuple[str, Dict[str, Any]]) -> Dict[str, Any]:
        recipe_id, data = pair
        try:
            return _enrich_one(
                svc, recipe_id, data, pins.get(recipe_id), args.min_raw_chars
            )
        except Exception as exc:
            return {
                "id": recipe_id,
                "ok": False,
                "fail": True,
                "error": f"{exc}\n{traceback.format_exc()}",
            }

    workers = max(1, args.workers)
    results: List[Dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(work, pair) for pair in items]
        for fut in as_completed(futs):
            results.append(fut.result())

    for row in results:
        rid = row.get("id") or ""
        if row.get("skip") == "no_raw":
            stats["skip_no_raw"] += 1
            print(f"  skip no_raw {rid} chars={row.get('raw_chars')}", flush=True)
            continue
        if row.get("fail") or not row.get("ok"):
            stats["fail"] += 1
            print(f"  FAIL {rid} {str(row.get('error') or '')[:240]}", flush=True)
            continue
        stats["ok"] += 1
        chips = ",".join(row.get("chips") or [])
        occ = ",".join(row.get("occasions") or [])
        line = row.get("tagline") or ""
        print(
            f"  ok {rid} {row.get('ms')}ms chips=[{chips}] occ=[{occ}] line={line}",
            flush=True,
        )
        if not args.apply:
            continue
        try:
            db.collection("recipes").document(rid).set(row["update"], merge=True)
            stats["wrote"] += 1
        except Exception as exc:
            stats["fail"] += 1
            print(f"  WRITE FAIL {rid} {exc}", flush=True)
        checkpoint["last_id"] = rid
        checkpoint["stats"] = stats
    _save_checkpoint(checkpoint)


if __name__ == "__main__":
    raise SystemExit(main())
