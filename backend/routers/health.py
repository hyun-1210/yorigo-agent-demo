"""
Health check and monitoring endpoints
"""

import asyncio
import logging
import os
import secrets
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Header, HTTPException, Query
from cookie_manager import (
    get_cookie_pool_status,
    get_source_refresh_status,
)
from rate_limiter import get_rate_limit_stats
from proxy_manager import get_proxy_manager

logger = logging.getLogger(__name__)

router = APIRouter(prefix="", tags=["health"])

# A-3: Firestore ping을 healthcheck에 포함 → stuck 시 503 반환 → ALB/Railway 자동 재시작.
HEALTH_FIRESTORE_TIMEOUT_SECONDS = float(
    os.getenv("HEALTH_FIRESTORE_TIMEOUT_SECONDS", "3")
)


async def _probe_firestore() -> bool:
    """Firestore가 실제로 응답하는지 확인. timeout 안에 1건이라도 list_documents()
    응답이 오면 OK. 컬렉션 존재 여부와 무관 — gRPC 응답성만 확인."""
    try:
        from services.firebase_service import get_firebase_service

        firebase_service = get_firebase_service()
        if not firebase_service or not firebase_service.is_available():
            return False
        db = firebase_service.db
        if db is None:
            return False

        def _probe():
            # _healthcheck 컬렉션은 존재할 필요 없음. .limit(1).get(timeout=...)이
            # SDK 레벨 deadline을 직접 걸어주는 게 핵심.
            try:
                list(
                    db.collection("_healthcheck").limit(1).get(
                        timeout=HEALTH_FIRESTORE_TIMEOUT_SECONDS
                    )
                )
                return True
            except Exception:
                return False

        return await asyncio.wait_for(
            asyncio.to_thread(_probe),
            timeout=HEALTH_FIRESTORE_TIMEOUT_SECONDS + 1.0,
        )
    except asyncio.TimeoutError:
        logger.warning("[Health] Firestore probe asyncio timeout")
        return False
    except Exception as e:
        logger.warning("[Health] Firestore probe failed: %s", e)
        return False


def _verify_monitor_access(x_internal_token: Optional[str]) -> None:
    """
    monitor 엔드포인트 접근용 내부 토큰을 검증합니다.
    """
    expected = (os.getenv("MONITOR_INTERNAL_TOKEN") or "").strip()
    if not expected:
        raise HTTPException(status_code=503, detail="Monitor endpoint is not configured")

    provided = (x_internal_token or "").strip()
    if not provided:
        raise HTTPException(status_code=401, detail="Missing monitor access token")

    if not secrets.compare_digest(provided, expected):
        raise HTTPException(status_code=403, detail="Invalid monitor access token")


@router.get("/health")
async def health_check():
    """
    Health check endpoint for ALB, Railway, and monitoring.

    A-3: 단순 200 반환이 아니라 **실제로 Firestore를 1번 ping** 한다.
    - Firestore가 stuck이면 healthcheck도 fail → 로드밸런서가 트래픽 차단 / 재시작
    - 쿠키 풀과 무관하게 Firestore 응답성을 핵심 지표로 삼음
    """
    cookie_status = get_cookie_pool_status()
    rate_limit_stats = get_rate_limit_stats()

    firestore_ok = await _probe_firestore()

    # Firestore가 stuck이면 healthcheck도 같이 stuck/fail → ALB unhealthy 트리거.
    if not firestore_ok:
        raise HTTPException(
            status_code=503,
            detail={
                "status": "degraded",
                "service": "yorigo-backend",
                "timestamp": datetime.now().isoformat(),
                "firestore": "unreachable_or_stuck",
                "cookie_pool_available": cookie_status['available_cookies'],
            },
        )

    return {
        "status": "healthy",
        "service": "yorigo-backend",
        "timestamp": datetime.now().isoformat(),
        "firestore": "ok",
        "cookie_pool": {
            "enabled": True,
            "note": "YouTube env/file cookies only; Instagram SOURCE_URL refresh disabled",
            "total": cookie_status['total_cookies'],
            "healthy": cookie_status['healthy_cookies'],
            "available": cookie_status['available_cookies'],
            "overall_success_rate": f"{cookie_status['overall_success_rate']:.1%}"
        },
        "rate_limits": {
            "global_last_minute": rate_limit_stats['global_requests_last_minute'],
            "global_last_hour": rate_limit_stats['global_requests_last_hour']
        },
        "proxy": get_proxy_manager().get_status()
    }


