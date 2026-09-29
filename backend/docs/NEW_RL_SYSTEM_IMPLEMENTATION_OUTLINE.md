# New RL System — Implementation Outline

This document is a **solid outline** for implementing the new reinforcement-learning layer alongside the recommender stack. It is meant to be used as a **build checklist** and architecture map, not as duplicate prose of every design detail.

**Related docs (read in this order for full context):**

| Doc | Role |
|-----|------|
| `New RL System Blueprint.md` | Full V2 recommender + eval blueprint (same folder) |
| `RECOMMENDER_V2_BLUEPRINT.md` | Alternate path if canonical; align content over time |
| `RESTRICTION_TRACKING_AND_FEEDBACK_FILTERS.md` | Hard/soft filters without mandatory survey |
| `RL_SYSTEM_ANALYSIS.md` | Current production code (`rl_agent.py`, `RecommendationService`) |

---

## 1. Purpose of the “New RL System”

- **Primary goal:** Learn **which decisions to make under uncertainty** (exploration vs exploitation, mix of retrieval sources, re-rank knobs) from logged feedback, **without** violating hard safety constraints.
- **Secondary goal:** Optionally keep or replace **tabular Q-learning over recipe IDs** with clearer separation of concerns (ranker vs policy).

**Non-goal for v1 of new RL:** End-to-end deep RL training the entire pipeline in one shot.

---

## 2. Where RL Fits (Single Picture)

```
User + context
    → Constraint Gate (NOT RL; rules + profile)
    → Stage 1: candidates (RL optional: source mix / exploration budget)
    → Stage 2: rank scores (usually supervised LTR; RL optional: online weight nudge)
    → Re-ranking (RL optional: diversity / novelty / session boost knobs)
    → Served list + logging (required for any RL)
    → Feedback → policy / bandit / Q updates
```

| Layer | Typical learning | RL? |
|-------|------------------|-----|
| Constraint Gate | Rules + `user_constraint_profile` | No |
| Stage 1 retrieval | Static + tuned weights | **Contextual bandit** over sources / quotas |
| Stage 2 ranker | GBDT / neural **offline** from logs | Rarely full MDP; optional **online** calibration |
| Re-ranking | Heuristics + A/B params | **Bandit** over knob vectors |
| Legacy `QLearningAgent` | Q(s, a) per user | Yes — **discrete pick** among candidates |

**Guiding principle:** RL learns **policies and exploration**; the **ranker** learns **relevance** from batch data. Do not duplicate the same job in two places without clear boundaries.

---

## 3. RL Surfaces to Implement (Choose v1 Scope)

### 3.1 Surface A — Contextual bandit (Stage 1)

- **State (context):** user embedding or feature summary, cart summary, session intent, time, candidate pool stats.
- **Actions:** discrete arms, e.g. `{mostly_overlap, mostly_prefs, ann_boost, explore_bucket}` or **mixture weights** (e.g. 4-simplex).
- **Reward:** downstream proxy (save, cook, cart) with optional click shaping; align with metric hierarchy in blueprint.
- **Algorithms (pick one for v1):** LinUCB, Thompson sampling on linear model, or epsilon-greedy over arms with logged propensity.

**Deliverables:** arm definition, logging of `policy_id` + `propensity`, serving module, offline OPE hook.

### 3.2 Surface B — Re-ranking bandit

- **State:** same as above + top-M scores from ranker.
- **Actions:** small discrete set of **re-rank policies** or continuous **knob vector** (diversity λ, novelty weight, session boost gain).
- **Reward:** same as Surface A; add **diversity / fatigue** as secondary or constraint.

**Deliverables:** parameterization, guardrails (max exploration %), logging.

### 3.3 Surface C — Legacy / thin Q-picker (optional)

- **State:** structured or hashed context (prefer structured features feeding ranker; hash only if needed).
- **Action:** `recipe_id` from top-K after ranker (K small, e.g. 20–50), not full catalog.
- **Reward:** feedback mapped to scalar (+ / −).
- **Reason to keep:** minimal change path from current `rl_agent.py`; **reason to drop:** ranker + bandit often makes this redundant.

**Decision checkpoint:** After Stage 2 is live, compare **Q-picker on top-K** vs **ranker-only + bandit** in offline + small online test.

### 3.4 Surface D — Factor weight learner (evolution of current `RLAgent`)

- **What it is:** Online nudge to **interpretable weights** (efficiency, taste, price, popularity) or to **calibration** of ranker outputs.
- **Keep** if product wants explainable “slider-like” personalization; **merge** into bandit if it becomes one knob vector.

---

## 4. Problem Formulation Checklist

For **each** RL surface you ship, fill in:

- [ ] **State** — feature vector schema, TTL, privacy.
- [ ] **Action space** — finite arms vs continuous; constraints on actions.
- [ ] **Reward** — primary + shaping; delay handling (cook happens later).
- [ ] **Policy class** — linear, tree policy, or neural; exploration rule.
- [ ] **Logging** — impression, action, propensity, `policy_id`, context hash.
- [ ] **Safety** — hard filters applied **before** action affects user-visible candidates.
- [ ] **Evaluation** — offline OPE gate + online A/B per blueprint.

---

## 5. Reward and Delayed Outcomes

- Log **recommendation_id** at impression; join **late** events (cook within 7d) back for reward attribution.
- Define **default reward** for neutral (no click) vs negative only if you have explicit skip/dislike.
- Prefer **multi-task labels** (cook > save > click) over single click for training and bandit reward.

---

## 6. Data & Storage (Implementation)

