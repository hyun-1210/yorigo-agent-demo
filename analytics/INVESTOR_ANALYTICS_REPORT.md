# Yorigo — Investor Analytics Report

**Generated:** 2026-06-27  
**Mixpanel project:** `4016163` (yorigo-co-ltd)  
**Data window queried:** 2024-01-01 → 2026-06-27  
**Raw export:** `analytics/mixpanel_investor_data.json`

> **Note on data collection:** The Mixpanel MCP server was not available in this environment (server errored). All figures were pulled via the authenticated `mixpanel_headless` CLI (`python -m mixpanel_headless`). Re-run `python analytics/pull_mixpanel_data.py` to refresh.

---

## Executive summary

Yorigo’s Mixpanel data shows a **sharp product launch / growth spike starting ~2026-05-28**, with sustained daily usage through June 2026. Mixpanel tracking was integrated into the Flutter app in this period; **pre-May 2026 Mixpanel figures are effectively zero** (Firebase Analytics may have older history not mirrored here).

| Metric | Value | Definition |
|--------|-------|------------|
| **Total unique sign-ups** (Mixpanel) | **2,218** | Users who fired `sign_up` at least once |
| **Total unique app installs tracked** | **2,369** | Users who fired `app_first_open` (once per install) |
| **Total unique users who completed a parse** | **1,047** | Users who fired `recipe_parsing_completed` |
| **Peak DAU — registered users** | **493** | Unique `yorigo_active_user` on 2026-05-28 |
| **Peak DAU — all app activity** | **2,201** | Unique `screen_view` on 2026-05-28 (includes guests) |
| **Avg DAU June (registered)** | **~238** | Mean daily unique `yorigo_active_user` (excl. zero days) |
| **Avg DAU June (all activity)** | **~402** | Mean daily unique `screen_view` |
| **WAU (week of 2026-06-22) — registered** | **821** | Unique `yorigo_active_user` |
| **WAU (week of 2026-06-22) — all activity** | **1,571** | Unique `screen_view` |
| **Tracked cart expenditure (KRW)** | **₩663,448** | Sum of `total_expenditure` on `cart_purchase_completed` |
| **Users who completed a cart purchase** | **20** | Unique users with `cart_purchase_completed` |
| **Users who tapped “add to cart” (tracked)** | **~138–263** | See cart funnel — legacy UI events from recent builds |
| **Users who engaged with cart (checked ingredients)** | **747** | Unique `ingredient_purchase_checked` |
| **Users who clicked affiliate links** | **30** | Unique users with `affiliate_link_clicked` |
| **Reviews written** | **59** | Unique users with `review_created` |

**Product story for investors:** Users discover recipes from short-form video (Instagram-heavy), parse them in-app, bookmark to their library, and a subset progresses to shopping-cart ingredient checkout with Coupang/Kurly affiliate links. Conversion to completed purchase is early but measurable (20 users, ~₩663k tracked spend).

---

## How we measure active users

### DAU — registered users (`yorigo_active_user`)

- **What it means:** A **signed-in Firebase user** opened the main app navigator (home tab shell) on that calendar day.
- **How it fires:** `MainNavigator.initState` → `_trackAppAccess()` → `UserService.updateLastAccessed()` → `AnalyticsService.trackActiveUser(uid)` → Mixpanel event `yorigo_active_user` with `day_id`, `week_id`, `month_id`.
- **Also on:** App resume (`AppLifecycleState.resumed` in `MainNavigator`) re-triggers `_trackAppAccess()`.
- **Identity:** Mixpanel `identify(userId)` after sign-in; `reset()` on sign-out.
- **Use for investors:** **DAU of authenticated, account-holding users.**

### DAU — all unique activity (`screen_view`)

- **What it means:** Any distinct Mixpanel distinct_id that viewed at least one screen that day — **includes guests** (not signed in) and signed-in users.
- **How it fires:** `AnalyticsService.trackScreen()` on route changes (`_AnalyticsNavigatorObserver` on push/pop/replace), main tab switches (`trackMainTab`), and explicit `trackRoute` calls.
- **Screen names include:** `dashboard_home`, `feed_explore`, `shopping_cart`, `fridge`, `profile`, `recipe_detail`, `login`, `signup`, etc.
- **Use for investors:** **Total daily reach** of the app UI, including try-before-sign-up flows.

