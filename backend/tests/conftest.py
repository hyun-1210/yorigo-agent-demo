"""QA용 가벼운 import. services/routers 패키지 __init__ 의 무거운 의존을 건너뛴다."""

from __future__ import annotations

import sys
import types
from pathlib import Path

_BACKEND = Path(__file__).resolve().parents[1]


def _namespace(name: str, path: Path) -> None:
    if name in sys.modules:
        return
    pkg = types.ModuleType(name)
    pkg.__path__ = [str(path)]
    pkg.__file__ = str(path / "__init__.py")
    sys.modules[name] = pkg


_namespace("services", _BACKEND / "services")
_namespace("routers", _BACKEND / "routers")
_namespace("utils", _BACKEND / "utils")
