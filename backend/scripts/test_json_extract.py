"""Unit test for the bracket-aware JSON extractors."""

from __future__ import annotations

import io
import sys
from pathlib import Path

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from services.llm_service import LLMService  # type: ignore  # noqa: E402


def assert_eq(got, want, label):
    ok = got == want
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {label}: got={got!r}")
    if not ok:
        print(f"          want={want!r}")
    return ok


# Access bound methods via an unconstructed proxy: use static helpers directly.
scan = LLMService._scan_balanced
strip_fences = LLMService._strip_md_fences


class Fake(LLMService):
    def __init__(self):
        pass


svc = Fake()
all_pass = True

# ── Case 1: plain JSON object, no prose ──
text = '{"a": 1, "b": 2}'
all_pass &= assert_eq(svc._extract_json_object(text), {"a": 1, "b": 2}, "plain object")

# ── Case 2: trailing "Extra data" (the DXBAhCxkepU failure mode) ──
text = '{"recipe": {"title": "x", "steps": [1, 2]}}\n\nHere is another object:\n{"commentary": "text"}'
all_pass &= assert_eq(
    svc._extract_json_object(text),
    {"recipe": {"title": "x", "steps": [1, 2]}},
    "trailing second object (the real bug)",
)

# ── Case 3: markdown code fence ──
text = '```json\n{"ok": true, "nested": {"deep": [1, 2, 3]}}\n```'
all_pass &= assert_eq(
    svc._extract_json_object(text),
    {"ok": True, "nested": {"deep": [1, 2, 3]}},
    "markdown code fence",
)

# ── Case 4: prose before and after ──
text = 'Here is the JSON you requested:\n{"x": [1, 2]}\nHope that helps!'
all_pass &= assert_eq(svc._extract_json_object(text), {"x": [1, 2]}, "prose before+after")

# ── Case 5: string contains literal braces (must not confuse scanner) ──
text = '{"note": "use {braces} carefully", "k": 1}'
all_pass &= assert_eq(
    svc._extract_json_object(text),
    {"note": "use {braces} carefully", "k": 1},
    "string contains braces",
)

# ── Case 6: escaped quote inside string ──
text = r'{"msg": "he said \"hi\"", "n": 5}'
all_pass &= assert_eq(
    svc._extract_json_object(text),
    {"msg": 'he said "hi"', "n": 5},
    "escaped quotes",
)

# ── Case 7: array extraction with trailing data ──
text = '[1, 2, {"k": 3}]\n\nExtra commentary here'
all_pass &= assert_eq(
    svc._extract_json_array(text),
    [1, 2, {"k": 3}],
    "array with trailing data",
)

# ── Case 8: nested array of arrays with prose ──
text = 'Sure! [[1, 2], [3, 4]]'
all_pass &= assert_eq(
    svc._extract_json_array(text),
    [[1, 2], [3, 4]],
    "nested arrays with prose",
)

print("\n" + ("ALL PASS" if all_pass else "SOME FAILED"))
sys.exit(0 if all_pass else 1)
