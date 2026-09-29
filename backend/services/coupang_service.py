"""
Coupang scraping service
쿠팡 크롤링 서비스

24시간 분산 실행을 위한 단일 검색어 크롤링 기능 제공
"""
from bs4 import BeautifulSoup
import time
import random
import re
from datetime import datetime, date
from typing import List, Dict, Optional, Tuple, Set
import logging
import hashlib
import hmac
import requests
import os
from services.firebase_service import get_firebase_service
from firebase_admin import firestore
from google.cloud.firestore_v1 import FieldFilter
from utils import convert_to_base_unit
from utils.deployment_env import is_production_api_host
from services.coupang_partner_urls import extract_partner_urls_from_scraped
from models import CoupangProduct
from services.product_service import SIMILAR_WORDS_MAP
from services.delivery_eta_parser import compute_delivery_eta_days
from services.chrome_driver_lock import chrome_driver_lock
from services.product_doc_cache import get_cached_firestore_doc

logger = logging.getLogger(__name__)

_EXCLUDED_PRODUCTS_CACHE: Set[str] = set()
_EXCLUDED_PRODUCTS_CACHE_AT: float = 0.0
_EXCLUDED_PRODUCTS_CACHE_TTL_SECONDS: int = int(
    os.getenv("EXCLUDED_PRODUCTS_CACHE_TTL_SECONDS", "300")
)


def get_excluded_product_ids(force_refresh: bool = False) -> Set[str]:
    """전역 제외 상품 ID 목록을 Firestore에서 조회(짧은 TTL 캐시 포함)."""
    global _EXCLUDED_PRODUCTS_CACHE, _EXCLUDED_PRODUCTS_CACHE_AT
    now = time.time()
    if (
        not force_refresh
        and _EXCLUDED_PRODUCTS_CACHE
        and now - _EXCLUDED_PRODUCTS_CACHE_AT < _EXCLUDED_PRODUCTS_CACHE_TTL_SECONDS
    ):
        return _EXCLUDED_PRODUCTS_CACHE

    excluded_ids: Set[str] = set()
    try:
        firebase_service = get_firebase_service()
        if not firebase_service.is_available() or not firebase_service.db:
            _EXCLUDED_PRODUCTS_CACHE = excluded_ids
            _EXCLUDED_PRODUCTS_CACHE_AT = now
            return excluded_ids

        docs = (
            firebase_service.db.collection("excluded_products_global")
            .where(filter=FieldFilter("active", "==", True))
            .stream()
        )
        for doc in docs:
            data = doc.to_dict() or {}
            product_id = str(data.get("productId") or doc.id).strip()
            if product_id:
                excluded_ids.add(product_id)
    except Exception as e:
        logger.warning(f"전역 제외 상품 조회 실패: {e}")

    _EXCLUDED_PRODUCTS_CACHE = excluded_ids
    _EXCLUDED_PRODUCTS_CACHE_AT = now
    return excluded_ids


def _filter_excluded_scraped_products(products: List[Dict[str, any]]) -> List[Dict[str, any]]:
    """스크래핑 원본(한글 키)에서 전역 제외 상품을 제거."""
    excluded_ids = get_excluded_product_ids()
    if not excluded_ids:
        return products

    filtered: List[Dict[str, any]] = []
    removed = 0
    for product in products:
        link = str(product.get("링크", "") or "")
        product_id = None
        hashed_id = hashlib.md5(link.encode("utf-8")).hexdigest() if link else None
        match = re.search(r"/(?:vp|np)/products/(\d+)", link)
        if match:
            product_id = match.group(1)
        if (product_id and product_id in excluded_ids) or (hashed_id and hashed_id in excluded_ids):
            removed += 1
            continue
        filtered.append(product)
    if removed > 0:
        logger.info(f"스크래핑 저장 전 전역 제외 상품 {removed}개 제거")
    return filtered


def _get_unique_display_port(offset: int = 0) -> int:
    """
    프로세스별 고유한 Xvfb 디스플레이 포트 할당
    
    Args:
        offset: 포트 오프셋 (재시도 시 사용)
    
    Returns:
        int: 디스플레이 포트 번호 (99 + PID % 100 + offset)
    """
    pid = os.getpid()
    # 99부터 시작, PID의 마지막 두 자리 사용 (0-99 범위)
    # offset을 추가하여 재시도 시 다른 포트 사용
    display_num = 99 + (pid % 100) + (offset % 10)
    return display_num


