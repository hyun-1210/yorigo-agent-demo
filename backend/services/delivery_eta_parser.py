"""
배송 도착일 정규화: scraped_at 기준으로 delivery_text_raw를 해석해
수집 시점에서 며칠 후 도착인지( delivery_eta_days )를 계산합니다.
오늘(today)은 사용하지 않으며, scraped_at과 도착 예정일만 사용합니다.
"""
import re
from datetime import date, timedelta
from typing import Optional


def compute_delivery_eta_days(
    delivery_text_raw: Optional[str],
    scraped_at_date: Optional[date],
) -> Optional[int]:
    """
    수집 시점(scraped_at_date) 기준으로 도착 예정일까지 며칠인지 계산합니다.
    도착 예정일 < scraped_at_date 이면 None 반환.

    Args:
        delivery_text_raw: 스크래핑한 도착 문구 (예: "내일(금) 도착 예정", "2/24(화) 도착 예정")
        scraped_at_date: 문구를 수집한 날짜 (기준일)

    Returns:
        수집 시점에서 도착일까지 일수 (0=당일, 1=다음날, ...). 파싱 실패 또는 과거 도착일이면 None.
    """
    if not delivery_text_raw or not isinstance(delivery_text_raw, str):
        return None
    text = delivery_text_raw.strip()
    if not text or not scraped_at_date:
        return None

    arrival_date: Optional[date] = _parse_arrival_date(text, scraped_at_date)
    if arrival_date is None:
        return None
    if arrival_date < scraped_at_date:
        return None

    delta = (arrival_date - scraped_at_date).days
    return delta


def _parse_arrival_date(text: str, scraped_at_date: date) -> Optional[date]:
    """delivery_text_raw를 scraped_at_date 기준으로 해석해 도착일(date) 반환."""
    text_lower = text.replace(" ", "").replace("\t", "")
    year = scraped_at_date.year

    # "오늘" -> 보수적으로 다음 날(내일)로 처리
    if "오늘" in text:
        return scraped_at_date + timedelta(days=1)
    if "내일" in text:
        return scraped_at_date + timedelta(days=1)
    if "모레" in text:
        return scraped_at_date + timedelta(days=2)

    # M/d(요일) 또는 M/d 형태 (예: 2/24(화), 2/24)
    m = re.search(r"(\d{1,2})/(\d{1,2})(?:\([월화수목금토일]\))?", text_lower)
    if m:
        try:
            month, day = int(m.group(1)), int(m.group(2))
            candidate = date(year, month, day)
            # 연도 넘어감 보정: 예) 12/말에 수집, 1/초 도착 문구가 나오면
            # scraped_at_date 기준으로는 과거가 되어 None이 될 수 있으므로 다음 해로 보정.
            # "연도 넘어감" 케이스만 보정:
            # - scraped가 예: 12월 말인데 도착 문구가 1월로 나오는 경우
            # - 같은 달(월이 동일)에서 단순히 과거 날짜면 그대로 None 처리하는 게 보수적
            if candidate < scraped_at_date and candidate.month < scraped_at_date.month:
                candidate = date(year + 1, month, day)
            return candidate
        except ValueError:
            pass

    # M월 d일
    m = re.search(r"(\d{1,2})월\s*(\d{1,2})일", text_lower)
    if m:
        try:
            month, day = int(m.group(1)), int(m.group(2))
            candidate = date(year, month, day)
            # 연도 넘어감 보정 (month/day만 있는 경우 동일한 문제 발생)
            if candidate < scraped_at_date and candidate.month < scraped_at_date.month:
                candidate = date(year + 1, month, day)
            return candidate
        except ValueError:
            pass

    return None