| Artifact | Purpose |
|----------|---------|
| `recommendation_impression` | OPE: position, propensity, policy_id, candidate set id |
| `policy_decision` | arm / knob chosen per request |
| `bandit_state_snapshot` | reproducible offline replay (hashed or redacted) |
| `user_constraint_profile` | Hard/soft filters (see restriction doc) |
| Q-table or bandit posterior | Per-user or global + user offset (design choice) |

**Replace file-based Q/weights** with DB-backed store when RL ships beyond dev (see `RL_SYSTEM_ANALYSIS.md` risks).

---

## 7. Serving API Contract (Outline)

Minimum fields to add to recommendation response / internal context:

- `policy_id`, `policy_version`
- `exploration_arm` or `rerank_profile_id`
- `logging_propensity` (per position or per list policy)
- `candidate_source_breakdown` (for Stage 1 bandit analysis)

Feedback endpoint extensions:

- `reason_code` on reject (links to restriction profile updates)
- optional delayed reward webhook or batch joiner for cook events

---

## 8. Phased Implementation Roadmap

### Phase 0 — Instrumentation only

- [ ] Impression + feedback schema + propensity for **current** policy (even if uniform).
- [ ] `recommendation_id` threaded frontend → backend → analytics.

### Phase 1 — Constraint gate + ranker path (no new RL)

- [ ] Hard/soft filters from `RESTRICTION_TRACKING_AND_FEEDBACK_FILTERS.md`.
- [ ] Stage 1 + Stage 2 as in blueprint; **fixed** exploration mix.

### Phase 2 — One bandit surface

- [ ] Implement **either** Stage 1 source mix **or** re-rank knob bandit (not both until stable).
- [ ] Offline OPE on logged data; online 1% → ramp.

### Phase 3 — Expand + consolidate

- [ ] Second surface if metrics justify complexity.
- [ ] Deprecate or narrow **Q-picker** to top-K only, or remove after A/B win.

### Phase 4 — ANN + neural ranker (optional)

- [ ] ANN as optional candidate source; bandit can include “ANN weight” arm.

---

## 9. Migration from Current Code

| Current | Suggested direction |
|---------|---------------------|
| `backend/rl_agent.py` | Keep behind flag; scope actions to **top-K** from ranker; or replace with bandit module |
| `RecommendationService.RLAgent` | Absorb into bandit knob vector or keep as interpretable layer with clear API |
| `recommendation_context.json` | Replace with durable store for OPE + delayed rewards |
| `record_feedback` | Extend payload with `reason_code`, join for bandit/Q updates |

---

## 10. Initial v1 model decisions (locked — may change if advanced later)

These are the **default answers** for the first shipped RL layer. Revisit when traffic, data volume, or infra require a more advanced design.

| # | Topic | Initial choice |
|---|--------|----------------|
| 1 | RL surfaces | **Single-surface RL** only in v1 (one contextual bandit: Stage 1 source mix *or* re-ranking knobs — pick one before coding; do not add a second surface until stable). |
| 2 | Posterior / learning granularity | **User-level** (per-user bandit state; no cohort-level posterior as the primary model in v1). |
| 3 | Personalization shape | **Fully per-user model** (no “global policy + user offset” as the v1 default; accept higher storage/compute cost until scale forces a change). |
| 4 | Reward attribution window | **7 days** for delayed outcomes (e.g. cook completion, save) joined back to `recommendation_id` / impression. |
| 5 | Tabular Q-learning deprecation | See **§10.1** below (initial criteria; adjust after first A/B cycle). |

### 10.1 Initial deprecation criteria for `QLearningAgent` (tabular Q)

Treat tabular Q-learning as **legacy / optional** once the v1 path exists. **Initial** deprecation rule:

1. **Precondition:** v1 is live with **constraint gate + ranker + single-surface bandit** and **7d attribution** logging is reliable (missing-rate below agreed SLO).
2. **Deprecate Q-picker from the serving path** when **both** hold:
   - **Offline:** OPE or replay estimate shows **no meaningful lift** from Q-picker on top of the same ranker+bandit vs ranker+bandit alone (primary metrics within noise band).
   - **Online:** A/B over sufficient users/duration shows treatment **without** Q-picker **≥** treatment **with** Q-picker on **primary** metrics (cook/save/cart), with **no** hard-constraint regression and guardrails green.
3. **Remove or freeze code** after one release of “Q disabled by default” (read-only Q-table optional for audit); delete module only when no rollback request for two release cycles.

If (2) cannot be met, **keep Q only on top-K** as a thin tie-breaker until data improves — do not expand Q state space.

**Note:** Cold start for fully per-user bandits should be documented in the bandit spec (e.g. prior from population or uniform exploration until N events per user).

---

## 11. Definition of Done (RL Subsystem)

- [ ] At least one RL surface has **logged propensity** and **offline OPE** report in CI or scheduled job.
- [ ] Online A/B template run with documented go/no-go.
- [ ] Hard constraint violations remain **zero** under RL policy.
- [ ] Runbook: rollback switch, default to fixed policy.

---

## 12. One-Page Summary for Implementers

1. **Filters and safety are not RL** — always first.
2. **Ranker learns relevance** from logs (batch).
3. **RL/bandit learns exploration and system knobs** (online, small action space).
4. **Legacy Q-learning** is optional glue on top-K; validate before investing.
5. **Logging + OPE + A/B** are part of the RL system, not an afterthought.

---

*End of outline. v1 RL scope: single-surface, user-level, fully per-user, 7d attribution; Q deprecation per §10.1.*
