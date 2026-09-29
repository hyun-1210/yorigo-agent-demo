"""Mixpanel 콘텐츠 소스 키 헬퍼."""

from __future__ import annotations

import unittest
from pathlib import Path

MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "utils" / "mixpanel_content_platform.py"
)
_ns: dict = {"__name__": "mixpanel_content_platform"}
exec(MODULE_PATH.read_text(encoding="utf-8"), _ns)
source_platform_props = _ns["source_platform_props"]


class TestSourcePlatformProps(unittest.TestCase):
    def test_instagram(self) -> None:
        self.assertEqual(
            source_platform_props("Instagram"),
            {"platform": "instagram", "source_platform": "instagram"},
        )

    def test_empty(self) -> None:
        self.assertEqual(source_platform_props(""), {})
        self.assertEqual(source_platform_props(None), {})


if __name__ == "__main__":
    unittest.main()
