"""
Lightweight image proxy for Flutter Web.

Instagram CDN (scontent-*.cdninstagram.com) does not send
Access-Control-Allow-Origin headers, so <img> / CachedNetworkImage on
Flutter Web is CORS-blocked. This endpoint fetches the image server-side
and streams it back with permissive CORS so the browser can render it.

Only allows image/* content-types and caps response size to prevent abuse.
"""

from __future__ import annotations

import hashlib
from urllib.parse import urlparse

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import Response

import httpx

router = APIRouter(tags=["util"])

_ALLOWED_HOSTS = {
    "cdninstagram.com",
    "scontent.cdninstagram.com",
    "i.ytimg.com",
    "yt3.ggpht.com",
    "yt3.googleusercontent.com",
    "firebasestorage.googleapis.com",
}

MAX_IMAGE_BYTES = 5 * 1024 * 1024  # 5 MB


def _host_allowed(url: str) -> bool:
    try:
        host = urlparse(url).hostname or ""
    except Exception:
        return False
    for allowed in _ALLOWED_HOSTS:
        if host == allowed or host.endswith("." + allowed):
            return True
    return False


@router.get("/proxy_image")
async def proxy_image(url: str = Query(..., description="Image URL to proxy")):
    if not url or not url.startswith("https://"):
        raise HTTPException(400, "Only HTTPS URLs are accepted.")
    if not _host_allowed(url):
        raise HTTPException(403, "Host not in allow-list.")

    etag = hashlib.md5(url.encode()).hexdigest()[:16]

    async with httpx.AsyncClient(follow_redirects=True, timeout=10.0) as client:
        try:
            resp = await client.get(url)
        except httpx.HTTPError as e:
            raise HTTPException(502, f"Upstream fetch failed: {e}") from e

    if resp.status_code != 200:
        raise HTTPException(resp.status_code, "Upstream returned non-200.")

    ct = resp.headers.get("content-type", "")
    if not ct.startswith("image/"):
        raise HTTPException(415, f"Not an image: {ct}")

    body = resp.content
    if len(body) > MAX_IMAGE_BYTES:
        raise HTTPException(413, "Image exceeds size limit.")

    return Response(
        content=body,
        media_type=ct,
        headers={
            "Cache-Control": "public, max-age=86400",
            "ETag": etag,
            "Access-Control-Allow-Origin": "*",
        },
    )
