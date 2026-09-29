"""
쿠팡 recommend_products 단일 호출이 왜 6~8초 걸리는지 구간별로 측정.
로컬에서 실제 Firebase에 붙여서 real data로 확인 (스크립트 실행 후 삭제 예정).
"""
import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

os.environ.setdefault("PYTHONIOENCODING", "utf-8")


async def main():
    from models import ProductSearchRequest
    from services.product_service import get_product_service
    from services import coupang_service

    service = get_product_service()

    # 1) get_scraped_products_for_ingredient 자체 시간 (문서 캐시 이미 워밍업된 상태 가정)
    t0 = time.perf_counter()
    products = await service._run_to_thread_limited(
        coupang_service.get_scraped_products_for_ingredient,
        "대파",
        fallback=[],
        op_name="diag_fetch",
    )
    t_fetch = time.perf_counter() - t0
    print(f"[1] get_scraped_products_for_ingredient: {t_fetch*1000:.0f}ms, n={len(products)}")

    n_missing_deeplink = sum(1 for p in products if not (p.deeplink_url or "").strip())
    n_has_deeplink = len(products) - n_missing_deeplink
    print(f"    deeplink_url 있음={n_has_deeplink} 없음(=API콜 필요)={n_missing_deeplink}")

    # 2) enrich 단계만 따로 측정 (combined = 전체 products, 실제 로직과 동일하게)
    t0 = time.perf_counter()
    enriched = await service._run_to_thread_limited(
        service._enrich_coupang_products_deeplinks_sync,
        products,
        fallback=products,
        op_name="diag_enrich",
    )
    t_enrich = time.perf_counter() - t0
    print(f"[2] deeplink enrich ({len(products)}개): {t_enrich*1000:.0f}ms")

    # 3) 전체 recommend_products 호출 (엔드투엔드, 위 스텝들 포함)
    t0 = time.perf_counter()
    resp = await service.recommend_products(
        ProductSearchRequest(ingredient_name="대파", marketplace="coupang", needed_qty=1, needed_unit="개")
    )
    t_full = time.perf_counter() - t0
    print(f"[3] recommend_products (coupang, full): {t_full*1000:.0f}ms, "
          f"best_match={'Y' if resp.best_match else 'N'}, see_more={len(resp.see_more_list)}")


if __name__ == "__main__":
    asyncio.run(main())
