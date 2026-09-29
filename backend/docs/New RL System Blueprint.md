# New RL System Blueprint

- Two-stage recommender
  - Stage 1: candidate generation
  - Stage 2: personalized ranker
- Product-level personalization
  - Hard constraints 우선 적용
  - Session-aware adaptation
  - Diversity + novelty re-ranking

## Product Goal

사용자별로 "가장 잘 맞는 레시피"를 추천하되 다음을 동시에 만족합니다.

1. **정확도**: 취향/상황/장바구니 맥락을 반영한 높은 relevance
2. **안전성/신뢰성**: 알레르기, 식이 제한 등 하드 제약 절대 위반 금지
3. **경험 품질**: 반복 추천 피로도 감소(다양성/신규성)
4. **운영 가능성**: 오프라인/온라인 평가 및 점진적 튜닝 가능

## End-to-End Architecture

`Request -> Constraint Gate -> Candidate Generation -> Personalized Ranking -> Re-ranking -> Response -> Logging`

1. **Constraint Gate (필수 통과)**
  - 알레르기, dietary, disliked ingredient, max cooking time, budget cap
  - 위반 후보는 즉시 제거
2. **Stage 1: Candidate Generation**
  - 빠른 필터 + ingredient overlap + optional ANN retrieval
  - 목표: recall 높은 후보군 확보 (예: 100~300개)
3. **Stage 2: Personalized Ranker**
  - GBDT 또는 lightweight neural ranker로 상위 점수 산출
  - 목표: precision 최적화 (예: top 20)
4. **Re-ranking Layer**
  - session intent boost + diversity/novelty constraints 반영
  - 최종 top K 노출 (예: K=5~10)
5. **Interaction Logging**
  - impression/click/save/cart/cook/skip 등 이벤트 저장
  - 다음 학습 배치와 평가에 활용

## Stage 1: Candidate Generation Design

## 1) 입력 신호

- 사용자 고정 프로필: 알레르기, diet, 비선호 재료, 선호 카테고리
- 사용자 단기 세션: 최근 클릭/스크롤/탭, 현재 시간대, 디바이스 컨텍스트
- 장바구니 문맥: 주재료, 재고량, 최근 구매/소비 패턴
- 레시피 메타: 재료, 태그, 카테고리, 조리시간, 예상 비용

## 2) Candidate source 구성

- **Source A: Ingredient-overlap retrieval**
  - cart/main ingredient와 겹치는 레시피 우선
- **Source B: Preference retrieval**
  - 태그/카테고리 유사 레시피
- **Source C: ANN retrieval (선택)**
  - 사용자 벡터-레시피 벡터 유사도 기반 후보 확장
- **Source D: Exploration bucket**
  - 신규/롱테일/트렌드 일부 주입 (작은 비율)

## 3) Hard filter 적용 순서

1. allergy exclude (절대)
2. dietary exclude (절대)
3. disliked ingredient exclude (절대)
4. max cook time
5. budget cap

권장: 절대 제약과 soft 제약을 명확히 분리하고, 절대 제약 위반은 어떤 점수 보정으로도 복구 불가.

## 4) Stage 1 출력

- 후보 리스트 N개 (권장 N=100~300)
- 각 후보별 기초 피처 첨부
  - overlap count, tag/category match, price band match, freshness signals

## Stage 2: Personalized Ranker Design

## 1) 모델 대안

### Option A: GBDT ranker (초기 권장)

- 장점: 학습/운영 단순, 피처 해석 용이, 데이터 적어도 강건
- 단점: 고차 상호작용 표현 제한

### Option B: Lightweight neural ranker

- 장점: 복합 상호작용 학습 가능
- 단점: 운영 복잡도 증가, 데이터 요구량 증가

권장 전략: **V2 초기에는 GBDT**, 충분한 로그 누적 후 neural 실험.

## 2) 피처 스키마 (예시)

- **User features**
  - 장기 선호 태그 분포, cuisine 선호 분포, 평균 선호 조리시간, 가격 민감도
- **Recipe features**
  - 태그/카테고리, 조리시간, 예상비용, 재료 희소성, 최근 인기/품질 지표
- **User-Recipe cross features**
  - 태그 교집합, 카테고리 일치율, 조리시간 거리, 비용 적합도, 재료 친숙도
- **Context features**
  - 시간대(아침/점심/저녁/야식), 요일, 세션 길이, 최근 액션 타입
- **Cart features**
  - main ingredient overlap, 예상 waste reduction, batch cooking 적합도

## 3) 학습 라벨 설계

단일 클릭 라벨 대신, multi-signal 가중 타깃 권장:

- cook completion: 1.0
- add to cart/save: 0.6
- recipe detail click: 0.25
- short bounce/skip: 0.0 또는 음수 샘플

학습 시점에는 position bias 보정을 고려(예: IPS/propensity 보정).

