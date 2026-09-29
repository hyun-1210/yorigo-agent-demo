import json
from typing import Any, Optional

from seed_data import poster_seeds
from schemas import assert_exposure_caps, normalize_poster, normalize_section


def test_normalize_seed_posters() -> None:
    posters = [normalize_poster(p, p["id"]) for p in poster_seeds()]
    assert len(posters) == 3
    assert posters[0]["chips"][0]["sectionKey"] == "poster_summer_all"


def test_normalize_section_rejects_bad_kind() -> None:
    try:
        normalize_section({"label": "x", "kind": "nope"}, "dessert")
        raise AssertionError("expected ValueError")
    except ValueError:
        pass


def test_exposure_caps() -> None:
    posters = [{"enabled": True} for _ in range(3)]
    sections = [
        {"enabled": True, "kind": "trend"} for _ in range(4)
    ]
    assert_exposure_caps(posters, sections)


if __name__ == "__main__":
    test_normalize_seed_posters()
    test_normalize_section_rejects_bad_kind()
    test_exposure_caps()
    print("ok")

