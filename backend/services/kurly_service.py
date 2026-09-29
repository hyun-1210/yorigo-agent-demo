"""
Kurly (마켓컬리) scraping service
마켓컬리 크롤링 서비스

24시간 분산 실행을 위한 단일 검색어 크롤링 기능 제공
"""
import undetected_chromedriver as uc
from bs4 import BeautifulSoup
import time
import random
import re
import pandas as pd
from datetime import datetime
from typing import List, Dict, Optional, Tuple, Any
import logging
import hashlib
from urllib.parse import quote
import sys
import os
import subprocess
import json
import threading
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.common.action_chains import ActionChains
from selenium.common.exceptions import TimeoutException, NoSuchElementException
import pyperclip
from services.firebase_service import get_firebase_service
from firebase_admin import firestore
from google.cloud.firestore_v1 import FieldFilter
from utils import convert_to_base_unit
from utils.deployment_env import is_production_api_host
from services.product_service import SIMILAR_WORDS_MAP
from services.chrome_driver_lock import chrome_driver_lock

logger = logging.getLogger(__name__)


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


def _init_chrome_driver(
    proxy: Optional[str] = None,
    headless: bool = False
) -> Tuple[uc.Chrome, Optional[subprocess.Popen]]:
    """
    Chrome 드라이버 초기화 (공통 함수)
    
    Args:
        proxy: 프록시 서버 (선택사항)
        headless: 헤드리스 모드 여부
    
    Returns:
        Tuple[uc.Chrome, Optional[subprocess.Popen]]: (드라이버 객체, Xvfb 프로세스)
    """
    xvfb_process = None
    
    # 환경 변수에서 프록시 가져오기
    env_proxy = os.getenv('KURLY_PROXY', None)
    if env_proxy and not proxy:
        proxy = env_proxy
        logger.info(f"환경 변수에서 프록시 로드: {proxy[:20]}...")
    
    # Xvfb 설정
    is_prod_api = is_production_api_host()
    is_docker = os.path.exists('/.dockerenv') or os.getenv('DOCKER_CONTAINER') == 'true'
    is_windows = sys.platform.startswith('win')
    
    force_xvfb = os.getenv('USE_XVFB', 'auto').lower()
    if force_xvfb == 'auto':
        use_xvfb = (is_prod_api or is_docker) and not is_windows and not headless
    else:
        use_xvfb = force_xvfb in ('true', '1', 'yes') and not headless
    
    if use_xvfb and is_windows:
        logger.warning("Windows에서는 Xvfb를 사용할 수 없습니다.")
        use_xvfb = False
    
    if use_xvfb:
        # 프로세스별 고유 디스플레이 포트 할당
        display_num = _get_unique_display_port()
        logger.info(f"Xvfb 가상 디스플레이 시작 중 (포트: {display_num})...")
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
        except FileNotFoundError:
            logger.warning("Xvfb를 찾을 수 없습니다. headless 모드로 전환합니다.")
            use_xvfb = False
        except Exception as e:
            logger.error(f"Xvfb 시작 중 오류: {e}")
            use_xvfb = False
    
    options = uc.ChromeOptions()
    
    # Headless 모드 설정
    if headless:
        options.add_argument('--headless=new')
        logger.info("Headless 모드로 실행")
    elif use_xvfb:
        # DISPLAY 환경 변수에서 포트 가져오기
        display_env = os.environ.get('DISPLAY', ':99')
        options.add_argument(f'--display={display_env}')
        logger.info(f"GUI 모드로 실행 (Xvfb 가상 디스플레이 사용: {display_env})")
    else:
        logger.info("GUI 모드로 실행 (크롬 창 표시)")
    
    # Chrome 옵션 설정
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-gpu')
    options.add_argument('--disable-software-rasterizer')
    options.add_argument('--disable-webrtc')
    options.add_argument('--disable-webrtc-multiple-routes-enabled')
    options.add_argument('--disable-webrtc-hw-decoding')
    options.add_argument('--disable-webrtc-hw-encoding')
    options.add_argument('--disable-extensions')
    options.add_argument('--disable-background-networking')
    options.add_argument('--disable-background-timer-throttling')
    options.add_argument('--disable-renderer-backgrounding')
    options.add_argument('--disable-backgrounding-occluded-windows')
    options.add_argument('--disable-ipc-flooding-protection')
    options.add_argument('--window-size=1920,1080')
    
    # 프록시 설정
    proxy_username = None
    proxy_password = None
    
    if proxy:
        logger.info(f"프록시 사용: {proxy[:30]}...")
        
        if proxy.startswith('http://') or proxy.startswith('https://'):
            from urllib.parse import urlparse
            parsed = urlparse(proxy)
            if parsed.hostname:
                proxy_url = f"{parsed.hostname}:{parsed.port or 3120}"
                options.add_argument(f'--proxy-server=http://{proxy_url}')
                if parsed.username and parsed.password:
                    proxy_username = parsed.username
                    proxy_password = parsed.password
                    logger.info("프록시 인증 정보 감지됨")
        else:
            options.add_argument(f'--proxy-server=http://{proxy}')
    
    # 프록시 인증 확장 프로그램
    proxy_ext_dir = None
    if proxy_username and proxy_password:
        try:
            proxy_ext_dir = "/app/proxy_auth_ext"
            os.makedirs(proxy_ext_dir, exist_ok=True)
            
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
            
            with open(os.path.join(proxy_ext_dir, "manifest.json"), "w") as f:
                json.dump(manifest, f, indent=2)
            
            with open(os.path.join(proxy_ext_dir, "background.js"), "w") as f:
                f.write(background_js)
            
            options.add_argument(f'--load-extension={proxy_ext_dir}')
            logger.info("프록시 인증 확장 프로그램 로드됨")
        except Exception as e:
            logger.warning(f"프록시 인증 확장 프로그램 생성 실패: {e}")
            proxy_ext_dir = None
    
    try:
        # Chrome 드라이버 초기화 시 파일 기반 락 사용 (프로세스 간 동기화)
        with chrome_driver_lock(timeout=300.0, retry_interval=1.0):
            # Chrome 드라이버 디렉토리 존재 확인 및 생성
            chrome_driver_dir = os.path.expanduser("~/.local/share/undetected_chromedriver")
            os.makedirs(chrome_driver_dir, exist_ok=True)
            
            driver = uc.Chrome(options=options, version_main=144, use_subprocess=True)
        logger.info("Chrome 드라이버 초기화 완료")
        
        # 드라이버 초기화 후 약간의 대기 시간 (크롬 창이 완전히 열릴 때까지)
        # Windows에서는 더 긴 대기 시간이 필요할 수 있음
        time.sleep(random.uniform(2, 3))
            
    except Exception as chrome_error:
        logger.error(f"Chrome 드라이버 초기화 실패: {chrome_error}", exc_info=True)
        raise
    
    # webdriver 속성 숨기기는 페이지가 로드된 후에 호출하는 함수에서 처리
    # (_init_chrome_driver에서는 드라이버만 반환)
    
    return driver, xvfb_process


def _human_click(driver, element):
    """자연스러운 마우스 이동 및 클릭"""
    try:
        # 요소 위치로 마우스 이동
        actions = ActionChains(driver)
        
        # 랜덤 오프셋 (요소 중심에서 약간 벗어난 위치)
        offset_x = random.randint(-10, 10)
        offset_y = random.randint(-10, 10)
        
        actions.move_to_element_with_offset(element, offset_x, offset_y)
        actions.pause(random.uniform(0.1, 0.3))
        actions.click()
        actions.perform()
        
        time.sleep(random.uniform(0.2, 0.5))
    except Exception as e:
        # 실패 시 일반 클릭으로 폴백
        logger.warning(f"마우스 클릭 실패, 일반 클릭으로 폴백: {e}")
        element.click()


def _type_like_human(element, text: str, min_delay: float = 0.05, max_delay: float = 0.3):
    """
    개선된 자연스러운 타이핑 모방
    
    Args:
        element: Selenium WebElement
        text: 입력할 텍스트
        min_delay: 최소 지연 시간 (초)
        max_delay: 최대 지연 시간 (초)
    """
    # clear() 대신 전체 선택 후 덮어쓰기
    element.click()
    time.sleep(random.uniform(0.1, 0.2))
    element.send_keys(Keys.CONTROL + 'a')
    time.sleep(random.uniform(0.1, 0.2))
    
    # 단어별로 타이핑 속도 변화
    words = text.split() if ' ' in text else [text]
    
    for word_idx, word in enumerate(words):
        # 단어 시작 시 약간 느리게
        if word_idx == 0:
            time.sleep(random.uniform(0.2, 0.4))
        
        for char_idx, char in enumerate(word):
            element.send_keys(char)
            
            # 문자별 지연 시간 (가우시안 분포 사용)
            delay = random.gauss(
                (min_delay + max_delay) / 2,
                (max_delay - min_delay) / 4
            )
            delay = max(min_delay, min(max_delay, delay))
            time.sleep(delay)
            
            # 5% 확률로 실수 시뮬레이션
            if random.random() < 0.05:
                element.send_keys(Keys.BACKSPACE)
                time.sleep(random.uniform(0.1, 0.2))
                element.send_keys(char)
                time.sleep(random.uniform(0.1, 0.2))
        
        # 단어 사이 공백
        if word_idx < len(words) - 1:
            element.send_keys(' ')
            time.sleep(random.uniform(0.1, 0.2))


def _hide_automation_signals(driver):
    """모든 자동화 신호 숨기기"""
    try:
        driver.execute_script("""
            // navigator.webdriver 숨기기 (이미 정의되어 있으면 삭제 후 재정의)
            try {
                delete navigator.__proto__.webdriver;
            } catch(e) {}
            try {
                Object.defineProperty(navigator, 'webdriver', {
                    get: () => undefined,
                    configurable: true
                });
            } catch(e) {
                // 이미 정의되어 있으면 무시
            }
            
            // window.chrome 객체 추가 (없으면 추가)
            if (!window.chrome) {
                window.chrome = {
                    runtime: {}
                };
            }
            
            // navigator.plugins 정상화 (없으면 추가)
            if (!navigator.plugins || navigator.plugins.length === 0) {
                try {
                    Object.defineProperty(navigator, 'plugins', {
                        get: () => [1, 2, 3, 4, 5],
                        configurable: true
                    });
                } catch(e) {
                    // 이미 정의되어 있으면 무시
                }
            }
        """)
    except Exception as e:
        logger.debug(f"자동화 신호 숨기기 실패 (무시): {e}")


def _handle_security_error(driver, wait, max_retries: int = 3) -> bool:
    """보안 인증 오류 처리 (확인 버튼 클릭 후 재시도)"""
    for attempt in range(max_retries):
        try:
            # 보안 오류 모달 확인
            error_selectors = [
                (By.XPATH, '//div[contains(text(), "보안 인증 과정에서 오류가 발생하였습니다")]'),
                (By.XPATH, '//div[contains(text(), "보안 인증")]'),
                (By.XPATH, '//button[contains(text(), "확인")]'),
            ]
            
            error_modal = None
            confirm_button = None
            
            for by, selector in error_selectors:
                try:
                    elements = driver.find_elements(by, selector)
                    for elem in elements:
                        if "확인" in elem.text or "보안 인증" in elem.text:
                            if "확인" in elem.text:
                                confirm_button = elem
                            else:
                                error_modal = elem
                except:
                    continue
            
            if error_modal and confirm_button:
                logger.warning(f"보안 인증 오류 감지 (시도 {attempt + 1}/{max_retries})")
                print(f"[KurlyLogin] Security error detected, clicking confirm button...", flush=True)
                
                # 확인 버튼 클릭
                _human_click(driver, confirm_button)
                time.sleep(random.uniform(2, 3))
                
                # 페이지 새로고침 또는 재접속
                driver.refresh()
                time.sleep(random.uniform(3, 5))
                
                return True  # 오류 처리 완료
            
            return False  # 오류 없음
            
        except Exception as e:
            logger.warning(f"보안 오류 처리 중 예외: {e}")
            if attempt < max_retries - 1:
                time.sleep(random.uniform(2, 4))
    
    return False


