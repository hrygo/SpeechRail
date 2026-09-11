"""Registration/CLI tests for the speechrail-mcp MCPServer surface."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import httpx
import pytest
from mcp.client import Client
from mcp.server.context import ServerRequestContext
from mcp.types import CallToolRequestParams, TextContent

import speechrail
from speechrail.mcp import server
from speechrail.mcp.client import SpeechRailClient
from speechrail.mcp.models import DescribeResult, TranscribeResult, VoiceRecord

# Per-tool (title, read_only_hint, destructive_hint, idempotent_hint) contract.
_TOOL_ANNOTATIONS: dict[str, tuple[str, bool, bool, bool]] = {
    "describe": ("Current capability snapshot", True, False, True),
    "transcribe": ("Transcribe audio", True, False, True),
    "synthesize": ("Synthesize speech to a file", False, False, False),
    "preview_voice": ("Audition a voice instruction", False, False, False),
    "create_voice": ("Create a persistent voice", False, False, False),
    "delete_voice": ("Delete a voice", False, True, True),
    "create_job": ("Create a durable job", False, False, False),
    "get_job": ("Get a job record", True, False, True),
    "cancel_job": ("Cancel a job", False, True, True),
}

# Each tool's published outputSchema must expose these known model keys.
_TOOL_OUTPUT_KEYS: dict[str, set[str]] = {
    "describe": {"tier", "readiness", "realtime", "jobs", "models", "voices"},
    "transcribe": {"text", "segments", "words", "language", "duration"},
    "synthesize": {"audio_path", "content_type", "output_format", "bytes"},
    "preview_voice": {"audio_path", "content_type", "output_format", "bytes"},
    "create_voice": {"id", "name", "mode", "available", "capabilities"},
    "delete_voice": {"id", "name", "mode", "available", "capabilities"},
    "create_job": {"id", "kind", "state", "result_ref", "params"},
    "get_job": {"id", "kind", "state", "result_ref", "params"},
    "cancel_job": {"id", "kind", "state", "result_ref", "params"},
}

# Each tool's required input set must survive Annotated descriptions and ctx.
_TOOL_REQUIRED: dict[str, list[str]] = {
    "describe": [],
    "transcribe": ["audio_ref"],
    "synthesize": ["text"],
    "preview_voice": ["instruction", "text"],
    "create_voice": ["name", "instruction"],
    "delete_voice": ["voice_id"],
    "create_job": ["kind", "input_ref"],
    "get_job": ["job_id"],
    "cancel_job": ["job_id"],
}


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


def test_streamable_http_defaults_to_loopback_8202(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SPEECHRAIL_MCP_HOST", raising=False)
    monkeypatch.delenv("SPEECHRAIL_MCP_PORT", raising=False)
    assert server._host_from_env() == "127.0.0.1"
    assert server._port_from_env() == 8202


def test_mcp_host_and_port_are_env_overridable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SPEECHRAIL_MCP_HOST", "0.0.0.0")
    monkeypatch.setenv("SPEECHRAIL_MCP_PORT", "9200")
    assert server._host_from_env() == "0.0.0.0"
    assert server._port_from_env() == 9200


def test_invalid_mcp_port_falls_back_to_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SPEECHRAIL_MCP_PORT", "not-a-port")
    assert server._port_from_env() == 8202
    monkeypatch.setenv("SPEECHRAIL_MCP_PORT", "70000")
    assert server._port_from_env() == 8202


def _capturing_server(recorded: dict[str, Any]) -> Any:
    class _Spy:
        def run(self, **kwargs: Any) -> None:
            recorded.update(kwargs)

    return _Spy()


def test_main_streamable_http_binds_configured_host_and_port(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    recorded: dict[str, Any] = {}
    monkeypatch.setattr(server, "create_server", lambda: _capturing_server(recorded))
    monkeypatch.delenv("SPEECHRAIL_MCP_HOST", raising=False)
    monkeypatch.delenv("SPEECHRAIL_MCP_PORT", raising=False)
    assert server.main(["--transport", "streamable-http", "--port", "9001"]) == 0
    assert recorded == {"transport": "streamable-http", "host": "127.0.0.1", "port": 9001}


def test_main_stdio_does_not_bind_a_port(monkeypatch: pytest.MonkeyPatch) -> None:
    recorded: dict[str, Any] = {}
    monkeypatch.setattr(server, "create_server", lambda: _capturing_server(recorded))
    assert server.main([]) == 0
    assert recorded == {"transport": "stdio"}


def test_main_rejects_invalid_port(capsys: pytest.CaptureFixture[str]) -> None:
    assert server.main(["--transport", "streamable-http", "--port", "abc"]) == 2
    captured = capsys.readouterr()
    assert "invalid port" in captured.err


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


def _tools_by_name() -> dict[str, Any]:
    app = server.create_server()
    return {tool.name: tool for tool in _run(app.list_tools())}


def test_server_info_exposes_name_title_and_version() -> None:
    app = server.create_server()
    assert app.name == "speechrail-mcp"
    assert app.title == "SpeechRail"
    assert app.description
    assert app.version == speechrail.__version__
    assert app.version
    assert app.instructions == server._INSTRUCTIONS


def test_every_tool_has_title_and_expected_annotations() -> None:
    by_name = _tools_by_name()
    assert set(by_name) == set(_TOOL_ANNOTATIONS)

    for name, (title, read_only, destructive, idempotent) in _TOOL_ANNOTATIONS.items():
        tool = by_name[name]
        assert tool.title == title, name
        annotations = tool.annotations
        assert annotations is not None, name
        assert annotations.title == title, name
        assert annotations.read_only_hint is read_only, name
        assert annotations.destructive_hint is destructive, name
        assert annotations.idempotent_hint is idempotent, name
        assert annotations.open_world_hint is False, name


def test_delete_voice_and_cancel_job_are_destructive() -> None:
    by_name = _tools_by_name()
    assert by_name["delete_voice"].annotations.destructive_hint is True
    assert by_name["cancel_job"].annotations.destructive_hint is True


def test_every_tool_publishes_concrete_output_schema() -> None:
    by_name = _tools_by_name()

    for name, expected_keys in _TOOL_OUTPUT_KEYS.items():
        schema = by_name[name].output_schema
        assert schema is not None, name
        assert schema.get("type") == "object", name
        assert schema.get("additionalProperties") is True, name
        properties = schema.get("properties", {})
        assert properties, f"{name} has no properties"
        assert expected_keys <= set(properties), name


def test_tool_parameters_carry_descriptions() -> None:
    by_name = _tools_by_name()

    for tool in by_name.values():
        for param, schema in tool.input_schema.get("properties", {}).items():
            assert schema.get("description"), f"{tool.name}.{param}"


def test_tool_required_parameters_are_preserved() -> None:
    by_name = _tools_by_name()

    for name, expected in _TOOL_REQUIRED.items():
        required = by_name[name].input_schema.get("required", [])
        assert sorted(required) == sorted(expected), name


def test_transcribe_error_flows_through_injected_context() -> None:
    class FakeSession:
        def __init__(self) -> None:
            self.calls: list[tuple[float, float | None, str | None]] = []

        async def report_progress(
            self, progress: float, total: float | None = None, message: str | None = None
        ) -> None:
            self.calls.append((progress, total, message))

    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError(f"unexpected HTTP {request.method} {request.url.path}")

    client = SpeechRailClient(
        base_url="http://rail.test/v1", transport=httpx.MockTransport(handler)
    )
    app = server.create_server(client=client)
    session = FakeSession()
    request_context = ServerRequestContext(
        session=session,
        lifespan_context=None,
        protocol_version="2025-11-25",
        method="tools/call",
    )

    result = _run(
        app._handle_call_tool(
            request_context,
            CallToolRequestParams(
                name="transcribe",
                arguments={"audio_ref": "data:audio/wav;base64,AAAA"},
            ),
        )
    )

    assert result.is_error is True
    text = result.content[0].text
    assert "base64_not_supported" in text
    assert session.calls == [(0.0, 1.0, "started")]


def test_context_is_injected_but_absent_from_input_schema() -> None:
    app = server.create_server()
    by_name = {tool.name: tool for tool in _run(app.list_tools())}
    internal = {tool.name: tool for tool in app._tool_manager.list_tools()}

    for name in ("transcribe", "synthesize", "get_job"):
        assert "ctx" not in by_name[name].input_schema.get("properties", {})
        assert internal[name].context_kwarg == "ctx"

    for name in ("describe", "create_job", "cancel_job", "delete_voice"):
        assert internal[name].context_kwarg is None


def test_cache_hints_cover_list_methods_only() -> None:
    app = server.create_server()
    hints = app._lowlevel_server.cache_hints

    assert hints["tools/list"].ttl_ms == 300_000
    assert hints["tools/list"].scope == "public"
    assert hints["prompts/list"].ttl_ms == 300_000
    assert hints["prompts/list"].scope == "public"
    assert hints["resources/list"].ttl_ms == 300_000
    assert hints["resources/list"].scope == "public"
    # The three resource URIs are static metadata, but resource CONTENT is
    # dynamic (profile-dependent), so resources/read must stay uncached.
    assert "resources/read" not in hints


def test_transcribe_result_tolerates_unknown_and_partial_payloads() -> None:
    result = TranscribeResult.model_validate(
        {"text": "hello", "usage": {"seconds": 1.5}, "unexpected": {"a": 1}}
    )

    assert result.text == "hello"
    assert result.segments is None
    assert result.words is None
    dumped = result.model_dump()
    assert dumped["usage"] == {"seconds": 1.5}
    assert dumped["unexpected"] == {"a": 1}


def test_describe_result_tolerates_unknown_and_partial_nested_payloads() -> None:
    result = DescribeResult.model_validate(
        {
            "tier": "quality",
            "readiness": {"asr": True, "diarization_extra": 3},
            "realtime": {},
            "jobs": {},
            "models": [{"id": "speechrail/qwen3-asr", "unexpected_field": 7}],
            "voices": [],
            "top_level_extra": "kept",
        }
    )

    assert result.tier == "quality"
    assert result.readiness.asr is True
    assert result.models[0].id == "speechrail/qwen3-asr"
    dumped = result.model_dump()
    assert dumped["top_level_extra"] == "kept"
    assert dumped["models"][0]["unexpected_field"] == 7
    assert dumped["readiness"]["diarization_extra"] == 3


def test_voice_record_accepts_fully_optional_payload() -> None:
    record = VoiceRecord.model_validate({"id": "custom_1", "future": True})

    assert record.id == "custom_1"
    assert record.name is None
    assert record.mode is None
    assert record.available is None
    assert record.model_dump()["future"] is True


def _quality_rest_handler(request: httpx.Request) -> httpx.Response:
    """Serve the three GETs ``describe`` reads for a quality-tier snapshot."""
    path = request.url.path
    if request.method == "GET" and path == "/v1/models":
        return httpx.Response(
            200,
            json={
                "object": "list",
                "data": [
                    {
                        "id": "speechrail/qwen3-asr",
                        "object": "model",
                        "profile": "quality",
                        "family": "qwen3_asr",
                        "variant": "asr",
                    },
                    {
                        "id": "speechrail/qwen3-tts",
                        "object": "model",
                        "profile": "quality",
                        "family": "qwen3_tts",
                        "variant": "voice_design",
                    },
                ],
            },
        )
    if request.method == "GET" and path == "/v1/voices":
        return httpx.Response(
            200,
            json={
                "object": "list",
                "data": [
                    {
                        "id": "serena",
                        "name": "serena",
                        "mode": "system",
                        "available": True,
                        "variant": "voice_design",
                    }
                ],
            },
        )
    if request.method == "GET" and path == "/health":
        return httpx.Response(
            200,
            json={
                "status": "ok",
                "profile": "quality",
                "asr_ready": True,
                "tts_ready": True,
                "diarization_ready": True,
            },
        )
    raise AssertionError(f"unexpected HTTP {request.method} {path}")


def test_describe_success_returns_structured_content() -> None:
    """A successful tools/call returns is_error=False, a tier dict and text."""
    client = SpeechRailClient(
        base_url="http://rail.test/v1",
        transport=httpx.MockTransport(_quality_rest_handler),
    )
    app = server.create_server(client=client)
    request_context = ServerRequestContext(
        session=None,
        lifespan_context=None,
        protocol_version="2026-07-28",
        method="tools/call",
    )

    result = _run(
        app._handle_call_tool(
            request_context,
            CallToolRequestParams(name="describe", arguments={}),
        )
    )

    assert result.is_error is False
    assert isinstance(result.structured_content, dict)
    assert result.structured_content["tier"] == "quality"
    assert isinstance(result.content[0], TextContent)


def test_transcribe_success_reports_started_and_done_progress(tmp_path: Path) -> None:
    """A successful transcribe reports both progress edges and the transcript."""
    audio_path = tmp_path / "sample.wav"
    audio_path.write_bytes(
        b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00"
        b"\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00"
        b"\x02\x00\x10\x00data\x00\x00\x00\x00"
    )
    recorded: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        recorded.append(request)
        if request.method == "POST" and request.url.path == "/v1/audio/transcriptions":
            return httpx.Response(200, json={"text": "hello"})
        raise AssertionError(f"unexpected HTTP {request.method} {request.url.path}")

    class FakeSession:
        def __init__(self) -> None:
            self.calls: list[tuple[float, float | None, str | None]] = []

        async def report_progress(
            self, progress: float, total: float | None = None, message: str | None = None
        ) -> None:
            self.calls.append((progress, total, message))

    client = SpeechRailClient(
        base_url="http://rail.test/v1", transport=httpx.MockTransport(handler)
    )
    app = server.create_server(client=client)
    session = FakeSession()
    request_context = ServerRequestContext(
        session=session,
        lifespan_context=None,
        protocol_version="2026-07-28",
        method="tools/call",
    )

    result = _run(
        app._handle_call_tool(
            request_context,
            CallToolRequestParams(
                name="transcribe", arguments={"audio_ref": str(audio_path)}
            ),
        )
    )

    assert result.is_error is False
    assert session.calls == [(0.0, 1.0, "started"), (1.0, 1.0, "done")]
    assert [(request.method, request.url.path) for request in recorded] == [
        ("POST", "/v1/audio/transcriptions")
    ]
    assert isinstance(result.structured_content, dict)
    assert result.structured_content["text"] == "hello"


def test_cache_hints_are_emitted_per_protocol_era() -> None:
    """The 2026 era advertises public cache hints; legacy stays uncached/private."""

    async def probe(mode: str) -> tuple[str | None, tuple[int, str], tuple[int, str]]:
        app = server.create_server()
        async with Client(app, mode=mode) as client:
            tools = await client.list_tools(cache_mode="bypass")
            resources = await client.list_resources(cache_mode="bypass")
            return (
                client.session.protocol_version,
                (tools.ttl_ms, tools.cache_scope),
                (resources.ttl_ms, resources.cache_scope),
            )

    modern = _run(probe("2026-07-28"))
    assert modern == ("2026-07-28", (300_000, "public"), (300_000, "public"))

    legacy = _run(probe("legacy"))
    assert legacy == ("2025-11-25", (0, "private"), (0, "private"))
