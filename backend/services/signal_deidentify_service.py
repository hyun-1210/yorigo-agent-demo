"""계정 탈퇴 시 행동 시그널(GCS) 비식별 처리.

설계 원칙:
- 시그널 자체(노출/클릭/요리/구매 의도 등)는 통계·추천 품질 개선을 위해 남긴다.
- 특정 개인과 연결되는 식별자만 제거한다: userId, deviceId, sessionId.
- backfill eventId처럼 UID가 문자열에 박혀 있는 경우도 제거한다.
- raw 경로 ``signals/raw/{date}/{uid}/...`` 자체에 UID가 드러나므로,
  비식별 결과를 processed 파티션에 별도 파일로 옮긴 뒤 원본 raw는 삭제한다.
- processed gzip은 다수 유저가 섞여 있으므로 해당 uid 라인만 비식별해 덮어쓴다.
- 계정 삭제 API가 실패하지 않도록, 비식별 실패는 예외를 밖으로 던지지 않고
  큐에 남겨 재시도한다(지체 없는 처리 + 최종 일관성).

비용 최적화 (중요):
- ``signals/processed/``는 삭제되지 않고 계속 쌓이므로, "탈퇴 1건마다 전체
  히스토리를 다운로드해서 uid를 찾는" 방식은 데이터가 커질수록 탈퇴 1건당
  비용(다운로드 바이트/네트워크 egress)이 무한정 늘어난다.
- 그래서 계정 생성일(``account_created_date``)을 알면 그 날짜 ~ 오늘 사이의
  ``dt=`` 파티션만 골라서 리스트/다운로드한다. 유저는 계정 생성 이전 날짜의
  이벤트를 절대 만들 수 없으므로 정확성 손실 없이 스캔 범위만 좁아진다.
- 생성일을 알 수 없는 예외 상황(예: Firebase Auth 조회 실패)에는 안전을
  우선해 기존처럼 전체 스캔으로 폴백한다 — 비용보다 데이터 유실 방지가 우선.
  이 경로를 타면 ``stats["scan_mode"] == "full_history_fallback"``으로
  남겨 모니터링/알림으로 감지할 수 있게 한다.
"""

from __future__ import annotations

import gzip
import io
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

import firebase_admin
from firebase_admin import firestore as admin_firestore
from firebase_admin import storage as admin_storage
from google.cloud.firestore_v1 import FieldFilter

logger = logging.getLogger(__name__)

_RAW_PREFIX = "signals/raw"
_PROCESSED_PREFIX = "signals/processed"
_QUEUE_COLLECTION = "signal_deidentify_queue"
_IDENTIFYING_KEYS = ("userId", "deviceId", "sessionId")

# signals/raw/ 버킷 lifecycle(setup_signal_storage_lifecycle.py 기본값)과 맞춘
# 값. 이보다 오래된 raw 데이터는 이미 GCS가 자동 삭제했으므로 스캔할 필요가 없다.
_RAW_LIFECYCLE_DAYS = 14
# 타임존/시계 오차, 가입일 추정 오차에 대비한 여유일.
_DATE_SAFETY_BUFFER_DAYS = 2
# 날짜 범위가 비정상적으로 넓으면(데이터 오류 등) 오히려 리스트 호출 수가
# 폭증할 수 있어, 이 한도를 넘으면 폴백(전체 스캔)한다.
_MAX_BOUNDED_SCAN_DAYS = 3650  # 약 10년


def _resolve_bucket_name() -> str:
    env_bucket = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    if env_bucket:
        return env_bucket
    try:
        project_id = firebase_admin.get_app().project_id
    except Exception:
        project_id = os.getenv("FIREBASE_PROJECT_ID", "").strip()
    if not project_id:
        return ""
    return f"{project_id}.firebasestorage.app"


def _get_bucket() -> Any:
    bucket_name = _resolve_bucket_name()
    if not bucket_name:
        raise RuntimeError("Firebase Storage bucket not configured")
    return admin_storage.bucket(bucket_name, app=firebase_admin.get_app())


