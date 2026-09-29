"""
Batch LLM research for ingredient shelf life + storage type (1–10 items per call).
Results are auto-saved to Firestore `ingredient_shelf_life`.
Available to any authenticated user.
"""

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Header, HTTPException
from firebase_admin import auth as firebase_auth
from firebase_admin import firestore as admin_firestore

from models import (
    ShelfLifeEntry,
    ShelfLifeResearchRequest,
    ShelfLifeResearchResponse,
)
from services.firebase_service import get_firebase_service
from services.llm_service import get_llm_service
from services.mixpanel_service import get_mixpanel_service


def create_shelf_life_research_router() -> APIRouter:
    router = APIRouter(prefix="", tags=["shelf-life-research"])

    def _verify_authenticated_user(authorization: Optional[str]) -> Dict[str, Any]:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
        token = authorization[7:].strip()
        if not token:
            raise HTTPException(status_code=401, detail="Empty bearer token")

        try:
            decoded = firebase_auth.verify_id_token(token)
        except Exception:
            raise HTTPException(status_code=401, detail="Invalid or expired ID token")

        uid = (decoded.get("uid") or "").strip()
        email = (decoded.get("email") or "").strip().lower()
        if not uid:
            raise HTTPException(status_code=401, detail="Invalid token: no uid")

        return {"uid": uid, "email": email}

    @router.post(
        "/admin/shelf-life/research-batch",
        response_model=ShelfLifeResearchResponse,
    )
    def research_shelf_life_batch(
        body: ShelfLifeResearchRequest,
        authorization: Optional[str] = Header(None),
    ):
        """
        Runs one Gemini call for 1–10 ingredient names, returns
        storageType + shelfLifeDays for each. Results are auto-saved to
        Firestore `ingredient_shelf_life/{ingredientName}`.
        """
        user = _verify_authenticated_user(authorization)

        llm = get_llm_service()
        llm.reset_last_usage_tokens()
        try:
            raw_results = llm.research_shelf_life_batch(body.ingredient_names)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"LLM error: {e!s}") from e
        finally:
            _inp, _out, _think = llm.last_usage_tokens
            if _inp or _out or _think:
                get_mixpanel_service().track(user.get("uid", "unknown"), "llm_shelf_life_research", {
                    "llm_input_tokens": _inp,
                    "llm_output_tokens": _out,
                    "llm_thinking_tokens": _think,
                    "llm_total_tokens": _inp + _out + _think,
                    "batch_size": len(body.ingredient_names or []),
                })

        entries: List[ShelfLifeEntry] = []
        for r in raw_results:
            try:
                entry = ShelfLifeEntry(
                    ingredientName=r.get("ingredientName", ""),
                    storageType=r.get("storageType", "refrigerated"),
                    shelfLifeDays=int(r.get("shelfLifeDays", 7)),
                    notes=r.get("notes"),
                )
                entries.append(entry)
            except Exception:
                continue

        fb = get_firebase_service()
        if fb.is_available() and fb.db is not None:
            batch = fb.db.batch()
            for entry in entries:
                doc_ref = fb.db.collection("ingredient_shelf_life").document(
                    entry.ingredientName
                )
                batch.set(
                    doc_ref,
                    {
                        "ingredientName": entry.ingredientName,
                        "storageType": entry.storageType,
                        "shelfLifeDays": entry.shelfLifeDays,
                        "notes": entry.notes,
                        "source": "llm_research",
                        "researchedBy": user.get("email", "unknown"),
                        "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                    },
                    merge=True,
                )
            try:
                batch.commit()
            except Exception as e:
                print(f"[ShelfLifeResearch] Firestore write failed: {e}", flush=True)

        return ShelfLifeResearchResponse(ok=True, results=entries)

    return router