def _find_curator_button(driver, wait) -> Optional[Any]:
    """컬리 큐레이터 버튼 찾기"""
    # 페이지 로딩 완료 대기
    try:
        WebDriverWait(driver, 10).until(
            lambda d: d.execute_script("return document.readyState") == "complete"
        )
        time.sleep(random.uniform(1, 2))
    except:
        pass
    
    # 다양한 셀렉터 시도
    selectors = [
        # CSS 클래스 기반
        (By.CSS_SELECTOR, 'span.css-1yxu09j'),
        (By.CSS_SELECTOR, 'a[href*="curator-program"]'),
        (By.CSS_SELECTOR, 'a[href*="curator"]'),
        
        # XPath - 텍스트 기반
        (By.XPATH, '//span[contains(text(), "컬리 큐레이터")]'),
        (By.XPATH, '//a[contains(text(), "컬리 큐레이터")]'),
        (By.XPATH, '//*[contains(text(), "컬리 큐레이터")]'),
        
        # XPath - normalize-space 사용
        (By.XPATH, '//span[contains(normalize-space(text()), "컬리 큐레이터")]'),
        (By.XPATH, '//a[contains(normalize-space(text()), "컬리 큐레이터")]'),
        
        # XPath - 자식 요소 포함
        (By.XPATH, '//span[.//text()[contains(., "컬리 큐레이터")]]'),
        (By.XPATH, '//a[.//text()[contains(., "컬리 큐레이터")]]'),
    ]
    
    for by, selector in selectors:
        try:
            element = wait.until(EC.element_to_be_clickable((by, selector)))
            # 텍스트 확인
            try:
                element_text = element.text.strip()
                if "컬리 큐레이터" in element_text or "curator" in element_text.lower():
                    logger.info(f"컬리 큐레이터 버튼 발견 ({selector}): {element_text[:30]}...")
                    return element
            except:
                # 텍스트를 가져올 수 없어도 반환 (a 태그 등)
                logger.info(f"컬리 큐레이터 요소 발견 ({selector})")
                return element
        except TimeoutException:
            continue
        except Exception as e:
            logger.debug(f"셀렉터 {selector} 시도 실패: {e}")
            continue
    
    # 최종 시도: 모든 a 태그와 span 태그 검색
    try:
        elements = driver.find_elements(By.TAG_NAME, "a")
        elements.extend(driver.find_elements(By.TAG_NAME, "span"))
        for elem in elements:
            try:
                elem_text = elem.text.strip()
                if "컬리 큐레이터" in elem_text:
                    if elem.is_displayed() and elem.is_enabled():
                        logger.info(f"컬리 큐레이터 버튼 발견 (텍스트 기반): {elem_text[:30]}...")
                        return elem
            except:
                continue
    except:
        pass
    
    logger.warning("컬리 큐레이터 버튼을 찾을 수 없습니다.")
    return None


def _find_welcome_login_button(driver, wait) -> Optional[Any]:
    """Welcome 페이지의 로그인 버튼 찾기"""
    # 페이지 로딩 완료 대기
    try:
        WebDriverWait(driver, 10).until(
            lambda d: d.execute_script("return document.readyState") == "complete"
        )
        time.sleep(random.uniform(1, 2))  # 추가 대기
    except:
        pass
    
    # 다양한 셀렉터 시도 (우선순위 순)
    selectors = [
        # CSS 클래스 기반 (사진에서 확인된 클래스)
        (By.CSS_SELECTOR, 'button.css-puimvz'),
        (By.CSS_SELECTOR, 'button.e1poubxt3'),
        (By.CSS_SELECTOR, 'button[class*="css-puimvz"]'),
        (By.CSS_SELECTOR, 'button[class*="e1poubxt3"]'),
        
        # XPath - normalize-space 사용 (공백 정규화)
        (By.XPATH, '//button[normalize-space(text())="1분만에 지원하고 수익 만들기"]'),
        (By.XPATH, '//button[contains(normalize-space(text()), "1분만에 지원하고 수익 만들기")]'),
        (By.XPATH, '//button[contains(normalize-space(text()), "수익 만들기")]'),
        (By.XPATH, '//button[contains(normalize-space(text()), "지원하고")]'),
        
        # XPath - 자식 요소 포함 검색
        (By.XPATH, '//button[.//text()[contains(., "1분만에 지원하고 수익 만들기")]]'),
        (By.XPATH, '//button[.//text()[contains(., "수익 만들기")]]'),
        (By.XPATH, '//button[.//text()[contains(., "지원하고")]]'),
        
        # 일반 텍스트 매칭 (기존 방식 - 호환성)
        (By.XPATH, '//button[contains(text(), "1분만에 지원하고 수익 만들기")]'),
        (By.XPATH, '//button[contains(text(), "수익 만들기")]'),
        (By.XPATH, '//button[contains(text(), "지원하고")]'),
        
        # 모든 button 요소 중 텍스트로 찾기
        (By.TAG_NAME, 'button'),
    ]
    
    for by, selector in selectors:
        try:
            if by == By.TAG_NAME:
                # 모든 button 요소를 찾아서 텍스트로 필터링
                buttons = driver.find_elements(By.TAG_NAME, 'button')
                for btn in buttons:
                    try:
                        btn_text = btn.text.strip()
                        if "1분만에 지원하고 수익 만들기" in btn_text or \
                           "수익 만들기" in btn_text or \
                           "지원하고" in btn_text:
                            if btn.is_displayed() and btn.is_enabled():
                                logger.info(f"Welcome 버튼 발견 (텍스트 기반): {btn_text[:30]}...")
                                return btn
                    except:
                        continue
            else:
                # 일반 셀렉터 사용
                element = wait.until(EC.element_to_be_clickable((by, selector)))
                # 텍스트 확인 (버튼인 경우)
                if element.tag_name.lower() == 'button':
                    element_text = element.text.strip()
                    if "1분만에 지원하고 수익 만들기" in element_text or \
                       "수익 만들기" in element_text or \
                       "지원하고" in element_text:
                        logger.info(f"Welcome 버튼 발견 ({selector}): {element_text[:30]}...")
                        return element
                else:
                    # button이 아니어도 반환 (a 태그 등)
                    logger.info(f"Welcome 요소 발견 ({selector})")
                    return element
        except TimeoutException:
            continue
        except Exception as e:
            logger.debug(f"셀렉터 {selector} 시도 실패: {e}")
            continue
    
    # 최종 시도: JavaScript로 찾기
    try:
        button = driver.execute_script("""
            var buttons = document.querySelectorAll('button');
            for (var i = 0; i < buttons.length; i++) {
                var btn = buttons[i];
                var text = btn.textContent || btn.innerText || '';
                if (text.includes('1분만에 지원하고 수익 만들기') || 
                    text.includes('수익 만들기') || 
                    text.includes('지원하고')) {
                    return btn;
                }
            }
            return null;
        """)
        if button:
            logger.info("Welcome 버튼 발견 (JavaScript 기반)")
            return button
    except Exception as e:
        logger.debug(f"JavaScript 버튼 찾기 실패: {e}")
    
    logger.warning("Welcome 페이지 로그인 버튼을 찾을 수 없습니다.")
    return None


