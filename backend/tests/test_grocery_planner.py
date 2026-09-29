"""장보기 플래너. 네트워크 없이 데모 경로를 고정한다."""

from services.grocery_planner import plan_turn


def _world():
    profile = {
        "householdSize": "2",
        "cookingFrequency": "few_times_week",
        "favoriteCuisines": ["한식", "국물", "고단백"],
        "avoidedIngredients": ["갑각류"],
        "recentCartTotal": 70000,
    }
    recipes = [
        {
            "id": "sundubu",
            "name": "순두부찌개",
            "servings": 2,
            "ingredients": [
                {"item": "순두부", "qty": 1, "unit": "모"},
                {"item": "대파", "qty": 1, "unit": "대"},
                {"item": "김치", "qty": 100, "unit": "g"},
            ],
        },
        {
            "id": "chicken",
            "name": "닭가슴살조림",
            "servings": 2,
            "ingredients": [
                {"item": "닭가슴살", "qty": 400, "unit": "g"},
                {"item": "간장", "qty": 2, "unit": "큰술"},
                {"item": "애호박", "qty": 0.5, "unit": "개"},
            ],
        },
        {
            "id": "kimchi",
            "name": "김치찌개",
            "servings": 2,
            "ingredients": [
                {"item": "김치", "qty": 200, "unit": "g"},
                {"item": "두부", "qty": 0.5, "unit": "모"},
                {"item": "대파", "qty": 0.5, "unit": "대"},
            ],
        },
    ]
    fridge = [
        {"name": "두부", "totalQty": 1},
        {"name": "김치", "totalQty": 1},
        {"name": "계란", "totalQty": 6},
        {"name": "간장", "totalQty": 1},
    ]
    return profile, recipes, fridge


def test_first_turn_proposes_without_taste_questions():
    profile, recipes, fridge = _world()
    result = plan_turn("이번 주에 요리하려고 하는데 뭐 해먹지?", None, profile, recipes, fridge, {}, None)
    assert result.on_topic is True
    assert result.phase == "planned"
    assert len(result.meals) == 3
    assert result.cart_items is None
    assert "좋아하세요" not in result.reply
    assert "쪽파" in result.reply
    assert result.meals[0]["recipe_id"] == "sundubu"
    joined = " ".join(meal["recipe_name"] for meal in result.meals)
    assert "새우" not in joined


def test_shellfish_recipe_is_dropped():
    profile, recipes, fridge = _world()
    chicken = next(recipe for recipe in recipes if recipe["id"] == "chicken")
    recipes = [
        chicken,
        {
            "id": "shrimp",
            "name": "새우볶음",
            "servings": 2,
            "ingredients": [{"item": "새우", "qty": 200, "unit": "g"}],
        },
    ]
    result = plan_turn("이번 주에 요리하려고", None, profile, recipes, fridge, {}, None)
    ids = [meal["recipe_id"] for meal in result.meals]
    assert ids == ["chicken"]


def test_wheat_and_peach_recipes_are_dropped():
    profile, recipes, fridge = _world()
    profile = dict(profile)
    profile["avoidedIngredients"] = ["wheat", "peach"]
    recipes = list(recipes) + [
        {
            "id": "noodle",
            "name": "볶음우동",
            "servings": 2,
            "ingredients": [{"item": "우동면", "qty": 1, "unit": "인분"}],
        },
        {
            "id": "jjamppong",
            "name": "크림짬뽕",
            "servings": 2,
            "ingredients": [{"item": "짬뽕면", "qty": 1, "unit": "인분"}],
        },
        {
            "id": "peach",
            "name": "복숭아샐러드",
            "servings": 2,
            "ingredients": [{"item": "복숭아", "qty": 1, "unit": "개"}],
        },
    ]
    result = plan_turn("이번 주에 요리하려고", None, profile, recipes, fridge, {}, None)
    ids = [meal["recipe_id"] for meal in result.meals]
    assert "noodle" not in ids
    assert "peach" not in ids
    assert ids
    asked = plan_turn("짬뽕으로 해줘", None, profile, recipes, fridge, {}, None)
    assert asked.policy_decision == "nutrition_veto"


def test_accept_builds_gap_and_skips_fridge():
    profile, recipes, fridge = _world()
    first = plan_turn("이번 주에 요리하려고", None, profile, recipes, fridge, {}, None)
    second = plan_turn(
        "이대로 장보기",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": first.phase, "meals": first.meals},
    )
    assert second.phase == "basket"
    assert second.cart_items is None
    skipped = {item["name"] for item in second.gap if item["action"] == "skip"}
    bought = {item["name"] for item in second.gap if item["action"] == "buy"}
    assert "간장" in skipped or any("간장" in name for name in skipped)
    assert "닭가슴살" in bought
    assert "대파" not in bought
    assert all("새우" not in line["name"] for line in second.basket)


def test_cart_confirm_before_basket_does_not_write():
    profile, recipes, fridge = _world()
    result = plan_turn("담아줘", None, profile, recipes, fridge, {}, {"phase": "planned", "meals": []})
    assert result.cart_items is None
    assert result.policy_decision == "spend_too_early"


