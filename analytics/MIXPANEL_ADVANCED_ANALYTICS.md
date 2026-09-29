# Yorigo Advanced Mixpanel Analytics

This document describes the expanded Mixpanel instrumentation in the Flutter app and the dashboards created to analyze user behaviour.

## Mixpanel dashboards

| Dashboard | ID | Purpose |
|-----------|----|---------|
| Yorigo Product Overview | `11358271` | North-star daily metrics: DAU, auth, views, parses, purchases, navigation |
| Yorigo Acquisition & Auth | `11358272` | Sign-up/login methods, first-open conversion, churn signals |
| Yorigo Recipe Engagement | `11358273` | View → bookmark → cook → review, parse quality, search & share |
| Yorigo Purchase Funnel | `11358274` | Cart/affiliate conversion, marketplace mix, spend |
| Yorigo Engagement & Retention | `11358275` | Cohort retention, notifications, social, fridge, meal calendar |
| Yorigo Retention & Engagement (legacy) | `11241866` | Earlier retention dashboard |

Open in Mixpanel: **Dashboards** → select a board by title.

---

## Event catalog

### Lifecycle & session

| Event | Properties | Fired when |
|-------|------------|------------|
| `app_first_open` | — | First launch per install |
| `yorigo_active_user` | `day_id`, `week_id`, `month_id` | Daily/weekly/monthly active user ping |
| `screen_view` | `screen_name`, `screen_class` | Route or main tab change |
| `screen_stay` | `screen_name`, `duration_seconds`, `next_screen?` | Leave screen (dwell ≥ 1s) |
| `main_tab_selected` | `tab_index`, `tab_name` | Bottom nav tap (`home` / `explore` / `cart` / `fridge` / `profile`) |

### Auth

| Event | Properties | Fired when |
|-------|------------|------------|
| `sign_up` | `sign_up_method` | New account created (`email`, `google`, `kakao`, `apple`) |
| `login` | `login_method` | Returning user signs in |
| `logout` | — | User signs out |
| `password_reset_requested` | — | Password reset email requested |
| `account_deleted` | — | Account deletion succeeds |

### Recipe parsing

| Event | Properties | Fired when |
|-------|------------|------------|
| `parsing_request_started` | `platform`, `is_authenticated` | Parse job starts |
| `recipe_parsing_completed` | `platform`, `ingredient_count`, `step_count`, `saved_to_cloud`, `parse_time_ms?` | Parse succeeds |
| `recipe_parsing_failed` | `platform`, `saved_to_cloud`, `error`, `error_type` | Parse fails |
| `add_recipe_opened` | `source`, `has_initial_url` | Add-recipe sheet opens |
| `share_extension_opened` | — | Shared URL handled from share extension |

`platform` values: `youtube`, `instagram`, `tiktok`, `naver_blog`, `manual`, `unknown`

### Recipe engagement

| Event | Properties | Fired when |
|-------|------------|------------|
| `recipe_viewed` | `recipe_id`, `platform?`, `source_screen?` | Recipe detail opened (once per recipe per session) |
| `recipe_bookmarked` | `recipe_id`, `platform?` | Recipe saved/bookmarked |
| `cooking_started` | `recipe_id?`, `source_screen` | Cooking instruction sheet opened |
| `cooking_completed` | `recipe_id?`, `source_screen` | Fridge “요리 완료” finishes |
| `review_created` | `recipe_id`, `rating`, `platform`, `photo_count`, `has_photo` | Review submitted |
| `search_opened` | `source_screen` | Recipe search opened |
| `meal_calendar_opened` | `source_screen` | Meal calendar opened |

### Home discovery (behavior)

