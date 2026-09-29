"""
쿠팡 크롤링 분산 스케줄러
48시간 동안 검색어를 분산시켜 실행 (봇 탐지 최소화)
"""
import time
import random
import sys
import os
from datetime import datetime, timedelta

# Ensure we can import from services and utils
# When running in Docker/Railway, this file is at /app/coupang_scheduler.py
# and services/ and utils/ are at /app/services/ and /app/utils/
current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

from services.coupang_service import scrape_single_keyword
from utils.coupang_utils import get_ingredients_list
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class DistributedScheduler:
    """48시간 분산 크롤링 스케줄러"""
    
    def __init__(self, keywords: list, hours: int = 48, 
                 min_interval_seconds: float = 240.0, max_interval_seconds: float = 360.0):
        """
        분산 스케줄러 초기화
        
        Args:
            keywords: 검색할 키워드 리스트
            hours: 분산할 시간 (기본 48시간)
            min_interval_seconds: 최소 간격 (초) - 기본 240.0초 (4분)
            max_interval_seconds: 최대 간격 (초) - 기본 360.0초 (6분)
        """
        self.keywords = keywords.copy()
        random.shuffle(self.keywords)  # 순서 랜덤화
        self.hours = hours
        self.total_keywords = len(self.keywords)
        self.completed = 0
        self.start_time = None
        
        # 랜덤 간격 범위 (초 단위)
        self.min_interval_seconds = min_interval_seconds
        self.max_interval_seconds = max_interval_seconds
        self.avg_interval_seconds = (min_interval_seconds + max_interval_seconds) / 2
    
    def run_single_search(self, keyword: str):
        """단일 검색어 크롤링 실행"""
        try:
            import sys
            print(f"[ScrapingScheduler] Starting search for: {keyword}", flush=True)
            logger.info(f"'{keyword}' 검색 시작...")
            
            # 로컬 파일 저장 비활성화 (Firebase에만 저장)
            results = scrape_single_keyword(keyword, save_to_file=False)
            self.completed += 1
            
            elapsed = (datetime.now() - self.start_time).total_seconds() / 3600
            remaining = self.total_keywords - self.completed
            estimated_hours = (remaining * self.avg_interval_seconds) / 3600
            
            print(f"[ScrapingScheduler] Completed: {self.completed}/{self.total_keywords} - Found {len(results)} products", flush=True)
            logger.info(f"진행 상황 - 완료: {self.completed}/{self.total_keywords} ({self.completed/self.total_keywords*100:.1f}%)")
            logger.info(f"경과 시간: {elapsed:.1f}시간, 예상 남은 시간: {estimated_hours:.1f}시간")
            logger.info(f"수집된 상품: {len(results)}개")
            
        except Exception as e:
            import sys
            print(f"[ScrapingScheduler] ERROR: Search failed for '{keyword}': {e}", flush=True)
            logger.error(f"'{keyword}' 검색 실패: {e}", exc_info=True)
            self.completed += 1
    
    def schedule_all(self):
        """모든 검색어를 48시간에 걸쳐 분산 스케줄링 (랜덤 간격)"""
        self.start_time = datetime.now()
        
        logger.info("="*60)
        logger.info("분산 스케줄러 시작")
        logger.info("="*60)
        logger.info(f"총 검색어: {self.total_keywords}개")
        logger.info(f"분산 시간: {self.hours}시간")
        logger.info(f"랜덤 간격: {self.min_interval_seconds:.1f}초 ~ {self.max_interval_seconds:.1f}초 "
                   f"(평균 {self.avg_interval_seconds:.1f}초, 약 {self.min_interval_seconds/60:.1f}분 ~ {self.max_interval_seconds/60:.1f}분)")
        logger.info(f"예상 완료 시간: {self.start_time + timedelta(hours=self.hours)}")
        logger.info("="*60)
        
        current_time = self.start_time
        scheduled_tasks = []
        
        for i, keyword in enumerate(self.keywords):
            # 랜덤 간격 (240초 ~ 360초 사이, 4분 ~ 6분)
            interval_seconds = random.uniform(self.min_interval_seconds, self.max_interval_seconds)
            interval_minutes = interval_seconds / 60
            
            # 다음 실행 시간 계산
            if i == 0:
                # 첫 번째는 즉시 실행
                execute_time = current_time
            else:
                # 이전 시간 + 랜덤 간격
                execute_time = current_time + timedelta(seconds=interval_seconds)
            
            scheduled_tasks.append((execute_time, keyword, interval_seconds))
            logger.info(f"[{i+1:3d}] '{keyword}' -> {execute_time.strftime('%Y-%m-%d %H:%M:%S')} "
                       f"(간격: {interval_seconds:.1f}초, {interval_minutes:.2f}분)")
            
            current_time = execute_time
        
        logger.info(f"총 {len(self.keywords)}개의 검색이 스케줄되었습니다.")
        
        return scheduled_tasks
    
    def run_scheduled_tasks(self, scheduled_tasks):
        """스케줄된 작업들을 순차적으로 실행"""
        for execute_time, keyword, interval_seconds in scheduled_tasks:
            # 현재 시간이 실행 시간이 될 때까지 대기
            now = datetime.now()
            if execute_time > now:
                wait_seconds = (execute_time - now).total_seconds()
                import sys
                print(f"[ScrapingScheduler] Next search in {wait_seconds/60:.2f} minutes ({wait_seconds:.1f} seconds)...", flush=True)
                logger.info(f"다음 검색까지 {wait_seconds/60:.2f}분 ({wait_seconds:.1f}초) 대기...")
                time.sleep(wait_seconds)
            
            # 검색 실행
            self.run_single_search(keyword)


