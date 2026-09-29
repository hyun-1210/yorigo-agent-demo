# New RL System — Implemented Summary and Future Scaling

This document summarizes **what is implemented today** in the backend (aligned with code) and **how to evolve** the system when you have more data and computing capacity.

---

## 1. What Was Implemented

### 1.1 Single-surface RL: re-ranking bandit

- **Location:** `backend/services/recommendation_service.py`
- **Class:** `RerankBanditAgent`
- **Idea:** After the usual **candidate list** is built (shared main ingredients, etc.), a **per-user** contextual bandit chooses one of a small set of **re-ranking policies** (arms). Each arm is a fixed mix of weights over:
  - `efficiency`, `taste_match`, `price_saving`, `popularity`
- **Selection:** Thompson sampling (Beta posteriors per arm, per user).
- **Learning:** On `/recommendation_feedback`, the selected arm’s posterior is updated from positive/negative feedback.

**Arms (fixed profiles):** `balanced`, `taste_focus`, `efficiency_focus`, `price_focus`.

### 1.2 User-level, fully per-user state

- Bandit state is stored **per Firebase UID** in Firestore:
  - Collection: `recommendation_bandit_users`
  - Document ID = `user_id`
- No default “global policy + user offset” in this v1 path.

### 1.3 Legacy tabular Q-learning: disabled by default

- **Env:** `ENABLE_LEGACY_Q_LEARNING` — when unset/false, `QLearningAgent` / `PersonalizedQLearningAgent` are **not** initialized.
- When `true`, the old Q-picker path can still run after candidates exist (same as before).
- **Rationale:** avoids duplicating “pick a recipe” logic while the re-rank bandit is the primary RL surface.

### 1.4 Feedback API: optional reject survey

- **Model:** `RecommendationFeedbackRequest` in `backend/models.py`
  - `reason_code` (optional)
  - `reason_text` (optional, max length 300)
- **Router:** `backend/routers/recommendation.py` passes these into `record_feedback`.

### 1.5 Firestore artifacts

| Collection | Purpose |
|------------|---------|
| `recommendation_bandit_users` | Per-user bandit posteriors and counters |
| `recommendation_feedback_events` | Append-only feedback events (policy id, factors, reasons) for analysis / future OPE |
| `user_constraint_profile` | Reason-driven hard/soft constraint hints (e.g. allergy / dietary / dislikes) |

### 1.6 Recommendation context (local JSON, unchanged path)

- `recommendation_context.json` still stores per-`recommendation_id` context for feedback.
- Extended context includes: `policy_type`, `policy_arm_id`, `policy_arm_sample`, `policy_weights`, `recipe_ingredients`, `reward_window_days` (set to **7** for documentation of intended attribution horizon).

### 1.7 What “7-day reward window” means today

- **Implemented:** metadata field `reward_window_days: 7` on context and events.
- **Not yet implemented:** automatic joining of delayed events (e.g. cook completed 3 days later) back to the original `recommendation_id` to update bandit or ranker. That is the next step when you add event pipelines and jobs.

---

## 2. How It Fits the Outline / Blueprint

| Outline intent | Status |
|----------------|--------|
| Single-surface RL first | Done (re-rank bandit) |
| User-level personalization | Done |
| Hard/soft filters from reject reasons | Partial (profile updates; serving-time filter gate not yet wired into candidate generation) |
| Two-stage ranker (GBDT / neural) | Not implemented |
| OPE + full A/B automation | Partial (events to Firestore; estimators and dashboards not in repo) |
| ANN retrieval | Not implemented |

---

## 3. How to Improve Later (More Data + More Compute)

Below is a realistic progression. **More compute** mainly unlocks: **larger candidate pools**, **heavier models**, **frequent retraining**, and **online features** — not necessarily “bigger RL” first.

### 3.1 Short term (little extra compute)

- **Tighten reason codes:** validate `reason_code` with a strict enum in Pydantic so analytics and constraint updates stay consistent.
- **Wire `user_constraint_profile` into candidate filtering** before bandit scoring (true “constraint gate”).
- **Delayed reward job:** nightly worker joins cook/save events within 7 days to the same `recommendation_id` and applies a second, softer bandit update (or stores labels only).

### 3.2 Medium term (moderate compute — one GPU optional)

- **Learned ranker (Stage 2):** train **GBDT** (e.g. XGBoost/LightGBM) on logged `(context, candidate, outcome)` rows exported from `recommendation_feedback_events` + impressions.
  - Bandit then chooses **knobs on top of ranker scores** (diversity λ, exploration mix), not raw heuristic factors only.
- **Better candidate features:** embeddings for tags/cuisine from a small text encoder; cache recipe vectors offline.
- **Batch retraining:** daily or weekly retrains on a small VM or CI job; serving stays lightweight (export model artifact, load at startup).

### 3.3 Long term (high compute — GPUs + vector infra)

- **ANN / vector retrieval (Stage 1):** maintain recipe embeddings and user embeddings; use FAISS / managed vector DB / Vertex AI Matching Engine scale.
  - Cost driver: index size, QPS, embedding refresh cadence.
- **Neural ranker:** two-tower or cross-attention ranker for `(user, context, recipe)`; requires more data and GPU training.
- **Online learning variants:** neural contextual bandits or off-policy policy gradients — only justified after logging + evaluation maturity; otherwise risk and variance dominate.

### 3.4 Scaling operations (compute + engineering)

- **Separate read/write paths:** event ingestion at high QPS (Pub/Sub → BigQuery/Firestore), model training offline.
- **Feature store:** low-latency serving of user/session features for ranker + bandit.
- **A/B and OPE automation:** scheduled jobs computing IPS/DR uplift before promoting policies.

---

## 4. Key Code References

| Area | File |
|------|------|
| Bandit + recommend/feedback integration | `backend/services/recommendation_service.py` |
| Feedback request fields | `backend/models.py` |
| HTTP wiring | `backend/routers/recommendation.py` |
| Legacy Q toggle | env `ENABLE_LEGACY_Q_LEARNING` (see `RecommendationService.__init__`) |

---

## 5. One-line takeaway

**Today:** a **Firestore-backed, per-user re-ranking bandit** chooses how to weight efficiency vs taste vs price vs popularity over existing candidates, learns from thumbs up/down, and logs structured feedback (including optional reject reasons) for future ranking and evaluation.

**Tomorrow:** add **learned ranking + vector retrieval + delayed rewards + constraint gate in serving** as compute and data volume justify it.
