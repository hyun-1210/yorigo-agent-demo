"""
마켓컬리 크롤링 분산 스케줄러
48시간 주기, 20시간 크롤링 + 4시간 휴식 블록. 넓은 간격·지터·주기적 긴 휴식으로 봇 탐지 최소화.
"""
import time
import random
import sys
import os
import subprocess
from datetime import datetime, timedelta

# Ensure we can import from services and utils
current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

from services.kurly_service import scrape_single_keyword, save_products_to_firebase
from utils.kurly_utils import get_ingredients_list
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class DistributedScheduler:
    """48시간 분산 크롤링 스케줄러 (20h 크롤링 + 4h 휴식, 넓은 간격·지터·주기적 긴 휴식)"""
    
    def __init__(self, keywords: list, hours: int = 48,
                 min_interval_seconds: float = 240.0, max_interval_seconds: float = 300.0,
                 jitter_seconds: float = 30.0,
                 long_break_every_n: int = 30,
                 long_break_min_seconds: float = 180.0, long_break_max_seconds: float = 360.0):
        """
        분산 스케줄러 초기화 (봇처럼 보이지 않도록 넓은 간격 + 지터 + 주기적 긴 휴식)
        
        Args:
            keywords: 검색할 키워드 리스트
            hours: 분산할 시간 (기본 48시간)
            min_interval_seconds: 기본 최소 간격 (초) - 4분
            max_interval_seconds: 기본 최대 간격 (초) - 5분
            jitter_seconds: 매 간격에 더할 랜덤 지터 ±(초)
            long_break_every_n: 이 횟수마다 긴 휴식 추가 (예: 30)
            long_break_min_seconds: 긴 휴식 최소 (초) - 3분
            long_break_max_seconds: 긴 휴식 최대 (초) - 6분
        """
        self.keywords = keywords.copy()
        random.shuffle(self.keywords)  # 순서 랜덤화
        self.hours = hours
        self.total_keywords = len(self.keywords)
        self.completed = 0
        self.start_time = None
        
        # 넓은 랜덤 간격 (4~5분) + 지터로 실제로는 3.5~5.5분대
        self.min_interval_seconds = min_interval_seconds
        self.max_interval_seconds = max_interval_seconds
        self.avg_interval_seconds = (min_interval_seconds + max_interval_seconds) / 2
        self.jitter_seconds = jitter_seconds
        self.long_break_every_n = long_break_every_n
        self.long_break_min_seconds = long_break_min_seconds
        self.long_break_max_seconds = long_break_max_seconds
        
        # 세션 관리 변수
        self.driver = None
        self.xvfb_process = None
        self.last_login_time = None
        self.session_refresh_interval = 30 * 60  # 30분마다 세션 갱신 (초)
        self.proxy = os.getenv('KURLY_PROXY', None)
        self.headless = False
        
        # 블록 관리 변수 (20시간 크롤링 + 4시간 휴식) - 48h 주기에서 크롤링 시간 확보
        self.block_duration_hours = 20  # 각 블록 크롤링 시간
        self.rest_duration_hours = 4    # 각 블록 휴식 시간
        self.is_rest_period = False     # 휴식 기간 여부
        self.block_start_time = None    # 현재 블록 시작 시간
        
        # 랜덤 로그인 방법 선택 시스템 (하이브리드 방식)
        self.login_methods = [
            "main_page",      # 메인 페이지 → 큐레이터 버튼
            "welcome_page",   # Welcome 페이지 직접 접속
            "direct",         # 기존 로그인 URL 직접 접속
            "default"         # 기존 로직
        ]
        self.login_method_stats = {
            method: {"success": 0, "fail": 0} 
            for method in self.login_methods
        }
        self.use_weighted_random = True  # 가중치 기반 사용 여부
    
    def _get_login_method(self) -> str:
        """로그인 방법 선택 (하이브리드 방식: 완전 랜덤 + 가중치 기반)"""
        if self.use_weighted_random and any(
            stats["success"] + stats["fail"] > 0 
            for stats in self.login_method_stats.values()
        ):
            # 통계가 있으면 가중치 기반
            return self._get_weighted_random_login_method()
        else:
            # 통계가 없으면 완전 랜덤
            method = random.choice(self.login_methods)
            logger.info(f"랜덤 로그인 방법 선택: {method}")
            return method
    
    def _get_weighted_random_login_method(self) -> str:
        """가중치 기반 랜덤 선택 (성공률이 높은 방법 우선)"""
        weights = []
        methods = []
        
        for method in self.login_methods:
            stats = self.login_method_stats[method]
            total = stats["success"] + stats["fail"]
            
            if total == 0:
                weight = 1.0
            else:
                success_rate = stats["success"] / total
                # 성공률이 높을수록 가중치 증가 (최소 0.3, 최대 2.0)
                weight = 0.3 + (success_rate * 1.7)
            
            weights.append(weight)
            methods.append(method)
        
        method = random.choices(methods, weights=weights, k=1)[0]
        logger.info(f"가중치 기반 랜덤 로그인 방법 선택: {method}")
        return method
    
    def _record_login_result(self, method: str, success: bool):
        """로그인 결과 기록"""
        if success:
            self.login_method_stats[method]["success"] += 1
        else:
            self.login_method_stats[method]["fail"] += 1
        
        # 통계 로깅 (10회마다 또는 실패 시)
        stats = self.login_method_stats[method]
        total = stats["success"] + stats["fail"]
        if total > 0 and (total % 10 == 0 or not success):
            success_rate = stats["success"] / total * 100
            logger.info(f"로그인 방법 '{method}' 통계: 성공 {stats['success']}/{total} ({success_rate:.1f}%)")
    
    def _check_block_status(self):
        """블록 상태 확인 및 전환 처리 (20시간 크롤링 + 4시간 휴식, 48h 주기)"""
        if self.start_time is None:
            return
        
        elapsed_hours = (datetime.now() - self.start_time).total_seconds() / 3600
        
        # 48시간 주기 내에서의 위치 계산
        cycle_position = elapsed_hours % 48
        
        # 블록 계산 (각 블록은 24시간: 20시간 크롤링 + 4시간 휴식)
        block_position = cycle_position % 24
        
        # 크롤링 기간 (0-20시간) vs 휴식 기간 (20-24시간)
        if block_position < self.block_duration_hours:
            new_block = int(cycle_position / 24)
            is_rest = False
        else:
            new_block = int(cycle_position / 24)
            is_rest = True
        
        # 블록 전환 감지
        if is_rest != self.is_rest_period:
            old_rest = self.is_rest_period
            self.is_rest_period = is_rest
            self.block_start_time = datetime.now()
            
            if not old_rest and is_rest:
                logger.info("="*60)
                logger.info(f"휴식 기간 시작 (블록 {new_block + 1})")
                logger.info(f"{self.rest_duration_hours}시간 휴식 후 블록 {new_block + 1} 재개")
                logger.info("="*60)
                self.cleanup()
            
            if old_rest and not is_rest:
                logger.info("="*60)
                logger.info(f"크롤링 기간 시작 (블록 {new_block + 1})")
                logger.info("="*60)
    
    def _ensure_session(self):
        """세션이 유효한지 확인하고 필요시 갱신"""
        from services.kurly_service import _refresh_session_if_needed
        
        # 세션 갱신이 필요한지 확인 (30분 경과 또는 세션 만료)
        need_refresh = False
        if self.driver is None:
            need_refresh = True
            logger.info("드라이버가 없어 세션 초기화 필요")
        elif self.last_login_time is None:
            need_refresh = True
            logger.info("로그인 시간이 없어 세션 초기화 필요")
        else:
            elapsed = (datetime.now() - self.last_login_time).total_seconds()
            if elapsed >= self.session_refresh_interval:
                need_refresh = True
                logger.info(f"세션 갱신 시간 경과 ({elapsed/60:.1f}분), 주기적 갱신 수행")
        
        if need_refresh:
            logger.info("세션 갱신 시작...")
            
            # 랜덤으로 로그인 방법 선택
            login_method = self._get_login_method()
            
            self.driver, self.xvfb_process, success = _refresh_session_if_needed(
                self.driver, 
                self.proxy, 
                self.headless, 
                self.xvfb_process,
                login_method=login_method
            )
            
            # 결과 기록
            self._record_login_result(login_method, success)
            
            if success and self.driver is not None:
                self.last_login_time = datetime.now()
                logger.info("세션 갱신 완료")
            else:
                logger.error("세션 갱신 실패")
                raise Exception("세션 갱신 실패")
    
    def run_single_search(self, keyword: str):
        """재료별로 한 번에 모든 작업 완료 (상품 수집 + 링크 생성 + Firebase 저장)"""
        try:
            print(f"[KurlyScrapingScheduler] Starting search for: {keyword}", flush=True)
            logger.info(f"'{keyword}' 검색 시작 (상품 수집 + 링크 생성)...")
            
            # 세션 확인 및 갱신 (필요시)
            self._ensure_session()
            
            # 상품 수집 및 링크 생성 (한 번에 처리) - 드라이버 재사용
            products, self.driver, self.xvfb_process = scrape_single_keyword(
                keyword, 
                save_to_file=False, 
                save_to_firebase=False,  # 여기서는 저장 안 함, 아래에서 저장
                max_products=20, 
                headless=self.headless,
                driver=self.driver,  # 기존 드라이버 재사용
                xvfb_process=self.xvfb_process  # 기존 프로세스 재사용
            )
            
            self.completed += 1
            
            elapsed = (datetime.now() - self.start_time).total_seconds() / 3600
            remaining = self.total_keywords - self.completed
            estimated_hours = (remaining * self.avg_interval_seconds) / 3600
            
            print(f"[KurlyScrapingScheduler] Completed: {self.completed}/{self.total_keywords} - Found {len(products)} products", flush=True)
            logger.info(f"진행 상황 - 완료: {self.completed}/{self.total_keywords} ({self.completed/self.total_keywords*100:.1f}%)")
            logger.info(f"경과 시간: {elapsed:.1f}시간, 예상 남은 시간: {estimated_hours:.1f}시간")
            logger.info(f"수집된 상품: {len(products)}개 (링크 포함: {sum(1 for p in products if p.get('링크'))}개)")
            
            # 20개 모두 완료 후 Firebase에 한꺼번에 저장
            if products:
                try:
                    logger.info(f"'{keyword}' 상품 {len(products)}개를 Firebase에 저장 중...")
                    save_products_to_firebase(keyword, products, collection_name="kurly_products")
                    logger.info(f"'{keyword}' Firebase 저장 완료: {len(products)}개 상품")
                except Exception as e:
                    logger.error(f"'{keyword}' Firebase 저장 실패: {e}", exc_info=True)
            else:
                logger.warning(f"'{keyword}' 수집된 상품이 없습니다.")
            
        except Exception as e:
            print(f"[KurlyScrapingScheduler] ERROR: Search failed for '{keyword}': {e}", flush=True)
            logger.error(f"'{keyword}' 검색 실패: {e}", exc_info=True)
            # 에러 발생 시 세션 재초기화 시도
            try:
                self.driver = None
                self.xvfb_process = None
                self.last_login_time = None
                logger.info("에러 발생으로 인한 세션 재초기화")
            except:
                pass
            self.completed += 1
    
    def cleanup(self):
        """리소스 정리 (드라이버 및 프로세스 종료)"""
        if self.driver:
            try:
                self.driver.quit()
                logger.info("드라이버 종료 완료")
            except Exception as e:
                logger.warning(f"드라이버 종료 중 오류: {e}")
            self.driver = None
        
        if self.xvfb_process:
            try:
                self.xvfb_process.terminate()
                self.xvfb_process.wait(timeout=5)
                logger.info("Xvfb 프로세스 종료 완료")
            except subprocess.TimeoutExpired:
                try:
                    self.xvfb_process.kill()
                    logger.warning("Xvfb 프로세스 강제 종료")
                except:
                    pass
            except Exception as e:
                logger.warning(f"Xvfb 프로세스 종료 중 오류: {e}")
            self.xvfb_process = None
    
    def schedule_all(self):
        """모든 검색어를 48시간에 걸쳐 분산 스케줄링 (넓은 간격 + 지터 + 주기적 긴 휴식)"""
        self.start_time = datetime.now()
        self.block_start_time = self.start_time
        
        logger.info("="*60)
        logger.info("분산 스케줄러 시작 (마켓컬리, 48h 주기)")
        logger.info("="*60)
        logger.info(f"총 검색어: {self.total_keywords}개")
        logger.info(f"분산 시간: {self.hours}시간")
        logger.info(f"블록 구조: {self.block_duration_hours}시간 크롤링 + {self.rest_duration_hours}시간 휴식 (반복)")
        logger.info(f"간격: {self.min_interval_seconds:.0f}~{self.max_interval_seconds:.0f}초 + 지터 ±{self.jitter_seconds:.0f}초, "
                   f"매 {self.long_break_every_n}회마다 긴 휴식 +{self.long_break_min_seconds:.0f}~{self.long_break_max_seconds:.0f}초")
        logger.info(f"세션 갱신 간격: {self.session_refresh_interval/60:.1f}분")
        logger.info(f"로그인 방법: 랜덤 선택 (하이브리드 방식)")
        logger.info(f"예상 완료 시간: {self.start_time + timedelta(hours=self.hours)}")
        logger.info("="*60)
        
        current_time = self.start_time
        scheduled_tasks = []
        min_effective = 180.0  # 최소 3분은 유지 (너무 짧은 간격 방지)
        
        for i, keyword in enumerate(self.keywords):
            if i == 0:
                execute_time = current_time
                interval_seconds = 0.0
            else:
                # 기본 간격 (4~5분) + 지터 ±30초
                base = random.uniform(self.min_interval_seconds, self.max_interval_seconds)
                jitter = random.uniform(-self.jitter_seconds, self.jitter_seconds)
                interval_seconds = max(min_effective, base + jitter)
                # 매 N회마다 긴 휴식 추가 (사람 행동 모방)
                if (i + 1) % self.long_break_every_n == 0:
                    long_break = random.uniform(
                        self.long_break_min_seconds,
                        self.long_break_max_seconds
                    )
                    interval_seconds += long_break
                    logger.debug(f"  [긴 휴식 +{long_break/60:.1f}분 추가]")
                execute_time = current_time + timedelta(seconds=interval_seconds)
            
            scheduled_tasks.append((execute_time, keyword, interval_seconds))
            interval_minutes = interval_seconds / 60
            logger.info(f"[{i+1:3d}] '{keyword}' -> {execute_time.strftime('%Y-%m-%d %H:%M:%S')} "
                       f"(간격: {interval_seconds:.1f}초, {interval_minutes:.2f}분)")
            
            current_time = execute_time
        
        logger.info(f"총 {len(self.keywords)}개의 검색이 스케줄되었습니다.")
        
        return scheduled_tasks
    
    def run_scheduled_tasks(self, scheduled_tasks):
        """스케줄된 작업들을 블록별로 실행 (20시간 크롤링 + 4시간 휴식)"""
        for execute_time, keyword, interval_seconds in scheduled_tasks:
            # 블록 상태 확인
            self._check_block_status()
            
            # 휴식 기간이면 스킵
            if self.is_rest_period:
                # 다음 크롤링 기간까지 대기
                if self.block_start_time:
                    wait_until = self.block_start_time + timedelta(hours=self.rest_duration_hours)
                    wait_seconds = (wait_until - datetime.now()).total_seconds()
                    if wait_seconds > 0:
                        logger.info(f"휴식 기간 중... {wait_seconds/3600:.1f}시간 후 재개")
                        time.sleep(min(wait_seconds, 3600))  # 최대 1시간씩 체크
                        continue
                else:
                    # block_start_time이 없으면 즉시 다음 블록으로
                    self._check_block_status()
                    continue
            
            # 현재 시간이 실행 시간이 될 때까지 대기
            now = datetime.now()
            if execute_time > now:
                wait_seconds = (execute_time - now).total_seconds()
                print(f"[KurlyScrapingScheduler] Next search in {wait_seconds/60:.2f} minutes ({wait_seconds:.1f} seconds)...", flush=True)
                logger.info(f"다음 검색까지 {wait_seconds/60:.2f}분 ({wait_seconds:.1f}초) 대기...")
                time.sleep(wait_seconds)
            
            # 블록 상태 재확인 (대기 중 블록 전환 가능)
            self._check_block_status()
            
            # 휴식 기간이 아니면 검색 실행
            if not self.is_rest_period:
                self.run_single_search(keyword)