def deidentify_event(event: dict[str, Any], uid: str) -> dict[str, Any]:
    """단일 이벤트에서 식별자를 제거한다. 원본 dict는 변경하지 않는다."""
    if not isinstance(event, dict):
        return {}
    out = dict(event)
    for key in _IDENTIFYING_KEYS:
        out.pop(key, None)

    event_id = out.get("eventId")
    if isinstance(event_id, str) and uid and uid in event_id:
        # backfill_save_{uid}_{recipeId} 형태 등 — UID 잔존 방지.
        # 결정적 해시가 아니라 새 UUID를 써서 동일 유저 이벤트끼리
        # eventId로 재연결되지 않게 한다.
        out["eventId"] = f"deid_{uuid.uuid4().hex}"

    # 경로/파일명 등에 남을 수 있는 문자열 필드에서도 uid 리터럴 제거.
    for key, value in list(out.items()):
        if key in ("eventId",):
            continue
        if isinstance(value, str) and uid and uid in value:
            out[key] = value.replace(uid, "[redacted]")

    out["deidentified"] = True
    return out


def event_belongs_to_user(event: dict[str, Any], uid: str) -> bool:
    """이벤트가 해당 유저의 것인지 판별한다."""
    if not uid or not isinstance(event, dict):
        return False
    if event.get("userId") == uid:
        return True
    event_id = event.get("eventId")
    if isinstance(event_id, str) and uid in event_id:
        return True
    return False


def _gzip_jsonl_lines(lines: list[str]) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
        payload = ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8")
        gz.write(payload)
    return buf.getvalue()


def _read_gzip_text(blob: Any) -> str:
    raw = blob.download_as_bytes()
    try:
        return gzip.decompress(raw).decode("utf-8", errors="replace")
    except OSError:
        return raw.decode("utf-8", errors="replace")


def _date_from_raw_path(blob_name: str) -> Optional[str]:
    # signals/raw/{yyyy-MM-dd}/{uid}/file.jsonl
    parts = blob_name.split("/")
    if len(parts) < 4:
        return None
    date_str = parts[2]
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
        return date_str
    return None


def _iso_date_range(start: str, end: str) -> Optional[list[str]]:
    """[start, end] 사이(포함) 날짜 문자열 목록. 범위가 비정상이면 None."""
    try:
        start_d = datetime.strptime(start, "%Y-%m-%d").date()
        end_d = datetime.strptime(end, "%Y-%m-%d").date()
    except ValueError:
        return None
    if end_d < start_d:
        return []
    span_days = (end_d - start_d).days
    if span_days > _MAX_BOUNDED_SCAN_DAYS:
        return None
    return [
        (start_d + timedelta(days=offset)).isoformat()
        for offset in range(span_days + 1)
    ]


def compute_scan_dates(
    account_created_date: Optional[str],
) -> dict[str, Optional[list[str]]]:
    """계정 생성일 기준으로 raw/processed 스캔 대상 날짜 목록을 계산한다.

    account_created_date가 없거나 파싱에 실패하면 두 값 모두 None을 반환해
    호출자가 기존 전체 스캔으로 폴백하게 한다(비용보다 정확성 우선).
    """
    if not account_created_date:
        return {"raw_dates": None, "processed_dates": None}
    try:
        created = datetime.strptime(account_created_date, "%Y-%m-%d").date()
    except ValueError:
        logger.warning(
            "[SignalDeid] account_created_date 파싱 실패: %r — 전체 스캔으로 폴백",
            account_created_date,
        )
        return {"raw_dates": None, "processed_dates": None}

    today = datetime.now(timezone.utc).date()
    end = (today + timedelta(days=_DATE_SAFETY_BUFFER_DAYS)).isoformat()

    processed_start = (created - timedelta(days=_DATE_SAFETY_BUFFER_DAYS)).isoformat()
    processed_dates = _iso_date_range(processed_start, end)

    raw_earliest_possible = today - timedelta(
        days=_RAW_LIFECYCLE_DAYS + _DATE_SAFETY_BUFFER_DAYS
    )
    raw_start = max(
        created - timedelta(days=_DATE_SAFETY_BUFFER_DAYS), raw_earliest_possible
    ).isoformat()
    raw_dates = _iso_date_range(raw_start, end)

    return {"raw_dates": raw_dates, "processed_dates": processed_dates}


