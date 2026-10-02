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


def _model(profile: str, variant: str, *, design: bool = False) -> list[dict[str, Any]]:
    """Build the ``/v1/models`` payload the service actually publishes.

    ``variant`` is the production TTS route and is only ever ``custom_voice`` or
    ``base``. ``design`` stands for whether a VoiceDesign artifact is bound, which
    is an independent fact: it drives ``supports_preview`` / ``supports_instruction``
    on the TTS entry and is published as its own ``models["voice_design"]`` peer
    role. Folding it into ``variant`` fabricates a state no deployment can reach.
    """
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
                "supports_preview": design,
                "supports_clone": profile in {"quality", "extreme"},
                "supports_instruction": design,
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
    *,
    design: bool = False,
) -> dict[str, Any]:
    """Build the snapshot shape the service actually publishes.

    ``models["tts"]`` names the production route only. VoiceDesign is a
    tier-independent on-demand lane, so it is published as a peer ``voice_design``
    role and never as a ``tts`` variant.
    """
    return {
        "schema_version": "effective_capabilities_v1",
        "snapshot_id": f"{profile}-{variant}",
        "profile": profile,
        "models": {
            "tts": {"variant": variant},
            "tts_clone": (
                {"variant": "base"}
                if profile in {"fast", "quality", "reference", "extreme"}
                else {}
            ),
            "voice_design": (
                {"artifact": "tts-1.7b-design-bf16", "variant": "voice_design"}
                if design
                else {"assurance": "unknown", "runtime_revision": None}
            ),
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
            tts_entry = next(
                entry for entry in models if entry.get("family") == "qwen3_tts"
            )
            return _ok(
                _effective_capabilities(
                    health["profile"],
                    tts_entry["variant"],
                    voices,
                    design=bool(
                        tts_entry.get("capabilities", {}).get("supports_preview")
                    ),
                )
            )
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
    models = _model("quality", "custom_voice", design=True)
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
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
    models = _model("extreme", "custom_voice", design=True)
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
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
    models = _model("quality", "custom_voice", design=True)
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
    health = {"status": "ok", "profile": "extreme", "diarization_ready": True}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("extreme", "custom_voice", voices, design=True))
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


def test_describe_does_not_infer_profile_from_voice_variant(
    make_client: Any, run_async: Any
) -> None:
    models = _model("quality", "custom_voice", design=True)
    for entry in models:
        entry.pop("profile", None)
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
    health = {"status": "ok", "diarization_ready": True}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/speechrail/capabilities":
            return _ok(
                _effective_capabilities("quality", "custom_voice", voices, design=True)
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
            assert _multipart_field(request, "model") == "gpt-4o-transcribe-diarize"
            assert _multipart_field(request, "response_format") == "diarized_json"
            assert _multipart_field(request, "chunking_strategy") == "auto"
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
    # 系统音色走生产 TTS 路由, 只能是 custom_voice/base;voice_design 是独立
    # 设计通道制品 variant, 不进入合成入口(synthesize 已不再放行).
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
    audio_bytes = b"ID3-fake-mp3"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("quality", "custom_voice", voices, design=True))
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
                # The production route is only ever custom_voice or base; design
                # is a peer `voice_design` role, never a tts variant. Folding it
                # into this slot fabricates a state no deployment can reach.
                "variant": "custom_voice",
                "catalog_revision": "c" * 40,
            },
            "tts_clone": {
                "variant": "base",
                "artifact": "tts-base-bf16" if profile == "extreme" else "tts-base-q8",
            },
            "voice_design": {
                "artifact": "tts-1.7b-design-bf16",
                "variant": "voice_design",
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
        "models": {
            "tts": {"variant": "custom_voice"},
            "voice_design": {
                "artifact": "tts-1.7b-design-bf16",
                "variant": "voice_design",
            },
        },
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


@pytest.mark.parametrize("profile", ["quality", "extreme"])
def test_synthesize_refuses_instruction_voice_even_when_design_lane_is_bound(
    make_client: Any, run_async: Any, profile: str
) -> None:
    """An instruction voice is a design candidate, never a synthesis route.

    The design lane being available does not make the candidate synthesizable:
    /v1/audio/speech answers `voice_design_task_required` for any voice without a
    runtime role, so the proxy must refuse before spending a request. Rejecting
    with the capability's own code also keeps the answer honest — the old
    `variant == "voice_design"` short-circuit could only fire in a snapshot no
    deployment publishes, and its fallback message claimed VoiceDesign was
    "unavailable" precisely when it was available.
    """
    voices = [
        _voice("serena", mode="system", available=True, variant="custom_voice"),
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
        ),
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(
                _effective_capabilities(profile, "custom_voice", voices, design=True)
            )
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.synthesize(client, text="hi", voice="my_voice"))
    assert excinfo.value.code == "voice_design_task_required"
    assert "publish_voice_design" in (excinfo.value.hint or "")
    assert "unavailable in the active profile" not in excinfo.value.message
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
    ]


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
    assert excinfo.value.code == "voice_design_task_required"
    assert "voice_design task" in excinfo.value.message
    assert "switch" not in excinfo.value.message.lower()
    assert "light" in excinfo.value.message
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
    ]


