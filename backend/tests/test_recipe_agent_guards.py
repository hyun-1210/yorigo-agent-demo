"""recipe_agent 가드·overlay 머지 계약. LLM 호출 없음."""

from services.recipe_agent_service import (
    OFF_TOPIC_REPLY,
    prefilter_message,
    sanitize_patches,
)
from services.recipe_overlay import (
    apply_overlay,
    compact_snapshot,
    firestore_doc_to_base,
    slice_for_ingredient,
)


KIMCHI = {
    "name": "김치찌개",
    "servings": 2,
    "ingredients": [
        {"item": "돼지고기", "qty": 200.0, "unit": "g", "category": "protein"},
        {"item": "김치", "qty": 200.0, "unit": "g", "category": "veg"},
        {"item": "고춧가루", "qty": 1.0, "unit": "큰술", "category": "seasoning"},
    ],
    "steps": [
        {"order": 1, "instruction": "돼지고기를 볶는다."},
        {"order": 2, "instruction": "김치와 고춧가루를 넣고 끓인다."},
    ],
}


def test_confirm_yes_no_markers_are_exact():
    from services.recipe_agent_service import is_confirm_no, is_confirm_yes

    assert is_confirm_yes("네")
    assert is_confirm_yes("네!")
    assert is_confirm_yes("진행할게요")
    assert is_confirm_yes("OK")
    assert is_confirm_yes("ㄱㄱ")
    assert is_confirm_yes("고고")
    assert is_confirm_yes("네 굴소스 빼줘") is False
    assert is_confirm_no("아니오")
    assert is_confirm_no("안 해")
    assert is_confirm_no("취소")
    assert is_confirm_no("아니 굴소스는 남겨") is False


def test_needs_research_for_change_but_not_card_facts():
    from services.recipe_agent_service import needs_research

    assert needs_research("missing_ingredient", "") is True
    assert needs_research("air_fryer", "") is True
    assert needs_research(None, "면에 새우 추가해줘") is True
    assert needs_research(None, "양파 빼줘") is True
    assert needs_research(None, "굴소스 그냥 안넣어도 되나?") is True
    assert needs_research(None, "계란 빼도 돼?") is True
    assert needs_research(None, "오븐으로 만들어줘") is True
    assert needs_research(None, "전자레인지로 데울 수 있어?") is True
    assert needs_research(None, "소금 줄여줘") is True
    assert needs_research(None, "그릭요거트는 언제 넣나요?") is False
    assert needs_research(None, "시금치 넣는 이유가 뭐예요?") is False


def test_build_user_prompt_adds_search_notes():
    from services.recipe_agent_service import build_user_prompt

    prompt = build_user_prompt(
        snapshot=KIMCHI,
        truncated=False,
        chip_id="missing_ingredient",
        message="",
        history=[],
        focus_ingredient="돼지고기",
        notes=["두부로 대체하고 마지막에 넣는다."],
        researched=True,
    )
    assert "<<NOTES>>" in prompt
    assert "두부로 대체" in prompt
    assert "remove" in prompt
    assert "add" in prompt
    fact = build_user_prompt(
        snapshot=KIMCHI,
        truncated=False,
        chip_id=None,
        message="고춧가루를 언제 넣나요?",
        history=[],
        focus_ingredient=None,
        researched=False,
    )
    assert "<<NOTES>>" not in fact
    assert "검색 결과 없음" not in fact


def test_sanitize_keeps_airfryer_step_under_limit():
    patches, _ = sanitize_patches(
        [
            {
                "action": "step.edit",
                "order": 1,
                "instruction": "돼지고기를 에어프라이어 200도에서 8분 굽고 뒤집는다.",
            }
        ],
        snapshot=KIMCHI,
        chip_id="air_fryer",
        focus_ingredient=None,
    )
    assert patches
    assert "에어프라이어" in patches[0]["instruction"]


def test_prefilter_blocks_homework_and_allows_recipe_question():
    assert prefilter_message("숙제 대신 파이썬 코드 짜줘") == "off_topic"
    assert prefilter_message("고춧가루 없으면 어떻게 해요?") is None
    assert prefilter_message("") == "empty"
    assert prefilter_message("가" * 501) == "too_long"


