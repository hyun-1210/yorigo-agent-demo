"""카드 칩·한줄소개·상황 태그 가드 단위 테스트."""

from __future__ import annotations

import os
import sys
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import types

if "services" not in sys.modules:
    pkg = types.ModuleType("services")
    pkg.__path__ = [str(BACKEND_DIR / "services")]
    pkg.__file__ = str(BACKEND_DIR / "services" / "__init__.py")
    sys.modules["services"] = pkg

from services.recipe_character import RecipeCharacterMixin, salvage_character_payload  # noqa: E402


class _FakeLLM:
    def __init__(self, chips: Dict[str, Any] | None = None, line: Dict[str, Any] | None = None, boom: str = "") -> None:
        self.chips = chips or {}
        self.line = line or {}
        self.boom = boom

    def select_recipe_character(self, **kwargs: Any) -> Dict[str, Any]:
        if self.boom in {"both", "chips"}:
            raise RuntimeError("chip llm down")
        return dict(self.chips)

    def write_recipe_tagline(self, **kwargs: Any) -> Dict[str, Any]:
        if self.boom in {"both", "line"}:
            raise RuntimeError("tagline llm down")
        return dict(self.line)


class _Harness(RecipeCharacterMixin):
    def __init__(self, llm: Any = None) -> None:
        self.llm_service = llm

    def _load_chef_tags(self) -> List[str]:
        return ["백종원", "이연복"]

    def _detect_chef_tag(self, *args: Any, **kwargs: Any) -> str | None:
        return None

    def _save_chef_tags(self, chefs: List[str]) -> None:
        return None

    def _verify_chef_with_llm(self, candidate: str) -> bool:
        return False


