#!/usr/bin/env python3
"""Firestore에 기록된 signal export 실행 결과를 읽어 Resend로 일일 다이제스트를 보낸다.

Railway 스케줄러가 ``system_schedules/signal_export.lastRun`` 에 요약을 남기면,
이 스크립트(GitHub Actions)가 기존 RESEND_* / ALERT_EMAIL_* 시크릿으로 메일을 보낸다.

사용:
  python signal_export_digest.py --sa ../backend/firebase-service-account.json
  python signal_export_digest.py --sa ... --dry-run
  python signal_export_digest.py --sa ... --force   # 이미 통지한 runId도 재발송
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, List, Optional, Sequence

from google.cloud import firestore
from google.oauth2 import service_account

SCHEDULE_COLLECTION = "system_schedules"
SCHEDULE_DOC = "signal_export"


def _recipients(raw: str) -> List[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


def send_resend(
    *,
    api_key: str,
    to_addrs: List[str],
    from_addr: str,
    subject: str,
    text_body: str,
) -> dict[str, Any]:
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
            "User-Agent": "yorigo-signal-export-digest/1.0",
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


def load_schedule_doc(sa_path: Path) -> dict[str, Any]:
    creds = service_account.Credentials.from_service_account_file(str(sa_path))
    project_id = json.loads(sa_path.read_text(encoding="utf-8")).get("project_id")
    client = firestore.Client(project=project_id, credentials=creds)
    snap = client.collection(SCHEDULE_COLLECTION).document(SCHEDULE_DOC).get()
    if not snap.exists:
        return {}
    return snap.to_dict() or {}


def mark_notified(sa_path: Path, run_id: str) -> None:
    creds = service_account.Credentials.from_service_account_file(str(sa_path))
    project_id = json.loads(sa_path.read_text(encoding="utf-8")).get("project_id")
    client = firestore.Client(project=project_id, credentials=creds)
    client.collection(SCHEDULE_COLLECTION).document(SCHEDULE_DOC).set(
        {
            "lastNotifiedRunId": run_id,
            "lastNotifiedAt": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )


def render_report(last_run: dict[str, Any], *, schedule: dict[str, Any]) -> tuple[str, str]:
    status = str(last_run.get("status") or "unknown")
    ok = bool(last_run.get("ok"))
    run_id = str(last_run.get("runId") or "?")
    tag = "OK" if ok else "FAIL"
    subject = f"[SignalExport {tag}] {status} run={run_id[:8]}"

    lines = [
        "# Signal Export Digest",
        "",
        f"- status: **{status}**",
        f"- ok: {ok}",
        f"- runId: `{run_id}`",
        f"- startedAt: {last_run.get('startedAt')}",
        f"- finishedAt: {last_run.get('finishedAt')}",
        f"- bucket: {last_run.get('bucket')}",
        f"- lookbackDays: {last_run.get('lookbackDays')}",
        f"- totalRawFiles: {last_run.get('totalRawFiles')}",
        f"- totalEvents: {last_run.get('totalEvents')}",
        f"- totalFailedDownloads: {last_run.get('totalFailedDownloads')}",
        f"- uploadedDates: {last_run.get('uploadedDates')}",
        f"- skippedDates: {last_run.get('skippedDates')}",
        f"- abortedDates: {last_run.get('abortedDates')}",
        f"- schedule.status: {schedule.get('status')}",
        f"- schedule.lastError: {schedule.get('lastError')}",
        "",
    ]
    if last_run.get("error"):
        lines.extend(["## Error", "", str(last_run.get("error")), ""])

    dates = last_run.get("dates") or []
    if dates:
        lines.append("## Per-date")
        lines.append("")
        for row in dates:
            lines.append(
                "- `{date}` raw={raw} events={events} uploaded={uploaded} "
                "skipped={skipped} aborted={aborted} failed_downloads={fd}".format(
                    date=row.get("date"),
                    raw=row.get("raw_file_count"),
                    events=row.get("event_count"),
                    uploaded=row.get("uploaded"),
                    skipped=row.get("skipped"),
                    aborted=row.get("aborted"),
                    fd=row.get("failed_downloads"),
                )
            )
            failed_names = row.get("failed_blob_names") or []
            if failed_names:
                lines.append(f"  - failed blobs (sample): {failed_names[:5]}")
        lines.append("")

    lines.extend(
        [
            "## Notes",
            "",
            "- aborted 날짜는 다운로드 일부 실패로 processed 업로드를 건너뛴 경우입니다.",
            "- 기존 processed 파일은 유지되며, 다음 스케줄 lookback에서 재시도됩니다.",
            f"- generatedAt(UTC): {datetime.now(timezone.utc).isoformat()}",
            "",
        ]
    )
    return subject, "\n".join(lines)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sa", type=Path, required=True, help="Firebase SA JSON path")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--force",
        action="store_true",
        help="이미 통지한 runId여도 다시 메일 발송",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "reports" / "signal_export",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if not args.sa.is_file():
        print(f"SA file missing: {args.sa}", file=sys.stderr)
        return 2

    schedule = load_schedule_doc(args.sa)
    last_run = schedule.get("lastRun")
    if not isinstance(last_run, dict) or not last_run:
        print("No lastRun on system_schedules/signal_export yet", file=sys.stderr)
        return 3

    run_id = str(last_run.get("runId") or "")
    last_notified = str(schedule.get("lastNotifiedRunId") or "")
    if run_id and run_id == last_notified and not args.force:
        print(f"Already notified runId={run_id}; skip (use --force to resend)")
        return 0

    subject, body = render_report(last_run, schedule=schedule)
    out_dir = args.out_dir / (run_id or "unknown")
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "email_subject.txt").write_text(subject + "\n", encoding="utf-8")
    (out_dir / "report.md").write_text(body + "\n", encoding="utf-8")
    (out_dir / "last_run.json").write_text(
        json.dumps(last_run, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8",
    )
    print(subject)
    print(f"report_dir={out_dir}")

    if args.dry_run:
        print("--- dry-run body preview ---")
        print(body[:4000])
        return 0 if last_run.get("ok") else 20

    api_key = (os.getenv("RESEND_API_KEY") or "").strip()
    to_raw = (os.getenv("ALERT_EMAIL_TO") or "").strip()
    from_addr = (
        (os.getenv("ALERT_EMAIL_FROM") or "").strip()
        or "Signal Export <noreply@alerts.yorigo.kr>"
    )
    if "alerts.yorigo.app" in from_addr.lower():
        from_addr = from_addr.replace("alerts.yorigo.app", "alerts.yorigo.kr")
    if not api_key:
        print("RESEND_API_KEY missing", file=sys.stderr)
        return 2
    if not to_raw:
        print("ALERT_EMAIL_TO missing", file=sys.stderr)
        return 2

    result = send_resend(
        api_key=api_key,
        to_addrs=_recipients(to_raw),
        from_addr=from_addr,
        subject=subject,
        text_body=body,
    )
    print(json.dumps({"email": result}, ensure_ascii=False))
    if run_id:
        mark_notified(args.sa, run_id)
    return 0 if last_run.get("ok") else 20


if __name__ == "__main__":
    raise SystemExit(main())
