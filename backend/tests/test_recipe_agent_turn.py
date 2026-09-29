"""run_turn 계약. 실제 LLM 없이 스냅샷·가드·프롬프트만 검증한다."""

from __future__ import annotations

import json
import sys
import types
from typing import Any, Dict, List, Optional

from services.recipe_agent_service import (
    CONFIRM_ASK,
    CONFIRMED_REPLY,
    DECLINED_REPLY,
    ERROR_REPLY,
    MAX_CLIENT_SNAPSHOT_BYTES,
    NEED_CONFIRM_REQUEST_REPLY,
    RecipeAgentService,
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


class FakeLLM:
    """research + JSON 생성만 흉내 낸다."""

    def __init__(
        self,
        text: Any,
        engine: str = "deepseek",
        notes: Optional[List[str]] = None,
        sources: Optional[List[str]] = None,
        research_exc: Optional[Exception] = None,
    ) -> None:
        self._texts = list(text) if isinstance(text, list) else [text]
        self._i = 0
        self.engine = engine
        self.notes = list(notes or [])
        self.sources = list(sources or [])
        self.research_exc = research_exc
        self.research_calls: List[Dict[str, Any]] = []
        self.gen_users: List[str] = []

    def research_recipe_adaptation(self, **kwargs: Any) -> Dict[str, Any]:
        self.research_calls.append(kwargs)
        if self.research_exc is not None:
            raise self.research_exc
        return {"notes": self.notes, "sources": self.sources}

    def generate_recipe_agent_json(self, *, system: str, user: str) -> tuple:
        self.gen_users.append(user)
        idx = min(self._i, len(self._texts) - 1)
        self._i += 1
        return self._texts[idx], self.engine

    def _extract_json_object(self, text: str) -> Dict[str, Any]:
        return json.loads(text)

    def _strip_md_fences(self, text: str) -> str:
        return text


def _patch_llm(monkeypatch, fake: FakeLLM) -> None:
    """가벼운 테스트 환경은 llm_service 실모듈을 못 불러서 스텁한다."""
    mod = types.ModuleType("services.llm_service")
    mod.get_llm_service = lambda: fake  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "services.llm_service", mod)


def _ok_json(reply: str = "고춧가루는 2번에 넣어요.", patches: Optional[list] = None) -> str:
    return json.dumps(
        {
            "on_topic": True,
            "reply": reply,
            "followup_chips": ["less_spicy", "nope"],
            "proposed_patches": patches or [],
            "warnings": [],
        },
        ensure_ascii=False,
    )


