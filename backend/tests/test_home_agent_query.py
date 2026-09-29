"""문서 필드 기준 쿼리 계획: 복합 조건·제외·헐거운 키워드."""

from __future__ import annotations

from services.home_agent_query import (
    QueryPlan,
    card_matches_plan,
    plan_home_query,
)
from services.home_agent_rank import compact_from_doc, spicy_craving
from services.home_agent_service import HomeAgentService, match_chip_by_regex
from tests.test_home_agent_guards import FakeReader
from tests.test_home_agent_rank import FakeCardReader, _card


def test_plan_excludes_egg_and_not_include():
    plan = plan_home_query("계란 없이 만들 수 있는 거")
    assert plan.exclude_ingredients == ["계란"]
    assert plan.include_ingredients == []


def test_plan_onion_leftover_and_chicken_with_time():
    onion = plan_home_query("양파 있는데 뭐 해먹지")
    assert onion.include_ingredients == ["양파"]
    chicken = plan_home_query("닭가슴살로 10분")
    assert chicken.include_ingredients == ["닭가슴살"]
    assert chicken.cook_time == "10분 내"


def test_plan_soup_and_thirty_minutes_not_ten():
    soup = plan_home_query("국물 있는 거 추천")
    assert soup.moment == "soup"
    assert soup.menu_type.startswith("국")
    thirty = plan_home_query("30분 안에 저녁")
    assert thirty.cook_time == "30분 내"
    ten = plan_home_query("10분 안에")
    assert ten.cook_time == "10분 내"


def test_spicy_craving_ignores_not_spicy():
    assert spicy_craving("매운 거 땡겨") is True
    assert spicy_craving("안 매운 거") is False
    assert spicy_craving("안매운 음식") is False
    assert match_chip_by_regex("안 매운 거")[0] == "less_spicy"
    assert match_chip_by_regex("청양 없는 매운 거") is None


def test_soup_filter_drops_cheesecake():
    plan = QueryPlan(moment="soup", menu_type="국 / 찌개 / 탕")
    stew = _card("s1", "김치찌개", ings=["김치", "돼지고기"])
    cake = _card("c1", "치즈케이크", ings=["치즈", "설탕"], tags=["디저트"])
    cake.menu_types = ["디저트"]
    stew.menu_types = ["국 / 찌개 / 탕"]
    assert card_matches_plan(stew, plan) is True
    assert card_matches_plan(cake, plan) is False


def test_tag_only_spicy_is_not_content_spicy():
    card = compact_from_doc(
        "t1",
        {
            "status": "completed",
            "tags": ["매운", "매콤"],
            "categories": {"cook_time": ["30분 내"], "menu_type": ["밥"]},
            "groupKey": "덮밥",
            "recipe": {
                "name": "간장 덮밥",
                "ingredients": [{"item": "간장"}, {"item": "밥"}],
                "steps": [{"order": 1, "instruction": "밥을 담는다."}],
            },
        },
    )
    assert card is not None
    assert card.spicy is False
    assert card.menu_types == ["밥"]
    assert card.group_key == "덮밥"


def test_not_spicy_query_uses_weekly_not_craving():
    reader = FakeReader()
    result = HomeAgentService(
        reader=reader,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("LLM should not run")),
    ).run_turn(chip_id=None, message="안 매운 거", focus_ingredient=None)
    assert result["used_llm"] is False
    assert result["spice_low"] is True
    assert result["spice_high"] is False
    assert result["retrieve"] in ("weekly", "keyword")
    assert result["recipe_ids"] == ["w1", "w2", "w3"]


def test_cheongyang_free_spicy_is_not_local_filter():
    reader = FakeReader()
    result = HomeAgentService(
        reader=reader,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("LLM should not run")),
    ).run_turn(chip_id=None, message="청양 없는 매운 거", focus_ingredient=None)
    assert result["retrieve"] != "local_filter"
    assert result["spice_high"] is True
    assert result["spice_low"] is False