def test_apply_overlay_remove_and_add_does_not_mutate_base_identity():
    overlay = {
        "ingredients": {
            "removed": ["돼지고기"],
            "added": [
                {
                    "id": "u_1",
                    "item": "두부",
                    "qty": 200,
                    "unit": "g",
                    "memo": "돼지고기 대체",
                }
            ],
        }
    }
    merged = apply_overlay(KIMCHI, overlay)
    items = [i["item"] for i in merged["ingredients"]]
    assert "돼지고기" not in items
    assert "두부" in items
    assert KIMCHI["ingredients"][0]["item"] == "돼지고기"


def test_sanitize_drops_unknown_item_and_keeps_focus_remove_add():
    patches, warnings = sanitize_patches(
        [
            {"action": "ingredient.remove", "item": "돼지고기"},
            {"action": "ingredient.add", "item": "두부", "qty": 200, "unit": "g"},
            {"action": "ingredient.remove", "item": "없는재료"},
            {"action": "step.edit", "order": 9, "instruction": "없는 단계"},
        ],
        snapshot=KIMCHI,
        chip_id="missing_ingredient",
        focus_ingredient="돼지고기",
    )
    actions = {(p["action"], p.get("item")) for p in patches}
    assert ("ingredient.remove", "돼지고기") in actions
    assert ("ingredient.add", "두부") in actions
    assert ("ingredient.remove", "없는재료") not in actions
    assert all(p.get("order") != 9 for p in patches)
    assert warnings == []


def test_sanitize_keeps_if_undercooked_then_add_time():
    patches, warnings = sanitize_patches(
        [
            {
                "action": "step.edit",
                "order": 2,
                "instruction": "김치와 고춧가루를 넣고 끓인다. 면이 덜 익으면 2분 더 끓인다.",
            }
        ],
        snapshot=KIMCHI,
        chip_id=None,
        focus_ingredient=None,
    )
    assert patches
    assert warnings == []
    patches, warnings = sanitize_patches(
        [
            {
                "action": "step.edit",
                "order": 1,
                "instruction": "돼지고기를 날것으로 먹는다.",
            }
        ],
        snapshot=KIMCHI,
        chip_id=None,
        focus_ingredient=None,
    )
    assert patches == []
    assert warnings
    surface, warn_surface = sanitize_patches(
        [
            {
                "action": "step.edit",
                "order": 1,
                "instruction": "돼지고기는 겉만 익혀도 됩니다.",
            }
        ],
        snapshot=KIMCHI,
        chip_id=None,
        focus_ingredient=None,
    )
    assert surface == []
    assert warn_surface
    under, warn_under = sanitize_patches(
        [
            {
                "action": "step.edit",
                "order": 1,
                "instruction": "고기를 덜 익혀 드세요.",
            }
        ],
        snapshot=KIMCHI,
        chip_id=None,
        focus_ingredient=None,
    )
    assert under == []
    assert warn_under


def test_sanitize_treats_beef_brisket_as_meat():
    """우삼겹 카드에서도 겉만 익히라는 패치를 버린다."""
    pasta = {
        "name": "고추장 크림 파스타",
        "servings": 1,
        "ingredients": [{"item": "우삼겹", "qty": 200.0, "unit": "g"}],
        "steps": [{"order": 1, "instruction": "우삼겹을 굽는다."}],
    }
    patches, warnings = sanitize_patches(
        [
            {
                "action": "step.edit",
                "order": 1,
                "instruction": "우삼겹은 겉만 익혀도 됩니다.",
            }
        ],
        snapshot=pasta,
        chip_id=None,
        focus_ingredient=None,
    )
    assert patches == []
    assert warnings


def test_sanitize_allergen_particle():
    from services.recipe_agent_service import _hangul_eun_neun

    assert _hangul_eun_neun("새우") == "는"
    assert _hangul_eun_neun("땅콩") == "은"
    patches, warnings = sanitize_patches(
        [{"action": "ingredient.add", "item": "새우", "qty": 8, "unit": "마리"}],
        snapshot=KIMCHI,
        chip_id=None,
        focus_ingredient=None,
    )
    assert patches
    assert any("새우는 알러지" in w for w in warnings)
    assert not any("새우은" in w for w in warnings)


def test_sanitize_drops_oversized_step_rewrite():
    original = KIMCHI["steps"][0]["instruction"]
    huge = original + ("아주 긴 새 요리법. " * 40)
    patches, _ = sanitize_patches(
        [{"action": "step.edit", "order": 1, "instruction": huge}],
        snapshot=KIMCHI,
        chip_id=None,
        focus_ingredient=None,
    )
    assert patches == []