## 4) 출력 스코어

- `rank_score` (0~1 정규화)
- top-N 후보 정렬 후 re-ranking 단계로 전달

## Product-Level Personalization Gains

## A. Hard Constraints First

### 목표

- "Best fit" 이전에 "절대 안전/적합" 보장

### 정책

- allergy/diet/disliked ingredient는 **blocking rule**
- max cooking time/budget cap은 기본 blocking 또는 사용자 설정에 따라 soft 처리 가능

### 필요 데이터

- user profile에 제약 필드 구조화 저장
- recipe ingredient ontology 정규화(동의어/파생어 포함)

### 실패 시 fallback

- 제약이 너무 강해 후보가 0개면:
  1. 완화 가능한 soft 제약 순차 해제
  2. 사용자에게 “조건 완화 제안” 명시

## B. Session-aware Adaptation

### 목표

- 같은 사용자라도 현재 의도(quick meal vs weekend cooking)에 맞춰 추천 변화

### 세션 의도 추정 신호

- 최근 5~20개 액션(클릭/머무름/필터)
- 현재 시간대/요일
- 최근 선택 조리시간 분포
- 최근 예산 선택 패턴

### 적용 방식

- stage2 점수에 `session_boost`를 곱/가산
- 예:
  - quick intent면 짧은 조리시간, 단순 레시피 가중치 상향
  - weekend intent면 고난도/긴 조리시간 허용 폭 상향

### 단기 메모리 decay

- 최근 상호작용 가중치에 시간 감쇠 적용 (예: 24~72시간 반감)

## C. Diversity + Novelty Controls

### 목표

- 높은 relevance를 유지하면서 추천 피로도/중복 최소화

### re-ranking 전략

- MMR(Maximal Marginal Relevance) 또는 xQuAD 스타일 도입
- 동일 카테고리/주재료의 연속 노출 제한
- 최근 노출된 레시피/유사군에 novelty penalty 적용

### 예시 규칙

- top K 내 동일 cuisine 최대 M개
- top K 내 동일 main ingredient cluster 최대 M개
- 최근 7일 노출 레시피는 점수 감점

## Online Serving Contract (초안)

추천 응답에 다음 필드 추가 권장:

- `hard_constraint_passed: true/false`
- `candidate_source_breakdown`
- `rank_score`
- `diversity_adjusted_score`
- `explanations` (사용자 표시용 간단 사유)

학습/디버깅 로그에는 다음 포함:

- request context snapshot (익명/비식별)
- pre-filter 후보 수 / post-filter 후보 수
- stage2 feature vector hash (또는 주요 피처 요약)
- final rank list + served positions

## Data & Logging Plan

## 필수 이벤트

- impression (노출)
- click (상세 진입)
- save/bookmark
- add_to_cart
- cook_started / cook_completed
- explicit like/dislike

## 스키마 원칙

- 이벤트 타임스탬프 UTC
- request_id, user_id, recipe_id, position, score 포함
- 개인정보/민감정보 비식별화

## 학습 데이터셋 생성

- daily batch로 interaction join
- positive/negative 샘플링 정책 고정
- train/validation/test를 시간축으로 분리

## Evaluation Framework

## Offline 지표

- ranking: NDCG@K, MAP@K, Recall@K
- action-based: save/add-to-cart/cook completion proxy AUC
- 제약 준수율: hard-constraint violation rate (목표 0%)
- 다양성: intra-list diversity, catalog coverage
- 신규성: novelty score, repeat suppression score

## Online 지표

- CTR, save rate, add-to-cart rate, cook completion rate
- session length, 7-day retention
- 사용자 불만 지표(숨김/싫어요/이탈)

## Guardrail

- hard constraint 위반 1건이라도 즉시 롤백
- latency SLO 초과 시 stage2 degraded mode 제공

## Evaluation System Implementation Plan

V2에서는 평가를 "보고용"이 아니라 "출시 게이트"로 운영합니다.

핵심 원칙:

1. 오프라인 통과 없이 온라인 실험 금지
2. 클릭 단일 최적화 금지 (downstream 우선)
3. guardrail 위반 시 자동 중단/롤백

### 1) Offline Counterfactual/OPE 파이프라인

#### 목적

- 기존 정책 로그를 사용해 신규 정책의 잠재 성능을 사전 추정
- 사용자 노출 전 저품질 정책 제거

#### 입력 데이터 (필수)

- recommendation impression 로그
  - request_id, user_id(비식별), recipe_id, position, served_score
  - logging_policy_id, logging_propensity
  - timestamp, context snapshot(요약)
- interaction 로그
  - click, save, add_to_cart, cook_started, cook_completed, dislike/hide

#### 구현 요구사항

- 정책별 score replay 함수 제공
  - 같은 request context에 대해 "후보별 score" 재계산 가능해야 함
- 학습/평가 데이터 시간 분리
  - train / validation / test를 시간축으로 분리