def test_chicken_ten_minutes_intersects_ingredient_and_time():
    reader = FakeReader()
    reader.ingredients["닭가슴살"] = ["fast", "mid", "slow", "other"]
    reader.sections["quick_10min"] = ["other"]
    cards = FakeCardReader(
        {
            "fast": _card("fast", "닭가슴살 샐러드", ings=["닭가슴살", "양상추"], cook=["10분 내"]),
            "mid": _card("mid", "오야코동", ings=["닭가슴살", "계란"], cook=["30분 이내"]),
            "slow": _card("slow", "닭가슴살 스테이크", ings=["닭가슴살"], cook=["1시간 이상"]),
            "other": _card("other", "어묵볶음", ings=["어묵"], cook=["10분 내"]),
        }
    )
    result = HomeAgentService(
        reader=reader,
        card_reader=cards,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("intent LLM should not run")),
        rank_json=lambda s, u: (_ for _ in ()).throw(AssertionError("ranker should not be required")),
    ).run_turn(chip_id=None, message="닭가슴살로 10분", focus_ingredient=None)
    assert result["recipe_ids"] == ["fast"]
    assert "어묵" not in result["picks"][0]["name"]
    assert "오야코동" not in [p["name"] for p in result["picks"]]


def test_no_egg_drops_egg_dishes():
    reader = FakeReader()
    cards = FakeCardReader(
        {
            "w1": _card("w1", "계란찜", ings=["계란", "물"]),
            "w2": _card("w2", "두부조림", ings=["두부", "간장"]),
            "w3": _card("w3", "계란말이", ings=["계란", "소금"]),
        }
    )
    result = HomeAgentService(
        reader=reader,
        card_reader=cards,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("intent LLM should not run")),
        rank_json=lambda s, u: ("{}", "deepseek"),
    ).run_turn(chip_id=None, message="계란 없이 만들 수 있는 거", focus_ingredient=None)
    assert result["recipe_ids"] == ["w2"]
    assert "계란" not in result["picks"][0]["name"]


def test_onion_leftover_does_not_ignore_ingredient():
    reader = FakeReader()
    reader.ingredients["양파"] = ["o1"]
    result = HomeAgentService(
        reader=reader,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("LLM should not run")),
    ).run_turn(chip_id=None, message="양파 있는데 뭐 해먹지", focus_ingredient=None)
    assert result["retrieve"] == "ingredient"
    assert result["recipe_ids"] == ["o1"]
    assert reader.ingredient_calls == ["양파"]


def test_cook_time_alias_이내_matches_내():
    from services.home_agent_query import cook_time_ok

    ten = _card("a", "어묵볶음", ings=["어묵"], cook=["10분 이내"])
    thirty = _card("b", "제육볶음", ings=["돼지고기"], cook=["30분 이내"])
    assert cook_time_ok(ten, "10분 내") is True
    assert cook_time_ok(thirty, "10분 내") is False
    assert cook_time_ok(thirty, "30분 내") is True


def test_bibimbap_uses_group_key_when_index_misses():
    reader = FakeReader()
    reader.groups["비빔밥"] = ["b1", "b2"]
    cards = FakeCardReader(
        {
            "b1": _card("b1", "열무 비빔밥", ings=["열무", "밥"]),
            "b2": _card("b2", "돌솥 비빔밥", ings=["밥", "고추장"]),
        }
    )
    result = HomeAgentService(
        reader=reader,
        card_reader=cards,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("intent LLM should not run")),
        rank_json=lambda s, u: (
            '{"reply":"비빔밥으로 골랐어요.","picks":[{"id":"b1","reason":"이름에 비빔밥이 있어요."}]}',
            "deepseek",
        ),
    ).run_turn(chip_id=None, message="비빔밥 보여줘", focus_ingredient=None)
    assert "b1" in result["recipe_ids"]
    assert result["retrieve"] != "client_search"
    assert reader.group_calls and "비빔밥" in reader.group_calls


