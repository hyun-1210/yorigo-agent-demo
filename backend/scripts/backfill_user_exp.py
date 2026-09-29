"""과거 행동으로 경험치를 다시 계산해 users.expTotal / level 에 반영한다.

기본은 dry-run. 실제 반영: --apply
시드 계정(@yorigo.app)은 제외.
이미 expBackfillVersion >= 1 인 유저는 건너뛴다.
"""

from __future__ import annotations

import argparse
import os
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

import firebase_admin
from firebase_admin import credentials, firestore

ROOT = Path(__file__).resolve().parents[2]
CRED = ROOT / "backend" / "firebase-service-account.json"
KST = timezone(timedelta(hours=9))
BACKFILL_VERSION = 1

PHOTO_EXP = 50
TEXT_EXP = 30
ATTEND_EXP = 20
STREAK = {3: 30, 7: 70, 14: 150, 30: 300}
LIKE_EXP = 10
COMMENT_EXP = 20
POST_EXP = 40
POST_SHORT_EXP = 20
LIKES_10 = 50
LIKES_30 = 100
COMMENTS_5 = 50
COMMENTS_15 = 100
FEEDBACK_EXP = 80
MEAL_EXP = 20
FOLLOW_EXP = 10
SAVE_EXP = 10
PROFILE_EXP = 100


def exp_required_for_level(level: int) -> int:
    if level <= 1:
        return 0
    n = level - 1
    return round(50 * (n**1.38))


def level_for_exp(total_exp: int) -> int:
    if total_exp <= 0:
        return 1
    lo, hi = 1, 8
    while exp_required_for_level(hi) <= total_exp:
        hi *= 2
        if hi > 100000:
            break
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if exp_required_for_level(mid) <= total_exp:
            lo = mid
        else:
            hi = mid - 1
    return lo


def _resolve_cred(cli_path: str | None) -> Path:
    if cli_path:
        return Path(cli_path)
    env = (os.getenv("GOOGLE_APPLICATION_CREDENTIALS") or "").strip()
    if env:
        return Path(env)
    return CRED


def _init(cred_path: Path):
    if firebase_admin._apps:
        return firestore.client()
    if not cred_path.exists():
        raise SystemExit(f"missing credentials: {cred_path}")
    firebase_admin.initialize_app(credentials.Certificate(str(cred_path)))
    return firestore.client()


def _to_day(value) -> str:
    if value is None:
        return "unknown"
    if hasattr(value, "timestamp"):
        dt = datetime.fromtimestamp(value.timestamp(), tz=timezone.utc).astimezone(KST)
        return dt.strftime("%Y-%m-%d")
    if isinstance(value, datetime):
        dt = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return dt.astimezone(KST).strftime("%Y-%m-%d")
    text = str(value)
    return text[:10] if len(text) >= 10 else "unknown"


def _has_photo(data: dict) -> bool:
    urls = data.get("photoUrls")
    if isinstance(urls, list) and any(str(u).strip() for u in urls):
        return True
    url = (data.get("photoUrl") or "").strip()
    return bool(url)


def _grant(day_counts: dict[str, int], day: str, limit: int) -> bool:
    used = day_counts.get(day, 0)
    if used >= limit:
        return False
    day_counts[day] = used + 1
    return True


def _streak_bonus(days: set[str]) -> int:
    parsed = []
    for key in days:
        try:
            parsed.append(datetime.strptime(key, "%Y-%m-%d").date())
        except ValueError:
            continue
    parsed.sort()
    exp = 0
    run = 0
    prev = None
    for day in parsed:
        if prev is not None and (day - prev).days == 1:
            run += 1
        else:
            run = 1
        exp += STREAK.get(run, 0)
        prev = day
    return exp


def _iter(col):
    last = None
    while True:
        query = col.order_by("__name__").limit(400)
        if last is not None:
            query = query.start_after(last)
        docs = list(query.stream())
        if not docs:
            return
        for doc in docs:
            yield doc
        last = docs[-1]