def run_scraping_scheduler():
    """백그라운드 스레드에서 실행할 스크래핑 스케줄러 함수
    48시간 주기로 자동 재실행 (스케줄 완료 후 즉시 재시작)
    """
    print("[KurlyScrapingScheduler] Starting Kurly scraping scheduler...", flush=True)
    print("[KurlyScrapingScheduler] This will run in background thread", flush=True)
    logger.info("="*60)
    logger.info("마켓컬리 크롤링 분산 스케줄러 시작")
    logger.info("="*60)
    print("[KurlyScrapingScheduler] Scheduler initialized", flush=True)
    
    # 서버가 완전히 시작될 때까지 잠시 대기 (Railway 환경 고려)
    print("[KurlyScrapingScheduler] Waiting 10 seconds for server to fully start...", flush=True)
    time.sleep(10)
    print("[KurlyScrapingScheduler] Starting scheduler cycle...", flush=True)
    
    try:
        while True:
            try:
                # 식재료 목록 가져오기
                print("[KurlyScrapingScheduler] Fetching ingredients list...")
                logger.info("식재료 목록 가져오는 중...")
                ingredients = get_ingredients_list()
                print(f"[KurlyScrapingScheduler] Found {len(ingredients)} ingredients")
                logger.info(f"총 {len(ingredients)}개 식재료 발견")
                
                # 스케줄러 초기화 (48h, 20+4 블록, 넓은 간격 + 지터 + 주기적 긴 휴식)
                print("[KurlyScrapingScheduler] Initializing scheduler (48h, human-like intervals)...")
                scheduler = DistributedScheduler(
                    ingredients,
                    hours=48,
                    min_interval_seconds=240.0,   # 4분
                    max_interval_seconds=300.0,   # 5분
                    jitter_seconds=30.0,          # ±30초 지터
                    long_break_every_n=30,        # 30회마다 긴 휴식
                    long_break_min_seconds=180.0, # 3분
                    long_break_max_seconds=360.0 # 6분
                )
                
                # 스케줄 설정
                print("[KurlyScrapingScheduler] Scheduling tasks...")
                scheduled_tasks = scheduler.schedule_all()
                
                # 스케줄된 작업들 실행 (48시간에 걸쳐 분산 실행)
                print(f"[KurlyScrapingScheduler] Starting cycle with {len(ingredients)} keywords")
                logger.info(f"\n스케줄러 사이클 시작: {len(ingredients)}개 검색어")
                scheduler.run_scheduled_tasks(scheduled_tasks)
                
                # 48h 주기 끝: Railway에서 쌓인 pending 재료를 extra에 머지 (다음 주기부터 스크래핑)
                try:
                    from services.firebase_service import get_firebase_service
                    if get_firebase_service().merge_pending_into_extra():
                        logger.info("Pending scraping ingredients merged into extra for next cycle.")
                except Exception as e:
                    logger.warning(f"Could not merge pending into extra (non-fatal): {e}")
                
                logger.info(f"\n{'='*60}")
                logger.info(f"현재 사이클 완료! 리소스 정리 중...")
                logger.info(f"{'='*60}\n")
                
                # 사이클 완료 후 리소스 정리
                try:
                    scheduler.cleanup()
                except Exception as e:
                    logger.warning(f"리소스 정리 중 오류: {e}")
                
                logger.info("다음 사이클을 즉시 시작합니다.")
                
                # 즉시 다음 사이클 시작 (추가 대기 없음)
                
            except KeyboardInterrupt:
                logger.info("\n\n스케줄러를 종료합니다.")
                break
            except Exception as e:
                logger.error(f"스케줄러 실행 중 오류 발생: {e}", exc_info=True)
                # 오류 발생 시 1시간 후 재시도
                logger.info("1시간 후 재시도합니다...")
                time.sleep(60 * 60)
                
    except Exception as e:
        logger.error(f"스크래핑 스케줄러 초기화 오류: {e}", exc_info=True)


if __name__ == "__main__":
    # 별도 실행용
    run_scraping_scheduler()