def run_scraping_scheduler():
    """백그라운드 스레드에서 실행할 스크래핑 스케줄러 함수
    48시간마다 자동으로 재실행 (스케줄 완료 후 즉시 재시작)
    """
    # Railway 로그에 출력되도록 print도 함께 사용
    import sys
    print("[ScrapingScheduler] Starting Coupang scraping scheduler...", flush=True)
    print("[ScrapingScheduler] This will run in background thread", flush=True)
    logger.info("="*60)
    logger.info("쿠팡 크롤링 분산 스케줄러 시작")
    logger.info("="*60)
    print("[ScrapingScheduler] Scheduler initialized", flush=True)
    
    # 서버가 완전히 시작될 때까지 잠시 대기 (Railway 환경 고려)
    print("[ScrapingScheduler] Waiting 10 seconds for server to fully start...", flush=True)
    time.sleep(10)
    print("[ScrapingScheduler] Starting scheduler cycle...", flush=True)
    
    try:
        while True:
            try:
                # Drain priority queue first (urgent items from cart misses / health checks)
                try:
                    from services.firebase_service import get_firebase_service
                    firebase = get_firebase_service()
                    priority_items = firebase.get_priority_scraping_ingredients() if firebase.is_available() else []
                    if priority_items:
                        print(f"[ScrapingScheduler] Draining {len(priority_items)} priority ingredients first...")
                        logger.info(f"Priority queue: {len(priority_items)} items to scrape first")
                        scraped_ok = []
                        for keyword in priority_items:
                            try:
                                scrape_single_keyword(keyword)
                                scraped_ok.append(keyword)
                                time.sleep(random.uniform(10, 30))
                            except Exception as e:
                                logger.warning(f"Priority scrape failed for '{keyword}': {e}")
                        if scraped_ok:
                            firebase.remove_priority_scraping_ingredients(scraped_ok)
                            logger.info(f"Priority queue: scraped {len(scraped_ok)}/{len(priority_items)} items")
                except Exception as e:
                    logger.warning(f"Priority queue drain failed (non-fatal): {e}")

                # Increment cycle counter and fetch tier-aware ingredient list
                try:
                    from services.firebase_service import get_firebase_service
                    cycle_num = get_firebase_service().increment_scraping_cycle()
                except Exception:
                    cycle_num = 0
                print(f"[ScrapingScheduler] Starting cycle #{cycle_num}")
                logger.info(f"Scraping cycle #{cycle_num}")

                try:
                    from utils.coupang_utils import get_tier_summary
                    summary = get_tier_summary()
                    if summary:
                        tiers = summary.get("tiers", {})
                        print(f"[ScrapingScheduler] Tiers: hot={tiers.get('hot',0)}, warm={tiers.get('warm',0)}, cold={tiers.get('cold',0)}")
                        print(f"[ScrapingScheduler] Cold included this cycle: {summary.get('include_cold_this_cycle')}")
                        print(f"[ScrapingScheduler] Active ingredients this cycle: {summary.get('active_this_cycle')}")
                except Exception:
                    pass

                print("[ScrapingScheduler] Fetching ingredients list...")
                logger.info("식재료 목록 가져오는 중...")
                ingredients = get_ingredients_list(cycle_number=cycle_num)
                print(f"[ScrapingScheduler] Found {len(ingredients)} ingredients")
                logger.info(f"총 {len(ingredients)}개 식재료 발견 (cycle #{cycle_num})")
                
                # 스케줄러 초기화 (48시간에 걸쳐 분산, 랜덤 간격 240초 ~ 360초, 4분 ~ 6분)
                print("[ScrapingScheduler] Initializing scheduler...")
                scheduler = DistributedScheduler(
                    ingredients, 
                    hours=48,
                    min_interval_seconds=240.0,
                    max_interval_seconds=360.0
                )
                
                # 스케줄 설정
                print("[ScrapingScheduler] Scheduling tasks...")
                scheduled_tasks = scheduler.schedule_all()
                
                # 스케줄된 작업들 실행 (48시간에 걸쳐 분산 실행)
                print(f"[ScrapingScheduler] Starting cycle with {len(ingredients)} keywords")
                logger.info(f"\n스케줄러 사이클 시작: {len(ingredients)}개 검색어")
                scheduler.run_scheduled_tasks(scheduled_tasks)
                
                logger.info(f"\n{'='*60}")
                logger.info(f"현재 사이클 완료! 다음 사이클을 즉시 시작합니다.")
                logger.info(f"{'='*60}\n")
                
            except KeyboardInterrupt:
                logger.info("\n\n스케줄러를 종료합니다.")
                break
            except Exception as e:
                logger.error(f"스케줄러 실행 중 오류 발생: {e}", exc_info=True)
                logger.info("1시간 후 재시도합니다...")
                time.sleep(60 * 60)
                
    except Exception as e:
        logger.error(f"스크래핑 스케줄러 초기화 오류: {e}", exc_info=True)


if __name__ == "__main__":
    # 별도 실행용
    run_scraping_scheduler()

