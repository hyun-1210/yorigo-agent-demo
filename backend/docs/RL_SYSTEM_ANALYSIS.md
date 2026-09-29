# Reinforcement Learning System Analysis

## Overview

현재 추천 시스템의 RL 구성은 엄밀한 단일 RL 알고리즘이 아니라, **두 개의 학습 메커니즘이 병렬로 동작하는 하이브리드 구조**입니다.

1. **Q-Learning 기반 추천 선택기**
   - 구현 파일: `backend/rl_agent.py`
   - 상태(`state`)는 장바구니 주재료/취향/후보 개수 해시
   - 행동(`action`)은 추천 후보 recipe ID
   - 정책은 epsilon-greedy
   - 피드백 시 Bellman 업데이트 수행

2. **가중치 업데이트형 컨텍스트 밴딧 유사 학습기**
   - 구현 파일: `backend/services/recommendation_service.py` 내부 `RLAgent`
   - 효율성/취향/가격절감/인기도 4개 축 가중치를 피드백으로 업데이트
   - 사용자별 `user_weights.json`에 저장
   - 추천 점수 결합에 사용할 수 있는 개인화 파라미터 역할

즉, 코드상 "RL Agent"는 Q-Table 학습 + 피처 가중치 학습을 함께 포함합니다.

## Request-to-Learning Flow

1. `/recommend_recipe`
   - 인증된 uid로 요청 수신
   - `RecommendationService.recommend_recipe()` 호출
   - 후보 레시피 생성 후 Q-Learning 액션 선택 시도
   - Q 선택이 실패하거나 매칭 실패하면 LLM 추천 fallback
   - 결과와 함께 `recommendation_id` 발급
   - 추후 학습용 컨텍스트를 `recommendation_context.json`에 저장

2. `/recommendation_feedback`
   - `recommendation_id` 기반 컨텍스트 조회
   - 밴딧 유사 가중치 업데이트 (`RLAgent.update_weights`)
   - Q-Learning 업데이트 (`learn_from_feedback_for_user`)
   - 사용자별 통계 및 가중치 누적

3. `/user_weights/{user_id}`, `/rl_agent/stats`
   - 사용자 가중치/피드백 카운트 조회
   - Q-Table 관련 통계 조회(관리자 전용)

## Q-Learning Design Details

### State
- 입력: `cart_ingredients`, `user_preferences`, `available_recipes_count`
- 정규화 후 문자열 결합 -> MD5 해시
- 장점: 저장 크기 작고 조회 빠름
- 단점: 해시 상태는 해석 가능성이 낮아 디버깅/분석이 어려움

### Action
- 후보 recipe의 `id` 또는 `recipeId` 또는 recipe name 문자열
- 문제 가능성: ID 품질이 균질하지 않으면 action consistency가 약해질 수 있음

### Policy
- `epsilon` 탐험/활용 방식 (초기 0.1, decay 0.995, min 0.01)
- 피드백 누적 시 탐험 비율이 점차 감소

### Reward
- positive: `+1.0`
- negative: `-0.5`
- 코드 주석에 있는 timeout 보상(`-0.1`)은 현재 구현되어 있지 않음

### Update
- Bellman 식: `Q(s,a) = Q + alpha * (r + gamma * maxQ(s') - Q)`
- 현재 컨텍스트에서 `next_state`는 `None`으로 저장되어 실질적으로 **one-step immediate reward 업데이트**에 가까움

## Contextual Weight Learner (Bandit-like)

`RecommendationService.RLAgent`는 다음 특성을 가집니다.

- 가중치 벡터: `efficiency`, `taste_match`, `price_saving`, `popularity`
- 피드백 positive/negative에 따라 요인 점수(`factors`) 기반 증감
- 최소/최대 클램프 후 정규화
- 사용자별 저장/집계(`total_feedback`, `positive_feedback`, `negative_feedback`)

이 메커니즘은 Q-Learning과 별도로 작동하며, 향후 최종 ranking score에 더 적극적으로 결합할 여지가 큽니다.

## Strengths

- 구현 단순성: 파일 기반 Q-table이라 도입/디버깅이 빠름
- 사용자별 에이전트 분리: 개인화 학습 가능
- 강한 fallback 경로: Q선택 실패 시 LLM 추천 유지
- 추천-피드백 루프 완성: `recommendation_id`로 학습 데이터 연결
- 운영 가시성: RL stats, 사용자별 weight stats 제공

## Risks and Gaps

1. **파일 저장 동시성**
   - `q_table_{user}.json`, `user_weights.json`, `recommendation_context.json`이 파일 I/O 기반
   - 멀티 인스턴스/멀티 프로세스 환경에서 race condition 위험

2. **상태 일반화 한계**
   - 해시 상태가 희소해질 경우 cold state가 많아져 Q 재사용성이 낮음

3. **Action ID 안정성**
   - id/recipeId/name 혼합 사용으로 동일 레시피가 다른 action으로 기록될 가능성

4. **보상 신호 단순화**
   - positive/negative 이진 보상만 사용
   - dwell time, 클릭, 저장/재조회 같은 중간 신호 미반영

5. **Next-state 미활용**
   - Q-Learning 구조를 갖췄지만 실제로는 contextual bandit에 가까운 업데이트

6. **경로/스토리지 위치 명시성 부족**
   - 파일 경로가 상대경로 문자열이라 실행 위치에 따라 저장 위치가 달라질 수 있음

## Practical Improvement Priorities

### P1. 저장소 안정화
- 파일 기반 저장을 Firestore/Redis/PostgreSQL 중 하나로 이전
- 원자적 업데이트 및 optimistic locking 적용

### P2. Action ID 정규화
- action key를 recipe canonical id 하나로 강제
- name fallback 제거 또는 별도 매핑 테이블 유지

### P3. Reward 확장
- 이진 피드백 외에 클릭/체류/장바구니 재사용률을 연속 보상으로 통합
- 장기 재방문/재조리 이벤트를 지연 보상으로 반영

### P4. 상태 피처 개선
- 단순 해시 전에 구조화 피처(ingredient embedding, cuisine profile) 설계
- 해시 외 디버깅 가능한 raw feature snapshot 일부 저장

### P5. 오프라인 평가 체계
- replay 로그 기반 counterfactual/off-policy evaluation
- 정책 변경 전후 CTR/전환/재구매 지표 비교 자동화

## Final Assessment

현재 시스템은 **프로덕션 초기 단계에서 실용적인 RL-lite 아키텍처**로 적절합니다.  
특히 fallback이 강하고 사용자별 학습 루프가 존재한다는 점은 장점입니다.

다만 규모가 커질수록 파일 기반 동시성, action/state 표준화, 보상 설계의 단순성이 성능/안정성 병목이 될 가능성이 높습니다.  
단기적으로는 저장 계층 안정화와 action key 정규화가 가장 효과적인 개선 포인트입니다.
