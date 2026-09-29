"""
Firebase service for Firestore database operations

Handles Firebase Admin SDK initialization and caching operations.
"""

import os
import json
import re
import logging
import time
from typing import Optional, List, Dict, Any, Set, Tuple
from datetime import datetime, timedelta, timezone
import firebase_admin
from firebase_admin import credentials, firestore, auth
try:
    from google.cloud.firestore_v1 import FieldPath, FieldFilter
except ImportError:
    from google.cloud.firestore_v1.field_path import FieldPath
    from google.cloud.firestore_v1 import FieldFilter

# Configure logger for firebase service
logger = logging.getLogger(__name__)

# 재료명으로 캐시 조회 시 사용하는 컬렉션 (문서 ID = 재료명, prefix 범위 쿼리로 전체 스캔 방지)
INGREDIENT_CACHE_COLLECTION = "search_cache_by_ingredient"

_CART_HIT_MAP_CACHE: Dict[str, str] = {}
_CART_HIT_MAP_CACHE_AT: float = 0.0
_CART_HIT_MAP_CACHE_TTL_SECONDS = int(os.getenv("CART_HIT_MAP_CACHE_TTL_SECONDS", "600"))


def price_retry_block(
    entry: Optional[Dict[str, Any]],
    now: datetime,
    *,
    cooldown_hours: int = 24,
) -> Optional[str]:
    """단가 LLM을 다시 부를지 판정한다.

    None이면 호출한다. 'cooldown'은 프로바이더 장애 후 대기, 'given_up'은 다시 묻지 않는다.

    - 모델이 응답했는데 단가를 못 만들면 retryable=False → 즉시 포기
    - 호출 자체가 실패하면 retryable=True, failCount=1 → 24시간 뒤 1회만 더
    - 그 다음 실패(failCount>=2) 또는 예전 기록(retryable 없음)은 포기
    """
    if not entry:
        return None
    fail_count = int(entry.get("failCount") or 0)
    if fail_count <= 0:
        return None
    if entry.get("retryable") is True and fail_count == 1:
        last_attempt = _coerce_utc_datetime(entry.get("lastAttemptAt"))
        if last_attempt is None:
            return None
        elapsed_hours = (now - last_attempt).total_seconds() / 3600
        if elapsed_hours < cooldown_hours:
            return "cooldown"
        return None
    return "given_up"


def _coerce_utc_datetime(value: Any) -> Optional[datetime]:
    """Firestore에서 읽은 timestamp 값을 tz-aware UTC datetime으로 정규화.
    Firestore SERVER_TIMESTAMP는 읽어올 때 이미 tz-aware datetime 서브클래스지만,
    방어적으로 naive datetime/ISO 문자열도 처리한다."""
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None


def _sanitize_ingredient_doc_id(name: str) -> str:
    """Firestore 문서 ID로 쓸 수 있도록 재료명 정규화 (문자열 정렬·prefix 쿼리 호환)."""
    if not name or not isinstance(name, str):
        return ""
    s = name.strip()
    # 문서 ID에 사용 불가 문자 제거 (예: /)
    s = s.replace("/", "_")
    return s

# Basename of the expected credentials file (so we can skip it when scanning)
_EXPECTED_CREDENTIALS_BASENAME = "firebase-service-account.json"
_EXAMPLE_BASENAME = "firebase-service-account.example.json"


