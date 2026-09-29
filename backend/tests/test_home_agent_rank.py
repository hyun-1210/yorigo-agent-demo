"""닫힌 집합 랭킹: 모르는 id 폐기, 접지되지 않은 reason 교체, 읽기 상한."""

from __future__ import annotations

import json
from typing import Dict, List, Sequence

from services.home_agent_rank import (
    MAX_CANDIDATES,
    CompactCard,
    compact_from_doc,
    reason_is_grounded,
    sanitize_ranker_picks,
    template_reason,
)
from services.home_agent_service import HomeAgentService
from tests.test_home_agent_guards import FakeReader


def _card(
    rid: str,
    name: str,
    *,
    ings: List[str] | None = None,
    tags: List[str] | None = None,
    cook: List[str] | None = None,
    spicy: bool = False,
) -> CompactCard:
    return CompactCard(
        id=rid,
        name=name,
        tags=tags or [],
        servings=2,
        cook_time=cook or ["30분 내"],
        ingredients=ings or ["김치"],
        weekly_saves=1,
        steps_preview=["김치를 넣고 끓인다."],
        spicy=spicy,
        mains=["채소"],
    )


class FakeCardReader:
    def __init__(self, cards: Dict[str, CompactCard]) -> None:
        self.cards = cards
        self.calls: List[List[str]] = []

    def compact_cards(self, ids: Sequence[str], limit: int) -> List[CompactCard]:
        take = list(ids)[: min(limit, MAX_CANDIDATES)]
        self.calls.append(take)
        assert len(take) <= MAX_CANDIDATES
        return [self.cards[i] for i in take if i in self.cards]


def test_compact_from_doc_skips_hidden_and_extracts_fields():
    hidden = compact_from_doc("x", {"isHidden": True, "status": "completed", "recipe": {"name": "A"}})
    assert hidden is None
    card = compact_from_doc(
        "p1",
        {
            "status": "completed",
            "title": "겉제목",
            "tags": ["매콤", "집밥"],
            "weeklySaves": 9,
            "categories": {"cook_time": ["10분 내"], "main_ingredient": ["돼지고기"]},
            "recipe": {
                "name": "이연복 김치찌개",
                "servings": 2,
                "ingredients": [{"item": "김치"}, {"item": "청양고추"}],
                "steps": [
                    {"order": 1, "instruction": "김치를 볶는다."},
                    {"order": 2, "instruction": "물을 넣고 끓인다."},
                ],
            },
        },
    )
    assert card is not None
    assert card.name == "이연복 김치찌개"
    assert "김치" in card.ingredients
    assert card.spicy is True
    assert card.cook_time == ["10분 내"]
    assert card.steps_preview[0].startswith("김치")


def test_ranker_advice_and_english_keys_are_replaced():
    card = _card("a", "김치찌개", ings=["김치", "고춧가루"])
    _, picks, warnings = sanitize_ranker_picks(
        {
            "reply": "골랐어요.",
            "picks": [
                {
                    "id": "a",
                    "reason": "고춧가루를 줄이면 덜 맵게 할 수 있어요. ingredients에 김치가 있어요.",
                }
            ],
        },
        [card],
        q="김치찌개",
    )
    assert picks[0]["recipe_id"] == "a"
    assert "줄이" not in picks[0]["reason"]
    assert "ingredients" not in picks[0]["reason"]
    assert "ungrounded_reason" in warnings
    card = _card("a", "돼지고기 김치찌개", ings=["돼지고기", "김치"])
    reply, picks, warnings = sanitize_ranker_picks(
        {
            "reply": "김치찌개로 골랐어요.",
            "picks": [
                {"id": "a", "reason": "우주에서 온 특제 소스 맛이 일품입니다"},
                {"id": "HACKED", "reason": "없는 레시피"},
            ],
        },
        [card],
        q="김치찌개",
    )
    assert [p["recipe_id"] for p in picks] == ["a"]
    assert "HACKED" not in str(picks)
    assert "ungrounded_reason" in warnings
    assert "dropped_unknown_id" in warnings
    assert reason_is_grounded(picks[0]["reason"], card)
    assert "김치" in picks[0]["reason"] or "김치찌개" in picks[0]["reason"]
    assert reply.startswith("김치찌개")


def test_template_reason_cites_ingredient_and_time():
    card = _card("c1", "닭가슴살 샐러드", ings=["닭가슴살", "양상추"], cook=["10분 내"])
    reason = template_reason(card, focus="닭가슴살")
    assert "닭가슴살" in reason
    assert "10분" in reason or "양상추" in reason or "태그" in reason


def test_yasik_uses_late_night_section_not_client_search():
    reader = FakeReader()
    reader.sections["moment_late_night"] = ["n1", "n2"]
    result = HomeAgentService(
        reader=reader,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("LLM should not run")),
    ).run_turn(chip_id=None, message="야식", focus_ingredient=None)
    assert result["retrieve"] == "section"
    assert result["section_key"] == "moment_late_night"
    assert result["used_llm"] is False
    assert result["recipe_ids"] == ["n1", "n2"]


