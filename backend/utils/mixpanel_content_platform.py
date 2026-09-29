"""Mixpanel 이벤트에서 콘텐츠 소스와 기기 OS 키를 분리한다."""

from __future__ import annotations

from typing import Optional


def source_platform_props(platform: Optional[str]) -> dict:
    """콘텐츠 소스. Mixpanel 슈퍼프로퍼티 `platform`(기기 OS)과 구분한다."""
    src = (platform or "").strip().lower()
    if not src:
        return {}
    return {"platform": src, "source_platform": src}