@router.get("/monitor/cookies")
async def monitor_cookies(
    x_internal_token: Optional[str] = Header(None),
):
    """
    Detailed cookie pool monitoring endpoint.
    Shows per-cookie statistics, health, and source URL refresh status.
    """
    _verify_monitor_access(x_internal_token)
    status = get_cookie_pool_status()
    status["external_sync"] = get_source_refresh_status()
    return status


@router.post("/monitor/cookies/refresh")
async def monitor_cookies_refresh(
    x_internal_token: Optional[str] = Header(None),
):
    """
    소스 URL에서 쿠키를 한 번 가져와 풀에 반영 (수동 갱신).
    """
    _verify_monitor_access(x_internal_token)
    return {
        "ok": False,
        "error": (
            "SOURCE_URL cookie refresh is disabled. "
            "YouTube cookies load from YOUTUBE_COOKIES_BASE64(_2..5) or cookie files."
        ),
        "external_sync": get_source_refresh_status(),
    }


@router.get("/monitor/rate-limits")
async def monitor_rate_limits(
    x_internal_token: Optional[str] = Header(None),
):
    """
    Detailed rate limiter monitoring endpoint.
    Shows per-cookie rate limit statistics.
    """
    _verify_monitor_access(x_internal_token)
    return get_rate_limit_stats()


@router.get("/monitor/test-captions")
async def monitor_test_captions(
    url: str = Query(
        ...,
        description="YouTube watch URL (e.g. https://www.youtube.com/watch?v=CDc9arjUXzg)",
    ),
    x_internal_token: Optional[str] = Header(None),
):
    """
    Railway egress + cookie pool에서 자막 fetch 진단.
    bare HTTP vs pool-cookie 세션 vs _fetch_raw_vtt 결과를 JSON으로 반환.
    """
    _verify_monitor_access(x_internal_token)
    lower = (url or "").strip().lower()
    if "youtube.com" not in lower and "youtu.be" not in lower:
        raise HTTPException(status_code=400, detail="Only YouTube URLs are supported")

    from services.youtube_service import YouTubeService

    yt = YouTubeService()
    return await asyncio.to_thread(yt.diagnose_caption_fetch, url.strip())


@router.get("/monitor/yt-cdn-probe")
async def monitor_yt_cdn_probe(
    url: str = Query(
        "https://www.youtube.com/watch?v=Eu5zpddy0kg",
        description="YouTube watch URL to extract + probe from Railway egress",
    ),
    external_cdn_url: Optional[str] = Query(
        None,
        description="Optional pre-extracted googlevideo URL (e.g. from Mac mini) to probe IP-binding",
    ),
    x_internal_token: Optional[str] = Header(None),
):
    """Railway에서 YouTube CDN URL probe (맥미니 적재 URL vs Railway 추출 URL)."""
    _verify_monitor_access(x_internal_token)
    lower = (url or "").strip().lower()
    if "youtube.com" not in lower and "youtu.be" not in lower:
        raise HTTPException(status_code=400, detail="Only YouTube URLs are supported")

    return await asyncio.to_thread(
        _run_yt_cdn_probe,
        url.strip(),
        (external_cdn_url or "").strip() or None,
    )


