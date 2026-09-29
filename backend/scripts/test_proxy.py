"""Test the /proxy_image endpoint with a real Instagram CDN URL."""

from __future__ import annotations

import io
import os
import sys
import urllib.parse

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

from pathlib import Path
from dotenv import load_dotenv

backend_dir = Path(__file__).resolve().parent.parent
load_dotenv(backend_dir / ".env")
sys.path.insert(0, str(backend_dir))

import requests

from services.apify_instagram_service import ApifyInstagramService

token = (os.getenv("APIFY_API_TOKEN") or "").strip()
if not token:
    print("No APIFY_API_TOKEN")
    sys.exit(1)

url = sys.argv[1] if len(sys.argv) > 1 else "https://www.instagram.com/p/DWftPJ8gepn/"

print(f"[test_proxy] Fetching reel metadata via Apify: {url}")
svc = ApifyInstagramService(api_token=token, timeout_sec=120, retries=1)
post = svc.fetch_reel(url)
thumb = post.get("display_url", "")
print(f"[test_proxy] IG CDN URL: {thumb[:120]}...")
print()

encoded = urllib.parse.quote(thumb, safe="")
proxy_url = f"http://127.0.0.1:8000/proxy_image?url={encoded}"
print(f"[test_proxy] Proxy URL: {proxy_url[:140]}...")

r = requests.get(proxy_url, timeout=15)
print(f"[test_proxy] Status: {r.status_code}")
print(f"[test_proxy] Content-Type: {r.headers.get('content-type')}")
print(f"[test_proxy] Content-Length: {len(r.content)} bytes ({len(r.content)/1024:.1f} KB)")
print(f"[test_proxy] CORS header: {r.headers.get('access-control-allow-origin', 'MISSING')}")
print(f"[test_proxy] Cache-Control: {r.headers.get('cache-control', 'MISSING')}")

if r.status_code == 200 and (r.headers.get("content-type") or "").startswith("image/"):
    print("[test_proxy] PASS")
else:
    print(f"[test_proxy] FAIL - body head: {r.text[:200]}")
    sys.exit(1)
