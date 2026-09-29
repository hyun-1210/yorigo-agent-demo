#!/usr/bin/env python3
"""Gap A/B/C smoke test — no HTTP server required.

Calls IngredientService / LLMService directly with the shipped primary→Gemini
fallback stack.

Usage (from backend/):
  ./yorigo/bin/python scripts/smoke_gap_abc.py
  ./yorigo/bin/python scripts/smoke_gap_abc.py --fallback   # force primary fail → Gemini
  ./yorigo/bin/python scripts/smoke_gap_abc.py --skip-price

Requires backend/.env keys:
  GEMINI_API_KEY                      (backup for all)
  DEEPSEEK_API_KEY                    (Gap A/B primary)
  OPENAI_API_KEY                      (Gap C primary / gpt-5.6-luna)
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

try:
    from dotenv import load_dotenv

    load_dotenv(BACKEND_DIR / ".env")
except ImportError:
    pass


def _ok(cond: bool) -> str:
    return "PASS" if cond else "FAIL"


def _check_keys(*, need_deepseek: bool, need_openai: bool) -> List[str]:
    missing: List[str] = []
    if not (os.getenv("GEMINI_API_KEY") or "").strip():
        missing.append("GEMINI_API_KEY")
    if need_deepseek and not (os.getenv("DEEPSEEK_API_KEY") or "").strip():
        missing.append("DEEPSEEK_API_KEY")
    if need_openai and not (os.getenv("OPENAI_API_KEY") or "").strip():
        missing.append("OPENAI_API_KEY")
    return missing


def test_preprocess(ing: Any) -> Tuple[bool, str]:
    samples = ["다진 마늘", "계란 노른자", "양파 1개 (썰어서)"]
    out = ing.preprocess_ingredients(samples)
    expect = {
        "다진 마늘": {"마늘"},
        "계란 노른자": {"계란", "달걀"},
        "양파 1개 (썰어서)": {"양파"},
    }
    bits: List[str] = []
    all_ok = True
    for src, allowed in expect.items():
        got = (out.get(src) or "").strip()
        hit = got in allowed
        all_ok = all_ok and hit
        bits.append(f"{src!r}→{got!r}{'✓' if hit else '✗'}")
    return all_ok, "; ".join(bits)


def test_categorize_patterns(ing: Any) -> Tuple[bool, str]:
    """Pattern-only cases (should not need LLM)."""
    cases = [
        ("굴소스", "seasonings_sauces"),
        ("땅콩버터", "seasonings_sauces"),
        ("강력분", "grains"),
        ("김", "seasonings_sauces"),
        ("계란", "dairy"),
        ("두부", "vegetables_fruits"),
    ]
    bits: List[str] = []
    all_ok = True
    for name, exp in cases:
        got = ing.categorize_ingredient(name)
        cat = got.get("category")
        hit = cat == exp
        all_ok = all_ok and hit
        bits.append(f"{name}={cat}{'✓' if hit else f'✗ want {exp}'}")
    return all_ok, "; ".join(bits)


def test_categorize_llm_residual(ing: Any) -> Tuple[bool, str]:
    """Name unlikely to be pattern-covered — exercises residual LLM path."""
    # Use something odd enough that v3 may miss → LLM; if pattern hits, still OK.
    name = "할라피뇨"
    got = ing.categorize_ingredient(name)
    cat = got.get("category")
    valid = {
        "vegetables_fruits",
        "meat_processed_egg",
        "seafood",
        "dairy",
        "grains",
        "seasonings_sauces",
    }
    hit = cat in valid
    return hit, f"{name}→{cat} (conf={got.get('confidence')})"


def test_unit_price(llm: Any) -> Tuple[bool, str]:
    name = "시금치"
    got = llm.get_ingredient_price_from_ai(name)
    if not got:
        return False, f"{name}→None"
    price = got.get("unitPrice")
    unit = got.get("baseUnit")
    hit = isinstance(price, (int, float)) and float(price) > 0 and unit in ("g", "ml", "개")
    return hit, f"{name}→{price}원/{unit} (conf={got.get('confidence')})"


def run_suite(*, skip_price: bool, force_fallback: bool) -> int:
    print("=" * 60)
    print("Gap A/B/C smoke (no server)")
    if force_fallback:
        print("Mode: --fallback (poison primary keys → expect Gemini)")
        # Poison primary keys in-process so router falls back
        os.environ["DEEPSEEK_API_KEY"] = "invalid-smoke-key"
        os.environ["OPENAI_API_KEY"] = "invalid-smoke-key"
    print("=" * 60)

    need_ds = not force_fallback
    need_oa = not force_fallback and not skip_price
    missing = _check_keys(need_deepseek=need_ds, need_openai=need_oa)
    if missing and not force_fallback:
        print(f"Missing keys in .env: {', '.join(missing)}")
        print("Gemini-only still works if GEMINI_API_KEY is set (primaries will skip).")
    if not (os.getenv("GEMINI_API_KEY") or "").strip():
        print("FATAL: GEMINI_API_KEY required as backup")
        return 2

    # Late imports so .env / poisoned keys are in place first
    from services.ingredient_service import get_ingredient_service
    from services.llm_service import get_llm_service

    ing = get_ingredient_service()
    llm = get_llm_service()

    tests: List[Tuple[str, Callable[[], Tuple[bool, str]]]] = [
        ("A preprocess (DeepSeek→Gemini)", lambda: test_preprocess(ing)),
        ("B categorize patterns (v3)", lambda: test_categorize_patterns(ing)),
        ("B categorize residual LLM", lambda: test_categorize_llm_residual(ing)),
    ]
    if not skip_price and not force_fallback:
        tests.append(("C unit price (DeepSeek once)", lambda: test_unit_price(llm)))

    failed = 0
    for title, fn in tests:
        print(f"\n→ {title}")
        try:
            passed, detail = fn()
        except Exception as e:
            passed, detail = False, f"{type(e).__name__}: {e}"
        print(f"  {_ok(passed)}  {detail}")
        if not passed:
            failed += 1

    print("\n" + "=" * 60)
    if failed:
        print(f"DONE — {failed} failed. Check logs for engine=deepseek|openai|gemini")
        return 1
    print("DONE — all passed. Watch logs for: engine=deepseek / openai / gemini")
    if force_fallback:
        print("Expected fallback lines like: DeepSeek/OpenAI 실패 … -> Gemini")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Smoke-test Gap A/B/C without a server")
    parser.add_argument(
        "--fallback",
        action="store_true",
        help="Poison DEEPSEEK/OPENAI keys to verify Gemini backup path",
    )
    parser.add_argument(
        "--skip-price",
        action="store_true",
        help="Skip Gap C (avoids OpenAI spend)",
    )
    args = parser.parse_args()
    raise SystemExit(run_suite(skip_price=args.skip_price, force_fallback=args.fallback))


if __name__ == "__main__":
    main()