def login_to_kurly(
    username: Optional[str] = None,
    password: Optional[str] = None,
    proxy: Optional[str] = None,
    headless: bool = False,
    save_cookies: bool = True,
    login_url: Optional[str] = None,
    login_method: str = "default"
) -> Tuple[bool, Optional[uc.Chrome], Optional[Dict], Optional[subprocess.Popen]]:
    """
    컬리 로그인 수행
    
    Args:
        username: 컬리 아이디 (None이면 환경 변수 KURLY_USERNAME에서 읽음)
        password: 컬리 비밀번호 (None이면 환경 변수 KURLY_PASSWORD에서 읽음)
        proxy: 프록시 서버 (선택사항)
        headless: 헤드리스 모드 여부
        save_cookies: 로그인 후 쿠키 저장 여부
        login_url: 로그인 페이지 URL (기본값: 큐레이터 프로그램 로그인 페이지)
        login_method: 로그인 방법 ("main_page", "welcome_page", "direct", "default")
    
    Returns:
        Tuple[bool, Optional[uc.Chrome], Optional[Dict], Optional[subprocess.Popen]]: 
        (로그인 성공 여부, 드라이버 객체, 쿠키 딕셔너리, Xvfb 프로세스)
    
    Raises:
        ValueError: 아이디 또는 비밀번호가 제공되지 않았을 때
    """
    driver = None
    xvfb_process = None
    
    try:
        # 환경 변수에서 아이디/비밀번호 읽기 (파라미터가 None인 경우)
        if not username:
            username = os.getenv('KURLY_USERNAME')
        if not password:
            password = os.getenv('KURLY_PASSWORD')
        
        # 아이디/비밀번호 검증
        if not username:
            raise ValueError("아이디가 제공되지 않았습니다. KURLY_USERNAME 환경 변수를 설정하거나 username 파라미터를 제공하세요.")
        if not password:
            raise ValueError("비밀번호가 제공되지 않았습니다. KURLY_PASSWORD 환경 변수를 설정하거나 password 파라미터를 제공하세요.")
        
        logger.info(f"컬리 로그인 시작... (방법: {login_method})")
        print(f"[KurlyLogin] Starting login process for user: {username[:3]}*** (method: {login_method})", flush=True)
        
        # Chrome 드라이버 초기화
        driver, xvfb_process = _init_chrome_driver(proxy=proxy, headless=headless)
        
        # 드라이버 초기화 후 대기
        time.sleep(random.uniform(1, 2))
        
        # login_method에 따른 진입 경로
        if login_method == "main_page":
            # 메인 페이지 → 큐레이터 버튼 → welcome → 로그인
            logger.info("메인 페이지 접속 중...")
            try:
                driver.get("https://www.kurly.com/main")
            except Exception as e:
                logger.error(f"메인 페이지 접속 실패: {e}")
                # 재시도
                time.sleep(2)
                try:
                    driver.get("https://www.kurly.com/main")
                except Exception as e2:
                    logger.error(f"메인 페이지 접속 재시도 실패: {e2}")
                    raise
            time.sleep(random.uniform(2, 4))
            
            # 페이지 로딩 완료 대기
            try:
                WebDriverWait(driver, 30).until(
                    lambda d: d.execute_script("return document.readyState") == "complete"
                )
            except:
                pass
            time.sleep(random.uniform(1, 2))
            
            # 자동화 신호 숨기기 (페이지 로드 후)
            _hide_automation_signals(driver)
            
            # WebDriverWait 설정
            wait_timeout = 60 if headless else 30
            wait = WebDriverWait(driver, wait_timeout)
            
            # 컬리 큐레이터 버튼 찾기 및 클릭
            logger.info("컬리 큐레이터 버튼 찾는 중...")
            curator_button = _find_curator_button(driver, wait)
            if curator_button:
                logger.info("컬리 큐레이터 버튼 발견, 클릭 중...")
                _human_click(driver, curator_button)
                time.sleep(random.uniform(2, 3))
            else:
                logger.warning("컬리 큐레이터 버튼을 찾을 수 없습니다. 직접 welcome 페이지로 이동합니다.")
                driver.get("https://lounge.kurly.com/curator-program/welcome")
                time.sleep(random.uniform(2, 3))
            
            # welcome 페이지 확인 및 버튼 클릭
            if "welcome" in driver.current_url or "curator-program" in driver.current_url:
                # 페이지 로딩 대기
                time.sleep(random.uniform(2, 3))
                try:
                    WebDriverWait(driver, 30).until(
                        lambda d: d.execute_script("return document.readyState") == "complete"
                    )
                except:
                    pass
                time.sleep(random.uniform(1, 2))
                
                welcome_button = _find_welcome_login_button(driver, wait)
                if welcome_button:
                    logger.info("Welcome 페이지 로그인 버튼 발견, 클릭 중...")
                    
                    # 스크롤하여 버튼이 보이도록
                    try:
                        driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", welcome_button)
                        time.sleep(random.uniform(0.5, 1.0))
                    except:
                        pass
                    
                    # 여러 방법으로 클릭 시도
                    clicked = False
                    
                    # 방법 1: 일반 클릭
                    try:
                        _human_click(driver, welcome_button)
                        time.sleep(random.uniform(1, 2))
                        if "login" in driver.current_url.lower() or "member" in driver.current_url.lower():
                            clicked = True
                            logger.info("클릭 성공: 로그인 페이지로 이동 확인")
                    except Exception as e:
                        logger.debug(f"일반 클릭 실패: {e}")
                    
                    # 방법 2: JavaScript 클릭 (방법 1 실패 시)
                    if not clicked:
                        try:
                            driver.execute_script("arguments[0].click();", welcome_button)
                            time.sleep(random.uniform(1, 2))
                            if "login" in driver.current_url.lower() or "member" in driver.current_url.lower():
                                clicked = True
                                logger.info("JavaScript 클릭 성공: 로그인 페이지로 이동 확인")
                        except Exception as e:
                            logger.debug(f"JavaScript 클릭 실패: {e}")
                    
                    # 방법 3: 부모 요소 클릭 (a 태그 등)
                    if not clicked:
                        try:
                            parent = welcome_button.find_element(By.XPATH, "./..")
                            if parent.tag_name.lower() == 'a':
                                driver.execute_script("arguments[0].click();", parent)
                                time.sleep(random.uniform(1, 2))
                                if "login" in driver.current_url.lower() or "member" in driver.current_url.lower():
                                    clicked = True
                                    logger.info("부모 요소 클릭 성공: 로그인 페이지로 이동 확인")
                        except:
                            pass
                    
                    if not clicked:
                        logger.warning("버튼 클릭 후 로그인 페이지로 이동하지 않았습니다.")
                        logger.warning(f"현재 URL: {driver.current_url}")
                    
                    time.sleep(random.uniform(1, 2))
                else:
                    logger.warning("Welcome 페이지 로그인 버튼을 찾을 수 없습니다.")
                    # 디버깅 정보 출력
                    try:
                        current_url = driver.current_url
                        buttons = driver.find_elements(By.TAG_NAME, "button")
                        logger.warning(f"현재 URL: {current_url}, 버튼 개수: {len(buttons)}")
                    except:
                        pass
            
        elif login_method == "welcome_page":
            # Welcome 페이지 직접 접속 → 로그인 버튼
            logger.info("Welcome 페이지 직접 접속 중...")
            driver.get("https://lounge.kurly.com/curator-program/welcome")
            
            # 페이지 로딩 대기 (React 앱 고려)
            time.sleep(random.uniform(3, 5))
            
            # 페이지가 완전히 로드될 때까지 대기
            try:
                WebDriverWait(driver, 30).until(
                    lambda d: d.execute_script("return document.readyState") == "complete"
                )
            except:
                pass
            
            # 추가 대기 (JavaScript 실행 완료)
            time.sleep(random.uniform(2, 3))
            
            # 자동화 신호 숨기기 (페이지 로드 후)
            _hide_automation_signals(driver)
            
            # WebDriverWait 설정
            wait_timeout = 60 if headless else 30
            wait = WebDriverWait(driver, wait_timeout)
            
            welcome_button = _find_welcome_login_button(driver, wait)
            if welcome_button:
                logger.info("Welcome 페이지 로그인 버튼 발견, 클릭 중...")
                
                # 스크롤하여 버튼이 보이도록
                try:
                    driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", welcome_button)
                    time.sleep(random.uniform(0.5, 1.0))
                except:
                    pass
                
                # 여러 방법으로 클릭 시도
                clicked = False
                
                # 방법 1: 일반 클릭
                try:
                    _human_click(driver, welcome_button)
                    time.sleep(random.uniform(1, 2))
                    if "login" in driver.current_url.lower() or "member" in driver.current_url.lower():
                        clicked = True
                        logger.info("클릭 성공: 로그인 페이지로 이동 확인")
                except Exception as e:
                    logger.debug(f"일반 클릭 실패: {e}")
                
                # 방법 2: JavaScript 클릭 (방법 1 실패 시)
                if not clicked:
                    try:
                        driver.execute_script("arguments[0].click();", welcome_button)
                        time.sleep(random.uniform(1, 2))
                        if "login" in driver.current_url.lower() or "member" in driver.current_url.lower():
                            clicked = True
                            logger.info("JavaScript 클릭 성공: 로그인 페이지로 이동 확인")
                    except Exception as e:
                        logger.debug(f"JavaScript 클릭 실패: {e}")
                
                # 방법 3: 부모 요소 클릭 (a 태그 등)
                if not clicked:
                    try:
                        parent = welcome_button.find_element(By.XPATH, "./..")
                        if parent.tag_name.lower() == 'a':
                            driver.execute_script("arguments[0].click();", parent)
                            time.sleep(random.uniform(1, 2))
                            if "login" in driver.current_url.lower() or "member" in driver.current_url.lower():
                                clicked = True
                                logger.info("부모 요소 클릭 성공: 로그인 페이지로 이동 확인")
                    except:
                        pass
                
                if not clicked:
                    logger.warning("버튼 클릭 후 로그인 페이지로 이동하지 않았습니다.")
                    logger.warning(f"현재 URL: {driver.current_url}")
                
                time.sleep(random.uniform(1, 2))
            else:
                logger.warning("Welcome 페이지 로그인 버튼을 찾을 수 없습니다.")
                # 디버깅 정보 출력
                try:
                    current_url = driver.current_url
                    page_title = driver.title
                    buttons = driver.find_elements(By.TAG_NAME, "button")
                    logger.warning(f"현재 URL: {current_url}, Title: {page_title}, 버튼 개수: {len(buttons)}")
                    for i, btn in enumerate(buttons[:5]):  # 처음 5개만
                        try:
                            logger.warning(f"  버튼 {i+1}: {btn.text[:50]}")
                        except:
                            pass
                except Exception as e:
                    logger.warning(f"디버깅 정보 수집 실패: {e}")
        
        elif login_method == "direct":
            # 기존 로그인 URL 직접 접속
            if not login_url:
                login_url = "https://www.kurly.com/member/login?internalUrl=https%3A%2F%2Flounge.kurly.com%2Fcurator-program%3Fmove%3Dtrue"
            logger.info(f"로그인 URL 직접 접속: {login_url}")
            driver.get(login_url)
            time.sleep(random.uniform(2, 4))
            
            # 페이지 로딩 완료 대기
            try:
                WebDriverWait(driver, 30).until(
                    lambda d: d.execute_script("return document.readyState") == "complete"
                )
            except:
                pass
            time.sleep(random.uniform(1, 2))
            
            # 자동화 신호 숨기기 (페이지 로드 후)
            _hide_automation_signals(driver)
        
        else:  # default
            # 기존 로직
            if not login_url:
                login_url = "https://www.kurly.com/member/login?internalUrl=https%3A%2F%2Flounge.kurly.com%2Fcurator-program%3Fmove%3Dtrue"
            logger.info(f"로그인 페이지 접속: {login_url}")
            driver.get(login_url)
            time.sleep(random.uniform(2, 4))
            
            # 페이지 로딩 완료 대기
            try:
                WebDriverWait(driver, 30).until(
                    lambda d: d.execute_script("return document.readyState") == "complete"
                )
            except:
                pass
            time.sleep(random.uniform(1, 2))
            
            # 자동화 신호 숨기기 (페이지 로드 후)
            _hide_automation_signals(driver)
        
        # WebDriverWait 설정 (아직 설정되지 않은 경우)
        if 'wait' not in locals():
            wait_timeout = 60 if headless else 30
            wait = WebDriverWait(driver, wait_timeout)
        
        # 로그인 페이지인지 확인 (main_page 방법은 이미 welcome 버튼 클릭으로 이동했을 수 있음)
        current_url = driver.current_url
        if "login" not in current_url.lower() and "member" not in current_url.lower():
            # 로그인 페이지가 아니면 로그인 페이지로 이동
            logger.info("로그인 페이지로 이동 중...")
            driver.get("https://www.kurly.com/member/login?internalUrl=https%3A%2F%2Flounge.kurly.com%2Fcurator-program%3Fmove%3Dtrue")
            time.sleep(random.uniform(2, 3))
        
        # 페이지 로딩 대기
        if headless:
            time.sleep(random.uniform(5, 8))
        else:
            time.sleep(random.uniform(3, 5))
        
        # 페이지가 완전히 로드될 때까지 대기
        try:
            WebDriverWait(driver, 30).until(
                lambda d: d.execute_script("return document.readyState") == "complete"
            )
        except:
            pass
        
        # 추가 대기 (JavaScript 실행 완료 대기)
        if headless:
            time.sleep(random.uniform(3, 5))
        else:
            time.sleep(random.uniform(1, 2))
        
        # 자동화 신호 숨기기 (페이지 로드 후 재실행 - 이미 실행했으면 스킵)
        try:
            _hide_automation_signals(driver)
        except:
            pass
        
        # 보안 오류 확인 및 처리
        _handle_security_error(driver, wait, max_retries=3)
        
        # 아이디 입력 필드 찾기
        logger.info("아이디 입력 필드 찾는 중...")
        print(f"[KurlyLogin] Looking for ID input field...", flush=True)
        
        id_selectors = [
            (By.NAME, "id"),
            (By.CSS_SELECTOR, 'input[name="id"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="아이디"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="ID"]'),
            (By.CSS_SELECTOR, 'input[type="text"]'),
            (By.CSS_SELECTOR, 'input[type="email"]')
        ]
        
        id_input = None
        for by, selector in id_selectors:
            try:
                id_input = wait.until(EC.presence_of_element_located((by, selector)))
                logger.info(f"아이디 입력 필드 발견: {selector}")
                break
            except TimeoutException:
                continue
        
        # headless 모드에서 추가 재시도
        if not id_input and headless:
            logger.info("headless 모드에서 추가 대기 후 재시도 중...")
            time.sleep(random.uniform(5, 8))
            for by, selector in id_selectors:
                try:
                    id_input = wait.until(EC.presence_of_element_located((by, selector)))
                    logger.info(f"아이디 입력 필드 발견 (재시도): {selector}")
                    break
                except TimeoutException:
                    continue
        
        if not id_input:
            # 디버깅 정보 출력
            try:
                current_url = driver.current_url
                page_title = driver.title
                page_source_snippet = driver.page_source[:500] if driver.page_source else "N/A"
                logger.error(f"아이디 입력 필드를 찾을 수 없습니다. URL: {current_url}, Title: {page_title}")
                logger.debug(f"페이지 소스 일부: {page_source_snippet}")
            except Exception as e:
                logger.error(f"디버깅 정보 수집 실패: {e}")
            raise Exception("아이디 입력 필드를 찾을 수 없습니다.")
        
        # 비밀번호 입력 필드 찾기
        logger.info("비밀번호 입력 필드 찾는 중...")
        print(f"[KurlyLogin] Looking for password input field...", flush=True)
        
        password_selectors = [
            (By.CSS_SELECTOR, 'input[type="password"]'),
            (By.CSS_SELECTOR, 'input[name="password"]'),
            (By.CSS_SELECTOR, 'input[name="pw"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="비밀번호"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="Password"]')
        ]
        
        password_input = None
        for by, selector in password_selectors:
            try:
                password_input = wait.until(EC.presence_of_element_located((by, selector)))
                logger.info(f"비밀번호 입력 필드 발견: {selector}")
                break
            except TimeoutException:
                continue
        
        if not password_input:
            raise Exception("비밀번호 입력 필드를 찾을 수 없습니다.")
        
        # 보안 오류 재확인 (입력 전)
        _handle_security_error(driver, wait, max_retries=1)
        
        # 아이디 입력 (자연스러운 타이핑)
        logger.info("아이디 입력 중...")
        print(f"[KurlyLogin] Typing username...", flush=True)
        _human_click(driver, id_input)
        time.sleep(random.uniform(0.5, 1.0))
        _type_like_human(id_input, username)
        time.sleep(random.uniform(0.5, 1.0))
        
        # 비밀번호 입력 (자연스러운 타이핑)
        logger.info("비밀번호 입력 중...")
        print(f"[KurlyLogin] Typing password...", flush=True)
        _human_click(driver, password_input)
        time.sleep(random.uniform(0.5, 1.0))
        _type_like_human(password_input, password)
        time.sleep(random.uniform(1.0, 2.0))
        
        # 로그인 버튼 찾기 및 클릭
        logger.info("로그인 버튼 찾는 중...")
        print(f"[KurlyLogin] Looking for login button...", flush=True)
        
        login_button_selectors = [
            (By.CSS_SELECTOR, 'button[type="submit"]'),
            (By.CSS_SELECTOR, 'button:contains("로그인")'),
            (By.XPATH, '//button[contains(text(), "로그인")]'),
            (By.XPATH, '//button[contains(text(), "Login")]'),
            (By.CSS_SELECTOR, 'button.css-4ojrwk'),
            (By.CSS_SELECTOR, 'button.e4nu7ef3')
        ]
        
        login_button = None
        for by, selector in login_button_selectors:
            try:
                if by == By.XPATH:
                    login_button = wait.until(EC.element_to_be_clickable((by, selector)))
                else:
                    login_button = wait.until(EC.element_to_be_clickable((by, selector)))
                logger.info(f"로그인 버튼 발견: {selector}")
                break
            except TimeoutException:
                continue
        
        if not login_button:
            # 마지막 시도: 모든 button 요소 중 "로그인" 텍스트가 있는 것 찾기
            try:
                buttons = driver.find_elements(By.TAG_NAME, "button")
                for btn in buttons:
                    if "로그인" in btn.text or "Login" in btn.text:
                        login_button = btn
                        logger.info("로그인 버튼 발견 (텍스트 기반)")
                        break
            except Exception:
                pass
        
        if not login_button:
            raise Exception("로그인 버튼을 찾을 수 없습니다.")
        
        # 로그인 버튼 클릭
        logger.info("로그인 버튼 클릭...")
        print(f"[KurlyLogin] Clicking login button...", flush=True)
        _human_click(driver, login_button)
        
        # 로그인 완료 대기 (URL 변경 또는 특정 요소 확인)
        logger.info("로그인 완료 대기 중...")
        print(f"[KurlyLogin] Waiting for login to complete...", flush=True)
        time.sleep(random.uniform(3, 5))
        
        # 로그인 성공 확인
        current_url = driver.current_url
        page_source = driver.page_source.lower()
        
        # 성공 조건: 큐레이터 라운지 페이지로 이동했거나, 로그인 관련 에러가 없는 경우
        login_success = False
        
        # URL 기반 확인
        if "lounge.kurly.com" in current_url or "kurly.com" in current_url:
            # 로그인 실패 메시지 확인
            failure_keywords = ["로그인 실패", "아이디 또는 비밀번호", "incorrect", "invalid", "error"]
            has_failure = any(keyword in page_source for keyword in failure_keywords)
            
            if not has_failure:
                # 성공 키워드 확인
                success_keywords = ["큐레이터", "curator", "리워드", "reward", "강준석", "님"]
                has_success = any(keyword in page_source for keyword in success_keywords)
                
                if has_success or "lounge.kurly.com" in current_url:
                    login_success = True
                    logger.info("로그인 성공 확인됨 (URL 및 페이지 내용 기반)")
                    print(f"[KurlyLogin] Login successful! Current URL: {current_url[:80]}...", flush=True)
        
        if not login_success:
            # 추가 확인: 쿠키 확인
            cookies = driver.get_cookies()
            auth_cookies = [c for c in cookies if any(key in c.get('name', '').lower() for key in ['session', 'auth', 'login', 'user', 'member'])]
            
            if auth_cookies:
                login_success = True
                logger.info("로그인 성공 확인됨 (쿠키 기반)")
                print(f"[KurlyLogin] Login successful! Found {len(auth_cookies)} authentication cookies.", flush=True)
            else:
                logger.warning("로그인 실패 가능성 (성공 조건 미충족)")
                print(f"[KurlyLogin] WARNING: Login may have failed. Current URL: {current_url[:80]}...", flush=True)
        
        # 쿠키 저장
        cookies_dict = None
        if login_success and save_cookies:
            try:
                cookies = driver.get_cookies()
                cookies_dict = {cookie['name']: cookie['value'] for cookie in cookies}
                
                # 쿠키를 파일로 저장 (선택사항)
                cookie_file = os.path.join(
                    os.path.dirname(__file__),
                    "..",
                    "kurly_cookies.json"
                )
                cookie_file = os.path.abspath(cookie_file)
                
                with open(cookie_file, 'w', encoding='utf-8') as f:
                    json.dump(cookies, f, indent=2, ensure_ascii=False)
                
                logger.info(f"쿠키 저장 완료: {cookie_file} ({len(cookies)}개 쿠키)")
                print(f"[KurlyLogin] Saved {len(cookies)} cookies to file.", flush=True)
            except Exception as e:
                logger.warning(f"쿠키 저장 실패: {e}")
        
        return login_success, driver, cookies_dict, xvfb_process
        
    except TimeoutException as e:
        logger.error(f"타임아웃 에러: {e}", exc_info=True)
        print(f"[KurlyLogin] ERROR: Timeout - {e}", flush=True)
        if driver:
            try:
                driver.quit()
            except:
                pass
        return False, None, None, xvfb_process
    
    except Exception as e:
        logger.error(f"로그인 중 에러: {e}", exc_info=True)
        print(f"[KurlyLogin] ERROR: {e}", flush=True)
        if driver:
            try:
                driver.quit()
            except:
                pass
        return False, None, None, xvfb_process


