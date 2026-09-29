#!/usr/bin/env python3
"""yorigo-f7408 바깥에 백업 전용 GCP 프로젝트·버킷·IAM을 만든다.

Compute/Gemini는 켜지 않는다. 사용자 Google 계정(Owner)이 필요하다.
서비스 계정으로는 프로젝트를 만들 수 없다.

  python ops/backup/provision_backup_project.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from typing import List, Optional, Sequence

SOURCE_PROJECT = "yorigo-f7408"
SOURCE_NUMBER = "784944328733"
SOURCE_SA = f"firebase-adminsdk-fbsvc@{SOURCE_PROJECT}.iam.gserviceaccount.com"
FIRESTORE_SA = f"service-{SOURCE_NUMBER}@gcp-sa-firestore.iam.gserviceaccount.com"
BACKUP_PROJECT = os.getenv("BACKUP_PROJECT_ID", "yorigo-offsite-backup").strip()
BACKUP_BUCKET = os.getenv("BACKUP_BUCKET", "yorigo-offsite-backup-data").strip()
BILLING_ACCOUNT = os.getenv("BACKUP_BILLING_ACCOUNT", "0104DE-F3FF01-C96494").strip()
# 원본 Storage와 같은 리전 → 이그레스 최소화
BUCKET_LOCATION = os.getenv("BACKUP_BUCKET_LOCATION", "us-central1").strip()


def _gcloud_bin() -> str:
    env = (os.getenv("GCLOUD") or "").strip()
    if env:
        return env
    local = os.path.expandvars(
        r"%USERPROFILE%\AppData\Local\Google\CloudSDK\google-cloud-sdk\bin\gcloud.cmd"
    )
    if os.name == "nt" and os.path.isfile(local):
        return local
    found = shutil.which("gcloud")
    if found:
        return found
    raise SystemExit("gcloud 를 찾을 수 없습니다.")


def gcloud(args: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    cmd = [_gcloud_bin(), *args]
    print("+", " ".join(cmd), flush=True)
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.stdout:
        sys.stdout.write(proc.stdout)
    if proc.stderr:
        # gcloud Windows prefix noise
        filtered = "\n".join(
            line
            for line in proc.stderr.splitlines()
            if "platform independent libraries" not in line
        )
        if filtered.strip():
            sys.stderr.write(filtered + "\n")
    if check and proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc


def _active_account() -> str:
    proc = gcloud(
        ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"],
        check=False,
    )
    return (proc.stdout or "").strip().splitlines()[0].strip() if proc.stdout.strip() else ""


def _project_exists(project_id: str) -> bool:
    proc = gcloud(
        ["projects", "describe", project_id, "--format=value(projectId)"],
        check=False,
    )
    return proc.returncode == 0 and (proc.stdout or "").strip() == project_id


def main(argv: Optional[Sequence[str]] = None) -> int:
    del argv
    account = _active_account()
    print(f"active_account={account}", flush=True)
    if not account:
        print(
            "gcloud 로그인이 필요합니다. 로컬에서 `gcloud auth login` 후 다시 실행하세요.",
            file=sys.stderr,
        )
        return 2
    if account.endswith(".iam.gserviceaccount.com"):
        print(
            "지금 활성 계정이 서비스 계정입니다. "
            "`gcloud config set account <user@...>` 로 사용자 계정 전환 후 다시 실행하세요.",
            file=sys.stderr,
        )
        return 2

    if not _project_exists(BACKUP_PROJECT):
        gcloud(
            [
                "projects",
                "create",
                BACKUP_PROJECT,
                f"--name=Yorigo Backup",
                "--quiet",
            ]
        )
    else:
        print(f"project already exists: {BACKUP_PROJECT}", flush=True)

    link = gcloud(
        [
            "billing",
            "projects",
            "link",
            BACKUP_PROJECT,
            f"--billing-account={BILLING_ACCOUNT}",
        ],
        check=False,
    )
    if link.returncode != 0:
        print(
            "결제 계정 연결 실패. 콘솔에서 백업 프로젝트에 결제를 연결하세요. "
            f"https://console.cloud.google.com/billing/linkedaccount?project={BACKUP_PROJECT}",
            flush=True,
        )

    gcloud(
        [
            "services",
            "enable",
            "storage.googleapis.com",
            "iam.googleapis.com",
            f"--project={BACKUP_PROJECT}",
        ]
    )

    buckets = gcloud(
        ["storage", "buckets", "list", f"--project={BACKUP_PROJECT}", "--format=json"],
        check=False,
    )
    names: List[str] = []
    if buckets.returncode == 0 and (buckets.stdout or "").strip().startswith("["):
        try:
            names = [
                (item.get("name") or "").split("/")[-1]
                for item in json.loads(buckets.stdout)
            ]
        except json.JSONDecodeError:
            names = []
    if BACKUP_BUCKET not in names:
        gcloud(
            [
                "storage",
                "buckets",
                "create",
                f"gs://{BACKUP_BUCKET}",
                f"--project={BACKUP_PROJECT}",
                f"--location={BUCKET_LOCATION}",
                "--uniform-bucket-level-access",
                "--public-access-prevention",
            ]
        )
    else:
        print(f"bucket already exists: {BACKUP_BUCKET}", flush=True)

    for member in (SOURCE_SA, FIRESTORE_SA):
        gcloud(
            [
                "storage",
                "buckets",
                "add-iam-policy-binding",
                f"gs://{BACKUP_BUCKET}",
                f"--member=serviceAccount:{member}",
                "--role=roles/storage.admin",
                "--quiet",
            ]
        )

    gcloud(
        [
            "projects",
            "add-iam-policy-binding",
            SOURCE_PROJECT,
            f"--member=serviceAccount:{SOURCE_SA}",
            "--role=roles/datastore.importExportAdmin",
            "--quiet",
        ]
    )

    print(
        json.dumps(
            {
                "backup_project": BACKUP_PROJECT,
                "backup_bucket": BACKUP_BUCKET,
                "source_project": SOURCE_PROJECT,
                "source_sa": SOURCE_SA,
            },
            ensure_ascii=False,
            indent=2,
        ),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
