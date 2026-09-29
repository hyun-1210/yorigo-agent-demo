"""
Railway에서 실행되는 재료 가격 수집 스케줄러
24시간 주기로
  - pending_unit_price_recheck_ingredients (사용자 재료 가격 문제 보고 → 재추정·덮어쓰기)
  - pending_unit_price_ingredients (레시피 디테일 미적재 재료 보고)
  - pending_scraping_ingredients
를 읽어 AI로 단가를 채워 ingredient_unit_prices에 저장한다.

한 재료는 모델이 단가를 못 만들면 다시 묻지 않는다.
호출 자체가 실패한 경우만 24시간 뒤 1회 재시도한다.
"""
import time
import sys
import os
from datetime import datetime, timedelta
from typing import List, Optional, Set
import logging

# Ensure we can import from services
current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

from services.firebase_service import get_firebase_service
from services.llm_service import get_llm_service
from services.mixpanel_service import get_mixpanel_service

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Mixpanel distinct_id: 배치 스케줄러는 특정 사용자가 아닌 시스템 프로세스이므로 고정 식별자 사용.
_SCHEDULER_DISTINCT_ID = "system_price_scheduler"


def _note_price_attempt(firebase_service, name: str, *, saved: bool, outcome: str) -> str:
    """단가 시도 1건을 바로 기록한다. 반환은 success | transient | permanent."""
    if saved:
        firebase_service.record_price_attempt_results([name], [])
        return "success"
    # 가격은 받았는데 저장만 실패한 경우도 장애로 보고 하루 뒤 한 번만 다시 시도한다.
    if outcome == "unavailable" or outcome == "ok":
        firebase_service.record_price_attempt_results([], [name])
        return "transient"
    firebase_service.record_price_attempt_results([], [], permanent_names=[name])
    return "permanent"


def _track_batch_llm_usage(event: str, llm_service, *, calls: int, success: int, fail: int, **extra) -> None:
    """배치 사이클 동안 누적된 LLM 토큰 사용량을 Mixpanel에 fire-and-forget 전송."""
    if calls <= 0:
        return
    try:
        get_mixpanel_service().track(_SCHEDULER_DISTINCT_ID, event, {
            "llm_call_count": calls,
            "success_count": success,
            "fail_count": fail,
            **extra,
        })
    except Exception as e:
        logger.warning(f"Mixpanel 배치 이벤트 전송 실패({event}, 무시): {e}")