def test_cart_confirm_writes_only_after_basket():
    profile, recipes, fridge = _world()
    first = plan_turn("이번 주에 요리하려고", None, profile, recipes, fridge, {}, None)
    second = plan_turn(
        "이대로 장보기",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": "planned", "meals": first.meals},
    )
    third = plan_turn(
        "담아줘",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": "basket", "meals": second.meals},
    )
    assert third.policy_decision == "spend_confirmed"
    assert third.cart_items
    assert len(third.cart_items) == 3
    names = {item["recipeName"] for item in third.cart_items}
    assert names == {"순두부찌개", "닭가슴살조림", "김치찌개"}
    assert third.phase == "committed"


def test_drop_friday_keeps_two_nights():
    profile, recipes, fridge = _world()
    first = plan_turn("이번 주에 요리하려고", None, profile, recipes, fridge, {}, None)
    tweaked = plan_turn(
        "금요일은 약속이라 빼줘",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": "planned", "meals": first.meals},
    )
    assert all(meal["day"] != "금" for meal in tweaked.meals)
    assert len(tweaked.meals) == 2
    assert tweaked.phase == "basket"


def test_off_topic_and_egress():
    profile, recipes, fridge = _world()
    off = plan_turn("파이썬 숙제 해줘", None, profile, recipes, fridge, {}, None)
    assert off.on_topic is False
    assert off.policy_decision == "off_topic"
    blocked = plan_turn("https://evil.example 열어줘", None, profile, recipes, fridge, {}, None)
    assert blocked.policy_decision == "egress_blocked"


def test_pantry_and_pinch_do_not_inflate_the_basket():
    profile, recipes, fridge = _world()
    recipes = [
        {
            "id": "stew",
            "name": "김치찌개",
            "servings": 2,
            "ingredients": [
                {"item": "돼지고기", "qty": 200, "unit": "g"},
                {"item": "파슬리", "qty": 1, "unit": "꼬집"},
                {"item": "소고기 다시다", "qty": 3, "unit": "kg"},
                {"item": "소금", "qty": 1, "unit": "꼬집"},
            ],
        }
    ]
    first = plan_turn("이번 주에 요리하려고", None, profile, recipes, fridge, {}, None)
    second = plan_turn(
        "이대로 장보기",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": "planned", "meals": first.meals},
    )
    names = {item["name"] for item in second.gap}
    assert "돼지고기" in names
    assert "파슬리" not in names
    assert "소고기 다시다" not in names
    assert second.total_price < 70000


def test_narration_rejects_numbers_outside_the_template():
    from services.grocery_agent_service import narration_keeps_facts

    template = "12개, 66,990원, 남는 양 약 40%."
    assert narration_keeps_facts("12개에 66,990원이고 남는 양은 약 40%입니다.", template)
    assert not narration_keeps_facts("25개를 사용했으며 금액은 66,990원입니다.", template)
    plan = "수 순두부찌개 / 목 닭가슴살조림."
    assert narration_keeps_facts("수요일은 순두부찌개, 목요일은 닭가슴살조림입니다.", plan)
    assert not narration_keeps_facts("돼지갈비나 순살족발을 구워 먹어도 좋아요.", plan)


def test_lookup_reads_cart_fridge_and_recipes_without_replanning():
    profile, recipes, fridge = _world()
    cart = [{"recipeName": "김치찌개", "source": "grocery_agent"}]
    asked = plan_turn("장바구니에 뭐 있어?", None, profile, recipes, fridge, {}, None, cart)
    assert asked.policy_decision == "lookup_cart"
    assert "김치찌개" in asked.reply
    assert asked.meals == []
    fridge_answer = plan_turn("냉장고에 두부 있어?", None, profile, recipes, fridge, {}, {"phase": "planned", "meals": [{"day": "수"}]})
    assert fridge_answer.policy_decision == "lookup_fridge"
    assert "두부" in fridge_answer.reply
    held = plan_turn("장바구니에 뭐 담아둬어?", None, profile, recipes, fridge, {}, None, cart)
    assert held.policy_decision == "lookup_cart"
    assert "김치찌개" in held.reply
    commit = plan_turn("장바구니에 담아줘", None, profile, recipes, fridge, {}, {"phase": "basket", "meals": []})
    assert commit.policy_decision == "spend_confirmed" or commit.policy_decision == "spend_too_early"
    saved = plan_turn("저장한 레시피 보여줘", None, profile, recipes, fridge, {}, None)
    assert "순두부찌개" in saved.reply
    assert "김치찌개" in saved.reply
    detail = plan_turn("김치찌개 레시피 알려줘", None, profile, recipes, fridge, {}, None, cart)
    assert detail.policy_decision == "lookup_ingredients"
    assert "김치" in detail.reply
    assert "두부" in detail.reply
    assert detail.meals == []
    focused = dict(profile)
    focused["focus"] = "김치찌개"
    follow = plan_turn("알려줘 재료를", None, focused, recipes, fridge, {}, None, cart)
    assert follow.policy_decision == "lookup_ingredients"
    assert "알려줘" not in follow.reply
    assert "김치" in follow.reply
    goods = plan_turn(
        "상품 추천해줘",
        None,
        focused,
        recipes,
        fridge,
        {
            "대파": [
                {
                    "productName": "대파 1단",
                    "price": 1990,
                    "imageUrl": "https://example.com/pa.jpg",
                    "rating": 4.8,
                    "reviews": 120,
                    "link": "https://www.coupang.com/vp/products/1",
                }
            ]
        },
        None,
        cart,
    )
    assert goods.policy_decision == "products_recommended"
    assert goods.basket
    assert goods.basket[0]["image"].startswith("http")
    assert goods.basket[0]["rating"] == 4.8
    assert "별점" in goods.reply
    assert "원" in goods.reply


