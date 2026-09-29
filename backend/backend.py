import os
import tempfile
from typing import List, Optional, Dict, Any, Tuple
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel, HttpUrl
from dotenv import load_dotenv
from datetime import datetime, timedelta
import threading
import logging
import sys
import warnings

from rate_limiter import check_rate_limit, get_rate_limit_stats
from watchdog import start_watchdog, track_request

from utils import (
    normalize_unit,
    convert_to_base_unit,
    normalize_units,
    normalize_youtube_url,
    url_hash,
    estimate_nutrition,
    match_food,
    NUTRITION_TABLE,
    UNIT_TO_G,
    UNIT_TO_ML,
)
from utils.deployment_env import get_public_api_domain, is_parse_worker_host, is_production_api_host

from models import (
    ParseRequest,
    ParseResponse,
    Recipe,
    Nutrition,
    ProductSearchRequest,
    ProductRecommendationResponse,
    AdvancedProductSearchResponse,
    CoupangProduct,
    ProductSearchResult,
    PreprocessIngredientsRequest,
    PreprocessIngredientsResponse,
    CategorizeIngredientRequest,
    CategorizeIngredientResponse,
    ReclassifyIngredientRequest,
    ReclassifyIngredientResponse,
)

from services import (
    FirebaseService,
    IngredientService,
    ProductService,
)
from services.firebase_service import get_firebase_service
from services.ingredient_service import get_ingredient_service
from services.product_service import get_product_service
from services.compliance_service import run_underage_cleanup_scheduler
from services.agent_flags import grocery_agent_enabled, home_agent_enabled, recipe_agent_enabled
from utils.process_file_lock import try_acquire_process_file_lock

from routers import (
    health_router,
    create_product_router,
    create_ingredient_router,
    create_ingredient_price_router,
    auth_router,
    create_fridge_router,
    create_purchase_verification_router,
    # 쿠팡 주문→계정 매칭은 비용 때문에 당분간 비활성.
    # create_coupang_orders_router,
    create_recipe_agent_router,
    create_home_agent_router,
    create_grocery_agent_router,
)
from routers.conversion_gap_research import create_conversion_gap_research_router
from routers.shelf_life_research import create_shelf_life_research_router

# Load environment variables
env_path = os.path.join(os.path.dirname(__file__), '.env')
load_dotenv(dotenv_path=env_path)

# Configure logging
log_level = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, log_level, logging.INFO),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

# Suppress noisy third-party loggers (Railway/production)
for _name in ("easyocr.easyocr", "httpx", "httpcore", "torch.utils.data.dataloader"):
    _log = logging.getLogger(_name)
    _log.setLevel(logging.WARNING)
# torch DataLoader: pin_memory has no effect without GPU
warnings.filterwarnings("ignore", message=".*pin_memory.*accelerator.*", category=UserWarning, module="torch.utils.data.dataloader")

# Global service instances
_firebase_service: Optional[FirebaseService] = None
_ingredient_service: Optional[IngredientService] = None
_product_service: Optional[ProductService] = None