| Event | Properties | Fired when |
|-------|------------|------------|
| `home_category_clicked` | `source` (`recipebook` / `primary_filter` / `secondary_filter`), `category_id?`, `category_name?`, `position?` | Recipebook pill or 1차/2차 필터 탭 |
| `home_recipe_clicked` | `recipe_id`, `section_id`, `section_name?`, `card_index?` | Home trend/seasonal/chef card tap (section attribution) |
| `home_section_impression` | `section_id`, `section_name?`, `section_order?`, `visible_recipe_count?` | Section ≥50% visible (once per section per app session) |
| `home_section_scroll_summary` | `section_id`, `max_visible_index`, `item_count`, `section_name?`, `depth_percent?` | Horizontal carousel scrolled; flushed on home tab leave |
| `home_vertical_scroll_summary` | `max_depth_percent`, `deepest_section_id?`, `session_id?` | Vertical home scroll; flushed on home tab leave |

Notes:
- `section_id` / `category_id` are ASCII-safe keys (`HomeSectionKeys`); Korean labels go in `*_name` (truncate, not sanitize).
- Super properties on Mixpanel init: `app_version`, `app_build`, `platform`, `build_mode`, `environment`.

### Cart & purchase

| Event | Properties | Fired when |
|-------|------------|------------|
| `recipe_cart_add_footer_clicked` | `recipe_id?` | Recipe detail footer “장바구니에 담기” |
| `recipe_ingredient_add_clicked` | `ingredient_name`, `recipe_id?` | Ingredient row “담기” |
| `recipe_ingredient_purchase_clicked` | `ingredient_name`, `recipe_id?` | Ingredient row “구매” |
| `ingredient_purchase_checked` | `ingredient_name`, `checked`, `category?` | Cart check/uncheck |
| `cart_majority_checked` | `recipe_id`, `recipe_name`, `total_ingredients`, `checked_count`, `threshold` | ≥50% of recipe ingredients checked |
| `cart_marketplace_selected` | `marketplace`, `method` (`tab` / `swipe`) | Cart Coupang/Kurly tab switch |
| `cart_alternative_products_opened` | `ingredient_name?`, `marketplace?`, `product_count?` | Alternative products sheet opened |
| `cart_alternative_product_selected` | `ingredient_name?`, `product_id?`, `rank?`, `filter?`, `sort?` | User picks an alternative product |
| `cart_product_buy_clicked` | `marketplace`, `ingredient_name?`, `product_id?`, `source` | Main cart card buy CTA (before link open) |
| `affiliate_link_clicked` | `marketplace`, `ingredient_name?`, `product_id?`, `recipe_id?`, `source_screen?` | Coupang/Kurly/Oasis link click (once per open; Android no double-fire) |
| `affiliate_open_result` | `marketplace`, `success` (`1`/`0`), `reason?`, `product_id?`, `ingredient_name?` | External link launch success/failure |
| `purchase_button_clicked` | `ingredient_count`, `source?` | User taps 구매 완료 |
| `cart_purchase_completed` | `ingredient_count`, `recipe_count`, `total_expenditure`, `coupang_expenditure`, `kurly_expenditure` | Purchase flow completes |
| `ingredient_purchased` | `ingredient_name`, `price`, `marketplace`, `category` | Per-ingredient purchase in session |

### Social, fridge, notifications

| Event | Properties | Fired when |
|-------|------------|------------|
| `user_followed` | `target_user_id` | Follow succeeds |
| `user_unfollowed` | `target_user_id` | Unfollow succeeds |
| `fridge_ingredient_added` | `item_count`, `method` | Manual fridge add (`manual` / `manual_batch`) |
| `notifications_opened` | — | Notifications screen opened |
| `notification_tapped` | `notification_type`, `is_actionable` | Notification action handled |

---

## Mixpanel People properties

Updated via identify / people set / increment:

| Property | Meaning |
|----------|---------|
| `auth_state` | `signed_in` / reset on logout |
| `signup_method` | Last sign-up method |
| `last_login_method` | Last login method |
| `account_deleted` | `true` after deletion |
| `parseAttemptCount` | Parse attempts |
| `reviewCount` | Reviews written |
| `purchaseButtonClickCount` | Purchase button taps |
| `cookingButtonClickCount` | Cooking button taps |
| `cookingCompletedCount` | Cooking completions |
| `savedRecipesFromFeedCount` | Recipes saved from feed |
| `followCount` | Follows created |
| `fridgeAddCount` | Fridge ingredients added |
| `hasPurchasedIngredients` | Ever purchased |
| `purchaseCount` | Purchase sessions |
| `itemsBoughtTotalCount` | Items bought |
| `purchaseTotalPrice` / `purchaseTotalPriceCoupang` / `purchaseTotalPriceKurly` | Spend totals |
| `purchasedRecipeCountTotal` / `purchasedRecipeServingsTotal` | Purchased recipe volume |
| `hasInProgressPurchaseSession` | Cart ≥25% purchased |

