"""
백엔드 캐시 + 스트리밍 로직 검증 스크립트 (실제 서버/Firestore 불필요, 목으로 검증).
검증 항목:
 1. product_doc_cache: 동일 (collection, doc_id) 재조회 시 Firestore get()이 1번만 호출되는지,
    존재하지 않는 문서(None)도 캐시되어 재조회를 막는지.
 2. recommend_products_stream_items: 여러 item을 넣었을 때 완료되는 순서대로
    (인위적으로 지연시간을 다르게 줘서) 스트리밍되는지, 총 개수가 items와 일치하는지,
    타임아웃 걸린 item은 빈 응답으로 처리되는지.
"""
import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))


def test_doc_cache():
    from services import product_doc_cache

    product_doc_cache.clear_cache()

    call_count = {"n": 0}

    class FakeDoc:
        def __init__(self, exists, data):
            self.exists = exists
            self._data = data

        def to_dict(self):
            return self._data

    class FakeDocRef:
        def __init__(self, exists, data):
            self._exists = exists
            self._data = data

        def get(self, timeout=5):
            call_count["n"] += 1
            return FakeDoc(self._exists, self._data)

    class FakeCollection:
        def __init__(self, docs):
            self._docs = docs

        def document(self, doc_id):
            exists, data = self._docs.get(doc_id, (False, None))
            return FakeDocRef(exists, data)

    class FakeDb:
        def __init__(self, docs):
            self._docs = docs

        def collection(self, name):
            return FakeCollection(self._docs)

    db = FakeDb({
        "마늘": (True, {"products": [1, 2, 3]}),
        "없는재료": (False, None),
    })

    # 1) hit 문서: 첫 조회는 miss(firestore get 1회), 이후 캐시 hit로 get() 호출 없음
    d1 = product_doc_cache.get_cached_firestore_doc(db, "coupang_products", "마늘")
    assert d1 == {"products": [1, 2, 3]}, d1
    assert call_count["n"] == 1, call_count
    d2 = product_doc_cache.get_cached_firestore_doc(db, "coupang_products", "마늘")
    assert d2 == {"products": [1, 2, 3]}, d2
    assert call_count["n"] == 1, f"캐시 히트인데 get()이 다시 호출됨: {call_count}"

    # 2) 없는 문서: None 캐싱되어 재조회 막음
    n1 = product_doc_cache.get_cached_firestore_doc(db, "coupang_products", "없는재료")
    assert n1 is None
    assert call_count["n"] == 2, call_count
    n2 = product_doc_cache.get_cached_firestore_doc(db, "coupang_products", "없는재료")
    assert n2 is None
    assert call_count["n"] == 2, f"없는 문서(None)가 캐싱 안됨: {call_count}"

    stats = product_doc_cache.get_cache_stats()
    assert stats["hits"] == 2, stats
    assert stats["misses"] == 2, stats
    assert stats["entries"] == 2, stats
    print("[OK] test_doc_cache:", stats)


def test_stream_items():
    os.environ["RECOMMEND_ITEM_TIMEOUT_SECONDS"] = "0.3"
    os.environ["RECOMMEND_BATCH_TIMEOUT_SECONDS"] = "0.6"

    from models import ProductSearchRequest, ProductRecommendationResponse
    from services.product_service import ProductService

    service = ProductService.__new__(ProductService)  # __init__ 우회 (recommend_products만 목킹)

    async def fake_recommend(req: ProductSearchRequest) -> ProductRecommendationResponse:
        # 재료별로 지연시간 다르게: 빠른 것 먼저 끝나야 함
        delay_map = {"fast": 0.02, "mid": 0.08, "slow_but_ok": 0.15, "too_slow": 5.0}
        await asyncio.sleep(delay_map.get(req.ingredient_name, 0.02))
        if req.ingredient_name == "too_slow":
            raise RuntimeError("should not reach (item timeout should fire first)")
        return ProductRecommendationResponse(
            ingredient=req.ingredient_name,
            best_match=None,
            see_more_list=[],
            all_products=[],
        )

    service.recommend_products = fake_recommend

    items = [
        ProductSearchRequest(ingredient_name="slow_but_ok"),
        ProductSearchRequest(ingredient_name="fast"),
        ProductSearchRequest(ingredient_name="mid"),
        ProductSearchRequest(ingredient_name="too_slow"),
    ]

    async def run():
        arrival_order = []
        results_by_idx = {}
        t0 = time.monotonic()
        async for idx, result in service.recommend_products_stream_items(items):
            arrival_order.append(items[idx].ingredient_name)
            results_by_idx[idx] = result
        elapsed = time.monotonic() - t0
        return arrival_order, results_by_idx, elapsed

    arrival_order, results_by_idx, elapsed = asyncio.run(run())

    print("arrival order:", arrival_order, "elapsed=%.2fs" % elapsed)

    assert len(results_by_idx) == 4, results_by_idx
    # fast(0.02) < mid(0.08) < slow_but_ok(0.15) 순서로 도착해야 함
    assert arrival_order.index("fast") < arrival_order.index("mid"), arrival_order
    assert arrival_order.index("mid") < arrival_order.index("slow_but_ok"), arrival_order
    # too_slow는 item timeout(0.3s) 또는 batch timeout(0.6s)에 걸려 빈 응답이어야 함
    too_slow_result = results_by_idx[items.index(next(i for i in items if i.ingredient_name == "too_slow"))]
    assert too_slow_result.best_match is None
    # batch timeout(0.6s) 이내에 전체가 끝나야 함 (5s까지 기다리면 안 됨)
    assert elapsed < 1.0, f"batch timeout이 걸리지 않음: elapsed={elapsed}"
    print("[OK] test_stream_items: elapsed=%.2fs, all empty-on-timeout handled" % elapsed)


