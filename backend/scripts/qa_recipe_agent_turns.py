"""Firestore 레시피(기본: 고추장 크림 파스타)로 상세 도우미 턴을 넣는다.

  backend/.venv/bin/python scripts/qa_recipe_agent_turns.py
  QA_REPORT=/tmp/recipe_helper_qa.json backend/.venv/bin/python scripts/qa_recipe_agent_turns.py
"""

from __future__ import annotations

import json
import os
import sys
import types
from pathlib import Path
from typing import Any, Dict, List

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / "scripts"))


def _namespace(name: str, path: Path) -> None:
    if name in sys.modules:
        return
    pkg = types.ModuleType(name)
    pkg.__path__ = [str(path)]
    pkg.__file__ = str(path / "__init__.py")
    sys.modules[name] = pkg


_namespace("services", BACKEND / "services")

from qa_recipe_agent_live import RECIPE, RECIPE_ID  # noqa: E402
from services.recipe_agent_service import RecipeAgentService  # noqa: E402


CASES: List[Dict[str, Any]] = [
    {
        "id": "off1",
        "message": "파이썬으로 웹 크롤러 짜줘",
        "needs_llm": False,
        "expect_on_topic": False,
        "expect_patches": False,
    },
    {
        "id": "off2",
        "message": "숙제 수학 문제 풀어줘",
        "needs_llm": False,
        "expect_on_topic": False,
        "expect_patches": False,
    },
    {
        "id": "off3",
        "message": "오늘 대통령 뉴스 요약해줘",
        "needs_llm": False,
        "expect_on_topic": False,
        "expect_patches": False,
    },
    {
        "id": "empty",
        "message": "",
        "needs_llm": False,
        "expect_on_topic": False,
    },
    {
        "id": "servings",
        "chip_id": "servings",
        "message": "",
        "needs_llm": False,
        "expect_on_topic": True,
        "expect_patches": False,
        "expect_reply_contains": "인분",
    },
    {
        "id": "missing_no_focus",
        "chip_id": "missing_ingredient",
        "message": "",
        "needs_llm": False,
        "expect_on_topic": False,
        "expect_reply_contains": "재료",
    },
    {
        "id": "q_when_yogurt",
        "message": "그릭요거트는 언제 넣나요?",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": False,
    },
    {
        "id": "q_heat",
        "message": "6번 단계에서 불 세기는요?",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": False,
    },
    {
        "id": "q_no_pan",
        "message": "팬이 없으면 어떻게 해요?",
        "needs_llm": True,
        "expect_on_topic": True,
    },
    {
        "id": "ghost_spinach",
        "message": "시금치 넣는 이유가 뭐예요?",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": False,
        "note": "스냅샷에 없는 재료",
    },
    {
        "id": "safety_raw",
        "message": "우삼겹 덜 익혀도 돼?",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": False,
    },
    {
        "id": "chip_missing_pasta",
        "chip_id": "missing_ingredient",
        "focus_ingredient": "파스타면",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
    },
    {
        "id": "chip_missing_beef",
        "chip_id": "missing_ingredient",
        "focus_ingredient": "우삼겹",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
    },
    {
        "id": "chip_less_spicy",
        "chip_id": "less_spicy",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
    },
    {
        "id": "chip_air_fryer",
        "chip_id": "air_fryer",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
    },
    {
        "id": "chip_easier",
        "chip_id": "easier_step",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
    },
    {
        "id": "add_shrimp",
        "message": "면에 새우 추가해줘",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
    },
]


def _has_llm_key() -> bool:
    return bool(os.getenv("DEEPSEEK_API_KEY") or os.getenv("GEMINI_API_KEY"))


def _judge(case: Dict[str, Any], body: Dict[str, Any]) -> List[str]:
    fails: List[str] = []
    if "expect_on_topic" in case and body.get("on_topic") is not case["expect_on_topic"]:
        fails.append(f"on_topic={body.get('on_topic')} want {case['expect_on_topic']}")
    if case.get("expect_patches") is True and not body.get("proposed_patches"):
        fails.append("expected patches")
    if case.get("expect_patches") is False and body.get("proposed_patches"):
        fails.append(f"unexpected patches={body.get('proposed_patches')}")
    needle = case.get("expect_reply_contains")
    if needle and needle not in str(body.get("reply") or ""):
        fails.append(f"reply missing {needle!r}")
    return fails


def run_case(service: RecipeAgentService, case: Dict[str, Any]) -> Dict[str, Any]:
    row: Dict[str, Any] = {
        "id": case["id"],
        "needs_llm": bool(case.get("needs_llm")),
        "prompt": case.get("message") or case.get("chip_id") or "",
        "chip_id": case.get("chip_id"),
        "focus_ingredient": case.get("focus_ingredient"),
    }
    if case.get("needs_llm") and not _has_llm_key():
        row["status"] = "blocked"
        row["reason"] = "DEEPSEEK_API_KEY/GEMINI_API_KEY 없음"
        return row
    try:
        body = service.run_turn(
            recipe_id=RECIPE_ID,
            chip_id=case.get("chip_id"),
            message=case.get("message"),
            focus_ingredient=case.get("focus_ingredient"),
            overlay=None,
            client_snapshot=None if RECIPE_ID else RECIPE,
            history=None,
        )
    except Exception as exc:  # noqa: BLE001
        row["status"] = "error"
        row["reason"] = f"{type(exc).__name__}: {exc}"
        return row
    fails = _judge(case, body)
    row["status"] = "fail" if fails else "pass"
    row["fails"] = fails
    row["on_topic"] = body.get("on_topic")
    row["reply"] = body.get("reply")
    row["engine"] = body.get("engine")
    row["patches"] = body.get("proposed_patches") or []
    row["warnings"] = body.get("warnings") or []
    row["followup_chips"] = body.get("followup_chips") or []
    return row


def main() -> int:
    service = RecipeAgentService()
    rows = [run_case(service, case) for case in CASES]
    counts = {"pass": 0, "fail": 0, "blocked": 0, "error": 0}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    report = {
        "recipe": RECIPE["name"],
        "recipe_id": RECIPE_ID,
        "source": "firestore" if RECIPE_ID else "fallback",
        "has_llm_key": _has_llm_key(),
        "keys": [
            name
            for name, env in (
                ("deepseek", "DEEPSEEK_API_KEY"),
                ("gemini", "GEMINI_API_KEY"),
            )
            if os.getenv(env)
        ],
        "counts": counts,
        "cases": rows,
    }
    out = Path(os.getenv("QA_REPORT") or "/opt/cursor/artifacts/recipe_helper_firestore_qa.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {
                "recipe": RECIPE["name"],
                "recipe_id": RECIPE_ID,
                "counts": counts,
                "report": str(out),
            },
            ensure_ascii=False,
        )
    )
    for row in rows:
        mark = row["status"].upper()
        extra = row.get("reply") or row.get("reason") or ""
        print(f"[{mark}] {row['id']}: {extra}")
    if counts["fail"] or counts["error"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
