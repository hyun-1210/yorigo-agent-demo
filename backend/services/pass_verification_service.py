"""
PASS 본인인증 토큰 검증 서비스.

지원 모드:
- mock: `PASS_BIRTHDATE:YYYY-MM-DD` 토큰 수동 검증
- nice: NICE API 기반 실연동 (암호화 토큰 발급 + 결과 복호화)
- disabled: 비활성
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
import time
import uuid
from dataclasses import dataclass
from datetime import date
from typing import Dict, Optional

import httpx

from utils.deployment_env import get_public_api_domain
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

logger = logging.getLogger(__name__)


@dataclass
class PassVerificationResult:
    verified: bool
    reason: str
    birth_date: Optional[str] = None
    retryable: bool = False
    reference_id: Optional[str] = None
    message: Optional[str] = None
    verification_token: Optional[str] = None
    verification_method: str = "pass"


@dataclass
class NicePassInitResult:
    request_id: str
    auth_action_url: str
    token_version_id: str
    enc_data: str
    integrity_value: str
    verification_method: str = "pass"


@dataclass
class _NicePendingSession:
    request_id: str
    key: str
    iv: str
    hmac_key: str
    created_at: float
    expires_at: float
    provider: str
    req_no: str
    token_version_id: str
    verification_method: str


class PassVerificationService:
    """
    PASS 토큰 검증을 담당하는 서비스.
    """

    MAX_RETRY_COUNT = 3
    SESSION_TTL_SECONDS = 600
    VERIFIED_TOKEN_TTL_SECONDS = 900
    NICE_API_BASE = "https://svc.niceapi.co.kr:22001"
    NICE_AUTH_ACTION_URL = "https://nice.checkplus.co.kr/CheckPlusSafeModel/checkplus.cb"

    def __init__(self) -> None:
        self.verify_mode = (os.getenv("PASS_VERIFY_MODE") or "mock").strip().lower()
        self._pending_sessions: Dict[str, _NicePendingSession] = {}
        self._issued_tokens: Dict[str, Dict[str, str]] = {}
        self._nice_client_token: Optional[str] = None

    def initiate_nice_verification(
        self,
        provider: str,
        verification_method: str = "pass",
    ) -> NicePassInitResult:
        if self.verify_mode != "nice":
            raise RuntimeError("NICE mode is disabled. Set PASS_VERIFY_MODE=nice")
        verification_method = (verification_method or "pass").strip().lower()
        if verification_method not in {"pass", "sms"}:
            raise RuntimeError(f"Unsupported verification_method: {verification_method}")

        self._purge_expired_items()

        req_dtim = time.strftime("%Y%m%d%H%M%S")
        req_no = f"REQ{req_dtim}{secrets.token_hex(4).upper()}"
        request_id = f"nice_{uuid.uuid4().hex}"
        access_token = self._request_nice_client_token()
        crypto_data = self._request_nice_crypto_token(
            access_token=access_token,
            req_dtim=req_dtim,
            req_no=req_no,
        )

        token_val = str(crypto_data.get("token_val") or "")
        site_code = str(crypto_data.get("site_code") or "")
        token_version_id = str(crypto_data.get("token_version_id") or "")
        if not token_val or not site_code or not token_version_id:
            raise RuntimeError("NICE crypto token response is missing required fields")

        key, iv, hmac_key = self._derive_symmetric_keys(
            req_dtim=req_dtim,
            req_no=req_no,
            token_val=token_val,
        )
        return_url = self._get_nice_callback_url(verification_method=verification_method)
        request_payload = {
            "requestno": req_no,
            "returnurl": return_url,
            "sitecode": site_code,
            "authtype": "M",
            "methodtype": "get",
            "popupyn": "Y",
            "receivedata": request_id,
        }
        plain_text = json.dumps(request_payload, ensure_ascii=False, separators=(",", ":"))
        enc_data = self._encrypt_aes_cbc(plain_text=plain_text, key=key, iv=iv)
        integrity_value = base64.b64encode(
            hmac.new(hmac_key.encode("utf-8"), enc_data.encode("utf-8"), hashlib.sha256).digest()
        ).decode("utf-8")

        self._pending_sessions[request_id] = _NicePendingSession(
            request_id=request_id,
            key=key,
            iv=iv,
            hmac_key=hmac_key,
            created_at=time.time(),
            expires_at=time.time() + self.SESSION_TTL_SECONDS,
            provider=provider,
            req_no=req_no,
            token_version_id=token_version_id,
            verification_method=verification_method,
        )

        auth_action = self._get_nice_auth_action_url(verification_method=verification_method)
        return NicePassInitResult(
            request_id=request_id,
            auth_action_url=auth_action,
            token_version_id=token_version_id,
            enc_data=enc_data,
            integrity_value=integrity_value,
            verification_method=verification_method,
        )

    def finalize_nice_callback(
        self,
        request_id: str,
        token_version_id: str,
        enc_data: str,
        integrity_value: str,
        verification_method: str = "pass",
    ) -> PassVerificationResult:
        self._purge_expired_items()
        verification_method = (verification_method or "pass").strip().lower()
        if verification_method not in {"pass", "sms"}:
            return PassVerificationResult(
                verified=False,
                reason="unsupported_verification_method",
                retryable=False,
                message="지원하지 않는 본인인증 방식입니다.",
                verification_method=verification_method,
            )

        pending = self._pending_sessions.get(request_id)
        if pending is None and token_version_id:
            for session in self._pending_sessions.values():
                if session.token_version_id == token_version_id:
                    pending = session
                    request_id = session.request_id
                    break
        if pending is None:
            return PassVerificationResult(
                verified=False,
                reason="session_not_found",
                retryable=True,
                message="PASS 인증 세션이 만료되었거나 유효하지 않습니다.",
                verification_method=verification_method,
            )
        if pending.verification_method != verification_method:
            return PassVerificationResult(
                verified=False,
                reason="verification_method_mismatch",
                retryable=False,
                message="인증 방식이 세션 정보와 일치하지 않습니다.",
                verification_method=verification_method,
            )

        expected_integrity = base64.b64encode(
            hmac.new(pending.hmac_key.encode("utf-8"), enc_data.encode("utf-8"), hashlib.sha256).digest()
        ).decode("utf-8")
        if not hmac.compare_digest(expected_integrity, integrity_value):
            return PassVerificationResult(
                verified=False,
                reason="integrity_mismatch",
                retryable=False,
                message="PASS 인증 결과 무결성 검증에 실패했습니다.",
                verification_method=verification_method,
            )

        try:
            decoded = self._decrypt_aes_cbc(enc_data=enc_data, key=pending.key, iv=pending.iv)
            payload = json.loads(decoded)
        except Exception as exc:
            logger.warning("NICE callback decrypt failed: %s", exc)
            return PassVerificationResult(
                verified=False,
                reason="decrypt_failed",
                retryable=False,
                message="PASS 인증 결과 복호화에 실패했습니다.",
                verification_method=verification_method,
            )

        result_code = str(payload.get("resultcode") or payload.get("resultCode") or "")
        birth_date_raw = str(payload.get("birthdate") or "").strip()
        if result_code != "0000":
            return PassVerificationResult(
                verified=False,
                reason=f"nice_result_{result_code or 'unknown'}",
                retryable=True,
                message="PASS 본인인증이 완료되지 않았습니다.",
                verification_method=verification_method,
            )
        if len(birth_date_raw) != 8 or not birth_date_raw.isdigit():
            return PassVerificationResult(
                verified=False,
                reason="birthdate_missing",
                retryable=False,
                message="PASS 인증 결과에서 생년월일을 확인할 수 없습니다.",
                verification_method=verification_method,
            )

        birth_date = f"{birth_date_raw[:4]}-{birth_date_raw[4:6]}-{birth_date_raw[6:]}"
        try:
            date.fromisoformat(birth_date)
        except ValueError:
            return PassVerificationResult(
                verified=False,
                reason="birthdate_invalid",
                retryable=False,
                message="PASS 인증 생년월일 형식이 올바르지 않습니다.",
                verification_method=verification_method,
            )

        verification_token = f"{verification_method.upper()}_VERIFIED:{uuid.uuid4().hex}"
        self._issued_tokens[verification_token] = {
            "birth_date": birth_date,
            "expires_at": str(time.time() + self.VERIFIED_TOKEN_TTL_SECONDS),
            "reference_id": token_version_id,
            "verification_method": verification_method,
        }
        self._pending_sessions.pop(request_id, None)

        return PassVerificationResult(
            verified=True,
            reason="verified",
            birth_date=birth_date,
            retryable=False,
            reference_id=token_version_id,
            message="PASS 본인인증이 완료되었습니다.",
            verification_token=verification_token,
            verification_method=verification_method,
        )

    def verify_token(
        self,
        verification_token: str,
        retry_count: int = 0,
        request_id: Optional[str] = None,
        verification_method: str = "pass",
    ) -> PassVerificationResult:
        self._purge_expired_items()
        verification_method = (verification_method or "pass").strip().lower()
        if verification_method not in {"pass", "sms"}:
            return PassVerificationResult(
                verified=False,
                reason="unsupported_verification_method",
                retryable=False,
                reference_id=request_id or str(uuid.uuid4()),
                message="지원하지 않는 본인인증 방식입니다.",
                verification_method=verification_method,
            )

        reference_id = request_id or str(uuid.uuid4())
        if retry_count >= self.MAX_RETRY_COUNT:
            return PassVerificationResult(
                verified=False,
                reason="retry_limit_exceeded",
                retryable=False,
                reference_id=reference_id,
                message="본인인증 재시도 횟수를 초과했습니다. 잠시 후 다시 시도해주세요.",
                verification_method=verification_method,
            )

        token = (verification_token or "").strip()
        if not token:
            return PassVerificationResult(
                verified=False,
                reason="empty_token",
                retryable=True,
                reference_id=reference_id,
                message="PASS 인증 토큰이 비어 있습니다.",
                verification_method=verification_method,
            )

        if self.verify_mode == "disabled":
            return PassVerificationResult(
                verified=False,
                reason="pass_disabled",
                retryable=False,
                reference_id=reference_id,
                message="PASS 인증이 현재 비활성화되어 있습니다.",
                verification_method=verification_method,
            )

        if self.verify_mode == "mock":
            return self._verify_mock(
                token=token,
                reference_id=reference_id,
                verification_method=verification_method,
            )

        if self.verify_mode == "nice":
            return self._verify_nice_token(
                token=token,
                reference_id=reference_id,
                verification_method=verification_method,
            )

        return PassVerificationResult(
            verified=False,
            reason="unsupported_mode",
            retryable=False,
            reference_id=reference_id,
            message=f"지원하지 않는 PASS 모드입니다: {self.verify_mode}",
            verification_method=verification_method,
        )

    def _verify_mock(
        self,
        token: str,
        reference_id: str,
        verification_method: str,
    ) -> PassVerificationResult:
        prefix = "PASS_BIRTHDATE:" if verification_method == "pass" else "SMS_BIRTHDATE:"
        if not token.startswith(prefix):
            logger.warning("PASS mock verify failed: invalid token format")
            return PassVerificationResult(
                verified=False,
                reason="invalid_token_format",
                retryable=True,
                reference_id=reference_id,
                message="PASS 토큰 형식이 올바르지 않습니다.",
                verification_method=verification_method,
            )

        birth_date_str = token[len(prefix) :].strip()
        try:
            date.fromisoformat(birth_date_str)
        except ValueError:
            return PassVerificationResult(
                verified=False,
                reason="invalid_birth_date",
                retryable=True,
                reference_id=reference_id,
                message="PASS 생년월일 형식이 올바르지 않습니다.",
                verification_method=verification_method,
            )

        logger.info("PASS mock verify success (reference_id=%s)", reference_id)
        return PassVerificationResult(
            verified=True,
            reason="verified",
            birth_date=birth_date_str,
            retryable=False,
            reference_id=reference_id,
            message="PASS 본인인증이 완료되었습니다.",
            verification_method=verification_method,
        )

    def _verify_nice_token(
        self,
        token: str,
        reference_id: str,
        verification_method: str,
    ) -> PassVerificationResult:
        issued = self._issued_tokens.pop(token, None)
        if issued is None:
            return PassVerificationResult(
                verified=False,
                reason="invalid_or_expired_token",
                retryable=True,
                reference_id=reference_id,
                message="PASS 인증 토큰이 유효하지 않거나 만료되었습니다.",
                verification_method=verification_method,
            )
        issued_method = (issued.get("verification_method") or "pass").strip().lower()
        if issued_method != verification_method:
            return PassVerificationResult(
                verified=False,
                reason="verification_method_mismatch",
                retryable=False,
                reference_id=reference_id,
                message="인증 토큰 방식이 요청과 일치하지 않습니다.",
                verification_method=verification_method,
            )
        birth_date = issued.get("birth_date")
        if not birth_date:
            return PassVerificationResult(
                verified=False,
                reason="birth_date_missing",
                retryable=False,
                reference_id=reference_id,
                message="PASS 인증 결과가 올바르지 않습니다.",
                verification_method=verification_method,
            )
        return PassVerificationResult(
            verified=True,
            reason="verified",
            birth_date=birth_date,
            retryable=False,
            reference_id=issued.get("reference_id") or reference_id,
            message="PASS 본인인증이 완료되었습니다.",
            verification_method=verification_method,
        )

    def _request_nice_client_token(self) -> str:
        if self._nice_client_token:
            return self._nice_client_token

        client_id = (os.getenv("NICE_CLIENT_ID") or "").strip()
        client_secret = (os.getenv("NICE_CLIENT_SECRET") or "").strip()
        if not client_id or not client_secret:
            raise RuntimeError("NICE_CLIENT_ID / NICE_CLIENT_SECRET is not configured")

        auth_bytes = f"{client_id}:{client_secret}".encode("utf-8")
        auth_header = base64.b64encode(auth_bytes).decode("utf-8")
        scope = (os.getenv("NICE_OAUTH_SCOPE") or "default").strip()
        url = f"{self.NICE_API_BASE}/digital/niceid/oauth/oauth/token"

        with httpx.Client(timeout=10.0) as client:
            response = client.post(
                url,
                headers={
                    "Authorization": f"Basic {auth_header}",
                    "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                },
                data={
                    "grant_type": "client_credentials",
                    "scope": scope,
                },
            )
        if response.status_code != 200:
            raise RuntimeError(f"NICE oauth token request failed: {response.status_code}")

        payload = response.json()
        token = payload.get("access_token") or payload.get("dataBody", {}).get("access_token")
        if not token:
            raise RuntimeError("NICE oauth response does not include access_token")
        self._nice_client_token = str(token)
        return self._nice_client_token

    def _request_nice_crypto_token(
        self,
        access_token: str,
        req_dtim: str,
        req_no: str,
    ) -> Dict[str, str]:
        client_id = (os.getenv("NICE_CLIENT_ID") or "").strip()
        product_id = (os.getenv("NICE_PRODUCT_ID") or "").strip()
        if not client_id or not product_id:
            raise RuntimeError("NICE_CLIENT_ID / NICE_PRODUCT_ID is not configured")

        now_ts = int(time.time())
        bearer = base64.b64encode(f"{access_token}:{now_ts}:{client_id}".encode("utf-8")).decode("utf-8")
        url = f"{self.NICE_API_BASE}/digital/niceid/api/v1.0/common/crypto/token"

        body = {
            "dataHeader": {"CNTY_CD": "ko"},
            "dataBody": {
                "req_dtim": req_dtim,
                "req_no": req_no,
                "enc_mode": "1",
            },
        }

        with httpx.Client(timeout=10.0) as client:
            response = client.post(
                url,
                headers={
                    "Authorization": f"bearer {bearer}",
                    "productID": product_id,
                    "Content-Type": "application/json",
                },
                json=body,
            )
        if response.status_code != 200:
            raise RuntimeError(f"NICE crypto token request failed: {response.status_code}")

        payload = response.json()
        data_body = payload.get("dataBody") or {}
        rsp_cd = str(data_body.get("rsp_cd") or "")
        result_cd = str(data_body.get("result_cd") or "")
        if rsp_cd and rsp_cd != "P000":
            raise RuntimeError(f"NICE crypto token response error: rsp_cd={rsp_cd}")
        if result_cd and result_cd != "0000":
            raise RuntimeError(f"NICE crypto token response error: result_cd={result_cd}")
        return data_body

    def _derive_symmetric_keys(self, req_dtim: str, req_no: str, token_val: str) -> tuple[str, str, str]:
        seed = f"{req_dtim}{req_no}{token_val}".encode("utf-8")
        key_hash_b64 = base64.b64encode(hashlib.sha256(seed).digest()).decode("utf-8")
        key = key_hash_b64[:16]
        iv = key_hash_b64[-16:]
        hmac_key = key_hash_b64[:32]
        return key, iv, hmac_key

    def _encrypt_aes_cbc(self, plain_text: str, key: str, iv: str) -> str:
        padder = padding.PKCS7(128).padder()
        padded = padder.update(plain_text.encode("utf-8")) + padder.finalize()
        cipher = Cipher(algorithms.AES(key.encode("utf-8")), modes.CBC(iv.encode("utf-8")))
        encryptor = cipher.encryptor()
        encrypted = encryptor.update(padded) + encryptor.finalize()
        return base64.b64encode(encrypted).decode("utf-8")

    def _decrypt_aes_cbc(self, enc_data: str, key: str, iv: str) -> str:
        encrypted_bytes = base64.b64decode(enc_data)
        cipher = Cipher(algorithms.AES(key.encode("utf-8")), modes.CBC(iv.encode("utf-8")))
        decryptor = cipher.decryptor()
        decrypted = decryptor.update(encrypted_bytes) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        plain = unpadder.update(decrypted) + unpadder.finalize()
        return plain.decode("utf-8", errors="ignore")

    def _get_nice_callback_url(self, verification_method: str) -> str:
        env_key = "NICE_SMS_RETURN_URL" if verification_method == "sms" else "NICE_PASS_RETURN_URL"
        explicit = (os.getenv(env_key) or "").strip()
        if explicit:
            return explicit
        public_domain = get_public_api_domain()
        if public_domain:
            return f"https://{public_domain}/auth/age/{verification_method}/nice/callback"
        raise RuntimeError(
            f"{env_key} or PUBLIC_API_DOMAIN (or RAILWAY_PUBLIC_DOMAIN) must be configured"
        )

    def _get_nice_auth_action_url(self, verification_method: str) -> str:
        if verification_method == "sms":
            return (os.getenv("NICE_SMS_AUTH_ACTION_URL") or self.NICE_AUTH_ACTION_URL).strip()
        return (os.getenv("NICE_PASS_AUTH_ACTION_URL") or self.NICE_AUTH_ACTION_URL).strip()

    def initiate_nice_pass_verification(self, provider: str) -> NicePassInitResult:
        return self.initiate_nice_verification(provider=provider, verification_method="pass")

    def initiate_nice_sms_verification(self, provider: str) -> NicePassInitResult:
        return self.initiate_nice_verification(provider=provider, verification_method="sms")

    def finalize_nice_pass_callback(
        self,
        request_id: str,
        token_version_id: str,
        enc_data: str,
        integrity_value: str,
    ) -> PassVerificationResult:
        return self.finalize_nice_callback(
            request_id=request_id,
            token_version_id=token_version_id,
            enc_data=enc_data,
            integrity_value=integrity_value,
            verification_method="pass",
        )

    def finalize_nice_sms_callback(
        self,
        request_id: str,
        token_version_id: str,
        enc_data: str,
        integrity_value: str,
    ) -> PassVerificationResult:
        return self.finalize_nice_callback(
            request_id=request_id,
            token_version_id=token_version_id,
            enc_data=enc_data,
            integrity_value=integrity_value,
            verification_method="sms",
        )

    def verify_pass_token(
        self,
        verification_token: str,
        retry_count: int = 0,
        request_id: Optional[str] = None,
    ) -> PassVerificationResult:
        return self.verify_token(
            verification_token=verification_token,
            retry_count=retry_count,
            request_id=request_id,
            verification_method="pass",
        )

    def verify_sms_token(
        self,
        verification_token: str,
        retry_count: int = 0,
        request_id: Optional[str] = None,
    ) -> PassVerificationResult:
        return self.verify_token(
            verification_token=verification_token,
            retry_count=retry_count,
            request_id=request_id,
            verification_method="sms",
        )

    def _purge_expired_items(self) -> None:
        now = time.time()
        expired_session_ids = [
            key
            for key, value in self._pending_sessions.items()
            if value.expires_at < now
        ]
        for key in expired_session_ids:
            self._pending_sessions.pop(key, None)

        expired_tokens = [
            key
            for key, value in self._issued_tokens.items()
            if float(value.get("expires_at") or 0) < now
        ]
        for key in expired_tokens:
            self._issued_tokens.pop(key, None)


_pass_verification_service: Optional[PassVerificationService] = None


def get_pass_verification_service() -> PassVerificationService:
    global _pass_verification_service
    if _pass_verification_service is None:
        _pass_verification_service = PassVerificationService()
    return _pass_verification_service