def test_mild_query_drops_gochugaru_banchan_and_sauce():
    cucumber = _card("w1", "오이무침", ings=["오이", "고춧가루"])
    cucumber.menu_types = ["반찬"]
    sauce = _card("w2", "카우보이 버터", ings=["버터", "마늘"])
    sauce.menu_types = ["음료"]
    egg = _card("w3", "계란말이", ings=["계란", "소금"])
    egg.menu_types = ["반찬"]
    plan = plan_home_query("안 매운 거")
    assert plan.spice == "low"
    assert card_matches_plan(cucumber, plan) is False
    assert card_matches_plan(sauce, plan) is False
    assert card_matches_plan(egg, plan) is True


def test_what_to_eat_prefers_meals_over_banchan():
    side = _card("w1", "오이무침", ings=["오이", "소금"])
    side.menu_types = ["반찬"]
    stew = _card("w2", "김치찌개", ings=["김치", "돼지고기"])
    stew.menu_types = ["찌개"]
    sauce = _card("w3", "카우보이 버터", ings=["버터"])
    sauce.menu_types = ["음료"]
    reader = FakeReader()
    cards = FakeCardReader({"w1": side, "w2": stew, "w3": sauce})
    result = HomeAgentService(
        reader=reader,
        card_reader=cards,
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("intent LLM should not run")),
        rank_json=lambda s, u: (_ for _ in ()).throw(RuntimeError("ranker fallback")),
    ).run_turn(chip_id=None, message="뭐 해먹지", focus_ingredient=None)
    names = [p["name"] for p in result["picks"]]
    assert "김치찌개" in names
    assert "카우보이 버터" not in names
    assert names[0] == "김치찌개"
    assert result["used_ranker"] is False


def test_doenjang_stew_expands_to_soup_menu_and_stem():
    plan = plan_home_query("된장찌개 찾아줘")
    assert plan.menu_type.startswith("국")
    assert "된장찌개" in plan.name_needles
    assert "된장" in plan.name_needles
    stew = _card("a", "차돌 된장찌개", ings=["된장", "두부"])
    stew.menu_types = ["찌개"]
    banchan = _card("b", "된장무침", ings=["된장", "오이"])
    banchan.menu_types = ["반찬"]
    assert card_matches_plan(stew, plan) is True
    assert card_matches_plan(banchan, plan) is False


def test_kid_allows_bulgogi_and_blocks_spicy_name():
    plan = plan_home_query("아이 입맛에 맞는 거")
    assert plan.moment == "kid"
    bulgogi = _card("a", "소불고기", ings=["소고기", "간장", "설탕"])
    bulgogi.menu_types = ["밥"]
    egg = _card("b", "계란말이", ings=["계란", "소금"])
    egg.menu_types = ["반찬"]
    spicy = _card("c", "매운 제육볶음", ings=["돼지고기", "고추장"])
    spicy.menu_types = ["밥"]
    stew = _card("d", "돼지고기 김치찌개", ings=["돼지고기", "김치"])
    stew.menu_types = ["찌개"]
    ribs = _card("e", "우삼겹갈비탕", ings=["우삼겹", "무"])
    ribs.menu_types = ["찌개"]
    gamjatang = _card("f", "순살감자탕", ings=["돼지 앞다리살", "감자"])
    gamjatang.menu_types = ["찌개"]
    assert card_matches_plan(bulgogi, plan) is True
    assert card_matches_plan(egg, plan) is True
    assert card_matches_plan(spicy, plan) is False
    assert card_matches_plan(stew, plan) is False
    assert card_matches_plan(ribs, plan) is False
    assert card_matches_plan(gamjatang, plan) is False


def test_vegetarian_drops_egg_and_meat():
    plan = plan_home_query("채식")
    egg = _card("a", "두부 계란전", ings=["두부", "계란"])
    tofu = _card("b", "두부조림", ings=["두부", "간장", "버섯"])
    meat = _card("c", "버섯 불고기", ings=["소고기", "버섯"])
    baby = _card("d", "두부 자기주도식", ings=["두부", "당근"])
    assert card_matches_plan(egg, plan) is False
    assert card_matches_plan(tofu, plan) is True
    assert card_matches_plan(meat, plan) is False
    assert card_matches_plan(baby, plan) is False


