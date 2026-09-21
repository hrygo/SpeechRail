from __future__ import annotations

from pathlib import Path

import pytest

from speechrail import agents


def test_agent_install_status_update_and_safe_uninstall(tmp_path: Path) -> None:
    skills_dir = tmp_path / "skills"
    config_path = tmp_path / "config.toml"
    first = agents.install(
        skills_dir=skills_dir,
        config_path=config_path,
    )
    assert first["status"] == "installed"
    assert first["client_discovery"] == "configured"
    assert first["packaged"] == "available"
    assert first["client_configured"] == "configured"
    assert first["client_discovered"] == "unknown"
    assert first["session_activated"] == "unknown"
    assert (skills_dir / "speechrail" / "SKILL.md").is_file()
    assert "mcp_servers.speechrail" in config_path.read_text(encoding="utf-8")

    status = agents.status(skills_dir=skills_dir, config_path=config_path)
    assert status["status"] == "installed"
    assert status["client_discovered"] == "unknown"
    unchanged = agents.install(skills_dir=skills_dir, config_path=config_path)
    assert unchanged["status"] == "unchanged"

    managed = skills_dir / "speechrail" / "SKILL.md"
    managed.write_text("user edit", encoding="utf-8")
    with pytest.raises(agents.AgentIntegrationError, match="skill file conflict"):
        agents.install(skills_dir=skills_dir, config_path=config_path)
    drifted = agents.status(skills_dir=skills_dir, config_path=config_path)
    assert drifted["status"] == "drifted"

    removed = agents.uninstall(skills_dir=skills_dir, config_path=config_path)
    assert removed["status"] == "drifted"
    assert managed.read_text(encoding="utf-8") == "user edit"
    assert (skills_dir / agents._RECEIPT_NAME).is_file()
    assert agents.status(skills_dir=skills_dir, config_path=config_path)["status"] == "drifted"


def test_agent_status_without_receipt_is_not_installed(tmp_path: Path) -> None:
    result = agents.status(skills_dir=tmp_path / "skills", config_path=tmp_path / "config.toml")
    assert result["status"] == "not_installed"


def test_agent_install_does_not_overwrite_unmanaged_mcp_config(tmp_path: Path) -> None:
    config_path = tmp_path / "config.toml"
    config_path.write_text(
        '[mcp_servers.speechrail]\ncommand = "/user/owned/speechrail-mcp"\n',
        encoding="utf-8",
    )

    with pytest.raises(agents.AgentIntegrationError, match="MCP config conflict"):
        agents.install(skills_dir=tmp_path / "skills", config_path=config_path)

    assert "/user/owned/speechrail-mcp" in config_path.read_text(encoding="utf-8")