def _extract_product_info_from_card(
    driver: uc.Chrome,
    card_element,
    keyword: str,
    index: int
) -> Optional[Dict[str, any]]:
    """
    상품 카드에서 상품명, 가격, 이미지 추출 (링크 생성 없이)
    
    Args:
        driver: Chrome 드라이버
        card_element: 상품 카드 WebElement
        keyword: 검색어
        index: 상품 인덱스
    
    Returns:
        Dict: 상품 정보 (링크는 아직 없음)
    """
    try:
        # 상품명 추출
        product_name = ""
        try:
            # 상품 정보 div 찾기 (style="height: 64px; ...")
            info_divs = card_element.find_elements(By.XPATH, './/div[contains(@style, "height: 64px")]')
            if not info_divs:
                info_divs = card_element.find_elements(By.XPATH, './/div[contains(@style, "flex-direction: column")]')
            
            for info_div in info_divs:
                try:
                    spans = info_div.find_elements(By.TAG_NAME, "span")
                    for span in spans:
                        text = span.text.strip()
                        # 가격이 아닌 긴 텍스트를 상품명으로
                        if len(text) > 10 and not re.match(r'^[\d,]+원', text) and '%' not in text:
                            product_name = text
                            break
                    if product_name:
                        break
                except:
                    continue
        except Exception as e:
            logger.debug(f"상품명 추출 중 오류: {e}")
        
        if not product_name:
            # 전체 텍스트에서 가장 긴 것 찾기
            try:
                all_texts = card_element.text.split('\n')
                for text in all_texts:
                    text = text.strip()
                    if len(text) > 10 and not re.match(r'^[\d,]+원', text) and '링크' not in text:
                        product_name = text
                        break
            except:
                pass
        
        if not product_name:
            product_name = f"상품 {index + 1}"
        
        # 가격 추출
        price = "0"
        try:
            # 방법 1: "원" 텍스트가 포함된 span 찾기
            price_spans = card_element.find_elements(By.XPATH, './/span[contains(text(), "원")]')
            for span in price_spans:
                text = span.text.strip()
                # 숫자와 "원"이 함께 있는 경우
                price_match = re.search(r'([\d,]+)\s*원', text.replace(',', ''))
                if price_match:
                    price = price_match.group(1)
                    break
            
            # 방법 2: 숫자만 있는 span 찾기 (형제 요소에 "원"이 있는 경우)
            if price == "0":
                all_spans = card_element.find_elements(By.TAG_NAME, "span")
                for span in all_spans:
                    try:
                        text = span.text.strip()
                        # 숫자만 있는 경우 (가격일 가능성)
                        if re.match(r'^[\d,]+$', text.replace(',', '')):
                            # 형제나 부모 요소에 "원"이 있는지 확인
                            try:
                                parent = span.find_element(By.XPATH, "./..")
                                parent_text = parent.text
                                if "원" in parent_text:
                                    price = text.replace(',', '')
                                    break
                            except:
                                pass
                    except:
                        continue
            
            # 방법 3: 전체 텍스트에서 가격 패턴 찾기
            if price == "0":
                card_text = card_element.text
                price_matches = re.findall(r'([\d,]+)\s*원', card_text.replace(',', ''))
                if price_matches:
                    # 가장 큰 숫자를 가격으로 (할인가가 원가보다 작을 수 있음)
                    price_candidates = [int(m.replace(',', '')) for m in price_matches if int(m.replace(',', '')) >= 100]
                    if price_candidates:
                        price = str(max(price_candidates))  # 가장 큰 값 (원가일 가능성)
        except Exception as e:
            logger.debug(f"가격 추출 중 오류: {e}")
        
        # 이미지 추출
        img_url = ""
        try:
            img_tags = card_element.find_elements(By.TAG_NAME, "img")
            for img in img_tags:
                src = img.get_attribute("src") or img.get_attribute("data-src") or img.get_attribute("data-img-src")
                if src and "kurly.com" in src:
                    img_url = src
                    if img_url.startswith('//'):
                        img_url = "https:" + img_url
                    break
        except Exception as e:
            logger.debug(f"이미지 추출 중 오류: {e}")
        
        return {
            '검색어': keyword,
            '상품명': product_name,
            '가격': price,
            '이미지': img_url,
            '상품인덱스': index,
            '수집시간': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            '링크': None  # 나중에 생성
        }
    except Exception as e:
        logger.warning(f"상품 정보 추출 실패: {e}")
        return None


def _generate_link_and_click_confirm(
    driver: uc.Chrome,
    link_button,
    product_index: int,
    wait: WebDriverWait
) -> Optional[str]:
    """
    링크 생성 버튼 클릭 → 링크 복사 대기 → 확인 버튼 클릭
    
    Args:
        driver: Chrome 드라이버
        link_button: 링크 생성 버튼 WebElement
        product_index: 상품 인덱스
        wait: WebDriverWait 객체
    
    Returns:
        Optional[str]: 생성된 링크 (실패 시 None)
    """
    try:
        # 1. 링크 생성 버튼 클릭
        logger.info(f"링크 생성 버튼 클릭 (상품 {product_index + 1}번째)...")
        driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", link_button)
        time.sleep(random.uniform(0.5, 1.0))
        link_button.click()
        
        # 2. 모달 대기 ("이미 생성된 링크가 복사됐습니다." 또는 "링크가 복사됐습니다.")
        logger.info("링크 복사 완료 모달 대기...")
        time.sleep(random.uniform(2, 3))
        
        # 모달 텍스트 확인 (5초 타임아웃)
        modal_found = False
        modal_wait = WebDriverWait(driver, 5)  # 짧은 타임아웃 사용
        modal_selectors = [
            (By.XPATH, '//*[contains(text(), "이미 생성된 링크가 복사됐습니다")]'),
            (By.XPATH, '//*[contains(text(), "링크가 복사됐습니다")]'),
        ]
        
        for by, selector in modal_selectors:
            try:
                modal = modal_wait.until(EC.presence_of_element_located((by, selector)))
                modal_text = modal.text
                if "링크" in modal_text and "복사" in modal_text:
                    modal_found = True
                    logger.info("링크 복사 완료 모달 확인됨")
                    break
            except TimeoutException:
                continue
        
        if not modal_found:
            logger.warning("모달을 찾을 수 없지만 계속 진행합니다...")
        
        # 3. 클립보드에서 링크 읽기
        time.sleep(random.uniform(0.5, 1.0))
        try:
            clipboard_text = pyperclip.paste()
            if clipboard_text and ("kurly.com" in clipboard_text or "kurlycorp.com" in clipboard_text):
                generated_link = clipboard_text.strip()
                logger.info(f"링크 생성 성공: {generated_link[:50]}...")
            else:
                logger.warning(f"클립보드 내용이 링크 형식이 아님: {clipboard_text[:50] if clipboard_text else 'None'}")
                return None
        except Exception as e:
            logger.warning(f"클립보드 읽기 실패: {e}")
            return None
        
        # 4. 확인 버튼 클릭
        confirm_button = None
        confirm_selectors = [
            (By.CSS_SELECTOR, 'button[aria-label="confirm-button"]'),
            (By.XPATH, '//button[contains(text(), "확인")]'),
            (By.XPATH, '//button[contains(@aria-label, "confirm")]'),
        ]
        
        for by, selector in confirm_selectors:
            try:
                confirm_button = wait.until(EC.element_to_be_clickable((by, selector)))
                logger.info("확인 버튼 발견")
                break
            except TimeoutException:
                continue
        
        if confirm_button:
            try:
                driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", confirm_button)
                time.sleep(random.uniform(0.3, 0.5))
                confirm_button.click()
                logger.info("확인 버튼 클릭 완료")
                time.sleep(random.uniform(1, 2))  # 모달 닫힘 대기
            except Exception as e:
                logger.warning(f"확인 버튼 클릭 실패: {e}")
        else:
            logger.warning("확인 버튼을 찾을 수 없습니다. 계속 진행합니다...")
        
        return generated_link
        
    except Exception as e:
        logger.error(f"링크 생성 및 확인 버튼 클릭 중 오류: {e}", exc_info=True)
        return None


