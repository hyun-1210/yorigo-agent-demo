"""
Standalone verification for the Apify Instagram integration.

Usage:
    cd backend
    python scripts/verify_apify.py https://www.instagram.com/p/DWVxUoIAR5d/

Checks:
    1. APIFY_API_TOKEN is loaded from .env
    2. apify-client is importable
    3. The actor returns a result for the given URL
    4. The key fields we consume (video_url, display_url, caption, transcript) are populated

Prints a concise PASS/FAIL summary at the end. Does NOT hit Gemini or start any servers.
"""

from __future__ import annotations

import io
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")


def main() -> int:
    backend_dir = Path(__file__).resolve().parent.parent
    load_dotenv(backend_dir / ".env")

    sys.path.insert(0, str(backend_dir))

    url = sys.argv[1] if len(sys.argv) > 1 else "https://www.instagram.com/p/DWVxUoIAR5d/"
    print(f"[verify_apify] URL: {url}")

    token = (os.getenv("APIFY_API_TOKEN") or "").strip()
    if not token:
        print("[verify_apify] FAIL  APIFY_API_TOKEN is not set in .env")
        return 2
    masked = token[:12] + "..." + token[-4:]
    print(f"[verify_apify] PASS  APIFY_API_TOKEN loaded ({masked})")

    try:
        import apify_client  # noqa: F401
    except ImportError:
        print("[verify_apify] FAIL  apify-client not installed — run: pip install apify-client>=1.8.0")
        return 3
    print("[verify_apify] PASS  apify-client import ok")

    from services.apify_instagram_service import (
        ApifyInstagramService,
        ApifyError,
        ApifyReelNotFoundError,
    )

    svc = ApifyInstagramService(api_token=token, timeout_sec=60, retries=1)
    t0 = time.perf_counter()
    try:
        post = svc.fetch_reel(url)
    except ApifyReelNotFoundError as e:
        print(f"[verify_apify] FAIL  Apify returned no reel: {e}")
        print("[verify_apify]       (this URL is likely a photo /p/ post, deleted, or private)")
        return 4
    except ApifyError as e:
        print(f"[verify_apify] FAIL  Apify service error: {e}")
        return 5
    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    print(f"[verify_apify] PASS  fetch_reel completed in {elapsed_ms}ms")

    def _preview(s: str, n: int = 80) -> str:
        s = (s or "").replace("\n", " ")
        return (s[:n] + "...") if len(s) > n else s

    print("[verify_apify] --- Apify post (normalized) ---")
    print(f"  title:              {_preview(post.get('title'))!r}")
    print(f"  caption chars:      {len(post.get('caption') or '')}")
    print(f"  caption preview:    {_preview(post.get('caption'))!r}")
    print(f"  video_url present:  {bool(post.get('video_url'))}")
    print(f"  display_url present:{bool(post.get('display_url'))}")
    print(f"  display_url:        {_preview(post.get('display_url'))!r}")
    print(f"  duration sec:       {post.get('duration')}")
    print(f"  uploader:           {post.get('uploader')!r}")
    print(f"  uploader full:      {post.get('uploader_full_name')!r}")
    print(f"  product_type:       {post.get('product_type')!r}")
    print(f"  transcript chars:   {len(post.get('transcript') or '')}")
    print(f"  transcript preview: {_preview(post.get('transcript'))!r}")
    print(f"  view/play/like:     {post.get('view_count')}/{post.get('play_count')}/{post.get('like_count')}")
    print(f"  hashtags:           {post.get('hashtags')}")
    print(f"  latest_comments:    {len(post.get('latest_comments') or [])}")

    failures = []
    if not post.get("title"):
        failures.append("title is empty")
    if not post.get("video_url"):
        failures.append("video_url is empty (non-video post?)")
    if not post.get("display_url"):
        failures.append("display_url is empty (no thumbnail available)")

    if failures:
        print(f"[verify_apify] WARN  Missing fields: {failures}")
    else:
        print("[verify_apify] PASS  All key fields populated — early-emit will show thumbnail + title")

    # Adapter → resolve_instagram_cdn_urls 호환성
    from services.apify_instagram_service import apify_post_to_ytdlp_info
    from services.youtube_service import resolve_instagram_cdn_urls

    info = apify_post_to_ytdlp_info(post)
    v_url, a_url = resolve_instagram_cdn_urls(info)
    print("[verify_apify] --- Adapter / CDN resolve ---")
    print(f"  info.id:            {info.get('id')!r}")
    print(f"  info._source:       {info.get('_source')!r}")
    print(f"  info.channel:       {info.get('channel')!r}")
    print(f"  info.uploader:      {info.get('uploader')!r}")
    print(f"  formats count:      {len(info.get('formats') or [])}")
    print(f"  resolved video_url: {bool(v_url)}")
    print(f"  resolved audio_url: {bool(a_url)}")

    if not info.get("id"):
        failures.append("adapter id (short_code) empty")
    if info.get("_source") != "apify":
        failures.append("adapter _source != apify")
    if not v_url:
        failures.append("resolve_instagram_cdn_urls returned empty video URL")
        print("[verify_apify] FAIL  Adapter/CDN resolve did not yield a video URL")
        print("[verify_apify] ==== DONE ====")
        return 6
    print("[verify_apify] PASS  Adapter + resolve_instagram_cdn_urls OK")

    print("[verify_apify] ==== DONE ====")
    return 0


if __name__ == "__main__":
    sys.exit(main())