### DAU — guest vs authenticated parsing

`parsing_request_started` carries `is_authenticated` (1 = logged in, 0 = guest):

| Month | Authenticated parse starts | Guest parse starts |
|-------|---------------------------|-------------------|
| May 2026 | 7,846 | 1,180 |
| June 2026 | 20,971 | 1,718 |

Guests can parse locally without an account; most parse volume is from signed-in users.

### WAU

Same events as DAU, aggregated by ISO week (`week_id` on `yorigo_active_user`).

| Week starting | Registered WAU (`yorigo_active_user`) | All activity WAU (`screen_view`) |
|---------------|----------------------------------------|----------------------------------|
| 2026-05-04 | 110 | 817 |
| 2026-05-11 | 66 | 586 |
| 2026-05-18 | 60 | 391 |
| 2026-05-25 | 956 | 4,973 |
| 2026-06-01 | 581 | 1,967 |
| 2026-06-08 | 499 | 1,118 |
| 2026-06-15 | 984 | 2,321 |
| 2026-06-22 | 821 | 1,571 |

---

## Daily active users — last 30 days (selected)

| Date | Registered DAU | All-activity DAU (`screen_view`) | Sign-ups | Parses completed |
|------|----------------|----------------------------------|----------|------------------|
| 2026-05-28 | 493 | 2,201 | 449 | — |
| 2026-05-29 | 492 | 1,698 | 328 | — |
| 2026-06-01 | 257 | 596 | 44 | — |
| 2026-06-15 | 185 | 268 | 42 | — |
| 2026-06-17 | 405 | 749 | — | — |
| 2026-06-22 | 324 | 530 | — | — |
| 2026-06-26 | 326 | 606 | — | — |

Full daily series: see `mixpanel_investor_data.json` → `dau_unique_daily`.

**2026-06-27 shows 0** because the query ran early on that calendar day (incomplete day).

---

## Monthly growth (unique users per month)

| Month | Sign-ups | App first open | Parse started | Parse completed |
|-------|----------|----------------|---------------|-----------------|
| Apr 2026 | 3 | 0 | 2 | 2 |
| May 2026 | 1,042 | 0* | 1,435 | 414 |
| Jun 2026 | 1,172 | 2,353 | 1,978 | 501 |

\* `app_first_open` only appears in Mixpanel from June — the event was added with the Mixpanel SDK integration; May sign-ups are not backfilled with install events.

---

## User journey funnel (unique users, all time)

| Stage | Event | Unique users | % of sign-ups (2,218) |
|-------|-------|--------------|------------------------|
| Install / first launch | `app_first_open` | 2,369 | 107%* |
| Account created | `sign_up` | 2,218 | 100% |
| Parse attempted | `parsing_request_started` | — | — |
| Parse succeeded | `recipe_parsing_completed` | 1,047 | 47% |
| Parse failed | `recipe_parsing_failed` | 1,286 | 58% |
| Recipe saved / bookmarked | `recipe_bookmarked` | 426 | 19% |
| Ingredient checked in cart | `ingredient_purchase_checked` | 747 | 34% |
| 50%+ cart ingredients checked | `cart_majority_checked` | 18 | 0.8% |
| Affiliate link clicked | `affiliate_link_clicked` | 30 | 1.4% |
| Cart purchase completed | `cart_purchase_completed` | 20 | 0.9% |
| Ingredient purchase recorded | `ingredient_purchased` | 16 | 0.7% |
| Review posted | `review_created` | 59 | 2.7% |

\* Install count can exceed sign-ups because guests use the app before registering, and `app_first_open` / `sign_up` were not tracked for the same historical window.

**Funnel visualization:**

```
app_first_open (2,369)
    → sign_up (2,218)
        → recipe_parsing_completed (1,047)
            → recipe_bookmarked (426)
                → ingredient_purchase_checked (747)
                    → cart_majority_checked (18)
                        → affiliate_link_clicked (30)
                            → cart_purchase_completed (20)
                                → review_created (59)
```

Note: `ingredient_purchase_checked` unique users (747) exceeds bookmarked (426) because checking ingredients does not require bookmarking, and event volumes are not strictly nested.

---

## Recipe parsing — volume and platforms

### Completed parses by platform (event count, not unique users)

