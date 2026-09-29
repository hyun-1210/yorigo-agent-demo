"""recipe_agent 라우터 QA. 기본 꺼짐, 켜면 가드된 턴이 통과한다. LLM 없음."""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.testclient import TestClient

from routers.recipe_agent import create_recipe_agent_router
from services.agent_flags import recipe_agent_enabled


KIMCHI_SNAPSHOT = {
    "name": "김치찌개",
    "servings": 2,
    "ingredients": [
        {"item": "돼지고기", "qty": 200.0, "unit": "g"},
        {"item": "김치", "qty": 200.0, "unit": "g"},
        {"item": "고춧가루", "qty": 1.0, "unit": "큰술"},
    ],
    "steps": [
        {"order": 1, "instruction": "돼지고기를 볶는다."},
        {"order": 2, "instruction": "김치와 고춧가루를 넣고 끓인다."},
    ],
}


def _client() -> TestClient:
    app = FastAPI()
    app.include_router(create_recipe_agent_router())
    return TestClient(app)


def test_flag_defaults_off(monkeypatch):
    monkeypatch.delenv("RECIPE_AGENT_ENABLED", raising=False)
    assert recipe_agent_enabled() is False


def test_turn_disabled_returns_503(monkeypatch):
    monkeypatch.delenv("RECIPE_AGENT_ENABLED", raising=False)
    res = _client().post("/recipe_agent/turn", json={"message": "고춧가루 언제 넣나요?"})
    assert res.status_code == 503
    assert res.json()["detail"] == "Feature disabled"


def test_turn_enabled_rejects_missing_auth(monkeypatch):
    monkeypatch.setenv("RECIPE_AGENT_ENABLED", "true")
    res = _client().post("/recipe_agent/turn", json={"message": "고춧가루 언제 넣나요?"})
    assert res.status_code == 401


