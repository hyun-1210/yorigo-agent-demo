"""
Authentication endpoints for Kakao login
"""

import asyncio
import os
import logging
from datetime import date, datetime
from typing import Dict, Any, Optional
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from urllib.parse import urlencode
import httpx
from models import (
    KakaoTokenRequest,
    KakaoTokenResponse,
    KakaoLinkRequest,
    KakaoLinkResponse,
    KakaoUnlinkRequest,
    KakaoUnlinkResponse,
    AccountDeletionRequest,
    AccountDeletionResponse,
    AgeVerificationRequest,
    AgeVerificationResponse,
    PassVerificationRequest,
    PassVerificationResponse,
    NicePassInitRequest,
    NicePassInitResponse,
    SmsVerificationRequest,
    SmsVerificationResponse,
    NiceSmsInitRequest,
    NiceSmsInitResponse,
)
from services.firebase_service import get_firebase_service
from services.pass_verification_service import get_pass_verification_service
from services.compliance_service import delete_user_account_and_data
from firebase_admin import auth as firebase_auth
from firebase_admin import firestore as admin_firestore
from google.cloud.firestore_v1 import FieldFilter
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/auth", tags=["authentication"])

# 카카오 REST API Key (환경 변수에서 가져오기)
KAKAO_REST_API_KEY = (os.getenv("KAKAO_REST_API_KEY") or "").strip()
KAKAO_USER_INFO_URL = "https://kapi.kakao.com/v2/user/me"
KAKAO_LINKS_COLLECTION = "kakaoLinks"
KAKAO_UID_FALLBACK_PREFIX = "kakao_"
MIN_SIGNUP_AGE = 14
KST = ZoneInfo("Asia/Seoul")
PASS_CALLBACK_SCHEME = (os.getenv("PASS_CALLBACK_SCHEME") or "yorigo://pass-callback").strip()
SMS_CALLBACK_SCHEME = (os.getenv("SMS_CALLBACK_SCHEME") or "yorigo://sms-callback").strip()
AGE_VERIFICATION_MODE = (os.getenv("AGE_VERIFICATION_MODE") or "social_only").strip().lower()


def _txn_get_snap(transaction, doc_ref):
    """
    google-cloud-firestore 최신 버전에서 Transaction.get(단일 ref)는 제너레이터를 반환합니다.
    DocumentSnapshot 하나로 처리해야 exists / to_dict()를 호출할 수 있습니다.
    """
    gen = transaction.get(doc_ref)
    try:
        return next(gen)
    except TypeError:
        # 구버전 클라이언트: 바로 Snapshot 반환
        return gen
    except StopIteration:
        return None


