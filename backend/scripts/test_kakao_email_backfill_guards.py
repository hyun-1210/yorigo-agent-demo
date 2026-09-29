"""auth.py 소셜 이메일 backfill 가드 단위 테스트."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from routers.auth import _is_persistable_email, _should_backfill_user_email  # noqa: E402


class PersistableEmailTests(unittest.TestCase):
    def test_valid_emails(self) -> None:
        self.assertTrue(_is_persistable_email("tiff1115any@naver.com"))
        self.assertTrue(_is_persistable_email("  user@gmail.com "))

    def test_invalid_emails(self) -> None:
        self.assertFalse(_is_persistable_email(""))
        self.assertFalse(_is_persistable_email("not-an-email"))
        self.assertFalse(_is_persistable_email("user@"))
        self.assertFalse(_is_persistable_email("@naver.com"))
        self.assertFalse(_is_persistable_email("user @naver.com"))

    def test_backfill_only_when_empty(self) -> None:
        self.assertTrue(_should_backfill_user_email(None, "a@b.com"))
        self.assertTrue(_should_backfill_user_email("", "a@b.com"))
        self.assertTrue(_should_backfill_user_email("   ", "a@b.com"))
        self.assertFalse(_should_backfill_user_email("old@x.com", "new@x.com"))
        self.assertFalse(_should_backfill_user_email(None, "bad"))


if __name__ == "__main__":
    unittest.main()
