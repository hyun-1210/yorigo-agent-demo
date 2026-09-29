# Railway → AWS EC2 Migration Guide (Yorigo Backend)

Step-by-step runbook for migrating the Yorigo production backend from **Railway** to **AWS EC2**.

**Current production URL:** `https://yorigo-production.up.railway.app`  
**Target production URL:** `https://api.yorigo.kr`  
**Domain:** `yorigo.kr`  
**Docker image:** `backend/Dockerfile` (`requirements-railway.txt`)  
**Health check:** `GET /health` (returns 503 if Firestore is stuck)  
**AWS region:** `ap-northeast-2` (Seoul)  
**Build & deploy:** **GitHub Actions** → ECR → EC2 (no local Docker required)

> **Application code:** Scheduler decoupling, CORS, and NICE callbacks for AWS are on the migration branch. **Flutter still points at Railway** until AWS cutover (Phase 2 app release).

---

## Safe merge strategy (recommended)

Merge in **two phases** so Railway and store users stay unaffected:

| Phase | Merge to `main` | Production impact |
|-------|-----------------|-------------------|
| **1 — Now** | Backend (`deployment_env.py`, etc.) + `.github/workflows/deploy-backend-ec2.yml` + migration doc | **None** — Railway unchanged; app still uses `yorigo-production.up.railway.app` |
| **2 — After AWS live** | Flutter `environment_config.dart` → `https://api.yorigo.kr` + app store release | Users move to AWS API |

**GitHub Actions on push to `main`:** builds and pushes to ECR only. **Deploy to EC2** runs only when you click **Actions → Run workflow** (manual), not on every merge.

**Before Phase 1 merge:** ECR repo can exist; AWS secrets optional (workflow fails harmlessly if missing). **Do not** release a new app build until Phase 2.

---

## Table of contents

