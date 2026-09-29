"""에이전트 플래그. 기본 꺼짐."""

from services.agent_flags import home_agent_enabled, recipe_agent_enabled


def test_recipe_agent_flag_off_by_default(monkeypatch):
    monkeypatch.delenv("RECIPE_AGENT_ENABLED", raising=False)
    assert recipe_agent_enabled() is False


def test_recipe_agent_flag_on(monkeypatch):
    monkeypatch.setenv("RECIPE_AGENT_ENABLED", "true")
    assert recipe_agent_enabled() is True


def test_home_agent_stays_off_during_recipe_qa(monkeypatch):
    monkeypatch.delenv("HOME_AGENT_ENABLED", raising=False)
    monkeypatch.setenv("RECIPE_AGENT_ENABLED", "true")
    assert home_agent_enabled() is False
