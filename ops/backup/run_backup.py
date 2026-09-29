#!/usr/bin/env python3
"""yorigo-f7408 데이터를 백업 프로젝트 버킷으로 복사한다.

포함:
  - Firestore 전체(유저 문서·서브컬렉션 포함)
  - Auth 계정
  - Firebase Storage 전체(프로필/이미지 + signals/raw·processed 행동 로그)
  - Mixpanel 이벤트·People 프로필

첫 실행은 Mixpanel 전체 기간, 이후는 state.json 이후 증분.
Storage는 매회 rsync(없는/변경된 객체만). Firestore·Auth는 날짜 폴더에 전체 스냅샷.

  python ops/backup/run_backup.py --mode full
  python ops/backup/run_backup.py --mode monthly
"""

from __future__ import annotations

import argparse
import base64
import gzip
import io
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

from google.cloud import storage
from google.oauth2 import service_account

SOURCE_PROJECT = (os.getenv("SOURCE_PROJECT_ID") or "yorigo-f7408").strip()
BACKUP_PROJECT = (os.getenv("BACKUP_PROJECT_ID") or "yorigo-offsite-backup").strip()
BACKUP_BUCKET = (os.getenv("BACKUP_BUCKET") or "yorigo-offsite-backup-data").strip()
SOURCE_BUCKET = (
    os.getenv("SOURCE_STORAGE_BUCKET") or f"{SOURCE_PROJECT}.firebasestorage.app"
).strip()
MIXPANEL_START = (os.getenv("MIXPANEL_EXPORT_START") or "2025-10-01").strip()
STATE_BLOB = "meta/state.json"
SA_PATH_DEFAULT = (
    Path(__file__).resolve().parents[2] / "backend" / "firebase-service-account.json"
)


def _utc_today() -> date:
    return datetime.now(timezone.utc).date()


def _run_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")


