"""ShoppingRun 오케스트레이터.

전문가는 grocery_planner가 구조화하고, NVIDIA는 그 결과를 한국어로만 말한다.
"""

from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Dict, List, Optional

import requests

from services.firebase_service import get_firebase_service
from services.grocery_planner import (
    PlannerResult,
    TurnIntent,
    intent_from_payload,
    merge_intents,
    parse_intent_local,
    plan_turn,
)

logger = logging.getLogger(__name__)


def narration_keeps_facts(spoken: str, template: str) -> bool:
    """템플릿에 없는 숫자를 말하거나, 나열된 요리·재료를 빼면 사실 밖 문장으로 버린다."""
    spoken_nums = set(re.findall(r"\d+", (spoken or "").replace(",", "")))
    allowed = set(re.findall(r"\d+", (template or "").replace(",", "")))
    if not spoken or not spoken_nums <= allowed:
        return False
    for chunk in re.split(r"[·/]", template or ""):
        food = re.search(r"([가-힣]{2,}(?:\s+[가-힣]{2,})*)\s*$", chunk.strip())
        if not food:
            continue
        name = food.group(1)
        if name in ("있어요", "없어요"):
            continue
        if name not in spoken:
            return False
    return True


def _extract_json(text: str) -> Optional[Dict[str, Any]]:
    """모델 출력에서 JSON 객체 하나를 꺼낸다."""
    raw = text or ""
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, re.S)
    blob = fenced.group(1) if fenced else ""
    if not blob:
        start = raw.find("{")
        end = raw.rfind("}")
        if start >= 0 and end > start:
            blob = raw[start : end + 1]
    if not blob:
        return None
    try:
        parsed = json.loads(blob)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def korean_narration(text: str) -> str:
    """모델이 추론 과정을 섞어 내면 한국어 문장만 남긴다."""
    kept: List[str] = []
    for match in re.finditer(r"[가-힣][^A-Za-z\n\"]{12,}?\.", text or ""):
        sentence = match.group(0).strip()
        if sentence not in kept:
            kept.append(sentence)
        if len(kept) == 2:
            break
    return " ".join(kept)

NVIDIA_URL = "https://integrate.api.nvidia.com/v1/chat/completions"
NVIDIA_MODEL = os.getenv(
    "NVIDIA_MODEL",
    "nvidia/nemotron-3-super-120b-a12b",
)
RUN_DOC = "current"


class GroceryAgentError(RuntimeError):
    """에이전트 턴을 만들 수 없을 때."""