def process_single_product(
    product_info: Dict[str, any],
    keyword: str,
    driver: Optional[uc.Chrome] = None,
    proxy: Optional[str] = None,
    headless: bool = True,
    save_to_firebase: bool = True,
    current_scraping_products: Optional[List[Dict[str, any]]] = None
) -> Optional[Dict[str, any]]:
    """
    단일 상품 처리: 링크 생성 + 정보 수집 + Firebase 저장
    
    Args:
        product_info: 저장할 상품 정보
        keyword: 검색어
        driver: 기존 드라이버
        proxy: 프록시 서버
        headless: 헤드리스 모드
        save_to_firebase: Firebase 저장 여부
        current_scraping_products: 재료별 새로 수집한 상품 목록 (덮어쓰기 모드용)
    
    Args:
        product_info: scrape_single_keyword에서 수집한 상품 정보
        keyword: 검색어
        driver: 기존 드라이버 (None이면 새로 생성)
        proxy: 프록시 서버
        headless: 헤드리스 모드
        save_to_firebase: Firebase 저장 여부
    
    Returns:
        Dict: 완전한 상품 정보 (링크 포함)
    """
    xvfb_process = None
    should_close_driver = False
    
    try:
        product_name = product_info.get('상품명', '')
        product_index = product_info.get('상품인덱스', 0)
        
        logger.info(f"상품 처리 시작: {product_name[:30]}... (인덱스: {product_index})")
        
        # 드라이버가 없으면 로그인
        if driver is None:
            login_success, driver, _, xvfb_process = login_to_kurly(
                headless=headless,
                proxy=proxy,
                save_cookies=True
            )
            
            if not login_success or driver is None:
                raise Exception("로그인 실패")
            
            should_close_driver = True
        
        # 검색 페이지로 이동
        driver.get("https://lounge.kurly.com/curator-program/main")
        time.sleep(random.uniform(3, 5))
        
        wait = WebDriverWait(driver, 30)
        
        # 검색 박스 클릭
        search_box = None
        search_box_selectors = [
            (By.XPATH, '//*[contains(text(), "상품명을 검색하세요")]'),
            (By.CSS_SELECTOR, 'div.css-w7q2y.e51pgzy1'),
            (By.CSS_SELECTOR, 'div[class*="css-w7q2y"]'),
            (By.CSS_SELECTOR, 'div[class*="e51pgzy1"]'),
        ]
        
        for by, selector in search_box_selectors:
            try:
                search_box = WebDriverWait(driver, 10).until(
                    EC.element_to_be_clickable((by, selector))
                )
                logger.info(f"검색 박스 발견: {selector}")
                break
            except TimeoutException:
                continue
        
        # 추가 시도: 텍스트 기반 검색
        if not search_box:
            try:
                text_elements = driver.find_elements(By.XPATH, '//*[contains(text(), "상품명을 검색하세요")]')
                for elem in text_elements:
                    try:
                        parent = elem
                        for _ in range(5):
                            try:
                                tag_name = parent.tag_name.lower()
                                if tag_name in ['div', 'span', 'button', 'a']:
                                    if parent.is_displayed() and parent.is_enabled():
                                        search_box = parent
                                        logger.info("텍스트 기반으로 검색 박스 발견")
                                        break
                            except:
                                pass
                            try:
                                parent = parent.find_element(By.XPATH, "./..")
                            except:
                                break
                        if search_box:
                            break
                    except:
                        continue
            except:
                pass
        
        if not search_box:
            raise Exception("검색 박스를 찾을 수 없습니다.")
        
        driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", search_box)
        time.sleep(random.uniform(0.5, 1.0))
        search_box.click()
        time.sleep(random.uniform(2, 3))
        
        # 검색어 입력
        search_input = None
        search_input_selectors = [
            (By.CSS_SELECTOR, 'input[type="search"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="상품명을 검색하세요"]'),
        ]
        
        for by, selector in search_input_selectors:
            try:
                search_input = wait.until(EC.presence_of_element_located((by, selector)))
                break
            except TimeoutException:
                continue
        
        if not search_input:
            raise Exception("검색 입력 필드를 찾을 수 없습니다.")
        
        search_input.clear()
        time.sleep(random.uniform(0.3, 0.5))
        _type_like_human(search_input, keyword)
        time.sleep(random.uniform(0.5, 1.0))
        search_input.send_keys(Keys.RETURN)
        
        # 검색 결과 대기
        time.sleep(random.uniform(3, 5))
        
        # 링크 생성 버튼 찾기 (특정 인덱스의 상품)
        link_buttons = []
        link_button_selectors = [
            (By.CSS_SELECTOR, 'div.css-42745x.e2pr8b1'),
            (By.XPATH, '//span[contains(text(), "링크 생성")]/ancestor::div[contains(@class, "css-42745x")]'),
        ]
        
        for by, selector in link_button_selectors:
            try:
                buttons = driver.find_elements(by, selector)
                if buttons:
                    visible_buttons = [btn for btn in buttons if btn.is_displayed()]
                    if visible_buttons:
                        link_buttons = visible_buttons
                        break
            except:
                continue
        
        if not link_buttons:
            # 텍스트 기반 검색
            try:
                link_spans = driver.find_elements(By.XPATH, '//span[contains(text(), "링크 생성")]')
                for span in link_spans:
                    try:
                        parent = span
                        for _ in range(5):
                            try:
                                parent = parent.find_element(By.XPATH, "./..")
                                classes = parent.get_attribute("class") or ""
                                if "css-42745x" in classes or "e2pr8b1" in classes:
                                    if parent.is_displayed():
                                        link_buttons.append(parent)
                                        break
                            except:
                                break
                    except:
                        continue
            except:
                pass
        
        if not link_buttons or product_index >= len(link_buttons):
            raise Exception(f"링크 생성 버튼을 찾을 수 없습니다. (인덱스: {product_index}, 버튼 수: {len(link_buttons)})")
        
        link_button = link_buttons[product_index]
        
        # 링크 생성 버튼 클릭
        driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", link_button)
        time.sleep(random.uniform(0.5, 1.0))
        link_button.click()
        
        # 링크 복사 완료 모달 대기
        time.sleep(random.uniform(2, 3))
        
        # 클립보드에서 링크 읽기
        time.sleep(random.uniform(0.5, 1.0))
        try:
            clipboard_text = pyperclip.paste()
            if clipboard_text and ("kurly.com" in clipboard_text or "kurlycorp.com" in clipboard_text):
                generated_link = clipboard_text.strip()
                logger.info(f"링크 생성 성공: {generated_link[:50]}...")
            else:
                raise Exception("클립보드에 유효한 링크가 없습니다.")
        except Exception as e:
            logger.warning(f"클립보드 읽기 실패: {e}")
            raise
        
        # 최종 상품 정보 구성
        final_product_info = product_info.copy()
        final_product_info['링크'] = generated_link
        
        # Firebase 저장
        if save_to_firebase:
            try:
                save_single_product_to_firebase(
                    keyword, 
                    final_product_info,
                    current_scraping_products=current_scraping_products
                )
            except Exception as e:
                logger.warning(f"Firebase 저장 실패: {e}")
        
        return final_product_info
        
    except Exception as e:
        logger.error(f"상품 처리 중 에러: {e}", exc_info=True)
        return None
    
    finally:
        if should_close_driver and driver:
            try:
                driver.quit()
            except:
                pass
        if xvfb_process:
            try:
                xvfb_process.terminate()
                xvfb_process.wait(timeout=5)
            except:
                pass


def save_single_product_to_firebase(
    keyword: str,
    product: Dict[str, any],
    collection_name: str = "kurly_products",
    current_scraping_products: Optional[List[Dict[str, any]]] = None
):
    """
    단일 상품을 Firebase에 저장 (재료별 새로 수집한 상품 목록만 유지, 기존 데이터 덮어쓰기)
    
    Args:
        keyword: 검색어
        product: 저장할 상품 정보
        collection_name: Firebase 컬렉션 이름
        current_scraping_products: 현재 스크래핑 중인 상품 목록 (재료별로 새로 수집한 목록)
    """
    firebase_service = get_firebase_service()
    
    if not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다.")
        return
    
    try:
        db = firebase_service.db
        if not db:
            return
        
        normalized_keyword = keyword.strip()
        doc_ref = db.collection(collection_name).document(normalized_keyword)
        
        # 상품 데이터 변환
        price_value = product.get('가격', 0)
        try:
            if isinstance(price_value, str):
                price_value = int(price_value) if price_value.isdigit() else 0
            elif not isinstance(price_value, int):
                price_value = int(price_value) if price_value else 0
        except (ValueError, TypeError):
            price_value = 0
        
        product_data = {
            'productName': product.get('상품명', ''),
            'price': price_value,
            'link': product.get('링크', ''),
            'imageUrl': product.get('이미지', ''),
        }
        
        # current_scraping_products가 제공된 경우 (재료별 새로 수집한 목록)
        # 재료별로 새로 수집한 상품 목록만 유지하고, 기존 데이터는 완전히 덮어쓰기
        if current_scraping_products is not None:
            # 기존 문서에서 현재 스크래핑 중인 상품 중 이미 처리된 것들 가져오기
            doc = doc_ref.get()
            processed_products = []
            
            # 재료별 새로 수집한 상품 목록의 상품명 집합 생성
            scraping_product_names = {p.get('상품명', '').strip() for p in current_scraping_products}
            
            if doc.exists:
                existing_data = doc.to_dict()
                existing_products = existing_data.get('products', [])
                
                # 기존 상품 중 현재 스크래핑 중인 상품만 필터링
                # (재료별로 새로 수집한 상품 목록에 속한 것만 유지)
                for existing_product in existing_products:
                    existing_name = existing_product.get('productName', '').strip()
                    # 현재 스크래핑 중인 상품 목록에 포함된 상품만 유지
                    if existing_name in scraping_product_names:
                        processed_products.append(existing_product)
            
            # 현재 처리된 상품 추가/업데이트
            product_link = product.get('링크', '')
            product_name = product.get('상품명', '').strip()
            
            # 현재 처리된 상품이 재료별 새 목록에 속하는지 확인
            if product_name not in scraping_product_names:
                logger.warning(f"처리 중인 상품이 재료별 새 목록에 없음: {product_name}")
            
            if product_link:
                # 같은 링크가 있으면 업데이트, 없으면 추가
                found = False
                for i, p in enumerate(processed_products):
                    if p.get('link') == product_link:
                        processed_products[i] = product_data
                        found = True
                        break
                if not found:
                    processed_products.append(product_data)
            else:
                # 링크가 없으면 상품명으로 매칭
                found = False
                for i, p in enumerate(processed_products):
                    if p.get('productName', '').strip() == product_name:
                        processed_products[i] = product_data
                        found = True
                        break
                if not found:
                    processed_products.append(product_data)
            
            # 재료별 새로 수집한 상품 목록만 저장 (기존 데이터 완전히 덮어쓰기)
            # 주의: 재료별로 새로 수집한 상품만 유지하고, 나머지는 모두 삭제
            doc_ref.set({
                'keyword': normalized_keyword,
                'products': processed_products,
                'lastUpdated': firestore.SERVER_TIMESTAMP,
                'productCount': len(processed_products)
            }, merge=False)
            
            logger.info(f"상품 저장 완료 (덮어쓰기 모드): {product.get('상품명', 'Unknown')[:30]}... (재료별 새 목록: {len(processed_products)}개)")
        else:
            # 기존 방식 (하위 호환성)
            doc = doc_ref.get()
            existing_data = doc.to_dict() if doc.exists else {}
            existing_products = existing_data.get('products', [])
            
            product_link = product.get('링크', '')
            if product_link:
                existing_links = [p.get('link', '') for p in existing_products]
                if product_link not in existing_links:
                    existing_products.append(product_data)
                else:
                    for i, p in enumerate(existing_products):
                        if p.get('link') == product_link:
                            existing_products[i] = product_data
                            break
            else:
                existing_products.append(product_data)
            
            doc_ref.set({
                'keyword': normalized_keyword,
                'products': existing_products,
                'lastUpdated': firestore.SERVER_TIMESTAMP,
                'productCount': len(existing_products)
            }, merge=False)
            
            logger.info(f"상품 저장 완료: {product.get('상품명', 'Unknown')[:30]}...")
        
    except Exception as e:
        logger.error(f"Firebase 저장 중 오류: {e}")
        raise


