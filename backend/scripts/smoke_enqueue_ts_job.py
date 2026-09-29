"""배포 후 수동 스모크 테스트: 실제 Firestore 큐에 타임스탬프 잡 1건을 넣고

새 process-per-slot 워커(process_supervisor가 띄운 timestamp-0/1)가
claim → 처리 → done/failed로 마무리하는지 확인한다.

Usage:
    cd backend
    python Scripts/smoke_enqueue_ts_job.py
"""

from __future__ import annotations

import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_BACKEND = os.path.dirname(_HERE)
if _BACKEND not in sys.path:
    sys.path.insert(0, _BACKEND)

from services.firebase_service import get_firebase_service  # noqa: E402
from services.timestamp_queue import enqueue_timestamp_job  # noqa: E402


def main() -> int:
    fb = get_firebase_service()
    db = fb.db

    video_id = "Eu5zpddy0kg"  # 짧은(19s) 이전 검증 영상 재사용
    url = f"https://www.youtube.com/watch?v={video_id}"
    source_key = f"youtube:{video_id}"

    ok = enqueue_timestamp_job(
        platform="youtube",
        url=url,
        recipe={"steps": [{"text": "재료를 준비합니다"}, {"text": "끓입니다"}]},
        duration_sec=19,
        source_key=source_key,
        db=db,
    )
    print(f"enqueue ok={ok} source_key={source_key}")
    if not ok:
        return 1

    doc_id = source_key.replace("/", "_").replace(":", "_")
    doc_ref = db.collection("timestamp_jobs").document(doc_id)

    deadline = time.monotonic() + 120.0
    last_status = None
    while time.monotonic() < deadline:
        snap = doc_ref.get()
        data = snap.to_dict() or {}
        status = data.get("status")
        if status != last_status:
            print(
                f"t+{120.0 - (deadline - time.monotonic()):.0f}s status={status} "
                f"claimedBy={data.get('claimedBy')} attempts={data.get('attempts')}"
            )
            last_status = status
        if status in ("done", "failed"):
            print("error:", data.get("error"))
            return 0
        time.sleep(2)

    print("TIMEOUT waiting for job to finish")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