def collect_prices_for_pending_unit_price_ingredients(
    already_called: Optional[Set[str]] = None,
):
    """
    pending_unit_price_ingredients 큐: 이미 문서가 있으면 큐에서 제거,
    한 사이클에서 LLM 호출은 PENDING_UNIT_PRICE_BATCH_SIZE개까지.
    Returns:
        (success_count, fail_count, skip_count) 튜플
    """
    firebase_service = get_firebase_service()
    llm_service = get_llm_service()

    if not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다. 단가 큐 처리를 건너뜁니다.")
        return 0, 0, 0

    batch_size = int(os.getenv("PENDING_UNIT_PRICE_BATCH_SIZE", "100"))
    pending = firebase_service.get_pending_unit_price_ingredients()
    if not pending:
        logger.info("단가 큐(pending_unit_price_ingredients): 대기 항목 없음")
        return 0, 0, 0

    cleanup = [n for n in pending if firebase_service.has_ingredient_price(n)]
    if cleanup:
        firebase_service.remove_unit_price_names_from_pending(cleanup)
        logger.info(
            f"단가 큐: 이미 가격 문서 있음 → 큐에서 {len(cleanup)}개 제거"
        )

    pending = [n for n in pending if n not in cleanup]
    if not pending:
        return 0, 0, len(cleanup)

    eligible, skipped_cooldown, skipped_given_up = firebase_service.filter_price_names_eligible_for_retry(
        pending, batch_size
    )
    if skipped_cooldown or skipped_given_up:
        logger.info(
            f"단가 큐: 백오프로 스킵 — 쿨다운 {skipped_cooldown}개, 영구포기 {skipped_given_up}개"
        )
    logger.info(f"단가 큐 처리 시작: {len(eligible)}개 (배치 상한 {batch_size})")

    success_count = 0
    fail_count = 0
    saved_ok: List[str] = []
    llm_calls = 0
    usage_totals = [0, 0, 0]
    called = already_called if already_called is not None else set()

    for ingredient_name in eligible:
        try:
            if ingredient_name in called or firebase_service.has_ingredient_price(ingredient_name):
                saved_ok.append(ingredient_name)
                continue
            called.add(ingredient_name)
            logger.info(f"🔍 [단가큐] {ingredient_name}: AI에게 가격 요청 중...")
            llm_service.reset_last_usage_tokens()
            price_data = llm_service.get_ingredient_price_from_ai(ingredient_name)
            llm_calls += 1
            inp, out, think = llm_service.last_usage_tokens
            usage_totals[0] += inp
            usage_totals[1] += out
            usage_totals[2] += think
            saved = bool(
                price_data
                and price_data.get("unitPrice")
                and price_data.get("baseUnit")
                and firebase_service.save_ingredient_price(ingredient_name, price_data)
            )
            kind = _note_price_attempt(
                firebase_service,
                ingredient_name,
                saved=saved,
                outcome=llm_service.last_price_outcome,
            )
            if kind == "success":
                success_count += 1
                saved_ok.append(ingredient_name)
                logger.info(
                    f"✅ [단가큐] {ingredient_name}: {price_data['unitPrice']}원/{price_data['baseUnit']} 저장 완료"
                )
            else:
                fail_count += 1
                if kind == "permanent":
                    saved_ok.append(ingredient_name)
                logger.warning(
                    f"⚠️ [단가큐] {ingredient_name}: 단가 없음, 다시 묻지 않음"
                    if kind == "permanent"
                    else f"⚠️ [단가큐] {ingredient_name}: 호출 실패, 24시간 뒤 1회만 재시도"
                )
        except Exception as e:
            fail_count += 1
            called.add(ingredient_name)
            _note_price_attempt(
                firebase_service, ingredient_name, saved=False, outcome="unavailable"
            )
            logger.error(f"❌ [단가큐] {ingredient_name} 가격 수집 실패: {e}", exc_info=True)

    if saved_ok:
        firebase_service.remove_unit_price_names_from_pending(saved_ok)
        logger.info(f"단가 큐: 처리 완료 {len(saved_ok)}개 이름 제거")

    _track_batch_llm_usage(
        "llm_ingredient_unit_price_batch", llm_service,
        calls=llm_calls, success=success_count, fail=fail_count,
        llm_input_tokens=usage_totals[0], llm_output_tokens=usage_totals[1],
        llm_thinking_tokens=usage_totals[2],
        llm_total_tokens=sum(usage_totals),
        queue="pending_unit_price_ingredients",
        skipped_cooldown=skipped_cooldown, skipped_given_up=skipped_given_up,
    )

    logger.info(
        f"단가 큐 완료: 성공 {success_count}개, 실패 {fail_count}개, 스킵(이미있음) {len(cleanup)}개"
    )
    return success_count, fail_count, len(cleanup)


