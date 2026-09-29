#!/usr/bin/env python3
"""칩/한줄 DeepSeek vs Gemini 10건 베이크오프.

키가 있는 배포/로컬에서만 돈다. 엔진을 강제하므로 프로덕션 기본(Gemini 1차)과
다르게 한쪽만 탄다.
  python scripts/bakeoff_tag_tagline.py
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
os.chdir(BACKEND)

from dotenv import load_dotenv

load_dotenv(BACKEND / ".env")

from services.llm_service import LLMService  # noqa: E402
from services.recipe_character import RecipeCharacterMixin  # noqa: E402


FIXTURES: List[Dict[str, Any]] = [
    {
        "name": "고추장 크림 파스타",
        "ingredients": [{"item": "저당 고추장"}, {"item": "그릭요거트"}, {"item": "파스타"}],
        "steps": [{"instruction": "면을 삶고 소스를 졸인다"}],
        "title": "인생 고추장크림파스타",
        "description": "저당 고추장과 그릭요거트로 꾸덕한 파스타",
        "transcript": "꾸덕하게 볶아주세요",
    },
    {
        "name": "김치찌개",
        "ingredients": [{"item": "김치"}, {"item": "돼지고기"}, {"item": "두부"}],
        "steps": [{"instruction": "김치를 볶고 물을 부어 끓인다"}],
        "title": "얼큰 김치찌개",
        "description": "저녁 집밥 김치찌개",
        "transcript": "얼큰하게 끓여서 한그릇",
    },
    {
        "name": "새우파전",
        "ingredients": [{"item": "부침가루"}, {"item": "새우"}, {"item": "대파"}],
        "steps": [{"instruction": "반죽을 부쳐 바삭하게 만든다"}],
        "title": "비오는날 새우파전",
        "description": "밀가루 없이 부침가루로 바삭한 파전",
        "transcript": "바삭하게 부쳐주세요 안주",
    },
    {
        "name": "백김치",
        "ingredients": [{"item": "배추"}, {"item": "배주스"}, {"item": "까나리액젓"}],
        "steps": [{"instruction": "절인 배추에 양념을 버무린다"}],
        "title": "백김치",
        "description": "시원한 백김치",
        "transcript": "",
    },
    {
        "name": "삼겹살 된장 덮밥",
        "ingredients": [{"item": "삼겹살"}, {"item": "된장"}, {"item": "밥"}],
        "steps": [{"instruction": "된장을 풀어 자작하게 졸인다"}],
        "title": "삼겹살 된장 덮밥",
        "description": "원팬 혼밥",
        "transcript": "자작하게 졸여 한그릇",
    },
    {
        "name": "쿠키",
        "ingredients": [{"item": "버터"}, {"item": "설탕"}, {"item": "밀가루"}],
        "steps": [{"instruction": "반죽을 오븐에 굽는다"}],
        "title": "초코칩 쿠키",
        "description": "달달한 홈베이킹 쿠키",
        "transcript": "",
    },
    {
        "name": "닭가슴살 샐러드",
        "ingredients": [{"item": "닭가슴살"}, {"item": "채소"}, {"item": "드레싱"}],
        "steps": [{"instruction": "구운 닭을 샐러드에 올린다"}],
        "title": "운동후 닭가슴살 샐러드",
        "description": "고단백 샐러드",
        "transcript": "",
    },
    {
        "name": "미역국",
        "ingredients": [{"item": "미역"}, {"item": "소고기"}],
        "steps": [{"instruction": "미역을 불려 끓인다"}],
        "title": "생일 미역국",
        "description": "생일상 미역국",
        "transcript": "",
    },
    {
        "name": "김밥",
        "ingredients": [{"item": "밥"}, {"item": "김"}, {"item": "단무지"}],
        "steps": [{"instruction": "김에 밥을 올리고 만다"}],
        "title": "소풍 김밥",
        "description": "피크닉 도시락 김밥",
        "transcript": "",
    },
    {
        "name": "라면",
        "ingredients": [{"item": "신라면"}, {"item": "파"}, {"item": "계란"}],
        "steps": [{"instruction": "끓는 물에 면을 넣는다"}],
        "title": "신라면 야식",
        "description": "매콤한 야식 라면",
        "transcript": "매콤하게 끓여 혼밥",
    },
]


class _Harness(RecipeCharacterMixin):
    def __init__(self, llm: LLMService) -> None:
        self.llm_service = llm

    def _load_chef_tags(self) -> list:
        return ["백종원"]

    def _detect_chef_tag(self, *args: Any, **kwargs: Any) -> str | None:
        return None


def _run_engine(engine: str) -> List[Dict[str, Any]]:
    os.environ["TAG_CHARACTER_ENGINE"] = engine
    os.environ["TAG_TAGLINE_ENGINE"] = engine
    llm = LLMService()
    h = _Harness(llm)
    rows: List[Dict[str, Any]] = []
    for fx in FIXTURES:
        t0 = time.perf_counter()
        char = h._enrich_recipe_character(
            recipe=fx,
            title=str(fx.get("title") or ""),
            description=str(fx.get("description") or ""),
            transcript=str(fx.get("transcript") or ""),
            tags_raw=[],
        )
        ms = int((time.perf_counter() - t0) * 1000)
        rows.append(
            {
                "name": fx["name"],
                "engine": engine,
                "ms": ms,
                "tags": char.get("tags"),
                "occasionTags": char.get("occasion_tags"),
                "tagline": char.get("tagline"),
            }
        )
        print(f"[{engine}] {fx['name']} {ms}ms {char.get('tagline')} {char.get('tags')}", flush=True)
    return rows


def main() -> int:
    if not (os.getenv("DEEPSEEK_API_KEY") or os.getenv("GEMINI_API_KEY")):
        print("DEEPSEEK_API_KEY 또는 GEMINI_API_KEY 필요", flush=True)
        return 2
    engines = []
    if os.getenv("DEEPSEEK_API_KEY"):
        engines.append("deepseek")
    if os.getenv("GEMINI_API_KEY"):
        engines.append("gemini")
    all_rows: List[Dict[str, Any]] = []
    for engine in engines:
        all_rows.extend(_run_engine(engine))
    out = BACKEND / "scripts" / "_bakeoff_tag_tagline.json"
    out.write_text(json.dumps(all_rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
