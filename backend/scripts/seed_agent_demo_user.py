"""데모 Firebase에 데모 유저와 없는 레시피만 추가한다.

운영 요리고 DB는 읽기만 한다. 이미 있는 문서는 덮어쓰지 않는다.
비밀번호는 이 파일에 넣지 않고 backend/.env.agentdemo 에만 쓴다.
"""

from __future__ import annotations

import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import firebase_admin
from firebase_admin import auth, credentials, firestore

SRC_SA = Path(r"C:\Users\82102\yorigo\backend\firebase-service-account.json")
DST_SA = Path(r"C:\Users\82102\codegate\backend\firebase-service-account.json")
ENV_OUT = Path(r"C:\Users\82102\yorigo\backend\.env.agentdemo")
EMAIL = "agentdemo@yorigo.app"
TITLE_NEEDLES = ("순두부", "닭가슴", "김치찌개")


def _init(name: str, path: Path):
    cred = credentials.Certificate(str(path))
    app = firebase_admin.initialize_app(cred, name=name)
    return firestore.client(app=app), app


def _title(data: dict[str, Any]) -> str:
    inner = data.get("recipe") if isinstance(data.get("recipe"), dict) else {}
    return str(inner.get("name") or data.get("title") or "")


def _match_needle(title: str) -> Optional[str]:
    for needle in TITLE_NEEDLES:
        if needle in title:
            return needle
    return None


def _find_in(db, limit: int = 400) -> dict[str, str]:
    found: dict[str, str] = {}
    for snap in db.collection("recipes").limit(limit).stream():
        needle = _match_needle(_title(snap.to_dict() or {}))
        if needle and needle not in found:
            found[needle] = snap.id
        if len(found) == len(TITLE_NEEDLES):
            break
    return found


def _copy_recipe(src, dst, rid: str) -> bool:
    snap = src.collection("recipes").document(rid).get()
    if not snap.exists:
        return False
    if dst.collection("recipes").document(rid).get().exists:
        return True
    data = dict(snap.to_dict() or {})
    data["agentDemoSeed"] = True
    data["agentDemoSeededAt"] = datetime.now(timezone.utc)
    dst.collection("recipes").document(rid).set(data)
    return True


def _ingredient_names(doc: dict[str, Any]) -> set[str]:
    inner = doc.get("recipe") if isinstance(doc.get("recipe"), dict) else {}
    names: set[str] = set()
    for raw in inner.get("ingredients") or []:
        if isinstance(raw, dict):
            item = str(raw.get("item") or "").strip()
            if item:
                names.add(item)
    return names


def _copy_products(src, dst, names: set[str]) -> int:
    copied = 0
    for name in sorted(names):
        ref = dst.collection("coupang_products").document(name)
        if ref.get().exists:
            continue
        snap = src.collection("coupang_products").document(name).get()
        if not snap.exists:
            continue
        data = dict(snap.to_dict() or {})
        data["agentDemoSeed"] = True
        ref.set(data)
        copied += 1
    return copied


def _ensure_user(app, dst) -> str:
    try:
        user = auth.get_user_by_email(EMAIL, app=app)
        uid = user.uid
        print(f"user exists {uid}")
        return uid
    except auth.UserNotFoundError:
        password = secrets.token_urlsafe(12)
        user = auth.create_user(email=EMAIL, password=password, display_name="데모", app=app)
        ENV_OUT.write_text(
            f"AGENT_DEMO_EMAIL={EMAIL}\nAGENT_DEMO_PASSWORD={password}\n",
            encoding="utf-8",
        )
        print(f"user created {user.uid}")
        return user.uid


def main() -> int:
    if not SRC_SA.exists() or not DST_SA.exists():
        print("FAIL: service account missing", file=sys.stderr)
        return 1
    src, _src_app = _init("src_yorigo", SRC_SA)
    dst, dst_app = _init("dst_codegate", DST_SA)

    found = _find_in(dst)
    print(f"already present: {found}")
    if len(found) < len(TITLE_NEEDLES):
        print("looking in source section indexes")
        for key in ("high_protein", "comfort_bowl", "trending_now", "lean_strong", "moment_dinner"):
            snap = src.collection("home_section_index").document(key).get()
            ids = (snap.to_dict() or {}).get("recipeIds") or [] if snap.exists else []
            for rid in ids[:120]:
                recipe = src.collection("recipes").document(str(rid)).get()
                if not recipe.exists:
                    continue
                needle = _match_needle(_title(recipe.to_dict() or {}))
                if needle and needle not in found:
                    if _copy_recipe(src, dst, recipe.id):
                        found[needle] = recipe.id
                        print(f"copied {needle} {recipe.id}")
            if len(found) == len(TITLE_NEEDLES):
                break

    if len(found) < len(TITLE_NEEDLES):
        print("scanning source recipes for remaining titles")
        missing = set(TITLE_NEEDLES) - set(found)
        for snap in src.collection("recipes").limit(2000).stream():
            needle = _match_needle(_title(snap.to_dict() or {}))
            if needle in missing:
                if _copy_recipe(src, dst, snap.id):
                    found[needle] = snap.id
                    missing.discard(needle)
                    print(f"scanned {needle} {snap.id}")
            if not missing:
                break

    if len(found) < len(TITLE_NEEDLES):
        print("WARN missing", [n.encode("unicode_escape").decode() for n in (set(TITLE_NEEDLES) - set(found))])

    names: set[str] = set()
    for rid in found.values():
        snap = dst.collection("recipes").document(rid).get()
        if snap.exists:
            names |= _ingredient_names(snap.to_dict() or {})
    copied_products = _copy_products(src, dst, names)
    print(f"products copied {copied_products}")

    uid = _ensure_user(dst_app, dst)
    saved = list(found.values())
    dst.collection("users").document(uid).set(
        {
            "email": EMAIL,
            "name": "데모",
            "preferredMarketplace": "coupang",
            "recentCartTotal": 70000,
            "savedRecipes": saved,
            "agentDemo": True,
            "onboarding": {
                "displayName": "데모",
                "householdSize": "2",
                "cookingFrequency": "few_times_week",
                "cookingSkill": "learning",
                "favoriteCuisines": ["korean", "soup", "high_protein"],
                "avoidedIngredients": ["crustacean"],
                "preferredMarketplace": "coupang",
                "preferredMarketplaces": ["coupang"],
                "shoppingPriorities": ["price", "freshness"],
                "goals": ["save_money"],
                "completed": True,
            },
            "fridgeData": {
                "ingredients": [
                    {"name": "두부", "totalQty": 1, "unit": "모"},
                    {"name": "김치", "totalQty": 1, "unit": "통"},
                    {"name": "계란", "totalQty": 6, "unit": "개"},
                    {"name": "간장", "totalQty": 1, "unit": "병"},
                ],
                "recipes": [],
            },
        },
        merge=True,
    )
    print(f"user doc written saved={saved}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