async def verify_kakao_token(access_token: str) -> Dict[str, Any]:
    """
    카카오 access token을 검증하고 사용자 정보를 가져옵니다.
    
    Args:
        access_token: 카카오 access token
    
    Returns:
        카카오 사용자 정보 딕셔너리
    
    Raises:
        HTTPException: 토큰 검증 실패 시
    """
    try:
        if not KAKAO_REST_API_KEY:
            logger.error("KAKAO_REST_API_KEY is not configured")
            raise HTTPException(status_code=503, detail="Kakao auth is not configured")

        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(
                KAKAO_USER_INFO_URL,
                headers={
                    "Authorization": f"Bearer {access_token}",
                    "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                },
            )
            
            if response.status_code == 401:
                logger.warning("Kakao token verification failed: Unauthorized")
                raise HTTPException(
                    status_code=401,
                    detail="Invalid or expired Kakao access token"
                )
            
            if response.status_code != 200:
                logger.error("Kakao API error: status=%s", response.status_code)
                raise HTTPException(
                    status_code=response.status_code,
                    detail=f"Kakao API error: {response.status_code}"
                )
            
            user_data = response.json()
            logger.info(f"Kakao user info retrieved: {user_data.get('id')}")
            return user_data
            
    except httpx.TimeoutException:
        logger.error("Kakao API request timeout")
        raise HTTPException(status_code=504, detail="Kakao API request timeout")
    except httpx.RequestError as e:
        logger.error(f"Kakao API request error: {e}")
        raise HTTPException(status_code=503, detail="Failed to connect to Kakao API")
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Unexpected error verifying Kakao token: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")


def _format_kakao_birth_date(kakao_account: Dict[str, Any]) -> Optional[str]:
    """
    카카오 계정 정보에서 YYYY-MM-DD 형태의 생년월일을 구성합니다.
    """
    birthyear = str(kakao_account.get("birthyear") or "").strip()
    birthday = str(kakao_account.get("birthday") or "").strip()  # MMDD
    if len(birthyear) != 4 or len(birthday) != 4 or not (birthyear + birthday).isdigit():
        return None
    month = birthday[:2]
    day = birthday[2:]
    candidate = f"{birthyear}-{month}-{day}"
    try:
        date.fromisoformat(candidate)
    except ValueError:
        return None
    return candidate


def _calculate_age_in_kst(birth_date: date) -> int:
    """
    한국 시간 기준 만 나이를 계산합니다.
    """
    today = datetime.now(KST).date()
    return today.year - birth_date.year - ((today.month, today.day) < (birth_date.month, birth_date.day))


def _requires_profile_completion(user_doc_data: Optional[Dict[str, Any]]) -> bool:
    """
    회원가입 완료 조건(프로필 + 연령검증)을 충족하지 않으면 True.
    """
    if not user_doc_data:
        return True
    name = str(user_doc_data.get("name") or "").strip()
    handle = str(user_doc_data.get("handle") or "").strip()
    birth_date = str(user_doc_data.get("birthDate") or "").strip()
    is_age_verified = user_doc_data.get("isAgeVerified14Plus") is True
    return not (name and handle and birth_date and is_age_verified)


def _is_persistable_email(email: Optional[str]) -> bool:
    """카카오 등 소셜 이메일을 Firestore에 넣어도 되는지 검사."""
    value = str(email or "").strip()
    if not value or len(value) > 254 or " " in value:
        return False
    if value.count("@") != 1:
        return False
    local, _, domain = value.partition("@")
    return bool(local) and "." in domain and not domain.startswith(".") and not domain.endswith(".")


def _should_backfill_user_email(existing_email: Optional[str], new_email: Optional[str]) -> bool:
    """기존 email이 비어 있고 new_email이 유효할 때만 True (절대 overwrite 안 함)."""
    if str(existing_email or "").strip():
        return False
    return _is_persistable_email(new_email)


def _build_nice_callback_redirect_html(redirect_url: str, title: str) -> HTMLResponse:
    html = f"""<!doctype html>
<html lang="ko">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{title}</title>
  </head>
  <body>
    <script>
      window.location.replace("{redirect_url}");
    </script>
    <p>인증 결과를 앱으로 전달하고 있습니다...</p>
  </body>
</html>"""
    return HTMLResponse(content=html, status_code=200)


def _is_social_only_mode() -> bool:
    return AGE_VERIFICATION_MODE == "social_only"


def extract_kakao_user_info(user_data: Dict[str, Any]) -> Dict[str, Optional[str]]:
    """
    카카오 사용자 정보에서 필요한 데이터를 추출합니다.
    
    Args:
        user_data: 카카오 API에서 받은 사용자 정보
    
    Returns:
        추출된 사용자 정보 딕셔너리 (kakao_id, email, display_name)
    
    Raises:
        HTTPException: 필수 정보가 없는 경우
    """
    kakao_id = str(user_data.get("id", ""))
    if not kakao_id:
        raise HTTPException(status_code=400, detail="Kakao user ID not found")
    
    kakao_account = user_data.get("kakao_account", {})
    email = kakao_account.get("email", "")
    
    if not email:
        raise HTTPException(
            status_code=400,
            detail="Kakao email is required. Please provide email permission in Kakao developer console."
        )
    
    # 닉네임 우선, 없으면 이름, 둘 다 없으면 기본값
    profile = kakao_account.get("profile", {})
    display_name = (
        profile.get("nickname") or
        kakao_account.get("name") or
        "카카오 사용자"
    )
    
    return {
        "kakao_id": kakao_id,
        "email": email,
        "display_name": display_name,
        "birth_date": _format_kakao_birth_date(kakao_account),
    }


@router.post("/age/verify", response_model=AgeVerificationResponse)
async def verify_signup_age(request: AgeVerificationRequest):
    """
    가입 연령을 서버에서 최종 판정합니다.
    """
    method = (request.verification_method or "self_reported").strip().lower()
    provider = (request.provider or "unknown").strip().lower()
    raw_birth_date = (request.birth_date or "").strip()

    if not raw_birth_date:
        requires_additional = method == "social_profile"
        if requires_additional:
            available_methods = [] if _is_social_only_mode() else ["pass", "sms"]
            logger.info(
                "Age verify: additional verification required (provider=%s, method=%s, reason=missing_social_birth_date)",
                provider,
                method,
            )
            return AgeVerificationResponse(
                allowed=False,
                is_under_14=False,
                requires_additional_verification=True,
                recommended_verification_method=None,
                available_verification_methods=available_methods,
                computed_age=None,
                reason="missing_social_birth_date",
            )
        raise HTTPException(status_code=400, detail="birth_date is required")

    try:
        parsed_birth_date = date.fromisoformat(raw_birth_date)
    except ValueError:
        raise HTTPException(status_code=400, detail="birth_date must be YYYY-MM-DD")

    computed_age = _calculate_age_in_kst(parsed_birth_date)
    is_under_14 = computed_age < MIN_SIGNUP_AGE
    if is_under_14:
        logger.info(
            "Age verify: denied (provider=%s, method=%s, age=%s, reason=under_minimum_age)",
            provider,
            method,
            computed_age,
        )
        return AgeVerificationResponse(
            allowed=False,
            is_under_14=True,
            requires_additional_verification=False,
            recommended_verification_method=None,
            available_verification_methods=[],
            computed_age=computed_age,
            reason="under_minimum_age",
        )

    recommended_method = None
    logger.info(
        "Age verify: allowed (provider=%s, method=%s, age=%s)",
        provider,
        method,
        computed_age,
    )
    return AgeVerificationResponse(
        allowed=True,
        is_under_14=False,
        requires_additional_verification=False,
        recommended_verification_method=recommended_method,
        available_verification_methods=[],
        computed_age=computed_age,
        reason="eligible",
    )


@router.post("/age/pass/verify", response_model=PassVerificationResponse)
async def verify_pass_token(request: PassVerificationRequest):
    """
    PASS 본인인증 토큰을 검증하고 신뢰 가능한 생년월일을 반환합니다.
    """
    if _is_social_only_mode():
        raise HTTPException(
            status_code=503,
            detail="Additional verification is temporarily disabled (social_only mode)",
        )
    provider = (request.provider or "unknown").strip().lower()
    service = get_pass_verification_service()
    result = service.verify_pass_token(
        verification_token=request.verification_token,
        retry_count=request.retry_count,
        request_id=request.request_id,
    )
    logger.info(
        "PASS verify result (provider=%s, verified=%s, reason=%s, retryable=%s)",
        provider,
        result.verified,
        result.reason,
        result.retryable,
    )
    return PassVerificationResponse(
        verified=result.verified,
        birth_date=result.birth_date,
        verification_method="pass",
        reason=result.reason,
        retryable=result.retryable,
        max_retry_count=service.MAX_RETRY_COUNT,
        reference_id=result.reference_id,
        message=result.message,
    )


@router.post("/age/pass/nice/init", response_model=NicePassInitResponse)
async def init_nice_pass_verification(request: NicePassInitRequest):
    """
    NICE 본인인증 시작에 필요한 암호화 파라미터를 생성합니다.
    """
    if _is_social_only_mode():
        raise HTTPException(
            status_code=503,
            detail="Additional verification is temporarily disabled (social_only mode)",
        )
    provider = (request.provider or "unknown").strip().lower()
    service = get_pass_verification_service()
    try:
        init_result = service.initiate_nice_pass_verification(provider=provider)
    except Exception as exc:
        logger.error("NICE pass init failed (provider=%s): %s", provider, exc)
        raise HTTPException(status_code=503, detail="NICE PASS init failed")
    return NicePassInitResponse(
        request_id=init_result.request_id,
        auth_action_url=init_result.auth_action_url,
        token_version_id=init_result.token_version_id,
        enc_data=init_result.enc_data,
        integrity_value=init_result.integrity_value,
        method_type="get",
    )


@router.api_route(
    "/age/pass/nice/callback",
    methods=["GET", "POST"],
    include_in_schema=False,
    response_class=HTMLResponse,
)
async def nice_pass_callback(request: Request):
    """
    NICE 인증 완료 콜백을 받아 앱으로 전달할 verification_token을 발급합니다.
    """
    if _is_social_only_mode():
        query = urlencode(
            {
                "verified": "false",
                "reason": "social_only_mode",
                "message": "추가 본인인증이 현재 비활성화되어 있습니다.",
                "verification_method": "pass",
            }
        )
        redirect_url = f"{PASS_CALLBACK_SCHEME}?{query}"
        return _build_nice_callback_redirect_html(redirect_url=redirect_url, title="PASS Callback")

    if request.method == "POST":
        params = dict(await request.form())
    else:
        params = dict(request.query_params)

    request_id = str(params.get("receivedata") or "")
    token_version_id = str(params.get("token_version_id") or "")
    enc_data = str(params.get("enc_data") or "")
    integrity_value = str(params.get("integrity_value") or "")

    service = get_pass_verification_service()
    result = service.finalize_nice_pass_callback(
        request_id=request_id,
        token_version_id=token_version_id,
        enc_data=enc_data,
        integrity_value=integrity_value,
    )

    if result.verified and result.verification_token:
        verification_token = result.verification_token
        query = urlencode(
            {
                "verified": "true",
                "verification_token": verification_token,
                "request_id": request_id,
                "verification_method": "pass",
            }
        )
        redirect_url = f"{PASS_CALLBACK_SCHEME}?{query}"
    else:
        query = urlencode(
            {
                "verified": "false",
                "reason": result.reason,
                "message": result.message or "PASS 인증 실패",
                "verification_method": "pass",
            }
        )
        redirect_url = f"{PASS_CALLBACK_SCHEME}?{query}"

    return _build_nice_callback_redirect_html(redirect_url=redirect_url, title="PASS Callback")


@router.post("/age/sms/verify", response_model=SmsVerificationResponse)
async def verify_sms_token(request: SmsVerificationRequest):
    """
    SMS 본인인증 토큰을 검증하고 신뢰 가능한 생년월일을 반환합니다.
    """
    if _is_social_only_mode():
        raise HTTPException(
            status_code=503,
            detail="Additional verification is temporarily disabled (social_only mode)",
        )
    provider = (request.provider or "unknown").strip().lower()
    service = get_pass_verification_service()
    result = service.verify_sms_token(
        verification_token=request.verification_token,
        retry_count=request.retry_count,
        request_id=request.request_id,
    )
    logger.info(
        "SMS verify result (provider=%s, verified=%s, reason=%s, retryable=%s)",
        provider,
        result.verified,
        result.reason,
        result.retryable,
    )
    return SmsVerificationResponse(
        verified=result.verified,
        birth_date=result.birth_date,
        verification_method="sms",
        reason=result.reason,
        retryable=result.retryable,
        max_retry_count=service.MAX_RETRY_COUNT,
        reference_id=result.reference_id,
        message=result.message,
    )


@router.post("/age/sms/nice/init", response_model=NiceSmsInitResponse)
async def init_nice_sms_verification(request: NiceSmsInitRequest):
    """
    NICE SMS 본인인증 시작에 필요한 암호화 파라미터를 생성합니다.
    """
    if _is_social_only_mode():
        raise HTTPException(
            status_code=503,
            detail="Additional verification is temporarily disabled (social_only mode)",
        )
    provider = (request.provider or "unknown").strip().lower()
    service = get_pass_verification_service()
    try:
        init_result = service.initiate_nice_sms_verification(provider=provider)
    except Exception as exc:
        logger.error("NICE sms init failed (provider=%s): %s", provider, exc)
        raise HTTPException(status_code=503, detail="NICE SMS init failed")
    return NiceSmsInitResponse(
        request_id=init_result.request_id,
        auth_action_url=init_result.auth_action_url,
        token_version_id=init_result.token_version_id,
        enc_data=init_result.enc_data,
        integrity_value=init_result.integrity_value,
        method_type="get",
    )


@router.api_route(
    "/age/sms/nice/callback",
    methods=["GET", "POST"],
    include_in_schema=False,
    response_class=HTMLResponse,
)
async def nice_sms_callback(request: Request):
    """
    NICE SMS 인증 완료 콜백을 받아 앱으로 전달할 verification_token을 발급합니다.
    """
    if _is_social_only_mode():
        query = urlencode(
            {
                "verified": "false",
                "reason": "social_only_mode",
                "message": "추가 본인인증이 현재 비활성화되어 있습니다.",
                "verification_method": "sms",
            }
        )
        redirect_url = f"{SMS_CALLBACK_SCHEME}?{query}"
        return _build_nice_callback_redirect_html(redirect_url=redirect_url, title="SMS Callback")

    if request.method == "POST":
        params = dict(await request.form())
    else:
        params = dict(request.query_params)

    request_id = str(params.get("receivedata") or "")
    token_version_id = str(params.get("token_version_id") or "")
    enc_data = str(params.get("enc_data") or "")
    integrity_value = str(params.get("integrity_value") or "")

    service = get_pass_verification_service()
    result = service.finalize_nice_sms_callback(
        request_id=request_id,
        token_version_id=token_version_id,
        enc_data=enc_data,
        integrity_value=integrity_value,
    )

    if result.verified and result.verification_token:
        verification_token = result.verification_token
        query = urlencode(
            {
                "verified": "true",
                "verification_token": verification_token,
                "request_id": request_id,
                "verification_method": "sms",
            }
        )
        redirect_url = f"{SMS_CALLBACK_SCHEME}?{query}"
    else:
        query = urlencode(
            {
                "verified": "false",
                "reason": result.reason,
                "message": result.message or "SMS 인증 실패",
                "verification_method": "sms",
            }
        )
        redirect_url = f"{SMS_CALLBACK_SCHEME}?{query}"

    return _build_nice_callback_redirect_html(redirect_url=redirect_url, title="SMS Callback")


@router.post("/kakao/custom-token", response_model=KakaoTokenResponse)
async def create_kakao_custom_token(request: KakaoTokenRequest):
    """
    카카오 access token을 검증하고 Firebase Custom Token을 생성합니다.
    
    Args:
        request: 카카오 access token을 포함한 요청
    
    Returns:
        Firebase Custom Token과 카카오 사용자 정보
    
    Raises:
        HTTPException: 토큰 검증 실패 또는 Custom Token 생성 실패 시
    """
    try:
        # 1. 카카오 토큰 검증 및 사용자 정보 가져오기
        user_data = await verify_kakao_token(request.access_token)
        
        # 2. 사용자 정보 추출
        user_info = extract_kakao_user_info(user_data)
        kakao_id = user_info["kakao_id"]
        email = user_info["email"]
        display_name = user_info["display_name"]
        
        # 3. Firebase Custom Token 생성
        # UID는 kakaoLinks/{kakao_id} 매핑을 우선 사용 (유일성/일관성 강제)
        firebase_service = get_firebase_service()
        if not firebase_service.is_available():
            # Firestore가 unavailable이면 기존 fallback UID 정책을 사용
            firebase_uid = f"{KAKAO_UID_FALLBACK_PREFIX}{kakao_id}"
        else:
            fallback_uid = f"{KAKAO_UID_FALLBACK_PREFIX}{kakao_id}"
            db = firebase_service.db
            if db is None:
                firebase_uid = fallback_uid
            else:
                # Backward compatibility:
                # 이전 버전에서 kakaoId만 users/{uid}에 저장했을 수 있으므로,
                # kakaoLinks 매핑이 없으면 users에서 kakaoId를 찾아 uid를 복구 시도합니다.
                # NOTE: Firestore SDK는 동기 I/O이므로 to_thread로 감싸 event loop 블로킹을 방지.
                def _find_existing_uid_from_users() -> Optional[str]:
                    users_query = (
                        db.collection("users")
                        .where(filter=FieldFilter("kakaoId", "==", kakao_id))
                        .limit(1)
                    )
                    for doc in users_query.stream():
                        return doc.id
                    return None

                existing_uid_from_users = None
                try:
                    existing_uid_from_users = await asyncio.to_thread(
                        _find_existing_uid_from_users
                    )
                except Exception as e:
                    logger.warning(f"Failed to backfill kakaoLinks from users.kakaoId: {e}")

                candidate_uid = existing_uid_from_users or fallback_uid

                link_ref = db.collection(KAKAO_LINKS_COLLECTION).document(kakao_id)

                @admin_firestore.transactional
                def _resolve_uid(transaction):
                    snap = _txn_get_snap(transaction, link_ref)
                    if snap is not None and snap.exists:
                        data = snap.to_dict() or {}
                        existing_uid = data.get("uid")
                        if existing_uid:
                            return str(existing_uid)

                    # 매핑이 없으면 candidate uid로 매핑을 생성해서 안정성을 확보
                    transaction.set(
                        link_ref,
                        {"uid": candidate_uid, "updatedAt": admin_firestore.SERVER_TIMESTAMP},
                        merge=False,
                    )
                    return candidate_uid

                transaction = db.transaction()
                firebase_uid = await asyncio.to_thread(_resolve_uid, transaction)
        
        if not firebase_service.is_available():
            raise HTTPException(
                status_code=503,
                detail="Firebase service is not available"
            )
        
        # 추가 클레임에 카카오 정보 포함
        additional_claims = {
            "kakao_id": kakao_id,
            "email": email,
            "provider": "kakao",
        }
        
        custom_token = await asyncio.to_thread(
            firebase_service.create_custom_token,
            uid=firebase_uid,
            additional_claims=additional_claims,
        )

        requires_profile_completion = False
        db = firebase_service.db
        if db is not None:
            try:
                user_doc = await asyncio.to_thread(
                    lambda: db.collection("users").document(firebase_uid).get()
                )
                user_data = user_doc.to_dict() if user_doc.exists else None
                requires_profile_completion = _requires_profile_completion(user_data)
            except Exception as e:
                logger.warning("Failed to check profile completion for uid=%s: %s", firebase_uid, e)
        
        logger.info(f"Created Firebase custom token for Kakao user: {kakao_id}")
        
        return KakaoTokenResponse(
            custom_token=custom_token,
            kakao_id=kakao_id,
            email=email,
            display_name=display_name,
            birth_date=user_info.get("birth_date"),
            requires_profile_completion=requires_profile_completion,
        )
        
    except HTTPException:
        raise
    except ValueError as e:
        logger.error(f"Value error creating custom token: {e}")
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error(f"Unexpected error creating custom token: {e}")
        raise HTTPException(status_code=500, detail="Failed to create custom token")


class KakaoAlreadyLinkedToOtherUidError(Exception):
    def __init__(self, existing_uid: str):
        super().__init__(existing_uid)
        self.existing_uid = existing_uid


@router.post("/kakao/link", response_model=KakaoLinkResponse)
async def link_kakao_account(request: KakaoLinkRequest):
    """
    현재 Firebase 유저에 카카오 계정을 연결(link)합니다.
    - Firestore에서 kakao_id -> uid 1:1 매핑을 강제합니다.
    - 이미 다른 uid에 연결된 kakao_id면 409 반환합니다.
    """
    firebase_service = get_firebase_service()
    if not firebase_service.is_available() or firebase_service.db is None:
        raise HTTPException(status_code=503, detail="Firebase service is not available")

    # 1) verify Kakao token & extract kakao_id/email/display_name
    user_data = await verify_kakao_token(request.access_token)
    user_info = extract_kakao_user_info(user_data)
    kakao_id = user_info["kakao_id"]
    kakao_email = str(user_info.get("email") or "").strip()

    # 2) verify Firebase ID token to get current uid
    # NOTE: firebase_auth.verify_id_token은 동기 I/O. to_thread로 감싸 event loop 블로킹 방지.
    try:
        decoded = await asyncio.to_thread(
            firebase_auth.verify_id_token, request.firebase_id_token
        )
        firebase_uid = decoded.get("uid")
    except Exception as e:
        logger.warning(f"Invalid Firebase ID token for Kakao link: {e}")
        raise HTTPException(status_code=401, detail="Invalid Firebase ID token")

    if not firebase_uid:
        raise HTTPException(status_code=401, detail="Invalid Firebase ID token")

    db = firebase_service.db

    # Backward compatibility:
    # kakaoLinks 매핑이 아직 없더라도, 예전 방식으로 users.kakaoId에만 저장된 데이터가 있을 수 있습니다.
    # 이 경우에도 1:1 매핑을 강제하기 위해 users를 먼저 확인합니다.
    def _find_existing_uid_from_users() -> Optional[str]:
        users_query = (
            db.collection("users")
            .where(filter=FieldFilter("kakaoId", "==", kakao_id))
            .limit(1)
        )
        for doc in users_query.stream():
            return doc.id
        return None

    existing_uid_from_users = None
    try:
        existing_uid_from_users = await asyncio.to_thread(
            _find_existing_uid_from_users
        )
    except Exception as e:
        logger.warning(f"Failed to check users.kakaoId for Kakao link: {e}")

    link_ref = db.collection(KAKAO_LINKS_COLLECTION).document(kakao_id)
    user_ref = db.collection("users").document(firebase_uid)

    # 3) transaction: enforce kakao_id -> uid uniqueness
    @admin_firestore.transactional
    def _txn(transaction):
        snap = _txn_get_snap(transaction, link_ref)
        if snap is not None and snap.exists:
            data = snap.to_dict() or {}
            existing_uid = data.get("uid")
            if existing_uid and str(existing_uid) != str(firebase_uid):
                raise KakaoAlreadyLinkedToOtherUidError(str(existing_uid))
        else:
            if existing_uid_from_users and str(existing_uid_from_users) != str(firebase_uid):
                raise KakaoAlreadyLinkedToOtherUidError(str(existing_uid_from_users))

        # map kakao_id to this uid
        transaction.set(
            link_ref,
            {"uid": firebase_uid, "updatedAt": admin_firestore.SERVER_TIMESTAMP},
            merge=False,
        )
        # keep app user doc in sync (for quick UI checks)
        transaction.set(
            user_ref,
            {"kakaoId": kakao_id, "updatedAt": admin_firestore.SERVER_TIMESTAMP},
            merge=True,
        )

    try:
        transaction = db.transaction()
        await asyncio.to_thread(_txn, transaction)
    except KakaoAlreadyLinkedToOtherUidError as e:
        raise HTTPException(status_code=409, detail="이미 다른 계정에 연결된 카카오 계정입니다.")

    # 4) users.email이 비어 있을 때만 카카오 이메일 backfill (기존 email 절대 덮어쓰지 않음)
    # Auth email은 변경하지 않음 → email-already-in-use 충돌 회피
    if _is_persistable_email(kakao_email):
        def _backfill_email_if_empty() -> bool:
            snap = user_ref.get()
            data = snap.to_dict() or {} if snap.exists else {}
            existing = str(data.get("email") or "").strip()
            if not _should_backfill_user_email(existing, kakao_email):
                return False
            user_ref.set(
                {
                    "email": kakao_email,
                    "emailSource": "kakao",
                    "updatedAt": admin_firestore.SERVER_TIMESTAMP,
                },
                merge=True,
            )
            return True

        try:
            wrote = await asyncio.to_thread(_backfill_email_if_empty)
            if wrote:
                logger.info(
                    "Backfilled empty users.email from Kakao link uid=%s",
                    firebase_uid,
                )
        except Exception as e:
            logger.warning(
                "Failed to backfill Kakao email for uid=%s: %s", firebase_uid, e
            )

    return KakaoLinkResponse(kakao_id=kakao_id, uid=firebase_uid, linked=True)


@router.post("/kakao/unlink", response_model=KakaoUnlinkResponse)
async def unlink_kakao_account(request: KakaoUnlinkRequest):
    """
    현재 Firebase 유저의 카카오 연결을 해제합니다.
    - users/{uid}.kakaoId를 null/delete
    - kakaoLinks/{kakao_id} 매핑을 제거합니다.
    """
    firebase_service = get_firebase_service()
    if not firebase_service.is_available() or firebase_service.db is None:
        raise HTTPException(status_code=503, detail="Firebase service is not available")

    # NOTE: firebase_auth.verify_id_token은 동기 I/O. to_thread로 감싸 event loop 블로킹 방지.
    try:
        decoded = await asyncio.to_thread(
            firebase_auth.verify_id_token, request.firebase_id_token
        )
        firebase_uid = decoded.get("uid")
    except Exception as e:
        logger.warning(f"Invalid Firebase ID token for Kakao unlink: {e}")
        raise HTTPException(status_code=401, detail="Invalid Firebase ID token")

    if not firebase_uid:
        raise HTTPException(status_code=401, detail="Invalid Firebase ID token")

    db = firebase_service.db
    user_ref = db.collection("users").document(firebase_uid)

    # Load user's current kakaoId
    user_doc = await asyncio.to_thread(user_ref.get)
    if not user_doc.exists:
        raise HTTPException(status_code=400, detail="로그인이 필요합니다.")

    data = user_doc.to_dict() or {}
    kakao_id = data.get("kakaoId")
    if not kakao_id:
        raise HTTPException(status_code=400, detail="연결되지 않은 계정입니다.")

    kakao_id = str(kakao_id)
    link_ref = db.collection(KAKAO_LINKS_COLLECTION).document(kakao_id)

    @admin_firestore.transactional
    def _txn(transaction):
        # Remove mapping only if it points to this uid (safety)
        snap = _txn_get_snap(transaction, link_ref)
        if snap is not None and snap.exists:
            existing = snap.to_dict() or {}
            existing_uid = existing.get("uid")
            if existing_uid and str(existing_uid) != str(firebase_uid):
                # 데이터가 꼬인 경우: 매핑을 건드리지 않음
                return
            transaction.delete(link_ref)

        # Remove kakaoId from user doc
        transaction.update(
            user_ref,
            {"kakaoId": None, "updatedAt": admin_firestore.SERVER_TIMESTAMP},
        )

    transaction = db.transaction()
    await asyncio.to_thread(_txn, transaction)

    return KakaoUnlinkResponse(kakao_id=kakao_id, uid=firebase_uid, unlinked=True)


@router.post("/account/delete", response_model=AccountDeletionResponse)
async def delete_account(request: AccountDeletionRequest):
    """
    서버 주도 계정 삭제:
    - 사용자 소유/연관 데이터 확장 삭제
    - 법령상 보존 플래그(deletionLegalHold) 예외 처리
    """
    firebase_service = get_firebase_service()
    if not firebase_service.is_available() or firebase_service.db is None:
        raise HTTPException(status_code=503, detail="Firebase service is not available")

    # NOTE: firebase_auth.verify_id_token은 동기 I/O. to_thread로 감싸 event loop 블로킹 방지.
    try:
        decoded = await asyncio.to_thread(
            firebase_auth.verify_id_token, request.firebase_id_token
        )
        firebase_uid = decoded.get("uid")
    except Exception as e:
        logger.warning(f"Invalid Firebase ID token for account deletion: {e}")
        raise HTTPException(status_code=401, detail="Invalid Firebase ID token")

    if not firebase_uid:
        raise HTTPException(status_code=401, detail="Invalid Firebase ID token")

    # delete_user_account_and_data는 다수의 Firestore 컬렉션 삭제를 수행하는 매우 무거운 동기 작업.
    # to_thread로 감싸지 않으면 삭제하는 수 초 ~ 수십 초 동안 워커 전체가 정지한다.
    try:
        summary = await asyncio.to_thread(
            delete_user_account_and_data,
            db=firebase_service.db,
            uid=firebase_uid,
            reason="user_requested_account_deletion",
            requested_by="self",
        )
        return AccountDeletionResponse(
            uid=summary.uid,
            deleted=summary.deleted,
            legal_hold_applied=summary.legal_hold_applied,
            deleted_counts=summary.deleted_counts,
            message=summary.message,
        )
    except Exception as e:
        logger.exception("Account deletion failed (uid=%s): %s", firebase_uid, e)
        raise HTTPException(status_code=500, detail="Failed to delete account")