def test_synthesize_rejects_voice_missing_from_effective_snapshot(
    make_client: Any, run_async: Any
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("quality", "custom_voice", voices, design=True))
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


def test_synthesize_rejects_voice_design_variant_without_compat_shim(
    make_client: Any, run_async: Any
) -> None:
    """The synthesis entrypoint only accepts custom_voice/base (no compat shim).

    The production snapshot ``models["tts"].variant`` can only be
    ``custom_voice`` or ``base`` (the design lane is an independent peer
    role). Any state stuffing ``voice_design`` into synthesis is forged and
    must deterministically return ``tts_variant_unsupported``.
    """
    voices = [_voice("serena", mode="system", available=True, variant="voice_design")]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            snapshot = _effective_capabilities(
                "quality", "voice_design", voices, design=True
            )
            return _ok(snapshot)
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)
    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.synthesize(client, text="hi", voice="serena"))
    assert excinfo.value.code == "tts_variant_unsupported"
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
    ]


# ---------------------------------------------------------------------------
# preview_voice()
# ---------------------------------------------------------------------------


def test_preview_voice_quality_posts_preview_and_returns_wav_path(
    make_client: Any, run_async: Any
) -> None:
    audio_bytes = b"RIFF-fake-preview-wav"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("quality", "custom_voice", [], design=True))
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
            return _ok(_effective_capabilities("extreme", "custom_voice", [], design=True))
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
            return _ok(_effective_capabilities("extreme", "custom_voice", [], design=True))
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


def test_design_voice_creates_candidate_without_base(
    make_client: Any, run_async: Any
) -> None:
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("custom_voice", "custom_voice", voices, design=True))
        if request.method == "POST" and request.url.path == "/v1/voice-designs":
            body = _json_body(request)
            assert body["voice_id"] == "design"
            assert body["reference_text"] == "这是一个用于测试生成参考的示例句子，足够长。"
            return _ok(
                {
                    "candidate": {
                        "id": "vd_" + "a" * 24,
                        "target_voice_id": "design",
                        "name": "voice",
                        "state": "generated",
                        "revision": "vr_" + "b" * 32,
                        "publishable": False,
                    }
                },
                status=201,
            )
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)

    result = run_async(
        tools.design_voice(
            client,
            voice_id="design",
            name="voice",
            instruction="warm",
            reference_text="这是一个用于测试生成参考的示例句子，足够长。",
        )
    )

    assert result["state"] == "generated"
    assert result["publishable"] is False
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/voice-designs",
    ]


def test_design_voice_uses_reference_voice_design_capability(
    make_client: Any, run_async: Any
) -> None:
    candidate = {
        "id": "vd_" + "c" * 24,
        "target_voice_id": "new_design",
        "name": "A voice",
        "state": "generated",
        "revision": "vr_" + "d" * 32,
        "publishable": False,
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("reference", "custom_voice", [], design=True))
        if request.method == "POST" and request.url.path == "/v1/voice-designs":
            body = _json_body(request)
            assert body["voice_id"] == "new_design"
            assert body["name"] == "A voice"
            assert body["reference_text"] == "这是一个用于测试生成参考的完整示例句子。"
            return _ok({"candidate": candidate}, status=201)
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

    assert result["id"] == candidate["id"]
    assert [request.url.path for request in requests] == [
        "/v1/speechrail/capabilities",
        "/v1/voice-designs",
    ]