def test_slice_for_ingredient_limits_steps():
    sliced = slice_for_ingredient(KIMCHI, "돼지고기")
    assert [i["item"] for i in sliced["ingredients"]] == ["돼지고기"]
    assert all("돼지고기" in s["instruction"] for s in sliced["steps"])


def test_firestore_doc_to_base_reads_nested_recipe():
    doc = {
        "title": "ignore",
        "recipe": {
            "name": "계란말이",
            "servings": 1,
            "ingredients": [{"item": "계란", "qty": 3, "unit": "개"}],
            "steps": [{"order": 1, "instruction": "섞는다"}],
        },
    }
    base = firestore_doc_to_base(doc)
    assert base["name"] == "계란말이"
    assert base["ingredients"][0]["item"] == "계란"


def test_compact_snapshot_truncates_instruction():
    long_step = {"order": 1, "instruction": "가" * 500}
    snap, truncated = compact_snapshot(
        {"name": "x", "servings": 2, "ingredients": [], "steps": [long_step]}
    )
    assert truncated is True
    assert len(snap["steps"][0]["instruction"]) == 200


def test_golden_prefilter_cases():
    from pathlib import Path
    import json

    path = Path(__file__).parent / "fixtures" / "recipe_agent_golden_20.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    for case in data["cases"]:
        expected = case.get("expect_prefilter")
        if not expected:
            continue
        message = case.get("message") or ""
        assert prefilter_message(message) == expected, case["id"]


def test_sanitize_drops_url_add_and_huge_qty():
    patches, _ = sanitize_patches(
        [
            {"action": "ingredient.add", "item": "https://evil.example/x", "qty": 1, "unit": "g"},
            {"action": "ingredient.add", "item": "설탕", "qty": 99999, "unit": "g"},
            {"action": "ingredient.add", "item": "후추", "qty": 1, "unit": "꼬집"},
        ],
        snapshot=KIMCHI,
        chip_id=None,
        focus_ingredient=None,
    )
    items = [p.get("item") for p in patches]
    assert "설탕" not in items
    assert "https://evil.example/x" not in items
    assert "후추" in items


def test_sanitize_caps_patch_count():
    raw = [{"action": "ingredient.add", "item": f"재료{i}", "qty": 1, "unit": "g"} for i in range(20)]
    patches, _ = sanitize_patches(raw, snapshot=KIMCHI, chip_id=None, focus_ingredient=None)
    assert len(patches) <= 8


def test_apply_patches_to_overlay_roundtrip():
    from services.recipe_overlay import apply_patches_to_overlay

    overlay = apply_patches_to_overlay(
        {},
        [
            {"action": "ingredient.remove", "item": "돼지고기"},
            {"action": "ingredient.add", "item": "두부", "qty": 200, "unit": "g"},
            {"action": "step.edit", "order": 1, "instruction": "두부를 볶는다."},
        ],
    )
    merged = apply_overlay(KIMCHI, overlay)
    items = [i["item"] for i in merged["ingredients"]]
    assert "돼지고기" not in items
    assert "두부" in items
    assert merged["steps"][0]["instruction"] == "두부를 볶는다."
    restored = apply_patches_to_overlay(overlay, [{"action": "ingredient.restore", "item": "돼지고기"}])
    merged2 = apply_overlay(KIMCHI, restored)
    assert "돼지고기" in [i["item"] for i in merged2["ingredients"]]


def test_apply_overlay_add_then_remove_and_edit_added_qty():
    from services.recipe_overlay import apply_patches_to_overlay

    overlay = apply_patches_to_overlay(
        {},
        [{"action": "ingredient.add", "item": "새우", "qty": 8, "unit": "마리"}],
    )
    merged = apply_overlay(KIMCHI, overlay)
    assert "새우" in [i["item"] for i in merged["ingredients"]]
    edited = apply_patches_to_overlay(
        overlay,
        [{"action": "ingredient.edit", "item": "새우", "qty": 4, "unit": "마리"}],
    )
    merged_edit = apply_overlay(KIMCHI, edited)
    shrimp = next(i for i in merged_edit["ingredients"] if i["item"] == "새우")
    assert shrimp["qty"] == 4.0
    removed = apply_patches_to_overlay(
        edited,
        [{"action": "ingredient.remove", "item": "새우"}],
    )
    merged_rm = apply_overlay(KIMCHI, removed)
    assert "새우" not in [i["item"] for i in merged_rm["ingredients"]]
    assert not (removed.get("ingredients") or {}).get("added")

