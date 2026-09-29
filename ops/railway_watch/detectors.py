"""규칙 기반 Railway 이상 감지기 (자동 수정 없음)."""

from __future__ import annotations

from typing import Any, Dict, List

from .collect import summarize_log_signals


Finding = Dict[str, Any]


def _finding(
    rule_id: str,
    severity: str,
    title: str,
    detail: str,
    evidence: List[str] | None = None,
) -> Finding:
    return {
        "rule_id": rule_id,
        "severity": severity,  # ok | info | warning | critical
        "title": title,
        "detail": detail,
        "evidence": evidence or [],
    }


def detect(snapshot: Dict[str, Any]) -> List[Finding]:
    """스냅샷에서 규칙 매칭 결과 목록을 반환한다."""
    findings: List[Finding] = []
    logs: List[str] = list(snapshot.get("logs") or [])
    signals = summarize_log_signals(logs)
    snapshot["log_signals"] = signals

    # 1) 배포 상태
    # SKIPPED(watched files 변경 없음)는 실패가 아니므로, 최근 SUCCESS를 같이 본다.
    deployments = list(snapshot.get("deployments") or [])
    if deployments:
        latest = deployments[0]
        status = (latest.get("status") or "").upper()
        latest_success = next(
            (
                d
                for d in deployments
                if (d.get("status") or "").upper() in ("SUCCESS", "RUNNING", "ACTIVE")
            ),
            None,
        )
        if status in ("SUCCESS", "RUNNING", "ACTIVE"):
            findings.append(
                _finding(
                    "deploy_ok",
                    "ok",
                    "최근 배포 정상",
                    f"status={status} commit={latest.get('commitHash')} msg={latest.get('commitMessage')}",
                )
            )
        elif status == "SKIPPED" and latest_success is not None:
            findings.append(
                _finding(
                    "deploy_ok",
                    "ok",
                    "최근 배포 정상(후속 커밋은 SKIPPED)",
                    (
                        f"latest={status} commit={latest.get('commitHash')}; "
                        f"last_success={latest_success.get('commitHash')} "
                        f"msg={latest_success.get('commitMessage')}"
                    ),
                )
            )
        elif status == "SKIPPED":
            findings.append(
                _finding(
                    "deploy_skipped_only",
                    "warning",
                    "최근 배포가 SKIPPED뿐임",
                    f"status={status} commit={latest.get('commitHash')} msg={latest.get('commitMessage')}",
                    [str(latest)],
                )
            )
        else:
            findings.append(
                _finding(
                    "deploy_not_success",
                    "critical",
                    "최근 배포가 SUCCESS가 아님",
                    f"status={status} commit={latest.get('commitHash')} msg={latest.get('commitMessage')}",
                    [str(latest)],
                )
            )
    else:
        findings.append(
            _finding("deploy_unknown", "warning", "배포 목록을 가져오지 못함", "deployments empty")
        )

    # 2) 헬스
    health = snapshot.get("health") or {}
    if health.get("ok"):
        findings.append(
            _finding("health_ok", "ok", "/health 정상", f"status={health.get('status')}")
        )
    else:
        findings.append(
            _finding(
                "health_fail",
                "critical",
                "/health 실패",
                str(health),
            )
        )

    # 3) 스레드 고갈 / STUCK / Watchdog
    if signals["thread_exhaust"] > 0:
        findings.append(
            _finding(
                "thread_exhaustion",
                "critical",
                "can't start new thread 감지",
                f"count={signals['thread_exhaust']}",
            )
        )
    if signals["stuck"] > 0:
        findings.append(
            _finding("stuck_marker", "critical", "STUCK 마커 감지", f"count={signals['stuck']}")
        )
    if signals["watchdog"] > 0:
        findings.append(
            _finding("watchdog", "warning", "Watchdog 로그 감지", f"count={signals['watchdog']}")
        )

    # 4) 타임스탬프 큐 정체
    queue = snapshot.get("queue") or {}
    counts = queue.get("counts") or {}
    pending = int(counts.get("pending") or 0)
    processing = int(counts.get("processing") or 0)
    if queue.get("ok"):
        if pending > 0 and processing == 0 and signals["claims"] == 0:
            findings.append(
                _finding(
                    "timestamp_queue_stalled",
                    "critical",
                    "타임스탬프 큐 정체 의심",
                    f"pending={pending} processing={processing} claims_in_logs={signals['claims']}",
                )
            )
        elif pending + processing > 20:
            findings.append(
                _finding(
                    "timestamp_queue_backlog",
                    "warning",
                    "타임스탬프 큐 백로그",
                    f"pending={pending} processing={processing}",
                )
            )
        else:
            findings.append(
                _finding(
                    "timestamp_queue_ok",
                    "ok",
                    "타임스탬프 큐 정상 범위",
                    f"pending={pending} processing={processing} claims_in_logs={signals['claims']}",
                )
            )
        yt = queue.get("youtube_cdn") or {}
        findings.append(
            _finding(
                "youtube_cdn_enqueue",
                "info",
                "YouTube CDN 적재 샘플",
                (
                    f"sampled_youtube={yt.get('sampled_youtube')} "
                    f"with_cdn={yt.get('sampled_youtube_with_cdn')} "
                    f"active_yt_cdn={yt.get('with_cdn')}/{yt.get('without_cdn')}"
                ),
                [str(x) for x in (yt.get("recent_sample") or [])],
            )
        )
    else:
        findings.append(
            _finding(
                "timestamp_queue_unknown",
                "warning",
                "Firestore 큐 조회 실패",
                str(queue.get("error")),
            )
        )

    # 5) CDN 재사용 / 예산
    if signals["yt_cdn_true"] or signals["ig_cdn_true"]:
        findings.append(
            _finding(
                "cdn_reuse_active",
                "ok",
                "CDN 재사용 동작 확인",
                f"yt_true={signals['yt_cdn_true']} ig_true={signals['ig_cdn_true']} yt_false={signals['yt_cdn_false']}",
            )
        )
    if signals["budget_exceeded"] >= 5:
        findings.append(
            _finding(
                "budget_pressure",
                "warning",
                "예산/budget 관련 로그 다수",
                f"count={signals['budget_exceeded']}",
            )
        )

    # 6) HTTP 5xx
    http = snapshot.get("http") or {}
    status_counts = http.get("status_counts") or {}
    total = int(http.get("total") or 0)
    five_xx = sum(int(v) for k, v in status_counts.items() if str(k).startswith("5"))
    if http.get("ok") and total > 0:
        ratio = five_xx / total
        if five_xx >= 10 and ratio >= 0.05:
            findings.append(
                _finding(
                    "http_5xx_spike",
                    "critical",
                    "HTTP 5xx 비율 높음",
                    f"5xx={five_xx}/{total} ({ratio:.1%})",
                    list(http.get("sample_5xx") or []),
                )
            )
        elif five_xx > 0:
            findings.append(
                _finding(
                    "http_5xx_present",
                    "warning",
                    "HTTP 5xx 일부 발생",
                    f"5xx={five_xx}/{total}",
                    list(http.get("sample_5xx") or []),
                )
            )
        else:
            findings.append(
                _finding("http_ok", "ok", "HTTP 5xx 없음", f"total={total}")
            )

    # 7) Traceback
    if signals["traceback"] >= 3:
        findings.append(
            _finding(
                "traceback_many",
                "warning",
                "Traceback 다수",
                f"count={signals['traceback']}",
            )
        )

    # 수집 자체 오류
    for err in snapshot.get("errors") or []:
        findings.append(
            _finding("collect_error", "warning", "수집 단계 오류", str(err))
        )

    if not findings:
        findings.append(
            _finding("no_signals", "info", "특이 신호 없음", "규칙 매칭 결과 없음")
        )
    return findings