| Platform | May 2026 | June 2026 |
|----------|----------|------------|
| Instagram | 820 | 740 |
| YouTube | 211 | 70 |
| Manual entry | 57 | 142 |
| Naver Blog | 12 | 50 |
| TikTok | 20 | 1 |

Instagram is the dominant source — aligned with Korean recipe short-form content behavior.

### Parse success vs failure

Many users experience failed parses (`recipe_parsing_failed` unique users: 1,286 vs completed: 1,047). Failures fire on backend errors, save failures, or exhausted retries in `BackgroundParsingService`.

---

## Monetization & commerce

| Metric | Value |
|--------|-------|
| Total tracked cart expenditure | **₩663,448** |
| May 2026 expenditure | ₩447,635 |
| June 2026 expenditure | ₩215,813 |
| Unique users completing purchase flow | 20 |
| Unique users clicking Coupang/Kurly/Oasis links | 30 |

**How purchase value is tracked:** When a user confirms purchase in the shopping cart (`cart_screen.dart`), `trackPurchaseCompleted` sends `total_expenditure`, `coupang_expenditure`, `kurly_expenditure` (KRW integers). Per-ingredient `ingredient_purchased` events also carry `price` and `marketplace`.

**Affiliate clicks:** `openMarketplaceLink()` in `cart_screen.dart` fires `affiliate_link_clicked` before opening Coupang in-app browser, Kurly, or Oasis.

---

## Cart funnel — add recipe to cart → purchase

### What “add to cart” means in Yorigo

1. User parses or opens a recipe → taps **「장바구니에 담기」** on recipe detail (`recipe_detail_screen.dart` → `_showAddToCartDialog()`).
2. User selects ingredients and portions → `CalendarMealSheet` → `UserService.addToCart()` writes to Firestore `users/{uid}.cartItems`.
3. User opens **장바구니** tab → checks ingredients as purchased → may open Coupang/Kurly links → confirms purchase (moves items to 냉장고).

**Important:** The current production app does **not** fire a dedicated Mixpanel event when a recipe is added to the cart (`addToCart()` has no analytics call). Cart-add numbers below come from **legacy UI events** still present in Mixpanel from recent app builds, plus downstream cart engagement events.

### Funnel — unique users (May 1 – Jun 27, 2026)

| Step | Mixpanel event | Unique users | % of all sign-ups (2,218) | What it measures |
|------|----------------|--------------|---------------------------|------------------|
| 1. Tap “add to cart” (footer) | `recipe_cart_add_footer_clicked` | **138** | 6.2% | Tapped main footer **장바구니에 담기** on recipe detail |
| 2. Tap “add” on ingredient row | `recipe_ingredient_add_clicked` | **125** | 5.6% | Tapped per-ingredient **담기** in recipe detail |
| 3. Check ingredient in cart | `ingredient_purchase_checked` | **747** | 33.7% | Marked ingredient purchased/unpurchased in shopping cart |
| 4. 50%+ ingredients checked | `cart_majority_checked` | **18** | 0.8% | At least half of a recipe’s cart ingredients checked |
| 5. Open marketplace link | `affiliate_link_clicked` | **30** | 1.4% | Opened Coupang / Kurly / Oasis product link |
| 6. Complete purchase in app | `cart_purchase_completed` | **20** | 0.9% | Confirmed purchase; items saved to 냉장고 |
| 7. Per-ingredient purchase line | `ingredient_purchased` | **16** | 0.7% | Fired per ingredient on purchase confirm |

**Estimated unique users who tapped add-to-cart UI:** ~**180–220** (138 footer + 125 ingredient-row; some users did both — exact overlap not in Mixpanel export).

### Conversion: cart add → actually buy

| Conversion | Users | Rate |
|------------|-------|------|
| Add-to-cart tap (footer) → completed purchase | ~0 tracked same-path | **~0%** in daily cohorts* |
| Add-to-cart tap (footer) → affiliate click | ~2–11% D0 on Jun cohorts | Small samples (n=16–18/day) |
| Checked ingredient in cart → completed purchase | ~1–5% D0 on large cohorts | e.g. Jun 17 cohort n=93 → **1%** purchase same day |
| Checked ingredient in cart → affiliate click | ~1–9% D0 | e.g. Jun 19 cohort n=33 → **9%** affiliate D0 |
| All sign-ups → completed purchase | 20 / 2,218 | **0.9%** overall |

