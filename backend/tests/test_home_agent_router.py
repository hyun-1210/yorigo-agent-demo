"""home_agent 라우터. 기본 꺼짐, 켜면 가드된 턴이 통과한다."""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.testclient import TestClient

from routers.home_agent import create_home_agent_router
from services.agent_flags import home_agent_enabled


def _client() -> TestClient:
    app = FastAPI()
    app.include_router(create_home_agent_router())
    return TestClient(app)


def test_flag_defaults_off(monkeypatch):
    monkeypatch.delenv("HOME_AGENT_ENABLED", raising=False)
    assert home_agent_enabled() is False


def test_turn_disabled_returns_503(monkeypatch):
    monkeypatch.delenv("HOME_AGENT_ENABLED", raising=False)
    res = _client().post("/home_agent/turn", json={"message": "김치찌개 추천해줘"})
    assert res.status_code == 503
    assert res.json()["detail"] == "Feature disabled"


def test_turn_enabled_rejects_missing_auth(monkeypatch):
    monkeypatch.setenv("HOME_AGENT_ENABLED", "true")
    res = _client().post("/home_agent/turn", json={"message": "김치찌개 추천해줘"})
    assert res.status_code == 401