def initialize_firebase():
    """Initialize Firebase Admin SDK for Firestore access (using service)"""
    global _firebase_service
    _firebase_service = get_firebase_service()

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize services on startup and cleanup on shutdown"""
    global _firebase_service

    import sys
    print("\n" + "="*60, flush=True)
    print("[Startup] Initializing Yorigo Backend", flush=True)
    if is_production_api_host():
        print("[Startup] Mode: production API host", flush=True)
    else:
        print("[Startup] Mode: local / development", flush=True)
    print("="*60, flush=True)
    global _firebase_service, _ingredient_service, _product_service
    initialize_firebase()
    _ingredient_service = get_ingredient_service()
    _product_service = get_product_service(firebase_service=_firebase_service)
    print("[Startup] ✓ All services initialized", flush=True)
    # A-5: zombie 워커 자동 회복용 watchdog 시작. asyncio와 무관한 별도 스레드라
    # 이벤트 루프가 잠겨도 동작한다. 임계값 초과 시 os._exit(1)로 워커 자살 → 부모가 재기동.
    if start_watchdog():
        print("[Startup] ✓ Worker watchdog started", flush=True)
    else:
        print("[Startup] ⚠ Worker watchdog disabled (ENABLE_WATCHDOG=false)", flush=True)
    print(
        "[Startup] ✓ Products load only on purchase intent",
        flush=True,
    )
    else:
        print("[Startup] ⚠ Background model warmup disabled (ENABLE_MODEL_WARMUP=false)", flush=True)
    
    # 쿠팡 API 스케줄러 주석처리 (당분간 작동 안함)
    # Start Coupang API scheduler in background thread
    # Use file-based locking to ensure only one scheduler instance runs across all workers
    # This prevents duplicate scheduler execution when using multiple uvicorn workers
    # scheduler_enabled = os.getenv("ENABLE_COUPANG_SCHEDULER", "true").lower() == "true"
    
    # if scheduler_enabled and _product_service:
    if False:  # 쿠팡 API 스케줄러 비활성화
        lock_file_path = os.path.join(tempfile.gettempdir(), "yorigo_scheduler.lock")
        lock_acquired = False
        lock_file = None
        
        try:
            # Try to create lock file exclusively (atomic operation)
            # On Windows, this requires 'x' mode (exclusive creation)
            # On Unix, we can use O_CREAT | O_EXCL equivalent
            if sys.platform == 'win32':
                try:
                    # Windows: Try to create file exclusively
                    lock_file = open(lock_file_path, 'x')
                    lock_acquired = True
                except FileExistsError:
                    # Lock file already exists, another process has the lock
                    lock_acquired = False
            else:
                # Unix: Use O_CREAT | O_EXCL for atomic file creation
                import fcntl
                try:
                    lock_file = open(lock_file_path, 'w')
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    lock_acquired = True
                except (IOError, BlockingIOError):
                    # Lock already held by another process
                    if lock_file:
                        lock_file.close()
                    lock_acquired = False
            
            if lock_acquired:
                # Write PID to lock file for debugging
                lock_file.write(str(os.getpid()))
                lock_file.flush()
                # Keep file open to maintain lock (will be released when process exits)
                
                print("[Startup] Starting Coupang API query scheduler in background thread...")
                scheduler_thread = threading.Thread(
                    target=_product_service.process_safe_queue,
                    daemon=True,  # Daemon thread: will be killed when main process exits
                    name="CoupangScheduler"
                )
                scheduler_thread.start()
                print("[Startup] ✓ Coupang API scheduler started (lock acquired)")
            else:
                # Check if lock file contains a valid PID (process might have died)
                try:
                    with open(lock_file_path, 'r') as f:
                        old_pid = int(f.read().strip())
                    # Check if process is still running
                    try:
                        os.kill(old_pid, 0)  # Signal 0: just check if process exists
                        print(f"[Startup] ⚠ Scheduler lock held by process {old_pid}, skipping scheduler startup")
                    except (OSError, ProcessLookupError):
                        # Process is dead, remove stale lock file and retry
                        try:
                            os.remove(lock_file_path)
                            print(f"[Startup] Removed stale API scheduler lock file (process {old_pid} not found)")
                            print("[Startup] Retrying lock acquisition...")
                            
                            # 재시도: stale lock 제거 후 다시 lock 획득 시도
                            if sys.platform == 'win32':
                                try:
                                    lock_file = open(lock_file_path, 'x')
                                    lock_acquired = True
                                except FileExistsError:
                                    lock_acquired = False
                            else:
                                import fcntl
                                try:
                                    lock_file = open(lock_file_path, 'w')
                                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                                    lock_acquired = True
                                except (IOError, BlockingIOError):
                                    if lock_file:
                                        lock_file.close()
                                    lock_acquired = False
                            
                            if lock_acquired:
                                # Write PID to lock file
                                lock_file.write(str(os.getpid()))
                                lock_file.flush()
                                
                                print("[Startup] Starting Coupang API query scheduler in background thread...")
                                scheduler_thread = threading.Thread(
                                    target=_product_service.process_safe_queue,
                                    daemon=True,
                                    name="CoupangScheduler"
                                )
                                scheduler_thread.start()
                                print("[Startup] ✓ Coupang API scheduler started (lock acquired after retry)")
                            else:
                                print("[Startup] ⚠ API scheduler lock not acquired after retry - another instance may be running")
                        except Exception as e:
                            print(f"[Startup] ⚠ Could not remove stale lock file or retry failed: {e}")
                except (FileNotFoundError, ValueError):
                    # Lock file doesn't exist or is invalid, but we couldn't create it
                    print("[Startup] ⚠ Could not acquire scheduler lock, skipping scheduler startup")
        except Exception as e:
            print(f"[Startup] ⚠ Error setting up scheduler lock: {e}")
            if lock_file and not lock_file.closed:
                try:
                    lock_file.close()
                    if lock_acquired:
                        try:
                            os.remove(lock_file_path)
                        except:
                            pass
                except:
                    pass
    else:
        print("[Startup] ⚠ Coupang API scheduler disabled (주석처리됨 - 스크래핑 스케줄러만 작동)")
    
    # Start Coupang Scraping scheduler in background thread (local only; disabled on production API)
    # Use file-based locking to ensure only one scraping scheduler instance runs across all workers
    is_prod_api = is_production_api_host()
    scraping_scheduler_enabled = (
        os.getenv("ENABLE_SCRAPING_SCHEDULER", "false").lower() == "true"
        and not is_prod_api
    )
    if scraping_scheduler_enabled:
        scraping_lock_file_path = os.path.join(tempfile.gettempdir(), "yorigo_scraping_scheduler.lock")
        scraping_lock_acquired = False
        scraping_lock_file = None
        
        try:
            # Try to create lock file exclusively (atomic operation)
            if sys.platform == 'win32':
                try:
                    # Windows: Try to create file exclusively
                    scraping_lock_file = open(scraping_lock_file_path, 'x')
                    scraping_lock_acquired = True
                except FileExistsError:
                    # Lock file already exists, another process has the lock
                    scraping_lock_acquired = False
            else:
                # Unix: Use O_CREAT | O_EXCL for atomic file creation
                import fcntl
                try:
                    scraping_lock_file = open(scraping_lock_file_path, 'w')
                    fcntl.flock(scraping_lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    scraping_lock_acquired = True
                except (IOError, BlockingIOError):
                    # Lock already held by another process
                    if scraping_lock_file:
                        scraping_lock_file.close()
                    scraping_lock_acquired = False
            
            if scraping_lock_acquired:
                # Write PID to lock file for debugging
                scraping_lock_file.write(str(os.getpid()))
                scraping_lock_file.flush()
                # Keep file open to maintain lock (will be released when process exits)
                
                print("[Startup] Starting Coupang scraping scheduler in background thread...", flush=True)
                print("[Startup] This may take a moment to initialize...", flush=True)
                try:
                    # Try importing coupang_scheduler module
                    # In Docker/Railway, the file is at /app/coupang_scheduler.py
                    import importlib.util
                    import sys
                    
                    # Try multiple possible paths
                    possible_paths = [
                        os.path.join(os.getcwd(), 'coupang_scheduler.py'),
                        '/app/coupang_scheduler.py',
                        os.path.join(os.path.dirname(__file__), 'coupang_scheduler.py'),
                    ]
                    
                    scheduler_path = None
                    for path in possible_paths:
                        if os.path.exists(path):
                            scheduler_path = path
                            print(f"[Startup] Found coupang_scheduler.py at: {path}", flush=True)
                            break
                    
                    if scheduler_path:
                        spec = importlib.util.spec_from_file_location("coupang_scheduler", scheduler_path)
                        coupang_scheduler_module = importlib.util.module_from_spec(spec)
                        spec.loader.exec_module(coupang_scheduler_module)
                        run_scraping_scheduler = coupang_scheduler_module.run_scraping_scheduler
                        print(f"[Startup] Successfully loaded coupang_scheduler from {scheduler_path}", flush=True)
                    else:
                        # Fallback to normal import
                        from coupang_scheduler import run_scraping_scheduler
                    
                    scraping_scheduler_thread = threading.Thread(
                        target=run_scraping_scheduler,
                        daemon=True,  # Daemon thread: will be killed when main process exits
                        name="CoupangScrapingScheduler"
                    )
                    scraping_scheduler_thread.start()
                    print("[Startup] ✓ Coupang scraping scheduler thread started (lock acquired)", flush=True)
                    print("[Startup] Scheduler will begin scraping in background...", flush=True)
                except ImportError as e:
                    print(f"[Startup] ⚠ Failed to import scraping scheduler: {e}")
                    missing_module = str(e).replace("No module named ", "").strip("'\"")
                    print(f"[Startup] ⚠ Scraping scheduler requires '{missing_module}' module")
                    print(f"[Startup] ⚠ Install it with: pip install {missing_module}")
                    # Release lock file since we're not starting the scheduler
                    try:
                        scraping_lock_file.close()
                        os.remove(scraping_lock_file_path)
                    except:
                        pass
                except Exception as e:
                    print(f"[Startup] ⚠ Failed to start scraping scheduler: {e}")
                    # Release lock file since we're not starting the scheduler
                    try:
                        scraping_lock_file.close()
                        os.remove(scraping_lock_file_path)
                    except:
                        pass
            else:
                # Check if lock file contains a valid PID (process might have died)
                try:
                    with open(scraping_lock_file_path, 'r') as f:
                        old_pid = int(f.read().strip())
                    # Check if process is still running
                    try:
                        os.kill(old_pid, 0)  # Signal 0: just check if process exists
                        print(f"[Startup] ⚠ Scraping scheduler lock held by process {old_pid}, skipping scraping scheduler startup")
                    except (OSError, ProcessLookupError):
                        # Process is dead, remove stale lock file and retry
                        try:
                            os.remove(scraping_lock_file_path)
                            print(f"[Startup] Removed stale scraping scheduler lock file (process {old_pid} not found)")
                            print("[Startup] Retrying scraping scheduler lock acquisition...")
                            
                            # 재시도: stale lock 제거 후 다시 lock 획득 시도
                            if sys.platform == 'win32':
                                try:
                                    scraping_lock_file = open(scraping_lock_file_path, 'x')
                                    scraping_lock_acquired = True
                                except FileExistsError:
                                    scraping_lock_acquired = False
                            else:
                                import fcntl
                                try:
                                    scraping_lock_file = open(scraping_lock_file_path, 'w')
                                    fcntl.flock(scraping_lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                                    scraping_lock_acquired = True
                                except (IOError, BlockingIOError):
                                    if scraping_lock_file:
                                        scraping_lock_file.close()
                                    scraping_lock_acquired = False
                            
                            if scraping_lock_acquired:
                                # Write PID to lock file
                                scraping_lock_file.write(str(os.getpid()))
                                scraping_lock_file.flush()
                                
                                print("[Startup] Starting Coupang scraping scheduler in background thread...", flush=True)
                                try:
                                    # Try importing coupang_scheduler module
                                    import importlib.util
                                    import sys
                                    
                                    # Try multiple possible paths
                                    possible_paths = [
                                        os.path.join(os.getcwd(), 'coupang_scheduler.py'),
                                        '/app/coupang_scheduler.py',
                                        os.path.join(os.path.dirname(__file__), 'coupang_scheduler.py'),
                                    ]
                                    
                                    scheduler_path = None
                                    for path in possible_paths:
                                        if os.path.exists(path):
                                            scheduler_path = path
                                            print(f"[Startup] Found coupang_scheduler.py at: {path}", flush=True)
                                            break
                                    
                                    if scheduler_path:
                                        spec = importlib.util.spec_from_file_location("coupang_scheduler", scheduler_path)
                                        coupang_scheduler_module = importlib.util.module_from_spec(spec)
                                        spec.loader.exec_module(coupang_scheduler_module)
                                        run_scraping_scheduler = coupang_scheduler_module.run_scraping_scheduler
                                        print(f"[Startup] Successfully loaded coupang_scheduler from {scheduler_path}", flush=True)
                                    else:
                                        # Fallback to normal import
                                        from coupang_scheduler import run_scraping_scheduler
                                    
                                    scraping_scheduler_thread = threading.Thread(
                                        target=run_scraping_scheduler,
                                        daemon=True,
                                        name="CoupangScrapingScheduler"
                                    )
                                    scraping_scheduler_thread.start()
                                    print("[Startup] ✓ Coupang scraping scheduler started (lock acquired after retry)")
                                except ImportError as e:
                                    print(f"[Startup] ⚠ Failed to import scraping scheduler: {e}")
                                    missing_module = str(e).replace("No module named ", "").strip("'\"")
                                    print(f"[Startup] ⚠ Scraping scheduler requires '{missing_module}' module")
                                    print(f"[Startup] ⚠ Install it with: pip install {missing_module}")
                                    # Release lock file since we're not starting the scheduler
                                    try:
                                        scraping_lock_file.close()
                                        os.remove(scraping_lock_file_path)
                                    except:
                                        pass
                                except Exception as e:
                                    print(f"[Startup] ⚠ Failed to start scraping scheduler: {e}")
                                    # Release lock file since we're not starting the scheduler
                                    try:
                                        scraping_lock_file.close()
                                        os.remove(scraping_lock_file_path)
                                    except:
                                        pass
                            else:
                                print("[Startup] ⚠ Scraping scheduler lock not acquired after retry - another instance may be running")
                        except Exception as e:
                            print(f"[Startup] ⚠ Could not remove stale scraping scheduler lock file or retry failed: {e}")
                except (FileNotFoundError, ValueError):
                    # Lock file doesn't exist or is invalid, but we couldn't create it
                    print("[Startup] ⚠ Could not acquire scraping scheduler lock, skipping scraping scheduler startup")
        except Exception as e:
            print(f"[Startup] ⚠ Error setting up scraping scheduler lock: {e}")
            if scraping_lock_file and not scraping_lock_file.closed:
                try:
                    scraping_lock_file.close()
                    if scraping_lock_acquired:
                        try:
                            os.remove(scraping_lock_file_path)
                        except:
                            pass
                except:
                    pass
    else:
        reason = "production API host" if is_prod_api else "ENABLE_SCRAPING_SCHEDULER=false"
        print(f"[Startup] ⚠ Coupang scraping scheduler disabled ({reason})", flush=True)
    
    # Start Kurly scraping scheduler in background thread (local only; disabled on production API)
    # Use file-based locking to ensure only one kurly scraping scheduler instance runs across all workers
    kurly_scraping_scheduler_enabled = (
        os.getenv("ENABLE_KURLY_SCRAPING_SCHEDULER", "false").lower() == "true"
        and not is_prod_api
    )
    if kurly_scraping_scheduler_enabled:
        kurly_scraping_lock_file_path = os.path.join(tempfile.gettempdir(), "yorigo_kurly_scraping_scheduler.lock")
        kurly_scraping_lock_acquired = False
        kurly_scraping_lock_file = None
        
        try:
            # Try to create lock file exclusively (atomic operation)
            if sys.platform == 'win32':
                try:
                    # Windows: Try to create file exclusively
                    kurly_scraping_lock_file = open(kurly_scraping_lock_file_path, 'x')
                    kurly_scraping_lock_acquired = True
                except FileExistsError:
                    # Lock file already exists, another process has the lock
                    kurly_scraping_lock_acquired = False
            else:
                # Unix: Use O_CREAT | O_EXCL for atomic file creation
                import fcntl
                try:
                    kurly_scraping_lock_file = open(kurly_scraping_lock_file_path, 'w')
                    fcntl.flock(kurly_scraping_lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    kurly_scraping_lock_acquired = True
                except (IOError, BlockingIOError):
                    # Lock already held by another process
                    if kurly_scraping_lock_file:
                        kurly_scraping_lock_file.close()
                    kurly_scraping_lock_acquired = False
            
            if kurly_scraping_lock_acquired:
                # Write PID to lock file for debugging
                kurly_scraping_lock_file.write(str(os.getpid()))
                kurly_scraping_lock_file.flush()
                # Keep file open to maintain lock (will be released when process exits)
                
                print("[Startup] Starting Kurly scraping scheduler in background thread...", flush=True)
                print("[Startup] This may take a moment to initialize...", flush=True)
                try:
                    # Try importing kurly_scheduler module
                    # In Docker/Railway, the file is at /app/kurly_scheduler.py
                    import importlib.util
                    import sys
                    
                    # Try multiple possible paths
                    possible_paths = [
                        os.path.join(os.getcwd(), 'kurly_scheduler.py'),
                        '/app/kurly_scheduler.py',
                        os.path.join(os.path.dirname(__file__), 'kurly_scheduler.py'),
                    ]
                    
                    scheduler_path = None
                    for path in possible_paths:
                        if os.path.exists(path):
                            scheduler_path = path
                            print(f"[Startup] Found kurly_scheduler.py at: {path}", flush=True)
                            break
                    
                    if scheduler_path:
                        spec = importlib.util.spec_from_file_location("kurly_scheduler", scheduler_path)
                        kurly_scheduler_module = importlib.util.module_from_spec(spec)
                        spec.loader.exec_module(kurly_scheduler_module)
                        run_kurly_scraping_scheduler = kurly_scheduler_module.run_scraping_scheduler
                        print(f"[Startup] Successfully loaded kurly_scheduler from {scheduler_path}", flush=True)
                    else:
                        # Fallback to normal import
                        from kurly_scheduler import run_scraping_scheduler as run_kurly_scraping_scheduler
                    
                    kurly_scraping_scheduler_thread = threading.Thread(
                        target=run_kurly_scraping_scheduler,
                        daemon=True,  # Daemon thread: will be killed when main process exits
                        name="KurlyScrapingScheduler"
                    )
                    kurly_scraping_scheduler_thread.start()
                    print("[Startup] ✓ Kurly scraping scheduler thread started (lock acquired)", flush=True)
                    print("[Startup] Kurly scheduler will begin scraping in background...", flush=True)
                except ImportError as e:
                    print(f"[Startup] ⚠ Failed to import kurly scraping scheduler: {e}")
                    missing_module = str(e).replace("No module named ", "").strip("'\"")
                    print(f"[Startup] ⚠ Kurly scraping scheduler requires '{missing_module}' module")
                    print(f"[Startup] ⚠ Install it with: pip install {missing_module}")
                    # Release lock file since we're not starting the scheduler
                    try:
                        kurly_scraping_lock_file.close()
                        os.remove(kurly_scraping_lock_file_path)
                    except:
                        pass
                except Exception as e:
                    print(f"[Startup] ⚠ Failed to start kurly scraping scheduler: {e}")
                    # Release lock file since we're not starting the scheduler
                    try:
                        kurly_scraping_lock_file.close()
                        os.remove(kurly_scraping_lock_file_path)
                    except:
                        pass
            else:
                # Check if lock file contains a valid PID (process might have died)
                try:
                    with open(kurly_scraping_lock_file_path, 'r') as f:
                        old_pid = int(f.read().strip())
                    # Check if process is still running
                    try:
                        os.kill(old_pid, 0)  # Signal 0: just check if process exists
                        print(f"[Startup] ⚠ Kurly scraping scheduler lock held by process {old_pid}, skipping kurly scraping scheduler startup")
                    except (OSError, ProcessLookupError):
                        # Process is dead, remove stale lock file and retry
                        try:
                            os.remove(kurly_scraping_lock_file_path)
                            print(f"[Startup] Removed stale kurly scraping scheduler lock file (process {old_pid} not found)")
                            print("[Startup] Retrying kurly scraping scheduler lock acquisition...")
                            
                            # 재시도: stale lock 제거 후 다시 lock 획득 시도
                            if sys.platform == 'win32':
                                try:
                                    kurly_scraping_lock_file = open(kurly_scraping_lock_file_path, 'x')
                                    kurly_scraping_lock_acquired = True
                                except FileExistsError:
                                    kurly_scraping_lock_acquired = False
                            else:
                                import fcntl
                                try:
                                    kurly_scraping_lock_file = open(kurly_scraping_lock_file_path, 'w')
                                    fcntl.flock(kurly_scraping_lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                                    kurly_scraping_lock_acquired = True
                                except (IOError, BlockingIOError):
                                    if kurly_scraping_lock_file:
                                        kurly_scraping_lock_file.close()
                                    kurly_scraping_lock_acquired = False
                            
                            if kurly_scraping_lock_acquired:
                                # Write PID to lock file
                                kurly_scraping_lock_file.write(str(os.getpid()))
                                kurly_scraping_lock_file.flush()
                                
                                print("[Startup] Starting Kurly scraping scheduler in background thread...", flush=True)
                                try:
                                    # Try importing kurly_scheduler module
                                    import importlib.util
                                    import sys
                                    
                                    # Try multiple possible paths
                                    possible_paths = [
                                        os.path.join(os.getcwd(), 'kurly_scheduler.py'),
                                        '/app/kurly_scheduler.py',
                                        os.path.join(os.path.dirname(__file__), 'kurly_scheduler.py'),
                                    ]
                                    
                                    scheduler_path = None
                                    for path in possible_paths:
                                        if os.path.exists(path):
                                            scheduler_path = path
                                            print(f"[Startup] Found kurly_scheduler.py at: {path}", flush=True)
                                            break
                                    
                                    if scheduler_path:
                                        spec = importlib.util.spec_from_file_location("kurly_scheduler", scheduler_path)
                                        kurly_scheduler_module = importlib.util.module_from_spec(spec)
                                        spec.loader.exec_module(kurly_scheduler_module)
                                        run_kurly_scraping_scheduler = kurly_scheduler_module.run_scraping_scheduler
                                        print(f"[Startup] Successfully loaded kurly_scheduler from {scheduler_path}", flush=True)
                                    else:
                                        # Fallback to normal import
                                        from kurly_scheduler import run_scraping_scheduler as run_kurly_scraping_scheduler
                                    
                                    kurly_scraping_scheduler_thread = threading.Thread(
                                        target=run_kurly_scraping_scheduler,
                                        daemon=True,
                                        name="KurlyScrapingScheduler"
                                    )
                                    kurly_scraping_scheduler_thread.start()
                                    print("[Startup] ✓ Kurly scraping scheduler started (lock acquired after retry)")
                                except ImportError as e:
                                    print(f"[Startup] ⚠ Failed to import kurly scraping scheduler: {e}")
                                    missing_module = str(e).replace("No module named ", "").strip("'\"")
                                    print(f"[Startup] ⚠ Kurly scraping scheduler requires '{missing_module}' module")
                                    print(f"[Startup] ⚠ Install it with: pip install {missing_module}")
                                    # Release lock file since we're not starting the scheduler
                                    try:
                                        kurly_scraping_lock_file.close()
                                        os.remove(kurly_scraping_lock_file_path)
                                    except:
                                        pass
                                except Exception as e:
                                    print(f"[Startup] ⚠ Failed to start kurly scraping scheduler: {e}")
                                    # Release lock file since we're not starting the scheduler
                                    try:
                                        kurly_scraping_lock_file.close()
                                        os.remove(kurly_scraping_lock_file_path)
                                    except:
                                        pass
                            else:
                                print("[Startup] ⚠ Kurly scraping scheduler lock not acquired after retry - another instance may be running")
                        except Exception as e:
                            print(f"[Startup] ⚠ Could not remove stale kurly scraping scheduler lock file or retry failed: {e}")
                except (FileNotFoundError, ValueError):
                    # Lock file doesn't exist or is invalid, but we couldn't create it
                    print("[Startup] ⚠ Could not acquire kurly scraping scheduler lock, skipping kurly scraping scheduler startup")
        except Exception as e:
            print(f"[Startup] ⚠ Error setting up kurly scraping scheduler lock: {e}")
            if kurly_scraping_lock_file and not kurly_scraping_lock_file.closed:
                try:
                    kurly_scraping_lock_file.close()
                    if kurly_scraping_lock_acquired:
                        try:
                            os.remove(kurly_scraping_lock_file_path)
                        except:
                            pass
                except:
                    pass
    else:
        reason = "production API host" if is_prod_api else "ENABLE_KURLY_SCRAPING_SCHEDULER=false"
        print(f"[Startup] ⚠ Kurly scraping scheduler disabled ({reason})", flush=True)
    
    # Start Ingredient Price Collection scheduler in background thread (production API only)
    # 24시간 주기로 pending_scraping_ingredients를 읽어서 AI에게 가격 요청하고 저장
    price_scheduler_enabled = (
        os.getenv("ENABLE_PRICE_COLLECTION_SCHEDULER", "true").lower() == "true"
        and is_prod_api
    )
    
    if price_scheduler_enabled:
        price_lock_file_path = os.path.join(tempfile.gettempdir(), "yorigo_price_scheduler.lock")
        price_lock_acquired = False
        price_lock_file = None
        
        try:
            # Try to create lock file exclusively (atomic operation)
            if sys.platform == 'win32':
                try:
                    price_lock_file = open(price_lock_file_path, 'x')
                    price_lock_acquired = True
                except FileExistsError:
                    price_lock_acquired = False
            else:
                # Unix: Use O_EXCL flag for atomic file creation
                try:
                    price_lock_file = os.open(price_lock_file_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
                    price_lock_acquired = True
                except FileExistsError:
                    price_lock_acquired = False
            
            if price_lock_acquired:
                # Write current PID to lock file
                try:
                    if sys.platform == 'win32':
                        price_lock_file.write(str(os.getpid()))
                        price_lock_file.flush()
                    else:
                        os.write(price_lock_file, str(os.getpid()).encode())
                        os.close(price_lock_file)
                        price_lock_file = None
                    
                    print("[Startup] Starting ingredient price collection scheduler in background thread...", flush=True)
                    
                    try:
                        # Try importing ingredient_price_scheduler module
                        import importlib.util
                        scheduler_paths = [
                            os.path.join(os.getcwd(), 'ingredient_price_scheduler.py'),
                            '/app/ingredient_price_scheduler.py',
                            os.path.join(os.path.dirname(__file__), 'ingredient_price_scheduler.py'),
                        ]
                        
                        scheduler_path = None
                        for path in scheduler_paths:
                            if os.path.exists(path):
                                scheduler_path = path
                                print(f"[Startup] Found ingredient_price_scheduler.py at: {path}", flush=True)
                                break
                        
                        if scheduler_path:
                            spec = importlib.util.spec_from_file_location("ingredient_price_scheduler", scheduler_path)
                            price_scheduler_module = importlib.util.module_from_spec(spec)
                            spec.loader.exec_module(price_scheduler_module)
                            run_price_collection_scheduler = price_scheduler_module.run_price_collection_scheduler
                            print(f"[Startup] Successfully loaded ingredient_price_scheduler from {scheduler_path}", flush=True)
                        else:
                            from ingredient_price_scheduler import run_price_collection_scheduler
                        
                        price_scheduler_thread = threading.Thread(
                            target=run_price_collection_scheduler,
                            daemon=True,
                            name="IngredientPriceCollectionScheduler"
                        )
                        price_scheduler_thread.start()
                        print("[Startup] ✓ Ingredient price collection scheduler thread started (lock acquired)", flush=True)
                        print("[Startup] Scheduler will collect prices for pending ingredients every 24 hours...", flush=True)
                    except ImportError as e:
                        missing_module = str(e).split("'")[1] if "'" in str(e) else "unknown"
                        print(f"[Startup] ⚠ Failed to import price collection scheduler: {e}")
                        print(f"[Startup] ⚠ Price collection scheduler requires '{missing_module}' module")
                        # Release lock file since we're not starting the scheduler
                        try:
                            if sys.platform == 'win32':
                                price_lock_file.close()
                            else:
                                os.remove(price_lock_file_path)
                        except:
                            pass
                    except Exception as e:
                        print(f"[Startup] ⚠ Failed to start price collection scheduler: {e}")
                        # Release lock file since we're not starting the scheduler
                        try:
                            if sys.platform == 'win32':
                                price_lock_file.close()
                            else:
                                os.remove(price_lock_file_path)
                        except:
                            pass
                except Exception as e:
                    print(f"[Startup] ⚠ Error writing to price scheduler lock file: {e}")
                    if price_lock_file:
                        try:
                            if sys.platform == 'win32':
                                price_lock_file.close()
                            else:
                                os.close(price_lock_file)
                        except:
                            pass
            else:
                # Lock file exists - check if process is still running
                try:
                    with open(price_lock_file_path, 'r') as f:
                        old_pid = int(f.read().strip())
                    
                    # Check if process is still running
                    try:
                        os.kill(old_pid, 0)  # Signal 0 just checks if process exists
                        print(f"[Startup] ⚠ Price collection scheduler lock held by process {old_pid}, skipping price scheduler startup")
                    except ProcessLookupError:
                        # Process doesn't exist - remove stale lock
                        try:
                            os.remove(price_lock_file_path)
                            print(f"[Startup] Removed stale price scheduler lock file (process {old_pid} not found)")
                            print("[Startup] Retrying price scheduler lock acquisition...")
                            # Retry logic could go here if needed
                        except Exception as e:
                            print(f"[Startup] ⚠ Could not remove stale price scheduler lock file or retry failed: {e}")
                    except PermissionError:
                        # Process exists but we can't signal it (different user)
                        print(f"[Startup] ⚠ Price collection scheduler lock held by process {old_pid} (different user), skipping")
                except (ValueError, FileNotFoundError):
                    # Lock file is invalid or doesn't exist anymore
                    try:
                        os.remove(price_lock_file_path)
                    except:
                        pass
                    print("[Startup] ⚠ Could not acquire price collection scheduler lock, skipping price scheduler startup")
        except Exception as e:
            print(f"[Startup] ⚠ Error setting up price collection scheduler lock: {e}")
    else:
        reason = "not production API host" if not is_prod_api else "ENABLE_PRICE_COLLECTION_SCHEDULER=false"
        print(f"[Startup] ⚠ Ingredient price collection scheduler disabled ({reason})", flush=True)

    # Start ingredient product coverage health check scheduler (production API: every 6 hours)
    # uvicorn 멀티워커면 파일 락으로 1개 워커만 루프를 띄운다 (우선순위 스크래핑 중복 enqueue 방지).
    health_check_enabled = (
        os.getenv("ENABLE_PRODUCT_HEALTH_CHECK", "true").lower() == "true"
        and is_prod_api
    )
    if health_check_enabled:
        health_lock_ok, _health_lock_fh = try_acquire_process_file_lock(
            "yorigo_product_health_check.lock",
            log_prefix="HealthCheck",
        )
        if health_lock_ok:
            def _run_product_health_check_loop():
                import time as _t
                _t.sleep(60)  # wait for server to settle
                while True:
                    try:
                        from services.product_service import check_ingredient_product_coverage
                        result = check_ingredient_product_coverage()
                        print(
                            f"[HealthCheck] Coverage: {result.get('covered', 0)}/{result.get('total', 0)} "
                            f"ingredients have products, {result.get('missing', 0)} missing, "
                            f"{result.get('checked_this_run', '?')} checked this run",
                            flush=True,
                        )
                    except Exception as e:
                        print(f"[HealthCheck] Error: {e}", flush=True)
                    _t.sleep(6 * 60 * 60)  # 6 hours

            threading.Thread(
                target=_run_product_health_check_loop,
                daemon=True,
                name="ProductHealthCheckScheduler",
            ).start()
            print(
                "[Startup] ✓ Product coverage health check scheduler started "
                "(every 6 hours, single-worker lock)",
                flush=True,
            )
        else:
            print(
                "[Startup] ⚠ Product coverage health check skipped "
                "(another worker holds yorigo_product_health_check.lock)",
                flush=True,
            )
    else:
        reason = "not production API host" if not is_prod_api else "ENABLE_PRODUCT_HEALTH_CHECK=false"
        print(f"[Startup] ⚠ Product coverage health check disabled ({reason})", flush=True)

    # Start underage cleanup scheduler in background thread (default: enabled)
    # uvicorn 멀티워커면 파일 락으로 1개 워커만 루프를 띄운다 (Firestore scan/삭제 ×N 방지).
    enable_underage_cleanup_scheduler = (
        os.getenv("ENABLE_UNDERAGE_CLEANUP_SCHEDULER", "true").lower() == "true"
        and not is_parse_worker_host()
    )
    if enable_underage_cleanup_scheduler and _firebase_service and _firebase_service.db is not None:
        underage_lock_ok, _underage_lock_fh = try_acquire_process_file_lock(
            "yorigo_underage_cleanup.lock",
            log_prefix="UnderageCleanup",
        )
        if underage_lock_ok:
            threading.Thread(
                target=run_underage_cleanup_scheduler,
                args=(_firebase_service.db,),
                daemon=True,
                name="UnderageCleanupScheduler",
            ).start()
            print(
                "[Startup] ✓ Underage cleanup scheduler started (single-worker lock)",
                flush=True,
            )
        else:
            print(
                "[Startup] ⚠ Underage cleanup scheduler skipped "
                "(another worker holds yorigo_underage_cleanup.lock)",
                flush=True,
            )
    else:
        print(
            "[Startup] ⚠ Underage cleanup scheduler disabled "
            "(ENABLE_UNDERAGE_CLEANUP_SCHEDULER=false or Firebase unavailable)",
            flush=True,
        )

    # B-2b: 일일 레시피 DB 스냅샷 → Mixpanel 전송.
    # uvicorn 멀티워커면 파일 락으로 1개 워커만 루프를 띄운다 (recipes 전량 scan ×N 방지).
    # 이 지표는 사용자 기능과 무관한 Mixpanel 참고용 카운트("총 유효 레시피 수")일
    # 뿐인데, 매일 completed+non-hidden 레시피 전체를 select 스트림으로 읽는다.
    # 레시피가 쌓일수록(현재 18,500+건) 비용이 무한정 커지는 반면 실사용 가치가
    # 낮아 기본값을 비활성화로 바꿨다. 필요 시 ENABLE_RECIPE_SNAPSHOT=true로 켤 수 있다.
    enable_recipe_snapshot = (
        os.getenv("ENABLE_RECIPE_SNAPSHOT", "false").lower() in ("1", "true", "yes")
        and not is_parse_worker_host()
    )
    if enable_recipe_snapshot and _firebase_service and _firebase_service.db is not None:
        snapshot_lock_ok, _snapshot_lock_fh = try_acquire_process_file_lock(
            "yorigo_recipe_snapshot.lock",
            log_prefix="RecipeSnapshot",
        )
        if snapshot_lock_ok:
            from services.recipe_snapshot_scheduler import run_recipe_snapshot_scheduler
            threading.Thread(
                target=run_recipe_snapshot_scheduler,
                args=(_firebase_service.db,),
                daemon=True,
                name="RecipeSnapshotScheduler",
            ).start()
            print(
                "[Startup] ✓ Daily recipe snapshot scheduler started (single-worker lock)",
                flush=True,
            )
        else:
            print(
                "[Startup] ⚠ Daily recipe snapshot scheduler skipped "
                "(another worker holds yorigo_recipe_snapshot.lock)",
                flush=True,
            )
    else:
        print("[Startup] ⚠ Daily recipe snapshot scheduler disabled", flush=True)

    # 쿠팡 주문→계정 매칭은 비용(7일 전량 upsert, 리포트 API, 상시 스레드) 때문에
    # 당분간 비활성. 되살릴 때 이 블록과 create_coupang_orders_router 등록을 풀면 된다.
    print(
        "[Startup] ⚠ Coupang order sync scheduler disabled (account matching off)",
        flush=True,
    )
    # enable_coupang_order_sync = (
    #     os.getenv("ENABLE_COUPANG_ORDER_SYNC", "false").lower() in ("1", "true", "yes")
    #     and not is_parse_worker_host()
    # )
    # if enable_coupang_order_sync and _firebase_service and _firebase_service.db is not None:
    #     order_sync_lock_ok, _order_sync_lock_fh = try_acquire_process_file_lock(
    #         "yorigo_coupang_order_sync.lock",
    #         log_prefix="CoupangOrderSync",
    #     )
    #     if order_sync_lock_ok:
    #         from services.coupang_order_sync_scheduler import run_coupang_order_sync_scheduler
    #         threading.Thread(
    #             target=run_coupang_order_sync_scheduler,
    #             args=(_firebase_service.db,),
    #             daemon=True,
    #             name="CoupangOrderSyncScheduler",
    #         ).start()
    #         print(
    #             "[Startup] ✓ Coupang order sync scheduler started (single-worker lock)",
    #             flush=True,
    #         )
    #     else:
    #         print(
    #             "[Startup] ⚠ Coupang order sync scheduler skipped "
    #             "(another worker holds yorigo_coupang_order_sync.lock)",
    #             flush=True,
    #         )
    # else:
    #     print("[Startup] ⚠ Coupang order sync scheduler disabled", flush=True)

    # B-2c: 일일 행동 시그널(impression/click/cook_done/purchase 등) 취합.
    # 클라이언트가 Firebase Storage(GCS)에 직접 올린 signals/raw/*.jsonl 배치를
    # 모아 gzip 후 signals/processed/{date}.jsonl.gz 로 만든다. BigQuery 외부
    # 테이블이 processed/*.jsonl.gz만 바라보므로 이 스케줄러가 데이터 파이프라인의
    # 핵심 단계 — 기본 활성화(ENABLE_SIGNAL_EXPORT_SCHEDULER=false로 끌 수 있음).
    enable_signal_export = (
        os.getenv("ENABLE_SIGNAL_EXPORT_SCHEDULER", "true").lower() in ("1", "true", "yes")
        and not is_parse_worker_host()
    )
    if enable_signal_export and _firebase_service and _firebase_service.db is not None:
        signal_export_lock_ok, _signal_export_lock_fh = try_acquire_process_file_lock(
            "yorigo_signal_export.lock",
            log_prefix="SignalExport",
        )
        if signal_export_lock_ok:
            from services.signal_export_scheduler import run_signal_export_scheduler
            threading.Thread(
                target=run_signal_export_scheduler,
                args=(_firebase_service.db,),
                daemon=True,
                name="SignalExportScheduler",
            ).start()
            print(
                "[Startup] ✓ Daily signal export scheduler started (single-worker lock)",
                flush=True,
            )
        else:
            print(
                "[Startup] ⚠ Daily signal export scheduler skipped "
                "(another worker holds yorigo_signal_export.lock)",
                flush=True,
            )
    else:
        print("[Startup] ⚠ Daily signal export scheduler disabled", flush=True)

    # B-3: 이벤트 루프 lag heartbeat.
    # 정상이면 lag ≈ 0ms. 동기 작업이 루프를 잡으면 lag가 초 단위로 튐.
    # 임계값 초과 시 WARN 로그 → stuck 직전 신호를 미리 감지.
    enable_loop_heartbeat = (
        os.getenv("ENABLE_EVENT_LOOP_HEARTBEAT", "true").lower() in ("1", "true", "yes")
    )
    if enable_loop_heartbeat:
        import asyncio as _asyncio
        import time as _time

        loop_lag_warn_seconds = float(os.getenv("EVENT_LOOP_LAG_WARN_SECONDS", "2"))
        loop_lag_check_interval = float(
            os.getenv("EVENT_LOOP_LAG_CHECK_INTERVAL_SECONDS", "5")
        )

        async def _event_loop_heartbeat():
            while True:
                t0 = _time.monotonic()
                try:
                    await _asyncio.sleep(loop_lag_check_interval)
                except _asyncio.CancelledError:
                    return
                lag = _time.monotonic() - t0 - loop_lag_check_interval
                if lag > loop_lag_warn_seconds:
                    logger.warning(
                        "[EventLoop] lag=%.2fs (interval=%.1fs, threshold=%.1fs) — "
                        "sync work is blocking asyncio loop",
                        lag,
                        loop_lag_check_interval,
                        loop_lag_warn_seconds,
                    )

        _asyncio.create_task(_event_loop_heartbeat())
        print("[Startup] ✓ Event loop heartbeat started", flush=True)
    else:
        print("[Startup] ⚠ Event loop heartbeat disabled", flush=True)

    print("="*60 + "\n", flush=True)
    yield

app = FastAPI(title="Yorigo Backend", lifespan=lifespan)

from fastapi.middleware.cors import CORSMiddleware
allowed_origins = [
    "http://localhost:8000",
    "http://localhost:59411",
    "https://yorigo-f7408.web.app",
    "https://yorigo-f7408.firebaseapp.com",
]

public_api_domain = get_public_api_domain()
if public_api_domain:
    allowed_origins.append(f"https://{public_api_domain}")
    allowed_origins.append(f"http://{public_api_domain}")

is_development = os.getenv("ENVIRONMENT") != "production"

def _get_production_cors_origins(default_origins: List[str]) -> List[str]:
    """
    프로덕션 CORS 허용 origin 목록을 환경변수 또는 기본값으로 반환합니다.
    """
    raw = (os.getenv("ALLOWED_ORIGINS") or "").strip()
    if raw:
        parsed = [item.strip() for item in raw.split(",") if item.strip()]
        if parsed:
            return parsed
    return default_origins


if is_development:
    cors_origins = ["*"]
    cors_credentials = False
    # 개발은 전부 허용.
    cors_origin_regex = None
else:
    cors_origins = _get_production_cors_origins(allowed_origins)
    cors_credentials = False
    # Flutter Web(`flutter run -d chrome`)은 localhost 포트가 매번 바뀌므로
    # 고정 origin 목록만으로는 CORS에 막힌다. 로컬 디버깅용으로만 허용.
    cors_origin_regex = r"https?://(localhost|127\.0\.0\.1)(:\d+)?"

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_origin_regex=cors_origin_regex,
    allow_credentials=cors_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)


# A-5: 모든 요청에 대해 watchdog in-flight 카운터를 증가시킨다.
# 특정 엔드포인트(예: /recommend_products*)만 추적하던 기존 구조는
# 다른 엔드포인트에서 동기 I/O로 event loop이 잠긴 좀비 워커를 잡지 못했다.
# 미들웨어로 끌어올려 어떤 라우트에서 막혀도 watchdog가 자살 결정을 내릴 수 있게 한다.
@app.middleware("http")
async def track_in_flight(request: Request, call_next):
    """A-5: watchdog용 in-flight 카운터. 헬스체크는 카운트에서 제외."""
    if request.url.path in ("/health", "/api/health", "/healthz"):
        return await call_next(request)
    with track_request():
        return await call_next(request)


REQUEST_LOG_HEADER_ALLOWLIST = {
    "origin",
    "user-agent",
    "content-type",
    "accept",
    "x-request-id",
    "x-forwarded-for",
    "x-forwarded-proto",
}


def _select_safe_headers_for_logging(headers: Dict[str, str]) -> Dict[str, str]:
    """허용된 요청 헤더만 선별하여 로그에 남깁니다."""
    selected: Dict[str, str] = {}
    for key, value in headers.items():
        if key.lower() in REQUEST_LOG_HEADER_ALLOWLIST:
            selected[key] = value
    return selected


# Request logging middleware for debugging
@app.middleware("http")
async def log_requests(request: Request, call_next):
    """Log all incoming requests for debugging"""
    should_log_requests = os.getenv("LOG_REQUESTS", "true" if is_development else "false").lower() in ("1", "true", "yes")
    if not should_log_requests:
        return await call_next(request)

    if request.url.path in ("/health", "/api/health", "/healthz"):
        return await call_next(request)

    should_log_headers = os.getenv("LOG_REQUEST_HEADERS", "true" if is_development else "false").lower() in ("1", "true", "yes")
    should_log_options_response_headers = os.getenv(
        "LOG_OPTIONS_RESPONSE_HEADERS",
        "true" if is_development else "false",
    ).lower() in ("1", "true", "yes")
    client_ip = request.client.host if request.client else "unknown"
    origin = request.headers.get("origin", "None")
    logger.info("[Request] %s %s", request.method, request.url.path)
    logger.info("[Request] Client IP: %s", client_ip)
    logger.info("[Request] Origin: %s", origin)
    if request.method == "OPTIONS":
        logger.info(
            "[Request] OPTIONS Request - Access-Control-Request-Method: %s",
            request.headers.get("access-control-request-method", "None"),
        )
        logger.info(
            "[Request] OPTIONS Request - Access-Control-Request-Headers: %s",
            request.headers.get("access-control-request-headers", "None"),
        )
    if should_log_headers:
        logger.info("[Request] Headers: %s", _select_safe_headers_for_logging(dict(request.headers)))
    try:
        response = await call_next(request)
        logger.info("[Request] Response status: %s", response.status_code)
        if request.method == "OPTIONS" and should_log_options_response_headers:
            logger.info(
                "[Request] OPTIONS Response headers: %s",
                _select_safe_headers_for_logging(dict(response.headers)),
            )
        return response
    except Exception as e:
        logger.exception("[Request] Error: %s", e)
        import traceback
        traceback.print_exc()
        raise

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    try:
        body = await request.body()
        body_size = len(body) if body else 0
    except Exception:
        body_size = -1
    
    print(f"[ERROR] Validation error: {exc.errors()}")
    print(f"[ERROR] Request body size: {body_size} bytes")
    return JSONResponse(
        status_code=422,
        content={"detail": exc.errors()}
    )

COUPANG_ACCESS_KEY = os.getenv("COUPANG_ACCESS_KEY", "")
COUPANG_SECRET_KEY = os.getenv("COUPANG_SECRET_KEY", "")
COUPANG_PARTNER_SUBID = os.getenv("COUPANG_PARTNER_SUBID", "YorigoMobile")
NAVER_CLIENT_ID = os.getenv("NAVER_CLIENT_ID", "")
NAVER_CLIENT_SECRET = os.getenv("NAVER_CLIENT_SECRET", "")

### ---------- Coupang API Helpers ----------
def generate_coupang_hmac(method: str, url: str, secret_key: str, access_key: str = None) -> str:
    """Generate Coupang HMAC (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.generate_coupang_hmac(method, url, secret_key, access_key)

def parse_product_size(product_name: str) -> tuple[Optional[float], Optional[str]]:
    """Parse product size (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.parse_product_size(product_name)

def generate_bulk_keyword(name: str, amount: Optional[str] = None) -> str:
    """Generate bulk keyword (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.generate_bulk_keyword(name, amount)

def encode_affiliate_link(product_url: str, product_id: Optional[str] = None) -> str:
    """Encode affiliate link (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.encode_affiliate_link(product_url, product_id)

def calculate_match_score(needed_qty: Optional[float], needed_unit: Optional[str],
                         product_size: Optional[float], product_unit: Optional[str],
                         product_price: int, 
                         unit_price: Optional[float] = None,
                         avg_unit_price: Optional[float] = None,
                         is_rocket: bool = False) -> float:
    """Calculate match score (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.calculate_match_score(needed_qty, needed_unit, product_size, product_unit, product_price, unit_price, avg_unit_price, is_rocket)

def calculate_amount_match_score(needed_qty: Optional[float], needed_unit: Optional[str],
                                product_size: Optional[float], product_unit: Optional[str]) -> float:
    """Calculate amount match score (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.calculate_amount_match_score(needed_qty, needed_unit, product_size, product_unit)

### ---------- Naver Shopping API ----------
def search_naver_shopping(query: str, limit: int = 50, coupang_only: bool = False) -> List[Dict[str, Any]]:
    """Search Naver Shopping (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.search_naver_shopping(query, limit, coupang_only)


CACHE_COLLECTION = "search_query_cache"
CACHE_TTL_HOURS = 12

def get_cached_search_results(query: str) -> Optional[List[Dict[str, Any]]]:
    """
    Check Firestore cache for search query results (using service).
    Returns cached results if valid (within 12 hours), None otherwise.
    """
    global _firebase_service
    if _firebase_service is None:
        _firebase_service = get_firebase_service()
    return _firebase_service.get_cached_search_results(query, CACHE_COLLECTION, CACHE_TTL_HOURS)

def save_search_results_to_cache(query: str, results: List[Dict[str, Any]]):
    """
    Save search query results to Firestore cache (using service).
    """
    global _firebase_service
    if _firebase_service is None:
        _firebase_service = get_firebase_service()
    _firebase_service.save_search_results_to_cache(query, results, CACHE_COLLECTION)

def search_coupang_products(query: str, limit: int = 10) -> List[Dict[str, Any]]:
    """Search Coupang products (using service)"""
    global _product_service
    if _product_service is None:
        _product_service = get_product_service(firebase_service=_firebase_service)
    return _product_service.search_coupang_products(query, limit)

### ---------- Register Routers ----------
# Health router (no dependencies)
app.include_router(health_router)
app.include_router(auth_router)

from routers.image_proxy import router as image_proxy_router
app.include_router(image_proxy_router)

# Other routers - services will be lazily loaded if None
app.include_router(create_product_router(_product_service))
app.include_router(create_ingredient_router(_ingredient_service))
app.include_router(create_ingredient_price_router())
app.include_router(create_fridge_router())
app.include_router(create_conversion_gap_research_router())
app.include_router(create_shelf_life_research_router())
app.include_router(create_purchase_verification_router())
# 쿠팡 주문→계정 매칭 API (admin sync, /coupang_orders/me) 당분간 비활성.
# app.include_router(create_coupang_orders_router())
# 에이전트 라우터는 플래그가 켜진 때만 연다. 기본은 꺼짐.
if recipe_agent_enabled():
    app.include_router(create_recipe_agent_router())
    logger.info("[Server] recipe_agent router enabled")
if home_agent_enabled():
    app.include_router(create_home_agent_router())
    logger.info("[Server] home_agent router enabled")
if grocery_agent_enabled():
    app.include_router(create_grocery_agent_router())
    logger.info("[Server] grocery_agent router enabled")


if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 8000))
    host = os.getenv("HOST", "0.0.0.0")
    print(f"\n{'='*60}")
    print(f"[Server] Starting Yorigo Backend on {host}:{port}")
    print(f"{'='*60}\n")
    uvicorn.run(app, host=host, port=port)