class GroceryAgentService:
    """유저 메모리와 상품 캐시를 읽어 한 턴을 실행한다."""

    def run_turn(
        self,
        uid: str,
        message: Optional[str],
        chip_id: Optional[str],
    ) -> Dict[str, Any]:
        """Firebase 유저 문서를 기준으로 식단·gap·장바구니를 갱신한다."""
        db = self._db()
        profile, recipes, fridge, cart = self._load_world(db, uid)
        catalog = self._load_catalog(db, recipes, fridge)
        run_ref = (
            db.collection("users")
            .document(uid)
            .collection("shoppingRuns")
            .document(RUN_DOC)
        )
        previous = {}
        try:
            snap = run_ref.get()
            if snap.exists:
                previous = snap.to_dict() or {}
        except Exception as exc:
            logger.warning("shopping run read failed: %s", exc)
            raise GroceryAgentError("firestore_unavailable") from exc

        if previous.get("allowOverBudget") or chip_id == "allow_over_budget" or "예산 초과 허용" in (message or ""):
            profile = dict(profile)
            profile["allowOverBudget"] = True
        else:
            profile = dict(profile)
        profile["focus"] = str(previous.get("focus") or "")
        intent = None if chip_id else self._interpret(message or "", recipes, fridge, cart, previous)
        result = plan_turn(
            message or "",
            chip_id,
            profile,
            recipes,
            fridge,
            catalog,
            previous,
            cart,
            intent,
        )
        if not os.getenv("NVIDIA_API_KEY", "").strip():
            raise GroceryAgentError("nvidia_key_missing")
        reply, used_llm = self._narrate(result, message or "")
        if result.cart_items is not None:
            self._write_cart(db, uid, result.cart_items)
        patch = dict(result.run_patch)
        patch["allowOverBudget"] = bool(profile.get("allowOverBudget"))
        patch["reply"] = reply
        patch["totalPrice"] = result.total_price
        patch["budget"] = result.budget
        try:
            run_ref.set(patch, merge=True)
        except Exception as exc:
            logger.warning("shopping run write failed: %s", exc)
            raise GroceryAgentError("firestore_unavailable") from exc
        return self._payload(result, reply, used_llm)

    def _db(self):
        firebase = get_firebase_service()
        if not firebase.is_available() or firebase.db is None:
            raise GroceryAgentError("firestore_unavailable")
        return firebase.db

    def _load_world(self, db, uid: str):
        try:
            user_snap = db.collection("users").document(uid).get()
        except Exception as exc:
            logger.warning("user read failed: %s", exc)
            raise GroceryAgentError("firestore_unavailable") from exc
        data = user_snap.to_dict() if user_snap.exists else {}
        data = data or {}
        onboarding = data.get("onboarding") if isinstance(data.get("onboarding"), dict) else {}
        profile = dict(onboarding)
        profile["recentCartTotal"] = data.get("recentCartTotal") or profile.get("recentCartTotal")
        saved_ids = [str(x) for x in (data.get("savedRecipes") or []) if str(x).strip()]
        recipes = self._load_recipes(db, saved_ids)
        if len(recipes) < 3:
            recipes = self._fill_from_sections(db, recipes)
        fridge_blob = data.get("fridgeData") if isinstance(data.get("fridgeData"), dict) else {}
        fridge = fridge_blob.get("ingredients") or []
        if not isinstance(fridge, list):
            fridge = []
        cart = data.get("cartItems") or []
        if not isinstance(cart, list):
            cart = []
        return profile, recipes, fridge, cart

    def _load_recipes(self, db, ids: List[str]) -> List[Dict[str, Any]]:
        found: List[Dict[str, Any]] = []
        for rid in ids[:24]:
            try:
                snap = db.collection("recipes").document(rid).get()
            except Exception as exc:
                logger.warning("recipe read failed %s: %s", rid, exc)
                continue
            if not snap.exists:
                continue
            found.append(self._recipe_card(snap.id, snap.to_dict() or {}))
        return found

    def _fill_from_sections(self, db, recipes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        have = {r["id"] for r in recipes}
        for key in ("high_protein", "comfort_bowl"):
            try:
                snap = db.collection("home_section_index").document(key).get()
            except Exception:
                continue
            if not snap.exists:
                continue
            for rid in (snap.to_dict() or {}).get("recipeIds") or []:
                sid = str(rid).strip()
                if not sid or sid in have:
                    continue
                card_list = self._load_recipes(db, [sid])
                if card_list:
                    recipes.append(card_list[0])
                    have.add(sid)
                if len(recipes) >= 6:
                    return recipes
        return recipes

    def _recipe_card(self, rid: str, doc: Dict[str, Any]) -> Dict[str, Any]:
        inner = doc.get("recipe") if isinstance(doc.get("recipe"), dict) else {}
        name = str(inner.get("name") or doc.get("title") or "").strip()
        servings = inner.get("servings") or 2
        try:
            servings_i = int(servings)
        except (TypeError, ValueError):
            servings_i = 2
        ingredients = []
        for raw in inner.get("ingredients") or []:
            if not isinstance(raw, dict):
                continue
            item = str(raw.get("item") or "").strip()
            if not item:
                continue
            ingredients.append(
                {
                    "item": item,
                    "qty": raw.get("qty"),
                    "unit": str(raw.get("unit") or ""),
                }
            )
        return {
            "id": rid,
            "name": name,
            "servings": servings_i or 2,
            "ingredients": ingredients,
            "description": str(
                inner.get("description") or doc.get("description") or ""
            ).strip()[:180],
            "image": str(
                doc.get("thumbnailUrl")
                or doc.get("thumbnailUrlLarge")
                or inner.get("thumbnailUrl")
                or ""
            ).strip(),
        }

    def _load_catalog(self, db, recipes: List[Dict[str, Any]], fridge: List[Any]) -> Dict[str, List[Dict[str, Any]]]:
        names = set()
        for recipe in recipes:
            for ing in recipe.get("ingredients") or []:
                item = str(ing.get("item") or "").strip()
                if item:
                    names.add(item)
        catalog: Dict[str, List[Dict[str, Any]]] = {}
        for name in list(names)[:40]:
            try:
                snap = db.collection("coupang_products").document(name).get()
            except Exception:
                continue
            if not snap.exists:
                continue
            products = (snap.to_dict() or {}).get("products") or []
            if isinstance(products, list) and products:
                catalog[name] = products[:8]
        return catalog

    def _write_cart(self, db, uid: str, items: List[Dict[str, Any]]) -> None:
        import time

        stamped = []
        now = int(time.time() * 1000)
        for item in items:
            copied = dict(item)
            copied["addedAt"] = now
            stamped.append(copied)
        try:
            db.collection("users").document(uid).set(
                {"cartItems": stamped},
                merge=True,
            )
        except Exception as exc:
            logger.warning("cart write failed: %s", exc)
            raise GroceryAgentError("firestore_unavailable") from exc

    def _interpret(
        self,
        message: str,
        recipes: List[Dict[str, Any]],
        fridge: List[Any],
        cart: List[Any],
        previous: Dict[str, Any],
    ) -> Optional[TurnIntent]:
        """NVIDIA가 유저 말에 맞는 도구를 고른다. 실패하면 로컬 해석을 쓴다."""
        local = parse_intent_local(message, None)
        key = os.getenv("NVIDIA_API_KEY", "").strip()
        if not key or not message.strip():
            return None
        recipe_names = [str(r.get("name") or "") for r in recipes if r.get("name")]
        fridge_names = [
            str(item.get("name") or "")
            for item in fridge
            if isinstance(item, dict) and item.get("name")
        ]
        cart_names = [
            str(item.get("recipeName") or "")
            for item in cart
            if isinstance(item, dict) and item.get("recipeName")
        ]
        meal_names = [
            f"{m.get('day')} {m.get('recipe_name')}"
            for m in (previous.get("meals") or [])
            if isinstance(m, dict)
        ]
        prompt = (
            "유저 말을 보고 JSON 객체 하나만 답해. 설명은 쓰지 마.\n"
            f"유저: {message}\n"
            f"저장 레시피: {recipe_names}\n"
            f"냉장고: {fridge_names}\n"
            f"장바구니: {cart_names}\n"
            f"지금 식단: {meal_names}\n"
            f"단계: {previous.get('phase') or 'idle'}\n"
            f"직전 요리: {previous.get('focus') or ''}\n"
            "kind는 propose, revise, lookup, basket, commit, explain, chat, off_topic.\n"
            "레시피·냉장고·장바구니·예산·재료·상품을 묻면 lookup이고 target은 recipes, fridge, cart, budget, ingredients, products.\n"
            "재료를 알려 달라면 ingredients. 상품 추천이면 products. include는 요리 이름만.\n"
            "식단을 짜 달라면 propose. 빼거나 바꾸면 revise. 장을 보자면 basket. 담으라면 commit.\n"
            "없는 요리 이름은 include에 넣지 마. 아래 키만 채우고, 예시를 베끼지 마.\n"
            '{"kind":"","target":"","meal_count":0,"drop_days":"","include":"","exclude":"","less_spicy":false,"swap_day":""}'
        )
        try:
            response = requests.post(
                NVIDIA_URL,
                headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                json={
                    "model": NVIDIA_MODEL,
                    "messages": [
                        {"role": "system", "content": "너는 요리고 장보기 지휘자다. JSON만 출력한다."},
                        {"role": "user", "content": prompt},
                    ],
                    "max_tokens": 220,
                    "temperature": 0,
                },
                timeout=20,
            )
            if response.status_code != 200:
                logger.warning("nvidia intent status %s", response.status_code)
                return None
            content = (
                ((response.json().get("choices") or [{}])[0].get("message") or {}).get("content")
                or ""
            )
            parsed = _extract_json(content)
            chosen = intent_from_payload(parsed or {})
            if chosen is None:
                return None
            merged = merge_intents(local, chosen)
            return None if merged == local else merged
        except Exception as exc:
            logger.warning("nvidia intent failed: %s", exc)
            return None

    def _narrate(self, result: PlannerResult, message: str) -> tuple[str, bool]:
        """NVIDIA가 실패하면 템플릿 문장을 유지한다. OpenAI로는 넘기지 않는다."""
        if not result.on_topic or result.policy_decision in (
            "products_recommended",
            "lookup_ingredients",
        ):
            return result.reply, False
        key = os.getenv("NVIDIA_API_KEY", "").strip()
        prompt = (
            "유저가 한 말에 답하는 한국어 두 문장만 써. 아래 사실에 없는 숫자와 요리는 만들지 마.\n"
            f"유저: {message}\n"
            f"사실: {result.reply}"
        )
        try:
            response = requests.post(
                NVIDIA_URL,
                headers={
                    "Authorization": f"Bearer {key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": NVIDIA_MODEL,
                    "messages": [
                        {"role": "system", "content": "너는 요리고 장보기 지휘자다. 사실 밖을 말하지 않는다."},
                        {"role": "user", "content": prompt},
                    ],
                    "max_tokens": 220,
                    "temperature": 0.2,
                },
                timeout=20,
            )
            if response.status_code != 200:
                logger.warning("nvidia status %s", response.status_code)
                return result.reply, False
            data = response.json()
            text = (
                ((data.get("choices") or [{}])[0].get("message") or {}).get("content")
                or ""
            ).strip()
            spoken = korean_narration(text)
            if not narration_keeps_facts(spoken, result.reply):
                return result.reply, False
            return spoken[:800], True
        except Exception as exc:
            logger.warning("nvidia narrate failed: %s", exc)
            return result.reply, False

    def _payload(self, result: PlannerResult, reply: str, used_llm: bool) -> Dict[str, Any]:
        return {
            "on_topic": result.on_topic,
            "reply": reply,
            "phase": result.phase,
            "skills_loaded": result.skills_loaded,
            "policy_decision": result.policy_decision,
            "used_llm": used_llm,
            "engine": NVIDIA_MODEL if used_llm else "template",
            "solver": result.solver,
            "meals": result.meals,
            "gap": result.gap,
            "basket": result.basket,
            "total_price": result.total_price,
            "budget": result.budget,
            "chips": result.chips,
            "warnings": result.warnings,
            "run_id": RUN_DOC,
        }


_service: Optional[GroceryAgentService] = None


def get_grocery_agent_service() -> GroceryAgentService:
    """프로세스 안에서 서비스를 한 번만 만든다."""
    global _service
    if _service is None:
        _service = GroceryAgentService()
    return _service
