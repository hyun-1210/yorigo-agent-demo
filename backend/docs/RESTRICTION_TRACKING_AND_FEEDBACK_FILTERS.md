# Restriction Tracking and Feedback-Driven Filters

## Purpose

This document defines how to build recommendation filters without relying on an upfront survey.

Core direction:
- Use background tracking to infer user-specific allergy/diet/dislike constraints.
- When a user rejects a recommendation, allow optional reason selection.
- Convert those signals into hard/soft filters for future recommendations.
- Keep future survey support as an additive input source, not a required dependency.

## Product Direction

## Current Policy (Now)

- No mandatory survey at onboarding.
- The system learns constraints from behavior and explicit rejection reasons.
- Rejection reason input is optional but strongly encouraged in UI.

## Future Policy (Later)

- Add optional profile survey for allergy/diet/restriction setup.
- Survey signals merge into the same constraint store used by background tracking.
- Survey does not replace behavioral learning; both coexist.

## Constraint Types

## 1) Hard Constraints (Block)

Hard constraints are absolute and should remove recipes before ranking:
- Confirmed allergy ingredients
- Confirmed dietary restrictions (e.g., vegan, halal, gluten-free strict mode)
- User-marked "never show ingredient"

Rule:
- Hard violations cannot be recovered by score boosts.

## 2) Soft Constraints (Penalty / Down-rank)

Soft constraints influence ranking but do not strictly block:
- Suspected dislike ingredients
- Suspected cuisine aversion
- Prep-time or budget tendency mismatches inferred from repeated rejection

Rule:
- Soft penalties can be overridden if overall relevance is high.

## Signal Sources

## A) Background Behavioral Tracking

- Impression -> click -> detail dwell -> save -> add-to-cart -> cook completion -> repeat cook
- Hide/dislike actions
- Repeated skip patterns (same ingredient/cuisine/time band)

Use:
- Build confidence scores for inferred preferences and inferred restrictions.

## B) Recommendation Rejection Reason (Optional)

When user rejects a recipe, present reason options:
- Contains allergic ingredient
- Violates dietary rule
- Contains ingredient I dislike
- Too expensive
- Too time-consuming
- Not my taste
- Already cooked recently
- Other (optional text)

Use:
- Convert explicit reason into structured update to constraint profile.

## C) Future Survey Input (Optional)

Potential fields:
- Allergy ingredient list
- Dietary mode
- Disliked ingredient list
- Time budget
- Price sensitivity

Use:
- Initialize or override low-confidence inferred signals.

## Constraint Confidence Model

Each constraint item is stored with:
- `source`: `behavior`, `reject_reason`, `survey`, `admin`
- `confidence`: `low`, `medium`, `high`, `confirmed`
- `updated_at`
- `evidence_count`

Recommended confidence escalation:

1. Single weak behavioral signal -> `low`
2. Repeated behavior or one explicit rejection reason -> `medium`
3. Repeated explicit reasons -> `high`
4. Survey-confirmed or user profile-confirmed allergy/diet -> `confirmed` (hard)

## Filter Update Logic

## On Reject Event

Input:
- `recommendation_id`
- `recipe_id`
- `reason_code` (optional)
- `reason_text` (optional)

Processing:
1. Resolve recipe features (ingredients, tags, cuisine, prep time, cost band).
2. Map `reason_code` to update policy:
   - `allergy` -> add matched ingredient(s) to hard block list with high/confirmed confidence.
   - `dietary_violation` -> add/update dietary hard rule.
   - `disliked_ingredient` -> add ingredient to soft list; escalate to hard only after repeated confirmation.
   - `too_expensive` -> strengthen soft budget penalty profile.
   - `too_time_consuming` -> strengthen soft prep-time penalty profile.
   - `not_my_taste` -> adjust taste embedding/category preference negatively.
   - `already_cooked_recently` -> apply novelty cooldown.
3. Persist evidence trail for auditability.

## On Positive Signals

- Save/add-to-cart/cook completion should weaken contradictory soft constraints.
- Positive signals should not auto-remove confirmed hard constraints.

## Serving-Time Filter Application

Order at recommendation time:

1. Build user constraint profile snapshot.
2. Apply hard blocks to candidate pool.
3. Stage 2 ranking.
4. Apply soft penalties/boosts in re-ranking.
5. Return top-K with explainable reason tags.

## Data Model (Proposed)

## `user_constraint_profile`

- `user_id`
- `allergy_blocks`: [{ ingredient_id, confidence, source, updated_at }]
- `dietary_blocks`: [{ rule_id, confidence, source, updated_at }]
- `ingredient_soft_dislikes`: [{ ingredient_id, weight, confidence, updated_at }]
- `time_preference`: { preferred_max_minutes, confidence, updated_at }
- `budget_preference`: { preferred_price_band, confidence, updated_at }
- `novelty_preferences`: { cooldown_days, diversity_weight, updated_at }

## `recommendation_feedback_events`

- `event_id`
- `user_id`
- `recommendation_id`
- `recipe_id`
- `action`: `reject` | `save` | `cook_complete` | etc.
- `reason_code` (nullable)
- `reason_text` (nullable)
- `context_snapshot`
- `created_at`

## Safety and UX Guardrails

- Allergy and strict dietary reasons should prompt high-confidence confirmation path.
- Do not auto-hard-block from one ambiguous signal unless it is explicit and safety-related.
- Always allow user to review/remove constraints in settings (future UI).
- Avoid over-blocking that collapses candidate pool to near zero.

## Relationship to Recommender V2 Blueprint

This document refines the hard/soft filter layer described in:
- `backend/docs/RECOMMENDER_V2_BLUEPRINT.md`

Integration points:
- Constraint Gate (before Stage 1/2 ranking)
- Re-ranking penalty logic
- Feedback logging pipeline
- Evaluation guardrails (constraint violation = 0 for hard blocks)

## Rollout Plan

## Phase 1: Logging and Reason Codes

- Add reject reason taxonomy in backend events.
- Add optional reason selector in app rejection flow.
- No automatic hard-block except explicit allergy/dietary.

## Phase 2: Soft Filter Learning

- Enable confidence-based soft penalties from rejection reasons + behavior.
- Monitor candidate shrink rate and downstream conversion.

## Phase 3: Hard Constraint Confirmation

- Enable stricter hard blocks for confirmed constraints.
- Add user-visible constraint management UI.

## Phase 4: Survey Integration (Optional)

- Add profile survey as an additional source.
- Merge survey + behavior + reject reasons into unified constraint profile.

## Open Decisions

1. Which reason codes are mandatory in v1 reject UI?
2. What confidence threshold upgrades soft -> hard for non-safety constraints?
3. Should "disliked ingredient" ever become hard without explicit confirmation?
4. What is the fallback behavior when hard filters remove all candidates?
5. How should constraints sync across devices/accounts?