def generate_kurly_product_link(
    product_name: str,
    driver: Optional[uc.Chrome] = None,
    auto_login: bool = True,
    product_index: int = 0,
    headless: bool = False,
    proxy: Optional[str] = None
) -> Optional[str]:
    """
    컬리 상품 링크 생성 및 반환
    
    플로우:
    1. 로그인 (필요시)
    2. 대시보드에서 검색 박스 클릭
    3. 상품명 입력 및 검색
    4. 검색 결과에서 상품 선택
    5. 링크 생성 버튼 클릭
    6. 복사된 링크 추출 및 반환
    
    Args:
        product_name: 검색할 상품명
        driver: 기존 드라이버 객체 (None이면 새로 생성)
        auto_login: 자동 로그인 여부
        product_index: 선택할 상품 인덱스 (0: 첫 번째 상품)
        headless: 헤드리스 모드 여부
        proxy: 프록시 서버 (선택사항)
    
    Returns:
        Optional[str]: 생성된 상품 링크 (실패 시 None)
    """
    xvfb_process = None
    should_close_driver = False
    
    try:
        # 드라이버가 없으면 로그인부터 시작
        if driver is None:
            if not auto_login:
                raise ValueError("드라이버가 없고 auto_login이 False입니다. 드라이버를 제공하거나 auto_login=True로 설정하세요.")
            
            logger.info("자동 로그인 시작...")
            print(f"[KurlyLinkGen] Starting auto-login...", flush=True)
            
            login_success, driver, _, xvfb_process = login_to_kurly(
                headless=headless,
                proxy=proxy,
                save_cookies=True
            )
            
            if not login_success or driver is None:
                raise Exception("로그인 실패")
            
            should_close_driver = True
            logger.info("로그인 완료, 대시보드 확인 중...")
            print(f"[KurlyLinkGen] Login successful, checking dashboard...", flush=True)
            
            # 로그인 후 리다이렉트 대기
            time.sleep(random.uniform(2, 3))
            current_url = driver.current_url
            logger.info(f"로그인 후 현재 URL: {current_url}")
            
            # 대시보드가 아니면 직접 이동
            if "lounge.kurly.com" not in current_url or "curator-program" not in current_url:
                logger.info("대시보드 페이지로 이동 중...")
                print(f"[KurlyLinkGen] Navigating to dashboard page...", flush=True)
                driver.get("https://lounge.kurly.com/curator-program/main")
                time.sleep(random.uniform(3, 5))
        
        wait = WebDriverWait(driver, 30)
        
        # Step 1: 대시보드에서 검색 박스 찾기 및 클릭
        logger.info("검색 박스 찾는 중...")
        print(f"[KurlyLinkGen] Looking for search box...", flush=True)
        
        # 현재 페이지 정보 확인 (디버깅)
        current_url = driver.current_url
        page_title = driver.title
        logger.info(f"현재 URL: {current_url}")
        logger.info(f"페이지 제목: {page_title}")
        
        # 이미지 분석 결과: 검색 박스는 input이 아니라 클릭 가능한 div/span 요소
        # 구조: div.css-w7q2y.e51pgzy1 > span (텍스트: "상품명을 검색하세요")
        search_box_selectors = [
            # 텍스트 기반 선택자 (가장 확실)
            (By.XPATH, '//*[contains(text(), "상품명을 검색하세요")]'),
            (By.XPATH, '//span[contains(text(), "상품명을 검색하세요")]'),
            (By.XPATH, '//div[contains(text(), "상품명을 검색하세요")]'),
            # 클래스 기반 선택자 (이미지에서 확인된 클래스)
            (By.CSS_SELECTOR, 'div.css-w7q2y.e51pgzy1'),
            (By.CSS_SELECTOR, 'div[class*="css-w7q2y"]'),
            (By.CSS_SELECTOR, 'div[class*="e51pgzy1"]'),
            # 일반적인 input 선택자 (혹시 모를 경우)
            (By.CSS_SELECTOR, 'input[placeholder*="상품명을 검색하세요"]'),
            (By.CSS_SELECTOR, 'input[type="search"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="검색"]'),
            (By.XPATH, '//input[@placeholder="상품명을 검색하세요"]'),
            (By.XPATH, '//input[contains(@placeholder, "상품명")]'),
        ]
        
        search_box = None
        for by, selector in search_box_selectors:
            try:
                # 더 긴 대기 시간으로 시도
                search_box = WebDriverWait(driver, 10).until(
                    EC.element_to_be_clickable((by, selector))
                )
                logger.info(f"검색 박스 발견: {selector}")
                print(f"[KurlyLinkGen] Found search box: {selector}", flush=True)
                break
            except TimeoutException:
                logger.debug(f"선택자 실패: {selector}")
                continue
            except Exception as e:
                logger.debug(f"선택자 오류 {selector}: {e}")
                continue
        
        # 추가 시도: 텍스트를 포함하는 모든 클릭 가능한 요소 찾기
        if not search_box:
            try:
                logger.info("텍스트 기반으로 검색 박스 찾기 시도...")
                # "상품명을 검색하세요" 텍스트를 포함하는 요소 찾기
                text_elements = driver.find_elements(By.XPATH, '//*[contains(text(), "상품명을 검색하세요")]')
                logger.info(f"'상품명을 검색하세요' 텍스트를 포함하는 요소 {len(text_elements)}개 발견")
                
                for elem in text_elements:
                    try:
                        # 클릭 가능한 부모 요소 찾기
                        parent = elem
                        for _ in range(5):  # 최대 5단계 위로 올라가기
                            try:
                                tag_name = parent.tag_name.lower()
                                if tag_name in ['div', 'span', 'button', 'a']:
                                    # 클릭 가능한지 확인
                                    if parent.is_displayed() and parent.is_enabled():
                                        search_box = parent
                                        logger.info(f"클릭 가능한 부모 요소 발견: {tag_name}")
                                        break
                            except:
                                pass
                            
                            try:
                                parent = parent.find_element(By.XPATH, "./..")
                            except:
                                break
                        
                        if search_box:
                            break
                    except Exception as e:
                        logger.debug(f"요소 처리 중 오류: {e}")
                        continue
                
                # 여전히 없으면 모든 div/span 중에서 찾기
                if not search_box:
                    all_divs = driver.find_elements(By.TAG_NAME, "div")
                    logger.info(f"페이지에 {len(all_divs)}개의 div 요소 발견")
                    for div in all_divs:
                        try:
                            text = div.text
                            classes = div.get_attribute("class") or ""
                            if ("상품명" in text or "검색" in text) and ("css-w7q2y" in classes or "e51pgzy1" in classes):
                                if div.is_displayed() and div.is_enabled():
                                    search_box = div
                                    logger.info(f"div 요소로 검색 박스 발견: class={classes}")
                                    break
                        except:
                            continue
            except Exception as e:
                logger.warning(f"텍스트 기반 검색 실패: {e}")
        
        if not search_box:
            # 디버깅: 페이지 소스 일부 저장
            try:
                page_source_snippet = driver.page_source[:2000]
                logger.warning(f"페이지 소스 일부:\n{page_source_snippet}")
            except:
                pass
            raise Exception("검색 박스를 찾을 수 없습니다.")
        
        # 검색 박스가 보이도록 스크롤
        try:
            driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", search_box)
            time.sleep(random.uniform(0.5, 1.0))
        except:
            pass
        
        # 검색 박스 클릭
        logger.info("검색 박스 클릭...")
        print(f"[KurlyLinkGen] Clicking search box...", flush=True)
        
        # 스크롤하여 검색 박스가 보이도록
        try:
            driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", search_box)
            time.sleep(random.uniform(0.5, 1.0))
        except:
            pass
        
        search_box.click()
        time.sleep(random.uniform(2, 3))
        
        # 페이지 전환 대기 (검색 페이지로 이동)
        logger.info("검색 페이지 로딩 대기...")
        print(f"[KurlyLinkGen] Waiting for search page to load...", flush=True)
        time.sleep(random.uniform(3, 5))
        
        # URL 변경 확인
        current_url = driver.current_url
        logger.info(f"클릭 후 현재 URL: {current_url}")
        
        # Step 2: 검색어 입력
        logger.info(f"상품명 입력 중: {product_name}")
        print(f"[KurlyLinkGen] Typing product name: {product_name}", flush=True)
        
        # 검색 입력 필드 찾기 (검색 페이지의 실제 input 필드)
        search_input_selectors = [
            (By.CSS_SELECTOR, 'input[type="search"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="상품명을 검색하세요"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="검색"]'),
            (By.CSS_SELECTOR, 'input.css-dcz4un'),
            (By.XPATH, '//input[@type="search"]'),
            (By.XPATH, '//input[contains(@placeholder, "상품명")]'),
            (By.XPATH, '//form//input[@type="search"]'),
            (By.XPATH, '//form//input')
        ]
        
        search_input = None
        for by, selector in search_input_selectors:
            try:
                search_input = WebDriverWait(driver, 10).until(
                    EC.presence_of_element_located((by, selector))
                )
                logger.info(f"검색 입력 필드 발견: {selector}")
                print(f"[KurlyLinkGen] Found search input field: {selector}", flush=True)
                break
            except TimeoutException:
                continue
        
        # 여전히 없으면 모든 input 요소 중에서 찾기
        if not search_input:
            try:
                all_inputs = driver.find_elements(By.TAG_NAME, "input")
                logger.info(f"검색 페이지에 {len(all_inputs)}개의 input 요소 발견")
                for inp in all_inputs:
                    try:
                        placeholder = inp.get_attribute("placeholder") or ""
                        input_type = inp.get_attribute("type") or ""
                        if "상품명" in placeholder or "검색" in placeholder or input_type == "search":
                            if inp.is_displayed() and inp.is_enabled():
                                search_input = inp
                                logger.info(f"텍스트 기반으로 검색 입력 필드 발견: placeholder={placeholder}")
                                break
                    except:
                        continue
            except Exception as e:
                logger.warning(f"input 요소 검색 실패: {e}")
        
        if not search_input:
            raise Exception("검색 입력 필드를 찾을 수 없습니다.")
        
        # 검색어 입력
        search_input.clear()
        time.sleep(random.uniform(0.3, 0.5))
        _type_like_human(search_input, product_name)
        time.sleep(random.uniform(0.5, 1.0))
        
        # 엔터 키 입력
        logger.info("검색 실행 (엔터 키 입력)...")
        print(f"[KurlyLinkGen] Pressing Enter to search...", flush=True)
        search_input.send_keys(Keys.RETURN)
        
        # Step 3: 검색 결과 대기
        logger.info("검색 결과 로딩 대기...")
        print(f"[KurlyLinkGen] Waiting for search results...", flush=True)
        time.sleep(random.uniform(3, 5))
        
        # 검색 결과 페이지 확인
        current_url = driver.current_url
        logger.info(f"현재 URL: {current_url}")
        
        # Step 4: 상품 선택 및 링크 생성 버튼 찾기
        # 이미지 분석 결과: "링크 생성"은 <span> 안에 있고, 그 부모 <div class="css-42745x e2pr8b1">가 클릭 가능
        logger.info(f"상품 {product_index + 1}번째 항목의 링크 생성 버튼 찾는 중...")
        print(f"[KurlyLinkGen] Looking for '링크 생성' button on product {product_index + 1}...", flush=True)
        
        # 검색 결과 로딩 대기 (추가 대기)
        time.sleep(random.uniform(2, 3))
        
        # 링크 생성 요소 선택자 (이미지에서 확인된 HTML 구조 기반)
        link_button_selectors = [
            # 클래스 기반 (이미지에서 확인된 정확한 클래스)
            (By.CSS_SELECTOR, 'div.css-42745x.e2pr8b1'),
            (By.CSS_SELECTOR, 'div[class*="css-42745x"]'),
            (By.CSS_SELECTOR, 'div[class*="e2pr8b1"]'),
            # span의 부모 div 찾기
            (By.XPATH, '//span[contains(text(), "링크 생성")]/ancestor::div[contains(@class, "css-42745x")]'),
            (By.XPATH, '//span[contains(text(), "링크 생성")]/ancestor::div[contains(@class, "e2pr8b1")]'),
            (By.XPATH, '//span[contains(text(), "링크 생성")]/parent::div'),
            (By.XPATH, '//div[.//span[contains(text(), "링크 생성")]]'),
            # 일반적인 button 요소도 시도
            (By.XPATH, '//button[contains(text(), "링크 생성")]'),
            (By.XPATH, '//button[.//span[contains(text(), "링크 생성")]]'),
        ]
        
        # 모든 링크 생성 버튼 찾기
        link_buttons = []
        for by, selector in link_button_selectors:
            try:
                elements = driver.find_elements(by, selector)
                if elements:
                    # 표시되고 활성화된 요소만 필터링
                    visible_elements = []
                    for elem in elements:
                        try:
                            if elem.is_displayed():
                                # "링크 생성" 텍스트가 포함되어 있는지 확인
                                elem_text = elem.text.strip()
                                if "링크 생성" in elem_text:
                                    visible_elements.append(elem)
                        except:
                            continue
                    
                    if visible_elements:
                        link_buttons = visible_elements
                        logger.info(f"링크 생성 버튼 {len(visible_elements)}개 발견: {selector}")
                        print(f"[KurlyLinkGen] Found {len(visible_elements)} '링크 생성' buttons", flush=True)
                        break
            except Exception as e:
                logger.debug(f"선택자 {selector} 실패: {e}")
                continue
        
        # 추가 시도: "링크 생성" 텍스트를 포함하는 span의 부모 div 찾기
        if not link_buttons:
            try:
                logger.info("'링크 생성' 텍스트를 포함하는 span 요소 검색 중...")
                link_spans = driver.find_elements(By.XPATH, '//span[contains(text(), "링크 생성")]')
                logger.info(f"'링크 생성' 텍스트를 포함하는 span {len(link_spans)}개 발견")
                
                for span in link_spans:
                    try:
                        if span.is_displayed():
                            # 부모 div 찾기 (최대 5단계 위로)
                            parent = span
                            for _ in range(5):
                                try:
                                    parent = parent.find_element(By.XPATH, "./..")
                                    tag_name = parent.tag_name.lower()
                                    classes = parent.get_attribute("class") or ""
                                    
                                    # css-42745x 또는 e2pr8b1 클래스를 가진 div 찾기
                                    if tag_name == "div" and ("css-42745x" in classes or "e2pr8b1" in classes):
                                        if parent.is_displayed():
                                            link_buttons.append(parent)
                                            logger.info(f"부모 div 발견: class={classes}")
                                            break
                                except:
                                    break
                            
                            if link_buttons:
                                break
                    except Exception as e:
                        logger.debug(f"span 처리 중 오류: {e}")
                        continue
                
                if link_buttons:
                    logger.info(f"span 기반으로 링크 생성 버튼 {len(link_buttons)}개 발견")
                    print(f"[KurlyLinkGen] Found {len(link_buttons)} buttons via span search", flush=True)
            except Exception as e:
                logger.warning(f"span 기반 검색 실패: {e}")
        
        # 마지막 시도: 모든 div 요소 중에서 찾기
        if not link_buttons:
            try:
                logger.info("모든 div 요소에서 '링크 생성' 검색 중...")
                all_divs = driver.find_elements(By.TAG_NAME, "div")
                logger.info(f"페이지에 {len(all_divs)}개의 div 요소 발견")
                
                for div in all_divs:
                    try:
                        if div.is_displayed():
                            div_text = div.text.strip()
                            classes = div.get_attribute("class") or ""
                            
                            # "링크 생성" 텍스트가 있고, 클릭 가능한 div
                            if "링크 생성" in div_text and ("css-42745x" in classes or "e2pr8b1" in classes):
                                link_buttons.append(div)
                                logger.info(f"div 요소로 버튼 발견: class={classes}")
                    except Exception as e:
                        logger.debug(f"div 처리 중 오류: {e}")
                        continue
                
                if link_buttons:
                    logger.info(f"div 기반으로 링크 생성 버튼 {len(link_buttons)}개 발견")
                    print(f"[KurlyLinkGen] Found {len(link_buttons)} buttons via div search", flush=True)
            except Exception as e:
                logger.warning(f"div 기반 검색 실패: {e}")
        
        if not link_buttons:
            # 디버깅: 페이지 소스 일부 확인
            try:
                page_source_snippet = driver.page_source
                if "링크 생성" in page_source_snippet:
                    logger.warning("페이지에 '링크 생성' 텍스트는 있지만 요소를 찾을 수 없습니다.")
                    # "링크 생성" 텍스트 위치 찾기
                    idx = page_source_snippet.find("링크 생성")
                    if idx > 0:
                        snippet = page_source_snippet[max(0, idx-300):idx+300]
                        logger.warning(f"'링크 생성' 주변 HTML:\n{snippet}")
            except:
                pass
            raise Exception("링크 생성 버튼을 찾을 수 없습니다.")
        
        # 인덱스 범위 확인
        if product_index >= len(link_buttons):
            logger.warning(f"요청한 인덱스 {product_index}가 범위를 벗어남. 첫 번째 상품 사용.")
            product_index = 0
        
        link_button = link_buttons[product_index]
        
        # 링크 생성 버튼 클릭
        logger.info(f"링크 생성 버튼 클릭 (상품 {product_index + 1}번째)...")
        print(f"[KurlyLinkGen] Clicking '링크 생성' button...", flush=True)
        
        # 스크롤하여 버튼이 보이도록
        driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", link_button)
        time.sleep(random.uniform(0.5, 1.0))
        
        link_button.click()
        
        # Step 5: 링크 복사 완료 모달 대기
        logger.info("링크 복사 완료 모달 대기...")
        print(f"[KurlyLinkGen] Waiting for 'Link copied' modal...", flush=True)
        time.sleep(random.uniform(2, 3))
        
        # 모달 확인
        modal_selectors = [
            (By.XPATH, '//*[contains(text(), "링크가 복사됐습니다")]'),
            (By.XPATH, '//*[contains(text(), "링크가 복사")]'),
            (By.XPATH, '//*[contains(text(), "복사됐습니다")]'),
            (By.CSS_SELECTOR, '[class*="modal"]'),
            (By.CSS_SELECTOR, '[class*="dialog"]')
        ]
        
        modal_found = False
        for by, selector in modal_selectors:
            try:
                modal = wait.until(EC.presence_of_element_located((by, selector)))
                modal_text = modal.text
                if "링크" in modal_text and "복사" in modal_text:
                    modal_found = True
                    logger.info("링크 복사 완료 모달 확인됨")
                    print(f"[KurlyLinkGen] 'Link copied' modal found!", flush=True)
                    break
            except TimeoutException:
                continue
        
        if not modal_found:
            logger.warning("모달을 찾을 수 없지만 계속 진행합니다...")
        
        # Step 6: 링크 추출
        logger.info("클립보드에서 링크 읽는 중...")
        print(f"[KurlyLinkGen] Reading link from clipboard...", flush=True)
        
        time.sleep(random.uniform(0.5, 1.0))  # 클립보드 복사 대기
        
        try:
            # 클립보드에서 링크 읽기
            clipboard_text = pyperclip.paste()
            
            # 링크 형식 확인 (kurly.com 또는 kurlycorp.com 포함)
            if clipboard_text and ("kurly.com" in clipboard_text or "kurlycorp.com" in clipboard_text):
                product_link = clipboard_text.strip()
                logger.info(f"링크 추출 성공: {product_link[:80]}...")
                print(f"[KurlyLinkGen] Link extracted successfully!", flush=True)
                return product_link
            else:
                logger.warning(f"클립보드 내용이 링크 형식이 아님: {clipboard_text[:50] if clipboard_text else 'None'}")
        except Exception as e:
            logger.warning(f"클립보드 읽기 실패: {e}")
        
        # 클립보드 방법 실패 시, 버튼의 data 속성에서 링크 찾기 시도
        logger.info("대체 방법: 버튼의 data 속성에서 링크 찾기 시도...")
        try:
            # 링크 생성 버튼의 부모 요소나 형제 요소에서 링크 찾기
            parent = link_button.find_element(By.XPATH, "./ancestor::a | ./ancestor::div[contains(@class, 'product')]")
            link_elem = parent.find_elements(By.TAG_NAME, "a")
            if link_elem:
                href = link_elem[0].get_attribute("href")
                if href and ("kurly.com" in href or "kurlycorp.com" in href):
                    logger.info(f"대체 방법으로 링크 추출: {href[:80]}...")
                    return href
        except Exception as e:
            logger.debug(f"대체 방법 실패: {e}")
        
        raise Exception("링크를 추출할 수 없습니다.")
        
    except Exception as e:
        logger.error(f"상품 링크 생성 중 에러: {e}", exc_info=True)
        print(f"[KurlyLinkGen] ERROR: {e}", flush=True)
        return None
    
    finally:
        # 드라이버 종료 (자동 로그인으로 생성한 경우만)
        if should_close_driver and driver:
            try:
                driver.quit()
                logger.info("드라이버 종료 완료")
            except Exception as e:
                logger.warning(f"드라이버 종료 중 오류: {e}")
        
        # Xvfb 프로세스 정리
        if xvfb_process:
            try:
                xvfb_process.terminate()
                xvfb_process.wait(timeout=5)
            except Exception as e:
                logger.warning(f"Xvfb 프로세스 종료 중 오류: {e}")