---

## Key call sites

| File | What is tracked |
|------|-----------------|
| `lib/services/analytics_service.dart` | All event APIs + Mixpanel/Firebase dual-write |
| `lib/services/auth_service.dart` | Login, logout, password reset, account delete, sign-up |
| `lib/services/user_service.dart` | Bookmark, follow/unfollow |
| `lib/services/background_parsing_service.dart` | Parse start/success/fail |
| `lib/services/review_service.dart` | Review created |
| `lib/main.dart` | First open, tabs, add-recipe, share extension, notification deep links |
| `lib/screens/recipe_detail_screen.dart` | Recipe view, cooking start, cart CTAs |
| `lib/screens/cart_screen.dart` | Marketplace tab, alt products, buy CTA, affiliate click/open result, purchase complete |
| `lib/screens/home_screen.dart` | Category/filter clicks, recipe click attribution, section impression, scroll summaries |
| `lib/constants/home_section_keys.dart` | Stable `section_id` mapping for home titles |
| `lib/utils/home_scroll_metrics.dart` | Carousel/vertical depth helpers |
| `lib/screens/fridge_screen.dart` | Ingredient add, cooking complete |
| `lib/widgets/app_header.dart` | Notifications opened |

---

## Funnel charts (Mixpanel)

| Funnel | Steps |
|--------|-------|
| First Open → Sign-up | `app_first_open` → `sign_up` |
| Sign-up → First Parse | `sign_up` → `parsing_request_started` → `recipe_parsing_completed` |
| View → Bookmark → Cook → Review | `recipe_viewed` → `recipe_bookmarked` → `cooking_started` → `review_created` |
| Parse → View → Cart Add | `recipe_parsing_completed` → `recipe_viewed` → `recipe_cart_add_footer_clicked` |
| Home Discover → Recipe | `home_section_impression` → `home_recipe_clicked` → `recipe_viewed` |
| Home Category → Recipe | `home_category_clicked` → `home_recipe_clicked` |
| Recipe → Cart → Affiliate → Purchase | `recipe_viewed` → `recipe_cart_add_footer_clicked` → `affiliate_link_clicked` → `cart_purchase_completed` |
| Cart Buy Intent → Open | `cart_product_buy_clicked` → `affiliate_link_clicked` → `affiliate_open_result` |
| Cart Alt Compare | `cart_alternative_products_opened` → `cart_alternative_product_selected` → `affiliate_link_clicked` |
| Cart Check → Majority → Complete | `ingredient_purchase_checked` → `cart_majority_checked` → `purchase_button_clicked` → `cart_purchase_completed` |

Retention charts use weekly cohorts for active users, sign-up → activity, sign-up → purchase, and parse → return parse.

---

## Data freshness notes

- Charts for **pre-existing** events (parses, purchases, bookmarks, affiliate clicks, etc.) populate immediately from historical Mixpanel data.
- Charts for **new** events (`home_*`, `cart_marketplace_selected`, `cart_product_buy_clicked`, `affiliate_open_result`, etc.) populate after a build with this instrumentation is released and users generate traffic.
- Mixpanel automatic events are **disabled** (`trackAutomaticEvents: false`); only explicit app events are sent.

---

## Related files

- `analytics/create_advanced_analytics_dashboards.py` — creates the five advanced dashboards + charts
- `analytics/create_retention_dashboard.py` — legacy retention dashboard script
- `yorigo-frontend/lib/config/environment_config.dart` — `MIXPANEL_PROJECT_TOKEN` / optional EU server URL
- `.cursor/mcp.json` — Mixpanel project token / API secret for tooling
