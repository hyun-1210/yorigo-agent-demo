"""장보기 에이전트 API. Firebase ID Token 필수. 기본은 라우터 미등록."""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from firebase_admin import auth as firebase_auth

from models import GroceryAgentTurnRequest, GroceryAgentTurnResponse
from services.agent_flags import grocery_agent_enabled
from services.grocery_agent_service import GroceryAgentError, get_grocery_agent_service

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
    except Exception as exc:
        logger.warning("Firebase ID token verification failed: %s", exc)
        raise HTTPException(status_code=401, detail="Invalid or expired ID token")


def create_grocery_agent_router() -> APIRouter:
    """플래그가 켜진 프로세스에서만 include 한다."""
    router = APIRouter(prefix="/grocery_agent", tags=["grocery_agent"])

    @router.post("/turn", response_model=GroceryAgentTurnResponse)
    async def grocery_agent_turn(
        body: GroceryAgentTurnRequest,
        authorization: Optional[str] = Header(None),
    ) -> GroceryAgentTurnResponse:
        if not grocery_agent_enabled():
            raise HTTPException(status_code=503, detail="Feature disabled")
        uid = _verify_bearer_uid(authorization)
        service = get_grocery_agent_service()
        try:
            result = service.run_turn(uid, body.message, body.chip_id)
        except GroceryAgentError as exc:
            code = str(exc)
            if code == "nvidia_key_missing":
                raise HTTPException(status_code=503, detail="nvidia_key_missing")
            if code == "firestore_unavailable":
                raise HTTPException(status_code=503, detail="firestore_unavailable")
            raise HTTPException(status_code=502, detail="agent_unavailable")
        except Exception:
            logger.exception("grocery_agent turn failed")
            raise HTTPException(status_code=502, detail="agent_unavailable")
        return GroceryAgentTurnResponse(**result)

    return router
