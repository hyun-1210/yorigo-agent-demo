"""
로컬 uvicorn(127.0.0.1:8123)에 대해 /recommend_products_stream 실제 검증:
1. NDJSON 라인이 순차적으로(한 번에 몰리지 않고) 도착하는지 각 라인의 도착 시각을 기록.
2. 응답에 모든 items의 index가 정확히 한 번씩 포함되는지.
3. 동일 요청을 2번 보내 캐시 효과로 첫 응답까지의 시간(TTFB)이나 전체 소요시간이
   유의미하게 줄어드는지 비교 (문서 캐시 히트 시 Firestore 왕복 제거).
"""
import json
import time

import requests

BASE = "http://127.0.0.1:8123"

ITEMS = [
    {"ingredient_name": n, "original_ingredient_name": n, "needed_qty": 1, "needed_unit": "개", "limit": 10, "marketplace": mp}
    for n in ["대파", "마늘", "양파", "돼지고기", "간장", "계란"]
    for mp in ["coupang", "kurly"]
]


def run_once(label: str):
    t0 = time.perf_counter()
    first_line_t = None
    arrivals = []
    seen_idx = set()
    with requests.post(f"{BASE}/recommend_products_stream", json={"items": ITEMS}, stream=True, timeout=60) as r:
        r.raise_for_status()
        for raw_line in r.iter_lines(decode_unicode=True):
            if not raw_line:
                continue
            now = time.perf_counter()
            if first_line_t is None:
                first_line_t = now
            obj = json.loads(raw_line)
            idx = obj["index"]
            seen_idx.add(idx)
            has_best = bool((obj.get("result") or {}).get("best_match"))
            arrivals.append((round((now - t0) * 1000), idx, ITEMS[idx]["ingredient_name"], ITEMS[idx]["marketplace"], has_best))
    total_ms = (time.perf_counter() - t0) * 1000
    ttfb_ms = (first_line_t - t0) * 1000 if first_line_t else None
    print(f"\n=== {label} ===")
    for ms, idx, name, mp, has_best in arrivals:
        print(f"  t={ms:6.0f}ms idx={idx:2d} {mp:7s} {name:6s} best_match={has_best}")
    print(f"TTFB={ttfb_ms:.0f}ms total={total_ms:.0f}ms n_items={len(ITEMS)} received={len(seen_idx)}/{len(ITEMS)}")
    assert seen_idx == set(range(len(ITEMS))), f"누락된 index 있음: {set(range(len(ITEMS))) - seen_idx}"
    # 마지막 도착이 첫 도착보다 확실히 늦어야 progressive streaming이 의미 있음
    if len(arrivals) > 1:
        spread_ms = arrivals[-1][0] - arrivals[0][0]
        print(f"spread(first->last)={spread_ms}ms")
    return total_ms, ttfb_ms


if __name__ == "__main__":
    total1, ttfb1 = run_once("1st call (cold, Firestore reads expected)")
    total2, ttfb2 = run_once("2nd call (should hit product_doc_cache)")
    print(f"\ntotal_ms: 1st={total1:.0f} 2nd={total2:.0f} delta={total1-total2:.0f}ms")
    print("ALL CHECKS PASSED (index coverage OK)")
