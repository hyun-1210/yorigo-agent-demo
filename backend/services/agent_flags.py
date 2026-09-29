"""에이전트 기능 플래그. 기본은 꺼짐. QA/로컬만 env로 켠다."""

from __future__ import annotations

import os


def env_flag_enabled(name: str, default: str = "false") -> bool:
    """환경 변수가 1/true/yes 이면 True."""
    return os.getenv(name, default).strip().lower() in ("1", "true", "yes")


def recipe_agent_enabled() -> bool:
    """상세 레시피 도우미. RECIPE_AGENT_ENABLED=true 일 때만 동작."""
    return env_flag_enabled("RECIPE_AGENT_ENABLED")


def home_agent_enabled() -> bool:
    """홈 검색 도우미. 이번 QA 범위 밖. 기본 꺼짐."""
    return env_flag_enabled("HOME_AGENT_ENABLED")


def grocery_agent_enabled() -> bool:
    """장보기 지휘자. GROCERY_AGENT_ENABLED=true 일 때만 라우터를 연다."""
    return env_flag_enabled("GROCERY_AGENT_ENABLED")