\*Most `cart_purchase_completed` events occurred in **May** (before `recipe_cart_add_footer_clicked` tracking started ~Jun 6), so footer-click → purchase daily retention reads **0%** — this is a **tracking timeline gap**, not necessarily zero conversion.

### Tracked commerce volume

| Metric | Value |
|--------|-------|
| Total in-app purchase value | **₩663,448** |
| Users with ≥1 completed purchase | **20** |
| Users who clicked affiliate links | **30** |

### Instrumentation gap (action item)

To measure add-to-cart accurately going forward, wire `AnalyticsService` when `UserService.addToCart()` succeeds (and optionally when `CalendarMealSheet` confirms). Today only legacy click events and downstream cart actions are visible.

---

## Cohort retention — daily (first 7 days)

Daily cohort retention: users who did the **birth event** on cohort date D0, then the **return event** on D0…D7.

**Full tables (all cohorts):** `analytics/retention_daily_tables.md`  
**Raw JSON:** `analytics/retention_daily_*.json`

### Sign-up → active user — launch spike cohorts

Primary growth event **2026-05-28** (449 sign-ups that day).

| Cohort (sign-up date) | Cohort size | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 |
|----------------------|-------------|-----|-----|-----|-----|-----|-----|-----|-----|
| 2026-05-28 | **449** | 99% | **24%** | **21%** | 19% | 15% | 13% | 14% | **12%** |
| 2026-05-29 | 328 | 98% | 27% | 22% | 18% | 17% | 16% | 16% | 9% |
| 2026-05-30 | 65 | 100% | 22% | 18% | 29% | 15% | 18% | 11% | 20% |
| 2026-05-31 | 43 | 100% | 47% | 42% | 23% | 26% | 16% | 19% | 26% |
| 2026-06-01 | 44 | 100% | 39% | 30% | 18% | 20% | 18% | 23% | 18% |

**Average across large sign-up cohorts (n≥100, 5 cohorts):** D0 **98.9%** → D1 **27.2%** → D3 **20.7%** → D7 **13.5%**.

### Sign-up → parse completed (first 7 days)

| Cohort | Size | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 |
|--------|------|-----|-----|-----|-----|-----|-----|-----|-----|
| 2026-05-28 | 449 | 11% | 2% | 1% | 1% | 1% | 1% | 1% | 1% |
| 2026-06-17 | 227 | 9% | 1% | 0% | 0% | 0% | 0% | 0% | 0% |
| 2026-06-18 | 129 | 8% | 1% | 2% | 1% | 1% | 0% | 0% | 0% |

~**9–11%** of sign-ups complete a parse on D0; day-1 parse retention is **~1–2%**.

### Sign-up → recipe bookmarked (first 7 days)

| Cohort | Size | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 |
|--------|------|-----|-----|-----|-----|-----|-----|-----|-----|
| 2026-05-28 | 449 | 18% | 4% | 2% | 2% | 2% | 2% | 2% | 1% |
| 2026-06-17 | 227 | 11% | 0% | 2% | 2% | 2% | 0% | 0% | 0% |

### Ingredient checked in cart → purchase / affiliate (first 7 days)

Users who checked an ingredient in the shopping cart, then later purchased or clicked a marketplace link.

| Cohort (first check date) | Size | → Purchase D0 | → Affiliate D0 | → Affiliate D1 |
|---------------------------|------|---------------|----------------|----------------|
| 2026-06-17 | 93 | 1% | 1% | 0% |
| 2026-06-18 | 50 | 0% | 4% | 2% |
| 2026-06-19 | 33 | 3% | **9%** | 0% |
| 2026-06-24 | 19 | 5% | 5% | — |

### First open → active user (guest / install cohorts, Jun 2026)

`app_first_open` only tracked from June; D0 active rate is **guest + signed-in** screen usage.

| Cohort | Size | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 |
|--------|------|-----|-----|-----|-----|-----|-----|-----|-----|
| 2026-06-17 | 379 | 8% | 3% | 3% | 3% | 3% | 2% | 3% | 3% |
| 2026-06-18 | 249 | 11% | 4% | 5% | 3% | 3% | 4% | 3% | 2% |

---

## Cohort retention (weekly)

