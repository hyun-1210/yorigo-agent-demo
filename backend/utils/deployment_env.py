"""
배포 환경 감지 (Railway, AWS EC2, 로컬).

Railway 전용 env(RAILWAY_ENVIRONMENT) 대신 명시적 플래그로 프로덕션 API 호스트를 구분합니다.
"""

import os


def is_production_api_host() -> bool:
    """
    Railway 또는 AWS 등 프로덕션 API 호스트 여부 (로컬 개발 백엔드가 아님).

    EC2: ENABLE_PRODUCTION_SCHEDULERS=true 설정.
    Railway: RAILWAY_ENVIRONMENT 자동 설정 (하위 호환).
    """
    if os.getenv("RAILWAY_ENVIRONMENT"):
        return True
    return os.getenv("ENABLE_PRODUCTION_SCHEDULERS", "false").lower() == "true"


def is_parse_worker_host() -> bool:
    """
    맥미니 등 파싱 전담 워커 호스트 여부.

    YORIGO_PARSE_WORKER=true 이면 가격/스크래핑 등 프로덕션 스케줄러를
    기동하지 않고 파싱 API만 제공하는 모드로 동작합니다.
    """
    return os.getenv("YORIGO_PARSE_WORKER", "false").lower() == "true"


def get_public_api_domain() -> str:
    """
    공개 API 도메인 (스킴 없음). 예: api.yorigo.kr

    PUBLIC_API_DOMAIN 우선, 없으면 RAILWAY_PUBLIC_DOMAIN (하위 호환).
    """
    for key in ("PUBLIC_API_DOMAIN", "RAILWAY_PUBLIC_DOMAIN"):
        raw = (os.getenv(key) or "").strip()
        if raw:
            return raw.replace("https://", "").replace("http://", "").rstrip("/")
    return ""
