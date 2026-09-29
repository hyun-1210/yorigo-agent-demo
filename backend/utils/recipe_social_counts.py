"""레시피 카드용 소셜 숫자 헬퍼.

파싱된 레시피는 작성자가 레시피북에 넣지만 saveCount 가 0 으로 남는 경우가 많다.
표시용으로 recipeId 기반 결정적 시드(1 이상)를 쓴다. 이미 1 이상인 실측 값은 덮지 않는다.
"""

from __future__ import annotations

import hashlib
from typing import Any


def seed_save_count(recipe_id: str) -> int:
    """recipeId 로 결정적인 북마크 시드. 범위 1–8, 대부분은 1–4.

    실측 saveCount 상위(수십~수천)를 밀어내지 않도록 상한을 낮게 둔다.
    """
    rid = (recipe_id or "").strip() or "unknown"
    digest = hashlib.sha256(f"yorigo:saveCount:{rid}".encode("utf-8")).digest()
    bucket = digest[0] % 100
    value_src = int.from_bytes(digest[1:5], "big")
    if bucket < 55:
        return 1 + (value_src % 2)
    if bucket < 85:
        return 3 + (value_src % 2)
    if bucket < 97:
        return 5 + (value_src % 2)
    return 7 + (value_src % 2)


def parse_save_count(raw: Any) -> int:
    """Firestore saveCount 를 int 로. 없거나 파싱 불가면 0."""
    if isinstance(raw, bool):
        return 0
    if isinstance(raw, (int, float)):
        n = int(raw)
        return n if n > 0 else 0
    if isinstance(raw, str):
        digits = "".join(ch for ch in raw if ch.isdigit())
        if digits:
            n = int(digits)
            return n if n > 0 else 0
    return 0


def needs_seeded_save_count(raw: Any) -> bool:
    """필드 없음/null/0 이하면 시드 대상."""
    if raw is None:
        return True
    return parse_save_count(raw) <= 0