def collect_prices_for_pending_unit_price_recheck(
    already_called: Optional[Set[str]] = None,
):
    """
    사용자가 단가 오류로 보고한 재료 큐(pending_unit_price_recheck_ingredients).
    기존 문서가 있어도 LLM으로 한 번 재추정 후 메인 문서 + units/{baseUnit} 동기화 저장.
    성공하거나 모델이 단가를 못 만들면 큐에서 제거. 호출 장애만 24시간 뒤 1회 재시도.
    """
    firebase_service = get_firebase_service()
    llm_service = get_llm_service()

    if not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다. 단가 재조사 큐 처리를 건너뜁니다.")
        return 0, 0, 0

    batch_size = int(os.getenv("PENDING_UNIT_PRICE_RECHECK_BATCH_SIZE", "50"))
    raw_pending = firebase_service.get_pending_unit_price_recheck_ingredients()
    if not raw_pending:
        logger.info("단가 재조사 큐: 대기 항목 없음")
        return 0, 0, 0

    unique_pending = list(dict.fromkeys(raw_pending))
    pending, skipped_cooldown, skipped_given_up = firebase_service.filter_price_names_eligible_for_retry(
        unique_pending, batch_size
    )
    if skipped_cooldown or skipped_given_up:
        logger.info(
            f"단가 재조사 큐: 백오프로 스킵 — 쿨다운 {skipped_cooldown}개, 영구포기 {skipped_given_up}개"
        )
    logger.info(f"단가 재조사 큐 처리 시작: {len(pending)}개 (배치 상한 {batch_size})")

    success_count = 0
    fail_count = 0
    to_remove: List[str] = []
    llm_calls = 0
    usage_totals = [0, 0, 0]
    called = already_called if already_called is not None else set()

    for ingredient_name in pending:
        try:
            if ingredient_name in called:
                continue
            called.add(ingredient_name)
            logger.info(f"🔁 [단가재조사] {ingredient_name}: AI 재추정 중...")
            llm_service.reset_last_usage_tokens()
            price_data = llm_service.get_ingredient_price_from_ai(ingredient_name)
            llm_calls += 1
            inp, out, think = llm_service.last_usage_tokens
            usage_totals[0] += inp
            usage_totals[1] += out
            usage_totals[2] += think
            saved = False
            if price_data and price_data.get("unitPrice") and price_data.get("baseUnit"):
                saved = bool(firebase_service.save_ingredient_price(ingredient_name, price_data))
                unit_key = firebase_service.normalize_unit_key_for_unit_prices(
                    str(price_data.get("baseUnit") or "")
                )
                if unit_key and saved:
                    firebase_service.save_ingredient_unit_price(
                        ingredient_name, unit_key, price_data
                    )
            kind = _note_price_attempt(
                firebase_service,
                ingredient_name,
                saved=saved,
                outcome=llm_service.last_price_outcome,
            )
            if kind == "success":
                success_count += 1
                to_remove.append(ingredient_name)
                logger.info(
                    f"✅ [단가재조사] {ingredient_name}: "
                    f"{price_data['unitPrice']}원/{price_data['baseUnit']} 반영"
                )
            else:
                fail_count += 1
                if kind == "permanent":
                    to_remove.append(ingredient_name)
                logger.warning(
                    f"⚠️ [단가재조사] {ingredient_name}: 단가 없음, 다시 묻지 않음"
                    if kind == "permanent"
                    else f"⚠️ [단가재조사] {ingredient_name}: 호출 실패, 24시간 뒤 1회만 재시도"
                )
        except Exception as e:
            fail_count += 1
            called.add(ingredient_name)
            _note_price_attempt(
                firebase_service, ingredient_name, saved=False, outcome="unavailable"
            )
            logger.error(f"❌ [단가재조사] {ingredient_name}: {e}", exc_info=True)

    if to_remove:
        firebase_service.remove_unit_price_recheck_names(to_remove)
        logger.info(f"단가 재조사 큐: {len(to_remove)}개 제거")

    _track_batch_llm_usage(
        "llm_ingredient_unit_price_batch", llm_service,
        calls=llm_calls, success=success_count, fail=fail_count,
        llm_input_tokens=usage_totals[0], llm_output_tokens=usage_totals[1],
        llm_thinking_tokens=usage_totals[2],
        llm_total_tokens=sum(usage_totals),
        queue="pending_unit_price_recheck_ingredients",
        skipped_cooldown=skipped_cooldown, skipped_given_up=skipped_given_up,
    )

    logger.info(
        f"단가 재조사 완료: 성공 {success_count}개, 실패 {fail_count}개"
    )
    return success_count, fail_count, 0


