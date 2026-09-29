"""쿠팡 파트너스 단축/랜딩 URL 구분.

스크래퍼 문서와 추천 응답에서 쓰는 필드명을 한곳에서 맞춘다.
AFFSDP 랜딩만 유저 subparam 추적에 쓰고, 단축 URL은 폴백이다.
"""

from __future__ import annotations

from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlparse

AFFSDP_HOST = "link.coupang.com"
AFFSDP_PATH_TOKEN = "/re/affsdp"


def _as_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def ensure_http_scheme(raw: str) -> str:
    """스킴이 없으면 https를 붙인다."""
    text = (raw or "").strip()
    if not text:
        return ""
    lowered = text.lower()
    if lowered.startswith("http://") or lowered.startswith("https://"):
        return text
    return f"https://{text}"


def is_coupang_affsdp_landing_url(url: Optional[str]) -> bool:
    """`link.coupang.com/re/AFFSDP` 랜딩만 추적 URL로 인정한다."""
    raw = ensure_http_scheme(_as_text(url))
    if not raw:
        return False
    try:
        parsed = urlparse(raw)
    except ValueError:
        return False
    host = (parsed.hostname or "").lower()
    if host != AFFSDP_HOST:
        return False
    return AFFSDP_PATH_TOKEN in (parsed.path or "").lower()


def _first_text(data: Dict[str, Any], keys: Tuple[str, ...]) -> str:
    for key in keys:
        text = _as_text(data.get(key))
        if text:
            return text
    return ""


def split_partner_urls(
    deeplink_url: Optional[str],
    landing_url: Optional[str],
) -> Tuple[str, str]:
    """단축 URL과 AFFSDP 랜딩을 분리한다.

    deeplink에 AFFSDP가 들어 있고 landing이 비면 랜딩으로 승격한다.
    짧은 URL을 랜딩으로 쓰지 않는다.
    """
    short_in = _as_text(deeplink_url)
    landing_in = _as_text(landing_url)

    landing_out = ""
    if is_coupang_affsdp_landing_url(landing_in):
        landing_out = ensure_http_scheme(landing_in)
    elif is_coupang_affsdp_landing_url(short_in):
        landing_out = ensure_http_scheme(short_in)

    short_out = ""
    if short_in and not is_coupang_affsdp_landing_url(short_in):
        short_out = ensure_http_scheme(short_in)

    return short_out, landing_out


def extract_partner_urls_from_scraped(
    data: Dict[str, Any],
) -> Tuple[str, str]:
    """스크래핑 문서/원본 dict에서 (shorten, landing)을 읽는다."""
    landing = _first_text(
        data,
        ("landingUrl", "landing_url", "landingURL"),
    )
    short = _first_text(
        data,
        (
            "shortenUrl",
            "shorten_url",
            "deeplinkUrl",
            "deeplink_url",
        ),
    )
    return split_partner_urls(short, landing)


def extract_report_subparam(row: Dict[str, Any]) -> str:
    """주문/광고 리포트 한 행에서 subParam을 꺼낸다."""
    return _first_text(row, ("subParam", "subparam", "sub_param"))