def scrape_single_keyword(
    keyword: str, 
    proxy: Optional[str] = None, 
    save_to_file: bool = False,
    save_to_firebase: bool = True,
    output_dir: str = "."
) -> List[Dict[str, any]]:
    """
    단일 검색어만 크롤링 (24시간 분산 실행용)
    
    Args:
        keyword: 검색할 식재료명
        proxy: 프록시 서버 (예: "proxy_ip:port" 또는 None)
        save_to_file: 결과를 파일에 저장할지 여부
        save_to_firebase: 결과를 Firebase에 저장할지 여부
        output_dir: 결과 파일 저장 디렉토리 (기본: 현재 디렉토리)
    
    Returns:
        list: 크롤링 결과 리스트
    """
    results = []
    driver = None
    xvfb_process = None
    
    try:
        # undetected-chromedriver: Firestore 조회 전용 경로에서는 import하지 않음 (Railway 슬림 이미지)
        import undetected_chromedriver as uc
        import sys
        import os
        import subprocess
        import signal
        
        logger.info("Chrome 드라이버 초기화 중...")
        print(f"[CoupangService] Initializing Chrome driver for keyword: {keyword}", flush=True)
        
        # 환경 변수에서 프록시 가져오기 (SmartProxy 형식 지원)
        # 형식: http://username:password@proxy.smartproxy.net:port
        env_proxy = os.getenv('COUPANG_PROXY', None)
        if env_proxy and not proxy:
            proxy = env_proxy
            logger.info(f"환경 변수에서 프록시 로드: {proxy[:20]}...")  # 보안상 일부만 표시
        
        # Xvfb (가상 디스플레이) 설정 - 프로덕션 API / Docker 환경에서 GUI 모드 사용
        # 환경 변수로 강제 사용 가능 (USE_XVFB=true)
        is_prod_api = is_production_api_host()
        is_docker = os.path.exists('/.dockerenv') or os.getenv('DOCKER_CONTAINER') == 'true'
        is_windows = sys.platform.startswith('win')
        
        # 환경 변수로 강제 사용 여부 확인
        force_xvfb = os.getenv('USE_XVFB', 'auto').lower()
        if force_xvfb == 'auto':
            use_xvfb = (is_prod_api or is_docker) and not is_windows
        else:
            use_xvfb = force_xvfb in ('true', '1', 'yes')
        
        if use_xvfb and is_windows:
            logger.warning("Windows에서는 Xvfb를 사용할 수 없습니다. WSL2나 Docker를 사용하세요.")
            print(f"[CoupangService] WARNING: Xvfb is not available on Windows. Use WSL2 or Docker.", flush=True)
            use_xvfb = False
        
        if use_xvfb:
            # 프로세스별 고유 디스플레이 포트 할당
            display_num = _get_unique_display_port()
            logger.info(f"Xvfb 가상 디스플레이 시작 중 (포트: {display_num})...")
            print(f"[CoupangService] Starting Xvfb virtual display", flush=True)
            try:
                xvfb_process = subprocess.Popen(
                    ['Xvfb', f':{display_num}', '-screen', '0', '1920x1080x24', '-ac', '+extension', 'GLX'],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
                # Xvfb 시작 확인 (0.5초 대기)
                time.sleep(0.5)
                if xvfb_process.poll() is not None:
                    # 프로세스가 즉시 종료됨 (포트 충돌 가능성)
                    logger.warning(f"Xvfb 시작 실패 (포트 {display_num} 사용 중일 수 있음), 다른 포트 시도...")
                    # 다음 포트 시도
                    display_num = _get_unique_display_port(offset=1)
                    xvfb_process = subprocess.Popen(
                        ['Xvfb', f':{display_num}', '-screen', '0', '1920x1080x24', '-ac', '+extension', 'GLX'],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE
                    )
                    time.sleep(0.5)
                    if xvfb_process.poll() is not None:
                        raise RuntimeError(f"Xvfb 시작 실패: 사용 가능한 디스플레이 포트를 찾을 수 없음")
                
                os.environ['DISPLAY'] = f':{display_num}'
                logger.info(f"Xvfb 가상 디스플레이 시작 완료 (DISPLAY=:{display_num}, PID={os.getpid()})")
                print(f"[CoupangService] Xvfb virtual display started (DISPLAY=:{display_num})", flush=True)
            except FileNotFoundError:
                logger.warning("Xvfb를 찾을 수 없습니다. headless 모드로 전환합니다.")
                print(f"[CoupangService] WARNING: Xvfb not found, falling back to headless mode", flush=True)
                use_xvfb = False
            except Exception as e:
                logger.error(f"Xvfb 시작 중 오류: {e}")
                use_xvfb = False
        
        options = uc.ChromeOptions()
        
        # Headless 모드 설정: Xvfb를 사용하면 headless=False 가능
        use_headless = os.getenv('CHROME_HEADLESS', 'auto').lower()
        if use_headless == 'auto':
            # Xvfb를 사용하면 headless 모드 불필요
            if use_xvfb:
                use_headless = False
            else:
                # 자동 감지: 프로덕션 API / Docker 환경인지 확인
                use_headless = (is_prod_api or is_docker) or (not is_windows and os.getenv('DISPLAY') is None)
        else:
            use_headless = use_headless in ('true', '1', 'yes')
        
        # 공유 메모리 부족 방지 (Docker/Railway 필수)
        options.add_argument('--disable-dev-shm-usage')  # /dev/shm 대신 /tmp 사용
        options.add_argument('--no-sandbox')  # 샌드박스 비활성화 (권한 문제 방지)
        
        # GPU 가속 비활성화 (Xvfb 환경에서 필수)
        options.add_argument('--disable-gpu')  # GPU 가속 끄기
        options.add_argument('--disable-software-rasterizer')  # 소프트웨어 래스터라이저 비활성화
        
        # WebRTC 비활성화 (실제 IP 유출 방지 - 프록시 사용 시 필수)
        options.add_argument('--disable-webrtc')  # WebRTC 비활성화
        options.add_argument('--disable-webrtc-multiple-routes-enabled')  # WebRTC 다중 경로 비활성화
        options.add_argument('--disable-webrtc-hw-decoding')  # WebRTC 하드웨어 디코딩 비활성화
        options.add_argument('--disable-webrtc-hw-encoding')  # WebRTC 하드웨어 인코딩 비활성화
        
        if use_headless:
            logger.info("Headless 모드로 실행 (GUI 없음)")
            print(f"[CoupangService] Running in headless mode", flush=True)
            options.add_argument('--headless=new')  # New headless mode (Chrome 109+)
        else:
            if use_xvfb:
                # DISPLAY 환경 변수에서 포트 가져오기
                display_env = os.environ.get('DISPLAY', ':99')
                logger.info(f"GUI 모드로 실행 (Xvfb 가상 디스플레이 사용: {display_env})")
                print(f"[CoupangService] Running in GUI mode with Xvfb virtual display", flush=True)
                # Xvfb 환경에서는 DISPLAY 설정
                options.add_argument(f'--display={display_env}')
            else:
                logger.info("GUI 모드로 실행 (크롬 창 표시)")
                print(f"[CoupangService] Running in GUI mode (Chrome window will be visible)", flush=True)
        options.add_argument('--disable-extensions')
        options.add_argument('--disable-background-networking')
        options.add_argument('--disable-background-timer-throttling')
        options.add_argument('--disable-renderer-backgrounding')
        options.add_argument('--disable-backgrounding-occluded-windows')
        options.add_argument('--disable-ipc-flooding-protection')
        options.add_argument('--window-size=1920,1080')  # Set window size for consistent rendering
        
        # 프록시 설정 (SmartProxy 형식 지원)
        # 형식 1: http://username:password@proxy.smartproxy.net:port
        # 형식 2: proxy_ip:port (기존 형식)
        proxy_username = None
        proxy_password = None
        
        if proxy:
            logger.info(f"프록시 사용: {proxy[:30]}...")  # 보안상 일부만 표시
            print(f"[CoupangService] Using proxy: {proxy.split('@')[-1] if '@' in proxy else proxy}", flush=True)
            
            # SmartProxy 형식 파싱
            if proxy.startswith('http://') or proxy.startswith('https://'):
                # http://username:password@proxy.smartproxy.net:port 형식
                from urllib.parse import urlparse
                parsed = urlparse(proxy)
                if parsed.hostname:
                    proxy_url = f"{parsed.hostname}:{parsed.port or 3120}"
                    options.add_argument(f'--proxy-server=http://{proxy_url}')
                    # 인증 정보 저장 (나중에 확장 프로그램에서 사용)
                    if parsed.username and parsed.password:
                        proxy_username = parsed.username
                        proxy_password = parsed.password
                        logger.info("프록시 인증 정보 감지됨")
                        print(f"[CoupangService] Proxy authentication detected (username: {proxy_username})", flush=True)
                else:
                    # 기존 형식: proxy_ip:port
                    options.add_argument(f'--proxy-server=http://{proxy}')
            else:
                # 기존 형식: proxy_ip:port
                options.add_argument(f'--proxy-server=http://{proxy}')
        
        # 프록시 인증이 필요한 경우, Chrome 확장 프로그램으로 처리
        # Chrome은 프록시 인증을 직접 지원하지 않으므로 확장 프로그램 필요
        proxy_ext_dir = None
        if proxy_username and proxy_password:
            try:
                import json
                import shutil
                
                # 영구 디렉토리에 확장 프로그램 생성 (/app/proxy_auth_ext)
                proxy_ext_dir = "/app/proxy_auth_ext"
                os.makedirs(proxy_ext_dir, exist_ok=True)
                
                # 프록시 인증 확장 프로그램 생성
                manifest = {
                    "version": "1.0.0",
                    "manifest_version": 2,
                    "name": "Proxy Auth",
                    "permissions": ["webRequest", "webRequestBlocking", "<all_urls>"],
                    "background": {
                        "scripts": ["background.js"]
                    }
                }
                
                background_js = f"""
                chrome.webRequest.onAuthRequired.addListener(
                    function(details) {{
                        return {{
                            authCredentials: {{
                                username: "{proxy_username}",
                                password: "{proxy_password}"
                            }}
                        }};
                    }},
                    {{urls: ["<all_urls>"]}},
                    ["blocking"]
                );
                """
                
                # manifest.json 작성
                with open(os.path.join(proxy_ext_dir, "manifest.json"), "w") as f:
                    json.dump(manifest, f, indent=2)
                
                # background.js 작성
                with open(os.path.join(proxy_ext_dir, "background.js"), "w") as f:
                    f.write(background_js)
                
                # 확장 프로그램 로드
                options.add_argument(f'--load-extension={proxy_ext_dir}')
                logger.info("프록시 인증 확장 프로그램 로드됨")
                print(f"[CoupangService] Proxy authentication extension loaded", flush=True)
            except Exception as e:
                logger.warning(f"프록시 인증 확장 프로그램 생성 실패: {e}")
                print(f"[CoupangService] WARNING: Failed to create proxy auth extension: {e}", flush=True)
                proxy_ext_dir = None
        
        try:
            # Chrome 드라이버 초기화 시 파일 기반 락 사용 (프로세스 간 동기화)
            with chrome_driver_lock(timeout=300.0, retry_interval=1.0):
                # Chrome 드라이버 디렉토리 존재 확인 및 생성
                chrome_driver_dir = os.path.expanduser("~/.local/share/undetected_chromedriver")
                os.makedirs(chrome_driver_dir, exist_ok=True)
                
                driver = uc.Chrome(options=options, version_main=144, use_subprocess=True)
            logger.info("Chrome 드라이버 초기화 완료")
            print(f"[CoupangService] Chrome driver initialized successfully", flush=True)
        except Exception as chrome_error:
            logger.error(f"Chrome 드라이버 초기화 실패: {chrome_error}", exc_info=True)
            print(f"[CoupangService] ERROR: Chrome driver initialization failed: {chrome_error}", flush=True)
            raise
        
        # webdriver 속성 숨기기
        driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
        
        # 먼저 메인 페이지로 이동하여 쿠키 받기
        driver.get("https://www.coupang.com/")
        time.sleep(random.uniform(3, 5))
        
        # 검색 URL 구성
        search_url = f"https://www.coupang.com/np/search?component=&q={keyword}&channel=user"
        
        logger.info(f"'{keyword}' 검색 시작...")
        driver.get(search_url)
        
        # 페이지 로딩 대기
        time.sleep(random.uniform(6, 10))
        
        # Access Denied 체크
        page_title = driver.title.lower()
        if "access denied" in page_title or "access denied" in driver.page_source.lower()[:500]:
            logger.warning("Access Denied 감지! 재시도...")
            time.sleep(random.uniform(10, 15))
            driver.get(search_url)
            time.sleep(random.uniform(6, 10))
        
        # 스크롤 다운 (자연스러운 사용자 행동 모방)
        scroll_pause = random.uniform(1, 2)
        driver.execute_script("window.scrollTo(0, document.body.scrollHeight/3);")
        time.sleep(scroll_pause)
        driver.execute_script("window.scrollTo(0, document.body.scrollHeight/2);")
        time.sleep(scroll_pause)
        driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
        time.sleep(scroll_pause)
        
        # 페이지 소스 파싱
        page_source = driver.page_source
        soup = BeautifulSoup(page_source, 'html.parser')
        
        # 상품 리스트 찾기
        items = soup.select('li[class*="ProductUnit"]')
        if not items:
            items = soup.select('li.search-product')
        if not items:
            items = soup.select('ul.search-product-list li')
        
        logger.info(f"{len(items)}개의 상품 발견")
        
        for item in items:
            try:
                # 상품명
                name_tag = item.select_one('[class*="ProductUnit_productNameV2"]')
                if not name_tag:
                    name_tag = item.select_one('div.name')
                name = name_tag.text.strip() if name_tag else "이름 없음"
                
                # 가격
                price_tag = item.select_one('[class*="PriceArea_priceArea"]')
                if not price_tag:
                    price_tag = item.select_one('strong.price-value')
                
                # 가격 파싱: HTML 구조 기반 파싱
                original_price = None
                discount_rate = None
                price = "0"
                
                if price_tag:
                    logger.debug(f"[Price Parse] Raw price HTML: {price_tag}")
                    
                    # 1. 원가 추출: <del> 태그에서
                    del_tag = price_tag.select_one('del')
                    if del_tag:
                        original_price_text = del_tag.get_text(strip=True)
                        # 쉼표 제거 후 숫자만 추출
                        original_price_match = re.search(r'(\d+(?:,\d+)*)', original_price_text.replace(',', ''))
                        if original_price_match:
                            try:
                                original_price = int(original_price_match.group(1))
                            except (ValueError, TypeError):
                                original_price = None
                    
                    # 2. 할인율 추출: % 기호가 포함된 요소에서
                    # 모든 요소를 순회하며 % 기호가 포함된 텍스트 찾기
                    all_elements = price_tag.find_all(['div', 'span', 'p', 'strong'])
                    for elem in all_elements:
                        elem_text = elem.get_text(strip=True)
                        if '%' in elem_text:
                            # 숫자와 % 기호 추출 (예: "22%", "9%")
                            discount_match = re.search(r'(\d+)\s*%', elem_text)
                            if discount_match:
                                try:
                                    discount_rate = float(discount_match.group(1))
                                    break
                                except (ValueError, TypeError):
                                    continue
                    
                    # 할인율을 찾지 못한 경우, 전체 텍스트에서도 시도
                    if discount_rate is None:
                        price_text = price_tag.get_text()
                        discount_match = re.search(r'(\d+)\s*%', price_text)
                        if discount_match:
                            try:
                                discount_rate = float(discount_match.group(1))
                            except (ValueError, TypeError):
                                discount_rate = None
                    
                    # 3. 현재가 추출: 가장 큰 숫자 또는 특정 클래스에서
                    # 방법 1: <del> 태그가 아닌 요소에서 큰 숫자 찾기
                    price_candidates = []
                    for elem in price_tag.find_all(['div', 'span', 'p', 'strong']):
                        # <del> 태그는 제외
                        if elem.name == 'del' or elem.find('del'):
                            continue
                        elem_text = elem.get_text(strip=True)
                        # 숫자 패턴 찾기 (쉼표 포함)
                        price_matches = re.findall(r'(\d+(?:,\d+)*)', elem_text.replace(',', ''))
                        for match in price_matches:
                            try:
                                price_int = int(match)
                                # 너무 작은 숫자는 제외 (할인율 등)
                                if price_int >= 100:  # 최소 100원 이상
                                    price_candidates.append(price_int)
                            except (ValueError, TypeError):
                                continue
                    
                    # 가장 큰 숫자를 현재가로 선택 (원가보다 작아야 함)
                    if price_candidates:
                        price_candidates.sort(reverse=True)
                        for candidate in price_candidates:
                            # 원가가 있으면 원가보다 작아야 함
                            if original_price:
                                if candidate < original_price:
                                    price = str(candidate)
                                    break
                            else:
                                # 원가가 없으면 가장 큰 숫자 사용
                                price = str(candidate)
                                break
                    
                    # 방법 2: price_candidates가 비어있으면 전체 텍스트에서 추출
                    if price == "0":
                        price_text = price_tag.get_text(strip=True)
                        # <del> 태그의 텍스트는 제외하기 위해 원가 텍스트 제거
                        if del_tag:
                            original_price_text = del_tag.get_text(strip=True)
                            price_text = price_text.replace(original_price_text, '', 1)
                        
                        # 할인율 텍스트도 제거
                        if discount_rate is not None:
                            price_text = re.sub(r'\d+\s*%', '', price_text)
                        
                        # 숫자 추출 (쉼표 제거 후)
                        price_matches = re.findall(r'(\d+(?:,\d+)*)', price_text.replace(',', ''))
                        if price_matches:
                            try:
                                price_ints = [int(m) for m in price_matches if int(m) >= 100]
                                if price_ints:
                                    # 원가가 있으면 원가보다 작은 값 선택
                                    if original_price:
                                        valid_prices = [p for p in price_ints if p < original_price]
                                        if valid_prices:
                                            price = str(max(valid_prices))
                                        else:
                                            price = str(max(price_ints))
                                    else:
                                        price = str(max(price_ints))
                            except (ValueError, TypeError):
                                pass
                    
                    # 검증: 원가와 현재가가 있으면 할인율 계산 검증
                    if original_price and price != "0":
                        try:
                            current_price_int = int(price)
                            calculated_discount = ((original_price - current_price_int) / original_price) * 100
                            # 계산된 할인율과 파싱된 할인율이 비슷한지 확인 (오차 2% 이내)
                            if discount_rate is not None:
                                if abs(calculated_discount - discount_rate) > 2:
                                    logger.warning(f"[Price Parse] Discount rate mismatch: parsed={discount_rate}, calculated={calculated_discount:.1f}")
                            else:
                                # 할인율이 파싱되지 않았으면 계산된 값 사용
                                discount_rate = round(calculated_discount, 1)
                        except (ValueError, TypeError):
                            pass
                    
                    logger.debug(f"[Price Parse] Parsed - price: {price}, originalPrice: {original_price}, discountRate: {discount_rate}")
                
                # 링크
                link_tag = item.select_one('a')
                link = "https://www.coupang.com" + link_tag['href'] if link_tag and link_tag.get('href') else ""
                
                # 이미지
                img_tag = item.select_one('img')
                img_url = ""
                if img_tag:
                    if img_tag.get('data-img-src'):
                        img_url = img_tag.get('data-img-src')
                    else:
                        img_url = img_tag.get('src')
                    if img_url and img_url.startswith('//'):
                        img_url = "https:" + img_url
                
                # 별점 및 리뷰 수
                rating = "0.0"
                reviews = "0"
                rating_area = item.select_one('[class*="ProductRating_productRating"]')
                if rating_area:
                    star_div = rating_area.select_one('div[aria-label]')
                    if star_div:
                        rating = star_div.get('aria-label', '').replace('점', '').strip()
                    review_span = rating_area.select_one('span[class*="fw-text"]')
                    if review_span:
                        reviews = review_span.text.strip().replace('(', '').replace(')', '').replace(',', '')
                else:
                    rating_tag = item.select_one('em.rating')
                    if rating_tag: 
                        rating = rating_tag.text.strip()
                    review_tag = item.select_one('span.rating-total-count')
                    if review_tag: 
                        reviews = review_tag.text.strip().replace('(', '').replace(')', '').replace(',', '')
                
                # 순위 (Rank)
                rank = None
                rank_span = item.select_one('span[class*="RankMark_rank"]')
                if rank_span:
                    rank_text = rank_span.text.strip()
                    if rank_text.isdigit():
                        rank = int(rank_text)
                # 대체 방법: 다른 클래스명으로도 시도
                if rank is None:
                    rank_elements = item.select('span[class*="rank"]')
                    for elem in rank_elements:
                        rank_text = elem.text.strip()
                        if rank_text.isdigit():
                            rank = int(rank_text)
                            break
                
                # 로켓프레시 여부
                is_rocket_fresh = False
                rocket_badge = item.select_one('img[data-badge-id="ROCKET_FRESH"]')
                if rocket_badge:
                    is_rocket_fresh = True
                # 대체 방법: data-testid로 확인
                if not is_rocket_fresh:
                    badge_container = item.select_one('div[data-testid="wp-ui-biz-badge"]')
                    if badge_container:
                        rocket_img = badge_container.select_one('img[data-badge-id="ROCKET_FRESH"]')
                        if rocket_img:
                            is_rocket_fresh = True
                
                # 도착 시간 정보
                arrival_info = ""
                delivery_div = item.select_one('div.fw-leading-\\[15px\\]')
                if not delivery_div:
                    # 대체 방법: 색상이 #008000인 span 찾기
                    green_spans = item.select('span[style*="#008000"]')
                    if green_spans:
                        delivery_texts = [span.text.strip() for span in green_spans if span.text.strip()]
                        if delivery_texts:
                            arrival_info = " ".join(delivery_texts).replace("== $0", "").strip()
                else:
                    # div 내부의 모든 텍스트 추출
                    delivery_text = delivery_div.get_text(separator=" ", strip=True)
                    if delivery_text:
                        arrival_info = delivery_text.replace("== $0", "").strip()
                
                # 추가 방법: "도착" 또는 "배송" 키워드가 포함된 텍스트 찾기
                if not arrival_info:
                    all_text = item.get_text(separator=" ", strip=True)
                    # "내일", "모레", "도착", "배송" 등의 키워드가 포함된 부분 찾기
                    arrival_pattern = r'(내일|모레|오늘|다음주)?\s*\(?[월화수목금토일]?\)?\s*(새벽|오전|오후|낮|저녁)?\s*(도착|배송)?\s*(보장)?'
                    match = re.search(arrival_pattern, all_text)
                    if match:
                        arrival_info = match.group(0).strip()
                
                # 무료배송 여부
                is_free_shipping = False
                free_shipping_spans = item.select('span')
                for span in free_shipping_spans:
                    span_text = span.text.strip()
                    if '무료배송' in span_text:
                        is_free_shipping = True
                        break
                
                # 대체 방법: 특정 스타일을 가진 span에서 찾기 (color: #454F5B)
                if not is_free_shipping:
                    styled_spans = item.select('span[style*="#454F5B"]')
                    for span in styled_spans:
                        if '무료배송' in span.text:
                            is_free_shipping = True
                            break
                
                # 추가 방법: 전체 텍스트에서 "무료배송" 키워드 확인
                if not is_free_shipping:
                    all_text = item.get_text(separator=" ", strip=True)
                    if '무료배송' in all_text:
                        is_free_shipping = True
                
                # 단위 가격
                unit_price = ""
                if price_tag:
                    unit_spans = price_tag.select('span')
                    for span in unit_spans:
                        span_text = span.text.strip()
                        if 'g당' in span_text or 'kg당' in span_text:
                            match = re.search(r'(\d+(?:,\d+)*)\s*원', span_text)
                            if match:
                                unit_price = match.group(1).replace(',', '')
                            else:
                                num_match = re.search(r'(\d+(?:,\d+)*)', span_text)
                                if num_match:
                                    unit_price = num_match.group(1).replace(',', '')
                            break
                    if not unit_price:
                        price_text = price_tag.get_text()
                        match = re.search(r'(\d+(?:,\d+)*)\s*(?:g|kg)당\s*(\d+(?:,\d+)*)\s*원', price_text)
                        if match:
                            unit_price = match.group(2).replace(',', '')
                
                results.append({
                    '검색어': keyword,
                    '상품명': name,
                    '가격': price,
                    '원가': original_price,
                    '할인율': discount_rate,
                    '단위가격': unit_price,
                    '별점': rating,
                    '리뷰수': reviews,
                    '순위': rank,
                    '로켓프레시': is_rocket_fresh,
                    '무료배송': is_free_shipping,
                    '도착정보': arrival_info,
                    '링크': link,
                    '이미지': img_url,
                    '수집시간': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                })
            except Exception as e:
                logger.warning(f"상품 파싱 중 오류: {e}")
                continue
        
        # 결과 저장 (선택사항)
        if save_to_file and results:
            date_str = datetime.now().strftime('%Y%m%d')
            file_name = f"{output_dir}/coupang_results_{date_str}.xlsx"
            
            try:
                import pandas as pd
                # 기존 파일이 있으면 읽어서 추가
                existing_df = pd.read_excel(file_name)
                new_df = pd.DataFrame(results)
                combined_df = pd.concat([existing_df, new_df], ignore_index=True)
                combined_df.to_excel(file_name, index=False)
                logger.info(f"결과 저장: {file_name} (기존 데이터에 추가)")
            except FileNotFoundError:
                # 새 파일 생성
                df = pd.DataFrame(results)
                df.to_excel(file_name, index=False)
                logger.info(f"결과 저장: {file_name} (새 파일 생성)")
        
        # 스크래핑 완료 후 크롬 드라이버 먼저 종료
        logger.info("스크래핑 완료, 크롬 드라이버 종료 중...")
        if driver:
            try:
                driver.quit()
                driver = None  # None으로 설정하여 finally에서 중복 종료 방지
                logger.info("크롬 드라이버 종료 완료")
                print(f"[CoupangService] Chrome driver terminated", flush=True)
            except Exception as e:
                logger.warning(f"크롬 드라이버 종료 중 오류: {e}")
        
        # Xvfb 프로세스 종료
        if xvfb_process:
            try:
                xvfb_process.terminate()
                xvfb_process.wait(timeout=5)
                xvfb_process = None  # None으로 설정하여 finally에서 중복 종료 방지
                logger.info("Xvfb 프로세스 종료 완료")
                print(f"[CoupangService] Xvfb process terminated", flush=True)
            except subprocess.TimeoutExpired:
                if xvfb_process:
                    xvfb_process.kill()
                    xvfb_process = None
                logger.warning("Xvfb 프로세스 강제 종료")
            except Exception as e:
                logger.warning(f"Xvfb 프로세스 종료 중 에러: {e}")
        
        # 크롬 드라이버 종료 후 딥링크 변환 진행
        if save_to_firebase and results:
            try:
                # 딥링크 변환 (10초 간격)
                access_key = os.getenv("COUPANG_ACCESS_KEY", "")
                secret_key = os.getenv("COUPANG_SECRET_KEY", "")
                sub_id = os.getenv("COUPANG_PARTNER_SUBID", "YorigoMobile")
                
                if access_key and secret_key:
                    logger.info(f"딥링크 변환 시작: {len(results)}개 상품 (크롬 드라이버 종료 후)")
                    results = convert_all_products_to_deeplinks(results, access_key, secret_key, sub_id)
                    logger.info(f"딥링크 변환 완료")
                else:
                    logger.warning("쿠팡 API 키가 설정되지 않아 딥링크 변환을 건너뜁니다.")
                
                save_products_to_firebase(keyword, results)
            except Exception as e:
                logger.warning(f"Firebase 저장 실패: {e}")
        
        return results
        
    except Exception as e:
        logger.error(f"'{keyword}' 크롤링 중 에러: {e}")
        return []
    finally:
        # 이미 종료된 경우는 건너뛰기 (driver가 None이면 이미 종료됨)
        if driver:
            try:
                driver.quit()
                logger.info("크롬 드라이버 종료 (finally 블록)")
            except:
                pass
        # Xvfb 프로세스 종료 (이미 종료된 경우는 건너뛰기)
        if xvfb_process:
            try:
                xvfb_process.terminate()
                xvfb_process.wait(timeout=5)
                logger.info("Xvfb 프로세스 종료 완료 (finally 블록)")
                print(f"[CoupangService] Xvfb process terminated", flush=True)
            except subprocess.TimeoutExpired:
                if xvfb_process:
                    xvfb_process.kill()
                logger.warning("Xvfb 프로세스 강제 종료 (finally 블록)")
            except Exception as e:
                logger.warning(f"Xvfb 프로세스 종료 중 에러: {e}")


def generate_coupang_hmac(method: str, url: str, secret_key: str, access_key: str) -> str:
    """
    쿠팡 API HMAC 인증 생성
    
    Args:
        method: HTTP 메서드 (GET, POST 등)
        url: API URL
        secret_key: 쿠팡 시크릿 키
        access_key: 쿠팡 액세스 키
    
    Returns:
        HMAC 인증 헤더 값
    """
    # Remove domain to get path and query string
    if url.startswith("https://api-gateway.coupang.com"):
        path_with_query = url.replace("https://api-gateway.coupang.com", "")
    else:
        path_with_query = url
    
    # Split path and query string
    path, *query = path_with_query.split("?")
    query_string = query[0] if query else ""
    
    # Generate datetime in format: yymmddTHHMMSSZ
    os_time = time.gmtime()
    datetime_gmt = time.strftime('%y%m%d', os_time) + 'T' + time.strftime('%H%M%S', os_time) + 'Z'
    
    # Create message: datetime + method + path + query_string
    message = datetime_gmt + method + path + (query_string if query_string else "")
    
    # Generate HMAC signature
    signature = hmac.new(
        bytes(secret_key, "utf-8"),
        message.encode("utf-8"),
        hashlib.sha256
    ).hexdigest()
    
    return f"CEA algorithm=HmacSHA256, access-key={access_key}, signed-date={datetime_gmt}, signature={signature}"


def convert_url_to_partner_links(
    original_url: str,
    access_key: str,
    secret_key: str,
    sub_id: str = "YorigoMobile",
) -> Dict[str, str]:
    """파트너스 딥링크 API에서 단축 URL과 AFFSDP 랜딩을 같이 받는다.

    Returns:
        {"shorten_url": str, "landing_url": str}. 실패 시 shorten은 원본, landing은 빈 문자열.
    """
    empty = {"shorten_url": original_url or "", "landing_url": ""}
    if not original_url or not original_url.startswith("http"):
        logger.warning(f"유효하지 않은 URL: {original_url}")
        return empty

    if not access_key or not secret_key:
        logger.warning("쿠팡 API 키가 설정되지 않았습니다. 원본 URL 반환")
        return empty

    try:
        normalized_url = original_url.strip()
        if "coupang.com" not in normalized_url.lower():
            logger.warning(f"쿠팡 URL이 아닙니다: {normalized_url[:50]}...")
            return empty

        original_with_query = normalized_url
        if "?" in normalized_url:
            from urllib.parse import urlparse, urlunparse

            parsed = urlparse(normalized_url)
            if "/vp/products/" in parsed.path or "/np/products/" in parsed.path:
                normalized_url = urlunparse(
                    (
                        parsed.scheme,
                        parsed.netloc,
                        parsed.path,
                        "",
                        "",
                        "",
                    )
                )
                if normalized_url != original_with_query:
                    logger.info("URL 정규화: 쿼리 파라미터 제거")
                    logger.debug(f"  원본: {original_with_query[:80]}...")
                    logger.debug(f"  정규화: {normalized_url}")

        api_url = (
            "https://api-gateway.coupang.com/v2/providers/affiliate_open_api"
            "/apis/openapi/v1/deeplink"
        )
        authorization = generate_coupang_hmac("POST", api_url, secret_key, access_key)
        payload = {"coupangUrls": [normalized_url], "subId": sub_id}
        headers = {
            "Authorization": authorization,
            "Content-Type": "application/json",
        }
        response = requests.post(api_url, json=payload, headers=headers, timeout=30)

        if response.status_code == 200:
            data = response.json()
            r_code = data.get("rCode")
            r_message = data.get("rMessage", "")
            if r_code == "0" and data.get("data"):
                deeplink_data = data["data"][0]
                shorten_url = (deeplink_data.get("shortenUrl") or "").strip()
                landing_url = (deeplink_data.get("landingUrl") or "").strip()
                if shorten_url or landing_url:
                    logger.debug(
                        "딥링크 변환 성공: %s... -> short=%s landing=%s",
                        normalized_url[:50],
                        bool(shorten_url),
                        bool(landing_url),
                    )
                    return {
                        "shorten_url": shorten_url or landing_url,
                        "landing_url": landing_url,
                    }
                logger.warning("딥링크 변환 응답에 URL이 없음")
            else:
                logger.warning(
                    f"딥링크 변환 실패: rCode={r_code}, rMessage={r_message}"
                )
        elif response.status_code == 429:
            logger.warning("딥링크 변환 Rate Limit (429)")
        else:
            logger.warning(f"딥링크 변환 API 오류: {response.status_code}")

    except requests.exceptions.Timeout:
        logger.warning("딥링크 변환 타임아웃 (재시도 없음)")
    except requests.exceptions.RequestException as e:
        logger.warning(f"딥링크 변환 네트워크 오류: {str(e)[:100]}... (재시도 없음)")
    except Exception as e:
        logger.warning(f"딥링크 변환 중 예외 발생: {e} (재시도 없음)")

    return empty


def convert_single_url_to_deeplink(
    original_url: str,
    access_key: str,
    secret_key: str,
    sub_id: str = "YorigoMobile"
) -> str:
    """
    단일 쿠팡 URL을 딥링크로 변환
    
    Args:
        original_url: 원본 쿠팡 URL
        access_key: 쿠팡 액세스 키
        secret_key: 쿠팡 시크릿 키
        sub_id: 서브 ID
    
    Returns:
        딥링크 URL (실패 시 원본 URL)
    """
    links = convert_url_to_partner_links(
        original_url, access_key, secret_key, sub_id
    )
    return links.get("shorten_url") or original_url


def convert_all_products_to_deeplinks(
    products: List[Dict[str, any]],
    access_key: str,
    secret_key: str,
    sub_id: str = "YorigoMobile"
) -> List[Dict[str, any]]:
    """
    모든 상품의 링크를 딥링크로 변환 (10초 간격)
    
    Args:
        products: 스크래핑된 상품 리스트
        access_key: 쿠팡 액세스 키
        secret_key: 쿠팡 시크릿 키
        sub_id: 서브 ID
    
    Returns:
        딥링크 변환된 상품 리스트
    """
    if not products:
        return products
    
    total_count = len(products)
    logger.info(f"딥링크 변환 시작: {total_count}개 상품")
    
    converted_count = 0
    failed_count = 0
    
    for idx, product in enumerate(products):
        # 첫 번째 상품 제외하고 10초 대기
        if idx > 0:
            time.sleep(10)
        
        original_url = product.get('링크', '')
        if not original_url:
            logger.debug(f"상품 {idx + 1}/{total_count}: 링크가 없어 건너뜀")
            product['deeplinkUrl'] = ''
            continue
        
        links = convert_url_to_partner_links(
            original_url, access_key, secret_key, sub_id
        )
        deeplink_url = links.get("shorten_url") or original_url
        product['deeplinkUrl'] = deeplink_url
        product['landingUrl'] = links.get("landing_url") or ""
        
        # 변환 성공 여부 확인 (원본 URL과 다르면 성공)
        if deeplink_url != original_url:
            converted_count += 1
            logger.debug(f"상품 {idx + 1}/{total_count}: 딥링크 변환 성공")
        else:
            failed_count += 1
            logger.debug(f"상품 {idx + 1}/{total_count}: 딥링크 변환 실패 (원본 URL 유지)")
        
        # 진행 상황 로깅 (10개마다)
        if (idx + 1) % 10 == 0 or (idx + 1) == total_count:
            progress = ((idx + 1) / total_count) * 100
            logger.debug(f"딥링크 변환 진행 중: {idx + 1}/{total_count} ({progress:.1f}%)")
    
    logger.info(f"딥링크 변환 완료: {total_count}개 상품 (성공: {converted_count}, 실패: {failed_count})")
    
    return products


def save_products_to_firebase(keyword: str, products: List[Dict[str, any]], collection_name: str = "coupang_products"):
    """
    쿠팡 크롤링 결과를 Firebase에 저장 (검색어별 하나의 문서, 덮어쓰기)
    
    Args:
        keyword: 검색어 (문서 ID로 사용)
        products: 크롤링된 상품 리스트
        collection_name: Firebase 컬렉션 이름
    """
    firebase_service = get_firebase_service()
    
    if not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다. 저장을 건너뜁니다.")
        return
    
    try:
        products = _filter_excluded_scraped_products(products)
        db = firebase_service.db
        if not db:
            logger.warning("Firestore 클라이언트가 없습니다.")
            return
        
        # 상품 데이터 변환
        products_data = []
        for product in products:
            try:
                # Firebase 문서 데이터 준비
                rank_value = product.get('순위')
                if rank_value is not None:
                    try:
                        rank_value = int(rank_value)
                    except (ValueError, TypeError):
                        rank_value = None
                
                # 로켓프레시 여부
                is_rocket_fresh = product.get('로켓프레시', False)
                if isinstance(is_rocket_fresh, str):
                    is_rocket_fresh = is_rocket_fresh.lower() in ('true', '1', 'yes')
                
                # 무료배송 여부
                is_free_shipping = product.get('무료배송', False)
                if isinstance(is_free_shipping, str):
                    is_free_shipping = is_free_shipping.lower() in ('true', '1', 'yes')
                
                # 가격 정보는 이미 scrape_single_keyword에서 파싱되었으므로 그대로 사용
                original_price = product.get('원가')
                discount_rate = product.get('할인율')
                price_value = product.get('가격', 0)
                unit_price_value = product.get('단위가격', '')
                
                # 타입 변환 (이미 파싱된 값이지만 안전성을 위해)
                try:
                    if isinstance(price_value, str):
                        price_value = int(price_value) if price_value.isdigit() else 0
                    elif not isinstance(price_value, int):
                        price_value = int(price_value) if price_value else 0
                except (ValueError, TypeError):
                    price_value = 0
                
                try:
                    if isinstance(unit_price_value, str):
                        unit_price_value = int(unit_price_value) if unit_price_value.isdigit() else None
                    elif isinstance(unit_price_value, (int, float)):
                        unit_price_value = int(unit_price_value) if unit_price_value > 0 else None
                    else:
                        unit_price_value = None
                except (ValueError, TypeError):
                    unit_price_value = None
                
                logger.debug(f"[Save Products] Product: {product.get('상품명', '')[:50]}")
                logger.debug(f"[Save Products] price: {price_value}, originalPrice: {original_price}, discountRate: {discount_rate}, unitPrice: {unit_price_value}")
                
                # 딥링크 URL 가져오기 (있으면 사용, 없으면 원본 링크)
                deeplink_url = product.get('deeplinkUrl', '')
                if not deeplink_url:
                    deeplink_url = product.get('링크', '')
                
                # 딥링크 변환 시각 (deeplinkUrl이 원본과 다르면 변환 성공)
                # 주의: firestore.SERVER_TIMESTAMP는 배열 안의 객체에는 사용할 수 없으므로 실제 타임스탬프 사용
                deeplink_converted_at = None
                original_link = product.get('링크', '')
                if deeplink_url and deeplink_url != original_link:
                    # 딥링크 변환 성공 시 현재 시간 저장
                    deeplink_converted_at = datetime.now()
                
                product_data = {
                    'productName': product.get('상품명', ''),
                    'price': price_value,
                    'originalPrice': original_price,
                    'discountRate': discount_rate,
                    'unitPrice': unit_price_value,
                    'rating': float(product.get('별점', 0)) if str(product.get('별점', '0')).replace('.', '').isdigit() else 0.0,
                    'reviews': int(product.get('리뷰수', 0)) if str(product.get('리뷰수', '0')).isdigit() else 0,
                    'rank': rank_value,
                    'isRocketFresh': bool(is_rocket_fresh),
                    'isFreeShipping': bool(is_free_shipping),
                    'arrivalInfo': product.get('도착정보', ''),
                    'link': original_link,
                    'deeplinkUrl': deeplink_url,
                    'landingUrl': product.get('landingUrl', ''),
                    'deeplinkConvertedAt': deeplink_converted_at,
                    'imageUrl': product.get('이미지', ''),
                }
                products_data.append(product_data)
            except Exception as e:
                logger.warning(f"상품 변환 중 오류 (상품명: {product.get('상품명', 'unknown')}): {e}")
                continue
        
        # 문서 ID는 검색어 이름 사용
        doc_ref = db.collection(collection_name).document(keyword)
        
        # 기존 문서 여부와 관계없이 완전히 덮어쓰기
        doc_ref.set({
            'keyword': keyword,
            'products': products_data,
            'scrapedAt': firestore.SERVER_TIMESTAMP,
            'lastUpdated': firestore.SERVER_TIMESTAMP,
            'productCount': len(products_data)
        }, merge=False)  # merge=False로 완전히 덮어쓰기
        
        logger.debug(f"'{keyword}' 스크래핑 결과 저장 완료: {len(products_data)}개 상품 (덮어쓰기)")
        
        # 검색어별 요약 정보도 저장
        try:
            summary_ref = db.collection("coupang_scraping_summary").document(keyword)
            summary_ref.set({
                'keyword': keyword,
                'productCount': len(products_data),
                'scrapedAt': firestore.SERVER_TIMESTAMP,
                'lastUpdated': firestore.SERVER_TIMESTAMP
            }, merge=True)
        except Exception as e:
            logger.warning(f"요약 정보 저장 실패: {e}")
            
    except Exception as e:
        logger.error(f"Firebase 저장 중 오류: {e}")
        raise


def get_products_from_firebase(
    keyword: Optional[str] = None,
    collection_name: str = "coupang_products",
    limit: int = 100
) -> List[Dict[str, any]]:
    """
    Firebase에서 쿠팡 상품 데이터 조회
    
    Args:
        keyword: 검색어로 필터링 (None이면 전체)
        collection_name: Firebase 컬렉션 이름
        limit: 최대 조회 개수
    
    Returns:
        상품 리스트
    """
    firebase_service = get_firebase_service()
    
    if not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다.")
        return []
    
    try:
        db = firebase_service.db
        if not db:
            return []
        
        collection_ref = db.collection(collection_name)
        
        if keyword:
            query = collection_ref.where(filter=FieldFilter("keyword", "==", keyword)).limit(limit)
        else:
            query = collection_ref.limit(limit)
        
        docs = query.stream()
        products = []
        
        for doc in docs:
            data = doc.to_dict()
            if data:
                if 'scrapedAt' in data and hasattr(data['scrapedAt'], 'timestamp'):
                    data['scrapedAt'] = datetime.fromtimestamp(data['scrapedAt'].timestamp()).isoformat()
                if 'lastUpdated' in data and hasattr(data['lastUpdated'], 'timestamp'):
                    data['lastUpdated'] = datetime.fromtimestamp(data['lastUpdated'].timestamp()).isoformat()
                
                products.append(data)
        
        logger.debug(f"Firebase에서 {len(products)}개 상품 조회 (검색어: {keyword or '전체'})")
        return products
        
    except Exception as e:
        logger.error(f"Firebase 조회 중 오류: {e}")
        return []




def calculate_scraping_product_score(
    needed_qty: Optional[float],
    needed_unit: Optional[str],
    product_size: Optional[float],
    product_unit: Optional[str],
    unit_price: Optional[float],
    avg_unit_price: Optional[float],
    is_rocket_fresh: bool,
    is_free_shipping: bool,
    rank: Optional[int],
    rating: Optional[float],
    reviews: Optional[int],
    max_reviews: Optional[int] = None,
    product_name: Optional[str] = None
) -> float:
    """
    스크래핑 상품의 점수를 계산 (0-100점)
    
    점수 구성:
    - 필요량과의 양차이: 20점
    - 단위당 가격: 30점
    - Rank: 20점 (선형 감소)
    - 리뷰수: 15점 (선형 감소)
    - 평점: 15점 (선형 감소)
    - 로켓프레시: 10점
    - 무료배송: 10점
    
    Args:
        needed_qty: 필요량
        needed_unit: 필요 단위
        product_size: 상품 크기
        product_unit: 상품 단위
        unit_price: 단위당 가격 (100g당)
        avg_unit_price: 평균 단위당 가격
        is_rocket_fresh: 로켓프레시 여부
        is_free_shipping: 무료배송 여부
        rank: 순위 (1-10)
        rating: 평점 (0.0-5.0)
        reviews: 리뷰수
        max_reviews: 최대 리뷰수 (전체 상품 중)
        product_name: 상품명 (단위 확인용)
    
    Returns:
        점수 (0-100)
    """
    score = 0.0
    
    # 1. 필요량과의 양차이 점수 (20점)
    if product_name:
        # 상품명에 단위가 있는지 확인
        unit_patterns = [
            r'\d+\s*g\b', r'\d+\s*kg\b', r'\d+\s*ml\b', r'\d+\s*L\b',
            r'\d+\s*개\b', r'\d+\s*팩\b', r'\d+\s*박스\b', r'\d+\s*봉\b',
            r'\d+\s*입\b', r'\d+\s*구\b',
        ]
        has_unit_in_name = any(re.search(pattern, product_name, re.IGNORECASE) for pattern in unit_patterns)
    else:
        has_unit_in_name = True
    
    if needed_qty and needed_unit and product_size and product_unit and has_unit_in_name:
        needed_base_qty, needed_base_unit = convert_to_base_unit(needed_qty, needed_unit)
        product_base_qty, product_base_unit = convert_to_base_unit(product_size, product_unit)
        
        if needed_base_unit == product_base_unit:
            ratio = product_base_qty / needed_base_qty
            
            # 20점 기준으로 점수 계산 (기존 100점 기준을 20점으로 스케일)
            if 0.95 <= ratio <= 1.05:
                score += 20.0
            elif 1.05 < ratio <= 1.5:
                score += (85.0 + ((1.5 - ratio) / 0.45) * 15.0) * 0.2
            elif 0.9 <= ratio < 0.95:
                score += (85.0 + ((ratio - 0.9) / 0.05) * 15.0) * 0.2
            elif 1.5 < ratio <= 2.0:
                score += (70.0 + ((2.0 - ratio) / 0.5) * 15.0) * 0.2
            elif 0.8 <= ratio < 0.9:
                score += (60.0 + ((ratio - 0.8) / 0.1) * 10.0) * 0.2
            elif 2.0 < ratio <= 2.5:
                score += (60.0 + ((2.5 - ratio) / 0.5) * 10.0) * 0.2
            elif 0.7 <= ratio < 0.8:
                score += (50.0 + ((ratio - 0.7) / 0.1) * 10.0) * 0.2
            elif 2.5 < ratio <= 4.0:
                score += (40.0 + ((4.0 - ratio) / 1.5) * 20.0) * 0.2
            elif 0.5 <= ratio < 0.7:
                score += (30.0 + ((ratio - 0.5) / 0.2) * 20.0) * 0.2
            elif 4.0 < ratio <= 10.0:
                score += max(0.0, (20.0 - ((ratio - 4.0) / 6.0) * 20.0) * 0.2)
            elif ratio < 0.5:
                score += (10.0 * (ratio / 0.5)) * 0.2
            elif 10.0 < ratio <= 50.0:
                score += max(0.0, (10.0 - ((ratio - 10.0) / 40.0) * 10.0) * 0.2)
    # 양이 없으면 0점 (자동)
    
    # 2. 단위당 가격 점수 (30점)
    if unit_price is not None and avg_unit_price is not None and avg_unit_price > 0:
        price_ratio = unit_price / avg_unit_price
        # 30점 기준으로 점수 계산 (기존 40점 기준을 30점으로 스케일)
        if price_ratio <= 0.5:
            score += 30.0
        elif price_ratio <= 0.7:
            score += (30.0 + ((0.7 - price_ratio) / 0.2) * 10.0) * 0.75
        elif price_ratio <= 0.9:
            score += (20.0 + ((0.9 - price_ratio) / 0.2) * 10.0) * 0.75
        elif price_ratio <= 1.1:
            score += (10.0 + ((1.1 - price_ratio) / 0.2) * 10.0) * 0.75
        elif price_ratio <= 1.5:
            score += (5.0 + ((1.5 - price_ratio) / 0.4) * 5.0) * 0.75
        else:
            score += max(0.0, (5.0 - ((price_ratio - 1.5) / 1.0) * 5.0) * 0.75)
    elif unit_price is not None:
        score += 15.0  # 단위가격만 있는 경우
    else:
        score += 7.5   # 단위가격 없는 경우
    
    # 3. Rank 점수 (20점, 선형 감소)
    if rank is not None and 1 <= rank <= 10:
        # 1위=20점, 10위=0점으로 선형 감소
        score += 20.0 * (1.0 - (rank - 1) / 9.0)
    # rank 없으면 0점 (자동)
    
    # 4. 리뷰수 점수 (15점, 선형 감소)
    if reviews is not None and max_reviews and max_reviews > 0:
        # 최대 리뷰수를 기준으로 선형 감소
        review_ratio = min(reviews / max_reviews, 1.0)
        score += 15.0 * review_ratio
    elif reviews is not None:
        # max_reviews가 없으면 절대값 기준 (10000개 = 15점)
        review_ratio = min(reviews / 10000.0, 1.0)
        score += 15.0 * review_ratio
    
    # 5. 평점 점수 (15점, 선형 감소)
    if rating is not None:
        # 5.0점 = 15점, 0.0점 = 0점으로 선형 감소
        score += 15.0 * (rating / 5.0)
    
    # 6. 로켓프레시 (10점)
    if is_rocket_fresh:
        score += 10.0
    
    # 7. 무료배송 (10점)
    if is_free_shipping:
        score += 10.0
    
    return min(score, 100.0)


def parse_product_size_from_name(product_name: str) -> Tuple[Optional[float], Optional[str]]:
    """
    상품명에서 크기와 단위를 추출.
    "500g, 2개"처럼 중량+개수가 있으면 총량(500*2=1000g)으로 반환.
    
    Returns:
        (크기, 단위) 튜플
    """
    # 단위 패턴 (개입보다 먼저 '개'만 매칭하려면 개(?!입) 사용)
    patterns = [
        (r'(\d+(?:\.\d+)?)\s*(kg|킬로그램|KG)', False),
        (r'(\d+(?:\.\d+)?)\s*(g|그램)', False),
        (r'(\d+(?:\.\d+)?)\s*(l|리터|L)', False),
        (r'(\d+(?:\.\d+)?)\s*(ml|밀리리터|ML)', False),
        (r'(\d+(?:\.\d+)?)\s*(개입)', False),
        (r'(\d+(?:\.\d+)?)\s*(봉지)', False),
        (r'(\d+(?:\.\d+)?)\s*개(?!입)', True),   # "2개" (개입 제외)
        (r'(\d+(?:\.\d+)?)\s*세트', True),        # "6세트" — pack multiplier like 개
        (r'(\d+(?:\.\d+)?)(kg|킬로그램|KG)(?![a-zA-Z0-9])', False),
        (r'(\d+(?:\.\d+)?)(g|그램)(?![a-zA-Z0-9])', False),
        (r'(\d+(?:\.\d+)?)(l|리터|L)(?![a-zA-Z0-9])', False),
        (r'(\d+(?:\.\d+)?)(ml|밀리리터|ML)(?![a-zA-Z0-9])', False),
    ]
    
    weight_matches = []  # (size, unit, pos)
    count_ea = None      # "N개"에서 N (중량과 함께 쓸 때만 사용)
    
    for pattern, is_count_only in patterns:
        for match in re.finditer(pattern, product_name, re.IGNORECASE):
            size = float(match.group(1))
            unit = match.group(2).lower() if not is_count_only else '개'
            if is_count_only:
                count_ea = int(size) if size == int(size) else size
            else:
                weight_matches.append((size, unit, match.start()))
    
    # Ignore unrealistic pack counts (e.g. "100개" is a sales count, not a multiplier).
    if count_ea is not None and count_ea > 30:
        count_ea = None

    # "500g, 2개" 형태: 중량/부피 한 종류 + 개수 있으면 총량으로 반환
    if count_ea is not None and count_ea > 0 and weight_matches:
        for size, unit, _ in weight_matches:
            if unit in ['kg', '킬로그램']:
                total_g = size * 1000 * count_ea
                return (total_g, 'g')
            if unit in ['g', '그램']:
                total_g = size * count_ea
                return (total_g, 'g')
            if unit in ['l', '리터']:
                total_ml = size * 1000 * count_ea
                return (total_ml, 'ml')
            if unit in ['ml', '밀리리터']:
                total_ml = size * count_ea
                return (total_ml, 'ml')
    
    if not weight_matches:
        return (None, None)
    
    # 기존: 가장 큰 크기 선택
    best_match = None
    best_size = 0.0
    
    for size, unit, _ in weight_matches:
        if unit in ['kg', '킬로그램']:
            normalized_size = size * 1000
            normalized_unit = 'g'
        elif unit in ['l', '리터']:
            normalized_size = size * 1000
            normalized_unit = 'ml'
        elif unit in ['g', '그램']:
            normalized_size = size
            normalized_unit = 'g'
        elif unit in ['ml', '밀리리터']:
            normalized_size = size
            normalized_unit = 'ml'
        elif unit in ['개입']:
            normalized_size = size
            normalized_unit = '개'
        elif unit in ['봉지']:
            normalized_size = size
            normalized_unit = '봉지'
        else:
            normalized_size = size
            normalized_unit = unit
        
        if normalized_size > best_size:
            best_size = normalized_size
            best_match = (size, unit)
    
    if best_match:
        return (best_match[0], best_match[1])
    return (None, None)


def _scraped_at_to_date(scraped_at) -> Optional[date]:
    """Firestore Timestamp or ISO string -> date. Returns None if invalid."""
    if scraped_at is None:
        return None
    try:
        if hasattr(scraped_at, "timestamp"):
            return datetime.fromtimestamp(scraped_at.timestamp()).date()
        if isinstance(scraped_at, str):
            return datetime.fromisoformat(scraped_at.replace("Z", "+00:00")).date()
        if isinstance(scraped_at, datetime):
            return scraped_at.date()
    except (ValueError, TypeError, OSError):
        pass
    return None


def convert_scraped_to_coupang_product(
    scraped_data: Dict[str, any],
    product_id: Optional[str] = None,
    delivery_text_raw: Optional[str] = None,
    delivery_eta_days: Optional[int] = None,
) -> CoupangProduct:
    """
    스크래핑 결과를 CoupangProduct로 변환
    
    Args:
        scraped_data: Firebase에서 가져온 스크래핑 데이터
        product_id: 상품 ID (없으면 링크에서 추출)
    
    Returns:
        CoupangProduct 객체
    """
    if not product_id:
        # 링크에서 product ID 추출 또는 링크 자체를 해시
        link = scraped_data.get('link', '')
        if link:
            product_id = hashlib.md5(link.encode('utf-8')).hexdigest()
        else:
            product_id = hashlib.md5(
                f"{scraped_data.get('productName', '')}{scraped_data.get('keyword', '')}".encode('utf-8')
            ).hexdigest()
    
    # 상품명에서 크기 파싱
    product_name = scraped_data.get('productName', '')
    package_size, package_unit = parse_product_size_from_name(product_name)
    
    # 원가 및 할인율 (이미 Firebase에 저장된 값 사용)
    original_price = scraped_data.get('originalPrice')
    discount_rate = scraped_data.get('discountRate')
    
    # 평점 및 리뷰수 파싱
    rating = scraped_data.get('rating')
    if rating is not None:
        try:
            rating = float(rating) if isinstance(rating, (int, float, str)) else None
        except (ValueError, TypeError):
            rating = None
    
    reviews = scraped_data.get('reviews')
    if reviews is not None:
        try:
            reviews = int(reviews) if isinstance(reviews, (int, str)) and str(reviews).isdigit() else None
        except (ValueError, TypeError):
            reviews = None
    
    # 단축 URL과 AFFSDP 랜딩을 분리해서 보관. 열 때는 프론트가 랜딩을 우선한다.
    original_link = scraped_data.get('link', '')
    deeplink_url, landing_url = extract_partner_urls_from_scraped(scraped_data)
    final_url = deeplink_url or landing_url or original_link

    product = CoupangProduct(
        product_id=product_id,
        product_name=product_name,
        product_price=scraped_data.get('price', 0),
        product_image=scraped_data.get('imageUrl', ''),
        product_url=final_url,
        original_url=original_link or None,
        deeplink_url=deeplink_url or None,
        landing_url=landing_url or None,
        is_rocket=scraped_data.get('isRocketFresh', False),
        is_free_shipping=scraped_data.get('isFreeShipping', False),
        unit_price=float(scraped_data.get('unitPrice', 0)) if scraped_data.get('unitPrice') else None,
        package_size=package_size,
        package_unit=package_unit,
        sales_rank=scraped_data.get('rank'),
        match_score=None,  # 나중에 계산
        tag=None,  # 나중에 설정
        # 추가 정보도 직접 포함
        original_price=original_price,
        discount_rate=discount_rate,
        rating=rating,
        reviews=reviews,
        arrival_info=scraped_data.get('arrivalInfo'),
        delivery_text_raw=delivery_text_raw if delivery_text_raw is not None else scraped_data.get('arrivalInfo'),
        delivery_eta_days=delivery_eta_days,
    )
    
    return product


def _extract_products_from_doc(data: dict, ingredient_name: str) -> List[CoupangProduct]:
    """
    문서 데이터에서 상품 추출 및 필터링

    Args:
        data: Firestore 문서의 dict 데이터 (doc.to_dict(), 캐시된 값일 수 있음)
        ingredient_name: 식재료명 (필터링용)

    Returns:
        CoupangProduct 리스트
    """
    products_data = data.get('products', [])
    scraped_at_date = _scraped_at_to_date(data.get('scrapedAt'))
    
    # 상품명 필터링 (SIMILAR_WORDS_MAP 사용)
    similar_words = SIMILAR_WORDS_MAP.get(ingredient_name, [ingredient_name])
    products = []
    excluded_ids = get_excluded_product_ids()
    
    for product_data in products_data:
        product_name = product_data.get('productName', '')
        product_name_lower = product_name.lower()
        
        # 상품명에 검색어 또는 유사 단어가 포함되어 있는지 확인
        matched = False
        for word in similar_words:
            if word.lower() in product_name_lower:
                matched = True
                break
        
        if matched:
            # CoupangProduct로 변환 (delivery_text_raw, delivery_eta_days 계산)
            try:
                raw_text = product_data.get('arrivalInfo', '') or ''
                eta_days = compute_delivery_eta_days(raw_text, scraped_at_date) if raw_text and scraped_at_date else None
                product = convert_scraped_to_coupang_product(
                    product_data, None,
                    delivery_text_raw=raw_text or None,
                    delivery_eta_days=eta_days,
                )
                if product.product_id and product.product_id in excluded_ids:
                    continue
                products.append(product)
            except Exception as e:
                logger.warning(f"상품 변환 중 오류: {e}, 상품명: {product_name[:50]}")
                continue
    
    logger.debug(f"스크래핑 결과 {len(products)}개 상품 조회 (검색어: {ingredient_name})")
    return products


def get_scraped_products_for_ingredient(
    ingredient_name: str,
    collection_name: str = "coupang_products"
) -> List[CoupangProduct]:
    """
    Firebase에서 스크래핑된 상품을 조회.
    Uses search expansion (CART_SEARCH_EXPANSION) to merge products from
    multiple coupang_products docs (e.g. '다진 마늘' also pulls from '마늘').
    Falls back to SIMILAR_WORDS_MAP if the primary doc doesn't exist.
    """
    from services.product_service import get_search_names

    firebase_service = get_firebase_service()

    if not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다.")
        return []

    try:
        db = firebase_service.db
        if not db:
            logger.warning("Firestore 클라이언트가 없습니다.")
            return []

        search_names = get_search_names(ingredient_name)
        all_products: List[CoupangProduct] = []
        seen_ids: set = set()

        def _add_products(products: List[CoupangProduct]):
            for p in products:
                pid = p.product_id
                if pid and pid not in seen_ids:
                    seen_ids.add(pid)
                    all_products.append(p)

        for name in search_names:
            data = get_cached_firestore_doc(db, collection_name, name)
            if data is not None:
                _add_products(_extract_products_from_doc(data, name))

        if all_products:
            logger.debug(
                f"Search expansion for '{ingredient_name}': "
                f"{len(all_products)} products from docs {search_names}"
            )
            return all_products

        # Fallback: SIMILAR_WORDS_MAP
        similar_words = SIMILAR_WORDS_MAP.get(ingredient_name, [])
        for similar_word in similar_words:
            if similar_word != ingredient_name:
                data = get_cached_firestore_doc(db, collection_name, similar_word)
                if data is not None:
                    logger.info(f"유사 단어로 문서 발견: '{similar_word}' (검색어: {ingredient_name})")
                    return _extract_products_from_doc(data, ingredient_name)

        logger.debug(f"스크래핑 결과 없음 (검색어: {ingredient_name})")
        return []

    except Exception as e:
        logger.error(f"스크래핑 결과 조회 중 오류: {e}")
        return []