def _discover_and_create_credentials_file(backend_dir: str, expected_path: str) -> Optional[str]:
    """
    If expected_path does not exist (or exists but is the example placeholder), look for any
    JSON file in backend_dir that looks like a real Firebase service account. Copy the first
    one to expected_path. Returns expected_path if a file was found and copied, None otherwise.
    """
    expected_basename = os.path.basename(expected_path)
    if os.path.exists(expected_path):
        try:
            with open(expected_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not _is_placeholder_credentials(data):
                return expected_path
        except (json.JSONDecodeError, OSError):
            pass
    try:
        for name in os.listdir(backend_dir):
            if not name.endswith(".json"):
                continue
            if name == expected_basename or name == _EXAMPLE_BASENAME:
                continue
            candidate = os.path.join(backend_dir, name)
            if not os.path.isfile(candidate):
                continue
            try:
                with open(candidate, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except (json.JSONDecodeError, OSError, UnicodeDecodeError):
                continue
            # Service account files are always JSON objects; skip arrays/strings/etc.
            # (the backend folder also contains parser output, cookie dumps, ...)
            if not isinstance(data, dict):
                continue
            if data.get("type") != "service_account" or "private_key" not in data:
                continue
            if _is_placeholder_credentials(data):
                continue
            try:
                with open(candidate, "r", encoding="utf-8") as f:
                    content = f.read()
                with open(expected_path, "w", encoding="utf-8") as f:
                    f.write(content)
            except OSError as copy_err:
                print(f"[WARN] Failed to copy {name} -> {expected_basename}: {copy_err}")
                continue
            print(f"[Startup] Using Firebase key from {name} -> {expected_basename}")
            return expected_path
    except OSError:
        pass
    return None


def _is_placeholder_credentials(cred_dict: dict) -> bool:
    """True if this looks like the example file (not real credentials)."""
    return cred_dict.get("project_id") == "your-project-id" or "YOUR_PRIVATE_KEY_HERE" in (cred_dict.get("private_key") or "")


def _load_credentials_from_file(file_path: str) -> None:
    """Load Firebase Admin from a service account JSON file."""
    with open(file_path, "r", encoding="utf-8") as f:
        cred_dict = json.load(f)
    cred = credentials.Certificate(cred_dict)
    firebase_admin.initialize_app(cred)
    print(f"[Startup] Firebase Admin initialized from file: {file_path}")


class FirebaseService:
    """Service for Firebase Firestore operations"""
    
    def __init__(self):
        self.db: Optional[firestore.Client] = None
        self._initialized = False
    
    def initialize(self) -> bool:
        """
        Initialize Firebase Admin SDK for Firestore access.
        
        Returns:
            True if initialization successful, False otherwise
        """
        if self._initialized and self.db is not None:
            return True
        
        try:
            # Check if Firebase is already initialized
            if firebase_admin._apps:
                print("[Startup] Firebase Admin already initialized")
                self.db = firestore.client()
                self._initialized = True
                return True
            
            # Try to initialize with service account JSON from environment variable
            service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
            if service_account_json:
                # Check if it's a file path or JSON string
                file_path = service_account_json
                if not os.path.isabs(file_path):
                    # Relative path - normalize it (remove ./ prefix if present)
                    if file_path.startswith('./'):
                        file_path = file_path[2:]
                    # Get backend directory (parent of services directory)
                    backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    file_path = os.path.join(backend_dir, file_path)
                    # Normalize path (resolve .. and .)
                    file_path = os.path.normpath(file_path)
                
                if os.path.exists(file_path):
                    # Check if file is not empty
                    file_size = os.path.getsize(file_path)
                    if file_size == 0:
                        print(f"[WARN] Firebase service account file is empty: {file_path}")
                        raise ValueError(f"Firebase service account file is empty: {file_path}")
                    try:
                        with open(file_path, "r", encoding="utf-8") as f:
                            cred_dict = json.load(f)
                        if _is_placeholder_credentials(cred_dict):
                            backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                            discovered = _discover_and_create_credentials_file(backend_dir, file_path)
                            if discovered:
                                _load_credentials_from_file(discovered)
                            else:
                                print("[WARN] firebase-service-account.json is the example placeholder. Put a real key .json in the backend folder and run again.")
                                raise ValueError("Firebase credentials are placeholder only. Add a real service account JSON file to the backend folder.")
                        else:
                            _load_credentials_from_file(file_path)
                    except json.JSONDecodeError as json_error:
                        print(f"[ERROR] Firebase service account file contains invalid JSON: {file_path}")
                        print(f"[ERROR] JSON error: {json_error}")
                        raise
                    except Exception as cert_error:
                        print(f"[ERROR] Failed to load Firebase credentials from file: {file_path}")
                        print(f"[ERROR] File size: {file_size} bytes")
                        print(f"[ERROR] Error: {cert_error}")
                        raise cert_error
                    else:
                        self.db = firestore.client()
                        self._initialized = True
                        print("[Startup] Firestore client initialized")
                        return True
                else:
                    # File not found - if it looks like a filename, try to discover a key file in backend dir
                    if service_account_json.endswith('.json') and not service_account_json.strip().startswith('{'):
                        backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                        discovered = _discover_and_create_credentials_file(backend_dir, file_path)
                        if discovered:
                            try:
                                _load_credentials_from_file(discovered)
                                self.db = firestore.client()
                                self._initialized = True
                                print("[Startup] Firestore client initialized")
                                return True
                            except Exception as e:
                                print(f"[ERROR] Failed to load discovered credentials: {e}")
                                raise
                        else:
                            print(f"[ERROR] Firebase service account file not found: {file_path}")
                            print("[ERROR] Put your service account JSON in the backend folder (any name), or create:")
                            print(f"[ERROR]   {file_path}")
                            print("[ERROR] From Firebase Console: Project Settings → Service accounts → Generate new private key")
                            raise FileNotFoundError(
                                f"Firebase credentials file not found: {file_path}. "
                                "Put any Firebase service account .json file in the backend folder and run again."
                            )
                    # Otherwise treat as JSON string
                    try:
                        cred_dict = json.loads(service_account_json)
                        cred = credentials.Certificate(cred_dict)
                        firebase_admin.initialize_app(cred)
                        print("[Startup] Firebase Admin initialized from environment variable (JSON string)")
                    except json.JSONDecodeError as e:
                        print(f"[WARN] FIREBASE_SERVICE_ACCOUNT_JSON is not a valid JSON string and not a file path: {e}")
                        print(f"[WARN] Tried file path: {file_path}")
                        raise
            else:
                # No env set: look for firebase-service-account.json (or any service account .json in backend)
                backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                canonical = os.path.join(backend_dir, _EXPECTED_CREDENTIALS_BASENAME)
                if os.path.exists(canonical):
                    try:
                        _load_credentials_from_file(canonical)
                        self.db = firestore.client()
                        self._initialized = True
                        print("[Startup] Firestore client initialized")
                        return True
                    except Exception as e:
                        print(f"[WARN] Failed to load {_EXPECTED_CREDENTIALS_BASENAME}: {e}")
                else:
                    discovered = _discover_and_create_credentials_file(backend_dir, canonical)
                    if discovered:
                        try:
                            _load_credentials_from_file(discovered)
                            self.db = firestore.client()
                            self._initialized = True
                            print("[Startup] Firestore client initialized")
                            return True
                        except Exception as e:
                            print(f"[WARN] Failed to load discovered credentials: {e}")
                # Try to initialize with default credentials (for local development or GCP)
                try:
                    firebase_admin.initialize_app()
                    # Try to create Firestore client to verify credentials actually work
                    test_db = firestore.client()
                    # If we get here, credentials are valid
                    self.db = test_db
                    self._initialized = True
                    print("[Startup] Firebase Admin initialized with default credentials")
                    print("[Startup] Firestore client initialized")
                    return True
                except Exception as default_error:
                    # Default credentials don't work, but that's OK for development
                    error_msg = str(default_error)
                    if "default credentials were not found" in error_msg or "credentials" in error_msg.lower():
                        print(f"[INFO] Firebase credentials not found: {error_msg}")
                        print("[INFO] Running without Firebase cache (OK for development)")
                    else:
                        print(f"[WARN] Firebase initialization failed: {default_error}")
                        print("[WARN] Caching will be disabled. Continuing without cache...")
                    self.db = None
                    self._initialized = False
                    return False
            
            # If we get here, we successfully initialized with service account
            self.db = firestore.client()
            self._initialized = True
            print("[Startup] Firestore client initialized")
            return True
        except Exception as e:
            error_msg = str(e)
            # Check if it's a credentials issue (common in development)
            if "default credentials were not found" in error_msg or "credentials" in error_msg.lower():
                print(f"[INFO] Firebase credentials not found: {error_msg}")
                print("[INFO] Running without Firebase cache (OK for development)")
            else:
                print(f"[WARN] Firebase initialization failed: {e}")
                print("[WARN] Caching will be disabled. Continuing without cache...")
            self.db = None
            self._initialized = False
            return False
    
    def is_available(self) -> bool:
        """Check if Firebase is available"""
        return self.db is not None
    
    def get_cached_search_results(self, query: str, cache_collection: str = "search_query_cache", ttl_hours: int = 24) -> Optional[List[Dict[str, Any]]]:
        """
        Check Firestore cache for search query results.
        Returns cached results if valid (within TTL hours), None otherwise.
        
        Args:
            query: Search query string
            cache_collection: Firestore collection name for cache
            ttl_hours: Cache validity period in hours
            
        Returns:
            Cached results if valid, None otherwise
        """
        if self.db is None:
            return None
        
        try:
            # Use query string as document ID
            doc_ref = self.db.collection(cache_collection).document(query)
            doc = doc_ref.get()
            
            if not doc.exists:
                logger.debug(f"Cache miss for query: '{query}' (document not found)")
                return None
            
            data = doc.to_dict()
            if not data:
                logger.debug(f"Cache miss for query: '{query}' (empty document)")
                return None
            
            # Check if savedAt timestamp exists and is valid
            saved_at = data.get("savedAt")
            if not saved_at:
                logger.debug(f"Cache miss for query: '{query}' (no savedAt field)")
                return None
            
            # Convert Firestore Timestamp to datetime if needed
            if hasattr(saved_at, 'timestamp'):
                saved_at_dt = datetime.fromtimestamp(saved_at.timestamp())
            elif isinstance(saved_at, datetime):
                saved_at_dt = saved_at
            else:
                logger.debug(f"Cache miss for query: '{query}' (invalid savedAt format)")
                return None
            
            # Check if cache is still valid (within TTL hours)
            now = datetime.now()
            time_diff = now - saved_at_dt
            if time_diff > timedelta(hours=ttl_hours):
                logger.debug(f"Cache expired for query: '{query}' (age: {time_diff})")
                return None
            
            # Cache hit - return cached response data
            response_data = data.get("responseData", [])
            logger.debug(f"Cache hit for query: '{query}' (age: {time_diff})")
            return response_data
            
        except Exception as e:
            logger.warning(f"Error checking cache for query '{query}': {e}")
            return None
    
    def get_cached_results_by_ingredient(self, ingredient_name: str, cache_collection: str = "search_query_cache", ttl_hours: int = 24) -> List[Dict[str, Any]]:
        """
        Get all cached search results for an ingredient name.
        Uses a dedicated collection (search_cache_by_ingredient) where document ID = ingredient name,
        and runs a prefix range query so only matching docs are read (no full collection scan).
        (e.g. "돼지고기" matches docs "돼지고기", "돼지고기 앞다리살", etc.)
        
        Args:
            ingredient_name: Ingredient name to search for
            cache_collection: Unused; kept for API compatibility. Uses INGREDIENT_CACHE_COLLECTION.
            ttl_hours: Cache validity period in hours
            
        Returns:
            List of all products from matching cached queries
        """
        if self.db is None:
            return []
        
        prefix = _sanitize_ingredient_doc_id(ingredient_name)
        if not prefix:
            return []
        
        try:
            col_ref = self.db.collection(INGREDIENT_CACHE_COLLECTION)
            # Prefix range: document ID >= prefix and <= prefix + high Unicode sentinel
            end = prefix + "\uf8ff"
            query = (
                col_ref.where(filter=FieldFilter(FieldPath.document_id(), ">=", prefix))
                .where(filter=FieldFilter(FieldPath.document_id(), "<=", end))
            )
            docs = query.stream()
            
            all_products = []
            product_id_set = set()
            now = datetime.now()
            
            for doc in docs:
                data = doc.to_dict()
                if not data:
                    continue
                saved_at = data.get("savedAt")
                if not saved_at:
                    continue
                if hasattr(saved_at, "timestamp"):
                    saved_at_dt = datetime.fromtimestamp(saved_at.timestamp())
                elif isinstance(saved_at, datetime):
                    saved_at_dt = saved_at
                else:
                    continue
                if now - saved_at_dt > timedelta(hours=ttl_hours):
                    continue
                response_data = data.get("responseData", [])
                for product in response_data:
                    product_id = str(product.get("productId", product.get("id", "")))
                    if product_id and product_id not in product_id_set:
                        product_id_set.add(product_id)
                        all_products.append(product)
            
            logger.info(f"Found {len(all_products)} unique products for ingredient '{ingredient_name}' from cache ({INGREDIENT_CACHE_COLLECTION})")
            return all_products
            
        except Exception as e:
            logger.warning(f"Error searching cache for ingredient '{ingredient_name}': {e}")
            return []
    
    def save_search_results_to_cache(self, query: str, results: List[Dict[str, Any]], cache_collection: str = "search_query_cache", ingredient_name: Optional[str] = None):
        """
        Save search query results to Firestore cache.
        Writes to (1) search_query_cache by query for exact lookup, (2) search_cache_by_ingredient
        by ingredient name for get_cached_results_by_ingredient (prefix lookup, no full scan).
        
        Args:
            query: Search query string
            results: Search results to cache
            cache_collection: Firestore collection name for cache (query-keyed)
            ingredient_name: Optional ingredient name (extracted from query if not provided)
        """
        if self.db is None:
            return
        
        try:
            if ingredient_name is None:
                ingredient_name = self._extract_ingredient_name(query)
            
            cache_data = {
                "query": query,
                "ingredientName": ingredient_name,
                "responseData": results,
                "savedAt": firestore.SERVER_TIMESTAMP,
            }
            
            # 1) 기존: query 기준 캐시 (get_cached_search_results용)
            self.db.collection(cache_collection).document(query).set(cache_data, merge=False)
            print(f"[CACHE] Saved cache for query: '{query}' (ingredient: {ingredient_name}, {len(results)} results)")
            
            # 2) 재료명 기준 캐시 (get_cached_results_by_ingredient용, prefix 쿼리만 읽음)
            doc_id = _sanitize_ingredient_doc_id(ingredient_name or "")
            if doc_id:
                by_ingredient_ref = self.db.collection(INGREDIENT_CACHE_COLLECTION).document(doc_id)
                by_ingredient_ref.set(cache_data, merge=True)
                logger.debug(f"[CACHE] Saved by-ingredient cache doc id: '{doc_id}'")
            
        except Exception as e:
            print(f"[WARN] Error saving cache for query '{query}': {e}")
    
    # --- 스크래핑 대기/추가 재료 (Railway 요청 → 로컬 48h 주기 후 반영) ---
    CONFIG_COLLECTION = "config"
    PENDING_SCRAPING_DOC = "pending_scraping_ingredients"
    EXTRA_SCRAPING_DOC = "extra_scraping_ingredients"
    PENDING_SCRAPING_META_DOC = "pending_scraping_ingredients_meta"
    EXTRA_SCRAPING_META_DOC = "extra_scraping_ingredients_meta"
    # 레시피 디테일에서 가격 문서가 없을 때 클라이언트가 보고하는 큐 (스크래핑 pending과 분리)
    PENDING_UNIT_PRICE_DOC = "pending_unit_price_ingredients"
    # 사용자가 단가 오류로 보고한 재료 → 주기적으로 LLM으로 재추정 후 덮어쓰기
    PENDING_UNIT_PRICE_RECHECK_DOC = "pending_unit_price_recheck_ingredients"
    # 재료 단가 3개 큐(pending_unit_price / recheck / scraping) 공용 LLM 재시도 상태.
    # {"state": {ingredientName: {"failCount": int, "lastAttemptAt": timestamp, "retryable": bool}}}
    # 모델이 단가를 못 만들면 retryable=False로 즉시 포기.
    # 프로바이더 장애만 retryable=True이며, 24시간 뒤 1회(failCount 2에서 포기).
    PRICE_RETRY_STATE_DOC = "ingredient_price_llm_retry_state"
    PRICE_RETRY_MAX_FAILURES = 2
    # High-priority scraping queue: fed by cart misses + health checks, consumed by local scraper
    PRIORITY_SCRAPING_DOC = "priority_scraping_ingredients"
    PRIORITY_SCRAPING_META_DOC = "priority_scraping_ingredients_meta"
    # Unified scraping ingredients list (single source of truth)
    SCRAPING_INGREDIENTS_DOC = "scraping_ingredients"
    # Ingredients confirmed to have products — skip in future health checks
    PRODUCT_COVERAGE_VERIFIED_DOC = "product_coverage_verified"
    # 재료별 최근 장바구니 검색 시각(cart-hit) — 재료 1개당 문서 1개.
    # scraping_ingredients 문서의 items 배열에 통째로 read-modify-write 하던
    # 방식(경쟁 조건 + 대형 배열 rewrite 비용)을 없애기 위해 별도 컬렉션으로 분리.
    # 주의: scrapingyorigo(별도 레포)도 동일한 컬렉션명/스키마를 읽으므로,
    # 이름을 바꾸려면 두 레포를 함께 수정해야 함.
    CART_HIT_COLLECTION = "scraping_cart_hits"
    MAX_UNIT_PRICE_QUEUE_NAME_LEN = 80
    SCRAPING_CATEGORY_WHITELIST = {
        "protein",
        "vegetables_fruits",
        "room_temperature",
        "dairy_eggs_refrigerated",
        "seasonings",
    }

    @staticmethod
    def _meta_source_priority(source: str) -> int:
        """메타 source 우선순위(값이 클수록 신뢰도 높음)."""
        s = (source or "").strip().lower()
        if s == "manual":
            return 30
        if s == "parser":
            return 20
        if s == "unknown":
            return 0
        return 10

    def normalize_scraping_category(self, category: Optional[str]) -> str:
        """스크래핑 메타로 저장할 카테고리 정규화."""
        c = str(category or "").strip()
        if not c:
            return "unknown"
        if c in self.SCRAPING_CATEGORY_WHITELIST:
            return c
        return "unknown"

    def _read_scraping_meta_items(self, doc_ref) -> Dict[str, Dict[str, Any]]:
        """meta 문서의 items 배열을 name 기반 dict로 변환."""
        doc = doc_ref.get()
        if not doc.exists:
            return {}
        data = doc.to_dict() or {}
        raw_items = data.get("items") or []
        if not isinstance(raw_items, list):
            return {}
        by_name: Dict[str, Dict[str, Any]] = {}
        for raw in raw_items:
            if not isinstance(raw, dict):
                continue
            name = str(raw.get("name") or "").strip()
            if not name:
                continue
            by_name[name] = {
                "name": name,
                "category": self.normalize_scraping_category(raw.get("category")),
                "source": str(raw.get("source") or "unknown").strip() or "unknown",
                "updatedAt": raw.get("updatedAt"),
            }
        return by_name

    def _upsert_scraping_meta_items(
        self,
        meta_doc_name: str,
        entries: List[Dict[str, str]],
    ) -> bool:
        """meta 문서에 name 기준 업서트."""
        if self.db is None or not entries:
            return False
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(meta_doc_name)
            existing = self._read_scraping_meta_items(doc_ref)
            changed = False
            now_dt = datetime.utcnow()
            for raw in entries:
                if not isinstance(raw, dict):
                    continue
                name = str(raw.get("name") or "").strip()
                if not name:
                    continue
                incoming_source = str(raw.get("source") or "unknown").strip() or "unknown"
                incoming_category = self.normalize_scraping_category(raw.get("category"))
                incoming_priority = self._meta_source_priority(incoming_source)
                current = existing.get(name)
                if current is None:
                    existing[name] = {
                        "name": name,
                        "category": incoming_category,
                        "source": incoming_source,
                        "updatedAt": now_dt,
                    }
                    changed = True
                    continue
                current_source = str(current.get("source") or "unknown").strip() or "unknown"
                current_category = self.normalize_scraping_category(current.get("category"))
                current_priority = self._meta_source_priority(current_source)
                should_replace = False
                if incoming_priority > current_priority:
                    should_replace = True
                elif incoming_priority == current_priority:
                    if current_category == "unknown" and incoming_category != "unknown":
                        should_replace = True
                if should_replace:
                    existing[name] = {
                        "name": name,
                        "category": incoming_category,
                        "source": incoming_source,
                        "updatedAt": now_dt,
                    }
                    changed = True
            if not changed:
                return True
            items = sorted(existing.values(), key=lambda x: str(x.get("name") or ""))
            doc_ref.set({"items": items, "lastUpdated": firestore.SERVER_TIMESTAMP}, merge=True)
            return True
        except Exception as e:
            logger.warning(f"Error upserting scraping meta items '{meta_doc_name}': {e}")
            return False

    def get_pending_scraping_ingredients_meta(self) -> List[Dict[str, Any]]:
        """pending 스크래핑 메타 목록."""
        if self.db is None:
            return []
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PENDING_SCRAPING_META_DOC)
            doc = doc_ref.get()
            if not doc.exists:
                return []
            data = doc.to_dict() or {}
            items = data.get("items") or []
            return items if isinstance(items, list) else []
        except Exception as e:
            logger.warning(f"Error reading pending scraping ingredients meta: {e}")
            return []

    def get_extra_scraping_ingredients_meta(self) -> List[Dict[str, Any]]:
        """extra 스크래핑 메타 목록."""
        if self.db is None:
            return []
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.EXTRA_SCRAPING_META_DOC)
            doc = doc_ref.get()
            if not doc.exists:
                return []
            data = doc.to_dict() or {}
            items = data.get("items") or []
            return items if isinstance(items, list) else []
        except Exception as e:
            logger.warning(f"Error reading extra scraping ingredients meta: {e}")
            return []

    def upsert_pending_scraping_ingredients_meta(self, entries: List[Dict[str, str]]) -> bool:
        """pending 스크래핑 메타 업서트."""
        return self._upsert_scraping_meta_items(self.PENDING_SCRAPING_META_DOC, entries)

    def upsert_extra_scraping_ingredients_meta(self, entries: List[Dict[str, str]]) -> bool:
        """extra 스크래핑 메타 업서트."""
        return self._upsert_scraping_meta_items(self.EXTRA_SCRAPING_META_DOC, entries)

    def get_pending_scraping_ingredients(self) -> List[str]:
        """스크래핑 목록에 아직 반영되지 않은 요청 재료 목록 (Railway에서 추가된 것)."""
        if self.db is None:
            return []
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PENDING_SCRAPING_DOC)
            doc = doc_ref.get()
            if not doc.exists:
                return []
            data = doc.to_dict() or {}
            return list(data.get("ingredients") or [])
        except Exception as e:
            logger.warning(f"Error reading pending scraping ingredients: {e}")
            return []

    def get_extra_scraping_ingredients(self) -> List[str]:
        """기본 목록에 더해 스크래핑할 추가 재료 목록 (기본 + pending 머지 결과)."""
        if self.db is None:
            return []
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.EXTRA_SCRAPING_DOC)
            doc = doc_ref.get()
            if not doc.exists:
                return []
            data = doc.to_dict() or {}
            return list(data.get("ingredients") or [])
        except Exception as e:
            logger.warning(f"Error reading extra scraping ingredients: {e}")
            return []

    def add_pending_ingredient(
        self,
        name: str,
        recipe_category: Optional[str] = None,
        source: str = "unknown",
    ) -> bool:
        """추천 요청으로 들어온 재료를 pending 목록에 추가 (중복·공백 제거). Railway에서 호출."""
        if self.db is None:
            return False
        s = (name or "").strip()
        if not s:
            return False
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PENDING_SCRAPING_DOC)
            doc_ref.set({"ingredients": firestore.ArrayUnion([s])}, merge=True)
            self._upsert_scraping_meta_items(
                self.PENDING_SCRAPING_META_DOC,
                [{
                    "name": s,
                    "category": self.normalize_scraping_category(recipe_category),
                    "source": (source or "unknown"),
                }],
            )
            logger.info(f"Added pending scraping ingredient: '{s}'")
            return True
        except Exception as e:
            logger.warning(f"Error adding pending ingredient '{name}': {e}")
            return False

    def add_pending_ingredients_batch(
        self,
        items: List[Dict[str, str]],
    ) -> int:
        """Add multiple ingredients to pending scraping queue in a single
        Firestore ArrayUnion write + single meta upsert.
        Each item: {"name": str, "category": str, "source": str}.
        Returns number of names successfully queued."""
        if self.db is None or not items:
            return 0
        names: List[str] = []
        meta_entries: List[Dict[str, str]] = []
        for raw in items:
            n = str(raw.get("name") or "").strip()
            if not n:
                continue
            names.append(n)
            meta_entries.append({
                "name": n,
                "category": self.normalize_scraping_category(raw.get("category")),
                "source": str(raw.get("source") or "unknown").strip() or "unknown",
            })
        if not names:
            return 0
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PENDING_SCRAPING_DOC)
            doc_ref.set({"ingredients": firestore.ArrayUnion(names)}, merge=True)
            self._upsert_scraping_meta_items(self.PENDING_SCRAPING_META_DOC, meta_entries)
            logger.info(f"Batch-added {len(names)} pending scraping ingredient(s)")
            return len(names)
        except Exception as e:
            logger.warning(f"Error batch-adding pending ingredients: {e}")
            return 0

    def merge_pending_into_extra(self) -> bool:
        """pending을 extra에 머지하고 pending 비우기. 메타 문서도 함께 승격."""
        if self.db is None:
            return False
        try:
            config_ref = self.db.collection(self.CONFIG_COLLECTION)
            pending_ref = config_ref.document(self.PENDING_SCRAPING_DOC)
            extra_ref = config_ref.document(self.EXTRA_SCRAPING_DOC)
            pending_meta_ref = config_ref.document(self.PENDING_SCRAPING_META_DOC)
            extra_meta_ref = config_ref.document(self.EXTRA_SCRAPING_META_DOC)

            @firestore.transactional
            def _merge(transaction) -> Tuple[int, int]:
                pending_doc = transaction.get(pending_ref)
                extra_doc = transaction.get(extra_ref)
                pending = list((pending_doc.to_dict() or {}).get("ingredients") or []) if pending_doc.exists else []
                extra = list((extra_doc.to_dict() or {}).get("ingredients") or []) if extra_doc.exists else []
                merged = list(set(extra) | set(pending))
                transaction.set(extra_ref, {"ingredients": merged})
                transaction.set(pending_ref, {"ingredients": []})
                return len(pending), len(merged)

            transaction = self.db.transaction()
            added, total = _merge(transaction)
            pending_meta = self._read_scraping_meta_items(pending_meta_ref)
            if pending_meta:
                existing_extra_meta = self._read_scraping_meta_items(extra_meta_ref)
                merged_meta: List[Dict[str, str]] = []
                for name, raw in pending_meta.items():
                    pending_source = str(raw.get("source") or "unknown").strip() or "unknown"
                    pending_category = self.normalize_scraping_category(raw.get("category"))
                    existing = existing_extra_meta.get(name)
                    if existing is None:
                        merged_meta.append({
                            "name": name,
                            "category": pending_category,
                            "source": pending_source,
                        })
                        continue
                    existing_source = str(existing.get("source") or "unknown").strip() or "unknown"
                    existing_category = self.normalize_scraping_category(existing.get("category"))
                    if self._meta_source_priority(pending_source) > self._meta_source_priority(existing_source):
                        merged_meta.append({
                            "name": name,
                            "category": pending_category,
                            "source": pending_source,
                        })
                    elif (
                        self._meta_source_priority(pending_source) == self._meta_source_priority(existing_source)
                        and existing_category == "unknown"
                        and pending_category != "unknown"
                    ):
                        merged_meta.append({
                            "name": name,
                            "category": pending_category,
                            "source": pending_source,
                        })
                if merged_meta:
                    self._upsert_scraping_meta_items(self.EXTRA_SCRAPING_META_DOC, merged_meta)
                pending_meta_ref.set({"items": [], "lastUpdated": firestore.SERVER_TIMESTAMP}, merge=True)
            logger.info(f"Merged pending into extra: {added} new ingredients, extra total={total}")
            return True
        except Exception as e:
            logger.warning(f"Error merging pending into extra: {e}")
            return False

    # --- Priority scraping queue (cart misses + health checks) ---

    def add_priority_scraping_ingredient(
        self, name: str, source: str = "unknown",
    ) -> bool:
        """Add a single ingredient to the priority scraping queue."""
        if self.db is None:
            return False
        s = (name or "").strip()
        if not s:
            return False
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PRIORITY_SCRAPING_DOC)
            doc_ref.set({"ingredients": firestore.ArrayUnion([s])}, merge=True)
            self._upsert_scraping_meta_items(
                self.PRIORITY_SCRAPING_META_DOC,
                [{"name": s, "category": "unknown", "source": source or "unknown"}],
            )
            logger.info(f"Added priority scraping ingredient: '{s}' (source={source})")
            return True
        except Exception as e:
            logger.warning(f"Error adding priority ingredient '{name}': {e}")
            return False

    def add_priority_scraping_ingredients_batch(
        self, names: List[str], source: str = "unknown",
    ) -> int:
        """Add multiple ingredients to priority scraping queue. Returns count added."""
        if self.db is None or not names:
            return 0
        clean: List[str] = []
        seen: set = set()
        for raw in names:
            s = (raw or "").strip()
            if s and s not in seen:
                clean.append(s)
                seen.add(s)
        if not clean:
            return 0
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PRIORITY_SCRAPING_DOC)
            doc_ref.set({"ingredients": firestore.ArrayUnion(clean)}, merge=True)
            meta = [{"name": n, "category": "unknown", "source": source or "unknown"} for n in clean]
            self._upsert_scraping_meta_items(self.PRIORITY_SCRAPING_META_DOC, meta)
            logger.info(f"Batch-added {len(clean)} priority scraping ingredient(s) (source={source})")
            return len(clean)
        except Exception as e:
            logger.warning(f"Error batch-adding priority ingredients: {e}")
            return 0

    def get_priority_scraping_ingredients(self) -> List[str]:
        """Read the priority scraping queue."""
        if self.db is None:
            return []
        try:
            doc = (
                self.db.collection(self.CONFIG_COLLECTION)
                .document(self.PRIORITY_SCRAPING_DOC)
                .get()
            )
            if not doc.exists:
                return []
            return list((doc.to_dict() or {}).get("ingredients") or [])
        except Exception as e:
            logger.warning(f"Error reading priority scraping ingredients: {e}")
            return []

    def remove_priority_scraping_ingredients(self, names: List[str]) -> bool:
        """Remove ingredients from the priority queue after scraping."""
        if self.db is None or not names:
            return True
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PRIORITY_SCRAPING_DOC)
            doc_ref.set({"ingredients": firestore.ArrayRemove(names)}, merge=True)
            return True
        except Exception as e:
            logger.warning(f"Error removing from priority scraping queue: {e}")
            return False

    # --- Unified scraping ingredients list (single source of truth) ---

    def get_scraping_ingredients(self) -> List[Dict[str, Any]]:
        """Return all items from the unified scraping ingredients list.
        Each item: {name: str, freq: int, source: str}."""
        if self.db is None:
            return []
        try:
            doc = self.db.collection(self.CONFIG_COLLECTION).document(
                self.SCRAPING_INGREDIENTS_DOC
            ).get()
            if not doc.exists:
                return []
            items = (doc.to_dict() or {}).get("items") or []
            return items if isinstance(items, list) else []
        except Exception as e:
            logger.warning(f"Error reading scraping ingredients: {e}")
            return []

    def get_scraping_ingredient_names(self) -> Set[str]:
        """Return just the set of ingredient names from the unified list."""
        items = self.get_scraping_ingredients()
        return {str(i.get("name") or "").strip() for i in items if isinstance(i, dict) and i.get("name")}

    def add_scraping_ingredient(self, name: str, freq: int = 1, source: str = "unknown") -> bool:
        """Add a single ingredient to the unified scraping list.
        Uses space-collapsed key for dedup. Rejects blocked names."""
        if self.db is None:
            return False
        s = (name or "").strip()
        if not s or self._is_blocked_ingredient_name(s):
            return False
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.SCRAPING_INGREDIENTS_DOC
            )
            doc = doc_ref.get()
            if doc.exists:
                existing = (doc.to_dict() or {}).get("items") or []
                existing_keys = {
                    self._normalize_ingredient_key(str(i.get("name") or ""))
                    for i in existing if isinstance(i, dict)
                }
                if self._normalize_ingredient_key(s) in existing_keys:
                    return True
                existing.append({"name": s, "freq": freq, "source": source})
                doc_ref.update({"items": existing})
            else:
                doc_ref.set({"items": [{"name": s, "freq": freq, "source": source}]})
            return True
        except Exception as e:
            logger.warning(f"Error adding scraping ingredient '{s}': {e}")
            return False

    # 재료명으로 부적절한 패턴 (레시피 섹션 헤더, 쓰레기)
    _INGREDIENT_NAME_BLOCKLIST_PATTERNS = (
        "핵심재료", "기본재료", "선택재료", "추가재료", "마무리재료",
        "부재료", "토핑재료", "양념재료", "밑간재료", "소스재료",
    )
    _INGREDIENT_NAME_BLOCKLIST_EXACT: Set[str] = {"칼", "숯", "릭", "랩"}

    @staticmethod
    def _normalize_ingredient_key(name: str) -> str:
        """공백 제거 + 소문자 → 중복 검사용 키."""
        return re.sub(r"\s+", "", (name or "").strip()).lower()

    @classmethod
    def _is_blocked_ingredient_name(cls, name: str) -> bool:
        """재료명 블록리스트 체크."""
        if name in cls._INGREDIENT_NAME_BLOCKLIST_EXACT:
            return True
        return any(p in name for p in cls._INGREDIENT_NAME_BLOCKLIST_PATTERNS)

    def add_scraping_ingredients_batch(self, items: List[Dict[str, Any]]) -> int:
        """Batch-add ingredients to the unified list. Skips duplicates and
        blocked names. Uses space-collapsed key for dedup so '무염버터' and
        '무염 버터' are treated as the same entry.
        Each item: {name: str, freq?: int, source?: str}.
        Returns count of newly added items."""
        if self.db is None or not items:
            return 0
        new_items = []
        for raw in items:
            n = str(raw.get("name") or "").strip()
            if not n or self._is_blocked_ingredient_name(n):
                continue
            new_items.append({
                "name": n,
                "freq": int(raw.get("freq", 1)),
                "source": str(raw.get("source", "unknown")),
            })
        if not new_items:
            return 0
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.SCRAPING_INGREDIENTS_DOC
            )
            doc = doc_ref.get()
            existing = (doc.to_dict() or {}).get("items") or [] if doc.exists else []
            existing_keys = {
                self._normalize_ingredient_key(str(i.get("name") or ""))
                for i in existing if isinstance(i, dict)
            }
            added = 0
            for item in new_items:
                key = self._normalize_ingredient_key(item["name"])
                if key not in existing_keys:
                    existing.append(item)
                    existing_keys.add(key)
                    added += 1
            if added > 0:
                if doc.exists:
                    doc_ref.update({"items": existing})
                else:
                    doc_ref.set({"items": existing})
            return added
        except Exception as e:
            logger.warning(f"Error batch-adding scraping ingredients: {e}")
            return 0

    def remove_scraping_ingredients(self, names: List[str]) -> bool:
        """Remove ingredients by name from the unified list."""
        if self.db is None or not names:
            return False
        to_remove = {(n or "").strip() for n in names if n}
        if not to_remove:
            return False
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.SCRAPING_INGREDIENTS_DOC
            )
            doc = doc_ref.get()
            if not doc.exists:
                return True
            existing = (doc.to_dict() or {}).get("items") or []
            filtered = [i for i in existing if isinstance(i, dict) and str(i.get("name") or "").strip() not in to_remove]
            doc_ref.update({"items": filtered})
            return True
        except Exception as e:
            logger.warning(f"Error removing scraping ingredients: {e}")
            return False

    @staticmethod
    def _cart_hit_doc_id(name: str) -> str:
        """재료명 → Firestore 문서 ID. '/'는 경로 구분자라 치환 필요."""
        s = (name or "").strip()
        return s.replace("/", "_") or "_empty_"

    def update_scraping_ingredient_cart_hit(self, name: str) -> bool:
        """Record that an ingredient was added to a shopping cart.
        Writes to a dedicated per-ingredient document in CART_HIT_COLLECTION
        (no read-before-write, no shared large-array rewrite) so tier logic
        (classify_tier) can promote it via get_cart_hit_map()."""
        if self.db is None:
            return False
        s = (name or "").strip()
        if not s:
            return False
        try:
            from datetime import datetime, timezone
            doc_id = self._cart_hit_doc_id(s)
            self.db.collection(self.CART_HIT_COLLECTION).document(doc_id).set(
                {"name": s, "last_cart_hit": datetime.now(timezone.utc).isoformat()},
                merge=True,
            )
            return True
        except Exception as e:
            logger.warning(f"Error updating cart hit for '{s}': {e}")
            return False

    def get_cart_hit_map(self, force_refresh: bool = False) -> Dict[str, str]:
        """스케줄러 전용: CART_HIT_COLLECTION을 읽어
        {재료명: last_cart_hit(ISO 문자열)} 딕셔너리로 반환.

        사이클 시작 때 get_tier_summary + get_ingredients_list가 연속 호출하므로
        짧은 TTL 캐시로 전체 스트림을 한 번만 탄다.
        """
        global _CART_HIT_MAP_CACHE, _CART_HIT_MAP_CACHE_AT
        now = time.time()
        if (
            not force_refresh
            and _CART_HIT_MAP_CACHE_AT > 0
            and now - _CART_HIT_MAP_CACHE_AT < _CART_HIT_MAP_CACHE_TTL_SECONDS
        ):
            return dict(_CART_HIT_MAP_CACHE)
        if self.db is None:
            return {}
        try:
            result: Dict[str, str] = {}
            for doc in self.db.collection(self.CART_HIT_COLLECTION).stream():
                data = doc.to_dict() or {}
                name = str(data.get("name") or doc.id).strip()
                last_hit = data.get("last_cart_hit")
                if name and last_hit:
                    result[name] = last_hit
            _CART_HIT_MAP_CACHE = result
            _CART_HIT_MAP_CACHE_AT = now
            return dict(result)
        except Exception as e:
            logger.warning(f"Error reading cart hit map: {e}")
            return dict(_CART_HIT_MAP_CACHE)

    def get_scraping_cycle_number(self) -> int:
        """Get the current scraping cycle number (persisted across restarts)."""
        if self.db is None:
            return 0
        try:
            doc = self.db.collection(self.CONFIG_COLLECTION).document("scraping_cycle").get()
            if not doc.exists:
                return 0
            return int((doc.to_dict() or {}).get("cycle", 0))
        except Exception:
            return 0

    def increment_scraping_cycle(self) -> int:
        """Increment and return the new cycle number."""
        if self.db is None:
            return 0
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document("scraping_cycle")
            doc = doc_ref.get()
            current = int((doc.to_dict() or {}).get("cycle", 0)) if doc.exists else 0
            new_cycle = current + 1
            doc_ref.set({"cycle": new_cycle})
            return new_cycle
        except Exception:
            return 0

    # --- Product coverage tracking (health check optimization) ---

    def get_product_coverage_verified(self) -> set:
        """Ingredient names confirmed to have products — skip in future health checks."""
        if self.db is None:
            return set()
        try:
            doc = (
                self.db.collection(self.CONFIG_COLLECTION)
                .document(self.PRODUCT_COVERAGE_VERIFIED_DOC)
                .get()
            )
            if not doc.exists:
                return set()
            return set((doc.to_dict() or {}).get("ingredients") or [])
        except Exception as e:
            logger.warning(f"Error reading product coverage verified: {e}")
            return set()

    def add_product_coverage_verified(self, names: List[str]) -> bool:
        """Mark ingredients as having confirmed products."""
        if self.db is None or not names:
            return True
        clean = [s for s in (n.strip() for n in names) if s]
        if not clean:
            return True
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PRODUCT_COVERAGE_VERIFIED_DOC)
            doc_ref.set({"ingredients": firestore.ArrayUnion(clean)}, merge=True)
            return True
        except Exception as e:
            logger.warning(f"Error updating product coverage verified: {e}")
            return False

    def normalize_ingredient_name_for_unit_price_queue(self, name: str) -> Optional[str]:
        """큐/Firestore 문서 ID에 쓸 재료명 정규화. 빈 문자열이면 None."""
        if not name or not isinstance(name, str):
            return None
        s = re.sub(r"\s+", " ", name.strip())
        if not s:
            return None
        if len(s) > self.MAX_UNIT_PRICE_QUEUE_NAME_LEN:
            s = s[: self.MAX_UNIT_PRICE_QUEUE_NAME_LEN].rstrip()
        return s if s else None

    @staticmethod
    def _sanitize_ingredient_doc_id(name: str) -> str:
        """
        Firestore 문서 ID에 사용할 수 있도록 재료명에서 '/'를 '_'로 치환.
        Firestore는 '/'를 경로 구분자로 해석하므로 그대로 쓰면
        'A document must have an even number of path elements' 에러가 발생합니다.
        """
        if not isinstance(name, str):
            return name
        return name.replace("/", "_")

    def normalize_unit_key_for_unit_prices(self, unit: str) -> Optional[str]:
        """
        ingredient_unit_prices/{ingredient}/units/{unitKey} 문서 ID 정규화.
        - 'g' <-> '그램'
        - 'ml' <-> '밀리리터'
        - '개' <-> '구'
        그 외에는 공백을 '_'로 바꾼 뒤 소문자 처리합니다.
        """
        if not unit or not isinstance(unit, str):
            return None
        s = re.sub(r"\s+", "_", unit.strip()).lower()
        if not s:
            return None
        # Common synonyms
        if s in ("그램", "g"):
            s = "g"
        elif s in ("밀리리터", "ml"):
            s = "ml"
        elif s in ("구", "개"):
            s = "개"
        # Firestore path safety
        s = s.replace("/", "_")
        return s if s else None

    def add_pending_unit_price_ingredients(self, names: List[str]) -> int:
        """
        단가 수집 대기 큐에 재료명 추가 (ArrayUnion, 정규화 후 중복은 Firestore가 병합).
        Returns: 정규화 후 유효한 이름 개수(요청에 포함된 고유 개수).
        """
        if self.db is None:
            return 0
        seen: set = set()
        union_list: List[str] = []
        for raw in names:
            n = self.normalize_ingredient_name_for_unit_price_queue(raw)
            if not n or n in seen:
                continue
            seen.add(n)
            union_list.append(n)
        if not union_list:
            return 0
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PENDING_UNIT_PRICE_DOC)
            doc_ref.set({"ingredients": firestore.ArrayUnion(union_list)}, merge=True)
            logger.info(f"Added pending unit price ingredients: {len(union_list)} name(s)")
            return len(union_list)
        except Exception as e:
            logger.warning(f"Error adding pending unit price ingredients: {e}")
            return 0

    def get_pending_unit_price_ingredients(self) -> List[str]:
        """단가 수집 대기 큐 (정규화된 재료명 목록)."""
        if self.db is None:
            return []
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PENDING_UNIT_PRICE_DOC)
            doc = doc_ref.get()
            if not doc.exists:
                return []
            data = doc.to_dict() or {}
            return list(data.get("ingredients") or [])
        except Exception as e:
            logger.warning(f"Error reading pending unit price ingredients: {e}")
            return []

    def remove_unit_price_names_from_pending(self, names: List[str]) -> bool:
        """큐에서 처리 완료된 재료명 제거 (ArrayRemove)."""
        if self.db is None or not names:
            return True
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(self.PENDING_UNIT_PRICE_DOC)
            doc_ref.set({"ingredients": firestore.ArrayRemove(names)}, merge=True)
            return True
        except Exception as e:
            logger.warning(f"Error removing from pending unit price queue: {e}")
            return False

    def add_pending_unit_price_recheck_ingredients(self, names: List[str]) -> int:
        """
        단가 재조사 큐에 재료명 추가 (ArrayUnion → 동일 이름은 Firestore가 중복 없이 병합).
        """
        if self.db is None:
            return 0
        seen: set = set()
        union_list: List[str] = []
        for raw in names:
            n = self.normalize_ingredient_name_for_unit_price_queue(raw)
            if not n or n in seen:
                continue
            seen.add(n)
            union_list.append(n)
        if not union_list:
            return 0
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.PENDING_UNIT_PRICE_RECHECK_DOC
            )
            doc_ref.set({"ingredients": firestore.ArrayUnion(union_list)}, merge=True)
            logger.info(f"Added pending unit price recheck: {len(union_list)} name(s)")
            return len(union_list)
        except Exception as e:
            logger.warning(f"Error adding pending unit price recheck: {e}")
            return 0

    def get_pending_unit_price_recheck_ingredients(self) -> List[str]:
        """단가 재조사 대기 큐."""
        if self.db is None:
            return []
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.PENDING_UNIT_PRICE_RECHECK_DOC
            )
            doc = doc_ref.get()
            if not doc.exists:
                return []
            data = doc.to_dict() or {}
            return list(data.get("ingredients") or [])
        except Exception as e:
            logger.warning(f"Error reading pending unit price recheck queue: {e}")
            return []

    def remove_unit_price_recheck_names(self, names: List[str]) -> bool:
        """재조사 큐에서 처리 완료된 이름 제거."""
        if self.db is None or not names:
            return True
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.PENDING_UNIT_PRICE_RECHECK_DOC
            )
            doc_ref.set({"ingredients": firestore.ArrayRemove(names)}, merge=True)
            return True
        except Exception as e:
            logger.warning(f"Error removing from unit price recheck queue: {e}")
            return False

    # --- 재료 단가 LLM 재시도 백오프 상태 (pending_unit_price / recheck / scraping 3개 큐 공용) ---

    def get_price_retry_state(self) -> Dict[str, Dict[str, Any]]:
        """재료 단가 큐 공용 재시도 상태 조회. {name: {failCount, lastAttemptAt}}"""
        if self.db is None:
            return {}
        try:
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.PRICE_RETRY_STATE_DOC
            )
            doc = doc_ref.get()
            if not doc.exists:
                return {}
            data = doc.to_dict() or {}
            state = data.get("state") or {}
            return state if isinstance(state, dict) else {}
        except Exception as e:
            logger.warning(f"Error reading price retry state: {e}")
            return {}

    def record_price_attempt_results(
        self,
        success_names: List[str],
        failed_names: List[str],
        permanent_names: Optional[List[str]] = None,
    ) -> bool:
        """재료 단가 LLM 시도 결과를 반영.

        - 성공: 재시도 상태 삭제
        - 프로바이더 장애(failed_names): failCount +1, retryable=True. 24시간 뒤 1회만 더 허용
        - 모델이 단가를 못 만듦(permanent_names): retryable=False. 다시 호출하지 않음
        """
        if self.db is None:
            return False
        success_names = [n for n in (success_names or []) if n]
        failed_names = [n for n in (failed_names or []) if n]
        permanent_names = [n for n in (permanent_names or []) if n]
        if not success_names and not failed_names and not permanent_names:
            return True
        try:
            state_updates: Dict[str, Any] = {}
            for name in failed_names:
                state_updates[name] = {
                    "failCount": firestore.Increment(1),
                    "lastAttemptAt": firestore.SERVER_TIMESTAMP,
                    "retryable": True,
                }
            for name in permanent_names:
                state_updates[name] = {
                    "failCount": 1,
                    "lastAttemptAt": firestore.SERVER_TIMESTAMP,
                    "retryable": False,
                }
            for name in success_names:
                state_updates[name] = firestore.DELETE_FIELD
            doc_ref = self.db.collection(self.CONFIG_COLLECTION).document(
                self.PRICE_RETRY_STATE_DOC
            )
            doc_ref.set({"state": state_updates}, merge=True)
            return True
        except Exception as e:
            logger.warning(f"Error recording price retry state: {e}")
            return False

    def price_retry_block_reason(self, name: str) -> Optional[str]:
        """이 재료를 지금 LLM에 다시 물으면 안 되는 이유. 없으면 None."""
        if not name:
            return "given_up"
        state = self.get_price_retry_state()
        return price_retry_block(state.get(name), datetime.now(timezone.utc))

    def filter_price_names_eligible_for_retry(
        self, names: List[str], limit: int
    ) -> Tuple[List[str], int, int]:
        """대기 큐 이름 목록에서 재시도 백오프 규칙을 적용해 이번 배치에 시도할 이름을 뽑는다.

        규칙:
        - 모델이 단가를 못 만든 재료, 장애 재시도까지 끝난 재료: 포기
        - 프로바이더 장애 1회: 24시간 쿨다운 후 한 번만 더
        - 앞쪽 이름이 쿨다운/포기 상태여도 스캔은 계속되어 뒤쪽의 새 이름을 채운다

        Returns: (eligible_names, skipped_cooldown_count, skipped_given_up_count)
        """
        if not names or limit <= 0:
            return [], 0, 0
        state = self.get_price_retry_state()
        now = datetime.now(timezone.utc)
        eligible: List[str] = []
        skipped_cooldown = 0
        skipped_given_up = 0
        for name in names:
            block = price_retry_block(state.get(name), now)
            if block == "given_up":
                skipped_given_up += 1
                continue
            if block == "cooldown":
                skipped_cooldown += 1
                continue
            eligible.append(name)
            if len(eligible) >= limit:
                break
        return eligible, skipped_cooldown, skipped_given_up

    def save_ingredient_price_issue_report(self, payload: Dict[str, Any]) -> bool:
        """사용자 재료 가격 문제 보고 로그 (감사/분석용)."""
        if self.db is None:
            return False
        try:
            data = {**payload, "createdAt": firestore.SERVER_TIMESTAMP}
            self.db.collection("ingredient_price_issue_reports").add(data)
            return True
        except Exception as e:
            logger.warning(f"Error saving ingredient price issue report: {e}")
            return False

    def save_receipt_purchase(
        self,
        uid: str,
        *,
        store_name: Optional[str],
        purchased_at: Optional[str],
        items: List[Dict[str, Any]],
        store_branch: Optional[str] = None,
        store_address: Optional[str] = None,
        region_sido: Optional[str] = None,
        region_sigungu: Optional[str] = None,
        match_query: Optional[str] = None,
    ) -> bool:
        """영수증 스캔 1건을 사용자별 구매 이력 문서로 저장한다.

        저장 위치는 users/{uid}/receiptPurchases/{autoId} — savedRecipes 등
        기존 사용자 서브컬렉션과 동일한 규칙(uid로 소유권 분리)을 따른다.
        카드번호/전화번호 등 민감정보는 이 시점 이전에 fridge_vision_service의
        1차(프롬프트)·2차(정규식) 필터를 거친 값만 들어오지만, 저장하는 필드
        자체도 가격·매장·주소·수량·재료명 등 의미 있는 구매 데이터로 한정한다
        (영수증 원문 라인은 여기 저장하지 않음).

        storeAddress / regionSido / regionSigungu / matchQuery 는 이후 장소
        매칭(카카오 로컬 등)용 원천 정보이며, 이 메서드에서는 매칭 API를
        호출하지 않는다.
        """
        if self.db is None or not uid:
            return False
        try:
            total_amount = 0
            has_price = False
            clean_items: List[Dict[str, Any]] = []
            for it in items:
                price = it.get("price")
                if isinstance(price, (int, float)) and price > 0:
                    total_amount += int(price)
                    has_price = True
                clean_items.append({
                    "name": str(it.get("name") or "")[:60],
                    "category": str(it.get("category") or "")[:40],
                    "qty": float(it.get("qty") or 0),
                    "unit": str(it.get("unit") or "")[:20],
                    "price": int(price) if isinstance(price, (int, float)) and price > 0 else None,
                })
            if not clean_items:
                return False

            data: Dict[str, Any] = {
                "storeName": (store_name or None),
                "storeBranch": (store_branch or None),
                "storeAddress": (store_address or None),
                "regionSido": (region_sido or None),
                "regionSigungu": (region_sigungu or None),
                "matchQuery": (match_query or None),
                "purchasedAt": (purchased_at or None),
                "items": clean_items,
                "itemCount": len(clean_items),
                "totalAmount": total_amount if has_price else None,
                "source": "photo_receipt",
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
            self.db.collection("users").document(uid).collection(
                "receiptPurchases"
            ).add(data)
            return True
        except Exception as e:
            logger.warning(f"Error saving receipt purchase for uid={uid}: {e}")
            return False

    def has_ingredient_price(self, ingredient_name: str) -> bool:
        """ingredient_unit_prices에 해당 재료의 가격이 있는지 확인"""
        if self.db is None:
            return False
        try:
            doc_id = self._sanitize_ingredient_doc_id(ingredient_name)
            doc_ref = self.db.collection("ingredient_unit_prices").document(doc_id)
            doc = doc_ref.get()
            return doc.exists and doc.to_dict() is not None
        except Exception as e:
            logger.warning(f"Error checking ingredient price for '{ingredient_name}': {e}")
            return False

    def get_ingredient_price(self, ingredient_name: str) -> Optional[Dict[str, Any]]:
        """ingredient_unit_prices/{ingredient_name} 상위 문서 조회."""
        if self.db is None:
            return None
        try:
            doc_id = self._sanitize_ingredient_doc_id(ingredient_name)
            doc_ref = self.db.collection("ingredient_unit_prices").document(doc_id)
            doc = doc_ref.get()
            if not doc.exists or doc.to_dict() is None:
                return None
            return doc.to_dict()
        except Exception as e:
            logger.warning(f"Error getting ingredient price for '{ingredient_name}': {e}")
            return None
    
    def save_ingredient_price(
        self, 
        ingredient_name: str, 
        price_data: Dict[str, Any]
    ) -> bool:
        """
        재료 가격을 ingredient_unit_prices에 저장
        
        Args:
            ingredient_name: 재료명
            price_data: {
                "unitPrice": float,
                "baseUnit": str,
                "confidence": float (optional),
                "source": str (optional),
                "reasoning": str (optional)
            }
        
        Returns:
            True if successful, False otherwise
        """
        if self.db is None:
            return False
        
        try:
            doc_id = self._sanitize_ingredient_doc_id(ingredient_name)
            doc_ref = self.db.collection("ingredient_unit_prices").document(doc_id)
            
            doc_data = {
                "ingredientName": ingredient_name,
                "unitPrice": price_data.get("unitPrice"),
                "baseUnit": price_data.get("baseUnit"),
                "source": price_data.get("source", "ai_estimate"),
                "lastUpdated": firestore.SERVER_TIMESTAMP,
            }
            
            # 선택적 필드 추가
            if "confidence" in price_data:
                doc_data["confidence"] = price_data["confidence"]
            if "reasoning" in price_data:
                doc_data["reasoning"] = price_data["reasoning"]
            
            doc_ref.set(doc_data, merge=True)
            logger.info(f"Saved ingredient price: {ingredient_name} - {price_data.get('unitPrice')}원/{price_data.get('baseUnit')}")
            return True
            
        except Exception as e:
            logger.warning(f"Error saving ingredient price for '{ingredient_name}': {e}")
            return False

    def get_ingredient_unit_price(
        self,
        ingredient_name: str,
        unit_key: str,
    ) -> Optional[Dict[str, Any]]:
        """
        ingredient_unit_prices/{ingredient}/units/{unitKey}에서 해당 단위의 unitPrice/baseUnit 조회.
        """
        if self.db is None:
            return None
        try:
            doc_id = self._sanitize_ingredient_doc_id(ingredient_name)
            doc_ref = (
                self.db.collection("ingredient_unit_prices")
                .document(doc_id)
                .collection("units")
                .document(unit_key)
            )
            doc = doc_ref.get()
            if not doc.exists or doc.to_dict() is None:
                return None
            return doc.to_dict()
        except Exception as e:
            logger.warning(
                f"Error getting ingredient unit price for '{ingredient_name}' unit '{unit_key}': {e}"
            )
            return None

    def save_ingredient_unit_price(
        self,
        ingredient_name: str,
        unit_key: str,
        price_data: Dict[str, Any],
    ) -> bool:
        """
        ingredient_unit_prices/{ingredient}/units/{unitKey}에 저장.
        price_data는 최소 {unitPrice, baseUnit}를 포함해야 합니다.
        """
        if self.db is None:
            return False
        try:
            doc_id = self._sanitize_ingredient_doc_id(ingredient_name)
            doc_ref = (
                self.db.collection("ingredient_unit_prices")
                .document(doc_id)
                .collection("units")
                .document(unit_key)
            )
            doc_data = {
                "ingredientName": ingredient_name,
                "unitPrice": price_data.get("unitPrice"),
                "baseUnit": price_data.get("baseUnit"),
                "source": price_data.get("source", "ai_estimate"),
                "lastUpdated": firestore.SERVER_TIMESTAMP,
            }
            if "confidence" in price_data:
                doc_data["confidence"] = price_data.get("confidence")
            if "reasoning" in price_data:
                doc_data["reasoning"] = price_data.get("reasoning")

            doc_ref.set(doc_data, merge=True)
            return True
        except Exception as e:
            logger.warning(
                f"Error saving ingredient unit price for '{ingredient_name}' unit '{unit_key}': {e}"
            )
            return False
    
    def _extract_ingredient_name(self, query: str) -> str:
        """
        Extract ingredient name from query string by removing prefixes and units.
        
        Examples:
            "쌀 500g" -> "쌀"
            "국산 쌀 1kg" -> "쌀"
            "유기농 달걀 30구" -> "달걀"
        """
        # Remove common prefixes
        prefixes = ["국산 ", "유기농 "]
        cleaned = query
        for prefix in prefixes:
            if cleaned.startswith(prefix):
                cleaned = cleaned[len(prefix):]
                break
        
        # Remove units (numbers followed by units like g, kg, ml, L, 개, 구, etc.)
        # Pattern: optional number, optional decimal, unit (g, kg, ml, L, 개, 구, 묶음, 박스, etc.)
        unit_pattern = r'\s*\d+(?:\.\d+)?\s*(?:g|kg|ml|L|리터|그램|킬로그램|밀리리터|개|구|묶음|박스|봉지|망|포대|말통|식당용|대용량|한\s*판|대란\s*한\s*판|왕란|전장|100매|파래김\s*100장|24개입|18개입|36개입|20개입|멀티팩|2L\s*6개|2L\s*12개|1L\s*2개|2\.3L|900ml\s*2개|24팩|190ml\s*24개|1\.8L|10kg|20kg|3kg|5kg)\s*$'
        cleaned = re.sub(unit_pattern, '', cleaned, flags=re.IGNORECASE)
        
        # Remove any trailing whitespace
        cleaned = cleaned.strip()
        
        return cleaned if cleaned else query  # Fallback to original query if extraction fails
    
    def create_custom_token(self, uid: str, additional_claims: Optional[Dict[str, Any]] = None) -> str:
        """
        Firebase Custom Token을 생성합니다.
        
        Args:
            uid: Firebase 사용자 UID (카카오 ID를 사용)
            additional_claims: 추가 클레임 (예: {'kakao_id': '123456789'})
        
        Returns:
            Firebase Custom Token 문자열
        
        Raises:
            ValueError: Firebase가 초기화되지 않았거나 uid가 유효하지 않은 경우
        """
        if not self._initialized:
            raise ValueError("Firebase is not initialized")
        
        if not uid or not isinstance(uid, str):
            raise ValueError("uid must be a non-empty string")
        
        try:
            # Custom Token 생성
            custom_token = auth.create_custom_token(uid, additional_claims)
            logger.info(f"Created custom token for uid: {uid}")
            return custom_token.decode('utf-8')
        except Exception as e:
            logger.error(f"Failed to create custom token for uid {uid}: {e}")
            raise


# Global instance (for backward compatibility during migration)
_firebase_service: Optional[FirebaseService] = None


def get_firebase_service() -> FirebaseService:
    """Get or create global Firebase service instance"""
    global _firebase_service
    if _firebase_service is None:
        _firebase_service = FirebaseService()
        _firebase_service.initialize()
    return _firebase_service