- OPE estimator 2종 이상 운영
  - IPS 계열 + Doubly Robust 계열 권장
- 샘플 효율 및 분산 관리
  - propensity clipping / self-normalized estimator 적용 가능

#### Offline 승인 게이트 (예시)

- hard-constraint violation estimate = 0
- baseline 대비:
  - NDCG@10 >= +3%
  - cook/save proxy uplift >= +2%
  - repeat suppression 지표 악화 없음
- 분산/신뢰구간이 과도하면 online 진입 보류

### 2) Online A/B 실험 시스템

#### 실험 단위

- 기본: user-level randomization (권장)
- 예외: 트래픽 적거나 단기 기능 검증 시 request-level 가능

#### 실험 버킷

- Control: 기존 추천 정책
- Treatment A: V2 ranker baseline
- Treatment B (선택): V2 + diversity 강화

#### 트래픽 단계적 확대

- 1% -> 5% -> 20% -> 50% -> 100%
- 각 단계에서 최소 관측 기간/표본 기준 충족 시 다음 단계

#### 온라인 핵심 지표

- Primary (최적화 대상)
  - save rate
  - add-to-cart rate
  - cook completion rate
- Secondary
  - CTR
  - session depth/length
  - repeat usage
  - 7-day retention
- Guardrail
  - hard-constraint violation
  - hide/dislike rate 급등
  - p95 latency
  - crash/error rate

#### 온라인 중단 조건 (예시)

- hard-constraint 위반 > 0
- primary metric 유의미 하락
- guardrail metric 임계치 초과

### 3) Metric Hierarchy (의사결정 우선순위)

의사결정 우선순위는 아래 순서를 따릅니다.

1. Safety/Trust (절대 조건)
  - hard constraint violation = 0
2. Downstream Value (핵심 성공)
  - cook completion, save, add-to-cart
3. Engagement (보조)
  - CTR, session length
4. Ecosystem Health (장기)
  - diversity, novelty, catalog coverage, repeat suppression

주의: CTR이 상승해도 downstream이 하락하면 실패로 판단합니다.

### 4) Go/No-Go Release Gate (운영 기준)

#### Go

- safety 조건 모두 만족
- primary metric 최소 1개 이상 유의 개선
- 나머지 primary/secondary 비열화 또는 경미한 변동
- latency/error guardrail 정상

#### Conditional Go

- primary 개선은 있으나 일부 secondary 악화
- 악화 원인이 명확하고 완화 계획이 있을 때 제한 배포

#### No-Go

- safety 위반
- primary 유의 하락
- 관측 데이터 품질 부족(로깅 누락/propensity 결함)

### 5) 실험/평가 운영 산출물

각 실험마다 아래 산출물을 남깁니다.

- experiment spec
  - 가설, 대상 사용자, 기간, 성공/중단 조건
- metric report
  - uplift, 신뢰구간, 유의성, 세그먼트별 결과
- decision log
  - go/conditional/no-go 판단 근거
- post-rollout monitoring plan
  - 1주/2주 추적 지표 및 알람 기준

## Rollout Plan (All Ideas Together)

한 번에 구현하되, 운영 리스크를 줄이기 위해 내부적으로는 workstream을 병렬화합니다.

### Workstream 1: Data foundation

- 이벤트 로깅/스키마 확정
- user constraint profile 정규화
- recipe metadata 정규화

### Workstream 2: Retrieval

- stage1 candidate pipelines (A/B/C/D) 구현
- hard constraint gate 구현

### Workstream 3: Ranking

- stage2 GBDT baseline 학습/서빙
- session boost 결합

### Workstream 4: Re-ranking

- diversity/novelty 정책 구현
- 파라미터 실험 테이블 운영

### Workstream 5: Eval/Experiment

- 오프라인 평가 자동화
- 온라인 A/B 실험 및 대시보드

## 구현 우선순위 (권장)

1. Hard constraints + canonical recipe ID
2. Stage1 retrieval + Stage2 GBDT baseline
3. Session-aware boost
4. Diversity/novelty re-ranking
5. ANN retrieval 및 neural ranker 실험

## Open Decisions Before Implementation

1. ANN 인프라 채택 여부 (Firestore-only vs 벡터 인덱스 추가)
2. budget/time 제약을 hard로 고정할지 사용자 설정형 soft로 둘지
3. 탐험 트래픽 비율 (exploration bucket 비중)
4. ranker 재학습 주기 (daily vs weekly)
5. 온라인 실험 단위 (user-level randomization vs request-level)

## Definition of Done (V2)

아래 조건을 모두 만족하면 V2 완료로 간주:

- hard constraint violation rate = 0
- baseline 대비 주요 전환 지표 유의미 개선
- 반복 추천률 감소 + catalog coverage 개선
- 학습/서빙/실험 파이프라인 문서 및 운영 런북 완성