def test_health_requires_real_light_ingredients():
    plan = plan_home_query("건강한 거")
    salad = _card("a", "닭가슴살 샐러드", ings=["닭가슴살", "양상추"])
    cake = _card("b", "치즈케이크", ings=["치즈", "설탕"])
    cake.menu_types = ["디저트"]
    spicy = _card("c", "스파이시 치킨 샐러드", ings=["닭가슴살", "상추"])
    assert card_matches_plan(salad, plan) is True
    assert card_matches_plan(cake, plan) is False
    assert card_matches_plan(spicy, plan) is False
    baguette = _card("d", "통밀바게트", ings=["통밀가루", "소금", "두부"])
    assert card_matches_plan(baguette, plan) is False


def test_low_salt_drops_jjamppong_and_stew():
    plan = plan_home_query("저염")
    assert plan.moment == "low_salt"
    soup = _card("a", "짬뽕탕", ings=["오징어", "고춧가루"])
    soup.menu_types = ["찌개"]
    salad = _card("b", "닭가슴살 샐러드", ings=["닭가슴살", "양상추"])
    salad.menu_types = ["샐러드"]
    spicy_salad = _card("c", "매콤감자샐러드", ings=["감자", "마요네즈"])
    spicy_salad.menu_types = ["샐러드"]
    assert card_matches_plan(soup, plan) is False
    assert card_matches_plan(salad, plan) is True
    assert card_matches_plan(spicy_salad, plan) is False


def test_airfryer_name_outRanks_dessert_with_tool_in_steps():
    from services.home_agent_query import score_plan_card

    plan = plan_home_query("에어프라이어 요리")
    chicken = _card("a", "에어프라이어 치킨", ings=["닭다리"])
    chicken.menu_types = ["반찬"]
    chicken.weekly_saves = 2
    cake = _card("b", "치즈케이크", ings=["치즈", "설탕"])
    cake.menu_types = ["디저트"]
    cake.weekly_saves = 80
    cake.steps_text = "에어프라이어에 15분 굽는다."
    cake.steps_preview = ["에어프라이어에 15분 굽는다."]
    baby = _card("c", "아기 프렌치파이", ings=["단호박", "치즈"])
    baby.steps_preview = ["에어프라이어에 굽는다."]
    baby.steps_text = "에어프라이어에 굽는다."
    assert card_matches_plan(chicken, plan) is True
    assert card_matches_plan(cake, plan) is True
    assert card_matches_plan(baby, plan) is False
    assert score_plan_card(chicken, plan) > score_plan_card(cake, plan)


def test_template_reason_skips_salad_as_ingredient():
    from services.home_agent_rank import template_reason

    card = _card("a", "닭가슴살 샐러드", ings=["샐러드", "닭가슴살", "양상추"])
    reason = template_reason(card, q="건강")
    assert "샐러드가 재료" not in reason
    assert "닭가슴살" in reason or "양상추" in reason or "이름" in reason


def test_microwave_query_is_tool_not_leftover_ingredient():
    plan = plan_home_query("전자레인지로 만들 수 있는 거")
    assert plan.tools == ["전자레인지"]
    assert plan.include_ingredients == []
    corn = _card("a", "초당 옥수수 콘립", ings=["옥수수"])
    corn.steps_preview = ["전자레인지에 돌린다."]
    corn.steps_text = "전자레인지에 돌린다."
    stew = _card("b", "김치찌개", ings=["김치"])
    assert card_matches_plan(corn, plan) is True
    assert card_matches_plan(stew, plan) is False


def test_kid_shortlist_drops_kimchi_when_enough_mild():
    from services.home_agent_query import shortlist_plan_cards

    plan = plan_home_query("아이 입맛에 맞는 거")
    rice = _card("a", "참치 주먹밥", ings=["밥", "참치"])
    rice.menu_types = ["밥"]
    noodle = _card("b", "불고기 야끼우동", ings=["소고기", "우동"])
    noodle.menu_types = ["면"]
    meat = _card("c", "불고기", ings=["소고기", "간장"])
    kimchi = _card("d", "대패삼겹살 김치 솥밥", ings=["삼겹살", "김치"])
    kimchi.menu_types = ["밥"]
    picked = shortlist_plan_cards([rice, noodle, meat, kimchi], plan, limit=4)
    names = [c.name for c in picked]
    assert "대패삼겹살 김치 솥밥" not in names
    assert names[0] == "참치 주먹밥"
    assert len(picked) == 3


