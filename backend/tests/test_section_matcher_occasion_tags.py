import os
import sys
import unittest

sys.path.insert(
    0,
    os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "cms_dashboard")
    ),
)

from section_matcher import matches_rule  # noqa: E402


class SectionMatcherOccasionTagsTest(unittest.TestCase):
    def test_any_tags_match_occasion_tags(self):
        data = {
            "status": "completed",
            "isHidden": False,
            "title": "잔치국수",
            "tags": ["매콤한", "한그릇"],
            "occasionTags": ["혼밥", "저녁"],
        }
        rule = {"anyTags": ["혼밥용", "혼밥"]}
        self.assertTrue(matches_rule(data, rule))

    def test_any_tags_do_not_match_unrelated_taste_only(self):
        data = {
            "status": "completed",
            "isHidden": False,
            "title": "잔치국수",
            "tags": ["매콤한", "한그릇"],
            "occasionTags": ["손님상"],
        }
        rule = {"anyTags": ["혼밥용", "혼밥"]}
        self.assertFalse(matches_rule(data, rule))

    def test_baby_food_matches_iyong_chip(self):
        data = {
            "status": "completed",
            "isHidden": False,
            "title": "아기 주먹밥",
            "tags": ["아이용"],
            "occasionTags": ["도시락"],
        }
        rule = {"anyTags": ["이유식", "아이용"]}
        self.assertTrue(matches_rule(data, rule))


if __name__ == "__main__":
    unittest.main()
