"""클라우드에서 홈 검색 도우미를 직접 띄워 프롬프트를 넣는 QA 서버.

인증/라우터 플래그 없이 HomeAgentService.run_turn 만 호출한다. 포트 8766.

  HOME_AGENT_ENABLED=1 backend/.venv/bin/python scripts/qa_home_agent_live.py
"""

from __future__ import annotations

import os
import sys
import time
import types
from pathlib import Path
from typing import Any, Dict, List, Optional

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))


def _namespace(name: str, path: Path) -> None:
    if name in sys.modules:
        return
    pkg = types.ModuleType(name)
    pkg.__path__ = [str(path)]
    pkg.__file__ = str(path / "__init__.py")
    sys.modules[name] = pkg


_namespace("services", BACKEND / "services")

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from services.home_agent_service import HomeAgentService

HTML = """<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8"/>
  <title>검색 도우미 QA</title>
  <style>
    body { font-family: sans-serif; max-width: 780px; margin: 24px auto 80px; }
    #log { white-space: pre-wrap; background: #111; color: #eee; padding: 12px;
           min-height: 240px; max-height: 480px; overflow: auto; font-size: 13px; }
    input, button { font-size: 16px; padding: 8px; }
    input { width: 62%; }
    .pick { border: 1px solid #ddd; padding: 8px; margin: 8px 0; }
    .meta { color: #666; font-size: 12px; }
  </style>
</head>
<body>
  <h1>검색 도우미 QA</h1>
  <p class="meta">grounded-rank-v1 · 닫힌 후보만 · 카드 필드 인용</p>
  <div id="log"></div>
  <div id="picks"></div>
  <p>
    <input id="msg" placeholder="예: 김치찌개 추천해줘" />
    <button id="send" type="button">보내기</button>
  </p>
  <p>
    <button type="button" data-q="김치찌개">김치찌개</button>
    <button type="button" data-q="김치찌개 추천해줘">추천</button>
    <button type="button" data-q="매운 거 땡겨">매운 거</button>
    <button type="button" data-q="뭐 해먹지">뭐 해먹지</button>
    <button type="button" data-q="닭가슴살 남은 거">닭가슴살</button>
    <button type="button" data-q="10분 안에">빨리</button>
    <button type="button" data-q="해장">해장</button>
    <button type="button" data-q="고단백">고단백</button>
    <button type="button" data-q="숙제 수학 문제 풀어줘">off-topic</button>
  </p>
  <script>
    const log = document.getElementById('log');
    const picks = document.getElementById('picks');
    const input = document.getElementById('msg');
    function line(t) { log.textContent += t + '\\n'; log.scrollTop = log.scrollHeight; }
    async function send(text) {
      const q = (text || input.value || '').trim();
      if (!q) return;
      input.value = '';
      line('> ' + q);
      picks.innerHTML = '';
      const t0 = Date.now();
      const res = await fetch('/turn', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({message: q}),
      });
      const body = await res.json();
      const ms = Date.now() - t0;
      line(JSON.stringify({
        ms, retrieve: body.retrieve, used_llm: body.used_llm, used_ranker: body.used_ranker,
        spice_high: body.spice_high, spice_low: body.spice_low, q: body.q,
        engine: body.engine, warnings: body.warnings, ids: body.recipe_ids,
      }, null, 2));
      line(body.reply || '');
      (body.picks || []).forEach((p, i) => {
        const div = document.createElement('div');
        div.className = 'pick';
        div.textContent = (i+1) + '. ' + (p.name || p.recipe_id) + '\\n' + (p.reason || '');
        picks.appendChild(div);
      });
    }
    document.getElementById('send').onclick = () => send();
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') send(); });
    document.querySelectorAll('button[data-q]').forEach(b => {
      b.onclick = () => send(b.getAttribute('data-q'));
    });
  </script>
</body>
</html>
"""


class TurnIn(BaseModel):
    message: Optional[str] = Field(default=None, max_length=500)
    chip_id: Optional[str] = Field(default=None, max_length=40)
    focus_ingredient: Optional[str] = Field(default=None, max_length=80)


SERVICE = HomeAgentService()


def _pick_names(result: Dict[str, Any]) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    # live HTML 에 이름을 붙이려고 서비스가 반환한 picks 만 쓴다.
    for row in result.get("picks") or []:
        if not isinstance(row, dict):
            continue
        out.append(
            {
                "recipe_id": str(row.get("recipe_id") or ""),
                "reason": str(row.get("reason") or ""),
                "name": str(row.get("name") or ""),
            }
        )
    return out


app = FastAPI()


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return HTML


@app.post("/turn")
def turn(body: TurnIn) -> Dict[str, Any]:
    t0 = time.time()
    result = SERVICE.run_turn(
        chip_id=body.chip_id,
        message=body.message,
        focus_ingredient=body.focus_ingredient,
        history=[],
    )
    elapsed_ms = int((time.time() - t0) * 1000)
    result["elapsed_ms"] = elapsed_ms
    result["picks"] = _pick_names(result)
    return result


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("QA_HOME_AGENT_PORT") or "8766")
    print(f"[qa-home] http://127.0.0.1:{port}", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=port)
