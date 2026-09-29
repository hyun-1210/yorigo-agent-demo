#!/usr/bin/env python3
"""firestore_daily_guard 순수 규칙 단위 테스트 (네트워크 없음)."""

from __future__ import annotations

import unittest
from datetime import datetime, timezone
from pathlib import Path

from firestore_daily_guard import (
    baseline_window,
    email_subject,
    evaluate_fingerprints,
    evaluate_from_monitoring_payload,
    evaluate_metric_spike,
    load_thresholds,
    overall_verdict,
    pick_complete_day,
)


class SpikeRulesTests(unittest.TestCase):
    def test_pick_complete_day_skips_today(self) -> None:
        daily = {"2026-07-28": 1.0, "2026-07-29": 2.0, "2026-07-30": 99.0}
        now = datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc)
        self.assertEqual(pick_complete_day(daily, now_utc=now), "2026-07-29")

    def test_baseline_window_uses_prior_seven(self) -> None:
        daily = {f"2026-07-{d:02d}": float(d) for d in range(20, 30)}
        vals = baseline_window(daily, "2026-07-29", days=7)
        self.assertEqual(len(vals), 7)
        self.assertEqual(vals[0], 22.0)
        self.assertEqual(vals[-1], 28.0)

    def test_ok_when_below_1_5x_median(self) -> None:
        # median of 10s = 10; yesterday 12 = 1.2x
        daily = {f"2026-07-{d:02d}": 10.0 for d in range(20, 28)}
        daily["2026-07-28"] = 12.0
        now = datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc)
        result = evaluate_metric_spike(
            daily, warning_ratio=1.5, critical_ratio=2.0, now_utc=now
        )
        self.assertEqual(result["verdict"], "OK")
        self.assertAlmostEqual(result["ratio_median"], 1.2)

    def test_warning_at_1_6x_median(self) -> None:
        daily = {f"2026-07-{d:02d}": 100.0 for d in range(20, 28)}
        daily["2026-07-28"] = 160.0
        now = datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc)
        result = evaluate_metric_spike(
            daily, warning_ratio=1.5, critical_ratio=2.0, now_utc=now
        )
        self.assertEqual(result["verdict"], "WARNING")

    def test_critical_at_2_1x_median(self) -> None:
        daily = {f"2026-07-{d:02d}": 100.0 for d in range(20, 28)}
        daily["2026-07-28"] = 210.0
        now = datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc)
        result = evaluate_metric_spike(
            daily, warning_ratio=1.5, critical_ratio=2.0, now_utc=now
        )
        self.assertEqual(result["verdict"], "CRITICAL")

    def test_insufficient_baseline_is_ok_not_alarm(self) -> None:
        daily = {"2026-07-28": 1000.0, "2026-07-27": 10.0}
        now = datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc)
        result = evaluate_metric_spike(
            daily, warning_ratio=1.5, critical_ratio=2.0, now_utc=now
        )
        self.assertEqual(result["status"], "insufficient_baseline")
        self.assertEqual(result["verdict"], "OK")


class FingerprintTests(unittest.TestCase):
    def test_coupang_select_name(self) -> None:
        findings = evaluate_fingerprints(
            [
                {
                    "text": "COLLECTION /coupang_products SELECT __name__",
                    "exec_count": 2,
                    "total_read_operations": 8000,
                    "avg_documents_scanned": 4000,
                }
            ],
            underage_exec_warning=3,
            coupang_full_scan_min_avg_docs=1000,
        )
        self.assertEqual(findings[0]["id"], "GHOST_COUPANG_SELECT_NAME")

    def test_underage_requires_threshold(self) -> None:
        low = evaluate_fingerprints(
            [
                {
                    "text": "COLLECTION /users LIMIT 1000",
                    "exec_count": 2,
                    "total_read_operations": 2000,
                }
            ],
            underage_exec_warning=3,
            coupang_full_scan_min_avg_docs=1000,
        )
        self.assertEqual(low, [])
        high = evaluate_fingerprints(
            [
                {
                    "text": "COLLECTION /users LIMIT 1000",
                    "exec_count": 3,
                    "total_read_operations": 3000,
                }
            ],
            underage_exec_warning=3,
            coupang_full_scan_min_avg_docs=1000,
        )
        self.assertEqual(high[0]["id"], "UNDERAGE_OVERFREQ")

    def test_normal_queries_ignored(self) -> None:
        findings = evaluate_fingerprints(
            [
                {
                    "text": "COLLECTION /home_section_overrides",
                    "exec_count": 1000,
                    "total_read_operations": 1000,
                    "avg_documents_scanned": 1,
                },
                {
                    "text": "COLLECTION /timestamp_jobs WHERE status = ? LIMIT 10",
                    "exec_count": 8000,
                    "total_read_operations": 1000,
                },
            ],
            underage_exec_warning=3,
            coupang_full_scan_min_avg_docs=1000,
        )
        self.assertEqual(findings, [])


class ReportIntegrationTests(unittest.TestCase):
    def test_fingerprint_alone_makes_warning(self) -> None:
        self.assertEqual(
            overall_verdict(
                {"document_reads": {"verdict": "OK"}},
                [{"id": "GHOST_COUPANG_SELECT_NAME"}],
            ),
            "WARNING",
        )

    def test_offline_payload_ok_path(self) -> None:
        thresholds = load_thresholds(
            Path(__file__).with_name("firestore_guard_thresholds.json")
        )
        # Build synthetic monitoring with flat reads
        daily = [{"date": f"2026-07-{d:02d}", "value": 100000.0} for d in range(20, 29)]
        daily.append({"date": "2026-07-29", "value": 110000.0})
        monitoring = {
            "project": "yorigo-f7408",
            "series": {
                "firestore.googleapis.com/document/read_count": {"daily": daily},
                "firestore.googleapis.com/document/write_count": {"daily": daily},
                "firestore.googleapis.com/api/request_count": {"daily": daily},
            },
        }
        report = evaluate_from_monitoring_payload(
            monitoring,
            [{"text": "COLLECTION /home_section_overrides", "exec_count": 1, "total_read_operations": 1}],
            thresholds,
            now_utc=datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(report["verdict"], "OK")
        self.assertFalse(report["auto_remediation"])
        subject = email_subject(report, day="2026-07-29")
        self.assertIn("[Firestore OK]", subject)
        self.assertIn("max", subject)
        self.assertIn("median", subject)

    def test_offline_payload_critical_spike(self) -> None:
        thresholds = load_thresholds(
            Path(__file__).with_name("firestore_guard_thresholds.json")
        )
        daily = [{"date": f"2026-07-{d:02d}", "value": 100000.0} for d in range(20, 29)]
        daily.append({"date": "2026-07-29", "value": 250000.0})
        monitoring = {
            "project": "yorigo-f7408",
            "series": {
                "firestore.googleapis.com/document/read_count": {"daily": daily},
                "firestore.googleapis.com/document/write_count": {
                    "daily": [{"date": r["date"], "value": 1000.0} for r in daily]
                },
                "firestore.googleapis.com/api/request_count": {
                    "daily": [{"date": r["date"], "value": 1000.0} for r in daily]
                },
            },
        }
        report = evaluate_from_monitoring_payload(
            monitoring,
            [],
            thresholds,
            now_utc=datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(report["verdict"], "CRITICAL")
        self.assertGreater(report["max_ratio_median"], 2.0)


if __name__ == "__main__":
    unittest.main()
