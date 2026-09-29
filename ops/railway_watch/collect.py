"""Railway 로그·헬스·Firestore 큐 상태 수집."""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from pathlib import Path


DEFAULT_PROJECT = "remarkable-energy"
DEFAULT_ENV = "production"
DEFAULT_SERVICE = "yorigo"
DEFAULT_PUBLIC_URL = "https://yorigo-production.up.railway.app"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _railway_cmd() -> List[str]:
    """railway CLI 실행 커맨드 (Windows npm shim 포함)."""
    import shutil

    which = shutil.which("railway") or shutil.which("railway.cmd") or shutil.which("railway.exe")
    if which:
        return [which]
    # npm global 직접 경로 폴백
    npm_js = (
        Path.home()
        / "AppData"
        / "Roaming"
        / "npm"
        / "node_modules"
        / "@railway"
        / "cli"
        / "bin"
        / "railway.js"
    )
    if npm_js.is_file() and shutil.which("node"):
        return [shutil.which("node") or "node", str(npm_js)]
    raise RuntimeError("railway CLI not found in PATH")


def _using_project_token() -> bool:
    """RAILWAY_TOKEN(Project Token) 사용 중인지.

    Project Token은 이미 project/environment에 스코프되므로
    CLI에 ``--project/--environment``를 같이 넘기면 Unauthorized가 난다.
    """
    if (os.getenv("RAILWAY_WATCH_USE_SESSION") or "").lower() in ("1", "true", "yes"):
        return False
    return bool((os.getenv("RAILWAY_TOKEN") or "").strip())


def _scope_args(*, project: str, environment: str, service: str) -> List[str]:
    """CLI 스코프 플래그. Project Token이면 service만."""
    if _using_project_token():
        return ["--service", service] if service else []
    args: List[str] = []
    if project:
        args.extend(["--project", project])
    if environment:
        args.extend(["--environment", environment])
    if service:
        args.extend(["--service", service])
    return args


def _run_railway(args: List[str], *, timeout: int = 120) -> str:
    """railway CLI를 실행하고 stdout을 반환한다."""
    env = os.environ.copy()
    env.setdefault("RAILWAY_CALLER", "ops:railway-watch")
    # 잘못된/만료 RAILWAY_TOKEN이 로컬 세션보다 우선되면 Unauthorized가 난다.
    # 로컬 dry-run에서는 세션을 쓰도록 비워둘 수 있게 한다.
    if (os.getenv("RAILWAY_WATCH_USE_SESSION") or "").lower() in ("1", "true", "yes"):
        env.pop("RAILWAY_TOKEN", None)
    cmd = _railway_cmd() + args
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            env=env,
            check=False,
            shell=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("railway CLI not found in PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"railway CLI timeout: {' '.join(args)}") from exc
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"railway {' '.join(args)} failed: {err[:500]}")
    return proc.stdout or ""


def collect_deployments(
    *,
    project: str,
    environment: str,
    service: str,
    limit: int = 5,
) -> List[Dict[str, Any]]:
    """최근 배포 목록."""
    raw = _run_railway(
        [
            "deployment",
            "list",
            *_scope_args(project=project, environment=environment, service=service),
            "--limit",
            str(limit),
            "--json",
        ]
    )
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    out: List[Dict[str, Any]] = []
    for item in data:
        meta = item.get("meta") or {}
        out.append(
            {
                "id": item.get("id"),
                "status": item.get("status"),
                "createdAt": item.get("createdAt"),
                "commitHash": (meta.get("commitHash") or "")[:12],
                "commitMessage": (meta.get("commitMessage") or "").split("\n", 1)[0][:120],
            }
        )
    return out


def collect_logs(
    *,
    project: str,
    environment: str,
    service: str,
    since: str = "24h",
    lines: int = 400,
) -> List[str]:
    """최근 deploy 로그 라인."""
    raw = _run_railway(
        [
            "logs",
            *_scope_args(project=project, environment=environment, service=service),
            "--since",
            since,
            "--lines",
            str(lines),
        ],
        timeout=180,
    )
    return [ln for ln in raw.splitlines() if ln.strip()]