def _deidentify_raw_blobs(
    bucket: Any,
    uid: str,
    *,
    max_blobs: int = 5000,
    dates: Optional[list[str]] = None,
) -> dict[str, int]:
    """uid 전용 raw 배치를 비식별해 processed로 옮기고 원본을 삭제한다.

    ``dates``가 주어지면 ``signals/raw/{date}/{uid}/`` 처럼 날짜+uid로 정확히
    좁힌 prefix만 리스트한다(다른 유저 파일은 애초에 나열조차 안 됨 — 리스트
    오퍼레이션 자체가 줄어든다). ``dates``가 None이면 기존처럼
    ``signals/raw/`` 전체를 리스트한 뒤 marker로 걸러낸다(폴백/테스트용).
    """
    stats = {
        "raw_blobs_scanned": 0,
        "raw_blobs_matched": 0,
        "raw_events_deidentified": 0,
        "raw_blobs_deleted": 0,
        "raw_upload_files": 0,
        "raw_errors": 0,
    }
    deid_by_date: dict[str, list[str]] = {}
    matched_blobs: list[Any] = []
    cap_hit = False

    if dates is not None:
        for date_str in dates:
            if cap_hit:
                break
            prefix = f"{_RAW_PREFIX}/{date_str}/{uid}/"
            for blob in bucket.list_blobs(prefix=prefix):
                stats["raw_blobs_scanned"] += 1
                name = blob.name or ""
                if not name.endswith(".jsonl"):
                    continue
                matched_blobs.append(blob)
                if len(matched_blobs) >= max_blobs:
                    cap_hit = True
                    break
    else:
        marker = f"/{uid}/"
        for blob in bucket.list_blobs(prefix=f"{_RAW_PREFIX}/"):
            stats["raw_blobs_scanned"] += 1
            name = blob.name or ""
            if marker not in name or not name.endswith(".jsonl"):
                continue
            matched_blobs.append(blob)
            if len(matched_blobs) >= max_blobs:
                cap_hit = True
                break

    if cap_hit:
        logger.warning(
            "[SignalDeid] raw blob match cap reached (%d) for uid=%s",
            max_blobs,
            uid,
        )

    stats["raw_blobs_matched"] = len(matched_blobs)
    if not matched_blobs:
        return stats

    for blob in matched_blobs:
        date_str = _date_from_raw_path(blob.name) or datetime.now(
            timezone.utc
        ).date().isoformat()
        try:
            text = blob.download_as_bytes().decode("utf-8", errors="replace")
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict):
                    continue
                # raw 경로가 해당 uid이므로 기본적으로 모두 대상.
                # 혹시 다른 userId가 섞여 있으면 그 줄만 스킵(유실 방지).
                other_uid = event.get("userId")
                if (
                    isinstance(other_uid, str)
                    and other_uid
                    and other_uid != uid
                    and not event_belongs_to_user(event, uid)
                ):
                    continue
                deid = deidentify_event(event, uid)
                deid_by_date.setdefault(date_str, []).append(
                    json.dumps(deid, ensure_ascii=False)
                )
                stats["raw_events_deidentified"] += 1
        except Exception as e:
            stats["raw_errors"] += 1
            logger.warning(
                "[SignalDeid] raw download/parse failed %s: %s", blob.name, e
            )
            # 일부 raw 파싱 실패 시 원본 삭제로 넘어가면 안 됨.
            return stats

    uploaded_ok = True
    for date_str, lines in deid_by_date.items():
        if not lines:
            continue
        out_name = (
            f"{_PROCESSED_PREFIX}/dt={date_str}/"
            f"events_deid_{uuid.uuid4().hex[:12]}.jsonl.gz"
        )
        try:
            bucket.blob(out_name).upload_from_string(
                _gzip_jsonl_lines(lines),
                content_type="application/gzip",
            )
            stats["raw_upload_files"] += 1
        except Exception as e:
            uploaded_ok = False
            stats["raw_errors"] += 1
            logger.warning(
                "[SignalDeid] deid upload failed %s: %s", out_name, e
            )
            break

    # 모든 업로드가 성공했을 때만 원본 raw 삭제(부분 유실 방지).
    if not uploaded_ok or stats["raw_errors"] > 0:
        return stats

    for blob in matched_blobs:
        try:
            blob.delete()
            stats["raw_blobs_deleted"] += 1
        except Exception as e:
            stats["raw_errors"] += 1
            logger.warning(
                "[SignalDeid] raw delete failed %s: %s", blob.name, e
            )

    return stats