def compute_all(db) -> dict[str, dict]:
    totals: dict[str, int] = defaultdict(int)
    breakdown: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))

    review_days: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    like_days: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    comment_days: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    post_days: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    follow_days: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    feedback_days: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))

    print("scanning reviews...")
    for doc in _iter(db.collection("reviews")):
        data = doc.to_dict() or {}
        uid = (data.get("userId") or data.get("authorId") or "").strip()
        day = _to_day(data.get("createdAt") or data.get("cookedAt"))
        if uid:
            amount = PHOTO_EXP if _has_photo(data) else TEXT_EXP
            if _grant(review_days[uid], day, 8):
                totals[uid] += amount
                breakdown[uid]["reviews"] += amount
            likes = int(data.get("likeCount") or 0)
            comments = int(data.get("commentCount") or 0)
            if likes >= 10:
                totals[uid] += LIKES_10
                breakdown[uid]["like_milestone"] += LIKES_10
            if likes >= 30:
                totals[uid] += LIKES_30
                breakdown[uid]["like_milestone"] += LIKES_30
            if comments >= 5:
                totals[uid] += COMMENTS_5
                breakdown[uid]["comment_milestone"] += COMMENTS_5
            if comments >= 15:
                totals[uid] += COMMENTS_15
                breakdown[uid]["comment_milestone"] += COMMENTS_15
        for liker in data.get("likedBy") or []:
            lid = str(liker).strip()
            if not lid or lid == uid:
                continue
            if _grant(like_days[lid], day, 15):
                totals[lid] += LIKE_EXP
                breakdown[lid]["likes"] += LIKE_EXP

    print("scanning board posts...")
    for doc in _iter(db.collection("board_posts")):
        data = doc.to_dict() or {}
        uid = (data.get("authorId") or "").strip()
        day = _to_day(data.get("createdAt"))
        body = (data.get("body") or "").strip()
        if uid:
            amount = POST_EXP if len(body) >= 20 else POST_SHORT_EXP
            if _grant(post_days[uid], day, 3):
                totals[uid] += amount
                breakdown[uid]["posts"] += amount
            likes = int(data.get("likeCount") or 0)
            comments = int(data.get("commentCount") or 0)
            if likes >= 10:
                totals[uid] += LIKES_10
                breakdown[uid]["like_milestone"] += LIKES_10
            if likes >= 30:
                totals[uid] += LIKES_30
                breakdown[uid]["like_milestone"] += LIKES_30
            if comments >= 5:
                totals[uid] += COMMENTS_5
                breakdown[uid]["comment_milestone"] += COMMENTS_5
            if comments >= 15:
                totals[uid] += COMMENTS_15
                breakdown[uid]["comment_milestone"] += COMMENTS_15
        for liker in data.get("likedBy") or []:
            lid = str(liker).strip()
            if not lid or lid == uid:
                continue
            if _grant(like_days[lid], day, 15):
                totals[lid] += LIKE_EXP
                breakdown[lid]["likes"] += LIKE_EXP

    print("scanning comments...")
    try:
        for doc in _iter(db.collection_group("comments")):
            data = doc.to_dict() or {}
            uid = (data.get("userId") or data.get("authorId") or "").strip()
            if not uid:
                continue
            text = (data.get("text") or "").strip()
            if len(text) < 5:
                continue
            day = _to_day(data.get("createdAt"))
            if _grant(comment_days[uid], day, 10):
                totals[uid] += COMMENT_EXP
                breakdown[uid]["comments"] += COMMENT_EXP
    except Exception as exc:
        print(f"comment scan skipped: {exc}")

    print("scanning follows...")
    for doc in _iter(db.collection("follows")):
        data = doc.to_dict() or {}
        uid = (data.get("followerId") or "").strip()
        if not uid:
            continue
        day = _to_day(data.get("createdAt"))
        if _grant(follow_days[uid], day, 5):
            totals[uid] += FOLLOW_EXP
            breakdown[uid]["follows"] += FOLLOW_EXP

    print("scanning feedback...")
    try:
        for doc in _iter(db.collection("app_feedback")):
            data = doc.to_dict() or {}
            uid = (data.get("userId") or "").strip()
            if not uid:
                continue
            written = f"{data.get('detail', '')}{data.get('liked', '')}{data.get('disliked', '')}"
            if len(written.strip()) < 8:
                continue
            day = _to_day(data.get("createdAt"))
            if _grant(feedback_days[uid], day, 2):
                totals[uid] += FEEDBACK_EXP
                breakdown[uid]["feedback"] += FEEDBACK_EXP
    except Exception as exc:
        print(f"feedback scan skipped: {exc}")

    print("scanning users...")
    users = {}
    for doc in _iter(db.collection("users")):
        data = doc.to_dict() or {}
        uid = doc.id
        email = (data.get("email") or "").strip().lower()
        users[uid] = data
        if email.endswith("@yorigo.app"):
            continue
        attendance = data.get("attendanceDays") or {}
        if isinstance(attendance, dict):
            days = {str(k) for k in attendance.keys() if str(k).count("-") == 2}
            attend_exp = len(days) * ATTEND_EXP
            streak_exp = _streak_bonus(days)
            totals[uid] += attend_exp + streak_exp
            breakdown[uid]["attendance"] += attend_exp
            breakdown[uid]["streak"] += streak_exp
        saved = data.get("savedRecipes") or []
        if isinstance(saved, list):
            save_exp = min(len(saved), 80) * SAVE_EXP
            totals[uid] += save_exp
            breakdown[uid]["saves"] += save_exp
        name = (data.get("name") or "").strip()
        handle = (data.get("handle") or "").strip()
        photo = (data.get("photoUrl") or "").strip()
        if name and handle and photo:
            totals[uid] += PROFILE_EXP
            breakdown[uid]["profile"] += PROFILE_EXP

    print("scanning meal plans...")
    meal_days: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    try:
        for meal in _iter(db.collection_group("mealPlans")):
            meal_data = meal.to_dict() or {}
            parent = meal.reference.parent.parent
            uid = parent.id if parent is not None else ""
            if not uid:
                continue
            date_key = str(meal_data.get("dateKey") or meal.id)
            meals = meal_data.get("meals") or {}
            count = 0
            if isinstance(meals, dict):
                for slot in meals.values():
                    if isinstance(slot, list):
                        count += len(slot)
                    elif slot:
                        count += 1
            for _ in range(count):
                if _grant(meal_days[uid], date_key, 5):
                    totals[uid] += MEAL_EXP
                    breakdown[uid]["meals"] += MEAL_EXP
    except Exception as exc:
        print(f"meal plan scan skipped: {exc}")

    result = {}
    for uid, amount in totals.items():
        data = users.get(uid) or {}
        email = (data.get("email") or "").strip().lower()
        if email.endswith("@yorigo.app"):
            continue
        result[uid] = {
            "computed": amount,
            "current": int(data.get("expTotal") or 0),
            "level": level_for_exp(amount),
            "name": str(data.get("name") or data.get("handle") or uid)
            .encode("ascii", "ignore")
            .decode()[:24]
            or uid[:8],
            "already": int(data.get("expBackfillVersion") or 0) >= BACKFILL_VERSION
            and int(data.get("expTotal") or 0) >= amount,
            "parts": dict(breakdown[uid]),
        }
    return result