def _load_sa_info() -> Dict[str, Any]:
    raw = (os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON") or "").strip()
    if raw.startswith("{"):
        return json.loads(raw)
    path = Path(os.getenv("GOOGLE_APPLICATION_CREDENTIALS") or SA_PATH_DEFAULT)
    if not path.is_file():
        raise SystemExit(f"서비스 계정 JSON 없음: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _credentials() -> service_account.Credentials:
    return service_account.Credentials.from_service_account_info(
        _load_sa_info(),
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )


def _storage_client(creds: service_account.Credentials) -> storage.Client:
    return storage.Client(project=BACKUP_PROJECT, credentials=creds)


def _init_firebase(sa_info: Dict[str, Any]) -> None:
    import firebase_admin
    from firebase_admin import credentials

    if firebase_admin._apps:
        return
    firebase_admin.initialize_app(
        credentials.Certificate(sa_info),
        {"storageBucket": SOURCE_BUCKET, "projectId": SOURCE_PROJECT},
    )


def _gzip_bytes(data: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


def _upload_bytes(bucket: storage.Bucket, name: str, data: bytes, ctype: str) -> int:
    blob = bucket.blob(name)
    blob.upload_from_string(data, content_type=ctype)
    return len(data)


def _load_state(bucket: storage.Bucket) -> Dict[str, Any]:
    blob = bucket.blob(STATE_BLOB)
    if not blob.exists():
        return {}
    return json.loads(blob.download_as_text(encoding="utf-8"))


def _save_state(bucket: storage.Bucket, state: Dict[str, Any]) -> None:
    bucket.blob(STATE_BLOB).upload_from_string(
        json.dumps(state, ensure_ascii=False, indent=2),
        content_type="application/json",
    )


def backup_auth(bucket: storage.Bucket, stamp: str) -> Dict[str, Any]:
    """Auth 계정 전체를 JSONL gzip으로 저장한다."""
    from firebase_admin import auth

    rows: List[str] = []
    for user in auth.list_users().iterate_all():
        rows.append(
            json.dumps(
                {
                    "uid": user.uid,
                    "email": user.email,
                    "email_verified": user.email_verified,
                    "disabled": user.disabled,
                    "display_name": user.display_name,
                    "photo_url": user.photo_url,
                    "provider_data": [
                        {
                            "uid": p.uid,
                            "provider_id": p.provider_id,
                            "email": p.email,
                        }
                        for p in (user.provider_data or [])
                    ],
                    "custom_claims": user.custom_claims,
                    "creation_timestamp": user.user_metadata.creation_timestamp
                    if user.user_metadata
                    else None,
                    "last_sign_in_timestamp": user.user_metadata.last_sign_in_timestamp
                    if user.user_metadata
                    else None,
                },
                ensure_ascii=False,
                default=str,
            )
        )
    payload = _gzip_bytes(("\n".join(rows) + ("\n" if rows else "")).encode("utf-8"))
    name = f"auth/{stamp}/accounts.jsonl.gz"
    _upload_bytes(bucket, name, payload, "application/gzip")
    print(f"[auth] users={len(rows)} bytes={len(payload)} -> {name}", flush=True)
    return {"users": len(rows), "bytes": len(payload), "object": name}


def _write_doc_line(doc: Any) -> str:
    return json.dumps(
        {"path": doc.reference.path, "id": doc.id, "data": doc.to_dict()},
        ensure_ascii=False,
        default=str,
    )


def _walk_collection(col: Any, lines: List[str]) -> int:
    count = 0
    for doc in col.stream():
        lines.append(_write_doc_line(doc))
        count += 1
        for sub in doc.reference.collections():
            count += _walk_collection(sub, lines)
    return count


def backup_firestore_walk(
    creds: service_account.Credentials, bucket: storage.Bucket, stamp: str
) -> Dict[str, Any]:
    """google-cloud-firestore Client로 컬렉션·서브컬렉션을 dump 한다."""
    from google.cloud import firestore as gcs_fs

    db = gcs_fs.Client(project=SOURCE_PROJECT, credentials=creds)
    lines: List[str] = []
    docs = 0
    top: List[str] = []
    for col in db.collections():
        top.append(col.id)
        docs += _walk_collection(col, lines)
    payload = _gzip_bytes(("\n".join(lines) + ("\n" if lines else "")).encode("utf-8"))
    name = f"firestore/{stamp}/documents.jsonl.gz"
    _upload_bytes(bucket, name, payload, "application/gzip")
    print(
        f"[firestore-walk] docs={docs} collections={top} bytes={len(payload)} -> {name}",
        flush=True,
    )
    return {
        "mode": "walk",
        "docs": docs,
        "collections": top,
        "bytes": len(payload),
        "object": name,
    }


def backup_firestore_native(creds: service_account.Credentials, stamp: str) -> Dict[str, Any]:
    """공식 export. 권한 없으면 예외를 올려 walk로 폴백한다."""
    from google.cloud import firestore_admin_v1

    client = firestore_admin_v1.FirestoreAdminClient(credentials=creds)
    prefix = f"gs://{BACKUP_BUCKET}/firestore/{stamp}/native"
    op = client.export_documents(
        request={
            "name": f"projects/{SOURCE_PROJECT}/databases/(default)",
            "output_uri_prefix": prefix,
        }
    )
    print(f"[firestore-native] started {prefix}", flush=True)
    op.result(timeout=3600)
    print("[firestore-native] done", flush=True)
    return {"mode": "native", "output_uri_prefix": prefix}


def backup_firestore(
    creds: service_account.Credentials, bucket: storage.Bucket, stamp: str
) -> Dict[str, Any]:
    prefix = f"gs://{BACKUP_BUCKET}/firestore/{stamp}/native"
    try:
        return backup_firestore_native(creds, stamp)
    except Exception as exc:
        msg = str(exc).lower()
        if "already exists" in msg or "alreadyexist" in msg:
            print(f"[firestore-native] reuse existing {prefix}", flush=True)
            return {"mode": "native", "reused": True, "output_uri_prefix": prefix}
        print(f"[firestore-native] fallback walk: {type(exc).__name__}: {exc}", flush=True)
        return backup_firestore_walk(creds, bucket, stamp)


def _gcloud_bin() -> str:
    env = (os.getenv("GCLOUD") or "").strip()
    if env:
        return env
    local = os.path.expandvars(
        r"%USERPROFILE%\AppData\Local\Google\CloudSDK\google-cloud-sdk\bin\gcloud.cmd"
    )
    if os.name == "nt" and os.path.isfile(local):
        return local
    found = shutil.which("gcloud")
    if not found:
        raise RuntimeError("gcloud 없음 — Storage rsync를 쓸 수 없습니다.")
    return found


def backup_storage(creds: service_account.Credentials, dest: storage.Bucket) -> Dict[str, Any]:
    """GCS 병렬 rsync. 대상에 있는 객체는 지우지 않는다."""
    del creds, dest
    dest_uri = f"gs://{BACKUP_BUCKET}/storage/{SOURCE_BUCKET}"
    cmd = [
        _gcloud_bin(),
        "storage",
        "rsync",
        f"gs://{SOURCE_BUCKET}",
        dest_uri,
        "--recursive",
        "--skip-if-dest-has-newer",
    ]
    print(f"[storage] rsync {' '.join(cmd[1:])}", flush=True)
    proc = subprocess.run(cmd, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"gcloud storage rsync failed: {proc.returncode}")
    print("[storage] rsync done", flush=True)
    return {
        "mode": "gcloud_rsync",
        "source_bucket": SOURCE_BUCKET,
        "dest_uri": dest_uri,
        "includes": ["signals/raw", "signals/processed", "user files"],
    }


def _mp_secret() -> str:
    secret = (os.getenv("MIXPANEL_API_SECRET") or "").strip()
    if secret:
        return secret
    env_path = Path(__file__).resolve().parents[2] / "backend" / ".env"
    if env_path.is_file():
        for raw in env_path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.strip() == "MIXPANEL_API_SECRET":
                return value.strip().strip('"').strip("'")
    raise SystemExit("MIXPANEL_API_SECRET 없음")


def _mp_auth_header(secret: str) -> str:
    token = base64.b64encode(f"{secret}:".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def _daterange(start: date, end: date) -> Iterable[Tuple[date, date]]:
    """Mixpanel export는 기간이 길면 잘리므로 7일 단위로 자른다."""
    cur = start
    while cur <= end:
        chunk_end = min(cur + timedelta(days=6), end)
        yield cur, chunk_end
        cur = chunk_end + timedelta(days=1)


def _mp_request(
    url: str,
    headers: Dict[str, str],
    data: Optional[bytes] = None,
    timeout: int = 300,
    method: Optional[str] = None,
) -> bytes:
    """Mixpanel HTTP. 429/5xx는 Retry-After 또는 지수 백오프로 재시도한다."""
    delay = 30.0
    attempts = 8
    last_exc: Optional[BaseException] = None
    for i in range(attempts):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            body = exc.read()
            last_exc = exc
            if exc.code in (429, 500, 502, 503) and i < attempts - 1:
                wait = delay
                retry_after = exc.headers.get("Retry-After") if exc.headers else None
                if retry_after:
                    try:
                        wait = max(delay, float(retry_after))
                    except ValueError:
                        pass
                print(
                    f"[mixpanel] HTTP {exc.code} retry {i + 1}/{attempts} in {wait:.0f}s",
                    flush=True,
                )
                time.sleep(wait)
                delay = min(delay * 2, 300.0)
                continue
            detail = body.decode("utf-8", errors="replace")[:500]
            raise RuntimeError(f"Mixpanel HTTP {exc.code}: {detail}") from exc
        except (TimeoutError, urllib.error.URLError) as exc:
            last_exc = exc
            if i < attempts - 1:
                print(
                    f"[mixpanel] {type(exc).__name__} retry {i + 1}/{attempts} in {delay:.0f}s",
                    flush=True,
                )
                time.sleep(delay)
                delay = min(delay * 2, 300.0)
                continue
            raise
    raise RuntimeError(f"Mixpanel request failed: {last_exc}") from last_exc


def _existing_event_blob(
    bucket: storage.Bucket, name: str
) -> Optional[storage.Blob]:
    blob = bucket.blob(name)
    if not blob.exists():
        return None
    blob.reload()
    return blob


def backup_mixpanel_events(
    bucket: storage.Bucket,
    start: date,
    end: date,
    on_chunk: Optional[Callable[[date], None]] = None,
) -> Dict[str, Any]:
    secret = _mp_secret()
    auth = _mp_auth_header(secret)
    files = 0
    events = 0
    bytes_out = 0
    skipped = 0
    for chunk_start, chunk_end in _daterange(start, end):
        name = (
            f"mixpanel/events/{chunk_start.isoformat()}_{chunk_end.isoformat()}.jsonl.gz"
        )
        existing = _existing_event_blob(bucket, name)
        if existing is not None and (existing.size or 0) > 20:
            skipped += 1
            files += 1
            bytes_out += int(existing.size or 0)
            print(
                f"[mixpanel-events] skip existing {chunk_start}..{chunk_end} bytes={existing.size}",
                flush=True,
            )
            if on_chunk:
                on_chunk(chunk_end)
            continue
        qs = urllib.parse.urlencode(
            {
                "from_date": chunk_start.isoformat(),
                "to_date": chunk_end.isoformat(),
            }
        )
        url = f"https://data.mixpanel.com/api/2.0/export?{qs}"
        body = _mp_request(
            url,
            {
                "Authorization": auth,
                "Accept": "text/plain",
                "User-Agent": "yorigo-offsite-backup/1.0",
            },
        )
        text = body.decode("utf-8", errors="replace")
        n = len([ln for ln in text.splitlines() if ln.strip()])
        payload = _gzip_bytes(body)
        _upload_bytes(bucket, name, payload, "application/gzip")
        files += 1
        events += n
        bytes_out += len(payload)
        print(
            f"[mixpanel-events] {chunk_start}..{chunk_end} events={n} bytes={len(payload)}",
            flush=True,
        )
        if on_chunk:
            on_chunk(chunk_end)
        time.sleep(8)
    return {
        "from": start.isoformat(),
        "to": end.isoformat(),
        "events": events,
        "files": files,
        "skipped_existing": skipped,
        "bytes": bytes_out,
    }


def backup_mixpanel_people(bucket: storage.Bucket, stamp: str) -> Dict[str, Any]:
    """People 프로필(유저별 속성) 전체 페이지를 받는다."""
    secret = _mp_secret()
    auth = _mp_auth_header(secret)
    session_id: Optional[str] = None
    page = 0
    profiles = 0
    lines: List[str] = []
    while True:
        payload: Dict[str, Any] = {"page": page, "include_all_users": True}
        if session_id:
            payload["session_id"] = session_id
        data = urllib.parse.urlencode(payload).encode("utf-8")
        raw_resp = _mp_request(
            "https://mixpanel.com/api/2.0/engage",
            {
                "Authorization": auth,
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "yorigo-offsite-backup/1.0",
            },
            data=data,
            timeout=120,
            method="POST",
        )
        parsed = json.loads(raw_resp.decode("utf-8"))
        results = parsed.get("results") or []
        for item in results:
            lines.append(json.dumps(item, ensure_ascii=False, default=str))
        profiles += len(results)
        session_id = parsed.get("session_id") or session_id
        page += 1
        if not results:
            break
        if page > 10000:
            break
        time.sleep(0.4)
    raw = ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8")
    gz = _gzip_bytes(raw)
    name = f"mixpanel/people/{stamp}.jsonl.gz"
    _upload_bytes(bucket, name, gz, "application/gzip")
    print(f"[mixpanel-people] profiles={profiles} bytes={len(gz)}", flush=True)
    return {"profiles": profiles, "bytes": len(gz), "object": name}


def _maybe_email(manifest: Dict[str, Any]) -> None:
    api_key = (os.getenv("RESEND_API_KEY") or "").strip()
    to_raw = (os.getenv("ALERT_EMAIL_TO") or "").strip()
    if not api_key or not to_raw:
        return
    from_addr = (
        os.getenv("ALERT_EMAIL_FROM") or "Yorigo Backup <noreply@alerts.yorigo.kr>"
    ).strip()
    if "alerts.yorigo.app" in from_addr.lower():
        from_addr = from_addr.replace("alerts.yorigo.app", "alerts.yorigo.kr")
    subject = f"[Yorigo backup] {manifest.get('mode')} {manifest.get('stamp')} ok={manifest.get('ok')}"
    body = json.dumps(manifest, ensure_ascii=False, indent=2)
    payload = json.dumps(
        {
            "from": from_addr,
            "to": [p.strip() for p in to_raw.split(",") if p.strip()],
            "subject": subject,
            "text": body,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "yorigo-offsite-backup/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"[email] status={resp.status}", flush=True)
    except urllib.error.HTTPError as exc:
        print(f"[email] fail HTTP {exc.code}", flush=True)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Yorigo offsite backup")
    parser.add_argument("--mode", choices=("full", "monthly"), default="monthly")
    parser.add_argument(
        "--skip-mixpanel",
        action="store_true",
        help="Mixpanel 생략 (시크릿 없을 때)",
    )
    parser.add_argument("--skip-auth", action="store_true")
    parser.add_argument("--skip-firestore", action="store_true")
    parser.add_argument(
        "--skip-storage",
        action="store_true",
        help="Storage는 Transfer Service가 맡을 때 생략",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    stamp = _run_stamp()
    sa_info = _load_sa_info()
    creds = _credentials()
    client = _storage_client(creds)
    bucket = client.bucket(BACKUP_BUCKET)
    try:
        bucket.reload()
    except Exception as exc:
        raise SystemExit(
            f"백업 버킷 접근 실패 gs://{BACKUP_BUCKET}: {type(exc).__name__}: {exc}"
        ) from exc

    _init_firebase(sa_info)
    state = _load_state(bucket)
    manifest: Dict[str, Any] = {
        "ok": True,
        "mode": args.mode,
        "stamp": stamp,
        "source_project": SOURCE_PROJECT,
        "backup_project": BACKUP_PROJECT,
        "backup_bucket": BACKUP_BUCKET,
        "started_at": datetime.now(timezone.utc).isoformat(),
    }

    try:
        if args.skip_auth:
            manifest["auth"] = {"skipped": True}
        else:
            manifest["auth"] = backup_auth(bucket, stamp)
        if args.skip_firestore:
            manifest["firestore"] = {"skipped": True}
        else:
            manifest["firestore"] = backup_firestore(creds, bucket, stamp)
        if args.skip_storage:
            manifest["storage"] = {"skipped": True, "note": "Transfer Service"}
        else:
            manifest["storage"] = backup_storage(creds, bucket)

        if not args.skip_mixpanel:
            yesterday = _utc_today() - timedelta(days=1)
            through = state.get("mixpanel_events_through")
            if args.mode == "monthly" and through:
                start = date.fromisoformat(str(through)) + timedelta(days=1)
            else:
                start = date.fromisoformat(MIXPANEL_START)

            def _advance_mixpanel(chunk_end: date) -> None:
                current = str(state.get("mixpanel_events_through") or "")
                nxt = chunk_end.isoformat()
                if not current or nxt > current:
                    state["mixpanel_events_through"] = nxt
                    _save_state(bucket, state)

            if start <= yesterday:
                manifest["mixpanel_events"] = backup_mixpanel_events(
                    bucket, start, yesterday, on_chunk=_advance_mixpanel
                )
                _advance_mixpanel(yesterday)
            else:
                manifest["mixpanel_events"] = {"skipped": "up_to_date"}
            try:
                manifest["mixpanel_people"] = backup_mixpanel_people(bucket, stamp)
            except Exception as exc:
                if args.mode == "monthly":
                    print(
                        f"[mixpanel-people] monthly continue after error: {type(exc).__name__}: {exc}",
                        flush=True,
                    )
                    manifest["mixpanel_people"] = {
                        "skipped": "error",
                        "error": f"{type(exc).__name__}: {exc}",
                    }
                else:
                    raise
        state["last_run"] = stamp
        state["last_mode"] = args.mode
        _save_state(bucket, state)
        name = f"meta/manifest-{stamp}.json"
        _upload_bytes(
            bucket,
            name,
            json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"),
            "application/json",
        )
        manifest["manifest_object"] = name
    except Exception as exc:
        manifest["ok"] = False
        manifest["error"] = f"{type(exc).__name__}: {exc}"
        print(f"[backup] FAILED {manifest['error']}", file=sys.stderr)
        _maybe_email(manifest)
        return 1

    manifest["finished_at"] = datetime.now(timezone.utc).isoformat()
    print(json.dumps({k: v for k, v in manifest.items() if k != "error"}, ensure_ascii=False, indent=2))
    _maybe_email(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
