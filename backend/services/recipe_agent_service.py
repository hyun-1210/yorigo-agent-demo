"""레시피 상세 에이전트 턴 로직.

원본 recipes 문서는 읽기만 한다. 이 레시피를 출발점으로 두고,
바꿀·넣을 내용은 웹 검색 노트와 패치로 제안한다. 반영은 로컬 overlay.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any, Dict, List, Optional, Sequence, Tuple

from services.recipe_overlay import (
    MAX_INSTRUCTION_CHARS,
    apply_overlay,
    client_snapshot_to_base,
    compact_snapshot,
    firestore_doc_to_base,
)

logger = logging.getLogger(__name__)

OFF_TOPIC_REPLY = "이 레시피에 대한 질문만 답할 수 있어요."
ERROR_REPLY = "지금은 답할 수 없어요. 잠시 후 다시 시도해 주세요."
CONFIRM_ASK = "이렇게 수정할 수 있습니다. 진행할까요?"
CONFIRMED_REPLY = "이 카드에 반영할게요."
DECLINED_REPLY = "반영하지 않았어요."
NEED_CONFIRM_REQUEST_REPLY = "어떤 수정을 진행할지 다시 말해 주세요."
STALE_CONFIRM_REPLY = "이 제안은 지금 카드 상태와 맞지 않아요. 다시 말해 주세요."
MAX_MESSAGE_CHARS = 500
MAX_CLIENT_SNAPSHOT_BYTES = 8 * 1024
MAX_PATCHES = 8
MAX_REPLY_CHARS = 400
CHANGE_CHIPS = (
    "missing_ingredient",
    "less_spicy",
    "air_fryer",
    "easier_step",
)
CONFIRM_CHIPS = (
    "confirm",
    "decline",
)
ALLOWED_CHIPS = CHANGE_CHIPS
CONFIRM_YES_EXACT = {
    "네",
    "예",
    "응",
    "ㅇㅇ",
    "진행",
    "진행할게요",
    "진행해줘",
    "진행할께",
    "좋아요",
    "그래",
    "해줘",
    "반영",
    "반영해줘",
    "ok",
    "okay",
    "yes",
    "ㅇㅋ",
    "ㄱㄱ",
    "고고",
    "go",
}
CONFIRM_NO_EXACT = {
    "아니",
    "아니오",
    "아니요",
    "아냐",
    "싫어",
    "취소",
    "됐어",
    "됐음",
    "안해",
    "안돼",
    "안됨",
    "no",
}
CHANGE_MARKERS = (
    "없으면",
    "대체",
    "추가해",
    "추가하",
    "넣어줘",
    "넣고 싶",
    "바꿔",
    "에어프라이",
    "오븐",
    "전자레인지",
    "덜 맵",
    "쉽게",
    "팬이 없",
    "냄비가 없",
    "대신",
    "빼줘",
    "빼고",
    "빼도",
    "안넣",
    "안 넣",
    "생략",
    "삭제",
    "줄여",
)
CHIP_PROMPTS = {
    "missing_ingredient": "이 재료가 없을 때 원래 재료는 remove, 대체는 add 패치로 이 레시피를 어떻게 바꾸면 되나요?",
    "less_spicy": "이 레시피를 덜 맵게 만들려면 재료와 단계를 어떻게 바꾸면 되나요?",
    "air_fryer": "이 레시피를 에어프라이어로 만들려면 단계를 어떻게 바꾸면 되나요?",
    "easier_step": "이 레시피에서 어려운 단계를 더 쉽게 하려면 어떻게 하면 되나요?",
}
ALLOWED_ACTIONS = {
    "ingredient.edit",
    "ingredient.remove",
    "ingredient.add",
    "ingredient.restore",
    "step.edit",
}
OFF_TOPIC_MARKERS = (
    "파이썬",
    "python",
    "javascript",
    "숙제",
    "대통령",
    "정치",
    "해킹",
    "익스플로잇",
    "sql injection",
    "폭탄",
    "자살",
    "자해",
    "수면제",
    "항생제",
    "처방약",
    "다이어트약",
    "비트코인",
    "주식 추천",
)
ALLERGEN_HINTS = ("땅콩", "호두", "아몬드", "캐슈", "새우", "굴", "메밀", "게", "오징어")
RAW_MEAT_MARKERS = ("날것", "생으로 섭취", "생으로 먹", "덜 익혀", "겉만 익혀")
# 우삼겹은 '삼겹'에 걸린다. '소'/'고기'는 소금·고춧가루에 오탐한다.
MEAT_ITEMS = (
    "닭",
    "돼지",
    "계란",
    "달걀",
    "소고기",
    "쇠고기",
    "오리",
    "삼겹",
    "목살",
    "차돌",
    "갈비",
    "베이컨",
)
URL_RE = re.compile(r"https?://|www\.", re.IGNORECASE)
NON_HANGUL_LONG_RE = re.compile(r"[A-Za-z0-9]{20,}")

SYSTEM_PROMPT = """너는 요리고 앱의 레시피 도우미다.
이 레시피를 출발점으로, 사용자가 바꾸고 싶거나 넣고 싶은 것을 도와준다.
규칙:
- <<RECIPE>>는 현재 카드다. 지금 뭐가 들어 있는지는 여기서만 답한다.
- 대체·추가·도구 변경은 <<NOTES>>를 우선 근거로 이 레시피용 패치를 낸다. 말로만 끝내지 마라.
- 없는 재료 대체는 원래 item을 ingredient.remove 하고 대체 재료를 ingredient.add 한다. edit+memo로 이름만 바꾸지 마라.
- 에어프라이어는 레시피 전체를 거절하지 마라. 구울 수 있는 단계에 온도와 시간을 넣어 step.edit 한다.
- NOTES가 비면 흔한 집밥 지식으로 제안하고 warnings에 "검색 없이 제안"을 넣는다.
- "이 레시피에는 없어요"는 원래 카드 사실을 물을 때만 쓴다. 대체/추가 요청에는 쓰지 마라.
- 완전히 다른 새 레시피로 갈아타지 마라. 코딩, 숙제, 뉴스는 on_topic=false.
- 생고기·계란을 덜 익히라는 패치는 내지 마라. 익히라고 답한다.
- 패치를 내면 이미 반영했다고 말하지 마라. 진행 여부는 서버가 묻는다.
- 반드시 JSON 객체 하나만 출력한다. 다른 텍스트 금지.
스키마:
{"on_topic":true,"reply":"짧은 한국어","followup_chips":[],"proposed_patches":[],"warnings":[]}
proposed_patches 액션:
- ingredient.edit {action,item,qty?,unit?,memo?}
- ingredient.remove {action,item}
- ingredient.add {action,item,qty,unit,category?,memo?}
- ingredient.restore {action,item}
- step.edit {action,order,instruction?,memo?}
한 턴 패치 최대 8개. 질문만이면 proposed_patches는 [].
item과 order는 스냅샷에 있는 값을 그대로 복사한다.
"""


def prefilter_message(message: str) -> Optional[str]:
    """LLM 호출 전 거절 사유. 통과면 None."""
    text = (message or "").strip()
    if not text:
        return "empty"
    if len(text) > MAX_MESSAGE_CHARS:
        return "too_long"
    lowered = text.lower()
    for marker in OFF_TOPIC_MARKERS:
        if marker.lower() in lowered or marker in text:
            return "off_topic"
    return None


def _norm_confirm_text(text: str) -> str:
    """네/아니오 비교용으로 공백·문장부호를 접는다."""
    folded = "".join((text or "").strip().lower().split())
    return folded.rstrip(".!?~…,")


def is_confirm_yes(text: str) -> bool:
    """유저가 제안 수정을 진행한다고 답했는지."""
    return _norm_confirm_text(text) in CONFIRM_YES_EXACT


def is_confirm_no(text: str) -> bool:
    """유저가 제안 수정을 거절했는지."""
    return _norm_confirm_text(text) in CONFIRM_NO_EXACT


def needs_research(chip_id: Optional[str], message: str) -> bool:
    """대체·추가·도구 변경이면 검색 노트가 필요하다."""
    if (chip_id or "").strip() in CHANGE_CHIPS:
        return True
    text = (message or "").strip()
    return any(marker in text for marker in CHANGE_MARKERS)


def research_question(
    *,
    chip_id: Optional[str],
    message: str,
    focus_ingredient: Optional[str],
    recipe_name: str,
) -> str:
    """검색에 넣을 한 줄 질문."""
    name = (recipe_name or "이 요리").strip() or "이 요리"
    chip = (chip_id or "").strip()
    focus = (focus_ingredient or "").strip()
    if chip == "missing_ingredient" and focus:
        return f"{name}에서 {focus}가 없을 때 대체 재료와 넣는 시점"
    if chip == "less_spicy":
        return f"{name} 덜 맵게 만드는 양념 비율과 대체"
    if chip == "air_fryer":
        return f"{name} 에어프라이어 온도 시간 변형"
    if chip == "easier_step":
        return f"{name} 더 쉽게 만드는 방법 시판 육수 대체"
    msg = (message or "").strip()
    return f"{name}: {msg}"[:180]


def _stable_snapshot_json(snapshot: Dict[str, Any]) -> str:
    """프리픽스 캐시가 먹도록 키 순서를 고정한다."""
    payload = {
        "name": snapshot.get("name") or "",
        "servings": snapshot.get("servings") or 2,
        "ingredients": snapshot.get("ingredients") or [],
        "steps": snapshot.get("steps") or [],
    }
    if snapshot.get("focus_ingredient"):
        payload["focus_ingredient"] = snapshot["focus_ingredient"]
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def build_user_prompt(
    *,
    snapshot: Dict[str, Any],
    truncated: bool,
    chip_id: Optional[str],
    message: str,
    history: Sequence[Dict[str, str]],
    focus_ingredient: Optional[str],
    notes: Optional[Sequence[str]] = None,
    researched: bool = False,
) -> str:
    lines = [
        "<<RECIPE>",
        _stable_snapshot_json(snapshot),
        "<<END_RECIPE>>",
    ]
    if truncated:
        lines.append("NOTE: snapshot truncated.")
    note_lines = [str(n).strip()[:240] for n in (notes or []) if str(n).strip()]
    if note_lines:
        lines.append("<<NOTES>>")
        for note in note_lines[:8]:
            lines.append(f"- {note}")
        lines.append("<<END_NOTES>>")
    elif researched:
        lines.append("NOTE: 검색 결과 없음. 흔한 집밥 지식으로 이 레시피 패치를 제안한다.")
    hist = list(history or [])[-4:]
    if hist:
        lines.append("<<HISTORY>>")
        for turn in hist:
            role = "U" if turn.get("role") == "user" else "A"
            text = str(turn.get("text") or "").strip()[:200]
            if text:
                lines.append(f"{role}: {text}")
        lines.append("<<END_HISTORY>>")
    chip = (chip_id or "").strip()
    if chip:
        lines.append(f"CHIP: {chip}")
        if chip in CHIP_PROMPTS:
            lines.append(CHIP_PROMPTS[chip])
    if focus_ingredient:
        lines.append(f"FOCUS_INGREDIENT: {focus_ingredient}")
    msg = (message or "").strip()
    if msg:
        lines.append("USER:")
        lines.append(msg)
    return "\n".join(lines)


def _normalize_item(item: Any) -> str:
    return " ".join(str(item or "").split()).strip()


def _snapshot_items(snapshot: Dict[str, Any]) -> set:
    return {
        _normalize_item(ing.get("item"))
        for ing in snapshot.get("ingredients") or []
        if _normalize_item(ing.get("item"))
    }


def _snapshot_orders(snapshot: Dict[str, Any]) -> Dict[int, str]:
    out: Dict[int, str] = {}
    for st in snapshot.get("steps") or []:
        try:
            order = int(st.get("order"))
        except (TypeError, ValueError):
            continue
        out[order] = str(st.get("instruction") or "")
    return out


def _hangul_eun_neun(word: str) -> str:
    """마지막 글자 받침에 따라 은/는."""
    ch = (word or "")[-1:]
    if not ch:
        return "은"
    code = ord(ch)
    if 0xAC00 <= code <= 0xD7A3:
        return "은" if (code - 0xAC00) % 28 else "는"
    return "은"


def _qty_ok(qty: Optional[float], unit: str) -> bool:
    if qty is None:
        return True
    if qty <= 0:
        return False
    u = (unit or "").lower()
    if any(x in u for x in ("g", "ml", "그램", "밀리")) and qty > 10000:
        return False
    if any(x in u for x in ("개", "큰술", "작은술", "t", "T")) and qty > 100:
        return False
    return True


def _add_item_ok(item: str) -> bool:
    if not item or len(item) > 20:
        return False
    if URL_RE.search(item) or NON_HANGUL_LONG_RE.search(item):
        return False
    return True


def _recipe_has_meat(snapshot: Dict[str, Any]) -> bool:
    blob = json.dumps(snapshot, ensure_ascii=False)
    return any(m in blob for m in MEAT_ITEMS)


def sanitize_patches(
    raw_patches: Any,
    *,
    snapshot: Dict[str, Any],
    chip_id: Optional[str],
    focus_ingredient: Optional[str],
) -> Tuple[List[Dict[str, Any]], List[str]]:
    """허용 액션만 남기고 스냅샷 가드를 적용한다."""
    warnings: List[str] = []
    if not isinstance(raw_patches, list):
        return [], warnings
    items = _snapshot_items(snapshot)
    orders = _snapshot_orders(snapshot)
    focus = _normalize_item(focus_ingredient)
    meat = _recipe_has_meat(snapshot)
    out: List[Dict[str, Any]] = []
    for raw in raw_patches[:MAX_PATCHES]:
        if not isinstance(raw, dict):
            continue
        action = str(raw.get("action") or "").strip()
        if action not in ALLOWED_ACTIONS:
            continue
        patch: Dict[str, Any] = {"action": action}
        if action.startswith("ingredient."):
            item = _normalize_item(raw.get("item"))
            if not item:
                continue
            if chip_id == "missing_ingredient" and focus and item != focus:
                if action != "ingredient.add":
                    continue
            if action in ("ingredient.edit", "ingredient.remove", "ingredient.restore"):
                if item not in items and action != "ingredient.restore":
                    continue
            if action == "ingredient.add":
                if not _add_item_ok(item):
                    continue
                qty = raw.get("qty")
                try:
                    qty_f = float(qty)
                except (TypeError, ValueError):
                    continue
                unit = str(raw.get("unit") or "").strip()[:20]
                if not _qty_ok(qty_f, unit):
                    continue
                patch["item"] = item
                patch["qty"] = qty_f
                patch["unit"] = unit
                cat = str(raw.get("category") or "").strip()[:20]
                if cat:
                    patch["category"] = cat
                memo = str(raw.get("memo") or "").strip()[:80]
                if memo:
                    patch["memo"] = memo
                if any(a in item for a in ALLERGEN_HINTS):
                    warnings.append(f"{item}{_hangul_eun_neun(item)} 알러지 주의 재료일 수 있어요.")
            else:
                patch["item"] = item
                if action == "ingredient.edit":
                    qty = raw.get("qty")
                    unit = str(raw.get("unit") or "").strip()[:20]
                    try:
                        qty_f = float(qty) if qty is not None else None
                    except (TypeError, ValueError):
                        qty_f = None
                    if qty_f is not None:
                        if not _qty_ok(qty_f, unit):
                            continue
                        patch["qty"] = qty_f
                    if unit:
                        patch["unit"] = unit
                    memo = str(raw.get("memo") or "").strip()[:80]
                    if memo:
                        patch["memo"] = memo
        elif action == "step.edit":
            try:
                order = int(raw.get("order"))
            except (TypeError, ValueError):
                continue
            if order not in orders:
                continue
            original = orders[order]
            instr = str(raw.get("instruction") or "").strip()
            memo = str(raw.get("memo") or "").strip()[:80]
            if instr:
                if len(instr) > MAX_INSTRUCTION_CHARS:
                    continue
                if meat and any(m in instr for m in RAW_MEAT_MARKERS):
                    warnings.append("생고기·계란을 덜 익히라는 제안은 반영하지 않았어요.")
                    continue
                if chip_id == "missing_ingredient" and focus:
                    if focus not in original and focus not in instr:
                        continue
                patch["instruction"] = instr
            if memo:
                patch["memo"] = memo
            patch["order"] = order
            if "instruction" not in patch and "memo" not in patch:
                continue
        out.append(patch)
    return out, warnings


def parse_llm_json(text: str) -> Dict[str, Any]:
    from services.llm_service import get_llm_service

    llm = get_llm_service()
    try:
        return llm._extract_json_object(text)
    except Exception:
        stripped = llm._strip_md_fences(text)
        return json.loads(stripped)


def _clip_reply(reply: str, on_topic: bool) -> str:
    text = (reply or "").strip()
    if not on_topic:
        return OFF_TOPIC_REPLY
    if not text:
        return "이 레시피 기준으로 답할게요."
    if len(text) > MAX_REPLY_CHARS:
        return text[:MAX_REPLY_CHARS].rstrip()
    return text


def _with_confirm_ask(reply: str) -> str:
    """패치 제안에 진행 여부를 붙인다. 이미 있으면 중복하지 않는다."""
    text = _clip_reply(reply, True)
    if CONFIRM_ASK in text:
        return text
    reserved = len(CONFIRM_ASK) + 2
    room = max(1, MAX_REPLY_CHARS - reserved)
    if len(text) > room:
        text = text[:room].rstrip()
    return f"{text}\n\n{CONFIRM_ASK}"


def _turn_response(
    *,
    reply: str,
    on_topic: bool = True,
    followup_chips: Optional[List[str]] = None,
    proposed_patches: Optional[List[Dict[str, Any]]] = None,
    warnings: Optional[List[str]] = None,
    engine: str = "",
    awaiting_confirm: bool = False,
) -> Dict[str, Any]:
    return {
        "on_topic": on_topic,
        "reply": reply,
        "followup_chips": list(followup_chips or []),
        "proposed_patches": list(proposed_patches or []),
        "warnings": list(warnings or []),
        "engine": engine,
        "awaiting_confirm": awaiting_confirm,
    }


def off_topic_response(reply: Optional[str] = None) -> Dict[str, Any]:
    return _turn_response(
        on_topic=False,
        reply=reply or OFF_TOPIC_REPLY,
    )


class RecipeAgentService:
    """상세 화면 레시피 에이전트."""

    def load_base_recipe(
        self,
        *,
        recipe_id: Optional[str],
        client_snapshot: Optional[Dict[str, Any]],
    ) -> Dict[str, Any]:
        rid = (recipe_id or "").strip()
        if rid:
            from services.firebase_service import get_firebase_service

            fb = get_firebase_service()
            if fb.db is None:
                raise RuntimeError("firestore_unavailable")
            snap = fb.db.collection("recipes").document(rid).get()
            if not snap.exists:
                raise KeyError("recipe_not_found")
            data = snap.to_dict() or {}
            return firestore_doc_to_base(data)
        if not isinstance(client_snapshot, dict):
            raise ValueError("client_snapshot_required")
        raw = json.dumps(client_snapshot, ensure_ascii=False)
        if len(raw.encode("utf-8")) > MAX_CLIENT_SNAPSHOT_BYTES:
            raise ValueError("client_snapshot_too_large")
        return client_snapshot_to_base(client_snapshot)

    def build_llm_snapshot(
        self,
        *,
        base: Dict[str, Any],
        overlay: Optional[Dict[str, Any]],
        chip_id: Optional[str],
        focus_ingredient: Optional[str],
    ) -> Tuple[Dict[str, Any], bool]:
        merged = apply_overlay(base, overlay)
        compact, truncated = compact_snapshot(merged)
        return compact, truncated

    def _confirm_pending_patches(
        self,
        *,
        recipe_id: Optional[str],
        overlay: Optional[Dict[str, Any]],
        client_snapshot: Optional[Dict[str, Any]],
        pending_patches: List[Dict[str, Any]],
    ) -> Dict[str, Any]:
        """네 응답이면 보류 패치를 다시 가드하고 반영용으로 돌려준다."""
        if not pending_patches:
            return _turn_response(reply=NEED_CONFIRM_REQUEST_REPLY)
        base = self.load_base_recipe(
            recipe_id=recipe_id,
            client_snapshot=client_snapshot,
        )
        snapshot, _truncated = self.build_llm_snapshot(
            base=base,
            overlay=overlay,
            chip_id=None,
            focus_ingredient=None,
        )
        patches, warnings = sanitize_patches(
            pending_patches,
            snapshot=snapshot,
            chip_id=None,
            focus_ingredient=None,
        )
        if not patches:
            return _turn_response(reply=STALE_CONFIRM_REPLY, warnings=warnings)
        return _turn_response(
            reply=CONFIRMED_REPLY,
            proposed_patches=patches,
            warnings=warnings[:4],
        )

    def run_turn(
        self,
        *,
        recipe_id: Optional[str],
        chip_id: Optional[str],
        message: Optional[str],
        focus_ingredient: Optional[str],
        overlay: Optional[Dict[str, Any]],
        client_snapshot: Optional[Dict[str, Any]],
        history: Optional[List[Dict[str, str]]],
        pending_patches: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        chip = (chip_id or "").strip() or None
        if chip == "servings":
            return _turn_response(reply="인분은 아래에서 직접 바꿔 주세요.")
        user_text = (message or "").strip()
        pending = [
            p for p in (pending_patches or [])[:MAX_PATCHES] if isinstance(p, dict)
        ]
        if chip == "confirm" or is_confirm_yes(user_text):
            return self._confirm_pending_patches(
                recipe_id=recipe_id,
                overlay=overlay,
                client_snapshot=client_snapshot,
                pending_patches=pending,
            )
        if chip == "decline" or is_confirm_no(user_text):
            return _turn_response(reply=DECLINED_REPLY)
        if chip and chip not in ALLOWED_CHIPS:
            chip = None
        if not user_text and chip and chip in CHIP_PROMPTS:
            user_text = CHIP_PROMPTS[chip]
        if chip == "missing_ingredient" and not (focus_ingredient or "").strip():
            return off_topic_response("어떤 재료가 없는지 먼저 골라 주세요.")
        reason = prefilter_message(user_text)
        if reason == "too_long":
            return off_topic_response("질문이 너무 길어요. 짧게 다시 물어봐 주세요.")
        if reason in ("off_topic",):
            return off_topic_response()
        if reason == "empty":
            return off_topic_response("레시피에 대해 궁금한 점을 적어 주세요.")

        base = self.load_base_recipe(
            recipe_id=recipe_id,
            client_snapshot=client_snapshot,
        )
        if chip == "missing_ingredient":
            focus = _normalize_item(focus_ingredient)
            if focus and focus not in _snapshot_items(base):
                return _turn_response(reply=f"이 카드에는 '{focus}'가 없어요.")
        snapshot, truncated = self.build_llm_snapshot(
            base=base,
            overlay=overlay,
            chip_id=chip,
            focus_ingredient=focus_ingredient,
        )
        if not snapshot.get("ingredients") and not snapshot.get("steps"):
            return off_topic_response("이 레시피 정보가 부족해서 답할 수 없어요.")

        researched = needs_research(chip, user_text)
        notes: List[str] = []
        source_hosts: List[str] = []
        from services.llm_service import get_llm_service

        llm = get_llm_service()
        if researched:
            try:
                packed = llm.research_recipe_adaptation(
                    recipe_name=str(snapshot.get("name") or ""),
                    question=research_question(
                        chip_id=chip,
                        message=user_text,
                        focus_ingredient=focus_ingredient,
                        recipe_name=str(snapshot.get("name") or ""),
                    ),
                )
                notes = list(packed.get("notes") or [])
                source_hosts = list(packed.get("sources") or [])
            except Exception as exc:  # noqa: BLE001
                logger.warning("[recipe_agent] research failed: %s", exc)

        user_prompt = build_user_prompt(
            snapshot=snapshot,
            truncated=truncated,
            chip_id=chip,
            message=user_text,
            history=history or [],
            focus_ingredient=focus_ingredient,
            notes=notes,
            researched=researched,
        )

        def _generate(prompt: str) -> Optional[Tuple[Dict[str, Any], str]]:
            raw_text, used_engine = llm.generate_recipe_agent_json(
                system=SYSTEM_PROMPT,
                user=prompt,
            )
            try:
                return parse_llm_json(raw_text), used_engine
            except Exception:
                logger.warning("[recipe_agent] JSON parse failed engine=%s", used_engine)
                return None

        generated = _generate(user_prompt)
        if generated is None:
            return _turn_response(reply=ERROR_REPLY)
        parsed, engine = generated
        on_topic = bool(parsed.get("on_topic", True))
        if not on_topic:
            return _turn_response(
                on_topic=False,
                reply=OFF_TOPIC_REPLY,
                engine=engine,
            )

        patches, warnings = sanitize_patches(
            parsed.get("proposed_patches"),
            snapshot=snapshot,
            chip_id=chip,
            focus_ingredient=focus_ingredient,
        )
        if researched and not patches:
            nudged = user_prompt + "\nNOTE: 이번엔 말로만 끝내지 말고 proposed_patches를 채워라."
            generated2 = _generate(nudged)
            if generated2 is not None:
                parsed2, engine2 = generated2
                if bool(parsed2.get("on_topic", True)):
                    patches2, warnings2 = sanitize_patches(
                        parsed2.get("proposed_patches"),
                        snapshot=snapshot,
                        chip_id=chip,
                        focus_ingredient=focus_ingredient,
                    )
                    if patches2:
                        parsed, engine, patches, warnings = parsed2, engine2, patches2, warnings2
        chips_out = []
        for c in parsed.get("followup_chips") or []:
            token = str(c).strip()
            if token in ALLOWED_CHIPS and token not in chips_out:
                chips_out.append(token)
        extra_warnings = parsed.get("warnings") or []
        if isinstance(extra_warnings, list):
            for w in extra_warnings:
                s = str(w).strip()
                if s and s not in warnings:
                    warnings.append(s[:80])
        if researched and not notes:
            extra = "검색 없이 흔한 집밥 지식으로 제안했어요."
            if extra not in warnings:
                warnings.append(extra)
        if source_hosts:
            host_line = "참고: " + ", ".join(source_hosts[:3])
            if host_line not in warnings:
                warnings.append(host_line[:80])
        awaiting = bool(patches)
        reply = _clip_reply(str(parsed.get("reply") or ""), True)
        if awaiting:
            reply = _with_confirm_ask(reply)
            chips_out = list(CONFIRM_CHIPS)
        return _turn_response(
            reply=reply,
            followup_chips=chips_out[:4],
            proposed_patches=patches,
            warnings=warnings[:4],
            engine=engine,
            awaiting_confirm=awaiting,
        )


_recipe_agent_service: Optional[RecipeAgentService] = None


def get_recipe_agent_service() -> RecipeAgentService:
    global _recipe_agent_service
    if _recipe_agent_service is None:
        _recipe_agent_service = RecipeAgentService()
    return _recipe_agent_service