def apply(db, rows: dict[str, dict]) -> int:
    written = 0
    batch = db.batch()
    pending = 0
    for uid, row in rows.items():
        if row["already"]:
            continue
        new_total = max(row["current"], row["computed"])
        if new_total <= 0:
            continue
        ref = db.collection("users").document(uid)
        batch.set(
            ref,
            {
                "expTotal": new_total,
                "level": level_for_exp(new_total),
                "expBackfillVersion": BACKFILL_VERSION,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        granted = max(0, new_total - row["current"])
        if granted > 0:
            batch.set(
                ref.collection("exp_ledger").document(f"exp_backfill_v{BACKFILL_VERSION}"),
                {
                    "action": "exp_backfill",
                    "amount": granted,
                    "track": "exp",
                    "status": "confirmed",
                    "sourceRef": f"v{BACKFILL_VERSION}",
                    "createdAt": firestore.SERVER_TIMESTAMP,
                },
            )
        pending += 1
        written += 1
        if pending >= 200:
            batch.commit()
            batch = db.batch()
            pending = 0
    if pending:
        batch.commit()
    return written


def recount_levels(db, write: bool) -> None:
    changed = 0
    batch = db.batch()
    pending = 0
    top = []
    for doc in _iter(db.collection("users")):
        data = doc.to_dict() or {}
        email = (data.get("email") or "").strip().lower()
        if email.endswith("@yorigo.app"):
            continue
        exp = int(data.get("expTotal") or 0)
        if exp <= 0:
            continue
        new_level = level_for_exp(exp)
        old_level = int(data.get("level") or 1)
        name = (
            str(data.get("name") or data.get("handle") or doc.id)
            .encode("ascii", "ignore")
            .decode()[:20]
            or doc.id[:8]
        )
        top.append((exp, new_level, old_level, name))
        if new_level == old_level:
            continue
        if write:
            batch.set(doc.reference, {"level": new_level}, merge=True)
            pending += 1
            changed += 1
            if pending >= 400:
                batch.commit()
                batch = db.batch()
                pending = 0
        else:
            changed += 1
    if write and pending:
        batch.commit()
    top.sort(reverse=True)
    print("top 10 after curve:")
    for exp, new_level, old_level, name in top[:10]:
        print(f"  {name:20} exp={exp:5} lv {old_level} -> {new_level}")
    print(f"{'updated' if write else 'would update'} {changed} users")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--levels-only", action="store_true")
    parser.add_argument(
        "--credentials",
        default="",
        help="firebase service account json. defaults to GOOGLE_APPLICATION_CREDENTIALS or backend/firebase-service-account.json",
    )
    args = parser.parse_args()
    db = _init(_resolve_cred(args.credentials or None))
    if args.levels_only:
        recount_levels(db, write=args.apply)
        return
    rows = compute_all(db)
    ranked = sorted(rows.values(), key=lambda r: r["computed"], reverse=True)
    pending = [
        row for row in rows.values()
        if not row["already"] and max(row["current"], row["computed"]) > 0
    ]
    print(f"users with computed exp: {len(rows)}")
    print(f"would update: {len(pending)} (already current: {len(rows) - len(pending)})")
    print("top 15:")
    for row in ranked[:15]:
        print(
            f"  {row['name']:24} computed={row['computed']:5} "
            f"lv={row['level']:2} current={row['current']:5} "
            f"{'skip' if row['already'] else 'update'}"
        )
    if not args.apply:
        print("dry-run only. pass --apply to write.")
        return
    count = apply(db, rows)
    print(f"updated {count} users")


if __name__ == "__main__":
    main()
