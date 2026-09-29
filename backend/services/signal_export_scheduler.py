"""일일 행동 시그널(impression/click/cook_start/cook_done/purchase 등) 취합 스케줄러.

Flutter 클라이언트가 Firebase Storage(GCS)에 직접 업로드한
``signals/raw/{yyyy-MM-dd}/{uid}/{sessionId}_{ts}_{batchId}.jsonl`` 배치 파일들을
하루 1회 모아서 gzip 압축 후 Hive 파티션 레이아웃
``signals/processed/dt={yyyy-MM-dd}/events.jsonl.gz`` 로 합친다. BigQuery 외부
테이블(``yorigo_signals.raw_events``)이 이 경로를 ``dt`` 파티션 컬럼으로 인식하므로,
날짜 범위로 필터링하는 쿼리는 해당 날짜의 gzip 파일만 스캔한다(전체 히스토리
풀스캔 방지 = BigQuery 쿼리 과금 절감). 이 스케줄러가 끝나야 그날 데이터가
쿼리에 잡힌다.

견고성 (1+A):
- blob 다운로드는 지수 백오프로 재시도한다.
- 재시도 후에도 실패한 blob이 있으면 해당 날짜의 processed 업로드를
  **건너뛴다**(부분 성공본으로 기존 processed를 덮어쓰지 않음).
- 실행 결과는 Firestore ``system_schedules/signal_export.lastRun`` 에 기록하고,
  GitHub Actions가 Resend로 성공/실패 메일을 보낸다.
"""

from __future__ import annotations

import gzip
import io
import logging
import os
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Optional

import firebase_admin
from firebase_admin import firestore as admin_firestore
from firebase_admin import storage as admin_storage

from utils.firestore_schedule_guard import (
    SCHEDULE_COLLECTION,
    ScheduleLeaseHeartbeat,
    complete_schedule_lease,
    fail_schedule_lease,
    try_acquire_schedule_lease,
)

logger = logging.getLogger(__name__)

_EXPORT_INTERVAL_SECONDS = 24 * 60 * 60  # 24시간
_INITIAL_DELAY_SECONDS = 90  # 서버 기동 직후 90초 대기
_SCHEDULE_NAME = "signal_export"
_RAW_PREFIX = "signals/raw"
_PROCESSED_PREFIX = "signals/processed"
_DEFAULT_LOOKBACK_DAYS = 3
_MAX_PARALLEL_DOWNLOADS = 16
_DEFAULT_DOWNLOAD_ATTEMPTS = 3
_DEFAULT_DOWNLOAD_BACKOFF_BASE_SECONDS = 0.5
_RUNS_COLLECTION = "signal_export_runs"


def _resolve_bucket_name() -> str:
    """Storage 버킷 이름을 환경변수 우선, 없으면 프로젝트 ID로 유추한다."""
    env_bucket = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    if env_bucket:
        return env_bucket
    project_id = None
    try:
        project_id = firebase_admin.get_app().project_id
    except Exception:
        pass
    project_id = project_id or os.getenv("FIREBASE_PROJECT_ID", "").strip()
    if not project_id:
        return ""
    # 최근 Firebase 프로젝트는 *.firebasestorage.app 버킷을 기본 사용.
    return f"{project_id}.firebasestorage.app"


def _get_bucket() -> Any:
    bucket_name = _resolve_bucket_name()
    if not bucket_name:
        raise RuntimeError(
            "Firebase Storage 버킷을 확인할 수 없습니다 "
            "(FIREBASE_STORAGE_BUCKET 환경변수를 설정하세요)."
        )
    app = firebase_admin.get_app()
    return admin_storage.bucket(bucket_name, app=app)


def _iter_target_dates(lookback_days: int) -> list[str]:
    """오늘부터 과거 lookback_days일(오늘 포함, UTC 기준) 날짜 문자열 목록."""
    today = datetime.now(timezone.utc).date()
    return [
        (today - timedelta(days=offset)).isoformat() for offset in range(lookback_days)
    ]


def _download_attempts() -> int:
    return max(
        1,
        int(os.getenv("SIGNAL_EXPORT_DOWNLOAD_ATTEMPTS", str(_DEFAULT_DOWNLOAD_ATTEMPTS))),
    )


def _download_backoff_base() -> float:
    return max(
        0.05,
        float(
            os.getenv(
                "SIGNAL_EXPORT_DOWNLOAD_BACKOFF_BASE_SECONDS",
                str(_DEFAULT_DOWNLOAD_BACKOFF_BASE_SECONDS),
            )
        ),
    )