def collect_http_summary(
    *,
    project: str,
    environment: str,
    service: str,
    since: str = "24h",
    lines: int = 300,
) -> Dict[str, Any]:
    """HTTP 로그 상태코드 요약."""
    try:
        raw = _run_railway(
            [
                "logs",
                *_scope_args(project=project, environment=environment, service=service),
                "--http",
                "--since",
                since,
                "--lines",
                str(lines),
                "--json",
            ],
            timeout=180,
        )
    except RuntimeError as exc:
        return {"ok": False, "error": str(exc), "status_counts": {}, "sample_5xx": []}

    status_counts: Counter[str] = Counter()
    sample_5xx: List[str] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        attrs = obj.get("attributes") or {}
        status = (
            obj.get("httpStatus")
            or obj.get("status")
            or attrs.get("httpStatus")
            or attrs.get("status")
        )
        path = obj.get("path") or attrs.get("path") or ""
        method = obj.get("method") or attrs.get("method") or ""
        if status is None:
            continue
        key = str(status)
        status_counts[key] += 1
        try:
            code = int(status)
        except (TypeError, ValueError):
            continue
        if code >= 500 and len(sample_5xx) < 8:
            sample_5xx.append(f"{method} {path} → {code}")
    return {
        "ok": True,
        "status_counts": dict(sorted(status_counts.items())),
        "sample_5xx": sample_5xx,
        "total": sum(status_counts.values()),
    }


def collect_health(public_url: str) -> Dict[str, Any]:
    """공개 /health 엔드포인트 확인."""
    url = public_url.rstrip("/") + "/health"
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "yorigo-railway-watch/1.0"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                payload = {"raw": body[:300]}
            return {"ok": 200 <= resp.status < 300, "status": resp.status, "body": payload}
    except urllib.error.HTTPError as exc:
        return {"ok": False, "status": exc.code, "error": str(exc)}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "status": None, "error": f"{type(exc).__name__}: {exc}"}


def collect_firestore_queue(sa_path: Optional[Path] = None) -> Dict[str, Any]:
    """timestamp_jobs 큐 상태 요약."""
    try:
        from google.cloud import firestore
        from google.cloud.firestore_v1 import FieldFilter
        import firebase_admin
        from firebase_admin import credentials
    except ImportError as exc:
        return {"ok": False, "error": f"firebase deps missing: {exc}"}

    path = sa_path or Path(
        os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
        or "backend/firebase-service-account.json"
    )
    if not path.is_file():
        return {"ok": False, "error": f"service account missing: {path}"}

    try:
        if not firebase_admin._apps:  # type: ignore[attr-defined]
            firebase_admin.initialize_app(credentials.Certificate(str(path)))
        db = firestore.Client.from_service_account_json(str(path))
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"firestore init failed: {exc}"}

    counts: Dict[str, int] = {}
    youtube_cdn = {"with_cdn": 0, "without_cdn": 0, "recent_sample": []}
    try:
        for status in ("pending", "processing", "done", "failed"):
            snaps = list(
                db.collection("timestamp_jobs")
                .where(filter=FieldFilter("status", "==", status))
                .limit(50)
                .stream()
            )
            counts[status] = len(snaps)
            if status in ("pending", "processing"):
                for snap in snaps:
                    data = snap.to_dict() or {}
                    if (data.get("platform") or "").lower() != "youtube":
                        continue
                    has_cdn = bool((data.get("cdnVideoUrl") or "").strip())
                    if has_cdn:
                        youtube_cdn["with_cdn"] += 1
                    else:
                        youtube_cdn["without_cdn"] += 1
                    if len(youtube_cdn["recent_sample"]) < 5:
                        cdn = (data.get("cdnVideoUrl") or "").strip()
                        youtube_cdn["recent_sample"].append(
                            {
                                "id": snap.id,
                                "status": status,
                                "hasCdn": has_cdn,
                                "cdnHost": cdn.split("/")[2] if cdn.startswith("http") else None,
                            }
                        )
        # YouTube CDN 샘플 (platform 쿼리 + 알려진 최근 문서 직접 조회)
        yt_snaps = list(
            db.collection("timestamp_jobs")
            .where(filter=FieldFilter("platform", "==", "youtube"))
            .limit(80)
            .stream()
        )
        yt_with = 0
        cdn_examples: List[Dict[str, Any]] = []
        for s in yt_snaps:
            data = s.to_dict() or {}
            cdn = (data.get("cdnVideoUrl") or "").strip()
            if not cdn:
                continue
            yt_with += 1
            if len(cdn_examples) < 5:
                cdn_examples.append(
                    {
                        "id": s.id,
                        "status": data.get("status"),
                        "cdnHost": cdn.split("/")[2] if cdn.startswith("http") else None,
                        "googlevideo": "googlevideo.com" in cdn,
                    }
                )
        # 문서 ID 정렬상 샘플에 안 잡힐 수 있어 직접 조회
        for doc_id in ("youtube_Eu5zpddy0kg",):
            snap = db.collection("timestamp_jobs").document(doc_id).get()
            if not snap.exists:
                continue
            data = snap.to_dict() or {}
            cdn = (data.get("cdnVideoUrl") or "").strip()
            if cdn and not any(x.get("id") == snap.id for x in cdn_examples):
                cdn_examples.append(
                    {
                        "id": snap.id,
                        "status": data.get("status"),
                        "cdnHost": cdn.split("/")[2] if cdn.startswith("http") else None,
                        "googlevideo": "googlevideo.com" in cdn,
                    }
                )
                yt_with = max(yt_with, 1)
        youtube_cdn["sampled_youtube"] = len(yt_snaps)
        youtube_cdn["sampled_youtube_with_cdn"] = yt_with
        youtube_cdn["cdn_examples"] = cdn_examples
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"queue query failed: {exc}", "counts": counts}

    return {
        "ok": True,
        "counts": counts,
        "active": int(counts.get("pending", 0)) + int(counts.get("processing", 0)),
        "youtube_cdn": youtube_cdn,
    }