def _check_session_valid(driver: uc.Chrome) -> bool:
    """
    현재 세션이 유효한지 확인 (로그인 상태 유지 여부)
    
    Args:
        driver: Chrome 드라이버
    
    Returns:
        bool: 세션이 유효하면 True, 만료되었으면 False
    """
    try:
        # 현재 URL 확인
        current_url = driver.current_url
        
        # 로그인 페이지로 리다이렉트되었는지 확인
        if "member/login" in current_url or "login" in current_url.lower():
            logger.warning("세션 만료 감지: 로그인 페이지로 리다이렉트됨")
            return False
        
        # 쿠키 확인
        cookies = driver.get_cookies()
        auth_cookies = [c for c in cookies if any(key in c.get('name', '').lower() for key in ['session', 'auth', 'login', 'user', 'member'])]
        
        if not auth_cookies:
            logger.warning("세션 만료 감지: 인증 쿠키가 없음")
            return False
        
        # 페이지 소스에서 로그인 관련 메시지 확인
        page_source = driver.page_source.lower()
        if any(keyword in page_source for keyword in ["로그인이 필요합니다", "login required", "세션이 만료", "session expired"]):
            logger.warning("세션 만료 감지: 페이지에 만료 메시지 발견")
            return False
        
        return True
    except Exception as e:
        logger.warning(f"세션 유효성 확인 중 오류: {e}")
        return False


def _refresh_session_if_needed(
    driver: Optional[uc.Chrome],
    proxy: Optional[str] = None,
    headless: bool = False,
    xvfb_process: Optional[subprocess.Popen] = None,
    login_method: str = "default"
) -> Tuple[Optional[uc.Chrome], Optional[subprocess.Popen], bool]:
    """
    세션이 만료되었으면 재로그인하여 세션 갱신
    
    Args:
        driver: 기존 Chrome 드라이버 (None이면 새로 생성)
        proxy: 프록시 서버
        headless: 헤드리스 모드
        xvfb_process: 기존 Xvfb 프로세스
        login_method: 로그인 방법 ("main_page", "welcome_page", "direct", "default")
    
    Returns:
        Tuple[Optional[uc.Chrome], Optional[subprocess.Popen], bool]: 
        (드라이버, Xvfb 프로세스, 재로그인 성공 여부)
    """
    try:
        # 드라이버가 없거나 세션이 만료되었으면 재로그인
        if driver is None or not _check_session_valid(driver):
            logger.info(f"세션 갱신 필요: 재로그인 시작 (방법: {login_method})...")
            
            # 기존 드라이버 종료
            if driver:
                try:
                    driver.quit()
                except:
                    pass
            
            # Xvfb 프로세스 종료
            if xvfb_process:
                try:
                    xvfb_process.terminate()
                    xvfb_process.wait(timeout=5)
                except:
                    try:
                        xvfb_process.kill()
                    except:
                        pass
            
            # 재로그인 (블록별 로그인 방법 사용)
            login_success, new_driver, _, new_xvfb_process = login_to_kurly(
                headless=headless,
                proxy=proxy,
                save_cookies=True,
                login_method=login_method
            )
            
            if not login_success or new_driver is None:
                logger.error("세션 갱신 실패: 재로그인 실패")
                return None, None, False
            
            logger.info("세션 갱신 완료: 재로그인 성공")
            return new_driver, new_xvfb_process, True
        
        # 세션이 유효하면 그대로 반환
        logger.debug("세션 유효: 재로그인 불필요")
        return driver, xvfb_process, True
        
    except Exception as e:
        logger.error(f"세션 갱신 중 오류: {e}", exc_info=True)
        return None, None, False


