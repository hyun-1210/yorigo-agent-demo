"""saveCount 시드 헬퍼 단위 테스트."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from utils.recipe_social_counts import (  # noqa: E402
    needs_seeded_save_count,
    parse_save_count,
    seed_save_count,
)


class TestSeedSaveCount(unittest.TestCase):
    def test_range_and_determinism(self) -> None:
        a = seed_save_count("abc123")
        b = seed_save_count("abc123")
        self.assertEqual(a, b)
        self.assertGreaterEqual(a, 1)
        self.assertLessEqual(a, 8)
        self.assertEqual(a, 2)

    def test_varies_by_id(self) -> None:
        values = {seed_save_count(f"recipe-{i}") for i in range(80)}
        self.assertGreaterEqual(len(values), 8)
        self.assertTrue(all(1 <= v <= 8 for v in values))

    def test_needs_seed(self) -> None:
        self.assertTrue(needs_seeded_save_count(None))
        self.assertTrue(needs_seeded_save_count(0))
        self.assertTrue(needs_seeded_save_count(-1))
        self.assertFalse(needs_seeded_save_count(1))
        self.assertFalse(needs_seeded_save_count(12))
        self.assertEqual(parse_save_count("7"), 7)


if __name__ == "__main__":
    unittest.main()
