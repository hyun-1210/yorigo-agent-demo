"""칩/한줄 Gemini 1차·DeepSeek 폴백 단위 테스트."""

from __future__ import annotations

import os
import sys
import types
import unittest
from pathlib import Path
from typing import Any, Dict, List
from unittest import mock

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

if "services" not in sys.modules:
    pkg = types.ModuleType("services")
    pkg.__path__ = [str(BACKEND_DIR / "services")]
    pkg.__file__ = str(BACKEND_DIR / "services" / "__init__.py")
    sys.modules["services"] = pkg

from services.llm_service import (  # noqa: E402
    LLMService,
    character_call_timeout,
    character_provider_order,
    character_response_usable,
)


class CharacterTimeoutHelpersTests(unittest.TestCase):
    def test_default_order_is_gemini_then_deepseek(self) -> None:
        self.assertEqual(character_provider_order(""), ("gemini", "deepseek"))
        self.assertEqual(character_provider_order("gemini"), ("gemini", "deepseek"))
        self.assertEqual(character_provider_order("GEMINI"), ("gemini", "deepseek"))

    def test_deepseek_override_flips_order(self) -> None:
        self.assertEqual(character_provider_order("deepseek"), ("deepseek", "gemini"))

    def test_call_timeout_reserves_fallback_on_12s_slot(self) -> None:
        self.assertEqual(character_call_timeout(12.0, has_fallback=True), 8.0)
        self.assertEqual(character_call_timeout(12.0, has_fallback=False), 12.0)

    def test_response_usable_requires_json_object(self) -> None:
        self.assertTrue(character_response_usable('{"tags":["고소한"]}'))
        self.assertFalse(character_response_usable(""))
        self.assertFalse(character_response_usable("   "))
        self.assertFalse(character_response_usable("I cannot help with that."))

    def test_call_timeout_skips_when_remain_too_small(self) -> None:
        self.assertIsNone(character_call_timeout(1.0, has_fallback=True))
        self.assertIsNone(character_call_timeout(1.0, has_fallback=False))

    def test_call_timeout_does_not_split_tight_remain(self) -> None:
        # 5s는 1차 4s + 폴백 1.5s 미만 → 1차에 전부 주고 폴백은 시간이 남으면.
        self.assertEqual(character_call_timeout(5.0, has_fallback=True), 5.0)


class CharacterGenerateEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self._saved = {
            k: os.environ.get(k)
            for k in (
                "GEMINI_API_KEY",
                "DEEPSEEK_API_KEY",
                "TAG_CHARACTER_ENGINE",
                "TAG_TAGLINE_ENGINE",
                "GEMINI_THINKING_FORCE",
            )
        }
        os.environ["GEMINI_API_KEY"] = "test-gemini"
        os.environ["DEEPSEEK_API_KEY"] = "test-deepseek"
        os.environ.pop("TAG_CHARACTER_ENGINE", None)
        os.environ.pop("TAG_TAGLINE_ENGINE", None)
        os.environ.pop("GEMINI_THINKING_FORCE", None)

    def tearDown(self) -> None:
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def _svc(self) -> LLMService:
        llm = LLMService()
        llm._gemini_api_key = "test-gemini"
        return llm

    def _patch(
        self,
        llm: LLMService,
        *,
        gemini: Any = '{"ok":1}',
        deepseek: Any = '{"ok":2}',
    ) -> List[str]:
        order: List[str] = []
        gemini_kw: List[Dict[str, Any]] = []

        def _g(**kwargs: Any) -> str:
            order.append("gemini")
            gemini_kw.append(kwargs)
            if isinstance(gemini, Exception):
                raise gemini
            return str(gemini)

        def _d(**kwargs: Any) -> str:
            order.append("deepseek")
            if isinstance(deepseek, Exception):
                raise deepseek
            return str(deepseek)

        llm._gemini_generate_text = _g  # type: ignore[method-assign]
        llm._deepseek_generate_text = _d  # type: ignore[method-assign]
        llm._gemini_kwargs = gemini_kw  # type: ignore[attr-defined]
        return order

    def test_default_calls_gemini_only(self) -> None:
        llm = self._svc()
        order = self._patch(llm)
        text = llm._character_generate_text(
            system="s", user="u", call_type="select_character", timeout=12
        )
        self.assertEqual(text, '{"ok":1}')
        self.assertEqual(order, ["gemini"])

    def test_gemini_timeout_is_not_330s_and_reserves_fallback(self) -> None:
        llm = self._svc()
        order = self._patch(llm)
        llm._character_generate_text(
            system="s", user="u", call_type="write_tagline", timeout=12
        )
        kw = llm._gemini_kwargs[0]  # type: ignore[attr-defined]
        self.assertAlmostEqual(float(kw["timeout"]), 8.0, places=2)
        self.assertEqual(kw["max_retries"], 1)
        self.assertEqual(kw["thinking_budget"], 0)
        self.assertTrue(kw["ignore_thinking_force"])
        self.assertEqual(order, ["gemini"])

    def test_primary_timeout_uses_slot_budget_not_elapsed_remain(self) -> None:
        llm = self._svc()
        ticks = [0.0, 0.04]

        def _mono() -> float:
            return ticks.pop(0) if len(ticks) > 1 else ticks[0]

        order = self._patch(llm)
        with mock.patch("services.llm_service.time.monotonic", side_effect=_mono):
            llm._character_generate_text(
                system="s", user="u", call_type="select_character", timeout=12
            )
        kw = llm._gemini_kwargs[0]  # type: ignore[attr-defined]
        self.assertEqual(float(kw["timeout"]), 8.0)
        self.assertEqual(order, ["gemini"])

    def test_gemini_failure_falls_back_to_deepseek(self) -> None:
        llm = self._svc()
        order = self._patch(llm, gemini=RuntimeError("gemini down"))
        text = llm._character_generate_text(
            system="s", user="u", call_type="select_character", timeout=12
        )
        self.assertEqual(text, '{"ok":2}')
        self.assertEqual(order, ["gemini", "deepseek"])

    def test_empty_gemini_falls_back_to_deepseek(self) -> None:
        llm = self._svc()
        order = self._patch(llm, gemini="   ")
        text = llm._character_generate_text(
            system="s", user="u", call_type="write_tagline", timeout=12
        )
        self.assertEqual(text, '{"ok":2}')
        self.assertEqual(order, ["gemini", "deepseek"])

    def test_non_json_gemini_falls_back_to_deepseek(self) -> None:
        llm = self._svc()
        order = self._patch(llm, gemini="I cannot help with that.")
        text = llm._character_generate_text(
            system="s", user="u", call_type="select_character", timeout=12
        )
        self.assertEqual(text, '{"ok":2}')
        self.assertEqual(order, ["gemini", "deepseek"])

    def test_missing_gemini_key_goes_straight_to_deepseek(self) -> None:
        os.environ.pop("GEMINI_API_KEY", None)
        llm = self._svc()
        llm._gemini_api_key = None
        order = self._patch(llm)
        text = llm._character_generate_text(
            system="s", user="u", call_type="select_character", timeout=12
        )
        self.assertEqual(text, '{"ok":2}')
        self.assertEqual(order, ["deepseek"])

    def test_engine_deepseek_calls_deepseek_first(self) -> None:
        os.environ["TAG_CHARACTER_ENGINE"] = "deepseek"
        llm = self._svc()
        order = self._patch(llm)
        text = llm._character_generate_text(
            system="s", user="u", call_type="select_character", timeout=12
        )
        self.assertEqual(text, '{"ok":2}')
        self.assertEqual(order, ["deepseek"])

    def test_no_keys_raises(self) -> None:
        os.environ.pop("GEMINI_API_KEY", None)
        os.environ.pop("DEEPSEEK_API_KEY", None)
        llm = self._svc()
        llm._gemini_api_key = None
        with self.assertRaises(RuntimeError) as ctx:
            llm._character_generate_text(
                system="s", user="u", call_type="select_character", timeout=12
            )
        self.assertIn("no LLM key", str(ctx.exception))

    def test_thinking_force_does_not_override_character_budget(self) -> None:
        os.environ["GEMINI_THINKING_FORCE"] = "24576"
        llm = self._svc()
        captured: Dict[str, Any] = {}

        def _record(**kwargs: Any) -> str:
            captured.update(kwargs)
            return '{"ok":1}'

        llm._gemini_generate_text = _record  # type: ignore[method-assign]
        llm._character_generate_text(
            system="s", user="u", call_type="select_character", timeout=12
        )
        self.assertEqual(captured.get("thinking_budget"), 0)
        self.assertTrue(captured.get("ignore_thinking_force"))

    def test_skips_fallback_when_primary_ate_the_slot(self) -> None:
        llm = self._svc()
        order: List[str] = []
        ticks = [0.0, 0.0, 11.2]

        def _mono() -> float:
            return ticks.pop(0) if len(ticks) > 1 else ticks[0]

        def _g(**kwargs: Any) -> str:
            order.append("gemini")
            raise RuntimeError("gemini timeout")

        def _d(**kwargs: Any) -> str:
            order.append("deepseek")
            return '{"ok":2}'

        llm._gemini_generate_text = _g  # type: ignore[method-assign]
        llm._deepseek_generate_text = _d  # type: ignore[method-assign]
        with mock.patch("services.llm_service.time.monotonic", side_effect=_mono):
            with self.assertRaises(RuntimeError) as ctx:
                llm._character_generate_text(
                    system="s", user="u", call_type="select_character", timeout=12
                )
        self.assertEqual(order, ["gemini"])
        self.assertIn("gemini timeout", str(ctx.exception))

    def test_deepseek_fallback_uses_remaining_not_5s_cap(self) -> None:
        llm = self._svc()
        ds_kw: List[Dict[str, Any]] = []

        def _g(**kwargs: Any) -> str:
            raise RuntimeError("gemini down")

        def _d(**kwargs: Any) -> str:
            ds_kw.append(kwargs)
            return '{"ok":2}'

        llm._gemini_generate_text = _g  # type: ignore[method-assign]
        llm._deepseek_generate_text = _d  # type: ignore[method-assign]
        llm._character_generate_text(
            system="s", user="u", call_type="select_character", timeout=12
        )
        self.assertEqual(ds_kw[0]["max_retries"], 1)
        self.assertGreaterEqual(float(ds_kw[0]["timeout"]), 10.0)


if __name__ == "__main__":
    unittest.main()