def test_servings_chip_skips_llm(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="servings",
        message="",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["on_topic"] is True
    assert "인분" in body["reply"]
    assert fake.gen_users == []


def test_missing_ingredient_without_focus_asks_to_pick(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="missing_ingredient",
        message="",
        focus_ingredient="",
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["on_topic"] is False
    assert "재료" in body["reply"]
    assert fake.gen_users == []


def test_missing_ingredient_ghost_focus_skips_llm(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="missing_ingredient",
        message="",
        focus_ingredient="시금치",
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["on_topic"] is True
    assert body["proposed_patches"] == []
    assert "시금치" in body["reply"]
    assert fake.gen_users == []
    assert fake.research_calls == []


def test_fact_question_does_not_research(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="고춧가루는 언제 넣나요?",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert fake.research_calls == []
    assert fake.gen_users


def test_remove_request_researches_and_keeps_patches(monkeypatch):
    fake = FakeLLM(
        _ok_json(
            reply="돼지고기를 빼요.",
            patches=[{"action": "ingredient.remove", "item": "돼지고기"}],
        ),
        notes=["두부로 대체해도 된다."],
        sources=["example.com"],
    )
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="돼지고기 빼줘",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert fake.research_calls
    assert body["proposed_patches"][0]["action"] == "ingredient.remove"
    assert any("example.com" in w for w in body["warnings"])
    assert body["awaiting_confirm"] is True
    assert CONFIRM_ASK in body["reply"]
    assert body["followup_chips"] == ["confirm", "decline"]
    assert "nope" not in body["followup_chips"]


def test_overlay_hides_removed_item_from_prompt(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    overlay = {"ingredients": {"removed": ["돼지고기"]}}
    RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="고춧가루는 언제 넣나요?",
        focus_ingredient=None,
        overlay=overlay,
        client_snapshot=KIMCHI,
        history=None,
    )
    prompt = fake.gen_users[0]
    payload = json.loads(prompt.split("<<RECIPE>")[1].split("<<END_RECIPE>>")[0])
    items = [i["item"] for i in payload["ingredients"]]
    assert "돼지고기" not in items
    assert "김치" in items


def test_invalid_json_returns_error_reply(monkeypatch):
    fake = FakeLLM("not-json")
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="고춧가루는 언제 넣나요?",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["reply"] == ERROR_REPLY
    assert body["proposed_patches"] == []


def test_llm_off_topic_clears_patches(monkeypatch):
    fake = FakeLLM(
        json.dumps(
            {
                "on_topic": False,
                "reply": "날씨요",
                "followup_chips": ["air_fryer"],
                "proposed_patches": [{"action": "ingredient.add", "item": "설탕", "qty": 1, "unit": "g"}],
                "warnings": [],
            },
            ensure_ascii=False,
        )
    )
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="오늘 하늘 색이 뭐예요?",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["on_topic"] is False
    assert body["proposed_patches"] == []
    assert body["followup_chips"] == []


def test_researched_empty_notes_warns(monkeypatch):
    fake = FakeLLM(
        _ok_json(
            reply="에어프라이어 200도 8분.",
            patches=[
                {
                    "action": "step.edit",
                    "order": 1,
                    "instruction": "돼지고기를 에어프라이어 200도 8분.",
                }
            ],
        ),
        notes=[],
        sources=[],
    )
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="air_fryer",
        message="",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert any("검색 없이" in w for w in body["warnings"])
    assert fake.research_calls


def test_research_failure_still_answers(monkeypatch):
    fake = FakeLLM(
        _ok_json(reply="고춧가루를 줄여요.", patches=[{"action": "ingredient.edit", "item": "고춧가루", "qty": 0.5, "unit": "큰술"}]),
        research_exc=RuntimeError("search down"),
    )
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="less_spicy",
        message="",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["on_topic"] is True
    assert body["proposed_patches"]


def test_client_snapshot_too_large():
    huge = {
        "name": "x",
        "servings": 1,
        "ingredients": [{"item": "가" * 20, "qty": 1, "unit": "g"}] * 400,
        "steps": [{"order": 1, "instruction": "볶는다."}],
    }
    raw = json.dumps(huge, ensure_ascii=False)
    assert len(raw.encode("utf-8")) > MAX_CLIENT_SNAPSHOT_BYTES
    try:
        RecipeAgentService().load_base_recipe(recipe_id=None, client_snapshot=huge)
        raise AssertionError("expected ValueError")
    except ValueError as exc:
        assert str(exc) == "client_snapshot_too_large"


def test_empty_recipe_is_rejected(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="어떻게 만들어요?",
        focus_ingredient=None,
        overlay=None,
        client_snapshot={"name": "빈것", "servings": 1, "ingredients": [], "steps": []},
        history=None,
    )
    assert body["on_topic"] is False
    assert "부족" in body["reply"]
    assert fake.gen_users == []


def test_unknown_chip_with_empty_message_is_empty_guard(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="foobar",
        message="",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["on_topic"] is False
    assert fake.gen_users == []


def test_reply_is_clipped(monkeypatch):
    fake = FakeLLM(_ok_json(reply="가" * 500))
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="고춧가루는 언제 넣나요?",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert len(body["reply"]) <= 400


def test_change_request_retries_when_first_turn_has_no_patches(monkeypatch):
    talk = _ok_json(reply="원하시면 패치할게요.", patches=[])
    patched = _ok_json(
        reply="돼지고기를 빼요.",
        patches=[{"action": "ingredient.remove", "item": "돼지고기"}],
    )
    fake = FakeLLM([talk, patched])
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="돼지고기 빼줘",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert len(fake.gen_users) == 2
    assert "proposed_patches를 채워라" in fake.gen_users[1]
    assert body["proposed_patches"][0]["action"] == "ingredient.remove"
    assert body["reply"].startswith("돼지고기를 빼요.")
    assert CONFIRM_ASK in body["reply"]
    assert body["awaiting_confirm"] is True


def test_fact_question_does_not_ask_confirm(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="고춧가루는 언제 넣나요?",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert body["awaiting_confirm"] is False
    assert CONFIRM_ASK not in body["reply"]
    assert body["proposed_patches"] == []


def test_confirm_yes_applies_pending_without_llm(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="네",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
        pending_patches=[{"action": "ingredient.remove", "item": "돼지고기"}],
    )
    assert fake.gen_users == []
    assert fake.research_calls == []
    assert body["reply"] == CONFIRMED_REPLY
    assert body["awaiting_confirm"] is False
    assert body["proposed_patches"] == [
        {"action": "ingredient.remove", "item": "돼지고기"}
    ]


def test_confirm_chip_yes_without_pending_asks_again(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="confirm",
        message="",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
    )
    assert fake.gen_users == []
    assert body["reply"] == NEED_CONFIRM_REQUEST_REPLY
    assert body["proposed_patches"] == []
    assert body["awaiting_confirm"] is False


def test_confirm_no_clears_pending_without_llm(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id="decline",
        message="",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
        pending_patches=[{"action": "ingredient.remove", "item": "돼지고기"}],
    )
    assert fake.gen_users == []
    assert body["reply"] == DECLINED_REPLY
    assert body["proposed_patches"] == []
    assert body["awaiting_confirm"] is False


def test_confirm_yes_drops_stale_pending_item(monkeypatch):
    fake = FakeLLM(_ok_json())
    _patch_llm(monkeypatch, fake)
    body = RecipeAgentService().run_turn(
        recipe_id=None,
        chip_id=None,
        message="진행할게요",
        focus_ingredient=None,
        overlay=None,
        client_snapshot=KIMCHI,
        history=None,
        pending_patches=[{"action": "ingredient.remove", "item": "시금치"}],
    )
    assert fake.gen_users == []
    assert body["proposed_patches"] == []
    assert "맞지 않" in body["reply"]
