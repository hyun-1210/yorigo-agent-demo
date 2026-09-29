"""홈 검색 도우미 라이브 평가. Firestore + LLM. 결과는 artifacts JSON.

  backend/.venv/bin/python scripts/qa_home_agent_eval.py
"""

from __future__ import annotations

import json
import os
import sys
import time
import types
from pathlib import Path
from typing import Any, Dict, List

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))


def _namespace(name: str, path: Path) -> None:
    if name in sys.modules:
        return
    pkg = types.ModuleType(name)
    pkg.__path__ = [str(path)]
    pkg.__file__ = str(path / "__init__.py")
    sys.modules[name] = pkg


_namespace("services", BACKEND / "services")

from services.home_agent_rank import reason_is_grounded
from services.home_agent_service import HomeAgentService, FirestoreHomeIndexReader
from services.firebase_service import get_firebase_service

PROMPTS: List[Dict[str, str]] = [
    {"id": "dish", "message": "김치찌개"},
    {"id": "recommend", "message": "김치찌개 추천해줘"},
    {"id": "doenjang", "message": "된장찌개 추천"},
    {"id": "spicy", "message": "매운 거 땡겨"},
    {"id": "spicy_kimchi", "message": "매운 김치찌개 추천"},
    {"id": "what", "message": "뭐 해먹지"},
    {"id": "leftover", "message": "닭가슴살 남은 거"},
    {"id": "egg", "message": "계란 남은 거"},
    {"id": "fast", "message": "10분 안에"},
    {"id": "hangover", "message": "해장"},
    {"id": "protein", "message": "고단백"},
    {"id": "less_spicy", "message": "김치찌개 덜 맵게"},
    {"id": "workout", "message": "운동 후에 든든하게 먹을 거"},
    {"id": "guest", "message": "손님 초대 저녁"},
    {"id": "dessert", "message": "달달한 거"},
    {"id": "late", "message": "야식"},
    {"id": "baby", "message": "이유식"},
    {"id": "off", "message": "숙제 수학 문제 풀어줘"},
]


def _judge(case: Dict[str, str], result: Dict[str, Any], cards: Dict[str, Any]) -> List[str]:
    issues: List[str] = []
    cid = case["id"]
    if cid == "off":
        if result.get("on_topic") is not False:
            issues.append("off_topic_not_blocked")
        if result.get("used_llm") or result.get("used_ranker"):
            issues.append("off_topic_used_llm")
        return issues
    if cid == "dish":
        if result.get("retrieve") != "client_search":
            issues.append("bare_dish_should_be_client_search")
        if result.get("used_llm") or result.get("used_ranker"):
            issues.append("bare_dish_should_skip_llm")
        return issues
    if not result.get("on_topic"):
        issues.append("expected_on_topic")
    if cid == "recommend" and not result.get("picks") and result.get("retrieve") == "client_search":
        issues.append("recommend_fell_back_to_client_search")
    picks = result.get("picks") or []
    for pick in picks:
        rid = pick.get("recipe_id")
        card = cards.get(rid)
        if card is None:
            issues.append(f"unknown_pick:{rid}")
            continue
        if not reason_is_grounded(str(pick.get("reason") or ""), card):
            issues.append(f"ungrounded:{rid}")
    if cid in ("guest", "dessert", "late", "baby"):
        if result.get("retrieve") == "client_search":
            issues.append("should_use_section_not_client_search")
        if not (result.get("picks") or result.get("recipe_ids")):
            issues.append("empty_section")
    if cid in ("recommend", "leftover", "protein", "fast", "what") and not picks and not result.get("q"):
        issues.append("empty_results")
    if cid == "spicy_kimchi":
        for pick in picks:
            card = cards.get(pick.get("recipe_id"))
            if card is None:
                continue
            if "김치찌개" not in card.name:
                issues.append(f"off_dish:{card.name}")
    return issues


def main() -> int:
    fb = get_firebase_service()
    if fb.db is None:
        print("firestore_unavailable", file=sys.stderr)
        return 2
    store = FirestoreHomeIndexReader(fb.db)
    service = HomeAgentService(reader=store, card_reader=store)
    rows: List[Dict[str, Any]] = []
    fail = 0
    for case in PROMPTS:
        t0 = time.time()
        result = service.run_turn(
            chip_id=None,
            message=case["message"],
            focus_ingredient=None,
            history=[],
        )
        elapsed_ms = int((time.time() - t0) * 1000)
        ids = list(result.get("recipe_ids") or [])
        cards = {c.id: c for c in store.compact_cards(ids, 8)} if ids else {}
        # 이미 턴에서 읽었지만 평가용 재조회(최대 8). QA 전용.
        named_picks = []
        for p in result.get("picks") or []:
            rid = p.get("recipe_id")
            card = cards.get(rid)
            named_picks.append(
                {
                    **p,
                    "name": card.name if card else "",
                    "ingredients": list(card.ingredients[:6]) if card else [],
                    "tags": list(card.tags) if card else [],
                    "cook_time": list(card.cook_time) if card else [],
                }
            )
        issues = _judge(case, result, cards)
        if issues:
            fail += 1
        row = {
            "id": case["id"],
            "message": case["message"],
            "elapsed_ms": elapsed_ms,
            "retrieve": result.get("retrieve"),
            "used_llm": result.get("used_llm"),
            "used_ranker": result.get("used_ranker"),
            "spice_high": result.get("spice_high"),
            "spice_low": result.get("spice_low"),
            "q": result.get("q"),
            "section_key": result.get("section_key"),
            "engine": result.get("engine"),
            "reply": result.get("reply"),
            "warnings": result.get("warnings"),
            "picks": named_picks,
            "issues": issues,
        }
        rows.append(row)
        print(
            f"{case['id']:12} {elapsed_ms:5}ms retrieve={result.get('retrieve')} "
            f"llm={result.get('used_llm')} rank={result.get('used_ranker')} "
            f"picks={len(named_picks)} issues={issues or '-'}",
            flush=True,
        )
        for p in named_picks:
            print(f"    - {p.get('name') or p.get('recipe_id')}: {p.get('reason')}", flush=True)

    out_dir = Path("/opt/cursor/artifacts")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "home_agent_eval.json"
    payload = {"fail": fail, "total": len(rows), "cases": rows}
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[eval] {fail}/{len(rows)} with issues → {out_path}", flush=True)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