def scrape_single_keyword(
    keyword: str, 
    proxy: Optional[str] = None, 
    save_to_file: bool = False,
    save_to_firebase: bool = False,  # 스케줄러에서 저장하므로 기본값 False
    output_dir: str = ".",
    max_products: int = 20,
    headless: bool = False,
    driver: Optional[uc.Chrome] = None,  # 기존 드라이버 재사용 (세션 유지용)
    xvfb_process: Optional[subprocess.Popen] = None  # 기존 Xvfb 프로세스 재사용
) -> Tuple[List[Dict[str, any]], Optional[uc.Chrome], Optional[subprocess.Popen]]:
    """
    재료별로 한 번에 모든 작업 완료:
    1. 로그인 (드라이버가 없거나 세션 만료 시)
    2. 재료명으로 검색
    3. 20개 상품 카드 수집 (상품명, 가격, 이미지)
    4. 각 상품마다 링크 생성 (같은 세션)
    5. 링크 생성 후 확인 버튼 클릭
    6. 20개 모두 완료 후 반환
    
    Args:
        keyword: 검색할 식재료명
        proxy: 프록시 서버 (예: "proxy_ip:port" 또는 None)
        save_to_file: 결과를 파일에 저장할지 여부
        save_to_firebase: 결과를 Firebase에 저장할지 여부 (기본값 False, 스케줄러에서 저장)
        output_dir: 결과 파일 저장 디렉토리 (기본: 현재 디렉토리)
        max_products: 최대 수집할 상품 수 (기본: 20개)
        headless: 헤드리스 모드 여부
        driver: 기존 드라이버 (세션 유지용, None이면 새로 생성)
        xvfb_process: 기존 Xvfb 프로세스 (세션 유지용)
    
    Returns:
        Tuple[List[Dict[str, any]], Optional[uc.Chrome], Optional[subprocess.Popen]]: 
        (상품 정보 리스트, 드라이버, Xvfb 프로세스) - 드라이버와 프로세스를 반환하여 재사용 가능
    """
    results = []
    
    try:
        logger.info(f"'{keyword}' 검색 및 상품 수집 시작 (최대 {max_products}개, 링크 생성 포함)")
        print(f"[KurlyService] Starting product collection with link generation for keyword: {keyword}", flush=True)
        
        # 세션 확인 및 갱신 (필요시)
        driver, xvfb_process, session_valid = _refresh_session_if_needed(
            driver, proxy, headless, xvfb_process
        )
        
        if not session_valid or driver is None:
            raise Exception("세션 갱신 실패")
        
        logger.info("세션 확인 완료, 검색 페이지로 이동")
        
        # 대시보드로 이동
        driver.get("https://lounge.kurly.com/curator-program/main")
        time.sleep(random.uniform(3, 5))
        
        wait = WebDriverWait(driver, 30)
        
        # 검색 박스 찾기 및 클릭
        logger.info("검색 박스 찾는 중...")
        search_box_selectors = [
            (By.XPATH, '//*[contains(text(), "상품명을 검색하세요")]'),
            (By.CSS_SELECTOR, 'div.css-w7q2y.e51pgzy1'),
            (By.CSS_SELECTOR, 'div[class*="css-w7q2y"]'),
        ]
        
        search_box = None
        for by, selector in search_box_selectors:
            try:
                search_box = WebDriverWait(driver, 10).until(
                    EC.element_to_be_clickable((by, selector))
                )
                logger.info(f"검색 박스 발견: {selector}")
                break
            except TimeoutException:
                continue
        
        if not search_box:
            # 텍스트 기반으로 찾기
            try:
                text_elements = driver.find_elements(By.XPATH, '//*[contains(text(), "상품명을 검색하세요")]')
                for elem in text_elements:
                    try:
                        parent = elem
                        for _ in range(5):
                            try:
                                tag_name = parent.tag_name.lower()
                                if tag_name in ['div', 'span', 'button', 'a']:
                                    if parent.is_displayed() and parent.is_enabled():
                                        search_box = parent
                                        break
                            except:
                                pass
                            try:
                                parent = parent.find_element(By.XPATH, "./..")
                            except:
                                break
                        if search_box:
                            break
                    except:
                        continue
            except:
                pass
        
        if not search_box:
            raise Exception("검색 박스를 찾을 수 없습니다.")
        
        # 검색 박스 클릭
        driver.execute_script("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", search_box)
        time.sleep(random.uniform(0.5, 1.0))
        search_box.click()
        time.sleep(random.uniform(2, 3))
        
        # 검색어 입력
        search_input_selectors = [
            (By.CSS_SELECTOR, 'input[type="search"]'),
            (By.CSS_SELECTOR, 'input[placeholder*="상품명을 검색하세요"]'),
        ]
        
        search_input = None
        for by, selector in search_input_selectors:
            try:
                search_input = wait.until(EC.presence_of_element_located((by, selector)))
                break
            except TimeoutException:
                continue
        
        if not search_input:
            raise Exception("검색 입력 필드를 찾을 수 없습니다.")
        
        search_input.clear()
        time.sleep(random.uniform(0.3, 0.5))
        _type_like_human(search_input, keyword)
        time.sleep(random.uniform(0.5, 1.0))
        search_input.send_keys(Keys.RETURN)
        
        # 검색 결과 대기
        logger.info("검색 결과 로딩 대기...")
        time.sleep(random.uniform(3, 5))
        
        # 상품 카드 찾기 (div.css-henp6x.e2pr8b0)
        logger.info("상품 카드 찾는 중...")
        product_card_selectors = [
            (By.CSS_SELECTOR, 'div.css-henp6x.e2pr8b0'),
            (By.CSS_SELECTOR, 'div[class*="css-henp6x"]'),
            (By.CSS_SELECTOR, 'div[class*="e2pr8b0"]'),
        ]
        
        product_cards = []
        for by, selector in product_card_selectors:
            try:
                cards = driver.find_elements(by, selector)
                if cards:
                    product_cards = cards[:max_products]  # 최대 개수 제한
                    logger.info(f"상품 카드 {len(product_cards)}개 발견: {selector}")
                    break
            except Exception as e:
                logger.debug(f"선택자 {selector} 실패: {e}")
                continue
        
        if not product_cards:
            # 대체 방법: 모든 div 중에서 찾기
            try:
                all_divs = driver.find_elements(By.TAG_NAME, "div")
                for div in all_divs:
                    try:
                        classes = div.get_attribute("class") or ""
                        if "css-henp6x" in classes or "e2pr8b0" in classes:
                            if div.is_displayed():
                                product_cards.append(div)
                                if len(product_cards) >= max_products:
                                    break
                    except:
                        continue
                logger.info(f"대체 방법으로 상품 카드 {len(product_cards)}개 발견")
            except Exception as e:
                logger.warning(f"상품 카드 검색 실패: {e}")
        
        if not product_cards:
            raise Exception("상품 카드를 찾을 수 없습니다.")
        
        # 각 상품 카드에서 정보 추출 및 링크 생성
        logger.info(f"상품 정보 추출 및 링크 생성 시작 ({len(product_cards)}개)...")
        
        # 링크 생성 버튼 찾기 (한 번만 찾고 재사용)
        link_buttons = []
        link_button_selectors = [
            (By.CSS_SELECTOR, 'div.css-42745x.e2pr8b1'),
            (By.XPATH, '//span[contains(text(), "링크 생성")]/ancestor::div[contains(@class, "css-42745x")]'),
        ]
        
        for by, selector in link_button_selectors:
            try:
                buttons = driver.find_elements(by, selector)
                if buttons:
                    visible_buttons = [btn for btn in buttons if btn.is_displayed()]
                    if visible_buttons:
                        link_buttons = visible_buttons[:max_products]
                        logger.info(f"링크 생성 버튼 {len(link_buttons)}개 발견")
                        break
            except:
                continue
        
        if not link_buttons:
            # 텍스트 기반 검색
            try:
                link_spans = driver.find_elements(By.XPATH, '//span[contains(text(), "링크 생성")]')
                for span in link_spans:
                    try:
                        parent = span
                        for _ in range(5):
                            try:
                                parent = parent.find_element(By.XPATH, "./..")
                                classes = parent.get_attribute("class") or ""
                                if "css-42745x" in classes or "e2pr8b1" in classes:
                                    if parent.is_displayed():
                                        link_buttons.append(parent)
                                        if len(link_buttons) >= max_products:
                                            break
                            except:
                                break
                        if len(link_buttons) >= max_products:
                            break
                    except:
                        continue
            except:
                pass
        
        if not link_buttons:
            logger.warning("링크 생성 버튼을 찾을 수 없습니다. 정보만 수집합니다.")
        
        # 각 상품 처리
        for idx, card in enumerate(product_cards):
            try:
                # 1. 상품 정보 추출
                product_info = _extract_product_info_from_card(driver, card, keyword, idx)
                if not product_info:
                    continue
                
                # 2. 링크 생성 (버튼이 있는 경우)
                if idx < len(link_buttons):
                    try:
                        generated_link = _generate_link_and_click_confirm(
                            driver, 
                            link_buttons[idx], 
                            idx, 
                            wait
                        )
                        if generated_link:
                            product_info['링크'] = generated_link
                            logger.info(f"상품 {idx+1}/{len(product_cards)}: {product_info.get('상품명', 'Unknown')[:30]}... (링크 생성 완료)")
                        else:
                            logger.warning(f"상품 {idx+1}/{len(product_cards)}: 링크 생성 실패")
                    except Exception as e:
                        logger.warning(f"상품 {idx+1} 링크 생성 중 오류: {e}")
                
                results.append(product_info)
                
            except Exception as e:
                logger.warning(f"상품 {idx+1} 처리 실패: {e}")
                continue
        
        logger.info(f"총 {len(results)}개 상품 정보 수집 완료 (링크 포함: {sum(1 for r in results if r.get('링크'))}개)")
        
        # 파일 저장 (선택사항)
        if save_to_file and results:
            date_str = datetime.now().strftime('%Y%m%d')
            file_name = f"{output_dir}/kurly_results_{date_str}.xlsx"
            try:
                df = pd.DataFrame(results)
                df.to_excel(file_name, index=False)
                logger.info(f"결과 저장: {file_name}")
            except Exception as e:
                logger.warning(f"파일 저장 실패: {e}")
        
        # Firebase 저장 (선택사항, 스케줄러에서 저장하는 경우 False)
        if save_to_firebase and results:
            try:
                save_products_to_firebase(keyword, results)
            except Exception as e:
                logger.warning(f"Firebase 저장 실패: {e}")
        
        # 드라이버와 프로세스를 반환하여 재사용 가능하도록 함
        return results, driver, xvfb_process
        
    except Exception as e:
        logger.error(f"'{keyword}' 크롤링 중 에러: {e}", exc_info=True)
        print(f"[KurlyService] ERROR: {e}", flush=True)
        # 에러 발생 시에도 드라이버는 반환 (재시도 가능)
        return [], driver, xvfb_process
    finally:
        # 스케줄러에서 재사용하므로 여기서는 종료하지 않음
        # 드라이버와 프로세스는 스케줄러에서 관리
        pass


def save_products_to_firebase(keyword: str, products: List[Dict[str, any]], collection_name: str = "kurly_products"):
    """
    마켓컬리 크롤링 결과를 Firebase에 저장 (검색어별 하나의 문서, 덮어쓰기)
    
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
        db = firebase_service.db
        if not db:
            logger.warning("Firestore 클라이언트가 없습니다.")
            return
        
        # 상품 데이터 변환
        products_data = []
        for product in products:
            try:
                # 가격 정보 파싱
                price_value = product.get('가격', 0)
                try:
                    if isinstance(price_value, str):
                        price_value = int(price_value) if price_value.isdigit() else 0
                    elif not isinstance(price_value, int):
                        price_value = int(price_value) if price_value else 0
                except (ValueError, TypeError):
                    price_value = 0
                
                # 리뷰 수 파싱 (마켓컬리는 별점 없음)
                reviews_value = product.get('리뷰수', '0')
                try:
                    reviews_value = int(reviews_value) if str(reviews_value).isdigit() else 0
                except (ValueError, TypeError):
                    reviews_value = 0
                
                product_data = {
                    'productName': product.get('상품명', ''),
                    'price': price_value,
                    'originalPrice': product.get('원가'),
                    'discountRate': product.get('할인율'),
                    'reviews': reviews_value,
                    'couponInfo': product.get('쿠폰정보', ''),
                    'deliveryInfo': product.get('배송정보', ''),
                    'isFreeShipping': bool(product.get('무료배송', False)),
                    'link': product.get('링크', ''),
                    'imageUrl': product.get('이미지', ''),
                }
                products_data.append(product_data)
            except Exception as e:
                logger.warning(f"상품 변환 중 오류 (상품명: {product.get('상품명', 'unknown')}): {e}")
                continue
        
        # 문서 ID는 검색어 이름 사용 (검색어를 그대로 사용)
        # 검색어가 비어있거나 None이면 에러
        if not keyword or not keyword.strip():
            logger.error("검색어가 비어있어 Firebase 저장을 건너뜁니다.")
            return
        
        # 검색어 정규화 (공백 제거)
        normalized_keyword = keyword.strip()
        
        doc_ref = db.collection(collection_name).document(normalized_keyword)
        
        # 완전히 덮어쓰기 (검색어를 명시적으로 저장)
        doc_ref.set({
            'keyword': normalized_keyword,  # 검색어를 명시적으로 저장
            'products': products_data,
            'scrapedAt': firestore.SERVER_TIMESTAMP,
            'lastUpdated': firestore.SERVER_TIMESTAMP,
            'productCount': len(products_data)
        }, merge=False)
        
        logger.info(f"'{normalized_keyword}' 스크래핑 결과 저장 완료: {len(products_data)}개 상품 (덮어쓰기)")
        
        # 검색어별 요약 정보도 저장
        try:
            summary_ref = db.collection("kurly_scraping_summary").document(normalized_keyword)
            summary_ref.set({
                'keyword': normalized_keyword,  # 검색어를 명시적으로 저장
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
    collection_name: str = "kurly_products",
    limit: int = 100
) -> List[Dict[str, any]]:
    """
    Firebase에서 마켓컬리 상품 데이터 조회
    
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
        
        logger.info(f"Firebase에서 {len(products)}개 상품 조회 (검색어: {keyword or '전체'})")
        return products
        
    except Exception as e:
        logger.error(f"Firebase 조회 중 오류: {e}")
        return []
    """
    마켓컬리 크롤링 결과를 Firebase에 저장 (검색어별 하나의 문서, 덮어쓰기)
    
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
        db = firebase_service.db
        if not db:
            logger.warning("Firestore 클라이언트가 없습니다.")
            return
        
        # 상품 데이터 변환
        products_data = []
        for product in products:
            try:
                # 가격 정보 파싱
                price_value = product.get('가격', 0)
                try:
                    if isinstance(price_value, str):
                        price_value = int(price_value) if price_value.isdigit() else 0
                    elif not isinstance(price_value, int):
                        price_value = int(price_value) if price_value else 0
                except (ValueError, TypeError):
                    price_value = 0
                
                # 리뷰 수 파싱 (마켓컬리는 별점 없음)
                reviews_value = product.get('리뷰수', '0')
                try:
                    reviews_value = int(reviews_value) if str(reviews_value).isdigit() else 0
                except (ValueError, TypeError):
                    reviews_value = 0
                
                product_data = {
                    'productName': product.get('상품명', ''),
                    'price': price_value,
                    'originalPrice': product.get('원가'),
                    'discountRate': product.get('할인율'),
                    'reviews': reviews_value,
                    'couponInfo': product.get('쿠폰정보', ''),
                    'deliveryInfo': product.get('배송정보', ''),
                    'isFreeShipping': bool(product.get('무료배송', False)),
                    'link': product.get('링크', ''),
                    'imageUrl': product.get('이미지', ''),
                }
                products_data.append(product_data)
            except Exception as e:
                logger.warning(f"상품 변환 중 오류 (상품명: {product.get('상품명', 'unknown')}): {e}")
                continue
        
        # 문서 ID는 검색어 이름 사용 (검색어를 그대로 사용)
        # 검색어가 비어있거나 None이면 에러
        if not keyword or not keyword.strip():
            logger.error("검색어가 비어있어 Firebase 저장을 건너뜁니다.")
            return
        
        # 검색어 정규화 (공백 제거)
        normalized_keyword = keyword.strip()
        
        doc_ref = db.collection(collection_name).document(normalized_keyword)
        
        # 완전히 덮어쓰기 (검색어를 명시적으로 저장)
        doc_ref.set({
            'keyword': normalized_keyword,  # 검색어를 명시적으로 저장
            'products': products_data,
            'scrapedAt': firestore.SERVER_TIMESTAMP,
            'lastUpdated': firestore.SERVER_TIMESTAMP,
            'productCount': len(products_data)
        }, merge=False)
        
        logger.info(f"'{normalized_keyword}' 스크래핑 결과 저장 완료: {len(products_data)}개 상품 (덮어쓰기)")
        
        # 검색어별 요약 정보도 저장
        try:
            summary_ref = db.collection("kurly_scraping_summary").document(normalized_keyword)
            summary_ref.set({
                'keyword': normalized_keyword,  # 검색어를 명시적으로 저장
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
    collection_name: str = "kurly_products",
    limit: int = 100
) -> List[Dict[str, any]]:
    """
    Firebase에서 마켓컬리 상품 데이터 조회
    
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
        
        logger.info(f"Firebase에서 {len(products)}개 상품 조회 (검색어: {keyword or '전체'})")
        return products
        
    except Exception as e:
        logger.error(f"Firebase 조회 중 오류: {e}")
        return []