def _run_yt_cdn_probe(youtube_url: str, external_cdn_url: Optional[str]) -> dict:
    """Railway egress에서 googlevideo CDN 재사용 가능성을 진단한다."""
    import socket
    import time
    import urllib.request
    from typing import Any, Dict, Optional as Opt

    def _host(u: str) -> str:
        try:
            return u.split("/")[2]
        except Exception:
            return ""

    def _probe(u: str, *, n: int = 65536, timeout: float = 25.0) -> Dict[str, Any]:
        req = urllib.request.Request(
            u,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
                ),
                "Range": f"bytes=0-{n - 1}",
            },
        )
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = resp.read(n)
                return {
                    "ok": True,
                    "status": getattr(resp, "status", None) or resp.getcode(),
                    "bytes": len(data),
                    "content_type": resp.headers.get("Content-Type"),
                    "elapsed_ms": int((time.time() - t0) * 1000),
                    "host": _host(resp.geturl() or u),
                }
        except Exception as exc:
            return {
                "ok": False,
                "status": getattr(exc, "code", None),
                "error": f"{type(exc).__name__}: {exc}"[:300],
                "elapsed_ms": int((time.time() - t0) * 1000),
                "host": _host(u),
            }

    def _download_n(u: str, n: int = 1_000_000, timeout: float = 60.0) -> Dict[str, Any]:
        req = urllib.request.Request(
            u,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
                ),
            },
        )
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                got = 0
                while got < n:
                    chunk = resp.read(min(256 * 1024, n - got))
                    if not chunk:
                        break
                    got += len(chunk)
                return {
                    "ok": got > 0,
                    "status": getattr(resp, "status", None) or resp.getcode(),
                    "downloaded": got,
                    "elapsed_ms": int((time.time() - t0) * 1000),
                }
        except Exception as exc:
            return {
                "ok": False,
                "error": f"{type(exc).__name__}: {exc}"[:300],
                "elapsed_ms": int((time.time() - t0) * 1000),
                "downloaded": 0,
            }

    def _pick_muxed_mp4(info: Dict[str, Any]) -> Opt[str]:
        formats = info.get("formats") or []
        for fmt in reversed(formats):
            if (
                fmt.get("url")
                and fmt.get("ext") == "mp4"
                and fmt.get("vcodec") not in (None, "none")
                and fmt.get("acodec") not in (None, "none")
            ):
                return fmt["url"]
        for fmt in reversed(formats):
            if fmt.get("url") and fmt.get("vcodec") not in (None, "none"):
                return fmt["url"]
        return None

    outbound_ip = None
    try:
        outbound_ip = (
            urllib.request.urlopen("https://api.ipify.org", timeout=10)
            .read()
            .decode("utf-8", errors="replace")
        )
    except Exception as exc:
        outbound_ip = f"fail:{type(exc).__name__}"

    result: Dict[str, Any] = {
        "hostname": socket.gethostname(),
        "outbound_ip": outbound_ip,
        "youtube_url": youtube_url,
        "external_cdn_probe": None,
        "railway_extract": None,
        "railway_cdn_probe": None,
        "railway_cdn_download_1mb": None,
    }

    if external_cdn_url:
        if "googlevideo.com" not in external_cdn_url and "googleusercontent.com" not in external_cdn_url:
            result["external_cdn_probe"] = {
                "ok": False,
                "error": "external_cdn_url must be googlevideo/googleusercontent",
            }
        else:
            result["external_cdn_probe"] = _probe(external_cdn_url)
            result["external_cdn_host"] = _host(external_cdn_url)

    try:
        from services.youtube_service import YouTubeService

        t0 = time.time()
        info = YouTubeService().extract_metadata_light(youtube_url)
        cdn = _pick_muxed_mp4(info if isinstance(info, dict) else {})
        result["railway_extract"] = {
            "ok": bool(cdn),
            "extract_ms": int((time.time() - t0) * 1000),
            "video_id": (info or {}).get("id"),
            "duration": (info or {}).get("duration"),
            "formats": len((info or {}).get("formats") or []),
            "cdn_host": _host(cdn) if cdn else None,
            "cdn_url_len": len(cdn) if cdn else 0,
        }
        if cdn:
            result["railway_cdn_probe"] = _probe(cdn)
            if result["railway_cdn_probe"].get("ok"):
                result["railway_cdn_download_1mb"] = _download_n(cdn, n=1_000_000)
    except Exception as exc:
        result["railway_extract"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}"[:400],
        }

    return result