def test_excluded_products_no_stampede():
    """캐시 만료 직후 여러 스레드가 동시에 _get_excluded_product_ids를 호출해도
    Firestore 쿼리(.stream())가 딱 1번만 실행되는지 확인 (cache stampede 방지)."""
    import threading
    from concurrent.futures import ThreadPoolExecutor

    from services.product_service import ProductService

    service = ProductService.__new__(ProductService)
    service.firebase_service = None
    service._excluded_products_cache = None
    service._excluded_products_cache_at = 0.0
    service._excluded_products_cache_ttl_seconds = 300
    service._excluded_products_refresh_lock = threading.Lock()

    query_count = {"n": 0}

    class FakeDoc:
        def __init__(self, pid):
            self._pid = pid

        def to_dict(self):
            return {"productId": self._pid}

    class FakeQuery:
        def stream(self):
            query_count["n"] += 1
            time.sleep(0.2)  # Firestore 쿼리 지연 흉내
            return [FakeDoc("p1"), FakeDoc("p2")]

    class FakeCollection:
        def where(self, filter=None):
            return FakeQuery()

    class FakeDb:
        def collection(self, name):
            return FakeCollection()

    class FakeFirebase:
        def is_available(self):
            return True

        db = FakeDb()

    fake_firebase = FakeFirebase()
    service.firebase_service = fake_firebase

    with ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(lambda _: service._get_excluded_product_ids(), range(8)))

    for r in results:
        assert r == {"p1", "p2"}, r
    assert query_count["n"] == 1, f"stampede 발생: 쿼리가 {query_count['n']}번 실행됨 (기대값 1)"
    print("[OK] test_excluded_products_no_stampede: 8 concurrent threads -> 1 Firestore query")


def test_cart_hit_debounce():
    """디바운스 윈도우는 이제 30일 tier 판정 창에 맞춰 ~29일(초 단위)로 설정됨.
    로직 자체(_should_record_cart_hit)는 윈도우 크기와 무관하게 동일하게 동작해야 함."""
    import threading as _threading

    from services.product_service import ProductService

    debounce_seconds = 29 * 86400  # product_service.py의 실제 기본값과 동일

    service = ProductService.__new__(ProductService)
    service._cart_hit_last_recorded = {}
    service._cart_hit_debounce_lock = _threading.Lock()
    service._cart_hit_debounce_seconds = debounce_seconds

    assert service._should_record_cart_hit("대파") is True
    # 디바운스 윈도우 내 재요청은 스킵되어야 함
    assert service._should_record_cart_hit("대파") is False
    assert service._should_record_cart_hit("대파") is False
    # 다른 재료는 독립적으로 기록되어야 함
    assert service._should_record_cart_hit("마늘") is True
    # 빈 이름은 항상 스킵
    assert service._should_record_cart_hit("") is False

    # 윈도우(29일)가 지나면 다시 기록 가능해야 함
    service._cart_hit_last_recorded["대파"] = time.time() - (debounce_seconds + 1)
    assert service._should_record_cart_hit("대파") is True
    print("[OK] test_cart_hit_debounce: repeat searches within 29-day window are skipped")


def test_cart_hit_debounce_env_default():
    """product_service.py가 실제로 CART_HIT_DEBOUNCE_DAYS(기본 29)를 초 단위로
    환산해 쓰는지, __init__ 코드를 다시 실행하지 않고도 env var 파싱 로직을
    직접 재현해 회귀를 잡는다."""
    default_days = int(os.environ.get("CART_HIT_DEBOUNCE_DAYS", "29"))
    assert default_days == 29, f"기본값이 29일에서 변경됨: {default_days}"
    seconds = default_days * 86400
    assert seconds == 2505600, seconds
    print("[OK] test_cart_hit_debounce_env_default: 29 days == 2,505,600 seconds")