def collect_prices_for_pending_ingredients(
    already_called: Optional[Set[str]] = None,
):
    """
    pending_scraping_ingredients에 있는 재료들에 대해 AI로 가격 수집

    Returns:
        (success_count, fail_count, skip_count) 튜플
    """
    firebase_service = get_firebase_service()
    llm_service = get_llm_service()

    if not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다. 가격 수집을 건너뜁니다.")
        return 0, 0, 0

    # pending_scraping_ingredients 가져오기
    pending = firebase_service.get_pending_scraping_ingredients()

    if not pending:
        logger.info("가격 수집할 pending 재료가 없습니다.")
        return 0, 0, 0

    batch_size = int(os.getenv("PENDING_SCRAPING_PRICE_BATCH_SIZE", "100"))
    # 가격이 이미 있는 항목은 백오프 스캔에서 제외 (LLM 대상 아님, 스크래핑 큐 자체는 건드리지 않음)
    llm_candidates = [n for n in pending if not firebase_service.has_ingredient_price(n)]
    skip_count = len(pending) - len(llm_candidates)
    eligible, skipped_cooldown, skipped_given_up = firebase_service.filter_price_names_eligible_for_retry(
        llm_candidates, batch_size
    )
    if skipped_cooldown or skipped_given_up:
        logger.info(
            f"스크래핑pending 가격큐: 백오프로 스킵 — 쿨다운 {skipped_cooldown}개, 영구포기 {skipped_given_up}개"
        )
    logger.info(f"가격 수집 시작: {len(eligible)}개 재료 (전체 대기 {len(pending)}개, 배치 상한 {batch_size})")

    success_count = 0
    fail_count = 0
    llm_calls = 0
    usage_totals = [0, 0, 0]
    called = already_called if already_called is not None else set()

    for ingredient_name in eligible:
        try:
            if ingredient_name in called or firebase_service.has_ingredient_price(ingredient_name):
                continue
            called.add(ingredient_name)
            logger.info(f"🔍 {ingredient_name}: AI에게 가격 요청 중...")

            llm_service.reset_last_usage_tokens()
            price_data = llm_service.get_ingredient_price_from_ai(ingredient_name)
            llm_calls += 1
            inp, out, think = llm_service.last_usage_tokens
            usage_totals[0] += inp
            usage_totals[1] += out
            usage_totals[2] += think

            saved = bool(
                price_data
                and price_data.get("unitPrice")
                and price_data.get("baseUnit")
                and firebase_service.save_ingredient_price(ingredient_name, price_data)
            )
            kind = _note_price_attempt(
                firebase_service,
                ingredient_name,
                saved=saved,
                outcome=llm_service.last_price_outcome,
            )
            if kind == "success":
                success_count += 1
                logger.info(f"✅ {ingredient_name}: {price_data['unitPrice']}원/{price_data['baseUnit']} 저장 완료")
            else:
                fail_count += 1
                logger.warning(
                    f"⚠️  {ingredient_name}: 단가 없음, 다시 묻지 않음"
                    if kind == "permanent"
                    else f"⚠️  {ingredient_name}: 호출 실패, 24시간 뒤 1회만 재시도"
                )

        except Exception as e:
            fail_count += 1
            called.add(ingredient_name)
            _note_price_attempt(
                firebase_service, ingredient_name, saved=False, outcome="unavailable"
            )
            logger.error(f"❌ {ingredient_name} 가격 수집 실패: {e}", exc_info=True)

    _track_batch_llm_usage(
        "llm_ingredient_unit_price_batch", llm_service,
        calls=llm_calls, success=success_count, fail=fail_count,
        llm_input_tokens=usage_totals[0], llm_output_tokens=usage_totals[1],
        llm_thinking_tokens=usage_totals[2],
        llm_total_tokens=sum(usage_totals),
        queue="pending_scraping_ingredients",
        skipped_cooldown=skipped_cooldown, skipped_given_up=skipped_given_up,
    )

    logger.info(f"가격 수집 완료: 성공 {success_count}개, 실패 {fail_count}개, 스킵 {skip_count}개")
    return success_count, fail_count, skip_count


