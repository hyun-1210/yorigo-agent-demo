"""파스타 외 레시피 + 라이브 HTTP 경로를 추가로 찌른다.

  QA_REPORT=/opt/cursor/artifacts/recipe_helper_cross_qa.json \\
    backend/.venv/bin/python scripts/qa_recipe_agent_cross.py
"""

from __future__ import annotations

import json
import os
import sys
import types
from pathlib import Path
from typing import Any, Dict, List, Optional

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

from qa_recipe_agent_deep import run_case  # noqa: E402
from services.recipe_agent_service import RecipeAgentService  # noqa: E402

SALAD_ID = "01ozSUTUGeMv7mc0j4ln"
DONEJANG_ID = "00d3CyEiIBTJHPTzITL5"

SALAD_CASES: List[Dict[str, Any]] = [
    {
        "id": "sal_egg_raw",
        "message": "계란 생으로 먹어도 돼?",
        "needs_llm": True,
        "expect_on_topic": True,
    },
    {
        "id": "sal_qty",
        "message": "파프리카는 몇 개예요?",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": False,
    },
    {
        "id": "sal_add",
        "message": "옥수수 추가해줘",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
        "no_closed_book": True,
    },
    {
        "id": "sal_missing_egg",
        "chip_id": "missing_ingredient",
        "focus_ingredient": "계란",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
        "no_closed_book": True,
    },
    {
        "id": "sal_off",
        "message": "주식 추천해줘",
        "needs_llm": False,
        "expect_on_topic": False,
        "expect_patches": False,
    },
]

DONEJANG_CASES: List[Dict[str, Any]] = [
    {
        "id": "dj_when",
        "message": "된장은 언제 넣나요?",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": False,
    },
    {
        "id": "dj_less",
        "chip_id": "less_spicy",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "no_closed_book": True,
    },
    {
        "id": "dj_missing_pork",
        "chip_id": "missing_ingredient",
        "focus_ingredient": "삼겹살",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "expect_patches": True,
        "no_closed_book": True,
    },
    {
        "id": "dj_air",
        "chip_id": "air_fryer",
        "message": "",
        "needs_llm": True,
        "expect_on_topic": True,
        "no_closed_book": True,
    },
]


def _count(rows: List[Dict[str, Any]]) -> Dict[str, int]:
    counts = {"pass": 0, "fail": 0, "blocked": 0, "error": 0}
    for row in rows:
        counts[row.get("status", "error")] = counts.get(row.get("status", "error"), 0) + 1
    return counts


def _has_remove_add(row: Dict[str, Any], focus: str) -> bool:
    patches = row.get("patches") or []
    removed = any(p.get("action") == "ingredient.remove" and p.get("item") == focus for p in patches)
    added = any(p.get("action") == "ingredient.add" for p in patches)
    return removed and added


def main() -> int:
    service = RecipeAgentService()
    salad = service.load_base_recipe(recipe_id=SALAD_ID, client_snapshot=None)
    donejang = service.load_base_recipe(recipe_id=DONEJANG_ID, client_snapshot=None)
    salad_rows = [run_case(service, c, recipe_id=SALAD_ID, snapshot=salad) for c in SALAD_CASES]
    dj_rows = [run_case(service, c, recipe_id=DONEJANG_ID, snapshot=donejang) for c in DONEJANG_CASES]
    extra_fails: List[str] = []
    for row, focus in (
        (next(r for r in salad_rows if r["id"] == "sal_missing_egg"), "계란"),
        (next(r for r in dj_rows if r["id"] == "dj_missing_pork"), "삼겹살"),
    ):
        if row.get("status") == "pass" and not _has_remove_add(row, focus):
            extra_fails.append(f"{row['id']}: expected remove+add")
            row["status"] = "fail"
            row.setdefault("fails", []).append("expected_remove_add")
    pasta_focus = service.run_turn(
        recipe_id="009Rtpj2yjttZN6b2Raj",
        chip_id="missing_ingredient",
        message="",
        focus_ingredient="파스타면",
        overlay=None,
        client_snapshot=None,
        history=None,
    )
    pasta_row = {
        "id": "pasta_missing_remove_add",
        "status": "pass",
        "fails": [],
        "reply": pasta_focus.get("reply"),
        "patches": pasta_focus.get("proposed_patches") or [],
        "warnings": pasta_focus.get("warnings") or [],
        "on_topic": pasta_focus.get("on_topic"),
    }
    if not _has_remove_add({"patches": pasta_row["patches"]}, "파스타면"):
        pasta_row["status"] = "fail"
        pasta_row["fails"] = ["expected_remove_add"]
        extra_fails.append("pasta_missing_remove_add")
    rows = salad_rows + dj_rows + [pasta_row]
    counts = _count(rows)
    report = {
        "salad": salad.get("name"),
        "salad_id": SALAD_ID,
        "donejang": donejang.get("name"),
        "donejang_id": DONEJANG_ID,
        "counts": counts,
        "salad_ings": [i.get("item") for i in salad.get("ingredients") or []],
        "donejang_ings": [i.get("item") for i in donejang.get("ingredients") or []],
        "cases": rows,
    }
    out = Path(os.getenv("QA_REPORT") or "/opt/cursor/artifacts/recipe_helper_cross_qa.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"counts": counts, "report": str(out), "extra_fails": extra_fails}, ensure_ascii=False))
    for row in rows:
        extra = row.get("reply") or row.get("reason") or ""
        print(f"[{row['status'].upper()}] {row['id']}: {extra}")
    if counts["fail"] or counts["error"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
