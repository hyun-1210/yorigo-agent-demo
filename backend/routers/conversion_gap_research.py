"""
Admin-only: batch LLM research for ingredient unit conversion gaps (1–3 items per call).
"""

from typing import Any, Dict, Optional

from fastapi import APIRouter, Header, HTTPException
from firebase_admin import auth as firebase_auth
from firebase_admin import firestore as admin_firestore

from models import ConversionGapResearchRequest, ConversionGapResearchResponse
from services.firebase_service import get_firebase_service
from services.llm_service import get_llm_service


def create_conversion_gap_research_router() -> APIRouter:
    router = APIRouter(prefix="", tags=["conversion-gap-research"])

    def _verify_admin_user(authorization: Optional[str]) -> Dict[str, Any]:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
        token = authorization[7:].strip()
        if not token:
            raise HTTPException(status_code=401, detail="Empty bearer token")

        try:
            decoded = firebase_auth.verify_id_token(token)
        except Exception:
            raise HTTPException(status_code=401, detail="Invalid or expired ID token")

        email = (decoded.get("email") or "").strip().lower()
        email_verified = bool(decoded.get("email_verified"))
        uid = (decoded.get("uid") or "").strip()
        if not uid or not email or not email_verified:
            raise HTTPException(status_code=403, detail="Admin access required")

        firebase = get_firebase_service()
        if not firebase.is_available() or firebase.db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        admin_doc = firebase.db.collection("admin_emails").document(email).get()
        data = admin_doc.to_dict() if admin_doc.exists else {}
        if not admin_doc.exists or not bool((data or {}).get("active", False)):
            raise HTTPException(status_code=403, detail="Admin access required")

        return {"uid": uid, "email": email}

    @router.post(
        "/admin/conversion-gaps/research-batch",
        response_model=ConversionGapResearchResponse,
    )
    def admin_research_conversion_gaps_batch(
        body: ConversionGapResearchRequest,
        authorization: Optional[str] = Header(None),
    ):
        """
        Runs one Gemini call with embedded Google search URLs (3 per ingredient).
        Request must contain **1 to 3** gaps — callers should batch on the client.
        """
        _verify_admin_user(authorization)

        gaps_payload = [g.model_dump(exclude_none=True) for g in body.gaps]
        llm = get_llm_service()
        try:
            model, urls = llm.research_conversion_gaps_batch(gaps_payload)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"LLM error: {e!s}") from e

        # Optional: persist for audit (non-blocking best-effort)
        try:
            fb = get_firebase_service()
            if fb.is_available() and fb.db is not None:
                fb.db.collection("conversion_gap_research_runs").add(
                    {
                        "gaps": gaps_payload,
                        "result": model,
                        "referenceSearchUrls": urls,
                        "createdAt": admin_firestore.SERVER_TIMESTAMP,
                    }
                )
        except Exception:
            pass

        return ConversionGapResearchResponse(ok=True, model=model, reference_search_urls=urls)

    return router
