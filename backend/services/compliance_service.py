"""
Compliance automation service.

Provides:
- Account deletion with expanded data scope cleanup.
- Underage account cleanup queue with retry metadata.
- Daily scheduler loop for automatic enforcement.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass, field
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from typing import Any, Callable, Dict, Optional
from zoneinfo import ZoneInfo

from firebase_admin import auth as firebase_auth
from firebase_admin import firestore as admin_firestore
from google.cloud.firestore_v1 import FieldFilter
from google.api_core.exceptions import FailedPrecondition
from utils.firestore_schedule_guard import (
    ScheduleLeaseHeartbeat,
    complete_schedule_lease,
    fail_schedule_lease,
    try_acquire_schedule_lease,
)

logger = logging.getLogger(__name__)

KST = ZoneInfo("Asia/Seoul")
MIN_SIGNUP_AGE = 14
QUEUE_COLLECTION = "underage_cleanup_queue"
RUN_LOG_COLLECTION = "underage_cleanup_runs"
ACCOUNT_DELETION_LOG_COLLECTION = "account_deletion_audit_logs"
DEFAULT_SCHEDULER_INTERVAL_SECONDS = 24 * 60 * 60
UNDERAGE_SCHEDULE_NAME = "underage_cleanup"

# 유저 스캔 커서 저장 위치. 매일 항상 문서 저장 순서 앞쪽 scan_limit 명만
# 스캔하던 편향(coverage bias)을 없애기 위해, 마지막으로 스캔한 문서 ID를
# 기억해뒀다가 다음 실행에서 이어서 스캔한다. 끝까지 도달하면 처음으로
# 되돌아간다(rotation). 가입 시 age gate(만 14세 미만 차단)가 이미 적용되어
# 있으므로 이 스캔은 우회 가입/레거시 계정을 잡아내는 2차 안전망이다.
SCAN_CURSOR_COLLECTION = "system_scan_cursors"
SCAN_CURSOR_DOC_ID = "underage_cleanup"


@dataclass
class AccountDeletionSummary:
    uid: str
    deleted: bool
    legal_hold_applied: bool = False
    deleted_counts: Dict[str, int] = field(default_factory=dict)
    message: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return {
            "uid": self.uid,
            "deleted": self.deleted,
            "legal_hold_applied": self.legal_hold_applied,
            "deleted_counts": self.deleted_counts,
            "message": self.message,
        }


def _increment(counter: Dict[str, int], key: str, amount: int = 1) -> None:
    counter[key] = counter.get(key, 0) + amount


_FIRESTORE_BATCH_LIMIT = 400


def _commit_delete_batch(db, refs: list) -> int:
    """refs를 배치로 나눠 삭제. 성공한 삭제 개수 반환."""
    deleted = 0
    batch = db.batch()
    ops = 0
    for ref in refs:
        batch.delete(ref)
        ops += 1
        deleted += 1
        if ops >= _FIRESTORE_BATCH_LIMIT:
            batch.commit()
            batch = db.batch()
            ops = 0
    if ops:
        batch.commit()
    return deleted


def _delete_query_docs(
    db,
    query,
    deleted_counts: Dict[str, int],
    counter_key: str,
) -> None:
    """쿼리 결과를 배치 삭제로 지운다 (문서당 개별 delete 대비 대폭 단축)."""
    refs = [doc.reference for doc in query.stream()]
    if not refs:
        return
    n = _commit_delete_batch(db, refs)
    _increment(deleted_counts, counter_key, n)


def _calculate_age_in_kst(birth_date: date) -> int:
    today = datetime.now(KST).date()
    return today.year - birth_date.year - ((today.month, today.day) < (birth_date.month, birth_date.day))


def _parse_birth_date(raw_value: object) -> Optional[date]:
    if not isinstance(raw_value, str):
        return None
    try:
        return date.fromisoformat(raw_value.strip())
    except ValueError:
        return None


def _delete_user_subcollection(
    db,
    uid: str,
    subcollection_name: str,
    deleted_counts: Dict[str, int],
) -> None:
    query = db.collection("users").document(uid).collection(subcollection_name)
    _delete_query_docs(db, query, deleted_counts, f"user.{subcollection_name}")


def _delete_reviews_and_nested_comments(db, uid: str, deleted_counts: Dict[str, int]) -> None:
    review_docs = list(
        db.collection("reviews").where(filter=FieldFilter("userId", "==", uid)).stream()
    )
    comment_refs = []
    review_refs = []
    for review_doc in review_docs:
        review_ref = review_doc.reference
        for comment_doc in review_ref.collection("comments").stream():
            comment_refs.append(comment_doc.reference)
        review_refs.append(review_ref)
    if comment_refs:
        n = _commit_delete_batch(db, comment_refs)
        _increment(deleted_counts, "reviews.comments", n)
    if review_refs:
        n = _commit_delete_batch(db, review_refs)
        _increment(deleted_counts, "reviews", n)


def _delete_user_comments_across_reviews(db, uid: str, deleted_counts: Dict[str, int]) -> None:
    review_comment_delta = defaultdict(int)
    try:
        comment_docs = list(
            db.collection_group("comments")
            .where(filter=FieldFilter("userId", "==", uid))
            .stream()
        )
        refs = []
        for comment_doc in comment_docs:
            parent_review_ref = comment_doc.reference.parent.parent
            refs.append(comment_doc.reference)
            if parent_review_ref is not None:
                review_comment_delta[parent_review_ref] += 1
        if refs:
            n = _commit_delete_batch(db, refs)
            _increment(deleted_counts, "reviews.comments", n)
    except FailedPrecondition as exc:
        # 컬렉션 그룹 인덱스가 없으면 전체 reviews 스캔은 수십 초~분 단위로
        # 계정 삭제 API를 타임아웃시킨다. 계정 삭제 자체는 막지 않고 스킵한다.
        logger.warning(
            "[Compliance] comments collection-group index missing; "
            "skipping cross-review comment cleanup for uid=%s (reason=%s)",
            uid,
            exc,
        )
        return

    for review_ref, removed_count in review_comment_delta.items():
        try:
            review_ref.update(
                {
                    "commentCount": admin_firestore.Increment(-removed_count),
                    "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                }
            )
        except Exception:
            # Parent review might have been deleted in parallel paths; best effort only.
            pass


def _delete_by_field(
    db,
    collection_name: str,
    field_name: str,
    field_value: str,
    deleted_counts: Dict[str, int],
) -> None:
    query = db.collection(collection_name).where(
        filter=FieldFilter(field_name, "==", field_value)
    )
    _delete_query_docs(db, query, deleted_counts, collection_name)


def _delete_user_handles(db, uid: str, deleted_counts: Dict[str, int]) -> None:
    query = db.collection("user_handles").where(filter=FieldFilter("uid", "==", uid))
    _delete_query_docs(db, query, deleted_counts, "user_handles")


def _delete_kakao_links(db, uid: str, deleted_counts: Dict[str, int]) -> None:
    query = db.collection("kakaoLinks").where(filter=FieldFilter("uid", "==", uid))
    _delete_query_docs(db, query, deleted_counts, "kakaoLinks")


def _resolve_account_created_date(uid: str, user_data: Dict[str, Any]) -> Optional[str]:
    """계정 생성일(``YYYY-MM-DD``, UTC 근사치)을 최대한 신뢰성 있게 추정한다.

    signal_deidentify_service가 이 값으로 GCS 스캔 범위를 좁혀 탈퇴 1건당
    비용을 "전체 히스토리"가 아니라 "이 유저의 활동 기간"에 비례하게
    만든다. Firebase Auth의 creation_timestamp는 앱 코드와 무관하게 모든
    계정에 항상 존재하므로 1순위로 쓰고, 조회 실패 시에만 Firestore
    ``users/{uid}.createdAt``으로 폴백한다. 둘 다 없으면 None — 호출부는
    None을 받으면 안전하게 전체 스캔으로 폴백한다(비용보다 정확성 우선).
    """
    try:
        auth_user = firebase_auth.get_user(uid)
        creation_ms = getattr(auth_user.user_metadata, "creation_timestamp", None)
        if creation_ms:
            return (
                datetime.fromtimestamp(creation_ms / 1000.0, tz=timezone.utc)
                .date()
                .isoformat()
            )
    except Exception as e:
        logger.warning(
            "[Compliance] Firebase Auth 계정 생성일 조회 실패 uid=%s: %s", uid, e
        )

    created_at = user_data.get("createdAt")
    if isinstance(created_at, datetime):
        return created_at.date().isoformat()
    return None


def _cleanup_user_community_social(
    db,
    uid: str,
    deleted_counts: Dict[str, int],
) -> None:
    """계정 삭제 시 모임·챌린지 잔여 데이터를 best-effort로 정리한다.

    실패해도 계정 삭제 자체는 계속 진행한다.
    """
    try:
        hosted = list(
            db.collection("meetups")
            .where(filter=FieldFilter("hostId", "==", uid))
            .stream()
        )
        for doc in hosted:
            try:
                doc.reference.update(
                    {
                        "cancelled": True,
                        "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                    }
                )
                _increment(deleted_counts, "meetups.cancelled")
            except Exception as exc:
                logger.warning(
                    "[Compliance] meetup cancel failed uid=%s meetup=%s: %s",
                    uid,
                    doc.id,
                    exc,
                )
    except Exception as exc:
        logger.warning(
            "[Compliance] hosted meetup cleanup failed uid=%s: %s", uid, exc
        )

    try:
        attendee_docs = list(
            db.collection_group("attendees")
            .where(filter=FieldFilter("uid", "==", uid))
            .stream()
        )
        for attendee_doc in attendee_docs:
            try:
                data = attendee_doc.to_dict() or {}
                meetup_ref = attendee_doc.reference.parent.parent
                if meetup_ref is not None and data.get("status") == "joined":
                    try:
                        meetup_ref.update(
                            {
                                "memberCount": admin_firestore.Increment(-1),
                                "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                            }
                        )
                    except Exception:
                        pass
                attendee_doc.reference.delete()
                _increment(deleted_counts, "meetups.attendees")
            except Exception as exc:
                logger.warning(
                    "[Compliance] attendee cleanup failed uid=%s: %s", uid, exc
                )
    except FailedPrecondition as exc:
        logger.warning(
            "[Compliance] attendees collection-group index missing; "
            "skipping meetup leave cleanup for uid=%s (reason=%s)",
            uid,
            exc,
        )
    except Exception as exc:
        logger.warning(
            "[Compliance] attendee collection-group cleanup failed uid=%s: %s",
            uid,
            exc,
        )

    try:
        created = list(
            db.collection("challenges")
            .where(filter=FieldFilter("createdBy", "==", uid))
            .stream()
        )
        for doc in created:
            data = doc.to_dict() or {}
            if data.get("kind") != "friend":
                continue
            try:
                doc.reference.update(
                    {
                        "cancelled": True,
                        "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                    }
                )
                _increment(deleted_counts, "challenges.cancelled")
            except Exception as exc:
                logger.warning(
                    "[Compliance] friend challenge cancel failed uid=%s id=%s: %s",
                    uid,
                    doc.id,
                    exc,
                )
            code = str(data.get("inviteCode") or "").strip()
            if code:
                try:
                    db.collection("challenge_invite_codes").document(code).delete()
                    _increment(deleted_counts, "challenge_invite_codes")
                except Exception as exc:
                    logger.warning(
                        "[Compliance] invite code delete failed uid=%s code=%s: %s",
                        uid,
                        code,
                        exc,
                    )
    except Exception as exc:
        logger.warning(
            "[Compliance] friend challenge cleanup failed uid=%s: %s", uid, exc
        )

    try:
        participant_docs = list(
            db.collection_group("participants")
            .where(filter=FieldFilter("uid", "==", uid))
            .stream()
        )
        for participant_doc in participant_docs:
            try:
                challenge_ref = participant_doc.reference.parent.parent
                if challenge_ref is not None:
                    try:
                        challenge_ref.update(
                            {
                                "participantCount": admin_firestore.Increment(-1),
                                "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                            }
                        )
                    except Exception:
                        pass
                participant_doc.reference.delete()
                _increment(deleted_counts, "challenges.participants")
            except Exception as exc:
                logger.warning(
                    "[Compliance] participant cleanup failed uid=%s: %s",
                    uid,
                    exc,
                )
    except FailedPrecondition as exc:
        logger.warning(
            "[Compliance] participants collection-group index missing; "
            "skipping challenge leave cleanup for uid=%s (reason=%s)",
            uid,
            exc,
        )
    except Exception as exc:
        logger.warning(
            "[Compliance] participant collection-group cleanup failed uid=%s: %s",
            uid,
            exc,
        )

    try:
        _delete_user_subcollection(
            db, uid, "challengeMemberships", deleted_counts
        )
    except Exception as exc:
        logger.warning(
            "[Compliance] challengeMemberships cleanup failed uid=%s: %s",
            uid,
            exc,
        )


def delete_user_account_and_data(
    db,
    uid: str,
    reason: str,
    requested_by: str,
) -> AccountDeletionSummary:
    """
    Deletes user-linked data with broader scope than client-side deletion.

    Legal hold:
    - If users/{uid}.deletionLegalHold == true, account is not deleted.
    """
    deleted_counts: Dict[str, int] = {}
    user_ref = db.collection("users").document(uid)
    user_doc = user_ref.get()
    user_data = user_doc.to_dict() if user_doc.exists else {}

    if user_data.get("deletionLegalHold") is True:
        summary = AccountDeletionSummary(
            uid=uid,
            deleted=False,
            legal_hold_applied=True,
            deleted_counts={},
            message="법령상 보존 사유(deletionLegalHold)로 삭제 보류",
        )
        db.collection(ACCOUNT_DELETION_LOG_COLLECTION).add(
            {
                **summary.as_dict(),
                "reason": reason,
                "requestedBy": requested_by,
                "createdAt": admin_firestore.SERVER_TIMESTAMP,
            }
        )
        return summary

    _delete_user_subcollection(db, uid, "mealPlans", deleted_counts)
    _delete_user_subcollection(db, uid, "notifications", deleted_counts)
    _delete_user_subcollection(db, uid, "fcmTokens", deleted_counts)

    _delete_by_field(db, "recipes", "userId", uid, deleted_counts)
    _delete_reviews_and_nested_comments(db, uid, deleted_counts)
    _delete_user_comments_across_reviews(db, uid, deleted_counts)
    _delete_by_field(db, "follows", "followerId", uid, deleted_counts)
    _delete_by_field(db, "follows", "followingId", uid, deleted_counts)
    _delete_by_field(db, "reports", "reporterId", uid, deleted_counts)
    _delete_user_handles(db, uid, deleted_counts)
    _delete_kakao_links(db, uid, deleted_counts)
    try:
        _cleanup_user_community_social(db, uid, deleted_counts)
    except Exception as exc:
        logger.exception(
            "[Compliance] community social cleanup raised for uid=%s: %s",
            uid,
            exc,
        )

    # 행동 시그널(GCS): 삭제하지 않고 비식별. 실패해도 계정 삭제는 계속 진행하고
    # signal_deidentify_queue에 남겨 스케줄러가 재시도한다.
    try:
        from services.signal_deidentify_service import deidentify_user_signals

        account_created_date = _resolve_account_created_date(uid, user_data)
        deid_stats = deidentify_user_signals(
            uid,
            db=db,
            reason=reason,
            enqueue_on_failure=True,
            account_created_date=account_created_date,
        )
        _increment(
            deleted_counts,
            "signals.deidentified_events",
            int(deid_stats.get("raw_events_deidentified") or 0)
            + int(deid_stats.get("processed_events_deidentified") or 0),
        )
        if not deid_stats.get("ok"):
            _increment(deleted_counts, "signals.deidentify_queued_retry")
            logger.warning(
                "[Compliance] signal deidentify incomplete for uid=%s stats=%s",
                uid,
                deid_stats,
            )
    except Exception as exc:
        _increment(deleted_counts, "signals.deidentify_error")
        logger.exception(
            "[Compliance] signal deidentify raised for uid=%s: %s", uid, exc
        )

    if user_doc.exists:
        user_ref.delete()
        _increment(deleted_counts, "users")

    try:
        firebase_auth.delete_user(uid)
    except Exception as exc:
        # If auth user already disappeared, we still treat data deletion as successful.
        logger.warning("Auth delete failed for uid=%s: %s", uid, exc)

    summary = AccountDeletionSummary(
        uid=uid,
        deleted=True,
        legal_hold_applied=False,
        deleted_counts=deleted_counts,
        message="사용자 데이터 삭제 완료(행동 시그널은 비식별 후 보관)",
    )
    db.collection(ACCOUNT_DELETION_LOG_COLLECTION).add(
        {
            **summary.as_dict(),
            "reason": reason,
            "requestedBy": requested_by,
            "createdAt": admin_firestore.SERVER_TIMESTAMP,
        }
    )
    return summary


def _load_scan_cursor(db) -> Optional[str]:
    """마지막으로 스캔을 마친 유저 문서 ID를 읽는다. 없으면 None(처음부터)."""
    try:
        doc = db.collection(SCAN_CURSOR_COLLECTION).document(SCAN_CURSOR_DOC_ID).get()
    except Exception:
        return None
    if not doc.exists:
        return None
    value = (doc.to_dict() or {}).get("lastScannedUserId")
    return value if isinstance(value, str) and value else None


def _save_scan_cursor(db, last_id: Optional[str]) -> None:
    """다음 실행이 이어서 스캔할 위치를 저장한다. None이면 처음부터 다시 순회."""
    db.collection(SCAN_CURSOR_COLLECTION).document(SCAN_CURSOR_DOC_ID).set(
        {
            "lastScannedUserId": last_id,
            "updatedAt": admin_firestore.SERVER_TIMESTAMP,
        }
    )


def _upsert_underage_queue_item(
    db,
    uid: str,
    age: int,
    birth_date: str,
    source: str,
) -> None:
    queue_ref = db.collection(QUEUE_COLLECTION).document(uid)
    existing_snap = queue_ref.get()
    existing = existing_snap.to_dict() if existing_snap.exists else {}
    existing_status = str(existing.get("status") or "").strip().lower()
    if existing_status in {"legal_hold", "completed"}:
        return
    retry_count = int(existing.get("retryCount") or 0)
    queue_ref.set(
        {
            "uid": uid,
            "age": age,
            "birthDate": birth_date,
            "source": source,
            "status": "pending" if existing_status != "retry" else "retry",
            "retryCount": retry_count,
            "lastError": existing.get("lastError"),
            "detectedAt": existing.get("detectedAt") or admin_firestore.SERVER_TIMESTAMP,
            "updatedAt": admin_firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )


def process_underage_cleanup_batch(
    db,
    scan_limit: int = 1000,
    queue_process_limit: int = 300,
    should_stop: Optional[Callable[[], bool]] = None,
) -> Dict[str, Any]:
    """
    1) Scan users (커서 기반 rotation으로 매일 이어서 스캔, 끝까지 가면 처음부터
       다시 순회 — 문서 저장 순서 앞쪽만 영원히 스캔하는 편향을 방지) and
       queue under-14 candidates.
    2) Process queue with retry metadata.
    """
    scanned = 0
    queued = 0
    deleted = 0
    legal_hold = 0
    retried = 0
    failed = 0

    cursor_id = _load_scan_cursor(db)
    scan_query = db.collection("users").order_by("__name__").limit(scan_limit)
    if cursor_id:
        cursor_snap = db.collection("users").document(cursor_id).get()
        if cursor_snap.exists:
            scan_query = scan_query.start_after(cursor_snap)
        # cursor_snap이 이미 삭제된 계정이면 그냥 처음부터 다시 스캔한다.

    scanned_docs = list(scan_query.stream())
    for user_doc in scanned_docs:
        if should_stop is not None and should_stop():
            raise RuntimeError("underage cleanup lease lost during user scan")
        scanned += 1
        data = user_doc.to_dict() or {}
        parsed_birth_date = _parse_birth_date(data.get("birthDate"))
        if parsed_birth_date is None:
            continue
        age = _calculate_age_in_kst(parsed_birth_date)
        if age >= MIN_SIGNUP_AGE:
            continue
        _upsert_underage_queue_item(
            db=db,
            uid=user_doc.id,
            age=age,
            birth_date=parsed_birth_date.isoformat(),
            source="daily_scan",
        )
        queued += 1

    # 이번 페이지가 scan_limit보다 적게 나왔다면 전체 유저를 다 훑은 것이므로
    # 다음 실행은 처음부터 다시 시작한다(rotation). 그렇지 않으면 마지막 문서
    # ID를 커서로 저장해 다음 실행이 이어서 스캔하게 한다.
    if scanned_docs and len(scanned_docs) >= scan_limit:
        _save_scan_cursor(db, scanned_docs[-1].id)
    else:
        _save_scan_cursor(db, None)

    queue_docs = (
        db.collection(QUEUE_COLLECTION)
        .where(filter=FieldFilter("status", "in", ["pending", "retry"]))
        .limit(queue_process_limit)
        .stream()
    )
    for queue_doc in queue_docs:
        if should_stop is not None and should_stop():
            raise RuntimeError("underage cleanup lease lost during queue processing")
        q = queue_doc.to_dict() or {}
        uid = str(q.get("uid") or "").strip()
        if not uid:
            continue

        next_retry_at = q.get("nextRetryAt")
        if hasattr(next_retry_at, "timestamp"):
            retry_due_at = datetime.fromtimestamp(next_retry_at.timestamp())
            if retry_due_at > datetime.utcnow():
                continue

        retry_count = int(q.get("retryCount") or 0)
        try:
            summary = delete_user_account_and_data(
                db=db,
                uid=uid,
                reason="underage_policy_enforcement",
                requested_by="underage_cleanup_scheduler",
            )
            if summary.legal_hold_applied:
                legal_hold += 1
                queue_doc.reference.set(
                    {
                        "status": "legal_hold",
                        "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                        "lastError": summary.message,
                    },
                    merge=True,
                )
                continue

            deleted += 1
            queue_doc.reference.set(
                {
                    "status": "completed",
                    "completedAt": admin_firestore.SERVER_TIMESTAMP,
                    "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                },
                merge=True,
            )
        except Exception as exc:
            failed += 1
            retry_count += 1
            backoff_minutes = min(240, 2 ** min(retry_count, 8))
            next_retry_at = datetime.utcnow() + timedelta(minutes=backoff_minutes)
            queue_doc.reference.set(
                {
                    "status": "retry",
                    "retryCount": retry_count,
                    "lastError": str(exc)[:500],
                    "nextRetryAt": next_retry_at,
                    "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                },
                merge=True,
            )
            retried += 1

    run_payload = {
        "scanned": scanned,
        "queued": queued,
        "deleted": deleted,
        "legalHold": legal_hold,
        "retried": retried,
        "failed": failed,
        "createdAt": admin_firestore.SERVER_TIMESTAMP,
    }
    db.collection(RUN_LOG_COLLECTION).add(run_payload)
    return run_payload


def run_underage_cleanup_scheduler(db) -> None:
    """
    Daemon loop for underage account cleanup.
    """
    interval_seconds = int(
        os.getenv("UNDERAGE_CLEANUP_INTERVAL_SECONDS", str(DEFAULT_SCHEDULER_INTERVAL_SECONDS))
    )
    scan_limit = int(os.getenv("UNDERAGE_CLEANUP_SCAN_LIMIT", "1000"))
    queue_limit = int(os.getenv("UNDERAGE_CLEANUP_QUEUE_LIMIT", "300"))
    lease_seconds = max(
        300,
        int(os.getenv("UNDERAGE_CLEANUP_LEASE_SECONDS", str(2 * 60 * 60))),
    )
    failure_retry_seconds = max(
        60,
        int(os.getenv("UNDERAGE_CLEANUP_FAILURE_RETRY_SECONDS", "300")),
    )

    logger.info(
        "[Compliance] Underage cleanup scheduler started (interval=%ss, scan_limit=%s, queue_limit=%s)",
        interval_seconds,
        scan_limit,
        queue_limit,
    )

    while True:
        lease_token: Optional[str] = None
        heartbeat: Optional[ScheduleLeaseHeartbeat] = None
        next_sleep = float(interval_seconds)
        try:
            lease = try_acquire_schedule_lease(
                db,
                UNDERAGE_SCHEDULE_NAME,
                interval_seconds=interval_seconds,
                lease_seconds=lease_seconds,
            )
            if not lease.acquired or not lease.token:
                next_sleep = max(60.0, lease.retry_after_seconds)
                logger.info(
                    "[Compliance] Underage cleanup skipped by schedule guard "
                    "(retry_after=%.0fs)",
                    next_sleep,
                )
                time.sleep(next_sleep)
                continue

            lease_token = lease.token
            heartbeat = ScheduleLeaseHeartbeat(
                db,
                UNDERAGE_SCHEDULE_NAME,
                lease_token,
                lease_seconds=lease_seconds,
            )
            heartbeat.start()
            result = process_underage_cleanup_batch(
                db=db,
                scan_limit=scan_limit,
                queue_process_limit=queue_limit,
                should_stop=lambda: heartbeat is not None and heartbeat.lease_lost,
            )
            heartbeat.stop()
            heartbeat = None
            if not complete_schedule_lease(db, UNDERAGE_SCHEDULE_NAME, lease_token):
                logger.warning(
                    "[Compliance] Underage cleanup lease completion skipped "
                    "(token no longer current)"
                )
            logger.info("[Compliance] Underage cleanup run result: %s", result)
        except Exception as exc:
            logger.exception("[Compliance] Underage cleanup run failed: %s", exc)
            next_sleep = float(failure_retry_seconds)
            if heartbeat:
                heartbeat.stop()
            if lease_token:
                try:
                    fail_schedule_lease(
                        db,
                        UNDERAGE_SCHEDULE_NAME,
                        lease_token,
                        str(exc),
                    )
                except Exception:
                    logger.exception("[Compliance] Failed to release schedule lease")
        time.sleep(max(60.0, next_sleep))