Retention = users who did **birth event** in cohort week, then **return event** in week N. Rates below are from Mixpanel `retention_rate` (unbounded carry-back).

### Sign-up → return as active user (`sign_up` → `yorigo_active_user`)

| Cohort week | Cohort size | Week 0 | Week 1 | Week 2 | Week 4 |
|-------------|-------------|--------|--------|--------|--------|
| 2026-05-25 | 892 | 99% | 31% | 27% | 4% |
| 2026-06-01 | 168 | 99% | 39% | 31% | — |
| 2026-06-08 | 117 | 98% | 30% | 9% | — |
| 2026-06-15 | 607 | 99% | 20% | — | — |
| 2026-06-22 | 280 | 100% | — | — | — |

**Interpretation:** ~99% of new sign-ups are “active” in week 0 (same week). **Week-1 retention ~20–39%** for recent cohorts — early product with launch spike; largest cohort (May 25, n=892) shows 31% W1 and 27% W2.

### Sign-up → completed parse (`sign_up` → `recipe_parsing_completed`)

| Cohort week | Size | Week 0 | Week 1 |
|-------------|------|--------|--------|
| 2026-05-25 | 892 | 11% | 2% |
| 2026-06-01 | 168 | 11% | 1% |
| 2026-06-15 | 607 | 11% | 0% |

~11% of sign-ups complete a parse in week 0; low repeat-parse retention in following weeks.

### Sign-up → bookmark recipe (`sign_up` → `recipe_bookmarked`)

| Cohort week | Size | Week 0 | Week 1 |
|-------------|------|--------|--------|
| 2026-05-25 | 892 | 18% | 4% |
| 2026-06-01 | 168 | 14% | 5% |
| 2026-06-15 | 607 | 14% | 0% |

### Sign-up → cart purchase completed (`sign_up` → `cart_purchase_completed`)

| Cohort week | Size | Week 0 |
|-------------|------|--------|
| 2026-06-01 | 168 | 1% |
| 2026-06-15 | 607 | 0% |
| 2026-06-22 | 280 | 0% |

Purchase conversion within first week is **~0–1%** of sign-ups (small sample, n=20 total purchasers).

### Parse → re-parse (`recipe_parsing_completed` → `recipe_parsing_completed`)

| Cohort week | Size | Week 0 | Week 1 |
|-------------|------|--------|--------|
| 2026-05-25 | 315 | 22% | 2% |
| 2026-06-15 | 245 | 29% | 1% |

Among users who complete a parse, **~22–29% parse again in the same week**; week-1 re-parse is low (~1–2%).

Full weekly retention matrices: `mixpanel_investor_data.json` → `retention_weekly`.  
Daily first-week matrices: `analytics/retention_daily_tables.md`.

---

## Engagement — reviews & cooking

| Metric | Unique users |
|--------|--------------|
| `review_created` | 59 |
| `cart_majority_checked` (50%+ ingredients checked) | 18 |

**Review flow:** User submits review in `ReviewService.submitReview()` → `trackReviewWrittenForUser` (Firestore + Mixpanel People) + `trackReviewCreated` with `recipe_id`, `rating`, `platform`, `photo_count`.

**Cooking start:** `trackCookingButtonClickForUser` fires from `recipe_detail_screen.dart` when user taps “요리 시작” — updates Firestore counter and Mixpanel People only (**no Mixpanel event** for cooking button today).

---

## Event dictionary — what each event means and where it fires

### Core lifecycle

| Event | Business meaning | Trigger (code path) | Key properties |
|-------|------------------|---------------------|----------------|
| `app_first_open` | First app launch after install | `main.dart` → `trackAppFirstOpenIfNeeded()` once per install (SharedPreferences gate `_mp_first_open_tracked`) | — |
| `sign_up` | New account created | `auth_service.dart` → `trackSignUp()` on email signup and `trackSocialSignupCompletion()` for Kakao/Google/Apple | `sign_up_method` (e.g. `email`, `kakao`) |
| `yorigo_active_user` | Registered user opened app that day | `main.dart` `_trackAppAccess()` → `user_service.updateLastAccessed()` → `trackActiveUser()` | `day_id`, `week_id`, `month_id` |
| `screen_view` | User navigated to a screen | `AnalyticsService.trackScreen()` via navigator observer + tab changes | `screen_name`, `screen_class` |
| `screen_stay` | User left a screen after ≥1s | `trackScreen()` flush on navigation / app pause | `screen_name`, `duration_seconds`, `next_screen` |