class RecipeCharacterTests(unittest.TestCase):
    def test_yasik_chip_moves_to_occasion(self) -> None:
        h = _Harness()
        usage: List[str] = []
        tags = h._normalize_and_limit_tags(
            tags_raw=["야식각", "매콤한"],
            title="야식 라면",
            description="밤에 먹기 좋은 매콤한 라면",
            transcript="매콤하게 끓여",
            usage_out=usage,
        )
        self.assertNotIn("야식각", tags)
        self.assertIn("야식", usage)
        self.assertIn("매콤한", tags)

    def test_clean_tagline_drops_channel(self) -> None:
        h = _Harness()
        line = h._clean_tagline(
            "엔지쿡이 알려주는 참치 김치찌개",
            uploader="엔지쿡",
            channel="엔지쿡",
            products=[],
            title="김치찌개",
        )
        self.assertNotIn("엔지쿡", line)

    def test_clean_tagline_drops_empty_hype(self) -> None:
        h = _Harness()
        line = h._clean_tagline(
            "감칠맛이 특별한 김치찌개",
            uploader="",
            channel="",
            products=[],
            title="김치찌개",
        )
        self.assertNotIn("감칠맛", line)
        self.assertNotIn("특별한", line)

    def test_source_fields_omit_empty_products(self) -> None:
        h = _Harness()
        fields = h._character_source_fields(
            {
                "tags": ["원팬"],
                "nutrition_rating": "A",
                "tagline": "원팬으로 끓인 김치찌개",
                "mentioned_products": [],
                "occasion_tags": ["저녁"],
            }
        )
        self.assertNotIn("mentionedProducts", fields)
        self.assertEqual(fields["occasionTags"], ["저녁"])
        self.assertEqual(fields["tagline"], "원팬으로 끓인 김치찌개")

    def test_enrich_uses_llm_chips_and_tagline(self) -> None:
        llm = _FakeLLM(
            chips={
                "tags": ["매콤한", "한그릇"],
                "occasion_tags": ["혼밥", "저녁"],
                "nutrition_rating": "B",
                "tag_evidence": [{"tag": "매콤한", "quote": "매콤한 라면"}],
            },
            line={"tagline": "고추장으로 매콤하게 끓인 라면", "mentioned_products": []},
        )
        h = _Harness(llm)
        char = h._enrich_recipe_character(
            recipe={"name": "라면", "ingredients": [{"item": "고추장"}], "steps": [{"instruction": "끓인다"}]},
            title="매콤 라면",
            description="매콤한 라면 야식",
            transcript="매콤하게 끓여 한그릇",
            tags_raw=["야식각"],
        )
        self.assertEqual(char["tagline"], "고추장으로 매콤하게 끓인 라면")
        self.assertIn("매콤한", char["tags"])
        self.assertNotIn("야식각", char["tags"])
        self.assertTrue(set(char["occasion_tags"]) & {"혼밥", "저녁", "야식"})

    def test_enrich_survives_llm_failure(self) -> None:
        h = _Harness(_FakeLLM(boom="both"))
        char = h._enrich_recipe_character(
            recipe={"name": "김치찌개", "ingredients": [{"item": "김치"}], "steps": []},
            title="김치찌개",
            description="얼큰한 김치찌개",
            transcript="얼큰하게 끓여",
            tags_raw=["얼큰한"],
        )
        self.assertEqual(char["tagline"], "")
        self.assertIn("얼큰한", char["tags"])

    def test_enrich_disabled_skips_llm(self) -> None:
        prev = os.environ.get("TAG_CHARACTER_ENRICH")
        os.environ["TAG_CHARACTER_ENRICH"] = "0"
        try:
            llm = _FakeLLM(
                line={"tagline": "이 줄은 나오면 안 됨"},
                chips={"tags": ["원팬"]},
            )
            h = _Harness(llm)
            char = h._enrich_recipe_character(
                recipe={"name": "계란볶음밥"},
                title="계란볶음밥",
                description="",
                transcript="",
                tags_raw=["한그릇"],
            )
            self.assertEqual(char["tagline"], "")
            self.assertEqual(char["llm_calls"], 0)
        finally:
            if prev is None:
                os.environ.pop("TAG_CHARACTER_ENRICH", None)
            else:
                os.environ["TAG_CHARACTER_ENRICH"] = prev

    def test_baby_chip_stays_on_card(self) -> None:
        h = _Harness()
        tags = h._normalize_and_limit_tags(
            tags_raw=["이유식", "한그릇"],
            title="아기 주먹밥",
            description="유아식 주먹밥",
            transcript="",
        )
        self.assertIn("아이용", tags)
        self.assertNotIn("이유식", tags)
        filtered = h._filter_tags_by_evidence(
            tags,
            title="아기 주먹밥",
            description="유아식 주먹밥",
            transcript="",
            recipe={"name": "주먹밥", "ingredients": [{"item": "밥"}]},
        )
        self.assertIn("아이용", filtered)

    def test_enrich_timeout_fail_open(self) -> None:
        class _SlowLLM:
            def select_recipe_character(self, **kwargs: Any) -> Dict[str, Any]:
                time.sleep(0.4)
                return {"tags": ["원팬"]}

            def write_recipe_tagline(self, **kwargs: Any) -> Dict[str, Any]:
                time.sleep(0.4)
                return {"tagline": "나오면 안 됨"}

        prev = os.environ.get("TAG_CHARACTER_TIMEOUT_SECONDS")
        os.environ["TAG_CHARACTER_TIMEOUT_SECONDS"] = "0.05"
        try:
            h = _Harness(_SlowLLM())
            t0 = time.perf_counter()
            char = h._enrich_recipe_character(
                recipe={"name": "김치찌개", "ingredients": [{"item": "김치"}]},
                title="김치찌개",
                description="얼큰한 김치찌개",
                transcript="얼큰하게 끓여",
                tags_raw=["얼큰한"],
            )
            elapsed = time.perf_counter() - t0
            self.assertEqual(char["tagline"], "")
            self.assertIn("얼큰한", char["tags"])
            self.assertLess(elapsed, 0.25)
        finally:
            if prev is None:
                os.environ.pop("TAG_CHARACTER_TIMEOUT_SECONDS", None)
            else:
                os.environ["TAG_CHARACTER_TIMEOUT_SECONDS"] = prev

    def test_enrich_skips_llm_on_empty_shell(self) -> None:
        class _CountingLLM:
            def __init__(self) -> None:
                self.n = 0

            def select_recipe_character(self, **kwargs: Any) -> Dict[str, Any]:
                self.n += 1
                return {"tags": ["원팬"]}

            def write_recipe_tagline(self, **kwargs: Any) -> Dict[str, Any]:
                self.n += 1
                return {"tagline": "나오면 안 됨"}

        llm = _CountingLLM()
        h = _Harness(llm)
        char = h._enrich_recipe_character(
            recipe={"ingredients": [], "steps": []},
            title="분석 중..",
            description="",
            transcript="",
            tags_raw=[],
        )
        self.assertEqual(llm.n, 0)
        self.assertEqual(char["llm_calls"], 0)
        self.assertEqual(char["tagline"], "")

    def test_enrich_counts_attempted_llm_calls(self) -> None:
        h = _Harness(_FakeLLM(chips={"tags": ["한그릇"]}, line={"tagline": "한그릇 계란볶음밥"}))
        char = h._enrich_recipe_character(
            recipe={"name": "계란볶음밥", "ingredients": [{"item": "계란"}]},
            title="계란볶음밥",
            description="원팬 볶음밥",
            transcript="",
            tags_raw=["한그릇"],
        )
        self.assertEqual(char["llm_calls"], 2)


class SalvageCharacterPayloadTests(unittest.TestCase):
    def test_salvage_tags_and_tagline(self) -> None:
        raw = '{"tags": ["매콤한", "한그릇"], "occasion_tags": ["혼밥"], "tagline": "고추장으로 끓인 라면"'
        out = salvage_character_payload(raw)
        self.assertEqual(out["tags"][:2], ["매콤한", "한그릇"])
        self.assertEqual(out["occasion_tags"], ["혼밥"])
        self.assertEqual(out["tagline"], "고추장으로 끓인 라면")


if __name__ == "__main__":
    unittest.main()