def _iter_processed_candidate_blobs(bucket: Any, dates: Optional[list[str]]):
    """비식별 대상이 될 수 있는 processed blob들을 순회한다.

    ``dates``가 주어지면 ``signals/processed/dt={date}/`` 단위로만 리스트해서
    유저 활동 기간 밖의 (다운로드도 안 하고 목록조차 안 가져오는) 오래된
    파티션은 애초에 건드리지 않는다 — 계정이 오래될수록, 전체 히스토리가
    커질수록 절감 효과가 커진다. ``dates``가 None이면 기존처럼
    ``signals/processed/`` 전체를 리스트한다(폴백/테스트용).
    """
    if dates is not None:
        for date_str in dates:
            prefix = f"{_PROCESSED_PREFIX}/dt={date_str}/"
            for blob in bucket.list_blobs(prefix=prefix):
                yield blob
    else:
        for blob in bucket.list_blobs(prefix=f"{_PROCESSED_PREFIX}/"):
            yield blob


def _deidentify_processed_blobs(
    bucket: Any,
    uid: str,
    *,
    max_blobs: int = 5000,
    dates: Optional[list[str]] = None,
) -> dict[str, int]:
    """processed gzip에서 해당 uid 라인만 비식별해 덮어쓴다.

    다수 유저 이벤트가 한 파일에 섞여 있어 uid 매칭 여부는 다운로드 전에
    알 수 없다. 그래서 비용 절감은 "어느 파일을 다운로드할지"를
    ``dates``(계정 활동 기간)로 좁히는 방식으로 한다 — 실제 데이터 유실 없이
    (유저는 가입 이전 날짜 이벤트를 만들 수 없음) 다운로드/디컴프레션 비용만
    줄인다. 자세한 배경은 모듈 docstring 참고.
    """
    stats = {
        "processed_blobs_scanned": 0,
        "processed_blobs_rewritten": 0,
        "processed_events_deidentified": 0,
        "processed_errors": 0,
    }
    rewritten = 0
    for blob in _iter_processed_candidate_blobs(bucket, dates):
        stats["processed_blobs_scanned"] += 1
        name = blob.name or ""
        if not (name.endswith(".jsonl.gz") or name.endswith(".jsonl")):
            continue
        # 방금/이전에 올린 deid 전용 파일은 userId가 없으므로 I/O 절약차 스킵.
        basename = name.rsplit("/", 1)[-1]
        if basename.startswith("events_deid_"):
            continue
        try:
            # generation precondition용 메타를 확보한다(없으면 None).
            try:
                blob.reload()
            except Exception:
                pass
            text = _read_gzip_text(blob)
        except Exception as e:
            stats["processed_errors"] += 1
            logger.warning(
                "[SignalDeid] processed download failed %s: %s", name, e
            )
            continue

        changed = False
        out_lines: list[str] = []
        for line in text.splitlines():
            raw_line = line.strip()
            if not raw_line:
                continue
            try:
                event = json.loads(raw_line)
            except json.JSONDecodeError:
                out_lines.append(raw_line)
                continue
            if event_belongs_to_user(event, uid):
                deid = deidentify_event(event, uid)
                out_lines.append(json.dumps(deid, ensure_ascii=False))
                stats["processed_events_deidentified"] += 1
                changed = True
            else:
                out_lines.append(raw_line)

        if not changed:
            continue
        try:
            if name.endswith(".jsonl.gz"):
                payload = _gzip_jsonl_lines(out_lines)
                content_type = "application/gzip"
            else:
                payload = ("\n".join(out_lines) + "\n").encode("utf-8")
                content_type = "application/x-ndjson"
            # 동시 탈퇴로 같은 processed 파일을 두 작업이 고치면
            # last-write-wins로 한쪽 비식별이 유실될 수 있다.
            # download 시점 generation과 일치할 때만 덮어쓰고, 아니면 재시도 큐로.
            generation = getattr(blob, "generation", None)
            upload_kwargs: dict[str, Any] = {"content_type": content_type}
            if generation is not None:
                upload_kwargs["if_generation_match"] = generation
            blob.upload_from_string(payload, **upload_kwargs)
            stats["processed_blobs_rewritten"] += 1
            rewritten += 1
            if rewritten >= max_blobs:
                break
        except Exception as e:
            stats["processed_errors"] += 1
            logger.warning(
                "[SignalDeid] processed rewrite failed %s: %s", name, e
            )

    return stats


