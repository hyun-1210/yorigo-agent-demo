"""레시피 상세 에이전트 API. Firebase ID Token 필수."""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from firebase_admin import auth as firebase_auth

from models import RecipeAgentPatch, RecipeAgentTurnRequest, RecipeAgentTurnResponse
from rate_limiter import check_recipe_agent_rate_limit
from services.agent_flags import recipe_agent_enabled
from services.mixpanel_service import get_mixpanel_service
from services.recipe_agent_service import get_recipe_agent_service

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


def create_recipe_agent_router() -> APIRouter:
    router = APIRouter(prefix="/recipe_agent", tags=["recipe_agent"])

    @router.post("/turn", response_model=RecipeAgentTurnResponse)
    async def recipe_agent_turn(
        body: RecipeAgentTurnRequest,
        authorization: Optional[str] = Header(None),
    ) -> RecipeAgentTurnResponse:
        if not recipe_agent_enabled():
            raise HTTPException(status_code=503, detail="Feature disabled")
        uid = _verify_bearer_uid(authorization)
        check_recipe_agent_rate_limit(uid)

        history = []
        for turn in body.history or []:
            role = (turn.role or "").strip()
            if role not in ("user", "assistant"):
                continue
            history.append({"role": role, "text": (turn.text or "").strip()})

        pending_patches = []
        for patch in body.pending_patches or []:
            pending_patches.append(patch.model_dump(exclude_none=True))

        service = get_recipe_agent_service()
        try:
            result = service.run_turn(
                recipe_id=body.recipe_id,
                chip_id=body.chip_id,
                message=body.message,
                focus_ingredient=body.focus_ingredient,
                overlay=body.overlay,
                client_snapshot=body.client_snapshot,
                history=history,
                pending_patches=pending_patches,
            )
        except KeyError:
            raise HTTPException(status_code=404, detail="recipe_not_found")
        except ValueError as e:
            code = str(e)
            if code == "client_snapshot_too_large":
                raise HTTPException(status_code=413, detail="client_snapshot_too_large")
            if code == "client_snapshot_required":
                raise HTTPException(status_code=400, detail="client_snapshot_required")
            raise HTTPException(status_code=400, detail="invalid_request")
        except RuntimeError:
            raise HTTPException(status_code=503, detail="firestore_unavailable")
        except Exception:
            logger.exception("recipe_agent turn failed")
            raise HTTPException(status_code=502, detail="agent_unavailable")

        patches = []
        for p in result.get("proposed_patches") or []:
            try:
                patches.append(RecipeAgentPatch.model_validate(p))
            except Exception:
                continue

        try:
            get_mixpanel_service().track(
                uid,
                "server_recipe_agent_turn",
                {
                    "chip_id": (body.chip_id or "")[:40],
                    "recipe_id": (body.recipe_id or "")[:100],
                    "on_topic": bool(result.get("on_topic")),
                    "patch_count": len(patches),
                    "engine": str(result.get("engine") or "")[:20],
                    "message_len": len((body.message or "").strip()),
                    "has_recipe_id": bool((body.recipe_id or "").strip()),
                },
            )
        except Exception:
            pass

        return RecipeAgentTurnResponse(
            on_topic=bool(result.get("on_topic")),
            reply=str(result.get("reply") or ""),
            followup_chips=list(result.get("followup_chips") or []),
            proposed_patches=patches,
            warnings=list(result.get("warnings") or []),
            engine=str(result.get("engine") or ""),
            awaiting_confirm=bool(result.get("awaiting_confirm")),
        )

    return router
