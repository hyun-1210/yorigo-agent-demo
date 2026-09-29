"""ProductSearchRequest.record_cart_hit 기본값과 미리보기 비활성."""

from __future__ import annotations

import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from models import ProductSearchRequest  # noqa: E402


def test_record_cart_hit_defaults_true():
    req = ProductSearchRequest(ingredient_name="대파")
    assert req.record_cart_hit is True


def test_record_cart_hit_can_be_disabled_for_preview():
    req = ProductSearchRequest(ingredient_name="대파", record_cart_hit=False)
    assert req.record_cart_hit is False


def test_record_cart_hit_parses_from_json_false():
    req = ProductSearchRequest.model_validate(
        {
            "ingredient_name": "양파",
            "marketplace": "coupang",
            "record_cart_hit": False,
        }
    )
    assert req.record_cart_hit is False
    assert req.marketplace == "coupang"


def test_include_see_more_defaults_true():
    req = ProductSearchRequest(ingredient_name="대파")
    assert req.include_see_more is True


def test_include_see_more_can_be_disabled_for_preview():
    req = ProductSearchRequest(ingredient_name="대파", include_see_more=False)
    assert req.include_see_more is False


def test_product_service_gates_cart_hit_on_request_flag():
    source = (BACKEND_DIR / "services" / "product_service.py").read_text(
        encoding="utf-8"
    )
    assert 'getattr(req, "record_cart_hit", True)' in source
    assert "_should_record_cart_hit" in source
    assert 'getattr(req, "include_see_more", True)' in source
    assert "_recommendation_lists" in source
    assert "recommendation_payload_lists" in source
    assert "_cached_partner_links" in source


def test_recommendation_lists_preview_enriches_best_match_only():
    from models import recommendation_payload_lists

    products = ["a", "b"]
    see_more, enrich = recommendation_payload_lists(
        False, products, products[0]
    )
    assert see_more == []
    assert enrich == ["a"]

    see_more, enrich = recommendation_payload_lists(True, products, products[0])
    assert see_more == ["a", "b"]
    assert enrich == ["a", "a", "b"]

    see_more, enrich = recommendation_payload_lists(
        True, products, products[0], see_more_cap=1
    )
    assert see_more == ["a"]
    assert enrich == ["a", "a"]


if __name__ == "__main__":
    test_record_cart_hit_defaults_true()
    test_record_cart_hit_can_be_disabled_for_preview()
    test_record_cart_hit_parses_from_json_false()
    test_include_see_more_defaults_true()
    test_include_see_more_can_be_disabled_for_preview()
    test_product_service_gates_cart_hit_on_request_flag()
    test_recommendation_lists_preview_enriches_best_match_only()
    print("ok")
