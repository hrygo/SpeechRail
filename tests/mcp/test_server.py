"""Registration/CLI tests for the speechrail-mcp MCPServer surface."""

from __future__ import annotations

from pathlib import Path

import pytest

from speechrail.mcp import server


def _run(coro):
    import asyncio

    return asyncio.run(coro)


def test_server_registers_the_nine_planned_tools() -> None:
    app = server.create_server()
    registered = _run(app.list_tools())
    names = {tool.name for tool in registered}
    assert names == {
        "describe",
        "transcribe",
        "synthesize",
        "preview_voice",
        "create_voice",
        "delete_voice",
        "create_job",
        "get_job",
        "cancel_job",
    }


def test_tool_schemas_never_leak_client_context() -> None:
    app = server.create_server()
    registered = _run(app.list_tools())
    by_name = {tool.name: tool for tool in registered}

    assert set(by_name["describe"].input_schema.get("properties", {})) == set()

    transcribe_props = set(by_name["transcribe"].input_schema.get("properties", {}))
    assert transcribe_props == {"audio_ref", "language", "diarize", "timestamps"}

    synthesize_props = set(by_name["synthesize"].input_schema.get("properties", {}))
    assert synthesize_props == {"text", "voice", "output_format", "speed"}

    preview_props = set(by_name["preview_voice"].input_schema.get("properties", {}))
    assert preview_props == {"instruction", "text"}

    create_voice_props = set(by_name["create_voice"].input_schema.get("properties", {}))
    assert create_voice_props == {"name", "instruction", "voice_id", "seed"}

    delete_voice_props = set(by_name["delete_voice"].input_schema.get("properties", {}))
    assert delete_voice_props == {"voice_id"}

    create_job_props = set(by_name["create_job"].input_schema.get("properties", {}))
    assert create_job_props == {"kind", "input_ref", "params"}

    for tool in registered:
        schema = tool.input_schema.get("properties", {})
        assert "client" not in schema
        assert "ctx" not in schema
        assert "context" not in schema
        assert tool.description


def test_tool_descriptions_teach_base64_and_describe_first() -> None:
    app = server.create_server()
    registered = _run(app.list_tools())
    descriptions = {tool.name: tool.description for tool in registered}
    assert "base64" in descriptions["transcribe"]
    assert "describe()" in descriptions["synthesize"]
    assert "quality" in descriptions["preview_voice"]


def test_main_rejects_unknown_transport(capsys: pytest.CaptureFixture[str]) -> None:
    assert server.main(["--transport", "carrier-pigeon"]) == 2
    captured = capsys.readouterr()
    assert "unsupported transport" in captured.err


def test_main_prints_help_without_running(capsys: pytest.CaptureFixture[str]) -> None:
    assert server.main(["--help"]) == 0
    captured = capsys.readouterr()
    assert "usage: speechrail-mcp" in captured.out


def test_resolve_api_key_prefers_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SPEECHRAIL_API_KEY", "env-key")
    assert server._resolve_api_key() == "env-key"


def test_resolve_api_key_falls_back_to_app_home(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("SPEECHRAIL_API_KEY", raising=False)
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / ".env").write_text('SPEECHRAIL_API_KEY="file-key"\n', encoding="utf-8")
    monkeypatch.setenv("SPEECHRAIL_APP_HOME", str(tmp_path))
    assert server._resolve_api_key() == "file-key"


def test_resolve_api_key_keyless_when_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("SPEECHRAIL_API_KEY", raising=False)
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / ".env").write_text("SPEECHRAIL_PORT=8201\n", encoding="utf-8")
    monkeypatch.setenv("SPEECHRAIL_APP_HOME", str(tmp_path))
    assert server._resolve_api_key() is None
