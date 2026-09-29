"""다양한 사용자 입장 질문을 홈 검색 도우미에 넣고 결과를 남긴다.

  backend/.venv/bin/python scripts/qa_home_agent_persona_sweep.py
"""

from __future__ import annotations

import json
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

from services.home_agent_service import FirestoreHomeIndexReader, HomeAgentService
from services.firebase_service import get_firebase_service

# persona: 실제 검색창에 칠 법한 말. 한 사용자는 여러 페르소나에 겹칠 수 있다.
CASES: List[Dict[str, str]] = [
    # 1. 요리명만 치는 사람
    {"persona": "요리명 검색", "id": "dish_kimchi", "message": "김치찌개"},
    {"persona": "요리명 검색", "id": "dish_pasta", "message": "크림파스타"},
    {"persona": "요리명 검색", "id": "dish_gyudon", "message": "규동"},
    {"persona": "요리명 검색", "id": "dish_tteok", "message": "떡볶이"},
    {"persona": "요리명 검색", "id": "dish_salad", "message": "샐러드"},
    # 2. 추천을 원하는 사람
    {"persona": "요리 추천", "id": "rec_kimchi", "message": "김치찌개 추천해줘"},
    {"persona": "요리 추천", "id": "rec_pasta", "message": "파스타 추천"},
    {"persona": "요리 추천", "id": "rec_show", "message": "비빔밥 보여줘"},
    {"persona": "요리 추천", "id": "rec_find", "message": "된장찌개 찾아줘"},
    {"persona": "요리 추천", "id": "rec_best", "message": "라면 뭐가 좋아"},
    # 3. 오늘 뭐 먹지
    {"persona": "메뉴 고민", "id": "what_eat", "message": "뭐 해먹지"},
    {"persona": "메뉴 고민", "id": "what_today", "message": "오늘 저녁 뭐 먹지"},
    {"persona": "메뉴 고민", "id": "what_solo", "message": "혼자 먹기 좋은 거"},
    {"persona": "메뉴 고민", "id": "what_lunch", "message": "점심 뭐하지"},
    # 4. 냉장고 남은 재료
    {"persona": "남은 재료", "id": "left_chicken", "message": "닭가슴살 남은 거"},
    {"persona": "남은 재료", "id": "left_egg", "message": "계란 남은 거"},
    {"persona": "남은 재료", "id": "left_tofu", "message": "두부 남은 거"},
    {"persona": "남은 재료", "id": "left_pork", "message": "남은 삼겹살"},
    {"persona": "남은 재료", "id": "left_kimchi", "message": "김치 남은 거"},
    {"persona": "남은 재료", "id": "have_onion", "message": "양파 있는데 뭐 해먹지"},
    {"persona": "남은 재료", "id": "no_egg", "message": "계란 없이 만들 수 있는 거"},
    # 5. 바쁜 사람
    {"persona": "시간 없음", "id": "fast_10", "message": "10분 안에"},
    {"persona": "시간 없음", "id": "fast_word", "message": "빨리 만들 수 있는 거"},
    {"persona": "시간 없음", "id": "fast_30", "message": "30분 안에 저녁"},
    {"persona": "시간 없음", "id": "fast_chicken", "message": "닭가슴살로 10분"},
    # 6. 매운맛 / 순한맛
    {"persona": "맵기", "id": "spicy_crave", "message": "매운 거 땡겨"},
    {"persona": "맵기", "id": "spicy_dish", "message": "매운 김치찌개 추천"},
    {"persona": "맵기", "id": "mild_dish", "message": "김치찌개 덜 맵게"},
    {"persona": "맵기", "id": "no_cheongyang", "message": "청양 없는 매운 거"},
    {"persona": "맵기", "id": "not_spicy", "message": "안 매운 거"},
    # 7. 해장 / 야식 / 아침
    {"persona": "시간대", "id": "hangover", "message": "해장"},
    {"persona": "시간대", "id": "hangover_sent", "message": "어제 술 마셔서 해장할 거"},
    {"persona": "시간대", "id": "late", "message": "야식"},
    {"persona": "시간대", "id": "late_sent", "message": "밤에 배고픈데 간단한 야식"},
    {"persona": "시간대", "id": "morning", "message": "아침으로 먹기 좋은 거"},
    # 8. 운동 / 몸관리
    {"persona": "운동·다이어트", "id": "protein", "message": "고단백"},
    {"persona": "운동·다이어트", "id": "workout", "message": "운동 후에 든든하게 먹을 거"},
    {"persona": "운동·다이어트", "id": "diet", "message": "다이어트"},
    {"persona": "운동·다이어트", "id": "low_salt", "message": "저염"},
    {"persona": "운동·다이어트", "id": "low_cal", "message": "저칼로리"},
    # 9. 아이 / 손님 / 혼밥 자리
    {"persona": "누구와 먹나", "id": "baby", "message": "이유식"},
    {"persona": "누구와 먹나", "id": "guest", "message": "손님 초대 저녁"},
    {"persona": "누구와 먹나", "id": "kid", "message": "아이 입맛에 맞는 거"},
    {"persona": "누구와 먹나", "id": "date", "message": "데이트 집에 초대 메뉴"},
    # 10. 달달 / 간식
    {"persona": "단맛·간식", "id": "dessert", "message": "달달한 거"},
    {"persona": "단맛·간식", "id": "dessert2", "message": "디저트"},
    {"persona": "단맛·간식", "id": "snack", "message": "간식 추천"},
    # 11. 도구 / 방식 (검색 도우미가 약할 수 있는 구간)
    {"persona": "조리 도구", "id": "microwave", "message": "전자레인지로 만들 수 있는 거"},
    {"persona": "조리 도구", "id": "airfryer", "message": "에어프라이어 요리"},
    {"persona": "조리 도구", "id": "onepot", "message": "냄비 하나로"},
    # 12. 술안주 / 국물 / 채식 느낌
    {"persona": "상황 메뉴", "id": "anju", "message": "술안주"},
    {"persona": "상황 메뉴", "id": "soup", "message": "국물 있는 거 추천"},
    {"persona": "상황 메뉴", "id": "vege", "message": "채식"},
    {"persona": "상황 메뉴", "id": "camp", "message": "캠핑 요리"},
    # 13. 거절해야 하는 요청
    {"persona": "거절", "id": "off_hw", "message": "숙제 수학 문제 풀어줘"},
    {"persona": "거절", "id": "off_code", "message": "파이썬으로 웹 크롤러 짜줘"},
    {"persona": "거절", "id": "off_med", "message": "당뇨약 대신 먹을 거"},
    {"persona": "거절", "id": "off_stock", "message": "주식 추천해줘"},
    {"persona": "거절", "id": "empty", "message": ""},
    # 14. 구어체·오타·애매
    {"persona": "구어체", "id": "casual_bap", "message": "밥 뭐먹지"},
    {"persona": "구어체", "id": "typo", "message": "김치찌게 추천"},
    {"persona": "구어체", "id": "english", "message": "pasta 추천"},
    {"persona": "구어체", "id": "healthy", "message": "건강한 거"},
]


