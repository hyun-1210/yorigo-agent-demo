#!/usr/bin/env python3
"""Firestore daily guard 리포트를 Resend로 발송한다.

환경변수:
  RESEND_API_KEY   (필수)
  ALERT_EMAIL_TO   (필수, 쉼표 구분 가능)
  ALERT_EMAIL_FROM (기본: Firestore Guard <onboarding@resend.dev>)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import List, Optional, Sequence


def _recipients(raw: str) -> List[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


def send_resend(
    *,
    api_key: str,
    to_addrs: List[str],
    from_addr: str,
    subject: str,
    text_body: str,
) -> dict:
    payload = {
        "from": from_addr,
        "to": to_addrs,
        "subject": subject,
        "text": text_body,
    }
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            # Cloudflare may block default Python-urllib User-Agent (1010).
            "User-Agent": "yorigo-firestore-guard/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
            return {"status": resp.status, "body": json.loads(body) if body else {}}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Resend HTTP {exc.code}: {detail}") from exc


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--from", dest="from_addr", default="")
    args = parser.parse_args(list(argv) if argv is not None else None)

    api_key = (os.getenv("RESEND_API_KEY") or "").strip()
    to_raw = (os.getenv("ALERT_EMAIL_TO") or "").strip()
    from_addr = (
        (args.from_addr or "").strip()
        or (os.getenv("ALERT_EMAIL_FROM") or "").strip()
        or "Firestore Guard <noreply@alerts.yorigo.kr>"
    )
    # 예전에 .app으로 잘못 넣힌 경우 자동 교정 (실제 인증 도메인은 .kr)
    if "alerts.yorigo.app" in from_addr.lower():
        from_addr = from_addr.replace("alerts.yorigo.app", "alerts.yorigo.kr")
    if not api_key:
        print("RESEND_API_KEY missing", file=sys.stderr)
        return 2
    if not to_raw:
        print("ALERT_EMAIL_TO missing", file=sys.stderr)
        return 2

    subject_path = args.report_dir / "email_subject.txt"
    md_path = args.report_dir / "report.md"
    if not subject_path.is_file() or not md_path.is_file():
        print(f"report files missing under {args.report_dir}", file=sys.stderr)
        return 2

    subject = subject_path.read_text(encoding="utf-8").strip()
    body = md_path.read_text(encoding="utf-8")
    result = send_resend(
        api_key=api_key,
        to_addrs=_recipients(to_raw),
        from_addr=from_addr,
        subject=subject,
        text_body=body,
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
