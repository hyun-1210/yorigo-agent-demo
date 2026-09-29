"""Firestore/Storage Admin SDK 초기화."""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

import firebase_admin
from firebase_admin import credentials, firestore, storage

ROOT = Path(__file__).resolve().parents[2]
CRED = ROOT / "backend" / "firebase-service-account.json"
_INIT_LOCK = threading.Lock()


def get_db() -> Any:
    if not firebase_admin._apps:
        with _INIT_LOCK:
            if not firebase_admin._apps:
                if not CRED.exists():
                    raise RuntimeError(f"Missing service account: {CRED}")
                cred = credentials.Certificate(str(CRED))
                firebase_admin.initialize_app(
                    cred, {"storageBucket": "yorigo-f7408.firebasestorage.app"}
                )
    return firestore.client()


def get_bucket() -> Any:
    get_db()
    return storage.bucket()
