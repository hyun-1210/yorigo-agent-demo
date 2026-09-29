"""클라우드에서 상세 레시피 도우미를 직접 띄워 프롬프트를 넣는 QA 서버.

인증/라우터 플래그 없이 RecipeAgentService.run_turn 만 호출한다.
기본은 Firestore recipes/{QA_RECIPE_ID}. 포트 8765.

  QA_RECIPE_ID=009Rtpj2yjttZN6b2Raj RECIPE_AGENT_ENABLED=1 \\
    backend/.venv/bin/python scripts/qa_recipe_agent_live.py
"""

from __future__ import annotations

import os
import sys
import types
from pathlib import Path

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

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from typing import Any, Dict, List, Optional

from services.recipe_agent_service import RecipeAgentService
from services.recipe_overlay import firestore_doc_to_base


DEFAULT_RECIPE_ID = "009Rtpj2yjttZN6b2Raj"  # 고추장 크림 파스타
FALLBACK = {
    "name": "고추장 크림 파스타",
    "servings": 1,
    "ingredients": [
        {"item": "파스타면", "qty": 70.0, "unit": "g"},
        {"item": "저당 고추장", "qty": 2.0, "unit": "큰술"},
        {"item": "우삼겹", "qty": 200.0, "unit": "g"},
        {"item": "양파", "qty": 0.5, "unit": "개"},
        {"item": "무가당 저지방 그릭요거트", "qty": 3.5, "unit": "큰술"},
    ],
    "steps": [
        {"order": 1, "instruction": "물에 소금을 넣고 끓인다."},
        {"order": 2, "instruction": "파스타면을 삶는다."},
        {"order": 3, "instruction": "양념장을 만든다."},
        {"order": 4, "instruction": "우삼겹과 양파를 굽는다."},
        {"order": 5, "instruction": "양념과 면을 볶고 요거트를 넣는다."},
    ],
}


def _load_recipe() -> tuple:
    """Firestore 공개 레시피를 읽고, 실패하면 폴백 스냅샷을 쓴다."""
    rid = (os.getenv("QA_RECIPE_ID") or DEFAULT_RECIPE_ID).strip()
    try:
        from services.firebase_service import get_firebase_service

        fb = get_firebase_service()
        if fb.db is None:
            raise RuntimeError("firestore_unavailable")
        snap = fb.db.collection("recipes").document(rid).get()
        if not snap.exists:
            raise KeyError(f"recipe_not_found:{rid}")
        base = firestore_doc_to_base(snap.to_dict() or {})
        if not base.get("ingredients") or not base.get("steps"):
            raise ValueError("recipe_incomplete")
        print(f"[qa-live] firestore {rid} {base.get('name')}", flush=True)
        return rid, base
    except Exception as exc:  # noqa: BLE001
        print(f"[qa-live] firestore 실패 ({type(exc).__name__}: {exc}) -> fallback", flush=True)
        return None, FALLBACK


RECIPE_ID, RECIPE = _load_recipe()

