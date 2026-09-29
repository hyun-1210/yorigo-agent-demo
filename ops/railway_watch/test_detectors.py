"""railway_watch detectors 단위 테스트."""

from __future__ import annotations

import unittest

from ops.railway_watch.detectors import detect, overall_severity, render_report


class DetectorTests(unittest.TestCase):
    def test_healthy_snapshot(self) -> None:
        snapshot = {
            "collected_at": "2026-07-30T12:00:00+00:00",
            "project": "remarkable-energy",
            "environment": "production",
            "service": "yorigo",
            "since": "24h",
            "errors": [],
            "deployments": [
                {
                    "status": "SUCCESS",
                    "commitHash": "abc123",
                    "commitMessage": "ok",
                    "createdAt": "2026-07-30T11:00:00Z",
                }
            ],
            "health": {"ok": True, "status": 200},
            "queue": {
                "ok": True,
                "counts": {"pending": 0, "processing": 0, "done": 10, "failed": 1},
                "youtube_cdn": {
                    "sampled_youtube": 5,
                    "sampled_youtube_with_cdn": 1,
                    "with_cdn": 0,
                    "without_cdn": 0,
                    "recent_sample": [],
                },
            },
            "http": {"ok": True, "status_counts": {"200": 100}, "total": 100, "sample_5xx": []},
            "logs": [
                "[timestamp_worker] yt_cdn_reuse=true url=https://www.youtube.com/watch?v=x",
                "[timestamp_queue] claim OK — youtube:x (attempt 1)",
            ],
        }
        findings = detect(snapshot)
        sev = overall_severity(findings)
        self.assertEqual(sev, "ok")
        subject, body = render_report(snapshot, findings)
        self.assertIn("[정상]", subject)
        self.assertIn("CDN", body)

    def test_queue_stall_critical(self) -> None:
        snapshot = {
            "collected_at": "2026-07-30T12:00:00+00:00",
            "project": "p",
            "environment": "e",
            "service": "s",
            "since": "24h",
            "errors": [],
            "deployments": [{"status": "SUCCESS", "commitHash": "x", "commitMessage": "m"}],
            "health": {"ok": True, "status": 200},
            "queue": {
                "ok": True,
                "counts": {"pending": 5, "processing": 0},
                "youtube_cdn": {},
            },
            "http": {"ok": True, "status_counts": {"200": 10}, "total": 10, "sample_5xx": []},
            "logs": ["no claims here"],
        }
        findings = detect(snapshot)
        self.assertEqual(overall_severity(findings), "critical")
        self.assertTrue(any(f["rule_id"] == "timestamp_queue_stalled" for f in findings))


if __name__ == "__main__":
    unittest.main()