def enqueue_signal_deidentify(
    db: Any,
    uid: str,
    reason: str,
    *,
    account_created_date: Optional[str] = None,
) -> None:
    """비식별 작업을 재시도 큐에 넣는다.

    ``account_created_date``를 큐 문서에 같이 저장해두면, 스케줄러가 나중에
    이 문서를 재시도할 때도(``process_signal_deidentify_queue``) 전체 스캔이
    아니라 좁혀진 날짜 범위로 재시도할 수 있다.
    """
    payload: dict[str, Any] = {
        "uid": uid,
        "status": "pending",
        "reason": reason,
        "attempts": 0,
        "createdAt": admin_firestore.SERVER_TIMESTAMP,
        "updatedAt": admin_firestore.SERVER_TIMESTAMP,
    }
    if account_created_date:
        payload["accountCreatedDate"] = account_created_date
    db.collection(_QUEUE_COLLECTION).document(uid).set(payload, merge=True)


def mark_signal_deidentify_done(
    db: Any,
    uid: str,
    stats: dict[str, Any],
) -> None:
    db.collection(_QUEUE_COLLECTION).document(uid).set(
        {
            "uid": uid,
            "status": "completed",
            "stats": stats,
            "completedAt": admin_firestore.SERVER_TIMESTAMP,
            "updatedAt": admin_firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )


def mark_signal_deidentify_failed(
    db: Any,
    uid: str,
    error: str,
    stats: Optional[dict[str, Any]] = None,
) -> None:
    ref = db.collection(_QUEUE_COLLECTION).document(uid)
    snap = ref.get()
    attempts = 0
    if snap.exists:
        attempts = int((snap.to_dict() or {}).get("attempts") or 0)
    ref.set(
        {
            "uid": uid,
            "status": "failed",
            "attempts": attempts + 1,
            "lastError": error[:1000],
            "stats": stats or {},
            "updatedAt": admin_firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )


def deidentify_user_signals(
    uid: str,
    *,
    db: Any = None,
    reason: str = "account_deletion",
    enqueue_on_failure: bool = True,
    account_created_date: Optional[str] = None,
) -> dict[str, Any]:
    """한 유저의 GCS 시그널을 비식별 처리한다.

    Args:
        account_created_date: ``YYYY-MM-DD`` 형식의 계정 생성일(UTC 기준
            느슨한 근사치면 충분). 주어지면 raw/processed 스캔 범위를 그
            날짜부터 오늘까지로 좁혀 GCS 다운로드/리스트 비용을 데이터
            전체 크기가 아니라 "이 유저의 활동 기간"에 비례하게 만든다.
            생략하면 기존처럼 전체 히스토리를 스캔한다(정확성 우선 폴백).

    Returns:
        처리 통계 dict. 실패해도 예외를 밖으로 던지지 않고 stats.error에 남긴다.
    """
    started = time.monotonic()
    stats: dict[str, Any] = {
        "uid": uid,
        "ok": False,
        "elapsed_seconds": 0.0,
    }
    if not uid or not isinstance(uid, str):
        stats["error"] = "invalid_uid"
        return stats

    try:
        if db is not None:
            # 계정 삭제와 동시에 재시도 가능하도록 먼저 큐에 표시.
            enqueue_signal_deidentify(
                db, uid, reason, account_created_date=account_created_date
            )

        scan_dates = compute_scan_dates(account_created_date)
        stats["scan_mode"] = (
            "bounded"
            if scan_dates["processed_dates"] is not None
            else "full_history_fallback"
        )
        if stats["scan_mode"] == "full_history_fallback":
            # 비용 모니터링용 — 이 경로가 잦으면 계정 생성일 조회 실패가
            # 늘고 있다는 신호이니 알림/로그로 추적한다.
            logger.warning(
                "[SignalDeid] uid=%s: account_created_date 없음 — "
                "processed 전체 히스토리 스캔으로 폴백(비용 ↑)",
                uid,
            )

        bucket = _get_bucket()
        raw_stats = _deidentify_raw_blobs(
            bucket, uid, dates=scan_dates["raw_dates"]
        )
        processed_stats = _deidentify_processed_blobs(
            bucket, uid, dates=scan_dates["processed_dates"]
        )
        stats.update(raw_stats)
        stats.update(processed_stats)
        stats["ok"] = (
            raw_stats.get("raw_errors", 0) == 0
            and processed_stats.get("processed_errors", 0) == 0
        )
        if db is not None:
            if stats["ok"]:
                mark_signal_deidentify_done(db, uid, stats)
            elif enqueue_on_failure:
                mark_signal_deidentify_failed(
                    db, uid, "partial_errors", stats
                )
    except Exception as e:
        logger.exception("[SignalDeid] failed for uid=%s: %s", uid, e)
        stats["error"] = str(e)
        stats["ok"] = False
        if db is not None and enqueue_on_failure:
            try:
                mark_signal_deidentify_failed(db, uid, str(e), stats)
            except Exception:
                logger.exception(
                    "[SignalDeid] failed to mark queue failure for uid=%s", uid
                )
    finally:
        stats["elapsed_seconds"] = round(time.monotonic() - started, 3)

    logger.info(
        "[SignalDeid] uid=%s ok=%s raw_matched=%s processed_rewritten=%s "
        "events=%s elapsed=%.2fs",
        uid,
        stats.get("ok"),
        stats.get("raw_blobs_matched"),
        stats.get("processed_blobs_rewritten"),
        (stats.get("raw_events_deidentified") or 0)
        + (stats.get("processed_events_deidentified") or 0),
        stats.get("elapsed_seconds") or 0,
    )
    return stats


def process_signal_deidentify_queue(
    db: Any,
    *,
    limit: int = 20,
) -> dict[str, int]:
    """pending/failed 큐를 재처리한다."""
    result = {"scanned": 0, "completed": 0, "failed": 0}
    docs: list[Any] = []
    try:
        docs = list(
            db.collection(_QUEUE_COLLECTION)
            .where(filter=FieldFilter("status", "in", ["pending", "failed"]))
            .limit(limit)
            .stream()
        )
    except Exception:
        docs = list(
            db.collection(_QUEUE_COLLECTION)
            .where(filter=FieldFilter("status", "==", "pending"))
            .limit(limit)
            .stream()
        )

    for doc in docs:
        result["scanned"] += 1
        data = doc.to_dict() or {}
        uid = str(data.get("uid") or doc.id)
        attempts = int(data.get("attempts") or 0)
        if attempts >= 8:
            continue
        stats = deidentify_user_signals(
            uid,
            db=db,
            reason=str(data.get("reason") or "retry"),
            enqueue_on_failure=True,
            account_created_date=data.get("accountCreatedDate"),
        )
        if stats.get("ok"):
            result["completed"] += 1
        else:
            result["failed"] += 1
    return result
