"""쿠팡 주문 subparam → uid 매칭."""

from __future__ import annotations

import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import importlib.util

_SPEC = importlib.util.spec_from_file_location(
    "coupang_order_attribution_under_test",
    BACKEND_DIR / "services" / "coupang_order_attribution_service.py",
)
_mod = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
sys.modules[_SPEC.name] = _mod
_SPEC.loader.exec_module(_mod)
CoupangOrderAttributionService = _mod.CoupangOrderAttributionService
attributed_order_doc_id = _mod.attributed_order_doc_id
is_yorigo_subparam = _mod.is_yorigo_subparam
lookback_date_range = _mod.lookback_date_range
row_to_api_item = _mod.row_to_api_item


class _Snap:
    def __init__(self, doc_id: str, data: dict):
        self.id = doc_id
        self._data = data

    def to_dict(self) -> dict:
        return dict(self._data)


class _Query:
    def __init__(self, matches: list[_Snap]):
        self._matches = matches

    def limit(self, _n: int) -> "_Query":
        return self

    def order_by(self, *_args, **_kwargs) -> "_Query":
        return self

    def stream(self):
        return iter(self._matches)


class _Ref:
    def __init__(self, db: "FakeDb", path: str):
        self.db = db
        self.path = path

    def collection(self, name: str) -> "FakeCol":
        return FakeCol(self.db, f"{self.path}/{name}")

    def set(self, data: dict, merge: bool = True) -> None:
        current = self.db.store.get(self.path, {})
        if merge:
            merged = dict(current)
            merged.update(data)
            self.db.store[self.path] = merged
        else:
            self.db.store[self.path] = dict(data)


class FakeCol:
    def __init__(self, db: "FakeDb", path: str):
        self.db = db
        self.path = path

    def document(self, doc_id: str) -> _Ref:
        return _Ref(self.db, f"{self.path}/{doc_id}")

    def where(self, field: str, op: str, value: object) -> _Query:
        prefix = f"{self.path}/"
        matches: list[_Snap] = []
        depth = self.path.count("/") + 1
        for key, data in self.db.store.items():
            if not key.startswith(prefix):
                continue
            if key.count("/") != depth:
                continue
            if op == "==" and data.get(field) == value:
                matches.append(_Snap(key.rsplit("/", 1)[-1], data))
        return _Query(matches)

    def order_by(self, *_args, **_kwargs) -> _Query:
        prefix = f"{self.path}/"
        depth = self.path.count("/") + 1
        matches = [
            _Snap(key.rsplit("/", 1)[-1], data)
            for key, data in self.db.store.items()
            if key.startswith(prefix) and key.count("/") == depth
        ]
        return _Query(matches)


class FakeDb:
    def __init__(self) -> None:
        self.store: dict[str, dict] = {}

    def collection(self, name: str) -> FakeCol:
        return FakeCol(self, name)


def test_yorigo_subparam_shape():
    assert is_yorigo_subparam("yr_abc123XYZ012") is True
    assert is_yorigo_subparam("firebaseUidTooLongValue") is False
    assert is_yorigo_subparam("") is False


def test_lookback_window_is_inclusive():
    from datetime import datetime, timezone

    start, end = lookback_date_range(
        3, now=datetime(2026, 9, 10, tzinfo=timezone.utc)
    )
    assert start == "20260908"
    assert end == "20260910"


def test_sync_matches_user_by_subparam():
    db = FakeDb()
    db.store["users/u1"] = {"coupangSubparam": "yr_trackToken12"}
    reports = {
        "reports/orders": [
            [
                {
                    "date": "20260910",
                    "orderId": 99,
                    "productId": 7,
                    "productName": "계란",
                    "gmv": 3000,
                    "commission": 90,
                    "subParam": "yr_trackToken12",
                }
            ]
        ],
        "reports/ads/orders": [[]],
        "reports/cancels": [[]],
    }

    def fetch(path: str, _start: str, _end: str, page: int):
        pages = reports.get(path, [[]])
        if page >= len(pages):
            return []
        return pages[page]

    service = CoupangOrderAttributionService(
        db,
        access_key="ak",
        secret_key="sk",
        report_fetcher=fetch,
    )
    stats = service.sync_recent_window(lookback_days=1)
    assert stats.fetched == 1
    assert stats.matched == 1
    assert stats.unmatched == 0
    doc = db.store["coupang_attributed_orders/20260910_99_7"]
    assert doc["uid"] == "u1"
    assert doc["matchStatus"] == "matched"
    assert db.store["users/u1/coupang_orders/20260910_99_7"]["uid"] == "u1"


def test_sync_keeps_unmatched_and_no_subparam():
    db = FakeDb()
    reports = {
        "reports/orders": [
            [
                {
                    "date": "20260910",
                    "orderId": 1,
                    "productId": 1,
                    "subParam": "yr_unknownToken1",
                },
                {
                    "date": "20260910",
                    "orderId": 2,
                    "productId": 2,
                },
            ]
        ],
        "reports/ads/orders": [[]],
        "reports/cancels": [[]],
    }

    def fetch(path: str, _start: str, _end: str, page: int):
        pages = reports.get(path, [[]])
        return pages[page] if page < len(pages) else []

    service = CoupangOrderAttributionService(
        db,
        access_key="ak",
        secret_key="sk",
        report_fetcher=fetch,
    )
    stats = service.sync_recent_window(lookback_days=1)
    assert stats.unmatched == 1
    assert stats.no_subparam == 1
    assert db.store["coupang_attributed_orders/20260910_1_1"]["uid"] is None
    assert db.store["coupang_attributed_orders/20260910_2_2"]["matchStatus"] == "no_subparam"


def test_cancel_marks_existing_shape():
    row = {
        "date": "20260910",
        "orderId": 3,
        "productId": 8,
    }
    assert attributed_order_doc_id(row) == "20260910_3_8"
    item = row_to_api_item(
        {
            "orderId": "3",
            "matchStatus": "matched",
            "cancelled": True,
            "uid": "u1",
        }
    )
    assert item["cancelled"] is True
    assert item["match_status"] == "matched"
    assert item["order_id"] == "3"


if __name__ == "__main__":
    test_yorigo_subparam_shape()
    test_lookback_window_is_inclusive()
    test_sync_matches_user_by_subparam()
    test_sync_keeps_unmatched_and_no_subparam()
    test_cancel_marks_existing_shape()
    print("ok")