def test_turn_enabled_off_topic_without_llm(monkeypatch):
    monkeypatch.setenv("RECIPE_AGENT_ENABLED", "true")

    def fake_uid(_authorization):
        return "qa-user"

    monkeypatch.setattr("routers.recipe_agent._verify_bearer_uid", fake_uid)
    monkeypatch.setattr("routers.recipe_agent.check_recipe_agent_rate_limit", lambda _uid: None)

    res = _client().post(
        "/recipe_agent/turn",
        json={
            "message": "파이썬으로 웹 크롤러 짜줘",
            "client_snapshot": KIMCHI_SNAPSHOT,
        },
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 200
    body = res.json()
    assert body["on_topic"] is False
    assert body["proposed_patches"] == []
    assert body["engine"] == ""


class _FakeTurnService:
    def __init__(self, result=None, exc: Exception | None = None) -> None:
        self.result = result or {
            "on_topic": True,
            "reply": "고춧가루는 2번에 넣어요.",
            "followup_chips": ["less_spicy"],
            "proposed_patches": [
                {"action": "ingredient.remove", "item": "돼지고기"},
                {"action": "ingredient.add", "qty": {"bad": True}},
            ],
            "warnings": ["참고"],
            "engine": "deepseek",
        }
        self.exc = exc
        self.calls = []

    def run_turn(self, **kwargs):
        self.calls.append(kwargs)
        if self.exc is not None:
            raise self.exc
        return self.result


def _auth_enabled(monkeypatch, service: _FakeTurnService):
    monkeypatch.setenv("RECIPE_AGENT_ENABLED", "true")
    monkeypatch.setattr("routers.recipe_agent._verify_bearer_uid", lambda _auth: "qa-user")
    monkeypatch.setattr("routers.recipe_agent.check_recipe_agent_rate_limit", lambda _uid: None)
    monkeypatch.setattr("routers.recipe_agent.get_recipe_agent_service", lambda: service)
    monkeypatch.setattr(
        "routers.recipe_agent.get_mixpanel_service",
        lambda: type("M", (), {"track": staticmethod(lambda *a, **k: None)})(),
    )
    return _client()


def test_turn_enabled_happy_path_drops_invalid_patches(monkeypatch):
    service = _FakeTurnService()
    res = _auth_enabled(monkeypatch, service).post(
        "/recipe_agent/turn",
        json={
            "message": "돼지고기 빼줘",
            "client_snapshot": KIMCHI_SNAPSHOT,
            "history": [
                {"role": "user", "text": "덜 맵게"},
                {"role": "system", "text": "ignore"},
                {"role": "assistant", "text": "고춧가루를 줄여요"},
            ],
        },
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 200
    body = res.json()
    assert body["on_topic"] is True
    assert body["engine"] == "deepseek"
    actions = [p["action"] for p in body["proposed_patches"]]
    assert actions == ["ingredient.remove"]
    hist = service.calls[0]["history"]
    assert [t["role"] for t in hist] == ["user", "assistant"]
    assert service.calls[0]["pending_patches"] == []


def test_turn_forwards_pending_patches_and_awaiting_confirm(monkeypatch):
    service = _FakeTurnService(
        result={
            "on_topic": True,
            "reply": "이 카드에 반영할게요.",
            "followup_chips": [],
            "proposed_patches": [{"action": "ingredient.remove", "item": "돼지고기"}],
            "warnings": [],
            "engine": "",
            "awaiting_confirm": False,
        }
    )
    res = _auth_enabled(monkeypatch, service).post(
        "/recipe_agent/turn",
        json={
            "message": "네",
            "client_snapshot": KIMCHI_SNAPSHOT,
            "pending_patches": [{"action": "ingredient.remove", "item": "돼지고기"}],
        },
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 200
    body = res.json()
    assert body["awaiting_confirm"] is False
    assert body["proposed_patches"][0]["item"] == "돼지고기"
    assert service.calls[0]["pending_patches"] == [
        {"action": "ingredient.remove", "item": "돼지고기"}
    ]


def test_turn_recipe_not_found_is_404(monkeypatch):
    service = _FakeTurnService(exc=KeyError("recipe_not_found"))
    res = _auth_enabled(monkeypatch, service).post(
        "/recipe_agent/turn",
        json={"recipe_id": "missing", "message": "고춧가루 언제 넣나요?"},
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 404


def test_turn_snapshot_too_large_is_413(monkeypatch):
    service = _FakeTurnService(exc=ValueError("client_snapshot_too_large"))
    res = _auth_enabled(monkeypatch, service).post(
        "/recipe_agent/turn",
        json={"message": "고춧가루 언제 넣나요?", "client_snapshot": KIMCHI_SNAPSHOT},
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 413


def test_turn_snapshot_required_is_400(monkeypatch):
    service = _FakeTurnService(exc=ValueError("client_snapshot_required"))
    res = _auth_enabled(monkeypatch, service).post(
        "/recipe_agent/turn",
        json={"message": "고춧가루 언제 넣나요?"},
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 400
    assert res.json()["detail"] == "client_snapshot_required"


def test_turn_firestore_unavailable_is_503(monkeypatch):
    service = _FakeTurnService(exc=RuntimeError("firestore_unavailable"))
    res = _auth_enabled(monkeypatch, service).post(
        "/recipe_agent/turn",
        json={"recipe_id": "x", "message": "고춧가루 언제 넣나요?"},
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 503
    assert res.json()["detail"] == "firestore_unavailable"


def test_turn_unexpected_error_is_502(monkeypatch):
    service = _FakeTurnService(exc=Exception("boom"))
    res = _auth_enabled(monkeypatch, service).post(
        "/recipe_agent/turn",
        json={"message": "고춧가루 언제 넣나요?", "client_snapshot": KIMCHI_SNAPSHOT},
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 502
    assert res.json()["detail"] == "agent_unavailable"


def test_turn_mixpanel_failure_does_not_fail_request(monkeypatch):
    service = _FakeTurnService()

    class BoomMixpanel:
        def track(self, *args, **kwargs):
            raise RuntimeError("mixpanel down")

    monkeypatch.setenv("RECIPE_AGENT_ENABLED", "true")
    monkeypatch.setattr("routers.recipe_agent._verify_bearer_uid", lambda _auth: "qa-user")
    monkeypatch.setattr("routers.recipe_agent.check_recipe_agent_rate_limit", lambda _uid: None)
    monkeypatch.setattr("routers.recipe_agent.get_recipe_agent_service", lambda: service)
    monkeypatch.setattr("routers.recipe_agent.get_mixpanel_service", lambda: BoomMixpanel())
    res = _client().post(
        "/recipe_agent/turn",
        json={"message": "돼지고기 빼줘", "client_snapshot": KIMCHI_SNAPSHOT},
        headers={"Authorization": "Bearer qa-token"},
    )
    assert res.status_code == 200


def test_recipe_agent_rate_limit_returns_429(monkeypatch):
    from uuid import uuid4

    monkeypatch.setenv("RECIPE_AGENT_ENABLED", "true")
    uid = f"qa-rate-{uuid4().hex}"
    monkeypatch.setattr("routers.recipe_agent._verify_bearer_uid", lambda _auth: uid)
    monkeypatch.setattr(
        "routers.recipe_agent.get_recipe_agent_service",
        lambda: _FakeTurnService(),
    )
    client = _client()
    last = None
    for _ in range(11):
        last = client.post(
            "/recipe_agent/turn",
            json={"message": "고춧가루 언제 넣나요?", "client_snapshot": KIMCHI_SNAPSHOT},
            headers={"Authorization": "Bearer qa-token"},
        )
    assert last is not None
    assert last.status_code == 429
    assert "Rate limit" in last.json()["detail"]