def _download_blob_text(
    blob: Any,
    *,
    max_attempts: Optional[int] = None,
    backoff_base: Optional[float] = None,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> str:
    """GCS blob을 텍스트로 받는다. 일시 실패는 지수 백오프로 재시도한다."""
    attempts = _download_attempts() if max_attempts is None else max(1, max_attempts)
    base = _download_backoff_base() if backoff_base is None else max(0.0, backoff_base)
    last_error: Optional[BaseException] = None
    for attempt in range(1, attempts + 1):
        try:
            raw = blob.download_as_bytes()
            return raw.decode("utf-8", errors="replace").strip("\n")
        except Exception as e:
            last_error = e
            if attempt >= attempts:
                break
            delay = base * (2 ** (attempt - 1))
            logger.warning(
                "[SignalExport] blob 다운로드 재시도 %s attempt=%d/%d wait=%.2fs err=%s",
                getattr(blob, "name", "?"),
                attempt,
                attempts,
                delay,
                e,
            )
            if delay > 0:
                sleep_fn(delay)
    assert last_error is not None
    raise last_error


def _merge_date(
    bucket: Any,
    date_str: str,
    should_stop: Optional[Callable[[], bool]] = None,
    *,
    download_fn: Callable[[Any], str] = _download_blob_text,
) -> dict[str, Any]:
    """하루치 raw JSONL 배치를 모두 내려받아 gzip으로 병합·업로드한다.

    다운로드 실패가 하나라도 남으면 processed를 덮어쓰지 않고 aborted=True 로 반환한다.
    """
    prefix = f"{_RAW_PREFIX}/{date_str}/"
    all_blobs = list(bucket.list_blobs(prefix=prefix))
    raw_blobs = [b for b in all_blobs if b.name.endswith(".jsonl")]

    if not raw_blobs:
        return {
            "date": date_str,
            "raw_file_count": 0,
            "event_count": 0,
            "skipped": True,
            "aborted": False,
            "uploaded": False,
            "failed_downloads": 0,
        }

    lines: list[str] = []
    failed_downloads = 0
    failed_blob_names: list[str] = []
    max_workers = min(_MAX_PARALLEL_DOWNLOADS, len(raw_blobs))
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        future_to_blob = {pool.submit(download_fn, b): b for b in raw_blobs}
        for future in as_completed(future_to_blob):
            if should_stop is not None and should_stop():
                raise RuntimeError(
                    f"signal export lease lost while merging {date_str}"
                )
            blob = future_to_blob[future]
            try:
                text = future.result()
            except Exception as e:
                failed_downloads += 1
                name = getattr(blob, "name", "?")
                failed_blob_names.append(str(name))
                logger.warning(
                    "[SignalExport] blob 다운로드 최종 실패 %s: %s", name, e
                )
                continue
            if text:
                lines.extend(line for line in text.split("\n") if line.strip())

    # 1+A: 부분 실패본으로 기존 processed를 덮어쓰지 않는다.
    if failed_downloads > 0:
        logger.error(
            "[SignalExport] %s: 다운로드 실패 %d건 — processed 업로드 중단 "
            "(기존 파일 유지). samples=%s",
            date_str,
            failed_downloads,
            failed_blob_names[:5],
        )
        return {
            "date": date_str,
            "raw_file_count": len(raw_blobs),
            "event_count": 0,
            "skipped": False,
            "aborted": True,
            "uploaded": False,
            "failed_downloads": failed_downloads,
            "failed_blob_names": failed_blob_names[:20],
        }

    if not lines:
        return {
            "date": date_str,
            "raw_file_count": len(raw_blobs),
            "event_count": 0,
            "skipped": True,
            "aborted": False,
            "uploaded": False,
            "failed_downloads": 0,
        }

    merged = "\n".join(lines) + "\n"
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
        gz.write(merged.encode("utf-8"))
    payload = buf.getvalue()

    # Hive 파티션 레이아웃(dt=YYYY-MM-DD/파일) — BigQuery 외부 테이블이
    # 이 경로를 파티션 컬럼으로 자동 인식해 날짜 필터 시 스캔 범위를 좁힌다.
    processed_blob = bucket.blob(
        f"{_PROCESSED_PREFIX}/dt={date_str}/events.jsonl.gz"
    )
    processed_blob.upload_from_string(payload, content_type="application/gzip")

    return {
        "date": date_str,
        "raw_file_count": len(raw_blobs),
        "event_count": len(lines),
        "compressed_bytes": len(payload),
        "skipped": False,
        "aborted": False,
        "uploaded": True,
        "failed_downloads": 0,
    }


def _persist_run_result(db: Any, summary: dict[str, Any]) -> None:
    """스케줄 문서와 runs 컬렉션에 실행 요약을 남긴다 (GH Actions 메일용)."""
    run_id = summary.get("runId") or uuid.uuid4().hex
    summary = {**summary, "runId": run_id}
    try:
        db.collection(SCHEDULE_COLLECTION).document(_SCHEDULE_NAME).set(
            {
                "lastRun": summary,
                "updatedAt": admin_firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        db.collection(_RUNS_COLLECTION).document(run_id).set(
            {
                **summary,
                "createdAt": admin_firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
    except Exception:
        logger.exception("[SignalExport] run result persist failed: %s", run_id)
    return


def _build_run_summary(
    *,
    run_id: str,
    started_at: datetime,
    finished_at: datetime,
    lookback_days: int,
    date_results: list[dict[str, Any]],
    error: Optional[str] = None,
) -> dict[str, Any]:
    aborted_dates = [r["date"] for r in date_results if r.get("aborted")]
    uploaded_dates = [r["date"] for r in date_results if r.get("uploaded")]
    skipped_dates = [r["date"] for r in date_results if r.get("skipped")]
    total_events = sum(int(r.get("event_count") or 0) for r in date_results)
    total_files = sum(int(r.get("raw_file_count") or 0) for r in date_results)
    total_failed_downloads = sum(
        int(r.get("failed_downloads") or 0) for r in date_results
    )
    ok = error is None and not aborted_dates
    status = "success" if ok else ("partial_failure" if date_results else "failure")
    if error and not date_results:
        status = "failure"
    return {
        "runId": run_id,
        "ok": ok,
        "status": status,
        "startedAt": started_at.isoformat(),
        "finishedAt": finished_at.isoformat(),
        "lookbackDays": lookback_days,
        "totalRawFiles": total_files,
        "totalEvents": total_events,
        "totalFailedDownloads": total_failed_downloads,
        "uploadedDates": uploaded_dates,
        "skippedDates": skipped_dates,
        "abortedDates": aborted_dates,
        "dates": date_results,
        "error": (error or "")[:1000] or None,
        "bucket": _resolve_bucket_name(),
    }


def run_signal_export_once(
    db: Any,
    *,
    lookback_days: Optional[int] = None,
    bucket: Any = None,
    should_stop: Optional[Callable[[], bool]] = None,
) -> dict[str, Any]:
    """한 번의 export 실행(테스트/수동 호출용). Firestore에 lastRun을 기록한다."""
    days = lookback_days
    if days is None:
        days = max(
            1,
            int(os.getenv("SIGNAL_EXPORT_LOOKBACK_DAYS", str(_DEFAULT_LOOKBACK_DAYS))),
        )
    run_id = uuid.uuid4().hex
    started = datetime.now(timezone.utc)
    date_results: list[dict[str, Any]] = []
    error: Optional[str] = None
    try:
        bkt = bucket if bucket is not None else _get_bucket()
        for date_str in _iter_target_dates(days):
            if should_stop is not None and should_stop():
                raise RuntimeError("signal export stopped before finishing all dates")
            result = _merge_date(bkt, date_str, should_stop=should_stop)
            date_results.append(result)
            if result.get("aborted"):
                logger.error(
                    "[SignalExport] %s aborted (failed_downloads=%s)",
                    date_str,
                    result.get("failed_downloads"),
                )
            elif result.get("skipped"):
                logger.info(
                    "[SignalExport] %s: raw 파일 없음(또는 빈 파일) — 건너뜀",
                    date_str,
                )
            else:
                logger.info(
                    "[SignalExport] %s 취합 완료: raw=%d개, event=%d건, "
                    "gzip=%d bytes, uploaded=%s",
                    date_str,
                    result["raw_file_count"],
                    result["event_count"],
                    result.get("compressed_bytes", 0),
                    result.get("uploaded"),
                )
    except Exception as e:
        error = str(e)
        logger.exception("[SignalExport] 취합 실패: %s", e)

    finished = datetime.now(timezone.utc)
    summary = _build_run_summary(
        run_id=run_id,
        started_at=started,
        finished_at=finished,
        lookback_days=days,
        date_results=date_results,
        error=error,
    )
    if db is not None:
        _persist_run_result(db, summary)
    logger.info(
        "[SignalExport] 이번 실행 총계: status=%s raw=%d개 event=%d건 "
        "failed_downloads=%d aborted=%s",
        summary["status"],
        summary["totalRawFiles"],
        summary["totalEvents"],
        summary["totalFailedDownloads"],
        summary["abortedDates"],
    )
    return summary


def run_signal_export_scheduler(db: Any) -> None:
    """데몬 스레드 진입점. 24시간 주기로 최근 N일 signals를 재취합한다."""
    interval_seconds = max(
        300,
        int(
            os.getenv(
                "SIGNAL_EXPORT_INTERVAL_SECONDS", str(_EXPORT_INTERVAL_SECONDS)
            )
        ),
    )
    lease_seconds = max(
        300,
        int(os.getenv("SIGNAL_EXPORT_LEASE_SECONDS", str(60 * 60))),
    )
    failure_retry_seconds = max(
        60,
        int(os.getenv("SIGNAL_EXPORT_FAILURE_RETRY_SECONDS", "300")),
    )
    lookback_days = max(
        1,
        int(os.getenv("SIGNAL_EXPORT_LOOKBACK_DAYS", str(_DEFAULT_LOOKBACK_DAYS))),
    )

    time.sleep(_INITIAL_DELAY_SECONDS)
    logger.info(
        "[SignalExport] 스케줄러 시작 (주기=%ds, lookback=%d일, download_attempts=%d)",
        interval_seconds,
        lookback_days,
        _download_attempts(),
    )

    while True:
        lease_token: Optional[str] = None
        heartbeat: Optional[ScheduleLeaseHeartbeat] = None
        next_sleep = float(interval_seconds)
        try:
            lease = try_acquire_schedule_lease(
                db,
                _SCHEDULE_NAME,
                interval_seconds=interval_seconds,
                lease_seconds=lease_seconds,
            )
            if not lease.acquired or not lease.token:
                next_sleep = max(60.0, lease.retry_after_seconds)
                logger.info(
                    "[SignalExport] schedule guard로 건너뜀 (retry_after=%.0fs)",
                    next_sleep,
                )
                time.sleep(next_sleep)
                continue

            lease_token = lease.token
            heartbeat = ScheduleLeaseHeartbeat(
                db,
                _SCHEDULE_NAME,
                lease_token,
                lease_seconds=lease_seconds,
            )
            heartbeat.start()

            # 계정 탈퇴 시 비식별이 부분 실패한 건을 재시도.
            try:
                from services.signal_deidentify_service import (
                    process_signal_deidentify_queue,
                )

                deid_queue_stats = process_signal_deidentify_queue(db, limit=20)
                if deid_queue_stats.get("scanned"):
                    logger.info(
                        "[SignalExport] deidentify queue: %s", deid_queue_stats
                    )
            except Exception:
                logger.exception("[SignalExport] deidentify queue processing failed")

            summary = run_signal_export_once(
                db,
                lookback_days=lookback_days,
                should_stop=lambda: (
                    heartbeat is not None and heartbeat.lease_lost
                ),
            )

            heartbeat.stop()
            heartbeat = None

            if summary.get("ok"):
                if not complete_schedule_lease(db, _SCHEDULE_NAME, lease_token):
                    logger.warning(
                        "[SignalExport] lease 완료 처리를 건너뜀 "
                        "(token no longer current)"
                    )
            else:
                # 부분 실패/예외: 짧은 재시도 간격으로 다시 시도
                # (lookback이 있어 성공 날짜는 멱등 재취합).
                next_sleep = float(failure_retry_seconds)
                fail_schedule_lease(
                    db,
                    _SCHEDULE_NAME,
                    lease_token,
                    summary.get("error")
                    or f"aborted_dates={summary.get('abortedDates')}",
                )
        except Exception as e:
            logger.exception("[SignalExport] 취합 실패: %s", e)
            next_sleep = float(failure_retry_seconds)
            if heartbeat:
                heartbeat.stop()
            if lease_token:
                try:
                    fail_schedule_lease(db, _SCHEDULE_NAME, lease_token, str(e))
                except Exception:
                    logger.exception("[SignalExport] schedule lease 해제 실패")
                try:
                    finished = datetime.now(timezone.utc)
                    _persist_run_result(
                        db,
                        _build_run_summary(
                            run_id=uuid.uuid4().hex,
                            started_at=finished,
                            finished_at=finished,
                            lookback_days=lookback_days,
                            date_results=[],
                            error=str(e),
                        ),
                    )
                except Exception:
                    logger.exception("[SignalExport] failure summary persist failed")

        time.sleep(max(60.0, next_sleep))
