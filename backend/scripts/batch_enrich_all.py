"""
Batch timestamp enrichment for ALL YouTube recipes in the database.
Uses the running backend's /enrich-timestamps API (cookies handled there).
Rate-limited: 6 per batch, 40s between batches, 5s between recipes.
Logs everything and saves a report at the end.
"""

import sys, os, json, time, requests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import firebase_admin
from firebase_admin import credentials, firestore

if not firebase_admin._apps:
    cred = credentials.Certificate(
        os.path.join(os.path.dirname(__file__), "..", "firebase-service-account.json")
    )
    firebase_admin.initialize_app(cred)
db = firestore.client()

BACKEND_URL = "http://localhost:8000/enrich-timestamps"
BATCH_SIZE = 6
BATCH_PAUSE_SEC = 40
PER_RECIPE_PAUSE_SEC = 5

results = {"vtt": [], "whisper": [], "ocr": [], "failed": [], "skipped_already": [], "skipped_no_steps": [], "skipped_not_yt": []}


def get_all_youtube_recipes():
    print("Fetching all recipes from Firestore...", flush=True)
    recipes = []
    for doc in db.collection("recipes").stream():
        d = doc.to_dict() or {}
        src = d.get("source", {})
        sk = src.get("sourceKey") or ""
        src_url = src.get("url") or d.get("sourceUrl") or ""
        is_yt = sk.startswith("youtube:") or "youtube" in src_url.lower() or "youtu.be" in src_url.lower()
        steps = d.get("recipe", {}).get("steps", [])
        step_dicts = [s for s in steps if isinstance(s, dict)]
        has_ts = any(s.get("start_sec") is not None for s in step_dicts)
        title = d.get("title") or d.get("recipe", {}).get("name") or "(untitled)"
        recipes.append({
            "id": doc.id,
            "title": title,
            "is_youtube": is_yt,
            "has_steps": len(step_dicts) > 0,
            "has_timestamps": has_ts,
            "step_count": len(step_dicts),
        })
    return recipes


def enrich_via_api(recipe_id):
    try:
        resp = requests.post(BACKEND_URL, json={"recipe_id": recipe_id}, timeout=120)
        return resp.json()
    except Exception as e:
        return {"error": str(e)}