def test_include_filter_uses_only_matching_saved_recipes():
    profile, recipes, fridge = _world()
    result = plan_turn("닭으로 2끼만 해줘", None, profile, recipes, fridge, {}, None)
    assert result.policy_decision == "meal_plan_proposed"
    assert len(result.meals) == 1
    assert "닭" in result.meals[0]["recipe_name"]


def test_unknown_recipe_is_not_invented():
    profile, recipes, fridge = _world()
    result = plan_turn("파스타로 해줘", None, profile, recipes, fridge, {}, None)
    assert result.policy_decision == "recipe_not_saved"
    assert result.meals == []


def test_requests_read_the_store_they_name():
    profile, recipes, fridge = _world()
    cart = [{"recipeName": "김치찌개"}]
    run = {"phase": "planned", "meals": [{"day": "수", "recipe_id": "sundubu", "recipe_name": "순두부찌개"}]}
    cases = [
        ("냉장고에 뭐 있어?", "lookup_fridge", "두부"),
        ("두부 있어?", "lookup_fridge", "두부"),
        ("순두부 있어?", "lookup_fridge", "순두부는 냉장고에 없"),
        ("장바구니 보여줘", "lookup_cart", "김치찌개"),
        ("저장한 레시피 뭐가 있어?", "lookup_recipes", "순두부찌개"),
        ("김치찌개 재료 알려줘", "lookup_ingredients", "대파"),
        ("못 먹는 거 뭐야?", "lookup_profile", "갑각류"),
        ("예산 얼마야?", "lookup_budget", "70,000"),
        ("파스타 레시피 있어?", "recipe_not_saved", "파스타"),
        ("닭으로 2끼만 해줘", "meal_plan_proposed", "닭가슴살조림"),
        ("파이썬 숙제 해줘", "off_topic", "요리와 장보기"),
    ]
    for message, policy, snippet in cases:
        result = plan_turn(message, None, profile, recipes, fridge, {}, run, cart)
        assert result.policy_decision == policy, message
        assert snippet in result.reply, (message, result.reply)


def test_model_cannot_swap_a_named_store():
    from services.grocery_planner import TurnIntent, merge_intents

    local = TurnIntent("lookup", target="fridge")
    chosen = TurnIntent("lookup", target="cart")
    assert merge_intents(local, chosen).target == "fridge"
    named = TurnIntent("lookup", target="ingredients", include="돼지갈비")
    cart_guess = TurnIntent("lookup", target="cart")
    assert merge_intents(named, cart_guess).target == "ingredients"
    planned = TurnIntent("propose", include="돼지갈비")
    assert merge_intents(planned, cart_guess).kind == "propose"
    from services.grocery_planner import intent_from_payload

    intent = intent_from_payload({"kind": "lookup", "target": "fridge", "meal_count": 0})
    assert intent is not None
    assert intent.kind == "lookup"
    assert intent_from_payload({"kind": "fly"}) is None


def test_korean_narration_drops_reasoning():
    from services.grocery_agent_service import korean_narration

    raw = (
        'We need two Korean sentences. Let\'s craft: "평소 주 2-4회라서 저녁 3끼로 잡을게요. '
        '수 순두부, 목 닭가슴살, 금 김치찌개입니다." That is the answer.'
    )
    spoken = korean_narration(raw)
    assert "We need" not in spoken
    assert "순두부" in spoken
    assert "김치찌개" in spoken


def test_over_budget_blocks_cart_until_override():
    profile, recipes, fridge = _world()
    profile = dict(profile)
    profile["recentCartTotal"] = 1000
    first = plan_turn("이번 주에 요리하려고", None, profile, recipes, fridge, {}, None)
    second = plan_turn(
        "이대로 장보기",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": "planned", "meals": first.meals},
    )
    third = plan_turn(
        "담아줘",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": "basket", "meals": second.meals},
    )
    assert third.policy_decision == "budget_blocked"
    assert third.cart_items is None
    allowed = plan_turn(
        "예산 초과 허용",
        None,
        profile,
        recipes,
        fridge,
        {},
        {"phase": "basket", "meals": second.meals},
    )
    # 허용만으로는 담지 않는다. 다시 확인해야 한다.
    assert allowed.cart_items is None
    committed = plan_turn(
        "담아줘",
        "accept_cart",
        {**profile, "allowOverBudget": True},
        recipes,
        fridge,
        {},
        {"phase": "basket", "meals": second.meals},
    )
    assert committed.policy_decision == "spend_confirmed"