1. [Should you migrate?](#1-should-you-migrate)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [IAM permissions](#4-iam-permissions)
5. [Phase 0 — Inventory Railway configuration](#5-phase-0--inventory-railway-configuration)
6. [Phase 1 — AWS infrastructure (Console)](#6-phase-1--aws-infrastructure-console)
7. [Phase 2 — Secrets and environment variables](#7-phase-2--secrets-and-environment-variables)
8. [Phase 3 — GitHub Actions setup](#8-phase-3--github-actions-setup)
9. [Phase 4 — EC2 bootstrap and first deploy](#9-phase-4--ec2-bootstrap-and-first-deploy)
10. [Phase 5 — Parallel testing](#10-phase-5--parallel-testing)
11. [Phase 6 — DNS cutover and app release](#11-phase-6--dns-cutover-and-app-release)
12. [Phase 7 — Decommission Railway](#12-phase-7--decommission-railway)
13. [Monitoring and alarms](#13-monitoring-and-alarms)
14. [Rollback plan](#14-rollback-plan)
15. [Environment variable reference](#15-environment-variable-reference)
16. [Cookie management on AWS](#16-cookie-management-on-aws)
17. [Known limitations](#17-known-limitations)
18. [Cost estimate](#18-cost-estimate)
19. [Checklist summary](#19-checklist-summary)

---

## 1. Should you migrate?

### Migrate to EC2 if

- Railway CPU/RAM limits hurt recipe parsing (Whisper, OCR, FFmpeg).
- You want predictable cost at steady load.
- You want the API in **Seoul** for lower latency to Korean users.
- Someone can own basic AWS ops (security groups, deploys, monitoring).

### Stay on Railway if

- Railway is stable and cost is acceptable.
- You prefer zero infra maintenance.
- The team is small and product work is higher priority.

### Recommendation

**Yes — EC2 is a good fit** for Yorigo: Dockerized backend, external Firestore, single API node. Start with **one EC2 instance behind an ALB**. Do not run multiple instances until you add distributed locking.

---

## 2. Architecture

### Current (Railway)

```
Flutter App / Web → Railway (Docker) → Firestore / OpenAI / Gemini
```

### Target (AWS)

```
GitHub (push / manual workflow)
       │
       ▼
GitHub Actions (ubuntu-latest)
  ├── docker build
  ├── push → ECR
  └── SSM → EC2 /opt/yorigo/deploy.sh
       │
       ▼
Flutter App / Web
       │
       ▼
Route 53 (api.yorigo.kr) → ALB (HTTPS/ACM) → EC2 (Docker :8000)
       │
       ├── SSM Parameter Store (secrets)
       └── CloudWatch Logs (optional)
       │
       ▼
Firestore / OpenAI / Gemini
```

**You do not need Docker on your Mac.** Images are built on GitHub’s runners.

### What stays off EC2

- Coupang / Kurly scraping schedulers
- Selenium cookie extraction (`backend/tools/run_selenium_cookie_extract.py`)

Production EC2 **consumes** cookies via `YOUTUBE_COOKIES_SOURCE_URL` / `INSTAGRAM_COOKIES_SOURCE_URL`.

### EC2 env behavior (already in code)

Set `ENABLE_PRODUCTION_SCHEDULERS=true` and `PUBLIC_API_DOMAIN=api.yorigo.kr` on EC2.

---

## 3. Prerequisites

### AWS account

- IAM users/roles (see [Section 4](#4-iam-permissions)).
- AWS CLI on your laptop **for setup only** (SSM params, debugging):

```bash
brew install awscli
aws configure          # region: ap-northeast-2, output: json
aws sts get-caller-identity
```

### GitHub

- Repo on GitHub with push access.
- Workflow file: `.github/workflows/deploy-backend-ec2.yml` (included in repo).
- Three repository **secrets** (Settings → Secrets and variables → Actions).

### Domain

- **`yorigo.kr`** with DNS control.
- API subdomain: **`api.yorigo.kr`**.

### Railway access

Export all production variables from Railway → Backend → **Variables**.

### Not required locally

- Docker Desktop
- Colima
- `docker build` on your machine

---

## 4. IAM permissions

### A) IAM user for your laptop (`yorigo-deploy`)

Used for `aws configure`, creating infra, SSM parameters.

**Initial setup:** `AdministratorAccess`  
**Later:** least-privilege for EC2, ELB, ECR, ACM, Route 53, SSM, IAM (EC2 role only).

### B) IAM user for GitHub Actions (`yorigo-github-actions`)

Create a **separate** IAM user. Attach this policy (replace `YOUR_ACCOUNT_ID`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories",
        "ecr:DescribeImages"
      ],
      "Resource": "arn:aws:ecr:ap-northeast-2:YOUR_ACCOUNT_ID:repository/yorigo-backend"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand",
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations"
      ],
      "Resource": "*"
    }
  ]
}
```

Create access keys → store as GitHub secrets (Section 8). **Do not** use your personal deploy keys in GitHub.

### C) EC2 instance role (`yorigo-ec2-role`)

Attach to the EC2 instance:

| Policy | Purpose |
|--------|---------|
| `AmazonEC2ContainerRegistryReadOnly` | `docker pull` from ECR |
| `AmazonSSMReadOnlyAccess` | Read `/yorigo/prod/*` secrets |
| `AmazonSSMManagedInstanceCore` | Session Manager + SSM agent |
| Custom: `backend/deploy/iam-ec2-cloudwatch-logs.json` | Docker → CloudWatch Logs (`/yorigo/backend`) |

---

## 5. Phase 0 — Inventory Railway configuration

### 5.1 Export environment variables

1. Railway → Backend → **Variables**.
2. Save locally (e.g. `railway-env-backup.env`). **Do not commit.**

Critical: `FIREBASE_SERVICE_ACCOUNT_JSON`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, cookie vars, Coupang/Naver keys, NICE keys.

### 5.2 Railway → EC2 mapping

| Feature | Railway | EC2 |
|---------|---------|-----|
| Production schedulers | `RAILWAY_ENVIRONMENT` | `ENABLE_PRODUCTION_SCHEDULERS=true` |
| Public API domain | `RAILWAY_PUBLIC_DOMAIN` | `PUBLIC_API_DOMAIN=api.yorigo.kr` |
| Health restart | Railway `/health` | ALB `/health` |
| HTTPS | Automatic | ACM + ALB |
| Secrets | Railway Variables | SSM Parameter Store |
| Image build | Railway | **GitHub Actions → ECR** |

---

## 6. Phase 1 — AWS infrastructure (Console)

Region: **`ap-northeast-2`**.

### Step 1 — ECR

**Elastic Container Registry** → **Create repository** → name `yorigo-backend`, private.

Note URI: `ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/yorigo-backend`

### Step 2 — IAM role for EC2

**IAM** → **Roles** → EC2 → attach policies from [Section 4C](#c-ec2-instance-role-yorigo-ec2-role) → `yorigo-ec2-role`.

### Step 3 — Security groups

- **`yorigo-alb-sg`:** HTTP 80, HTTPS 443 from `0.0.0.0/0`
- **`yorigo-ec2-sg`:** TCP **8000** from `yorigo-alb-sg` only

### Step 4 — ACM certificate

Request cert for **`api.yorigo.kr`**, DNS validation, wait for **Issued**.

### Step 5 — Target group

`yorigo-api-tg` — HTTP, port **8000**, health path **`/health`**, success **200**.

### Step 6 — Application Load Balancer

`yorigo-api-alb` — internet-facing, HTTPS 443 → target group + ACM cert, HTTP 80 → redirect 443.

### Step 7 — Launch EC2

| Field | Value |
|-------|--------|
| Name | `yorigo-backend-prod` |
| AMI | Amazon Linux 2023 |
| Type | `c6i.xlarge` |
| Storage | 50 GiB gp3 |
| Subnet | Public, auto-assign public IP |
| Security group | `yorigo-ec2-sg` |
| IAM profile | `yorigo-ec2-role` |

Copy the **instance ID** (e.g. `i-0abc123...`) for GitHub secrets.

### Step 8 — Register EC2 in target group

Port **8000**. Stays unhealthy until the container runs.

### Step 9 — DNS

Route 53 (or registrar): **`api.yorigo.kr`** → ALB alias/CNAME.

---

## 7. Phase 2 — Secrets and environment variables

### 7.1 SSM Parameter Store

**Systems Manager** → **Parameter Store** → SecureString under `/yorigo/prod/`:

| Parameter | Source |
|-----------|--------|
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Railway |
| `OPENAI_API_KEY` | Railway |
| `GEMINI_API_KEY` | Railway |
| `YOUTUBE_COOKIES_BASE64` | Railway |
| `COUPANG_ACCESS_KEY` | Railway |
| `COUPANG_SECRET_KEY` | Railway |

Add all other Railway secrets you use.

```bash
aws ssm put-parameter \
  --name "/yorigo/prod/FIREBASE_SERVICE_ACCOUNT_JSON" \
  --type SecureString \
  --value file://firebase-service-account.json \
  --region ap-northeast-2
```

### 7.2 Production env file on EC2

Create `/opt/yorigo/env.production` on the instance (Section 9):

```env
ENVIRONMENT=production
PORT=8000
HOST=0.0.0.0
LOG_LEVEL=INFO
ENABLE_PRODUCTION_SCHEDULERS=true
PUBLIC_API_DOMAIN=api.yorigo.kr
ENABLE_PRICE_COLLECTION_SCHEDULER=true
ENABLE_PRODUCT_HEALTH_CHECK=true
ENABLE_SCRAPING_SCHEDULER=false
ENABLE_KURLY_SCRAPING_SCHEDULER=false
ENABLE_UNDERAGE_CLEANUP_SCHEDULER=true
ENABLE_WATCHDOG=true
ENABLE_MODEL_WARMUP=true
ENABLE_EVENT_LOOP_HEARTBEAT=true
ALLOWED_ORIGINS=https://yorigo-f7408.web.app,https://yorigo-f7408.firebaseapp.com
NICE_PASS_RETURN_URL=https://api.yorigo.kr/auth/age/pass/nice/callback
NICE_SMS_RETURN_URL=https://api.yorigo.kr/auth/age/sms/nice/callback
UVICORN_WORKERS=1
```

---

## 8. Phase 3 — GitHub Actions setup

### 8.1 Workflow file

The repo includes `.github/workflows/deploy-backend-ec2.yml`. It:

1. **Builds** `backend/Dockerfile` on `ubuntu-latest`
2. **Pushes** to ECR as `:latest` and `:$GITHUB_SHA`
3. **Deploys** via SSM: `/opt/yorigo/deploy.sh $GITHUB_SHA`

Triggers:

- **Manual Run workflow:** build + push to ECR **and** deploy to EC2
- **Push to `main`** (when `backend/**` changes): build + push to ECR only — **no auto-deploy**

To deploy from your **AWS migration branch**, edit the workflow:

```yaml
on:
  push:
    branches:
      - main
      - your-aws-migration-branch-name
```

### 8.2 GitHub repository secrets

**GitHub** → repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

| Secret | Value |
|--------|--------|
| `AWS_ACCESS_KEY_ID` | From IAM user `yorigo-github-actions` |
| `AWS_SECRET_ACCESS_KEY` | Same user |
| `EC2_INSTANCE_ID` | e.g. `i-0abc123def456` |

### 8.3 First image push (before EC2 deploy script exists)

1. Complete ECR (Section 6, Step 1).
2. Add GitHub secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
3. **Temporarily comment out** the `deploy` job in the workflow, or leave `EC2_INSTANCE_ID` unset until EC2 is bootstrapped.
4. Push the workflow to GitHub → **Actions** → **Run workflow**.
5. Verify in **ECR** → `yorigo-backend` → image tag `latest` exists.

### 8.4 Ongoing deploys

After EC2 has `deploy.sh` (Section 9):

1. Set `EC2_INSTANCE_ID` secret.
2. Push to `main` (or migration branch), or **Run workflow** manually.
3. Watch the **deploy** job — it polls SSM until success or failure.

### 8.5 Verify ECR from CLI (optional)

```bash
aws ecr describe-images \
  --repository-name yorigo-backend \
  --region ap-northeast-2
```

---

## 9. Phase 4 — EC2 bootstrap and first deploy

EC2 only **pulls** images from ECR; it does not build them.

### 9.1 Install Docker on EC2

**EC2** → instance → **Connect** → **Session Manager**:

```bash
sudo dnf update -y
sudo dnf install -y docker aws-cli
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user
newgrp docker

sudo mkdir -p /opt/yorigo
sudo chown ec2-user:ec2-user /opt/yorigo
```

### 9.2 Create `env.production`

Paste the file from [Section 7.2](#72-production-env-file-on-ec2):

```bash
nano /opt/yorigo/env.production
```

### 9.3 Create `deploy.sh`

**Important:** The old deploy script only loaded 6 SSM keys into Docker. Railway has 40+ variables;
if cookies/monitor fail on AWS, update `/opt/yorigo/deploy.sh` from the repo:

```bash
# On your laptop (repo clone) or copy backend/scripts/ec2-deploy.sh contents to EC2.
sudo cp backend/scripts/ec2-deploy.sh /opt/yorigo/deploy.sh
sudo chmod +x /opt/yorigo/deploy.sh
# Edit ECR_URI if your account ID differs from 839922332232
nano /opt/yorigo/deploy.sh
```

The script loads **all** `/yorigo/prod/*` SSM parameters (except `test`), aliases
`YOUTUBE_COOKIES_REFRESH_INTERVAL_SECOND` → `..._SECONDS`, then appends `env.production`.

### 9.4 First deploy

**Option A — GitHub Actions (recommended):**

1. Set `EC2_INSTANCE_ID` in GitHub secrets.
2. Actions → **Deploy Backend to EC2** → **Run workflow**.

**Option B — Manual on EC2:**

```bash
/opt/yorigo/deploy.sh latest
docker logs -f yorigo-backend
```

### 9.5 Verify

- Target group → **healthy**
- `curl -sS https://api.yorigo.kr/health`
- Startup logs: production schedulers on, scraping schedulers off

---

## 10. Phase 5 — Parallel testing

Run Railway and EC2 together before cutover.

```dart
EnvironmentConfig.setMobileTestingUrl('https://<ALB-DNS-NAME>');
EnvironmentConfig.setEnvironment(Environment.mobileTesting);
```

| Test | Pass |
|------|------|
| `GET /health` | 200, `firestore: ok` |
| Parse YouTube / Instagram / TikTok | Recipe returned |
| Cart / products | Works |
| NICE age gate | Callback to `api.yorigo.kr` |
| 24–48h soak | No OOM / thread errors |

---

## 11. Phase 6 — DNS cutover and app release (Phase 2)

### Phase 2 code change — only after `api.yorigo.kr/health` works

In `yorigo-frontend/lib/config/environment_config.dart`:

```dart
static const String _productionUrl = 'https://api.yorigo.kr';
```

Then build and release to App Store / Play Store.

### Cutover steps

1. Lower DNS TTL on `api.yorigo.kr`.
2. Confirm DNS → ALB.
3. Verify `curl https://api.yorigo.kr/health`.
4. Merge Flutter URL change above; release app.
5. Monitor 48h.
6. Decommission Railway (Section 12).

---

## 12. Phase 7 — Decommission Railway

After **48+ hours** stable on EC2:

1. Disable Railway auto-deploy
2. Scale down or delete Railway service
3. Keep Railway env backup 30 days

---

## 13. Monitoring and alarms

### 13.1 CloudWatch Logs (Docker → 콘솔에서 로그 보기)

로그 그룹만 만들면 **로그가 안 쌓입니다.** EC2 Docker가 CloudWatch로내도록 **IAM 권한 + deploy.sh** 가 필요합니다.

#### Step 1 — 콘솔에서 로그 그룹 생성 (선택, deploy가 자동 생성도 가능)

1. **CloudWatch** → **로그** → **로그 그룹** → **로그 그룹 생성**
2. 로그 그룹 이름: **`/yorigo/backend`**
3. 보존: **30일** (또는 만기 없음)
4. 로그 클래스: **표준**
5. **생성**

#### Step 2 — EC2 IAM 역할에 CloudWatch 권한 추가

1. **IAM** → **역할** → EC2에 붙은 역할 (`yorigo-ec2-role`)
2. **권한 추가** → **인라인 정책 생성** → JSON
3. `backend/deploy/iam-ec2-cloudwatch-logs.json` 내용 붙여넣기 (계정 ID가 다르면 ARN 수정)
4. 정책 이름 예: `yorigo-ec2-cloudwatch-logs`

#### Step 3 — deploy.sh 업데이트 후 재배포

`backend/scripts/ec2-deploy.sh` 는 기본적으로 Docker `awslogs` 드라이버를 켭니다.

```bash
sudo cp backend/scripts/ec2-deploy.sh /opt/yorigo/deploy.sh
sudo chmod +x /opt/yorigo/deploy.sh
/opt/yorigo/deploy.sh latest
```

`/opt/yorigo/env.production` (선택):

```env
ENABLE_CLOUDWATCH_LOGS=true
CLOUDWATCH_LOG_GROUP=/yorigo/backend
CLOUDWATCH_LOG_STREAM=yorigo-backend
```

IAM 미설정 시 배포가 실패하면 임시로 `ENABLE_CLOUDWATCH_LOGS=false` 후 재배포.

#### Step 4 — 로그 확인

1. **CloudWatch** → **로그** → **로그 그룹** → **`/yorigo/backend`**
2. 로그 스트림 **`yorigo-backend`** 클릭
3. `[Startup]`, `[CookieManager]` 등 백엔드 stdout이 보이면 성공

CLI (로컬에 AWS CLI 있을 때):

```bash
aws logs create-log-group --log-group-name /yorigo/backend --region ap-northeast-2
aws logs tail /yorigo/backend --follow --region ap-northeast-2
```

### 13.2 Alarms

| Alarm | Threshold |
|-------|-----------|
| EC2 CPU | > 85% / 5 min |
| ALB 5xx | > 10 / 5 min |
| UnHealthyHostCount | ≥ 1 |

Uptime: `https://api.yorigo.kr/health`

---

## 14. Rollback plan

| Scenario | Action |
|----------|--------|
| Bad deploy | Re-run workflow from previous commit, or on EC2: `/opt/yorigo/deploy.sh <previous-sha>` |
| EC2 broken before cutover | Fix EC2; Railway unchanged |
| After cutover | Emergency app release with Railway URL; re-enable Railway |

---

## 15. Environment variable reference

| Variable | EC2 value |
|----------|-----------|
| `ENABLE_PRODUCTION_SCHEDULERS` | `true` |
| `PUBLIC_API_DOMAIN` | `api.yorigo.kr` |
| `ENABLE_PRICE_COLLECTION_SCHEDULER` | `true` |
| `ENABLE_PRODUCT_HEALTH_CHECK` | `true` |
| `ENABLE_SCRAPING_SCHEDULER` | `false` |
| `ENABLE_KURLY_SCRAPING_SCHEDULER` | `false` |

Secrets via SSM — see Section 7.1.

---

## 16. Cookie management on AWS

Same as Railway. Use SSM for `YOUTUBE_COOKIES_BASE64` or `YOUTUBE_COOKIES_SOURCE_URL` / `INSTAGRAM_COOKIES_SOURCE_URL` pointing to your local cookie server.

---

## 17. Known limitations

1. Single EC2 instance only (file-based scheduler locks).
2. GitHub Actions build can take 10–20 min (Whisper/OCR deps in Dockerfile).
3. `EC2_INSTANCE_ID` must be updated if you replace the instance.
4. Cookie server still required on a separate machine.

---

## 18. Cost estimate

| Resource | USD/mo |
|----------|--------|
| EC2 `c6i.xlarge` | ~$120–150 |
| ALB | ~$20–25 |
| ECR + other | ~$20–70 |
| **Total** | **~$160–245** |

GitHub Actions: free tier usually covers occasional backend builds.

---

## 19. Checklist summary

### Pre-migration (Phase 1 merge)

- [ ] Export Railway variables
- [ ] AWS CLI configured
- [ ] Merge **backend + workflow + docs** to `main` (Flutter URL **still Railway**)
- [ ] Optional: GitHub secrets for ECR build only

### AWS infra

- [ ] ECR `yorigo-backend`
- [ ] IAM: `yorigo-ec2-role`, `yorigo-github-actions` user
- [ ] ALB + ACM + target group + EC2
- [ ] DNS `api.yorigo.kr` → ALB
- [ ] SSM `/yorigo/prod/*`

### GitHub Actions

- [ ] `.github/workflows/deploy-backend-ec2.yml` in repo
- [ ] Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `EC2_INSTANCE_ID`
- [ ] Workflow run → image visible in ECR

### EC2

- [ ] Docker installed
- [ ] `/opt/yorigo/env.production` + `deploy.sh`
- [ ] Deploy via Actions or `deploy.sh latest`
- [ ] Target **healthy**, `/health` → 200

### Go live (Phase 2)

- [ ] `https://api.yorigo.kr/health` OK
- [ ] Merge Flutter URL → `api.yorigo.kr`
- [ ] Parallel test 24–48h
- [ ] Flutter release to stores
- [ ] Decommission Railway

---

## Related files

| Path | Role |
|------|------|
| `.github/workflows/deploy-backend-ec2.yml` | Build → ECR → SSM deploy |
| `backend/Dockerfile` | Production image |
| `backend/utils/deployment_env.py` | Production scheduler flags |
| `yorigo-frontend/lib/config/environment_config.dart` | Production URL — **Railway until Phase 2**, then `api.yorigo.kr` |

---

*Last updated: 2026-06-11. Builds via GitHub Actions — local Docker not required.*
