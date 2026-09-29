"""단축/랜딩 URL 분리와 스크래핑 필드 매핑."""

from __future__ import annotations

import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import importlib.util

_SPEC = importlib.util.spec_from_file_location(
    "coupang_partner_urls_under_test",
    BACKEND_DIR / "services" / "coupang_partner_urls.py",
)
_mod = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(_mod)
extract_partner_urls_from_scraped = _mod.extract_partner_urls_from_scraped
extract_report_subparam = _mod.extract_report_subparam
is_coupang_affsdp_landing_url = _mod.is_coupang_affsdp_landing_url
split_partner_urls = _mod.split_partner_urls

AFFSDP = "https://link.coupang.com/re/AFFSDP?lptag=abc&itemId=1"
SHORT = "https://link.coupang.com/a/short12"
WWW = "https://www.coupang.com/vp/products/1"


def test_affsdp_detection():
    assert is_coupang_affsdp_landing_url(AFFSDP) is True
    assert is_coupang_affsdp_landing_url("link.coupang.com/re/AFFSDP") is True
    assert is_coupang_affsdp_landing_url(SHORT) is False
    assert is_coupang_affsdp_landing_url(WWW) is False
    assert is_coupang_affsdp_landing_url("") is False


def test_split_prefers_explicit_landing_over_short():
    short, landing = split_partner_urls(SHORT, AFFSDP)
    assert short == SHORT
    assert landing == AFFSDP


def test_split_promotes_affsdp_stored_as_deeplink():
    short, landing = split_partner_urls(AFFSDP, "")
    assert short == ""
    assert landing == AFFSDP


def test_split_does_not_treat_short_as_landing():
    short, landing = split_partner_urls(SHORT, SHORT)
    assert short == SHORT
    assert landing == ""


def test_extract_scraped_field_aliases():
    short, landing = extract_partner_urls_from_scraped(
        {
            "shortenUrl": SHORT,
            "landing_url": AFFSDP,
        }
    )
    assert short == SHORT
    assert landing == AFFSDP


def test_extract_report_subparam_aliases():
    assert extract_report_subparam({"subParam": "yr_abc123XYZ0"}) == "yr_abc123XYZ0"
    assert extract_report_subparam({"subparam": "yr_abc123XYZ0"}) == "yr_abc123XYZ0"
    assert extract_report_subparam({"addtag": "400"}) == ""


if __name__ == "__main__":
    test_affsdp_detection()
    test_split_prefers_explicit_landing_over_short()
    test_split_promotes_affsdp_stored_as_deeplink()
    test_split_does_not_treat_short_as_landing()
    test_extract_scraped_field_aliases()
    test_extract_report_subparam_aliases()
    print("ok")
