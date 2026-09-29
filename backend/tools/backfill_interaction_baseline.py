"""기존 Firestore 데이터로 행동 시그널 웨어하우스 베이스라인을 만드는 1회성 백필.

새 이벤트 수집(analytics_service.dart logCardEvent → signals/raw/*.jsonl →
signal_export_scheduler → signals/processed/dt=.../events.jsonl.gz)이 켜지기
전까지는 카드 단위 impression/click 로그가 전혀 없었다. 하지만 기존
Firestore에는 사용자 행동을 "간접적으로" 보여주는 데이터가 이미 있어
아래 4가지를 신규 이벤트 스키마(logCardEvent와 동일 필드)로 변환한다.

실제 Firestore 스키마(코드에서 직접 확인한 필드명 — user_service.dart,
background_parsing_service.dart, meal_plan_service.dart, cart_screen.dart 기준):

  1) users/{uid}.savedRecipes : string[]  (레시피 ID 배열, arrayUnion으로 관리)
     users/{uid}.savedAt      : { [recipeId]: Timestamp }  (저장 시각, dot-path merge)
     → 레시피 저장(북마크) = 강한 관심 신호. *서브컬렉션 아님*, 유저 문서 필드.
     (참고: users/{uid}/savedRecipes/{rid} 서브컬렉션도 존재하지만 이건 홈
     빠른 렌더링용 mini-doc 캐시이며 savedAt이 없어 백필에 쓰지 않는다.)

  2) users/{uid}/mealPlans/{dateKey} : { date, meals: {breakfast|lunch|dinner: [recipeId,...]}, createdAt }
     → 식단에 레시피 추가 = 조리 의도 신호.

  3) users/{uid}.cartItems : [{ recipeId, recipeName, servings, ingredients: [{item, qty, unit}], ... }]
     → "레시피 단위로 그룹핑된" 재료 리스트. 상품(productId/price/marketplace)은
     Firestore에 저장되지 않고 클라이언트가 화면에서 그때그때 매칭하는 값이라
     백필로는 복원 불가능 — ingredientName 단위 cart_add 신호만 생성한다.
     담긴 시각도 저장되지 않으므로 전부 백필 실행 시각을 쓴다(정직하게 표시).

  4) users/{uid}.fridgeData.recipes : [{ recipeId, ingredients: [{item, qty, productName?}], ... }]
     users/{uid}.fridgeData.lastSentAt : Timestamp
     → "구매 완료" 시점 스냅샷 = 구매 신호. Firestore에 최신 1건만 있고 이력이
     없으므로 사용자당 최대 1회분만 복원 가능(근본적 한계). productId/price도
     저장되지 않아 productName이 있으면만 채우고 나머지는 비워둔다.

이 스크립트는 위 4가지를 signals/processed/dt={date}/events_backfill.jsonl.gz
로 적재한다. 날짜별 파티션 디렉터리 안에 스케줄러가 만드는 events.jsonl.gz
와 파일명만 다르게 둬서(같은 dt= 파티션 아래 여러 파일이 있어도 BigQuery
외부 테이블은 prefix 전체를 합쳐 읽으므로) 서로 덮어쓰지 않는다.

데이터 품질 한계(정직하게 기록해 리포트에 남긴다):
  - cartItems: 개별 담긴 시각 없음 → 전부 백필 실행 시각.
  - fridgeData: 마지막 "구매 완료" 스냅샷 1건만 존재(히스토리 없음).
  - cart/fridge 이벤트에는 productId/price/marketplace가 없음(원본 미저장).
  - 레시피 카테고리 스냅샷(recipeCuisineType 등)은 recipes/{id} 조회로 채우며,
    유니크 recipeId 기준 1회만 조회하도록 캐싱한다(중복 저장 레시피의 N+1 방지).

사용 예:
  python backend/tools/backfill_interaction_baseline.py --dry-run
  python backend/tools/backfill_interaction_baseline.py --dry-run --limit-users 50
  python backend/tools/backfill_interaction_baseline.py            # 실제 업로드
  python backend/tools/backfill_interaction_baseline.py --user-id abc123
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

PROCESSED_PREFIX = "signals/processed"
BACKFILL_FILENAME = "events_backfill.jsonl.gz"


def _load_env() -> None:
    env_path = BACKEND_DIR / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k, v = k.strip(), v.strip()
        if k and k not in os.environ:
            os.environ[k] = v


def _init_firebase():
    import firebase_admin
    from firebase_admin import credentials

    if firebase_admin._apps:
        return firebase_admin.get_app()

    _load_env()
    service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    bucket_env = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    options = {"storageBucket": bucket_env} if bucket_env else {}

    canonical = BACKEND_DIR / "firebase-service-account.json"
    if service_account_json:
        path = Path(service_account_json)
        if not path.is_absolute():
            path = BACKEND_DIR / path
        if path.exists():
            with open(path, "r", encoding="utf-8") as f:
                cred_dict = json.load(f)
            return firebase_admin.initialize_app(
                credentials.Certificate(cred_dict), options or None
            )
        try:
            cred_dict = json.loads(service_account_json)
            return firebase_admin.initialize_app(
                credentials.Certificate(cred_dict), options or None
            )
        except json.JSONDecodeError:
            pass
    if canonical.exists():
        with open(canonical, "r", encoding="utf-8") as f:
            cred_dict = json.load(f)
        return firebase_admin.initialize_app(
            credentials.Certificate(cred_dict), options or None
        )
    raise RuntimeError(
        "Firebase 서비스 계정을 찾을 수 없습니다 (FIREBASE_SERVICE_ACCOUNT_JSON "
        "또는 backend/firebase-service-account.json 필요)."
    )


def _bucket_name(app) -> str:
    env_bucket = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    if env_bucket:
        return env_bucket
    return f"{app.project_id}.firebasestorage.app"


def _iso_date(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).date().isoformat()


def _iso_ts(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat()


def _as_str_list(v: Any) -> Optional[list[str]]:
    if isinstance(v, list):
        out = [str(x).strip() for x in v if str(x).strip()]
        return out or None
    if isinstance(v, str) and v.strip():
        return [v.strip()]
    return None


def _to_datetime(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value
    to_datetime = getattr(value, "ToDatetime", None) or getattr(
        value, "to_datetime", None
    )
    if callable(to_datetime):
        try:
            return to_datetime()
        except Exception:
            return None
    return None


def _snapshot_from_recipe_data(data: dict[str, Any]) -> dict[str, Any]:
    source = data.get("source") or {}
    categories = data.get("categories") or source.get("categories") or {}
    return {
        "recipeCuisineType": _as_str_list(
            categories.get("cuisine_type") or categories.get("country")
        ),
        "recipeTimeCategory": _as_str_list(
            categories.get("time_category") or categories.get("cook_time")
        ),
        "recipeMenuType": _as_str_list(categories.get("menu_type")),
        "recipeMainIngredient": _as_str_list(categories.get("main_ingredient")),
        "recipeMainIngredientSub": _as_str_list(
            categories.get("main_ingredient_sub")
        ),
        "recipeTags": _as_str_list(data.get("tags") or source.get("tags")),
        "recipeSourcePlatform": (source.get("platform") or None),
        "recipeServings": data.get("servings"),
    }


class RecipeSnapshotCache:
    """recipes/{id} → 카테고리/태그/플랫폼 스냅샷.

    비용·속도 최적화: N명의 유저를 순회하며 매번 개별 get()을 부르면(약
    200~300ms/건) 유저 수만큼 사실상 직렬 네트워크 왕복이 발생해 수천 명
    규모에서 몇 시간이 걸린다. 대신 전체 유저를 1차 스캔해 필요한 유니크
    recipeId 집합을 먼저 모으고, `prefetch()`로 Firestore
    `get_all()`(배치 RPC, 청크당 1회 왕복) + 스레드풀 병렬 청크 처리로
    한 번에 채운 뒤 이벤트 생성 단계에서는 순수 캐시 히트만 발생시킨다.
    """

    def __init__(self, db: Any, enabled: bool = True, chunk_size: int = 300):
        self._db = db
        self._enabled = enabled
        self._chunk_size = chunk_size
        self._cache: dict[str, dict[str, Any]] = {}
        self.lookups = 0
        self.misses = 0

    def prefetch(self, recipe_ids: set[str], max_workers: int = 8) -> None:
        if not self._enabled:
            return
        pending = [rid for rid in recipe_ids if rid and rid not in self._cache]
        if not pending:
            return
        chunks = [
            pending[i : i + self._chunk_size]
            for i in range(0, len(pending), self._chunk_size)
        ]

        def _fetch_chunk(chunk: list[str]) -> None:
            refs = [self._db.collection("recipes").document(rid) for rid in chunk]
            try:
                snapshots = self._db.get_all(refs)
            except Exception:
                # 배치 실패 시 청크 내부만 개별 폴백(전체 실패 방지).
                for rid in chunk:
                    try:
                        doc = self._db.collection("recipes").document(rid).get()
                        self._cache[rid] = (
                            _snapshot_from_recipe_data(doc.to_dict() or {})
                            if doc.exists
                            else {}
                        )
                    except Exception:
                        self._cache[rid] = {}
                        self.misses += 1
                return
            for doc in snapshots:
                self.lookups += 1
                if doc.exists:
                    self._cache[doc.id] = _snapshot_from_recipe_data(
                        doc.to_dict() or {}
                    )
                else:
                    self._cache[doc.id] = {}
                    self.misses += 1

        if len(chunks) == 1:
            _fetch_chunk(chunks[0])
            return
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            list(executor.map(_fetch_chunk, chunks))

    def get(self, recipe_id: str) -> dict[str, Any]:
        if not self._enabled or not recipe_id:
            return {}
        return self._cache.get(recipe_id, {})


def _base_event(
    *,
    event_id: str,
    event_type: str,
    user_id: str,
    screen: str,
    section_id: str,
    content_type: str,
    client_ts: str,
    card_id: Optional[str] = None,
    recipe_id: Optional[str] = None,
    position: Optional[int] = None,
    ingredient_name: Optional[str] = None,
    marketplace: Optional[str] = None,
    product_id: Optional[str] = None,
    price: Optional[int] = None,
    recipe_snapshot: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    event: dict[str, Any] = {
        "eventId": event_id,
        "eventType": event_type,
        "clientTs": client_ts,
        "userId": user_id,
        "sessionId": "backfill",
        "deviceId": "backfill",
        "appVersion": "backfill",
        "platform": "backfill",
        "screen": screen,
        "sectionId": section_id,
        "cardId": card_id,
        "contentType": content_type,
        "recipeId": recipe_id,
        "position": position,
        "marketplace": marketplace,
        "productId": product_id,
        "ingredientName": ingredient_name,
        "price": price,
    }
    if recipe_snapshot:
        event.update({k: v for k, v in recipe_snapshot.items() if v is not None})
    return {k: v for k, v in event.items() if v is not None}


def process_user(
    user_id: str,
    user_data: dict[str, Any],
    meal_plan_docs: list[tuple[str, dict[str, Any]]],
    recipe_cache: RecipeSnapshotCache,
    stats: dict[str, int],
    now: datetime,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []

    # 1) savedRecipes(배열) + savedAt(저장 시각) — 유저 문서 필드에서 직접 읽는다.
    #    (서브컬렉션이 아니므로 추가 Firestore 조회가 필요 없다.)
    #    실운영 데이터 확인 결과 savedAt은 두 가지 형태로 섞여 있다:
    #      - 중첩 맵: savedAt: { recipeId: Timestamp, ... }
    #      - 최상위 dot 필드 리터럴: "savedAt.<recipeId>": Timestamp
    #        (Flutter set(merge:true)에 문자열 키 'savedAt.$id'를 그대로 넘기면
    #         중첩 병합이 아니라 문자 그대로의 필드명으로 저장됨 — 앱 코드도
    #         home_screen.dart/recipe_service.dart에서 이 두 형태를 모두 읽는다.)
    saved_recipe_ids = user_data.get("savedRecipes")
    saved_at_lookup: dict[str, Any] = {}
    saved_at_map = user_data.get("savedAt")
    if isinstance(saved_at_map, dict):
        saved_at_lookup.update(saved_at_map)
    for key, value in user_data.items():
        if key.startswith("savedAt."):
            saved_at_lookup[key[len("savedAt.") :]] = value
    if isinstance(saved_recipe_ids, list):
        for recipe_id in saved_recipe_ids:
            recipe_id = str(recipe_id).strip()
            if not recipe_id:
                continue
            ts = _to_datetime(saved_at_lookup.get(recipe_id))
            if ts is None:
                ts = now
                stats["approx_timestamp_saved_recipes"] += 1
            snapshot = recipe_cache.get(recipe_id)
            events.append(
                _base_event(
                    event_id=f"backfill_save_{user_id}_{recipe_id}",
                    event_type="click",
                    user_id=user_id,
                    screen="recipebook",
                    section_id="saved_recipes",
                    content_type="recipe_save",
                    client_ts=_iso_ts(ts),
                    card_id=recipe_id,
                    recipe_id=recipe_id,
                    recipe_snapshot=snapshot,
                )
            )
            stats["events_saved_recipes"] += 1

    # 2) mealPlans 서브컬렉션 — 식단에 추가 = 조리 의도 신호. (사전 조회된 값 재사용)
    for plan_doc_id, data in meal_plan_docs:
        plan_ts = _to_datetime(data.get("date")) or _to_datetime(
            data.get("createdAt")
        )
        if plan_ts is None:
            plan_ts = now
            stats["approx_timestamp_meal_plans"] += 1
        meals = data.get("meals") or {}
        if not isinstance(meals, dict):
            continue
        for meal_time, recipe_ids in meals.items():
            if not isinstance(recipe_ids, list):
                continue
            for position, recipe_id in enumerate(recipe_ids):
                recipe_id = str(recipe_id).strip()
                if not recipe_id:
                    continue
                snapshot = recipe_cache.get(recipe_id)
                events.append(
                    _base_event(
                        event_id=(
                            f"backfill_mealplan_{user_id}_{plan_doc_id}_"
                            f"{meal_time}_{position}_{recipe_id}"
                        ),
                        event_type="click",
                        user_id=user_id,
                        screen="meal_plan",
                        section_id=f"meal_plan_{meal_time}",
                        content_type="meal_plan_add",
                        client_ts=_iso_ts(plan_ts),
                        card_id=f"{plan_doc_id}_{meal_time}_{recipe_id}",
                        recipe_id=recipe_id,
                        position=position,
                        recipe_snapshot=snapshot,
                    )
                )
                stats["events_meal_plans"] += 1

    # 3) cartItems — 레시피 단위로 그룹핑된 재료 리스트. 상품 매칭 정보는
    #    Firestore에 없으므로(클라이언트 런타임 캐시) ingredientName만 기록.
    cart_items = user_data.get("cartItems")
    if isinstance(cart_items, list):
        for cart_position, cart_item in enumerate(cart_items):
            if not isinstance(cart_item, dict):
                continue
            recipe_id = str(cart_item.get("recipeId") or "").strip() or None
            snapshot = recipe_cache.get(recipe_id) if recipe_id else {}
            ingredients = cart_item.get("ingredients")
            if not isinstance(ingredients, list) or not ingredients:
                continue
            for ing_position, ingredient in enumerate(ingredients):
                if not isinstance(ingredient, dict):
                    continue
                ingredient_name = str(
                    ingredient.get("item") or ingredient.get("name") or ""
                ).strip()
                if not ingredient_name:
                    continue
                events.append(
                    _base_event(
                        event_id=(
                            f"backfill_cart_{user_id}_{cart_position}_{ing_position}"
                        ),
                        event_type="click",
                        user_id=user_id,
                        screen="cart",
                        section_id="cart_snapshot",
                        content_type="cart_add",
                        client_ts=_iso_ts(now),
                        card_id=ingredient_name,
                        recipe_id=recipe_id,
                        position=ing_position,
                        ingredient_name=ingredient_name,
                        recipe_snapshot=snapshot,
                    )
                )
                stats["events_cart_items"] += 1
                stats["approx_timestamp_cart_items"] += 1

    # 4) fridgeData.recipes — "구매 완료" 최신 스냅샷 1건(=purchaseHistory 베이스라인).
    fridge_data = user_data.get("fridgeData")
    if isinstance(fridge_data, dict):
        purchase_ts = _to_datetime(fridge_data.get("lastSentAt"))
        if purchase_ts is None:
            purchase_ts = now
            stats["approx_timestamp_fridge_data"] += 1
        recipes = fridge_data.get("recipes")
        if isinstance(recipes, list):
            for recipe_position, recipe_entry in enumerate(recipes):
                if not isinstance(recipe_entry, dict):
                    continue
                recipe_id = str(recipe_entry.get("recipeId") or "").strip() or None
                snapshot = recipe_cache.get(recipe_id) if recipe_id else {}
                ingredients = recipe_entry.get("ingredients")
                if not isinstance(ingredients, list) or not ingredients:
                    continue
                for ing_position, ingredient in enumerate(ingredients):
                    if not isinstance(ingredient, dict):
                        continue
                    ingredient_name = str(
                        ingredient.get("item") or ingredient.get("name") or ""
                    ).strip()
                    if not ingredient_name:
                        continue
                    events.append(
                        _base_event(
                            event_id=(
                                f"backfill_purchase_{user_id}_"
                                f"{recipe_position}_{ing_position}"
                            ),
                            event_type="purchase",
                            user_id=user_id,
                            screen="cart",
                            section_id="purchase_history_baseline",
                            content_type=(
                                "product"
                                if ingredient.get("productName")
                                else "ingredient"
                            ),
                            client_ts=_iso_ts(purchase_ts),
                            card_id=ingredient_name,
                            recipe_id=recipe_id,
                            position=ing_position,
                            ingredient_name=ingredient_name,
                            recipe_snapshot=snapshot,
                        )
                    )
                    stats["events_purchase_history"] += 1

    return events


def _collect_referenced_recipe_ids(
    user_data: dict[str, Any], meal_plan_docs: list[tuple[str, dict[str, Any]]]
) -> set[str]:
    ids: set[str] = set()
    saved = user_data.get("savedRecipes")
    if isinstance(saved, list):
        ids.update(str(r).strip() for r in saved if str(r).strip())
    cart_items = user_data.get("cartItems")
    if isinstance(cart_items, list):
        for item in cart_items:
            if isinstance(item, dict) and item.get("recipeId"):
                ids.add(str(item["recipeId"]).strip())
    fridge_data = user_data.get("fridgeData")
    if isinstance(fridge_data, dict):
        recipes = fridge_data.get("recipes")
        if isinstance(recipes, list):
            for r in recipes:
                if isinstance(r, dict) and r.get("recipeId"):
                    ids.add(str(r["recipeId"]).strip())
    for _plan_id, data in meal_plan_docs:
        meals = data.get("meals")
        if isinstance(meals, dict):
            for recipe_ids in meals.values():
                if isinstance(recipe_ids, list):
                    ids.update(str(r).strip() for r in recipe_ids if str(r).strip())
    ids.discard("")
    return ids


def _fetch_meal_plans(db: Any, user_id: str) -> list[tuple[str, dict[str, Any]]]:
    try:
        docs = (
            db.collection("users").document(user_id).collection("mealPlans").stream()
        )
        return [(d.id, d.to_dict() or {}) for d in docs]
    except Exception as e:
        print(f"[Backfill] mealPlans 조회 실패 (uid={user_id}): {e}")
        return []


def run(
    *,
    dry_run: bool,
    limit_users: Optional[int],
    single_user_id: Optional[str],
    skip_recipe_enrichment: bool,
    max_workers: int = 16,
) -> dict[str, Any]:
    app = _init_firebase()
    from firebase_admin import firestore, storage

    db = firestore.client()
    now = datetime.now(timezone.utc)
    recipe_cache = RecipeSnapshotCache(db, enabled=not skip_recipe_enrichment)

    stats: dict[str, int] = defaultdict(int)
    events_by_date: dict[str, list[dict[str, Any]]] = defaultdict(list)

    if single_user_id:
        user_docs = [db.collection("users").document(single_user_id).get()]
    else:
        query = db.collection("users")
        if limit_users:
            query = query.limit(limit_users)
        user_docs = list(query.stream())

    users = [(doc.id, doc.to_dict() or {}) for doc in user_docs if doc.exists]
    stats["users_scanned"] = len(users)
    start = time.monotonic()

    # 1단계: mealPlans 서브컬렉션을 유저별 병렬 조회로 1회씩만 가져온다
    # (이후 이벤트 생성 단계에서 재조회하지 않도록 캐싱).
    meal_plans_by_user: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {
            executor.submit(_fetch_meal_plans, db, uid): uid for uid, _ in users
        }
        for future in futures:
            uid = futures[future]
            meal_plans_by_user[uid] = future.result()

    # 2단계: 전체 유저에서 참조되는 유니크 recipeId를 모아 배치로 한 번에 채운다
    # (유저별 순차 get() 대신 get_all() 배치 RPC + 스레드풀 병렬 청크).
    all_recipe_ids: set[str] = set()
    for uid, user_data in users:
        all_recipe_ids.update(
            _collect_referenced_recipe_ids(user_data, meal_plans_by_user[uid])
        )
    recipe_cache.prefetch(all_recipe_ids, max_workers=max_workers)

    # 3단계: 캐시가 이미 채워진 상태로 이벤트를 생성한다(순수 인메모리 처리).
    for uid, user_data in users:
        events = process_user(
            uid, user_data, meal_plans_by_user[uid], recipe_cache, stats, now
        )
        for event in events:
            try:
                event_dt = datetime.fromisoformat(event["clientTs"])
            except Exception:
                event_dt = now
            date_str = _iso_date(event_dt)
            events_by_date[date_str].append(event)

    elapsed = time.monotonic() - start
    total_events = sum(len(v) for v in events_by_date.values())
    stats["total_events"] = total_events
    stats["unique_dates"] = len(events_by_date)
    stats["unique_recipe_ids_referenced"] = len(all_recipe_ids)
    stats["recipe_cache_lookups"] = recipe_cache.lookups
    stats["recipe_cache_misses"] = recipe_cache.misses
    stats["elapsed_seconds"] = round(elapsed, 2)

    report = {
        "generated_at": _iso_ts(now),
        "dry_run": dry_run,
        "stats": dict(stats),
        "dates": sorted(events_by_date.keys()),
    }

    if dry_run:
        print("[Backfill] --dry-run 지정: Storage 업로드는 생략합니다.")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return report

    bucket_name = _bucket_name(app)
    bucket = storage.bucket(bucket_name, app=app)
    uploaded_dates = []
    for date_str, events in events_by_date.items():
        jsonl = "\n".join(json.dumps(e, ensure_ascii=False) for e in events) + "\n"
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
            gz.write(jsonl.encode("utf-8"))
        payload = buf.getvalue()
        blob = bucket.blob(f"{PROCESSED_PREFIX}/dt={date_str}/{BACKFILL_FILENAME}")
        blob.upload_from_string(payload, content_type="application/gzip")
        uploaded_dates.append(date_str)
        print(f"[Backfill] {date_str}: {len(events)}건 업로드 완료")

    report["uploaded_dates"] = uploaded_dates
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit-users", type=int, default=None)
    parser.add_argument("--user-id", type=str, default=None)
    parser.add_argument(
        "--skip-recipe-enrichment",
        action="store_true",
        help="recipes/{id} 조회(카테고리 스냅샷)를 생략해 Firestore 읽기 비용을 줄임",
    )
    parser.add_argument(
        "--report-file",
        type=str,
        default=None,
        help="품질 리포트를 JSON 파일로도 저장",
    )
    args = parser.parse_args()

    try:
        report = run(
            dry_run=args.dry_run,
            limit_users=args.limit_users,
            single_user_id=args.user_id,
            skip_recipe_enrichment=args.skip_recipe_enrichment,
        )
        if args.report_file:
            with open(args.report_file, "w", encoding="utf-8") as f:
                json.dump(report, f, ensure_ascii=False, indent=2)
            print(f"[Backfill] 리포트 저장: {args.report_file}")
    except Exception as e:
        print(f"[Backfill] 실패: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