def _outcome(row: Dict[str, Any]) -> str:
    if row.get("retrieve") == "none" and row.get("on_topic") is False:
        return "거절"
    if not row.get("on_topic"):
        return "거절"
    picks = row.get("picks") or []
    if picks:
        return "근거 추천"
    if row.get("retrieve") == "client_search" and row.get("q"):
        return "클라 문자열 검색"
    if row.get("retrieve") == "local_filter":
        return "현재 목록 필터"
    if row.get("recipe_ids"):
        return "id만 (이유 없음)"
    return "빈 결과"


def main() -> int:
    fb = get_firebase_service()
    if fb.db is None:
        print("firestore_unavailable", file=sys.stderr)
        return 2
    store = FirestoreHomeIndexReader(fb.db)
    service = HomeAgentService(reader=store, card_reader=store)
    rows: List[Dict[str, Any]] = []
    for case in CASES:
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
        named = []
        for p in result.get("picks") or []:
            rid = p.get("recipe_id")
            card = cards.get(rid)
            named.append(
                {
                    "recipe_id": rid,
                    "name": card.name if card else (p.get("name") or ""),
                    "reason": p.get("reason") or "",
                    "tags": list(card.tags) if card else [],
                }
            )
        row = {
            **case,
            "elapsed_ms": elapsed_ms,
            "on_topic": result.get("on_topic"),
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
            "picks": named,
            "outcome": "",
        }
        row["outcome"] = _outcome(row)
        rows.append(row)
        names = ", ".join(p["name"] or "?" for p in named[:4]) or "-"
        print(
            f"{case['persona']:10} {case['id']:16} {elapsed_ms:5}ms "
            f"{row['outcome']:12} {result.get('retrieve')} "
            f"llm={result.get('used_llm')} rank={result.get('used_ranker')} | {names}",
            flush=True,
        )

    out_dir = Path("/opt/cursor/artifacts")
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = {"total": len(rows), "cases": rows}
    json_path = out_dir / "home_agent_persona_sweep.json"
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = ["홈 검색 도우미 페르소나 스윕", f"총 {len(rows)}개", ""]
    current = ""
    for row in rows:
        if row["persona"] != current:
            current = row["persona"]
            lines.append(f"## {current}")
            lines.append("")
        msg = row["message"] or "(빈 입력)"
        lines.append(f"- 입력: {msg}")
        lines.append(
            f"  결과: {row['outcome']} · retrieve={row['retrieve']} · "
            f"{row['elapsed_ms']}ms · llm={row['used_llm']} rank={row['used_ranker']}"
        )
        if row.get("reply"):
            lines.append(f"  안내: {row['reply']}")
        if row.get("q"):
            lines.append(f"  검색어 q: {row['q']}")
        if row.get("section_key"):
            lines.append(f"  섹션: {row['section_key']}")
        for p in row["picks"][:4]:
            lines.append(f"  · {p['name']}: {p['reason']}")
        if not row["picks"] and row["outcome"] == "빈 결과":
            lines.append("  · (카드 없음)")
        lines.append("")
    txt_path = out_dir / "home_agent_persona_sweep.txt"
    txt_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n[sweep] {len(rows)} → {json_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
