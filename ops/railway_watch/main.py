#!/usr/bin/env python3
"""Railway Watch 오케스트레이션: 수집 → 감지 → Resend 이메일 (수정/PR 없음).

사용:
  python -m ops.railway_watch.main
  python -m ops.railway_watch.main --dry-run
  python -m ops.railway_watch.main --since 12h
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional, Sequence

# 레포 루트를 path에 넣어 `ops.railway_watch` import 가능하게 함
REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from ops.railway_watch.collect import collect_all  # noqa: E402
from ops.railway_watch.detectors import detect, overall_severity, render_report  # noqa: E402
from ops.railway_watch.notify import send_report_email  # noqa: E402


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Railway daily watch (report-only)")
    parser.add_argument("--since", default="24h", help="로그 수집 기간 (기본 24h)")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="이메일 발송 없이 리포트만 stdout/파일로 출력",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=REPO_ROOT / "ops" / "railway_watch" / "reports",
        help="리포트 저장 디렉터리",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    snapshot = collect_all(since=args.since)
    findings = detect(snapshot)
    subject, body = render_report(snapshot, findings)
    sev = overall_severity(findings)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = (snapshot.get("collected_at") or "unknown").replace(":", "").replace("+", "_")
    report_dir = args.out_dir / stamp
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / "snapshot.json").write_text(
        json.dumps(
            {k: v for k, v in snapshot.items() if k != "logs"}
            | {"logs_tail": list(snapshot.get("logs") or [])[-80:]},
            ensure_ascii=False,
            indent=2,
            default=str,
        ),
        encoding="utf-8",
    )
    (report_dir / "findings.json").write_text(
        json.dumps(findings, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (report_dir / "email_subject.txt").write_text(subject + "\n", encoding="utf-8")
    (report_dir / "report.md").write_text(body + "\n", encoding="utf-8")

    print(subject)
    print(f"severity={sev} findings={len(findings)} report_dir={report_dir}")

    if args.dry_run:
        print("--- dry-run body preview ---")
        print(body[:4000])
        return 0 if sev != "critical" else 20

    result = send_report_email(subject=subject, body=body)
    print(json.dumps({"email": result}, ensure_ascii=False))
    return 0 if sev != "critical" else 20


if __name__ == "__main__":
    raise SystemExit(main())
