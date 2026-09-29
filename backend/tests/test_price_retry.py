"""단가 LLM 재시도 판정. 한 번 못 찾은 재료는 다시 호출하지 않는다."""

import unittest
from datetime import datetime, timedelta, timezone

from services.firebase_service import price_retry_block


class PriceRetryBlockTest(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 9, 27, 3, 0, tzinfo=timezone.utc)

    def test_new_name_is_tried_once(self) -> None:
        self.assertIsNone(price_retry_block(None, self.now))

    def test_model_miss_is_not_retried(self) -> None:
        entry = {"failCount": 1, "retryable": False, "lastAttemptAt": self.now}
        self.assertEqual(price_retry_block(entry, self.now), "given_up")

    def test_legacy_failure_without_retryable_is_not_retried(self) -> None:
        entry = {"failCount": 1, "lastAttemptAt": self.now - timedelta(days=3)}
        self.assertEqual(price_retry_block(entry, self.now), "given_up")

    def test_provider_outage_waits_one_day_then_allows_one_more(self) -> None:
        recent = {"failCount": 1, "retryable": True, "lastAttemptAt": self.now - timedelta(hours=2)}
        self.assertEqual(price_retry_block(recent, self.now), "cooldown")
        due = {"failCount": 1, "retryable": True, "lastAttemptAt": self.now - timedelta(hours=25)}
        self.assertIsNone(price_retry_block(due, self.now))

    def test_second_outage_stops(self) -> None:
        entry = {"failCount": 2, "retryable": True, "lastAttemptAt": self.now - timedelta(days=2)}
        self.assertEqual(price_retry_block(entry, self.now), "given_up")


if __name__ == "__main__":
    unittest.main()
