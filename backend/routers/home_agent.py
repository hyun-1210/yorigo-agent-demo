"""홈 검색 에이전트 API. Firebase ID Token 필수.

배포에서는 라우터를 등록하지 않는다. 등록돼도 503.
"""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from firebase_admin import auth as firebase_auth

from models import HomeAgentTurnRequest, HomeAgentTurnResponse
from rate_limiter import check_home_agent_rate_limit
from services.agent_flags import home_agent_enabled
from services.home_agent_service import get_home_agent_service
from services.mixpanel_service import get_mixpanel_service

logger = logging.getLogger(__name__)


def _verify_bearer_uid(authorization: Optional[str]) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    token = authorization[7:].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Empty bearer token")
    try:
        decoded = firebase_auth.verify_id_token(token)
        uid = decoded.get("uid")
        if not uid:
            raise HTTPException(status_code=401, detail="Invalid token payload")
        return uid
    except HTTPException:
        raise
    except Exception as e:
        logger.warning("Firebase ID token verification failed: %s", e)
        raise HTTPException(status_code=401, detail="Invalid or expired ID token")


def create_home_agent_router() -> APIRouter:
    router = APIRouter(prefix="/home_agent", tags=["home_agent"])

    @router.post("/turn", response_model=HomeAgentTurnResponse)
    async def home_agent_turn(
        body: HomeAgentTurnRequest,
        authorization: Optional[str] = Header(None),
    ) -> HomeAgentTurnResponse:
        if not home_agent_enabled():
            raise HTTPException(status_code=503, detail="Feature disabled")
        uid = _verify_bearer_uid(authorization)
        check_home_agent_rate_limit(uid)

        history = []
        for turn in body.history or []:
            role = (turn.role or "").strip()
            if role not in ("user", "assistant"):
                continue
            history.append({"role": role, "text": (turn.text or "").strip()})

        service = get_home_agent_service()
        try:
            result = service.run_turn(
                chip_id=body.chip_id,
                message=body.message,
                focus_ingredient=body.focus_ingredient,
                history=history,
            )
        except RuntimeError:
            raise HTTPException(status_code=503, detail="firestore_unavailable")
        except Exception:
            logger.exception("home_agent turn failed")
            raise HTTPException(status_code=502, detail="agent_unavailable")

        recipe_ids = [str(x).strip() for x in (result.get("recipe_ids") or []) if str(x).strip()]
        picks_out = []
        for raw in (result.get("picks") or [])[:8]:
            if not isinstance(raw, dict):
                continue
            rid = str(raw.get("recipe_id") or "").strip()
            if not rid:
                continue
            picks_out.append(
                {
                    "recipe_id": rid[:80],
                    "reason": str(raw.get("reason") or "").strip()[:200],
                    "name": str(raw.get("name") or "").strip()[:80],
                }
            )
        try:
            get_mixpanel_service().track(
                uid,
                "server_home_agent_turn",
                {
                    "chip_id": (body.chip_id or "")[:40],
                    "on_topic": bool(result.get("on_topic")),
                    "used_llm": bool(result.get("used_llm")),
                    "used_ranker": bool(result.get("used_ranker")),
                    "retrieve": str(result.get("retrieve") or "")[:40],
                    "result_count": len(recipe_ids),
                    "pick_count": len(picks_out),
                    "engine": str(result.get("engine") or "")[:40],
                    "message_len": len((body.message or "").strip()),
                },
            )
        except Exception:
            pass

        return HomeAgentTurnResponse(
            on_topic=bool(result.get("on_topic")),
            reply=str(result.get("reply") or "")[:400],
            used_llm=bool(result.get("used_llm")),
            used_ranker=bool(result.get("used_ranker")),
            retrieve=str(result.get("retrieve") or ""),
            recipe_ids=recipe_ids[:8],
            q=str(result.get("q") or "")[:40],
            spice_low=bool(result.get("spice_low")),
            spice_high=bool(result.get("spice_high")),
            section_key=str(result.get("section_key") or "")[:40],
            followup_chips=list(result.get("followup_chips") or [])[:4],
            warnings=[],
            engine="",
            picks=picks_out,
        )

    return router