def test_ranker_picks_closed_set_and_drops_unknown_ids():
    reader = FakeReader()
    reader.ingredients["김치"] = ["k1", "k2", "k3"]
    cards = FakeCardReader(
        {
            "k1": _card("k1", "이연복 김치찌개", ings=["김치", "돼지고기"], spicy=True),
            "k2": _card("k2", "백종원 김치찌개", ings=["김치"], spicy=True),
            "k3": _card("k3", "된장찌개", ings=["된장", "두부"]),
        }
    )

    def rank(_system: str, _user: str) -> tuple:
        payload = {
            "reply": "김치가 들어간 찌개로 골랐어요.",
            "picks": [
                {"id": "k1", "reason": "이름에 김치찌개가 있고 재료에 돼지고기가 있어요."},
                {"id": "GHOST", "reason": "없는 카드"},
                {"id": "k2", "reason": "이름에 김치찌개가 있어요."},
            ],
        }
        return json.dumps(payload, ensure_ascii=False), "deepseek"

    result = HomeAgentService(
        reader=reader,
        card_reader=cards,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("intent LLM should not run")),
        rank_json=rank,
    ).run_turn(chip_id=None, message="김치찌개 추천해줘", focus_ingredient=None)
    assert result["used_llm"] is False
    assert result["used_ranker"] is False
    assert result["retrieve"] != "client_search"
    assert result["q"] == ""
    reasons = {p["recipe_id"]: p["reason"] for p in result["picks"]}
    assert "김치" in reasons["k1"]
    assert len(cards.calls[0]) <= MAX_CANDIDATES


def test_section_chip_uses_template_reasons_without_ranker():
    reader = FakeReader()
    cards = FakeCardReader(
        {
            "p1": _card("p1", "닭가슴살 스테이크", ings=["닭가슴살"], cook=["10분 내"]),
            "p2": _card("p2", "그릭요거트볼", ings=["그릭요거트"]),
            "p3": _card("p3", "연어 샐러드", ings=["연어"]),
        }
    )
    called = {"rank": False}

    def rank(_s: str, _u: str) -> tuple:
        called["rank"] = True
        return "{}", "deepseek"

    result = HomeAgentService(
        reader=reader,
        card_reader=cards,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("intent LLM should not run")),
        rank_json=rank,
    ).run_turn(chip_id="high_protein", message="", focus_ingredient=None)
    assert called["rank"] is False
    assert result["used_ranker"] is False
    assert result["recipe_ids"] == ["p1", "p2", "p3"]
    assert result["picks"]
    assert "닭가슴살" in result["picks"][0]["reason"] or "10분" in result["picks"][0]["reason"]


def test_leftover_ingredient_ranker_only_from_index_ids():
    reader = FakeReader()
    cards = FakeCardReader(
        {
            "c1": _card("c1", "닭가슴살 덮밥", ings=["닭가슴살", "밥"]),
            "c2": _card("c2", "닭가슴살 샐러드", ings=["닭가슴살", "양상추"], cook=["10분 내"]),
        }
    )

    def rank(_s: str, _u: str) -> tuple:
        payload = {
            "reply": "닭가슴살이 들어간 요리예요.",
            "picks": [
                {"id": "c2", "reason": "재료에 닭가슴살이 있고 조리시간은 10분 내예요."},
                {"id": "OUTSIDE", "reason": "외부 id"},
            ],
        }
        return json.dumps(payload, ensure_ascii=False), "deepseek"

    result = HomeAgentService(
        reader=reader,
        card_reader=cards,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("intent LLM should not run")),
        rank_json=rank,
    ).run_turn(chip_id=None, message="닭가슴살 남은 거", focus_ingredient=None)
    assert result["recipe_ids"][0] == "c2"
    assert "OUTSIDE" not in result["recipe_ids"]
    assert result["used_ranker"] is False
    assert "닭가슴살" in result["picks"][0]["reason"]


def test_ranker_only_for_spicy_or_intent_llm():
    from services.home_agent_rank import should_call_ranker

    assert not should_call_ranker(
        retrieve="weekly", used_intent_llm=False, spice_high=False, card_count=4, from_chip=False
    )
    assert should_call_ranker(
        retrieve="keyword", used_intent_llm=False, spice_high=True, card_count=4, from_chip=False
    )
    assert should_call_ranker(
        retrieve="weekly", used_intent_llm=True, spice_high=False, card_count=4, from_chip=False
    )
    assert not should_call_ranker(
        retrieve="keyword", used_intent_llm=False, spice_high=False, card_count=4, from_chip=False
    )
    assert not should_call_ranker(
        retrieve="ingredient", used_intent_llm=False, spice_high=False, card_count=4, from_chip=False
    )
    assert not should_call_ranker(
        retrieve="weekly", used_intent_llm=False, spice_high=False, card_count=4, from_chip=True
    )