def overall_severity(findings: List[Finding]) -> str:
    """종합 심각도. info는 관찰용이라 종합을 올리지 않는다(ok로 취급)."""
    order = {"ok": 0, "info": 0, "warning": 2, "critical": 3}
    level = 0
    for f in findings:
        level = max(level, order.get(f.get("severity") or "info", 0))
    if level >= 3:
        return "critical"
    if level >= 2:
        return "warning"
    return "ok"


def render_report(snapshot: Dict[str, Any], findings: List[Finding]) -> tuple[str, str]:
    """이메일 subject/body 생성."""
    sev = overall_severity(findings)
    label = {"ok": "정상", "info": "관찰", "warning": "주의", "critical": "이상"}.get(sev, "관찰")
    collected = snapshot.get("collected_at") or ""
    subject = f"[Railway Watch][{label}] yorigo 일일 점검 ({collected[:10]})"

    lines: List[str] = []
    lines.append("Yorigo Railway 일일 점검 리포트 (규칙 기반, 자동 수정 없음)")
    lines.append(f"수집 시각(UTC): {collected}")
    lines.append(
        f"대상: {snapshot.get('project')}/{snapshot.get('environment')}/{snapshot.get('service')} since={snapshot.get('since')}"
    )
    lines.append("")
    lines.append("== 요약 ==")
    lines.append(f"종합: {label} ({sev})")
    for f in findings:
        mark = {"ok": "OK", "info": "INFO", "warning": "WARN", "critical": "CRIT"}.get(
            f.get("severity") or "info", "INFO"
        )
        lines.append(f"- [{mark}] {f.get('title')}: {f.get('detail')}")
        for ev in (f.get("evidence") or [])[:3]:
            lines.append(f"    · {ev}")

    lines.append("")
    lines.append("== 배포 ==")
    for d in (snapshot.get("deployments") or [])[:3]:
        lines.append(
            f"- {d.get('status')} {d.get('commitHash')} {d.get('commitMessage')} ({d.get('createdAt')})"
        )

    lines.append("")
    lines.append("== 헬스 ==")
    lines.append(str(snapshot.get("health")))

    lines.append("")
    lines.append("== 큐 ==")
    lines.append(str(snapshot.get("queue")))

    lines.append("")
    lines.append("== HTTP ==")
    http = snapshot.get("http") or {}
    lines.append(f"status_counts={http.get('status_counts')} total={http.get('total')}")

    lines.append("")
    lines.append("== 로그 시그널 ==")
    lines.append(str(snapshot.get("log_signals")))

    lines.append("")
    lines.append("== 로그 샘플 (최근 30줄) ==")
    for ln in list(snapshot.get("logs") or [])[-30:]:
        lines.append(ln[:300])

    return subject, "\n".join(lines)