def test_voice_design_confirm_validate_review_and_publish_flow(
    make_client: Any, run_async: Any
) -> None:
    candidate_id = "vd_" + "e" * 24
    revision = "vr_" + "f" * 32
    candidate = {
        "id": candidate_id,
        "target_voice_id": "new_design",
        "name": "A voice",
        "state": "generated",
        "revision": revision,
        "publishable": False,
    }
    validation_id = "vv_" + "1" * 24

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET" and request.url.path == "/v1/speechrail/capabilities":
            return _ok(_effective_capabilities("reference", "custom_voice", [], design=True))
        if request.url.path == f"/v1/voice-designs/{candidate_id}/confirm":
            assert _json_body(request) == {
                "reference_text": "编辑后的参考文本，长度足够并且表达自然。"
            }
            return _ok({"candidate": {**candidate, "state": "confirmed"}})
        if request.url.path == f"/v1/voice-designs/{candidate_id}/validate":
            body = _json_body(request)
            if "human_review" in body:
                assert body["human_review"] == {
                    "validation_id": validation_id,
                    "identity": "pass",
                    "naturalness": "pass",
                }
                return _ok(
                    {
                        "candidate": {
                            **candidate,
                            "state": "publishable",
                            "publishable": True,
                        }
                    }
                )
            assert body["test_text"] == "这是不同于参考文本的 Base 测试文本，长度足够。"
            return _ok(
                {
                    "candidate": {
                        **candidate,
                        "state": "validating",
                        "validations": [{"validation_id": validation_id, "machine_status": "pass"}],
                    }
                }
            )
        if request.url.path == f"/v1/voice-designs/{candidate_id}/publish":
            assert _json_body(request) == {"expected_candidate_revision": revision}
            return _ok(
                {
                    "candidate": {
                        **candidate,
                        "state": "published",
                        "publishable": True,
                        "published_voice_revision": revision,
                    },
                    "voice": {"id": "new_design", "mode": "clone", "available": True},
                },
                status=201,
            )
        raise AssertionError(f"unexpected request {request.method} {request.url.path}")

    client, requests = make_client(handler)

    confirmed = run_async(
        tools.confirm_voice_design(
            client,
            candidate_id=candidate_id,
            reference_text="编辑后的参考文本，长度足够并且表达自然。",
        )
    )
    validated = run_async(
        tools.validate_voice_design(
            client,
            candidate_id=candidate_id,
            test_text="这是不同于参考文本的 Base 测试文本，长度足够。",
        )
    )
    reviewed = run_async(
        tools.validate_voice_design(
            client,
            candidate_id=candidate_id,
            validation_id=validation_id,
            identity_review="pass",
            naturalness_review="pass",
        )
    )
    published = run_async(
        tools.publish_voice_design(
            client,
            candidate_id=candidate_id,
            expected_candidate_revision=revision,
        )
    )

    assert confirmed["state"] == "confirmed"
    assert validated["state"] == "validating"
    assert reviewed["publishable"] is True
    assert published["voice"]["id"] == "new_design"
    assert [request.url.path for request in requests] == [
        f"/v1/voice-designs/{candidate_id}/confirm",
        "/v1/speechrail/capabilities",
        f"/v1/voice-designs/{candidate_id}/validate",
        "/v1/speechrail/capabilities",
        f"/v1/voice-designs/{candidate_id}/validate",
        "/v1/speechrail/capabilities",
        f"/v1/voice-designs/{candidate_id}/publish",
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


def test_preview_create_loop_ends_at_a_design_candidate_not_a_synthesis_voice(
    make_client: Any, run_async: Any
) -> None:
    """preview -> create_voice stops at a candidate; it does not close the loop.

    `create_voice` registers an `instruction` voice. Such a voice has no runtime
    synthesis role, so the honest continuation is design_voice -> publish, not
    synthesize. This test pins that boundary so the shortcut is not reintroduced.
    """
    voices = [_voice("serena", mode="system", available=True, variant="custom_voice")]
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
                    "quality", "custom_voice", [*voices, effective_entry], design=True
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

    client, requests = make_client(handler)
    preview = run_async(tools.preview_voice(client, instruction="温和的中文女声。", text="你好"))
    Path(preview["audio_path"]).unlink()
    created = run_async(tools.create_voice(client, name="loop", instruction="温和的中文女声。"))
    assert created["id"] == "custom_loop"

    with pytest.raises(ToolCallError) as excinfo:
        run_async(tools.synthesize(client, text="hi", voice="custom_loop"))
    assert excinfo.value.code == "voice_design_task_required"
    assert "/v1/audio/speech" not in [request.url.path for request in requests]


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
