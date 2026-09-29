"""Mixpanel server_parse_* 이벤트에서 LLM 사용량/비용을 차원별로 집계.

주의: call_type(쿼리별) 속성은 Mixpanel에 전송되지 않음.
가능한 근사 차원: platform / track / pipeline_version / used_ocr / used_asr.

Run: python analytics/analyze_mixpanel_parse_llm_cost.py
"""

from __future__ import annotations

import base64
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = ROOT / "backend" / ".env"
OUT = ROOT / "analytics" / "mixpanel_parse_llm_cost_snapshot.json"

# Gemini 2.5 Flash 대략 단가 (USD / 1M tokens). env 우선.
DEFAULT_INPUT_USD = 0.30
DEFAULT_OUTPUT_USD = 2.50


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def as_int(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0
    return 0


def as_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def export_events(
    secret: str,
    events: list[str],
    from_date: str,
    to_date: str,
) -> list[dict[str, Any]]:
    params = urllib.parse.urlencode(
        {
            "from_date": from_date,
            "to_date": to_date,
            "event": json.dumps(events),
        }
    )
    url = f"https://data.mixpanel.com/api/2.0/export/?{params}"
    auth = base64.b64encode(f"{secret}:".encode()).decode()
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Basic {auth}", "Accept": "text/plain"},
    )
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=300, context=ctx) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    out: list[dict[str, Any]] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        out.append(json.loads(line))
    return out


def estimate_cost_usd(
    *,
    input_tokens: int,
    output_tokens: int,
    thinking_tokens: int,
    input_usd: float,
    output_usd: float,
    thinking_usd: float,
) -> float:
    return (
        (input_tokens / 1_000_000) * input_usd
        + (output_tokens / 1_000_000) * output_usd
        + (thinking_tokens / 1_000_000) * thinking_usd
    )


def empty_bucket() -> dict[str, Any]:
    return {
        "events": 0,
        "llm_calls": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "thinking_tokens": 0,
        "total_tokens": 0,
        "estimated_cost_usd_reported": 0.0,
        "estimated_cost_usd_recalc": 0.0,
        "parse_duration_ms_sum": 0,
        "used_ocr": 0,
        "used_asr": 0,
    }


def add_to_bucket(bucket: dict[str, Any], props: dict[str, Any], rates: dict[str, float]) -> None:
    inp = as_int(props.get("llm_input_tokens"))
    out = as_int(props.get("llm_output_tokens"))
    think = as_int(props.get("llm_thinking_tokens"))
    calls = as_int(props.get("llm_call_count"))
    reported = as_float(props.get("estimated_llm_cost_usd"))
    recalc = estimate_cost_usd(
        input_tokens=inp,
        output_tokens=out,
        thinking_tokens=think,
        input_usd=rates["input"],
        output_usd=rates["output"],
        thinking_usd=rates["thinking"],
    )
    bucket["events"] += 1
    bucket["llm_calls"] += calls
    bucket["input_tokens"] += inp
    bucket["output_tokens"] += out
    bucket["thinking_tokens"] += think
    bucket["total_tokens"] += inp + out + think
    bucket["estimated_cost_usd_reported"] += reported
    bucket["estimated_cost_usd_recalc"] += recalc
    bucket["parse_duration_ms_sum"] += as_int(props.get("parse_duration_ms"))
    bucket["used_ocr"] += as_int(props.get("used_ocr"))
    bucket["used_asr"] += as_int(props.get("used_asr"))


def finalize(bucket: dict[str, Any]) -> dict[str, Any]:
    n = bucket["events"] or 1
    out = dict(bucket)
    out["avg_total_tokens"] = round(bucket["total_tokens"] / n, 1)
    out["avg_llm_calls"] = round(bucket["llm_calls"] / n, 2)
    out["avg_parse_duration_ms"] = round(bucket["parse_duration_ms_sum"] / n, 1)
    out["estimated_cost_usd_reported"] = round(bucket["estimated_cost_usd_reported"], 4)
    out["estimated_cost_usd_recalc"] = round(bucket["estimated_cost_usd_recalc"], 4)
    out["cost_share_basis"] = "estimated_cost_usd_recalc"
    return out