### Recipe parsing pipeline

| Event | Business meaning | Trigger | Key properties |
|-------|------------------|---------|----------------|
| `parsing_request_started` | User submitted a URL / started parse | `background_parsing_service.dart` at start of `parseRecipe()` (and reparse paths) | `platform`, `is_authenticated` (0/1) |
| `recipe_parsing_completed` | Backend returned recipe; parse succeeded | `background_parsing_service.dart` on successful completion (multiple code paths) | `platform`, `ingredient_count`, `step_count`, `saved_to_cloud`, `parse_time_ms` |
| `recipe_parsing_failed` | Parse failed (server, save, retries) | `background_parsing_service.dart` on failure | `platform`, `saved_to_cloud`, `error`, `error_type` |

**People profile (not events):** `parseAttemptCount` incremented via `trackParseAttemptForUser()` when authenticated user starts parse.

### Recipe library & social

| Event | Business meaning | Trigger | Key properties |
|-------|------------------|---------|----------------|
| `recipe_bookmarked` | User saved recipe to library (first time) | `user_service.addSavedRecipe()` when `isFirstSave` | `recipe_id`, `platform` |
| `recipe_saved_from_feed` | **⚠️ NOT WIRED** — defined in `analytics_service.dart` but **never called** from UI | — | — |
| `recipe_cart_add_footer_clicked` | **Legacy** — tap footer 「장바구니에 담기」 | Older app builds (not in current Dart); 138 unique users in Mixpanel | — |
| `recipe_ingredient_add_clicked` | **Legacy** — tap ingredient-row 「담기」 | Older app builds (not in current Dart); 125 unique users | — |
| `recipe_ingredient_purchase_clicked` | **Legacy** — tap ingredient 「구매」 | Older app builds; 92 unique users | — |

**⚠️ Add-to-cart today:** `UserService.addToCart()` / `CalendarMealSheet` confirm **do not emit Mixpanel events** in the current codebase. Use legacy click events above or add new tracking on `addToCart()`.

**People profile:** `savedRecipesFromFeedCount` incremented via `trackSavedRecipeForUser()` on bookmark (name is historical; fires for all first-time saves).

### Shopping cart & monetization

| Event | Business meaning | Trigger | Key properties |
|-------|------------------|---------|----------------|
| `ingredient_purchase_checked` | User checked/unchecked ingredient as purchased in cart | `cart_screen.dart` `_markIngredientPurchased` / `_unmarkIngredientPurchased` | `ingredient_name`, `checked`, `category` |
| `cart_majority_checked` | ≥50% of recipe ingredients marked purchased (once per session) | `cart_screen.dart` `_checkCartMajorityThreshold()` | `recipe_id`, `recipe_name`, `total_ingredients`, `checked_count`, `threshold` |
| `affiliate_link_clicked` | User opened Coupang/Kurly/Oasis product link | `cart_screen.dart` `openMarketplaceLink()` | `marketplace`, `ingredient_name`, `recipe_id`, `source_screen` |
| `cart_purchase_completed` | User confirmed cart purchase (saved to fridge/history) | `cart_screen.dart` after successful purchase batch write | `ingredient_count`, `recipe_count`, `total_expenditure`, `coupang_expenditure`, `kurly_expenditure` |
| `ingredient_purchased` | Per-ingredient line item on purchase confirm | `cart_screen.dart` loop after `trackPurchaseCompleted` | `ingredient_name`, `price`, `marketplace`, `category` |
| `purchase_button_clicked` | **⚠️ NOT WIRED** — defined but **never called** | — | — |

**Firestore-only (not Mixpanel):** `trackProductCheckEvent()` writes rich product metadata to `users/{uid}/product_check_events` for internal analysis.

**People profiles on purchase:** `hasPurchasedIngredients`, `purchaseCount`, `purchaseTotalPrice`, marketplace splits, `itemsBoughtTotalCount`, etc.

### Reviews

| Event | Business meaning | Trigger | Key properties |
|-------|------------------|---------|----------------|
| `review_created` | User posted a recipe review | `review_service.dart` `submitReview()` after Firestore write | `recipe_id`, `rating`, `platform`, `photo_count`, `has_photo` |

