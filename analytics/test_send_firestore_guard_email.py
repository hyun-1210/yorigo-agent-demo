#!/usr/bin/env python3
"""send_firestore_guard_email 가드 테스트 (네트워크 mock)."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import send_firestore_guard_email as mailer


class SendEmailTests(unittest.TestCase):
    def test_missing_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report_dir = Path(tmp)
            (report_dir / "email_subject.txt").write_text("subj\n", encoding="utf-8")
            (report_dir / "report.md").write_text("body\n", encoding="utf-8")
            with patch.dict(os.environ, {}, clear=True):
                code = mailer.main(["--report-dir", str(report_dir)])
            self.assertEqual(code, 2)

    def test_send_success_mocked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report_dir = Path(tmp)
            (report_dir / "email_subject.txt").write_text(
                "[Firestore OK] test\n", encoding="utf-8"
            )
            (report_dir / "report.md").write_text("# ok\n", encoding="utf-8")

            class _Resp:
                status = 200

                def read(self) -> bytes:
                    return b'{"id":"email_123"}'

                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    return False

            with patch.dict(
                os.environ,
                {
                    "RESEND_API_KEY": "re_test",
                    "ALERT_EMAIL_TO": "you@example.com",
                    "ALERT_EMAIL_FROM": "",
                },
                clear=False,
            ), patch(
                "urllib.request.urlopen", return_value=_Resp()
            ) as mocked:
                code = mailer.main(["--report-dir", str(report_dir)])
            self.assertEqual(code, 0)
            req = mocked.call_args[0][0]
            payload = json.loads(req.data.decode("utf-8"))
            self.assertEqual(payload["to"], ["you@example.com"])
            self.assertEqual(payload["subject"], "[Firestore OK] test")
            self.assertIn("alerts.yorigo.kr", payload["from"])


if __name__ == "__main__":
    unittest.main()
