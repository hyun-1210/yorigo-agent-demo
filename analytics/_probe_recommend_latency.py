"""Probe recommend/preprocess latency vs direct Firestore reads.

Compares production API hop vs client-style Firestore document get.
"""
from __future__ import annotations

import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError as e:  # pragma: no cover
    raise SystemExit(f"firebase_admin required: {e}") from e

ROOT = Path(__file__).resolve().parents[1]
SA = ROOT / "backend" / "firebase-service-account.json"
BASE = "https://yorigo-production.up.railway.app"

# Typical cart-sized ingredient set
INGREDIENTS = [
    ("양파", 1, "개"),
    ("마늘", 10, "g"),
    ("대파", 0.5, "개"),
    ("돼지고기", 300, "g"),
    ("계란", 2, "개"),
    ("간장", 15, "ml"),
    ("설탕", 10, "g"),
    ("고추장", 20, "g"),
    ("두부", 0.5, "모"),
    ("당근", 0.5, "개"),
    ("감자", 1, "개"),
    ("참기름", 5, "ml"),
]


def _init_fs() -> Any:
    if not firebase_admin._apps:
        cred = credentials.Certificate(str(SA))
        firebase_admin.initialize_app(cred)
    return firestore.client()


def timed_post(path: str, payload: dict[str, Any], timeout: float = 60.0) -> dict[str, Any]:
    t0 = time.perf_counter()
    try:
        r = requests.post(f"{BASE}{path}", json=payload, timeout=timeout)
        ms = (time.perf_counter() - t0) * 1000
        body_len = len(r.content or b"")
        return {
            "ok": r.status_code == 200,
            "status": r.status_code,
            "ms": round(ms, 1),
            "body_bytes": body_len,
            "json": r.json() if r.headers.get("content-type", "").startswith("application/json") else None,
            "error": None,
        }
    except Exception as e:
        ms = (time.perf_counter() - t0) * 1000
        return {
            "ok": False,
            "status": None,
            "ms": round(ms, 1),
            "body_bytes": 0,
            "json": None,
            "error": str(e),
        }


def fs_get_doc(db: Any, collection: str, doc_id: str) -> dict[str, Any]:
    t0 = time.perf_counter()
    try:
        snap = db.collection(collection).document(doc_id).get(timeout=5)
        ms = (time.perf_counter() - t0) * 1000
        products = []
        if snap.exists:
            data = snap.to_dict() or {}
            products = data.get("products") or []
        return {
            "collection": collection,
            "doc": doc_id,
            "exists": bool(snap.exists),
            "ms": round(ms, 1),
            "n_products": len(products) if isinstance(products, list) else 0,
            "error": None,
        }
    except Exception as e:
        ms = (time.perf_counter() - t0) * 1000
        return {
            "collection": collection,
            "doc": doc_id,
            "exists": False,
            "ms": round(ms, 1),
            "n_products": 0,
            "error": str(e),
        }