**People profile:** `reviewCount` via `trackReviewWrittenForUser()`.

### Legacy / SDK events (in Mixpanel but not in current `analytics_service.dart`)

| Event | Notes |
|-------|-------|
| `$ae_first_open` | Mixpanel automatic first-open (SDK may have emitted before `trackAutomaticEvents: false`) |
| `recipe_cart_add_footer_clicked` | Present in Mixpanel (138 unique users); **not in current Dart codebase** — likely older build or Firebase→Mixpanel bridge |
| `recipe_ingredient_add_clicked` | Same — 125 unique users, no current Dart reference |
| `recipe_ingredient_purchase_clicked` | Same — 92 unique users, no current Dart reference |

---

## Mixpanel People properties (per-user profiles)

Updated via `getPeople().set()` / `increment()` — useful for investor cohort exports:

| Property | Meaning |
|----------|---------|
| `auth_state` | `signed_in` after `identify()` |
| `parseAttemptCount` | Total parse attempts (authenticated) |
| `reviewCount` | Reviews written |
| `purchaseButtonClickCount` | Purchase button clicks (Firestore counter; **no event**) |
| `cookingButtonClickCount` | Cooking starts (Firestore counter; **no event**) |
| `savedRecipesFromFeedCount` | First-time recipe saves |
| `hasPurchasedIngredients` | Boolean — completed at least one cart purchase |
| `purchaseCount` | Number of purchase sessions |
| `purchaseTotalPrice` | Cumulative KRW spend (cart confirmations + deltas) |
| `purchaseTotalPriceCoupang` / `purchaseTotalPriceKurly` | Marketplace spend splits |
| `hasInProgressPurchaseSession` | Cart reached ≥25% ingredients checked (once per cart signature) |

---

## Screen name reference (`screen_view`)

| `screen_name` | UI |
|---------------|-----|
| `dashboard_home` | Home tab (index 0) |
| `feed_explore` | Feed / explore tab |
| `shopping_cart` | Cart tab |
| `fridge` | Fridge tab |
| `profile` | Profile tab |
| `main_navigator` | Root route `/` |
| `login` / `signup` | Auth screens |
| `recipe_detail` | Recipe detail |
| `settings` | Settings |
| `recommendation` | Recommendation screen |
| `profile_detail` | Profile detail route |

---

## Caveats & data quality notes

1. **Short history:** Meaningful Mixpanel volume starts **May 2026**. Do not compare to 2024–2025 zeros — tracking was not live.
2. **`app_first_open` gap:** May sign-ups lack corresponding `app_first_open` events; install-to-signup retention from `app_first_open` → `sign_up` is unreliable for May cohorts.
3. **Launch spike (2026-05-28):** DAU jumped ~10× (registered: ~17 → 493). Likely marketing release, influencer campaign, or store listing — investigate separately.
4. **DAU today = 0:** Partial calendar day when query ran.
5. **Guest identity:** Guests use anonymous Mixpanel distinct_ids until sign-up; `screen_view` over-counts vs `yorigo_active_user` for “total reach.”
6. **Unwired events:** `purchase_button_clicked`, `recipe_saved_from_feed` exist in code but produce **zero** events — funnel gaps are instrumentation gaps, not necessarily user behavior gaps.
7. **Cooking engagement** is under-reported in Mixpanel (People counter only).
8. **Expenditure** reflects in-app tracked prices at purchase confirmation, not verified external order totals.
9. **Funnel unique-user sums** across months can double-count returning users; use Mixpanel cohorts for strict funnel analysis.

---

## Recommended investor dashboard (already scripted)

`analytics/create_retention_dashboard.py` creates a Mixpanel dashboard **“Yorigo Retention & Engagement”** with:

- Weekly retention: parse→parse, sign-up→bookmark, sign-up→affiliate, sign-up→purchase, sign-up→cart majority
- Weekly trends: parse attempts, recipe bookmarks

Run: `python analytics/create_retention_dashboard.py` (requires `mixpanel_headless login`).

---

## Refreshing this report

```powershell
cd c:\Users\david\Desktop\Yonsei\Yorigo\code\yorigo
python analytics/pull_mixpanel_data.py
python analytics/format_retention_tables.py
```

Then update this document from `analytics/mixpanel_investor_data.json` and `analytics/retention_daily_tables.md`.