def collect_all(*, since: str = "24h") -> Dict[str, Any]:
    """전체 스냅샷 수집."""
    project = os.getenv("RAILWAY_PROJECT", DEFAULT_PROJECT)
    environment = os.getenv("RAILWAY_ENVIRONMENT", DEFAULT_ENV)
    service = os.getenv("RAILWAY_SERVICE", DEFAULT_SERVICE)
    public_url = os.getenv("RAILWAY_PUBLIC_URL", DEFAULT_PUBLIC_URL)

    snapshot: Dict[str, Any] = {
        "collected_at": _now_iso(),
        "project": project,
        "environment": environment,
        "service": service,
        "since": since,
        "errors": [],
    }

    try:
        snapshot["deployments"] = collect_deployments(
            project=project, environment=environment, service=service
        )
    except Exception as exc:  # noqa: BLE001
        snapshot["deployments"] = []
        snapshot["errors"].append(f"deployments: {exc}")

    try:
        snapshot["logs"] = collect_logs(
            project=project, environment=environment, service=service, since=since
        )
    except Exception as exc:  # noqa: BLE001
        snapshot["logs"] = []
        snapshot["errors"].append(f"logs: {exc}")

    snapshot["http"] = collect_http_summary(
        project=project, environment=environment, service=service, since=since
    )
    if not snapshot["http"].get("ok"):
        snapshot["errors"].append(f"http: {snapshot['http'].get('error')}")

    snapshot["health"] = collect_health(public_url)
    if not snapshot["health"].get("ok"):
        snapshot["errors"].append(f"health: {snapshot['health']}")

    sa = Path(os.getenv("GOOGLE_APPLICATION_CREDENTIALS") or "backend/firebase-service-account.json")
    snapshot["queue"] = collect_firestore_queue(sa)
    if not snapshot["queue"].get("ok"):
        snapshot["errors"].append(f"queue: {snapshot['queue'].get('error')}")

    return snapshot


_CLAIM_RE = re.compile(r"claim OK[^\n]*?—\s*([^\s(]+)", re.IGNORECASE)
_YT_CDN_RE = re.compile(r"yt_cdn_reuse=(true|false)", re.IGNORECASE)
_IG_CDN_RE = re.compile(r"\[timestamp_worker\] cdn_reuse=(true|false)", re.IGNORECASE)


def summarize_log_signals(logs: List[str]) -> Dict[str, Any]:
    """로그에서 핵심 시그널 카운트."""
    text = "\n".join(logs)
    return {
        "claims": len(_CLAIM_RE.findall(text)),
        "yt_cdn_true": len(re.findall(r"yt_cdn_reuse=true", text, re.I)),
        "yt_cdn_false": len(re.findall(r"yt_cdn_reuse=false", text, re.I)),
        "ig_cdn_true": len(re.findall(r"cdn_reuse=true", text, re.I)),
        "budget_exceeded": len(re.findall(r"budget|TIMESTAMP_JOB_BUDGET", text, re.I)),
        "orphan": len(re.findall(r"orphan", text, re.I)),
        "thread_exhaust": len(re.findall(r"can't start new thread", text, re.I)),
        "stuck": len(re.findall(r"\bSTUCK\b", text)),
        "traceback": len(re.findall(r"Traceback \(most recent call last\)", text)),
        "watchdog": len(re.findall(r"Watchdog", text, re.I)),
    }