def main() -> None:
    names = [n for n, _, _ in INGREDIENTS]
    out: dict[str, Any] = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "base": BASE,
        "ingredients": names,
    }

    # 1) preprocess
    pre = timed_post("/preprocess_ingredients", {"ingredients": names}, timeout=45)
    out["preprocess"] = {
        "ms": pre["ms"],
        "ok": pre["ok"],
        "status": pre["status"],
        "error": pre["error"],
        "sample": (pre.get("json") or {}).get("preprocessed") if pre.get("json") else None,
    }
    print(f"[preprocess] {pre['ms']:.0f}ms ok={pre['ok']} status={pre['status']}")

    preprocessed = (pre.get("json") or {}).get("preprocessed") or {n: n for n in names}

    # 2) recommend batch — cart-like chunks of 5, concurrency 2
    items: list[dict[str, Any]] = []
    for name, qty, unit in INGREDIENTS:
        search = preprocessed.get(name, name)
        for mp in ("coupang", "kurly"):
            items.append(
                {
                    "ingredient_name": search if mp == "coupang" else name,
                    "original_ingredient_name": name,
                    "needed_qty": qty,
                    "needed_unit": unit,
                    "limit": 10,
                    "marketplace": mp,
                }
            )

    chunk_size = 5
    chunks = [items[i : i + chunk_size] for i in range(0, len(items), chunk_size)]
    chunk_results: list[dict[str, Any]] = []
    wall0 = time.perf_counter()

    def run_chunk(idx: int, chunk: list[dict[str, Any]]) -> dict[str, Any]:
        res = timed_post("/recommend_products_batch", {"items": chunk}, timeout=45)
        best = 0
        if res.get("json") and isinstance(res["json"].get("items"), list):
            for it in res["json"]["items"]:
                if isinstance(it, dict) and it.get("best_match"):
                    best += 1
        return {
            "idx": idx,
            "n": len(chunk),
            "ms": res["ms"],
            "ok": res["ok"],
            "status": res["status"],
            "body_bytes": res["body_bytes"],
            "best_match": best,
            "error": res["error"],
        }

    # concurrency=2 like cart
    with ThreadPoolExecutor(max_workers=2) as ex:
        futs = [ex.submit(run_chunk, i, c) for i, c in enumerate(chunks)]
        for f in as_completed(futs):
            cr = f.result()
            chunk_results.append(cr)
            print(
                f"[chunk {cr['idx']+1}/{len(chunks)}] {cr['ms']:.0f}ms "
                f"n={cr['n']} best={cr['best_match']} ok={cr['ok']}"
            )

    wall_ms = (time.perf_counter() - wall0) * 1000
    chunk_results.sort(key=lambda x: x["idx"])
    out["recommend_batch_cart_style"] = {
        "wall_ms": round(wall_ms, 1),
        "chunk_size": chunk_size,
        "concurrency": 2,
        "n_items": len(items),
        "chunks": chunk_results,
        "sum_chunk_ms": round(sum(c["ms"] for c in chunk_results), 1),
        "max_chunk_ms": round(max(c["ms"] for c in chunk_results), 1) if chunk_results else 0,
    }
    print(f"[batch wall] {wall_ms:.0f}ms for {len(items)} items in {len(chunks)} chunks")

    # 3) recipe-detail style: one mega batch
    mega = timed_post("/recommend_products_batch", {"items": items}, timeout=45)
    mega_best = 0
    if mega.get("json") and isinstance(mega["json"].get("items"), list):
        for it in mega["json"]["items"]:
            if isinstance(it, dict) and it.get("best_match"):
                mega_best += 1
    out["recommend_batch_recipe_style"] = {
        "ms": mega["ms"],
        "ok": mega["ok"],
        "status": mega["status"],
        "body_bytes": mega["body_bytes"],
        "n_items": len(items),
        "best_match": mega_best,
        "error": mega["error"],
    }
    print(
        f"[mega batch] {mega['ms']:.0f}ms n={len(items)} "
        f"best={mega_best} bytes={mega['body_bytes']}"
    )

    # 4) Direct Firestore gets (FE-style) — sequential vs parallel
    db = _init_fs()
    docs = [(name if mp == "coupang" else name, mp) for name, _, _ in INGREDIENTS for mp in ("coupang", "kurly")]
    # use preprocessed name for coupang doc id
    fs_targets: list[tuple[str, str]] = []
    for name, _, _ in INGREDIENTS:
        fs_targets.append(("coupang_products", preprocessed.get(name, name)))
        fs_targets.append(("kurly_products", name))

    seq0 = time.perf_counter()
    seq_rows = [fs_get_doc(db, col, doc) for col, doc in fs_targets]
    seq_ms = (time.perf_counter() - seq0) * 1000

    par0 = time.perf_counter()
    par_rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = [ex.submit(fs_get_doc, db, col, doc) for col, doc in fs_targets]
        for f in as_completed(futs):
            par_rows.append(f.result())
    par_ms = (time.perf_counter() - par0) * 1000

    out["firestore_direct"] = {
        "n_docs": len(fs_targets),
        "sequential_wall_ms": round(seq_ms, 1),
        "parallel_wall_ms": round(par_ms, 1),
        "sequential_sum_ms": round(sum(r["ms"] for r in seq_rows), 1),
        "exists": sum(1 for r in seq_rows if r["exists"]),
        "sample": seq_rows[:6],
    }
    print(
        f"[firestore] seq_wall={seq_ms:.0f}ms par_wall={par_ms:.0f}ms "
        f"exists={out['firestore_direct']['exists']}/{len(fs_targets)}"
    )

    out_path = ROOT / "analytics" / "recommend_latency_probe.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved {out_path}")

    print("\n=== SUMMARY ===")
    print(f"preprocess:              {out['preprocess']['ms']} ms")
    print(f"cart-style batch wall:   {out['recommend_batch_cart_style']['wall_ms']} ms")
    print(f"recipe mega batch:       {out['recommend_batch_recipe_style']['ms']} ms")
    print(f"FS direct sequential:    {out['firestore_direct']['sequential_wall_ms']} ms")
    print(f"FS direct parallel:      {out['firestore_direct']['parallel_wall_ms']} ms")
    print(
        "NOTE: FS direct is raw doc download only — no scoring/tags/deeplink/exclude."
    )


if __name__ == "__main__":
    main()