def run_price_collection_scheduler():
    """
    Railway에서 실행되는 가격 수집 스케줄러 (24시간 주기)
    """
    import sys
    print("[PriceCollectionScheduler] Starting ingredient price collection scheduler...", flush=True)
    print("[PriceCollectionScheduler] This will run in background thread (24h cycle)", flush=True)
    logger.info("="*60)
    logger.info("재료 가격 수집 스케줄러 시작 (24시간 주기)")
    logger.info("="*60)
    print("[PriceCollectionScheduler] Scheduler initialized", flush=True)

    # 서버가 완전히 시작될 때까지 잠시 대기
    print("[PriceCollectionScheduler] Waiting 30 seconds for server to fully start...", flush=True)
    time.sleep(30)
    print("[PriceCollectionScheduler] Starting price collection cycle...", flush=True)

    interval_hours = 24
    interval_seconds = interval_hours * 3600

    try:
        while True:
            try:
                cycle_start = datetime.now()
                logger.info(f"\n{'='*60}")
                logger.info(f"가격 수집 사이클 시작: {cycle_start.strftime('%Y-%m-%d %H:%M:%S')}")
                logger.info(f"{'='*60}")

                # 같은 사이클에서 한 재료는 LLM에 한 번만 묻는다.
                called_this_cycle: Set[str] = set()
                # 1) 사용자 단가 오류 보고 → 재조사
                rec_ok, rec_fail, _ = collect_prices_for_pending_unit_price_recheck(called_this_cycle)
                # 2) 레시피 디테일에서 보고된 미적재 단가 큐
                u_ok, u_fail, u_skip = collect_prices_for_pending_unit_price_ingredients(called_this_cycle)
                # 3) 스크래핑 pending (기존)
                success, fail, skip = collect_prices_for_pending_ingredients(called_this_cycle)

                cycle_end = datetime.now()
                elapsed = (cycle_end - cycle_start).total_seconds()
                next_run = cycle_end + timedelta(seconds=interval_seconds)

                logger.info(f"\n{'='*60}")
                logger.info(f"가격 수집 사이클 완료: {elapsed:.1f}초 소요")
                logger.info(
                    f"단가재조사: 성공 {rec_ok}, 실패 {rec_fail} | "
                    f"단가큐: 성공 {u_ok}, 실패 {u_fail}, 스킵 {u_skip} | "
                    f"스크래핑pending: 성공 {success}, 실패 {fail}, 스킵 {skip}"
                )
                logger.info(f"다음 실행 예정: {next_run.strftime('%Y-%m-%d %H:%M:%S')}")
                logger.info(f"{'='*60}\n")

                # 24시간 대기
                print(f"[PriceCollectionScheduler] Waiting {interval_hours} hours until next cycle...", flush=True)
                time.sleep(interval_seconds)

            except KeyboardInterrupt:
                logger.info("\n\n가격 수집 스케줄러를 종료합니다.")
                break
            except Exception as e:
                logger.error(f"가격 수집 스케줄러 실행 중 오류 발생: {e}", exc_info=True)
                # 오류 발생 시 1시간 후 재시도
                logger.info("1시간 후 재시도합니다...")
                time.sleep(3600)

    except Exception as e:
        logger.error(f"가격 수집 스케줄러 초기화 오류: {e}", exc_info=True)


if __name__ == "__main__":
    # 별도 실행용
    run_price_collection_scheduler()