def main() -> None:
    env = load_env(ENV_PATH)
    secret = (env.get("MIXPANEL_API_SECRET") or "").strip()
    if not secret:
        raise SystemExit("MIXPANEL_API_SECRET missing in backend/.env")

    input_usd = as_float(env.get("GEMINI_INPUT_USD_PER_1M_TOKENS")) or DEFAULT_INPUT_USD
    output_usd = as_float(env.get("GEMINI_OUTPUT_USD_PER_1M_TOKENS")) or DEFAULT_OUTPUT_USD
    thinking_usd = as_float(env.get("GEMINI_THINKING_USD_PER_1M_TOKENS")) or output_usd
    rates = {"input": input_usd, "output": output_usd, "thinking": thinking_usd}

    to_d = date.today()
    from_d = to_d - timedelta(days=29)
    from_s, to_s = from_d.isoformat(), to_d.isoformat()

    print(f"[Mixpanel] export {from_s}..{to_s}")
    try:
        rows = export_events(
            secret,
            ["server_parse_completed", "server_parse_failed"],
            from_s,
            to_s,
        )
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise SystemExit(f"export failed: {e.code} {body[:500]}") from e

    print(f"[Mixpanel] events={len(rows)}")

    all_prop_keys: set[str] = set()
    by_event: dict[str, dict[str, Any]] = defaultdict(empty_bucket)
    by_platform: dict[str, dict[str, Any]] = defaultdict(empty_bucket)
    by_track: dict[str, dict[str, Any]] = defaultdict(empty_bucket)
    by_pipeline: dict[str, dict[str, Any]] = defaultdict(empty_bucket)
    by_platform_track: dict[str, dict[str, Any]] = defaultdict(empty_bucket)
    by_error_type: dict[str, dict[str, Any]] = defaultdict(empty_bucket)
    completed_total = empty_bucket()
    failed_total = empty_bucket()
    has_call_type = 0
    has_usage_by_type = 0

    for row in rows:
        event = str(row.get("event") or "")
        props = row.get("properties") or {}
        if not isinstance(props, dict):
            continue
        all_prop_keys.update(str(k) for k in props.keys())
        if "call_type" in props or "llm_call_type" in props:
            has_call_type += 1
        if "llm_usage_by_type" in props:
            has_usage_by_type += 1

        add_to_bucket(by_event[event], props, rates)

        if event == "server_parse_completed":
            add_to_bucket(completed_total, props, rates)
            platform = str(props.get("platform") or "unknown") or "unknown"
            track = str(props.get("track") or "unknown") or "unknown"
            pipeline = str(props.get("pipeline_version") or "unknown") or "unknown"
            add_to_bucket(by_platform[platform], props, rates)
            add_to_bucket(by_track[track], props, rates)
            add_to_bucket(by_pipeline[pipeline], props, rates)
            add_to_bucket(by_platform_track[f"{platform}|{track}"], props, rates)
        elif event == "server_parse_failed":
            add_to_bucket(failed_total, props, rates)
            err = str(props.get("error_type") or "unknown") or "unknown"
            add_to_bucket(by_error_type[err], props, rates)

    def sort_map(m: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
        finalized = {k: finalize(v) for k, v in m.items()}
        return dict(
            sorted(
                finalized.items(),
                key=lambda kv: kv[1]["estimated_cost_usd_recalc"],
                reverse=True,
            )
        )

    completed_final = finalize(completed_total)
    failed_final = finalize(failed_total)
    total_cost = completed_final["estimated_cost_usd_recalc"] or 1.0

    platform_rows = sort_map(by_platform)
    for v in platform_rows.values():
        v["cost_share_pct"] = round(
            100.0 * v["estimated_cost_usd_recalc"] / total_cost, 1
        )

    report = {
        "generated_at": date.today().isoformat(),
        "from_date": from_s,
        "to_date": to_s,
        "source": "Mixpanel Raw Export API",
        "events_exported": len(rows),
        "limitation": (
            "Mixpanel에는 Gemini call_type/쿼리별 속성이 없음. "
            "platform/track/pipeline_version 근사 분석만 가능."
        ),
        "has_call_type_events": has_call_type,
        "has_llm_usage_by_type_events": has_usage_by_type,
        "observed_property_keys": sorted(all_prop_keys),
        "pricing_usd_per_1m": rates,
        "pricing_note": (
            "GEMINI_*_USD_PER_1M_TOKENS env가 0/미설정이면 Flash 기본 "
            f"input={DEFAULT_INPUT_USD}/output={DEFAULT_OUTPUT_USD} 사용. "
            "estimated_cost_usd_reported는 이벤트 적재 시점 env 기준."
        ),
        "totals": {
            "server_parse_completed": completed_final,
            "server_parse_failed": failed_final,
            "by_event": sort_map(by_event),
        },
        "by_platform": platform_rows,
        "by_track": sort_map(by_track),
        "by_pipeline_version": sort_map(by_pipeline),
        "by_platform_track": sort_map(by_platform_track),
        "failed_by_error_type": sort_map(by_error_type),
    }

    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[OK] wrote {OUT}")
    print(json.dumps(report["totals"]["server_parse_completed"], ensure_ascii=False, indent=2))
    print("--- by_platform ---")
    print(json.dumps(report["by_platform"], ensure_ascii=False, indent=2)[:4000])
    print("--- by_track ---")
    print(json.dumps(report["by_track"], ensure_ascii=False, indent=2)[:2500])
    print("--- by_platform_track top ---")
    print(json.dumps(report["by_platform_track"], ensure_ascii=False, indent=2)[:4000])


if __name__ == "__main__":
    main()