def main():
    print(f"{'=' * 60}", flush=True)
    print(f"  Batch Timestamp Enrichment — ALL YouTube Recipes", flush=True)
    print(f"  Backend: {BACKEND_URL}", flush=True)
    print(f"{'=' * 60}\n", flush=True)

    all_recipes = get_all_youtube_recipes()
    print(f"Total recipes in DB: {len(all_recipes)}\n", flush=True)

    to_process = []
    for r in all_recipes:
        if not r["is_youtube"]:
            results["skipped_not_yt"].append(r["title"])
        elif not r["has_steps"]:
            results["skipped_no_steps"].append(r["title"])
        elif r["has_timestamps"]:
            results["skipped_already"].append(r["title"])
        else:
            to_process.append(r)

    print(f"-- Pre-filter --", flush=True)
    print(f"  YouTube needing enrichment: {len(to_process)}", flush=True)
    print(f"  Already have timestamps:    {len(results['skipped_already'])}", flush=True)
    print(f"  Not YouTube:                {len(results['skipped_not_yt'])}", flush=True)
    print(f"  No steps:                   {len(results['skipped_no_steps'])}", flush=True)

    total_batches = (len(to_process) + BATCH_SIZE - 1) // BATCH_SIZE
    est_minutes = (len(to_process) * PER_RECIPE_PAUSE_SEC + total_batches * BATCH_PAUSE_SEC) // 60
    print(f"\n  Estimated time: ~{est_minutes} minutes ({total_batches} batches)", flush=True)
    print(f"\n-- Processing ({BATCH_SIZE}/batch, {BATCH_PAUSE_SEC}s pause) --\n", flush=True)

    for i, recipe in enumerate(to_process):
        in_batch = i % BATCH_SIZE

        if in_batch == 0 and i > 0:
            print(f"\n  ... batch pause ({BATCH_PAUSE_SEC}s) ...\n", flush=True)
            time.sleep(BATCH_PAUSE_SEC)

        title_short = recipe["title"][:40]
        print(f"  [{i+1}/{len(to_process)}] {title_short}...", end=" ", flush=True)

        resp = enrich_via_api(recipe["id"])

        if "error" in resp and resp["error"]:
            err = resp["error"]
            if "No timed captions" in str(err):
                results["failed"].append({"title": recipe["title"], "id": recipe["id"], "error": "no_captions"})
                print(f"X no captions", flush=True)
            else:
                results["failed"].append({"title": recipe["title"], "id": recipe["id"], "error": str(err)[:80]})
                print(f"X {str(err)[:60]}", flush=True)
        else:
            method = resp.get("timestamp_source", "unknown")
            ts = resp.get("step_timestamps", [])
            if method in results:
                results[method].append({"title": recipe["title"], "id": recipe["id"], "timestamps": ts})
            else:
                results["failed"].append({"title": recipe["title"], "id": recipe["id"], "error": f"unknown: {method}"})
            ts_str = ", ".join(str(t) for t in ts if t is not None)
            print(f"OK {method.upper()} [{ts_str}]", flush=True)

        time.sleep(PER_RECIPE_PAUSE_SEC)

    # ── Report ──
    total = len(to_process)
    vtt_n = len(results["vtt"])
    whisper_n = len(results["whisper"])
    ocr_n = len(results["ocr"])
    fail_n = len(results["failed"])

    print(f"\n{'=' * 60}", flush=True)
    print(f"  ENRICHMENT REPORT", flush=True)
    print(f"{'=' * 60}", flush=True)
    print(f"  Total YouTube processed:       {total}", flush=True)
    print(f"  Already had timestamps:        {len(results['skipped_already'])}", flush=True)
    print(f"  Non-YouTube (skipped):         {len(results['skipped_not_yt'])}", flush=True)
    print(f"  No steps (skipped):            {len(results['skipped_no_steps'])}", flush=True)
    print(f"{'-' * 60}", flush=True)

    if total > 0:
        print(f"  VTT captions:   {vtt_n:>3}  ({vtt_n/total*100:.1f}%)", flush=True)
        print(f"  Whisper ASR:    {whisper_n:>3}  ({whisper_n/total*100:.1f}%)", flush=True)
        print(f"  OCR:            {ocr_n:>3}  ({ocr_n/total*100:.1f}%)", flush=True)
        print(f"  Failed:         {fail_n:>3}  ({fail_n/total*100:.1f}%)", flush=True)
        success = vtt_n + whisper_n + ocr_n
        print(f"{'-' * 60}", flush=True)
        print(f"  Success rate: {success}/{total} ({success/total*100:.1f}%)", flush=True)
    print(f"{'=' * 60}", flush=True)

    if results["failed"]:
        print(f"\n  Failed recipes:", flush=True)
        for f in results["failed"]:
            print(f"    - {f['title'][:50]} | {f['error']}", flush=True)

    # Save JSON report
    report_path = os.path.join(os.path.dirname(__file__), "enrichment_report.json")
    with open(report_path, "w", encoding="utf-8") as fp:
        json.dump({
            "total_processed": total,
            "vtt_count": vtt_n, "whisper_count": whisper_n, "ocr_count": ocr_n, "failed_count": fail_n,
            "vtt": [{"title": r["title"], "id": r["id"]} for r in results["vtt"]],
            "whisper": [{"title": r["title"], "id": r["id"]} for r in results["whisper"]],
            "ocr": [{"title": r["title"], "id": r["id"]} for r in results["ocr"]],
            "failed": results["failed"],
            "skipped_already": results["skipped_already"],
            "skipped_not_yt": results["skipped_not_yt"],
            "skipped_no_steps": results["skipped_no_steps"],
        }, fp, ensure_ascii=False, indent=2)
    print(f"\n  JSON report saved: {report_path}", flush=True)


if __name__ == "__main__":
    main()