HTML = """<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8"/>
  <title>레시피 도우미 QA</title>
  <style>
    body { font-family: sans-serif; max-width: 720px; margin: 24px auto 120px; }
    #log { white-space: pre-wrap; background: #111; color: #eee; padding: 12px; min-height: 180px; max-height: 360px; overflow: auto; }
    input, button { font-size: 16px; padding: 8px; }
    input { width: 58%; }
    #dock { position: sticky; bottom: 0; background: #fff; padding: 12px 0 8px; border-top: 1px solid #ddd; }
    #confirm { display: none; margin: 0 0 10px; padding: 10px; background: #fff7ed; border: 1px solid #fdba74; }
    #confirm b { display: block; margin-bottom: 8px; }
    #yes { background: #16a34a; color: #fff; border: 0; margin-right: 8px; }
    #no { background: #e11d48; color: #fff; border: 0; }
  </style>
</head>
<body>
  <h1 id="title">레시피 도우미 QA</h1>
  <p id="status">confirm-v2</p>
  <div id="log"></div>
  <div id="dock">
    <div id="confirm">
      <b>이렇게 수정할 수 있습니다. 진행할까요?</b>
      <div id="diffs"></div>
      <button id="yes" type="button">네</button>
      <button id="no" type="button">아니오</button>
    </div>
    <input id="msg" placeholder="프롬프트" />
    <button id="send" type="button">보내기</button>
  </div>
  <script>
    let pendingPatches = [];
    let awaitingConfirm = false;
    const YES = new Set(['네','예','응','ㅇㅇ','진행','진행할게요','좋아요','ok','yes','ㄱㄱ','고고','go']);
    const NO = new Set(['아니','아니오','아니요','취소','됐어','no']);
    function fold(s) {
      return (s || '').trim().toLowerCase().replace(/\\s+/g, '').replace(/[.!?~…,]+$/g, '');
    }
    async function boot() {
      const s = await (await fetch('/status')).json();
      document.getElementById('title').textContent = '레시피 도우미 QA · ' + (s.recipe || '');
      document.getElementById('status').textContent =
        'confirm-v2 · ' + (s.source || '') + ' · ' +
        (s.has_llm_key ? ('LLM 준비됨 · ' + s.keys.join(', ')) : 'LLM 키 없음');
      document.getElementById('yes').onclick = function() { sendText('네'); };
      document.getElementById('no').onclick = function() { sendText('아니오'); };
      document.getElementById('send').onclick = send;
      try {
        const saved = JSON.parse(sessionStorage.getItem('qaPending') || '[]');
        if (Array.isArray(saved) && saved.length) pendingPatches = saved;
        awaitingConfirm = sessionStorage.getItem('qaAwaiting') === '1';
        renderConfirm();
      } catch (e) {}
    }
    function renderConfirm() {
      const box = document.getElementById('confirm');
      const diffs = document.getElementById('diffs');
      const on = awaitingConfirm && pendingPatches.length > 0;
      box.style.display = on ? 'block' : 'none';
      diffs.textContent = on ? pendingPatches.map(function(p) {
        return (p.action || '') + ' ' + (p.item || p.order || '');
      }).join(' · ') : '';
    }
    function persist() {
      sessionStorage.setItem('qaPending', JSON.stringify(pendingPatches || []));
      sessionStorage.setItem('qaAwaiting', awaitingConfirm ? '1' : '0');
    }
    async function sendText(msg) {
      document.getElementById('msg').value = msg;
      await send();
    }
    async function send() {
      const msg = document.getElementById('msg').value;
      if (!msg) return;
      const log = document.getElementById('log');
      log.textContent += '\\nUSER: ' + msg + '\\n...\\n';
      log.scrollTop = log.scrollHeight;
      const payload = {message: msg};
      const yesNo = YES.has(fold(msg)) || NO.has(fold(msg));
      if ((awaitingConfirm || yesNo) && pendingPatches.length) {
        payload.pending_patches = pendingPatches;
      }
      const res = await fetch('/turn', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(payload)
      });
      const body = await res.json();
      log.textContent += JSON.stringify(body, null, 2) + '\\n';
      log.scrollTop = log.scrollHeight;
      document.getElementById('msg').value = '';
      pendingPatches = body.proposed_patches || [];
      awaitingConfirm = body.awaiting_confirm === true;
      persist();
      renderConfirm();
    }
    boot();
  </script>
</body>
</html>
"""


class TurnIn(BaseModel):
    message: Optional[str] = Field(default=None, max_length=500)
    chip_id: Optional[str] = Field(default=None, max_length=40)
    focus_ingredient: Optional[str] = Field(default=None, max_length=80)
    snapshot: Optional[Dict[str, Any]] = None
    overlay: Optional[Dict[str, Any]] = None
    history: Optional[List[Dict[str, str]]] = None
    pending_patches: Optional[List[Dict[str, Any]]] = None


app = FastAPI(title="recipe-helper-qa")
_service = RecipeAgentService()


def _llm_keys() -> List[str]:
    found: List[str] = []
    if os.getenv("DEEPSEEK_API_KEY"):
        found.append("deepseek")
    if os.getenv("GEMINI_API_KEY"):
        found.append("gemini")
    return found


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return HTML


@app.get("/status")
def status() -> Dict[str, Any]:
    keys = _llm_keys()
    return {
        "ok": True,
        "has_llm_key": bool(keys),
        "keys": keys,
        "recipe": RECIPE["name"],
        "recipe_id": RECIPE_ID,
        "source": "firestore" if RECIPE_ID else "fallback",
        "servings": RECIPE["servings"],
        "ingredient_count": len(RECIPE["ingredients"]),
        "step_count": len(RECIPE["steps"]),
    }


@app.post("/turn")
def turn(body: TurnIn) -> Dict[str, Any]:
    if not _llm_keys() and (body.message or body.chip_id):
        # 가드만 통과하는 질문도 키가 없으면 LLM 턴에서 실패한다.
        pass
    try:
        return _service.run_turn(
            recipe_id=None if body.snapshot else RECIPE_ID,
            chip_id=body.chip_id,
            message=body.message,
            focus_ingredient=body.focus_ingredient,
            overlay=body.overlay,
            client_snapshot=body.snapshot or (None if RECIPE_ID else RECIPE),
            history=body.history,
            pending_patches=body.pending_patches,
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"{type(exc).__name__}: {exc}") from exc


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("QA_PORT", "8765"))
    print(f"[qa-live] recipe helper on http://127.0.0.1:{port}  keys={_llm_keys() or 'NONE'}")
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info")