def test_public_reply_strips_urls_and_fences():
    from services.home_agent_service import sanitize_public_reply

    text = sanitize_public_reply("보세요 https://evil.test/x ```code``` 끝")
    assert "http" not in text
    assert "```" not in text
    assert "보세요" in text


def test_kid_reply_mentions_child_not_just_mild():
    result = HomeAgentService(
        reader=FakeReader(),
        llm_json=lambda s, u: (_ for _ in ()).throw(AssertionError("LLM should not run")),
    ).run_turn(chip_id=None, message="아이 입맛에 맞는 거", focus_ingredient=None)
    assert "아이" in result["reply"]
    assert result["used_llm"] is False
    assert result["used_ranker"] is False


def test_airfryer_gather_uses_tool_index_not_weekly():
    from services.home_agent_query import gather_candidate_ids

    reader = FakeReader()
    reader.ingredients["에어프라이어"] = ["af1", "af2", "af3"]
    reader.ingredients["에어프라이"] = ["af1"]
    reader.menus["밥"] = ["rice1", "rice2"]
    reader.menus["간식"] = ["snack1"]
    plan = plan_home_query("에어프라이어 요리")
    ids = gather_candidate_ids(plan, reader, cap=24)
    assert "af1" in ids
    assert reader.weekly_calls == 0
    assert "밥" not in reader.menu_calls


def test_vegan_gather_opens_rice_bowl_menu():
    from services.home_agent_query import gather_candidate_ids

    reader = FakeReader()
    reader.ingredients["두부"] = ["v1", "v2"]
    plan = plan_home_query("채식")
    gather_candidate_ids(plan, reader, cap=24)
    assert "덮밥" in reader.menu_calls
    assert reader.menu_calls[0] in ("샐러드", "덮밥", "반찬")
    assert reader.weekly_calls == 0


def test_kid_plan_skips_morning_section():
    plan = plan_home_query("아이 입맛에 맞는 거")
    assert plan.moment == "kid"
    assert plan.section_key == ""
    assert plan.retrieve_hint != "section"
    from services.home_agent_query import gather_candidate_ids

    reader = FakeReader()
    reader.groups["주먹밥"] = ["k1", "k2"]
    plan = plan_home_query("아이 입맛에 맞는 거")
    ids = gather_candidate_ids(plan, reader, cap=24)
    assert "주먹밥" in reader.group_calls
    assert "주먹밥" not in reader.ingredient_calls
    assert "k1" in ids


def test_low_salt_prefers_salad_over_jeon():
    from services.home_agent_query import score_plan_card

    plan = plan_home_query("저염")
    salad = _card("a", "닭가슴살 샐러드", ings=["닭가슴살", "양상추"])
    salad.menu_types = ["샐러드"]
    salad.weekly_saves = 1
    jeon = _card("b", "두부전", ings=["두부", "부침가루"])
    jeon.menu_types = ["반찬"]
    jeon.weekly_saves = 20
    assert score_plan_card(salad, plan) > score_plan_card(jeon, plan)


def test_vegan_rice_bowl_outRanks_plain_salad_when_tofu_in_name():
    from services.home_agent_query import score_plan_card

    plan = plan_home_query("채식")
    bowl = _card("a", "두부덮밥", ings=["두부", "쌀밥", "간장"])
    bowl.menu_types = ["밥"]
    salad = _card("b", "그릭 오이 샐러드", ings=["오이", "올리브"])
    salad.menu_types = ["샐러드"]
    salad.weekly_saves = 8
    assert card_matches_plan(bowl, plan) is True
    assert score_plan_card(bowl, plan) >= score_plan_card(salad, plan)
