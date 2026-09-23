"""Behavior tests for the SpeechRail MCP tool logic.

Tools are exercised directly (async functions over a recording
``httpx.MockTransport``) so the proxy policy — describe merging, audio_ref
base64 rejection, active-capability enforcement, preview gates, error hints —
is verified without the MCP transport.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import httpx
import pytest

from speechrail.mcp import tools
from speechrail.mcp.client import SpeechRailError
from speechrail.mcp.tools import ToolCallError


def _ok(payload: Any, *, status: int = 200) -> httpx.Response:
    return httpx.Response(status_code=status, json=payload)


def _model(profile: str, variant: str) -> list[dict[str, Any]]:
    return [
        {
            "id": "speechrail/qwen3-asr",
            "object": "model",
            "owned_by": "speechrail",
            "created": 0,
            "profile": profile,
            "family": "qwen3_asr",
            "variant": "asr",
        },
        {
            "id": "speechrail/qwen3-tts",
            "object": "model",
            "owned_by": "speechrail",
            "created": 0,
            "profile": profile,
            "family": "qwen3_tts",
            "variant": variant,
            "capabilities": {
                "supports_preview": variant == "voice_design",
                "supports_clone": profile in {"quality", "extreme"},
                "supports_instruction": variant == "voice_design",
            },
        },
        {"id": "whisper-1", "object": "model", "resolves_to": "speechrail/qwen3-asr"},
        {"id": "tts-1", "object": "model", "resolves_to": "speechrail/qwen3-tts"},
    ]


def _voice(
    voice_id: str,
    *,
    mode: str,
    available: bool,
    variant: str,
    capabilities: dict[str, bool] | None = None,
    aliases: list[str] | None = None,
    is_default: bool = False,
) -> dict[str, Any]:
    return {
        "id": voice_id,
        "name": voice_id,
        "mode": mode,
        "available": available,
        "variant": variant,
        "is_default": is_default,
        "aliases": aliases or [],
        "capabilities": capabilities
        or {
            "supports_speaker": False,
            "supports_instruction": False,
            "supports_clone": False,
        },
    }


def _effective_capabilities(
    profile: str,
    variant: str,
    voices: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "schema_version": "effective_capabilities_v1",
        "snapshot_id": f"{profile}-{variant}",
        "profile": profile,
        "models": {
            "tts": {"variant": variant},
            "tts_clone": {"variant": "base"} if profile in {"quality", "extreme"} else {},
        },
        "voices": voices,
    }


def _base_handler(
    models: list[dict[str, Any]],
    voices: list[dict[str, Any]],
    health: dict[str, Any],
) -> Callable[[httpx.Request], httpx.Response]:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            variant = next(
                entry["variant"]
                for entry in models
                if entry.get("family") == "qwen3_tts"
            )
            return _ok(_effective_capabilities(health["profile"], variant, voices))
        if request.method == "GET" and request.url.path == "/v1/models":
            return _ok({"object": "list", "data": models})
        if request.method == "GET" and request.url.path == "/v1/voices":
            return _ok({"object": "list", "data": voices})
        if request.method == "GET" and request.url.path == "/health":
            return _ok(health)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    return handler


def _multipart_field(request: httpx.Request, name: str) -> str:
    token = f'name="{name}"'.encode()
    body = request.content
    start = body.index(token) + len(token)
    start = body.index(b"\r\n\r\n", start) + 4
    end = body.index(b"\r\n--", start)
    return body[start:end].decode("utf-8", "replace")


def _json_body(request: httpx.Request) -> dict[str, Any]:
    return json.loads(request.content)


def _write_wav(tmp_path: Path, name: str = "meeting.wav") -> Path:
    path = tmp_path / name
    path.write_bytes(b"RIFF-fake-wav-data")
    return path


# ---------------------------------------------------------------------------
# describe()
# ---------------------------------------------------------------------------


def test_describe_merges_models_voices_health_for_quality(
    make_client: Any, run_async: Any
) -> None:
    models = _model("quality", "voice_design")
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]
    health = {
        "status": "ok",
        "profile": "quality",
        "asr_ready": True,
        "tts_ready": True,
        "diarization_ready": True,
        "asr_state": "ready",
        "tts_state": "ready",
        "streaming_state": "ready",
        "tts_lifecycle": {
            "cooperative_cancel": True,
            "fallback_aborts": 2,
            "fallback_reloads": 1,
        },
        "realtime_vad": {
            "configured_engine": "auto",
            "resolved_engine": "silero",
            "speech_admission_enabled": True,
        },
    }
    client, requests = make_client(_base_handler(models, voices, health))

    snapshot = run_async(tools.describe(client))

    assert snapshot["tier"] == "quality"
    assert snapshot["profile"] == "quality"
    assert snapshot["diarization_ready"] is True
    assert snapshot["readiness"] == {"asr": True, "tts": True, "diarization": True}
    assert snapshot["tts_lifecycle"] == {
        "cooperative_cancel": True,
        "fallback_aborts": 2,
        "fallback_reloads": 1,
    }
    assert snapshot["realtime"]["vad"]["resolved_engine"] == "silero"
    assert snapshot["realtime"]["streaming_state"] == "ready"
    assert snapshot["realtime"]["orchestration"] == "caller"
    assert snapshot["realtime"]["server_llm"] is False
    assert snapshot["realtime"]["conversation_state"] is False
    assert snapshot["realtime"]["websocket_path"] == "/v1/realtime"
    assert snapshot["realtime"]["mcp_realtime"] is False
    assert snapshot["clone_supported"] is True
    assert snapshot["preview_supported"] is True
    assert snapshot["models"] == models
    assert snapshot["voices"][0]["id"] == "serena"
    assert "capabilities" not in snapshot["voices"][0]
    assert [request.url.path for request in requests] == [
        "/v1/models",
        "/health",
        "/v1/speechrail/capabilities",
    ]


def test_describe_derives_balanced_from_custom_voice_profile(
    make_client: Any, run_async: Any
) -> None:
    models = _model("balanced", "custom_voice")
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
    health = {"status": "ok", "profile": "balanced", "diarization_ready": False}
    client, _requests = make_client(_base_handler(models, voices, health))

    snapshot = run_async(tools.describe(client))

    assert snapshot["tier"] == "balanced"
    assert snapshot["profile"] == "balanced"
    assert snapshot["clone_supported"] is False
    assert snapshot["preview_supported"] is False
    assert snapshot["diarization_ready"] is False
    assert snapshot["tts_lifecycle"] is None


def test_describe_reports_extreme_profile_without_collapsing_it_to_quality(
    make_client: Any, run_async: Any
) -> None:
    models = _model("extreme", "voice_design")
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]
    health = {"status": "ok", "profile": "extreme", "diarization_ready": True}
    client, _requests = make_client(_base_handler(models, voices, health))

    snapshot = run_async(tools.describe(client))

    assert snapshot["tier"] == "extreme"
    assert snapshot["profile"] == "extreme"
    assert snapshot["profile_consistency"] == "consistent"
    assert snapshot["clone_supported"] is True
    assert snapshot["preview_supported"] is True


def test_describe_marks_conflicting_profile_sources_and_suppresses_capabilities(
    make_client: Any, run_async: Any
) -> None:
    models = _model("quality", "voice_design")
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]
    health = {"status": "ok", "profile": "extreme", "diarization_ready": True}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("extreme", "voice_design", voices))
        if request.url.path == "/v1/models":
            return _ok({"object": "list", "data": models})
        if request.url.path == "/v1/voices":
            return _ok({"object": "list", "data": voices})
        if request.url.path == "/health":
            return _ok(health)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, _requests = make_client(handler)

    snapshot = run_async(tools.describe(client))

    assert snapshot["profile"] is None
    assert snapshot["tier"] == "unknown"
    assert snapshot["profile_consistency"] == "inconsistent"
    assert snapshot["clone_supported"] is False
    assert snapshot["preview_supported"] is False
    assert snapshot["voices"][0]["available"] is False


def test_describe_does_not_infer_profile_from_voice_design_variant(
    make_client: Any, run_async: Any
) -> None:
    models = _model("quality", "voice_design")
    for entry in models:
        entry.pop("profile", None)
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]
    health = {"status": "ok", "diarization_ready": True}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/speechrail/capabilities":
            return _ok(
                _effective_capabilities("quality", "voice_design", voices)
                | {"profile": None}
            )
        if request.url.path == "/v1/models":
            return _ok({"object": "list", "data": models})
        if request.url.path == "/v1/voices":
            return _ok({"object": "list", "data": voices})
        if request.url.path == "/health":
            return _ok(health)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, _requests = make_client(handler)

    snapshot = run_async(tools.describe(client))

    assert snapshot["profile"] is None
    assert snapshot["tier"] == "unknown"
    assert snapshot["profile_consistency"] == "unknown"


# ---------------------------------------------------------------------------
# transcribe()
# ---------------------------------------------------------------------------


def test_transcribe_default_posts_json_format(
    make_client: Any, run_async: Any, tmp_path: Path
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/audio/transcriptions"
        assert _multipart_field(request, "response_format") == "json"
        assert _multipart_field(request, "file") == "RIFF-fake-wav-data"
        return _ok({"text": "你好世界", "usage": {"type": "duration", "seconds": 1.0}})

    client, requests = make_client(handler)
    audio = _write_wav(tmp_path)

    result = run_async(tools.transcribe(client, audio_ref=str(audio)))

    assert result["text"] == "你好世界"
    assert len(requests) == 1


def test_transcribe_timestamps_forces_verbose_json(
    make_client: Any, run_async: Any, tmp_path: Path
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert _multipart_field(request, "response_format") == "verbose_json"
        return _ok({"text": "hi", "segments": [{"start": 0.0, "end": 1.0, "text": "hi"}]})

    client, requests = make_client(handler)
    audio = _write_wav(tmp_path)

    result = run_async(tools.transcribe(client, audio_ref=str(audio), timestamps=True))

    assert result["segments"][0]["text"] == "hi"
    assert len(requests) == 1


def test_transcribe_diarize_preflights_health_then_posts_diarized_json(
    make_client: Any, run_async: Any, tmp_path: Path
) -> None:
    health = {"status": "ok", "profile": "quality", "diarization_ready": True}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/health":
            return _ok(health)
        if request.url.path == "/v1/audio/transcriptions":
            assert _multipart_field(request, "response_format") == "diarized_json"
            return _ok(
                {
                    "task": "transcribe",
                    "language": "zh",
                    "duration": 1.0,
                    "segments": [
                        {"speaker": "speaker_0", "start": 0.0, "end": 1.0, "text": "你好"}
                    ],
                }
            )
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    audio = _write_wav(tmp_path)

    result = run_async(tools.transcribe(client, audio_ref=str(audio), diarize=True))

    assert result["segments"][0]["speaker"] == "speaker_0"
    assert [request.url.path for request in requests] == [
        "/health",
        "/v1/audio/transcriptions",
    ]


def test_transcribe_diarize_rejected_when_not_ready(
    make_client: Any, run_async: Any, tmp_path: Path
) -> None:
    health = {"status": "ok", "profile": "balanced", "diarization_ready": False}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/health":
            return _ok(health)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    audio = _write_wav(tmp_path)

    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.transcribe(client, audio_ref=str(audio), diarize=True))
    assert excinfo.value.code == "diarization_not_available"
    assert "uv sync --extra diarization" in excinfo.value.message
    assert [request.url.path for request in requests] == ["/health"]


def test_transcribe_rejects_base64_data_uri(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(
            tools.transcribe(
                client,
                audio_ref="data:audio/wav;base64,QUFBQUFBQUFBQUFBQUFBQUFBQUFB",
            )
        )
    assert excinfo.value.code == "base64_not_supported"
    assert requests == []


def test_transcribe_rejects_bare_inline_base64(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.transcribe(client, audio_ref="A" * 100))
    assert excinfo.value.code == "base64_not_supported"
    assert requests == []


def test_transcribe_missing_file_is_structured_failure(
    make_client: Any, run_async: Any, tmp_path: Path
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    missing = tmp_path / "nope.wav"
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.transcribe(client, audio_ref=str(missing)))
    assert excinfo.value.code == "audio_ref_not_found"
    assert requests == []


def test_transcribe_rejects_remote_url(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.transcribe(client, audio_ref="https://example.com/a.wav"))
    assert excinfo.value.code == "remote_audio_unsupported"
    assert requests == []


def test_transcribe_accepts_file_uri(make_client: Any, run_async: Any, tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert _multipart_field(request, "response_format") == "json"
        return _ok({"text": "ok"})

    client, requests = make_client(handler)
    audio = _write_wav(tmp_path)
    result = run_async(tools.transcribe(client, audio_ref=audio.as_uri()))
    assert result["text"] == "ok"
    assert len(requests) == 1


def test_transcribe_includes_language_field(
    make_client: Any, run_async: Any, tmp_path: Path
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert _multipart_field(request, "language") == "en"
        return _ok({"text": "ok"})

    client, requests = make_client(handler)
    audio = _write_wav(tmp_path)
    run_async(tools.transcribe(client, audio_ref=str(audio), language="en"))
    assert len(requests) == 1


def test_get_voice_does_not_expose_private_recipe_or_reference(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "GET"
        assert request.url.path == "/v1/voices/clone_1"
        return _ok(
            {
                "id": "clone_1",
                "name": "Presenter",
                "mode": "clone",
                "variant": "base",
                "available": True,
                "availability_reason": "available",
                "revision": "vr_" + "a" * 32,
                "capabilities": {"supports_clone": True},
                "validation_state": {
                    "reference": {"status": "pass"},
                    "synthesis": {"status": "pass"},
                },
                "production_ready": True,
                "production_ready_reason": "validated",
                "instruction": "private recipe",
                "ref_text": "private reference text",
                "audio_path": "/private/reference.wav",
            }
        )

    client, _requests = make_client(handler)
    result = run_async(tools.get_voice(client, voice_id="clone_1"))

    assert result["production_ready"] is True
    assert "instruction" not in result
    assert "ref_text" not in result
    assert "audio_path" not in result


# ---------------------------------------------------------------------------
# synthesize()
# ---------------------------------------------------------------------------


def test_synthesize_posts_speech_and_returns_audio_path(
    make_client: Any, run_async: Any
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]
    audio_bytes = b"ID3-fake-mp3"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("quality", "voice_design", voices))
        if request.url.path == "/v1/audio/speech":
            body = _json_body(request)
            assert body == {
                "model": "speechrail/qwen3-tts",
                "input": "你好",
                "voice": "serena",
                "response_format": "mp3",
                "speed": 1.0,
            }
            return httpx.Response(status_code=200, content=audio_bytes)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    result = run_async(tools.synthesize(client, text="你好"))

    assert result["content_type"] == "audio/mpeg"
    assert result["output_format"] == "mp3"
    assert result["bytes"] == len(audio_bytes)
    path = Path(result["audio_path"])
    assert path.is_file()
    assert path.read_bytes() == audio_bytes
    assert path.name.endswith(".mp3")
    path.unlink()
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/audio/speech",
    ]


@pytest.mark.parametrize("profile", ["quality", "extreme"])
def test_synthesize_uses_effective_snapshot_to_pin_voice_and_model(
    make_client: Any, run_async: Any, profile: str
) -> None:
    voice_revision = "vr_" + "a" * 32
    model_revision = "b" * 40
    snapshot = {
        "schema_version": "effective_capabilities_v1",
        "snapshot_id": "snap_1",
        "profile": profile,
        "models": {
            "tts": {
                "variant": "voice_design",
                "catalog_revision": "c" * 40,
            },
            "tts_clone": {
                "variant": "base",
                "artifact": "tts-base-bf16" if profile == "extreme" else "tts-base-q8",
            },
        },
        "voices": [
            {
                "id": "clone_1",
                "name": "clone_1",
                "mode": "clone",
                "available": True,
                "availability_reason": "available",
                "variant": "base",
                "voice_revision": voice_revision,
                "voice_identity_assurance": "content_addressed",
                "aliases": [],
                "model": {"catalog_revision": model_revision},
            }
        ],
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(snapshot)
        if request.method == "POST" and request.url.path == "/v1/audio/speech":
            assert request.headers["SpeechRail-Expected-Voice-Revision"] == voice_revision
            assert request.headers["SpeechRail-Expected-Model-Revision"] == model_revision
            assert _json_body(request)["voice"] == "clone_1"
            return httpx.Response(status_code=200, content=b"ID3-pinned")
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    result = run_async(tools.synthesize(client, text="跨文本一致", voice="clone_1"))

    assert result["voice_revision"] == voice_revision
    assert result["model_revision"] == model_revision
    path = Path(result["audio_path"])
    assert path.read_bytes() == b"ID3-pinned"
    path.unlink()
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/audio/speech",
    ]


def test_synthesize_allows_unverified_diagnostics_but_requires_output_pass_for_production(
    make_client: Any, run_async: Any
) -> None:
    snapshot = {
        "schema_version": "effective_capabilities_v1",
        "snapshot_id": "snap-unverified",
        "profile": "quality",
        "models": {"tts": {"variant": "voice_design"}},
        "voices": [
            {
                "id": "clone_1",
                "name": "clone_1",
                "mode": "clone",
                "available": True,
                "variant": "base",
                "capabilities": {"supports_clone": True},
                "production_ready": False,
                "production_ready_reason": "synthesis_validation_not_run",
                "validation_state": {
                    "reference": {"status": "pass"},
                    "synthesis": {"status": "unevaluated"},
                },
            }
        ],
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(snapshot)
        if request.method == "POST" and request.url.path == "/v1/audio/speech":
            return httpx.Response(status_code=200, content=b"ID3-unverified")
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    result = run_async(tools.synthesize(client, text="试听", voice="clone_1"))
    assert result["validation_state"]["synthesis"]["status"] == "unevaluated"
    Path(result["audio_path"]).unlink()

    with pytest.raises(ToolCallError) as excinfo:
        run_async(
            tools.synthesize(
                client,
                text="正式制作",
                voice="clone_1",
                validation_policy="require_output_pass",
            )
        )
    assert excinfo.value.code == "voice_not_production_ready"
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/audio/speech",
        "/v1/speechrail/capabilities",
    ]


def test_synthesize_accepts_instruction_voice_on_quality_tier(
    make_client: Any, run_async: Any
) -> None:
    voices = [
        _voice("serena", mode="system", available=True, variant="voice_design"),
        _voice(
            "my_voice",
            mode="instruction",
            available=True,
            variant="voice_design",
            capabilities={
                "supports_speaker": False,
                "supports_instruction": True,
                "supports_clone": True,
            },
        ),
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("quality", "voice_design", voices))
        if request.url.path == "/v1/audio/speech":
            assert _json_body(request)["voice"] == "my_voice"
            return httpx.Response(status_code=200, content=b"ID3-x")
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, _requests = make_client(handler)
    result = run_async(tools.synthesize(client, text="hi", voice="my_voice"))
    Path(result["audio_path"]).unlink()


def test_synthesize_accepts_instruction_voice_on_extreme_tier(
    make_client: Any, run_async: Any
) -> None:
    voices = [
        _voice(
            "my_voice",
            mode="instruction",
            available=True,
            variant="voice_design",
            capabilities={
                "supports_speaker": False,
                "supports_instruction": True,
                "supports_clone": False,
            },
        )
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("extreme", "voice_design", voices))
        if request.url.path == "/v1/audio/speech":
            return httpx.Response(status_code=200, content=b"ID3-x")
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, _requests = make_client(handler)

    result = run_async(tools.synthesize(client, text="hi", voice="my_voice"))

    Path(result["audio_path"]).unlink()


def test_synthesize_rejects_clone_voice_on_custom_voice_tier(
    make_client: Any, run_async: Any
) -> None:
    voices = [
        _voice("serena", mode="system", available=True, variant="custom_voice"),
        _voice(
            "clone_1",
            mode="clone",
            available=False,
            variant="custom_voice",
            capabilities={
                "supports_speaker": False,
                "supports_instruction": False,
                "supports_clone": True,
            },
        ),
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("balanced", "custom_voice", voices))
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.synthesize(client, text="hi", voice="clone_1"))
    assert excinfo.value.code == "voice_not_available"
    assert "describe()" in excinfo.value.hint
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
    ]


def test_synthesize_hard_blocks_instruction_voice_when_tier_is_not_quality(
    make_client: Any, run_async: Any
) -> None:
    # Advertised-as-available instruction voice while active weights are custom_voice:
    # the proxy must still refuse before any TTS request is made.
    voices = [
        _voice("serena", mode="system", available=True, variant="custom_voice"),
        _voice(
            "free_form",
            mode="instruction",
            available=True,
            variant="custom_voice",
            capabilities={
                "supports_speaker": False,
                "supports_instruction": True,
                "supports_clone": False,
            },
        ),
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("light", "custom_voice", voices))
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.synthesize(client, text="hi", voice="free_form"))
    assert excinfo.value.code == "voice_not_available"
    assert "VoiceDesign capability" in excinfo.value.message
    assert "switch" not in excinfo.value.message.lower()
    assert "light" in excinfo.value.message
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
    ]


def test_synthesize_rejects_voice_missing_from_effective_snapshot(
    make_client: Any, run_async: Any
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("quality", "voice_design", voices))
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.synthesize(client, text="hi", voice="ghost"))
    assert excinfo.value.code == "voice_not_found"
    assert "describe()" in excinfo.value.hint
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
    ]


def test_synthesize_rejects_out_of_range_speed_before_network(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.synthesize(client, text="hi", speed=9.0))
    assert excinfo.value.code == "invalid_speed"
    assert requests == []


# ---------------------------------------------------------------------------
# preview_voice()
# ---------------------------------------------------------------------------


def test_preview_voice_quality_posts_preview_and_returns_wav_path(
    make_client: Any, run_async: Any
) -> None:
    audio_bytes = b"RIFF-fake-preview-wav"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("quality", "voice_design", []))
        if request.url.path == "/v1/voices/previews":
            body = _json_body(request)
            assert body["instruction"] == "温暖自然的中文女声。"
            assert body["input"] == "试听这一句。"
            assert body["response_format"] == "wav"
            return httpx.Response(status_code=200, content=audio_bytes)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    result = run_async(
        tools.preview_voice(client, instruction="温暖自然的中文女声。", text="试听这一句。")
    )
    assert result["content_type"] == "audio/wav"
    path = Path(result["audio_path"])
    assert path.is_file()
    assert path.read_bytes() == audio_bytes
    assert path.name.endswith(".wav")
    path.unlink()
    assert len(requests) == 2


def test_preview_voice_works_on_extreme_profile(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("extreme", "voice_design", []))
        if request.url.path == "/v1/voices/previews":
            return httpx.Response(status_code=200, content=b"RIFF-extreme-preview")
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    result = run_async(
        tools.preview_voice(client, instruction="温和的中文女声。", text="试听。")
    )

    path = Path(result["audio_path"])
    assert path.read_bytes() == b"RIFF-extreme-preview"
    path.unlink()
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/voices/previews",
    ]


def test_preview_voice_rejected_on_custom_voice_tier(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("balanced", "custom_voice", []))
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.preview_voice(client, instruction="温柔的女声", text="你好"))
    assert excinfo.value.code == "voice_preview_unsupported"
    assert "VoiceDesign" in excinfo.value.message
    assert "switch" not in excinfo.value.message.lower()
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities"
    ]


def test_preview_voice_requires_instruction(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.preview_voice(client, instruction="  ", text="你好"))
    assert excinfo.value.code == "invalid_instruction"
    assert requests == []


# ---------------------------------------------------------------------------
# create_voice() / delete_voice() — preview → persist → synthesize loop
# ---------------------------------------------------------------------------


def test_create_voice_posts_exact_body_and_returns_entry(
    make_client: Any, run_async: Any
) -> None:
    entry = {"id": "custom_test", "mode": "instruction", "available": True}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("extreme", "voice_design", []))
        assert request.method == "POST"
        assert request.url.path == "/v1/voices"
        assert _json_body(request) == {
            "name": "知性女声",
            "instruction": "温和自然的中文女声。",
            "id": "custom_test",
            "seed": 7,
        }
        return _ok(entry, status=201)

    client, requests = make_client(handler)
    result = run_async(
        tools.create_voice(
            client,
            name="知性女声",
            instruction="温和自然的中文女声。",
            voice_id="Custom_Test",
            seed=7,
        )
    )
    assert result == entry
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/voices",
    ]


def test_create_voice_rejects_missing_voice_design_before_rest_mutation(
    make_client: Any, run_async: Any
) -> None:
    models = _model("balanced", "custom_voice")
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
    health = {"status": "ok", "profile": "balanced", "diarization_ready": False}
    client, requests = make_client(_base_handler(models, voices, health))

    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.create_voice(client, name="voice", instruction="warm"))

    assert excinfo.value.code == "capability_not_available"
    assert "switch" not in excinfo.value.message.lower()
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities"
    ]


def test_design_voice_rejects_missing_base_before_rest_mutation(
    make_client: Any, run_async: Any
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("custom_voice", "voice_design", voices))
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)

    with pytest.raises(ToolCallError) as excinfo:
        run_async(
            tools.design_voice(
                client,
                voice_id="design",
                name="voice",
                instruction="warm",
                reference_text="这是一个用于测试生成参考的示例句子，足够长。",
            )
        )

    assert excinfo.value.code == "capability_not_available"
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities"
    ]


def test_design_voice_uses_extreme_voice_design_and_base_capabilities(
    make_client: Any, run_async: Any
) -> None:
    voice = {"id": "new_design", "mode": "clone", "available": True}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("extreme", "voice_design", []))
        if request.method == "POST" and request.url.path == "/v1/voices/designs":
            body = _json_body(request)
            assert body["id"] == "new_design"
            assert body["name"] == "A voice"
            assert body["reference_text"] == "这是一个用于测试生成参考的完整示例句子。"
            return _ok({"voice": voice, "synthesis_validation": "unevaluated"}, status=201)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)

    result = run_async(
        tools.design_voice(
            client,
            voice_id="new_design",
            name="A voice",
            instruction="warm and clear",
            reference_text="这是一个用于测试生成参考的完整示例句子。",
        )
    )

    assert result["id"] == "new_design"
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/voices/designs",
    ]


def test_clone_voice_rejects_missing_base_before_audio_read_or_rest_mutation(
    make_client: Any, run_async: Any, tmp_path: Path
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
    client, requests = make_client(
        lambda request: _ok(_effective_capabilities("balanced", "custom_voice", voices))
    )

    with pytest.raises(ToolCallError) as excinfo:
        run_async(
            tools.clone_voice(
                client,
                audio_ref=str(tmp_path / "missing.wav"),
                name="clone",
                ref_text="这是一个用于测试音色克隆的示例。",
            )
        )

    assert excinfo.value.code == "capability_not_available"
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities"
    ]


def test_validate_voice_rejects_missing_base_before_rest_mutation(
    make_client: Any, run_async: Any
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
    client, requests = make_client(
        lambda request: _ok(_effective_capabilities("balanced", "custom_voice", voices))
    )

    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.validate_voice(client, voice_id="clone"))

    assert excinfo.value.code == "capability_not_available"
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities"
    ]


def test_create_voice_rejects_overlong_instruction_before_network(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.create_voice(client, name="n", instruction="x" * 10_001))
    assert excinfo.value.code == "invalid_instruction"
    assert requests == []


def test_create_voice_rejects_bad_id_and_seed_before_network(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.create_voice(client, name="n", instruction="ok", voice_id="bad id!"))
    assert excinfo.value.code == "invalid_voice_id"
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.create_voice(client, name="n", instruction="ok", seed=-1))
    assert excinfo.value.code == "invalid_seed"
    assert requests == []


def test_delete_voice_forwards_id(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "DELETE"
        assert request.url.path == "/v1/voices/custom_test"
        return _ok({"status": "deleted", "id": "custom_test"})

    client, requests = make_client(handler)
    result = run_async(tools.delete_voice(client, voice_id="custom_test"))
    assert result == {"status": "deleted", "id": "custom_test"}
    assert len(requests) == 1


def test_preview_create_synthesize_loop_closes_over_mcp(
    make_client: Any, run_async: Any
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]
    entry = {"id": "custom_loop", "mode": "instruction", "available": True}
    effective_entry = dict(
        entry,
        variant="voice_design",
        name="custom_loop",
        is_default=False,
        aliases=[],
        capabilities={
            "supports_speaker": False,
            "supports_instruction": True,
            "supports_clone": False,
        },
    )

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(
                _effective_capabilities(
                    "quality", "voice_design", [*voices, effective_entry]
                )
            )
        if request.url.path == "/v1/voices/previews":
            return httpx.Response(status_code=200, content=b"RIFF-preview")
        if request.method == "POST" and request.url.path == "/v1/voices":
            return _ok(entry, status=201)
        if request.url.path == "/v1/voices" and request.method == "GET":
            created_entry = dict(
                entry,
                variant="voice_design",
                name="custom_loop",
                is_default=False,
                aliases=[],
                capabilities={
                    "supports_speaker": False,
                    "supports_instruction": True,
                    "supports_clone": False,
                },
            )
            return _ok({"object": "list", "data": [*voices, created_entry]})
        if request.url.path == "/v1/audio/speech":
            assert _json_body(request)["voice"] == "custom_loop"
            return httpx.Response(status_code=200, content=b"ID3-x")
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, _requests = make_client(handler)
    preview = run_async(tools.preview_voice(client, instruction="温和的中文女声。", text="你好"))
    Path(preview["audio_path"]).unlink()
    created = run_async(tools.create_voice(client, name="loop", instruction="温和的中文女声。"))
    assert created["id"] == "custom_loop"
    spoken = run_async(tools.synthesize(client, text="hi", voice="custom_loop"))
    Path(spoken["audio_path"]).unlink()


# ---------------------------------------------------------------------------
# create_job / get_job / cancel_job
# ---------------------------------------------------------------------------


def test_create_job_posts_kind_and_input_ref(make_client: Any, run_async: Any) -> None:
    job = {"id": "job_x", "kind": "transcription", "state": "queued"}

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/jobs"
        body = _json_body(request)
        assert body == {"kind": "transcription", "input_ref": "/tmp/meeting.wav"}
        return _ok(job, status=202)

    client, requests = make_client(handler)
    result = run_async(
        tools.create_job(client, kind="transcription", input_ref="/tmp/meeting.wav")
    )
    assert result == job
    assert len(requests) == 1


def test_create_job_rejects_unknown_kind(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.create_job(client, kind="realtime", input_ref="/tmp/in.wav"))
    assert excinfo.value.code == "invalid_job_kind"
    assert requests == []


def test_create_job_rejects_overlong_input_ref(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.create_job(client, kind="speech", input_ref="/x" * 501))
    assert excinfo.value.code == "invalid_input_ref"
    assert requests == []


def test_get_and_cancel_job_forward_job_id(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/jobs/job_x":
            return _ok({"id": "job_x", "state": "running"})
        if request.method == "DELETE" and request.url.path == "/v1/jobs/job_x":
            return _ok({"id": "job_x", "state": "cancelled"})
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    assert run_async(tools.get_job(client, job_id="job_x"))["state"] == "running"
    assert run_async(tools.cancel_job(client, job_id="job_x"))["state"] == "cancelled"
    assert [request.method for request in requests] == ["GET", "DELETE"]


def test_get_job_not_found_surfaces_job_error_code(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return _ok(
            {
                "error": {
                    "message": "Unknown job",
                    "type": "invalid_request_error",
                    "code": "job_not_found",
                    "request_id": "req_1",
                    "retryable": False,
                }
            },
            status=404,
        )

    client, _requests = make_client(handler)
    with pytest.raises(SpeechRailError) as excinfo:
        run_async(tools.get_job(client, job_id="job_nope"))
    assert excinfo.value.code == "job_not_found"
    assert excinfo.value.status == 404


def test_create_job_forwards_params_to_client(make_client: Any, run_async: Any) -> None:
    job = {
        "id": "job_x",
        "kind": "transcription",
        "state": "queued",
        "params": {"language": "zh"},
    }

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/jobs"
        body = _json_body(request)
        assert body == {
            "kind": "transcription",
            "input_ref": "/tmp/meeting.wav",
            "params": {"language": "zh"},
        }
        return _ok(job, status=202)

    client, requests = make_client(handler)
    result = run_async(
        tools.create_job(
            client,
            kind="transcription",
            input_ref="/tmp/meeting.wav",
            params={"language": "zh"},
        )
    )
    assert result == job
    assert len(requests) == 1


def test_create_speech_job_accepts_and_forwards_validation_policy(
    make_client: Any, run_async: Any
) -> None:
    job = {
        "id": "job_speech",
        "kind": "speech",
        "state": "queued",
        "params": {
            "voice": "clone_voice",
            "speed": 1.0,
            "validation_policy": "require_output_pass",
        },
    }

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/jobs"
        assert _json_body(request) == {
            "kind": "speech",
            "input_ref": "/tmp/script.txt",
            "params": {
                "voice": "clone_voice",
                "speed": 1.0,
                "validation_policy": "require_output_pass",
            },
        }
        return _ok(job, status=202)

    client, requests = make_client(handler)
    result = run_async(
        tools.create_job(
            client,
            kind="speech",
            input_ref="/tmp/script.txt",
            params={
                "voice": "clone_voice",
                "speed": 1.0,
                "validation_policy": "require_output_pass",
            },
        )
    )
    assert result == job
    assert len(requests) == 1


def test_create_speech_job_rejects_unknown_validation_policy(
    make_client: Any, run_async: Any
) -> None:
    client, requests = make_client(lambda request: _ok({"unexpected": True}))
    with pytest.raises(ToolCallError) as excinfo:
        run_async(
            tools.create_job(
                client,
                kind="speech",
                input_ref="/tmp/script.txt",
                params={"validation_policy": "maybe"},
            )
        )
    assert excinfo.value.code == "invalid_params"
    assert requests == []


def test_create_job_rejects_non_dict_params(make_client: Any, run_async: Any) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(
            tools.create_job(
                client, kind="speech", input_ref="/tmp/in.wav", params=["not", "a", "dict"]
            )
        )
    assert excinfo.value.code == "invalid_params"
    assert requests == []
