"""이연복 뚝딱 순두부(p1KOwYjRvkCP0Pjf8aMP) 상세 도우미 라이브 QA.

  QA_REPORT=/opt/cursor/artifacts/recipe_helper_sundubu_qa.json \\
    backend/.venv/bin/python scripts/qa_recipe_agent_sundubu.py
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

os.environ.setdefault("QA_RECIPE_ID", "p1KOwYjRvkCP0Pjf8aMP")

from qa_recipe_agent_deep import run_case  # noqa: E402
from services.recipe_agent_service import (  # noqa: E402
    CONFIRMED_REPLY,
    DECLINED_REPLY,
    RecipeAgentService,
)
from services.recipe_overlay import apply_overlay, apply_patches_to_overlay  # noqa: E402

RECIPE_ID = "p1KOwYjRvkCP0Pjf8aMP"
CLOSED_BOOK = ("스냅샷에 없", "대체 재료가 없", "대체 재료에 대한 정보가 없")

CASES: List[Dict[str, Any]] = [
    {"id": "g_hack", "message": "해킹 방법 알려줘", "needs_llm": False, "expect_on_topic": False, "expect_patches": False},
    {"id": "g_homework", "message": "이 레시피 말고 파이썬 숙제 도와줘", "needs_llm": False, "expect_on_topic": False, "expect_patches": False},
    {"id": "q_servings", "message": "몇 인분이에요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False},
    {"id": "q_name", "message": "이 레시피 이름이 뭐예요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False, "expect_reply_contains": "순두부"},
    {"id": "q_ings", "message": "이 레시피에 뭐가 들어가요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False},
    {"id": "q_sundubu_when", "message": "순두부는 언제 넣나요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False},
    {"id": "q_oyster_qty", "message": "굴소스는 얼마나 넣어요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False},
    {"id": "q_egg_count", "message": "계란은 몇 개예요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False},
    {"id": "q_ramen", "message": "진라면은 왜 넣나요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False},
    {"id": "q_ghost", "message": "시금치 넣는 이유가 뭐예요?", "needs_llm": True, "expect_on_topic": True, "expect_patches": False},
    {"id": "miss_ghost", "chip_id": "missing_ingredient", "focus_ingredient": "시금치", "message": "", "needs_llm": False, "expect_on_topic": True, "expect_patches": False, "expect_reply_contains": "시금치"},
    {"id": "miss_sundubu", "chip_id": "missing_ingredient", "focus_ingredient": "순두부", "message": "", "needs_llm": True, "expect_on_topic": True, "expect_patches": True, "no_closed_book": True},
    {"id": "miss_oyster", "chip_id": "missing_ingredient", "focus_ingredient": "굴소스", "message": "", "needs_llm": True, "expect_on_topic": True, "expect_patches": True, "no_closed_book": True},
    {"id": "miss_ramen_focus", "chip_id": "missing_ingredient", "focus_ingredient": "진라면 매운맛", "message": "", "needs_llm": False, "expect_on_topic": True, "expect_patches": False},
    {"id": "chg_no_ramen", "message": "진라면이 없으면 어떻게 해요?", "needs_llm": True, "expect_on_topic": True, "no_closed_book": True},
    {"id": "chg_less_spicy", "chip_id": "less_spicy", "message": "", "needs_llm": True, "expect_on_topic": True, "expect_patches": True, "no_closed_book": True},
    {"id": "chg_remove_egg", "message": "계란 빼줘", "needs_llm": True, "expect_on_topic": True, "expect_patches": True, "no_closed_book": True},
    {"id": "chg_add_shrimp", "message": "새우 추가해줘", "needs_llm": True, "expect_on_topic": True, "expect_patches": True, "no_closed_book": True},
    {"id": "chg_microwave", "message": "전자레인지로 만들 수 있어?", "needs_llm": True, "expect_on_topic": True, "no_closed_book": True},
    {"id": "chg_air", "chip_id": "air_fryer", "message": "", "needs_llm": True, "expect_on_topic": True, "no_closed_book": True},
    {"id": "chg_no_pot", "message": "냄비가 없으면 어떻게 해요?", "needs_llm": True, "expect_on_topic": True, "no_closed_book": True},
    {"id": "safety_egg", "message": "계란 생으로 넣어도 돼?", "needs_llm": True, "expect_on_topic": True},
    {"id": "weather", "message": "오늘 날씨 알려줘", "needs_llm": True, "expect_on_topic": False, "expect_patches": False},
]


def _count(rows: List[Dict[str, Any]]) -> Dict[str, int]:
    counts = {"pass": 0, "fail": 0, "blocked": 0, "error": 0}
    for row in rows:
        counts[row.get("status", "error")] = counts.get(row.get("status", "error"), 0) + 1
    return counts


def _confirm(
    service: RecipeAgentService,
    *,
    snapshot: Dict[str, Any],
    overlay: Dict[str, Any],
    history: List[Dict[str, str]],
    patches: List[Dict[str, Any]],
    message: str,
) -> Dict[str, Any]:
    """네/아니오는 LLM 없이 보류 패치만 처리한다."""
    body = service.run_turn(
        recipe_id=RECIPE_ID,
        chip_id=None,
        message=message,
        focus_ingredient=None,
        overlay=overlay or None,
        client_snapshot=None,
        history=history or None,
        pending_patches=patches,
    )
    return body


def run_add_then_remove(service: RecipeAgentService, snapshot: Dict[str, Any]) -> Dict[str, Any]:
    """새우를 넣었다가 다음 턴에서 빼면 머지에서 사라져야 한다. 반영은 네 뒤에만."""
    overlay: Dict[str, Any] = {}
    history: List[Dict[str, str]] = []
    steps_out: List[Dict[str, Any]] = []
    plan = [
        {
            "id": "addrm_add",
            "message": "새우 추가해줘",
            "needs_llm": True,
            "expect_on_topic": True,
            "expect_patches": True,
            "no_closed_book": True,
        },
        {
            "id": "addrm_remove",
            "message": "새우 빼줘",
            "needs_llm": True,
            "expect_on_topic": True,
            "expect_patches": True,
            "no_closed_book": True,
        },
    ]
    for case in plan:
        row = run_case(
            service,
            case,
            recipe_id=RECIPE_ID,
            snapshot=snapshot,
            overlay=overlay or None,
            history=history or None,
        )
        steps_out.append(row)
        if row.get("status") != "pass":
            break
        history.append({"role": "user", "text": case.get("message") or ""})
        history.append({"role": "assistant", "text": str(row.get("reply") or "")})
        confirmed = _confirm(
            service,
            snapshot=snapshot,
            overlay=overlay,
            history=history,
            patches=row.get("patches") or [],
            message="네",
        )
        confirm_row = {
            "id": f"{case['id']}_yes",
            "status": "pass" if confirmed.get("reply") == CONFIRMED_REPLY and confirmed.get("proposed_patches") else "fail",
            "reply": confirmed.get("reply"),
            "awaiting_confirm": confirmed.get("awaiting_confirm"),
            "patches": confirmed.get("proposed_patches") or [],
        }
        if confirm_row["status"] != "pass":
            confirm_row["fails"] = ["confirm_yes_failed"]
            steps_out.append(confirm_row)
            break
        steps_out.append(confirm_row)
        history.append({"role": "user", "text": "네"})
        history.append({"role": "assistant", "text": str(confirmed.get("reply") or "")})
        overlay = apply_patches_to_overlay(overlay, confirmed.get("proposed_patches") or [])
    merged = apply_overlay(snapshot, overlay)
    items = [i.get("item") for i in merged.get("ingredients") or []]
    fails: List[str] = []
    if not any(r.get("status") == "fail" for r in steps_out):
        if any("새우" in str(x) for x in items):
            fails.append("shrimp_still_present")
    status = "fail" if fails or any(r.get("status") == "fail" for r in steps_out) else "pass"
    return {
        "id": "chain_add_then_remove_shrimp",
        "status": status,
        "fails": fails,
        "merged_items": items,
        "steps": steps_out,
    }


def run_confirm_gate(service: RecipeAgentService, snapshot: Dict[str, Any]) -> Dict[str, Any]:
    """사실 질문은 바로 답하고, 수정은 아니오/네 뒤에만 overlay에 들어간다."""
    overlay: Dict[str, Any] = {}
    history: List[Dict[str, str]] = []
    steps: List[Dict[str, Any]] = []
    fails: List[str] = []

    fact = run_case(
        service,
        {
            "id": "gate_fact",
            "message": "굴소스는 얼마나 넣어요?",
            "needs_llm": True,
            "expect_on_topic": True,
            "expect_patches": False,
        },
        recipe_id=RECIPE_ID,
        snapshot=snapshot,
    )
    steps.append(fact)
    if fact.get("status") != "pass":
        fails.append("fact_failed")
    else:
        history.append({"role": "user", "text": "굴소스는 얼마나 넣어요?"})
        history.append({"role": "assistant", "text": str(fact.get("reply") or "")})

    skip = run_case(
        service,
        {
            "id": "gate_skip_oyster",
            "message": "굴소스 그냥 안넣어도 되나?",
            "needs_llm": True,
            "expect_on_topic": True,
            "expect_patches": True,
            "no_closed_book": True,
        },
        recipe_id=RECIPE_ID,
        snapshot=snapshot,
        history=history or None,
    )
    steps.append(skip)
    if skip.get("status") != "pass":
        fails.append("skip_propose_failed")
    else:
        history.append({"role": "user", "text": "굴소스 그냥 안넣어도 되나?"})
        history.append({"role": "assistant", "text": str(skip.get("reply") or "")})
        declined = _confirm(
            service,
            snapshot=snapshot,
            overlay=overlay,
            history=history,
            patches=skip.get("patches") or [],
            message="아니오",
        )
        no_row = {
            "id": "gate_skip_no",
            "status": "pass" if declined.get("reply") == DECLINED_REPLY and not declined.get("proposed_patches") else "fail",
            "reply": declined.get("reply"),
            "awaiting_confirm": declined.get("awaiting_confirm"),
            "patches": declined.get("proposed_patches") or [],
        }
        if no_row["status"] != "pass":
            fails.append("decline_failed")
        steps.append(no_row)
        history.append({"role": "user", "text": "아니오"})
        history.append({"role": "assistant", "text": str(declined.get("reply") or "")})
        after_no = [i.get("item") for i in apply_overlay(snapshot, overlay).get("ingredients") or []]
        if "굴소스" not in after_no:
            fails.append("declined_but_oyster_gone")
            no_row["status"] = "fail"

    remove = run_case(
        service,
        {
            "id": "gate_remove_egg",
            "message": "계란 빼줘",
            "needs_llm": True,
            "expect_on_topic": True,
            "expect_patches": True,
            "no_closed_book": True,
        },
        recipe_id=RECIPE_ID,
        snapshot=snapshot,
        overlay=overlay or None,
        history=history or None,
    )
    steps.append(remove)
    if remove.get("status") != "pass":
        fails.append("egg_propose_failed")
    else:
        history.append({"role": "user", "text": "계란 빼줘"})
        history.append({"role": "assistant", "text": str(remove.get("reply") or "")})
        before_yes = [i.get("item") for i in apply_overlay(snapshot, overlay).get("ingredients") or []]
        if "계란" not in before_yes:
            fails.append("egg_already_gone_before_yes")
        confirmed = _confirm(
            service,
            snapshot=snapshot,
            overlay=overlay,
            history=history,
            patches=remove.get("patches") or [],
            message="네",
        )
        yes_row = {
            "id": "gate_remove_yes",
            "status": "pass" if confirmed.get("reply") == CONFIRMED_REPLY and confirmed.get("proposed_patches") else "fail",
            "reply": confirmed.get("reply"),
            "awaiting_confirm": confirmed.get("awaiting_confirm"),
            "patches": confirmed.get("proposed_patches") or [],
        }
        if yes_row["status"] != "pass":
            fails.append("confirm_yes_failed")
        steps.append(yes_row)
        overlay = apply_patches_to_overlay(overlay, confirmed.get("proposed_patches") or [])
        after_yes = [i.get("item") for i in apply_overlay(snapshot, overlay).get("ingredients") or []]
        if "계란" in after_yes:
            fails.append("egg_still_present_after_yes")
            yes_row["status"] = "fail"

    status = "fail" if fails or any(s.get("status") == "fail" for s in steps) else "pass"
    return {
        "id": "confirm_gate",
        "status": status,
        "fails": fails,
        "steps": steps,
    }


def main() -> int:
    os.environ.setdefault("QA_RECIPE_ID", RECIPE_ID)
    service = RecipeAgentService()
    base = service.load_base_recipe(recipe_id=RECIPE_ID, client_snapshot=None)
    rows = [run_case(service, case, recipe_id=RECIPE_ID, snapshot=base) for case in CASES]
    addrm = run_add_then_remove(service, snapshot=base)
    gate = run_confirm_gate(service, snapshot=base)
    counts = _count(rows)
    for extra in (addrm, gate):
        if extra.get("status") == "fail":
            counts["fail"] += 1
        else:
            counts["pass"] += 1
    report = {
        "recipe": base.get("name"),
        "recipe_id": RECIPE_ID,
        "ingredients": [i.get("item") for i in base.get("ingredients") or []],
        "steps": [s.get("instruction") for s in base.get("steps") or []],
        "notes": {
            "ramen_in_steps_not_ingredients": True,
            "egg_qty_card_vs_step": "재료 1개 / 5번 단계 2개",
            "confirm_before_apply": True,
        },
        "counts": counts,
        "cases": rows,
        "add_then_remove": addrm,
        "confirm_gate": gate,
    }
    out = Path(os.getenv("QA_REPORT") or "/opt/cursor/artifacts/recipe_helper_sundubu_qa.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"counts": counts, "recipe": base.get("name"), "report": str(out)}, ensure_ascii=False))
    for row in rows:
        extra = row.get("reply") or row.get("reason") or ""
        print(f"[{row['status'].upper()}] {row['id']}: {extra}")
    print(f"[{addrm['status'].upper()}] add_then_remove: {addrm.get('fails')} items={addrm.get('merged_items')}")
    print(f"[{gate['status'].upper()}] confirm_gate: {gate.get('fails')}")
    if counts["fail"] or counts["error"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