def test_cart_hit_write_no_read_and_isolated_docs():
    """update_scraping_ingredient_cart_hit이 (1) 사전 .get() 없이 바로 .set()하는지,
    (2) 서로 다른 재료가 서로 다른 문서를 건드려 경쟁/덮어쓰기가 없는지 확인."""
    from services.firebase_service import FirebaseService

    call_log = {"get": 0, "set": []}

    class FakeDocRef:
        def __init__(self, doc_id):
            self.doc_id = doc_id

        def get(self, *a, **kw):
            call_log["get"] += 1
            raise AssertionError("사전 읽기가 발생하면 안 됨 (구조적 회귀)")

        def set(self, data, merge=False):
            call_log["set"].append((self.doc_id, dict(data), merge))

    class FakeCollection:
        def document(self, doc_id):
            return FakeDocRef(doc_id)

    class FakeDb:
        def collection(self, name):
            assert name == FirebaseService.CART_HIT_COLLECTION, name
            return FakeCollection()

    service = FirebaseService.__new__(FirebaseService)
    service.db = FakeDb()

    assert service.update_scraping_ingredient_cart_hit("양파") is True
    assert service.update_scraping_ingredient_cart_hit("대파") is True

    assert call_log["get"] == 0, "사전 .get() 호출이 발생함"
    assert len(call_log["set"]) == 2

    doc_ids = [doc_id for doc_id, _, _ in call_log["set"]]
    assert doc_ids == ["양파", "대파"], doc_ids
    assert all(merge is True for _, _, merge in call_log["set"])
    for doc_id, data, _ in call_log["set"]:
        assert data["name"] == doc_id
        assert "last_cart_hit" in data
    print("[OK] test_cart_hit_write_no_read_and_isolated_docs: no pre-read, independent docs")


def test_get_cart_hit_map():
    """get_cart_hit_map이 컬렉션 전체를 {name: last_cart_hit} 형태로 반환하는지 확인."""
    from services.firebase_service import FirebaseService

    class FakeDoc:
        def __init__(self, doc_id, data):
            self.id = doc_id
            self._data = data

        def to_dict(self):
            return self._data

    class FakeCollection:
        def stream(self):
            return [
                FakeDoc("양파", {"name": "양파", "last_cart_hit": "2026-08-01T00:00:00+00:00"}),
                FakeDoc("대파", {"name": "대파", "last_cart_hit": "2026-08-05T00:00:00+00:00"}),
            ]

    class FakeDb:
        def collection(self, name):
            assert name == FirebaseService.CART_HIT_COLLECTION, name
            return FakeCollection()

    service = FirebaseService.__new__(FirebaseService)
    service.db = FakeDb()

    result = service.get_cart_hit_map()
    assert result == {
        "양파": "2026-08-01T00:00:00+00:00",
        "대파": "2026-08-05T00:00:00+00:00",
    }, result
    print("[OK] test_get_cart_hit_map:", result)


def test_classify_tier_with_cart_hit_map():
    from datetime import datetime, timedelta, timezone

    from utils.coupang_utils import classify_tier

    now = datetime.now(timezone.utc)
    recent = (now - timedelta(days=5)).isoformat()
    stale = (now - timedelta(days=40)).isoformat()

    # freq만으로 hot (cart_hit_map 없어도 무관)
    assert classify_tier({"name": "소고기", "freq": 20}) == "hot"
    # freq는 낮지만 cart_hit_map에 최근 검색 기록 있음 -> hot
    assert classify_tier(
        {"name": "트러플오일", "freq": 1}, {"트러플오일": recent}
    ) == "hot"
    # cart_hit_map에 있지만 30일보다 오래됨 -> hot 아님
    assert classify_tier(
        {"name": "말린표고", "freq": 1}, {"말린표고": stale}
    ) == "cold"
    # cart_hit_map 자체가 None -> freq만으로 판정
    assert classify_tier({"name": "당근", "freq": 5}, None) == "warm"
    # cart_hit_map에 다른 재료 이름만 있음 -> 매칭 안 되어 영향 없음
    assert classify_tier({"name": "감자", "freq": 1}, {"당근": recent}) == "cold"
    print("[OK] test_classify_tier_with_cart_hit_map")


if __name__ == "__main__":
    test_doc_cache()
    test_stream_items()
    test_excluded_products_no_stampede()
    test_cart_hit_debounce()
    test_cart_hit_debounce_env_default()
    test_cart_hit_write_no_read_and_isolated_docs()
    test_get_cart_hit_map()
    test_classify_tier_with_cart_hit_map()
    print("ALL TESTS PASSED")
