"""Resend로 Railway Watch 일일 리포트를 발송한다.

환경변수:
  RESEND_API_KEY   (필수)
  ALERT_EMAIL_TO   (필수, 쉼표 구분 가능)
  ALERT_EMAIL_FROM (기본: Railway Watch <noreply@alerts.yorigo.kr>)
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import List


def recipients(raw: str) -> List[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


def send_resend(
    *,
    api_key: str,
    to_addrs: List[str],
    from_addr: str,
    subject: str,
    text_body: str,
) -> dict:
    """Resend API로 텍스트 메일을 보낸다."""
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
            "User-Agent": "yorigo-railway-watch/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
            return {"status": resp.status, "body": json.loads(body) if body else {}}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Resend HTTP {exc.code}: {detail}") from exc


def send_report_email(*, subject: str, body: str) -> dict:
    """환경변수에서 수신자/키를 읽어 리포트를 발송한다."""
    api_key = (os.getenv("RESEND_API_KEY") or "").strip()
    to_raw = (os.getenv("ALERT_EMAIL_TO") or "").strip()
    from_addr = (
        (os.getenv("ALERT_EMAIL_FROM") or "").strip()
        or "Railway Watch <noreply@alerts.yorigo.kr>"
    )
    if not api_key:
        raise RuntimeError("RESEND_API_KEY missing")
    if not to_raw:
        raise RuntimeError("ALERT_EMAIL_TO missing")
    # 예전에 .app으로 잘못 넣힌 경우 자동 교정 (실제 인증 도메인은 .kr)
    if "alerts.yorigo.app" in from_addr.lower():
        from_addr = from_addr.replace("alerts.yorigo.app", "alerts.yorigo.kr").replace(
            "alerts.yorigo.APP", "alerts.yorigo.kr"
        )
    try:
        return send_resend(
            api_key=api_key,
            to_addrs=recipients(to_raw),
            from_addr=from_addr,
            subject=subject,
            text_body=body,
        )
    except RuntimeError as exc:
        # 도메인 미인증/오타 시 onboarding으로 1회 폴백 (본인 계정 메일만 수신 가능)
        msg = str(exc)
        if "not verified" in msg.lower() or "domain" in msg.lower():
            fallback = "Railway Watch <onboarding@resend.dev>"
            note = (
                "\n\n---\n[발신 폴백] "
                f"{from_addr} 전송이 Resend에서 거절되어 "
                f"{fallback}로 재전송했습니다. 원인: {msg[:200]}\n"
            )
            return send_resend(
                api_key=api_key,
                to_addrs=recipients(to_raw),
                from_addr=fallback,
                subject=subject,
                text_body=body + note,
            )
        raise
