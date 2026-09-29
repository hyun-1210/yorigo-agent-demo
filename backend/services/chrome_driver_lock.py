"""
Chrome 드라이버 초기화 락 모듈 (파일 기반)
쿠팡과 컬리 스케줄러가 동시에 Chrome 드라이버를 초기화할 때 충돌 방지
프로세스 간 동기화를 위해 파일 기반 락 사용
"""
import os
import sys
import tempfile
import time
from contextlib import contextmanager

# 파일 기반 락 사용 (프로세스 간 동기화 가능)
_chrome_driver_lock_file_path = os.path.join(
    tempfile.gettempdir(), 
    "yorigo_chrome_driver_init.lock"
)

@contextmanager
def chrome_driver_lock(timeout: float = 300.0, retry_interval: float = 1.0):
    """
    Chrome 드라이버 초기화를 위한 파일 기반 락 컨텍스트 매니저
    
    Args:
        timeout: 락 획득 최대 대기 시간 (초)
        retry_interval: 락 획득 재시도 간격 (초)
    
    Yields:
        None (락 획득 성공 시)
    
    Raises:
        TimeoutError: 락 획득 실패 시
    """
    import logging
    logger = logging.getLogger(__name__)
    
    lock_acquired = False
    lock_file = None
    start_time = time.time()
    
    try:
        # 락 획득 시도 (타임아웃까지 재시도)
        while time.time() - start_time < timeout:
            try:
                if sys.platform == 'win32':
                    # Windows: exclusive file creation
                    try:
                        lock_file = open(_chrome_driver_lock_file_path, 'x')
                        lock_acquired = True
                        break
                    except FileExistsError:
                        # 다른 프로세스가 락을 보유 중
                        pass
                else:
                    # Unix: fcntl 사용
                    import fcntl
                    try:
                        lock_file = open(_chrome_driver_lock_file_path, 'w')
                        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        lock_acquired = True
                        break
                    except (IOError, BlockingIOError):
                        # 다른 프로세스가 락을 보유 중
                        if lock_file:
                            lock_file.close()
                            lock_file = None
                
                # 락 획득 실패 시 재시도
                time.sleep(retry_interval)
                
            except Exception as e:
                # 예상치 못한 오류 발생 시 재시도
                if lock_file:
                    try:
                        lock_file.close()
                    except:
                        pass
                    lock_file = None
                logger.warning(f"Chrome 드라이버 락 획득 중 오류: {e}")
                time.sleep(retry_interval)
        
        if not lock_acquired:
            raise TimeoutError(
                f"Chrome 드라이버 초기화 락 획득 실패 (timeout: {timeout}초). "
                f"다른 프로세스가 Chrome 드라이버를 초기화 중일 수 있습니다."
            )
        
        # PID 기록 (디버깅용)
        lock_file.write(str(os.getpid()))
        lock_file.flush()
        
        # 락 획득 성공
        yield
        
    finally:
        # 락 해제
        if lock_file:
            try:
                lock_file.close()
                if lock_acquired:
                    try:
                        os.remove(_chrome_driver_lock_file_path)
                    except:
                        pass
            except:
                pass

