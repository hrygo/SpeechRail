"""One business operation, two doors, one set of refusals.

REST and MCP both reach the same service. A caller must not learn a different
rule depending on which door it used: the same invalid render is refused for
the same reason everywhere, and an accepted one reaches the synthesizer once
per door.

The macOS App asserts its side of the same rule in
`macos/SpeechRailApp/SpeechRailMacControlTests/AppModelTests.swift`
(`testCreatorRefusesInvalidRendersBeforeSendingAnything`) and in
`ServiceContractTests.swift` (request headers and the strict validation policy).
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import (
    VoiceRevisionConflictError,
)
from speechrail.infrastructure.voice_registry import FileVoiceRegistry as VoiceRegistry
from speechrail.mcp.client import SpeechRailClient, SpeechRailError
from speechrail.mcp.tools import ToolCallError
from speechrail.mcp.tools import synthesize as mcp_synthesize

_PCM = b"\x01\x00\x02\x00\x03\x00"
_TEXT = "跨接口一致性的配音文稿。"


class ParitySynthesizer:
    """Records real deliveries, so "both doors accepted it" means both rendered."""

    def __init__(self, voice_revision: str) -> None:
        self.requests: list[SpeechRequest] = []
        self.voice_revision = voice_revision

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return "rt_" + ("9" * 64)

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        # The production backend enforces the revision pin while leasing the
        # profile. A stand-in that skipped this would let REST accept a render
        # the App and MCP both refuse — the exact drift this file exists to catch.
        if (
            request.expected_voice_revision is not None
            and request.expected_voice_revision != self.voice_revision
        ):
            raise VoiceRevisionConflictError
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="parity-response",
                chunk_index=0,
                audio=_PCM,
            )

        return chunks()


@dataclass(frozen=True)
class ParitySample:
    """One render a caller could attempt, and the fact both doors refuse on.

    The two codes are per-surface identifiers, not one shared vocabulary: REST
    reports schema refusals as `validation_error` plus the offending `param`,
    while an MCP tool answers the agent with the specific reason. What must
    match is the decision — refuse, refuse before synthesis, and refuse on the
    same fact.
    """

    name: str
    body: dict[str, Any]
    headers: dict[str, str] = field(default_factory=dict)
    mcp_arguments: dict[str, Any] = field(default_factory=dict)
    rest_code: str = ""
    rest_param: str | None = None
    mcp_code: str = ""


_STALE_REVISION = "vr_" + ("0" * 32)

SAMPLES: tuple[ParitySample, ...] = (
    ParitySample(
        name="blank_text",
        body={"model": "speechrail/qwen3-tts", "input": "   ", "voice": "narrator"},
        mcp_arguments={"text": "   ", "voice": "narrator"},
        rest_code="validation_error",
        rest_param="input",
        mcp_code="invalid_text",
    ),
    ParitySample(
        name="blank_voice",
        body={"model": "speechrail/qwen3-tts", "input": _TEXT, "voice": "  "},
        mcp_arguments={"text": _TEXT, "voice": "  "},
        rest_code="validation_error",
        rest_param="voice",
        mcp_code="invalid_voice",
    ),
    ParitySample(
        name="unknown_voice",
        body={"model": "speechrail/qwen3-tts", "input": _TEXT, "voice": "no_such_voice"},
        mcp_arguments={"text": _TEXT, "voice": "no_such_voice"},
        rest_code="voice_not_found",
        rest_param="voice",
        mcp_code="voice_not_found",
    ),
    ParitySample(
        name="speed_out_of_range",
        body={
            "model": "speechrail/qwen3-tts",
            "input": _TEXT,
            "voice": "narrator",
            "speed": 9.0,
        },
        mcp_arguments={"text": _TEXT, "voice": "narrator", "speed": 9.0},
        rest_code="validation_error",
        rest_param="speed",
        mcp_code="invalid_speed",
    ),
    ParitySample(
        name="unknown_output_format",
        body={
            "model": "speechrail/qwen3-tts",
            "input": _TEXT,
            "voice": "narrator",
            "response_format": "aiff",
        },
        mcp_arguments={"text": _TEXT, "voice": "narrator", "output_format": "aiff"},
        rest_code="validation_error",
        rest_param="response_format",
        mcp_code="invalid_output_format",
    ),
    ParitySample(
        name="unknown_validation_policy",
        body={"model": "speechrail/qwen3-tts", "input": _TEXT, "voice": "narrator"},
        headers={"SpeechRail-Validation-Policy": "trust_me"},
        mcp_arguments={
            "text": _TEXT,
            "voice": "narrator",
            "validation_policy": "trust_me",
        },
        rest_code="validation_error",
        mcp_code="invalid_validation_policy",
    ),
    ParitySample(
        name="stale_voice_revision",
        body={"model": "speechrail/qwen3-tts", "input": _TEXT, "voice": "narrator"},
        headers={"SpeechRail-Expected-Voice-Revision": _STALE_REVISION},
        mcp_arguments={
            "text": _TEXT,
            "voice": "narrator",
            "expected_voice_revision": _STALE_REVISION,
        },
        rest_code="voice_revision_conflict",
        mcp_code="voice_revision_conflict",
    ),
)


@pytest.fixture
def parity_app(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    asr_key = required_spec_artifact("quality", "asr")
    tts_key = required_spec_artifact("quality", "tts_custom_voice")
    base_key = required_spec_artifact("quality", "tts_base")
    assert asr_key is not None and tts_key is not None and base_key is not None
    registry = VoiceRegistry.open(
        storage_path=tmp_path / "custom_voices.json",
        voices_dir=tmp_path / "voices",
    )
    profile = registry.create_cloned_profile(
        name="Narrator",
        ref_text="参考文本。",
        audio_bytes=b"RIFF-test-reference",
        voice_id="narrator",
        duration_seconds=3.0,
    )
    assert profile.revision is not None
    synth = ParitySynthesizer(profile.revision)
    app = create_app(
        Settings(
            qwen3_model_dir=tmp_path / asr_key,
            asr_resident_bytes=1 * 1024**3,
            qwen3_python=None,
            qwen3_tts_model_dir=tmp_path / tts_key,
            tts_resident_bytes=1 * 1024**3,
            qwen3_tts_clone_model_dir=tmp_path / base_key,
            qwen3_tts_python=None,
            selection_schema_version=2,
            selection_asr_spec="quality",
            selection_tts_spec="quality",
            asr_artifact_key=asr_key,
            tts_artifact_key=tts_key,
            tts_base_artifact_key=base_key,
        ),
        tts_synthesizer=synth,
        voice_store=registry,
    )
    return app, synth


def _rest_refusal(client: TestClient, sample: ParitySample) -> str:
    response = client.post("/v1/audio/speech", json=sample.body, headers=sample.headers)
    assert response.status_code >= 400, f"{sample.name}: REST 接受了本该拒绝的请求"
    error = response.json()["error"]
    assert error["code"] == sample.rest_code
    assert error.get("param") == sample.rest_param
    assert error["request_id"]
    return str(error["code"])


@pytest.mark.parametrize("sample", SAMPLES, ids=lambda sample: sample.name)
@pytest.mark.anyio
async def test_rest_and_mcp_refuse_the_same_render_for_the_same_reason(
    parity_app,
    sample: ParitySample,
) -> None:
    app, synth = parity_app
    rest_code = _rest_refusal(TestClient(app), sample)

    client = SpeechRailClient(transport=httpx.ASGITransport(app=app))
    try:
        # A tool may refuse from its own argument checks, or hand the pin to the
        # service and report what came back. Either way the caller sees one code.
        with pytest.raises((ToolCallError, SpeechRailError)) as refusal:
            await mcp_synthesize(client, **sample.mcp_arguments)
    finally:
        await client.aclose()

    assert refusal.value.code == sample.mcp_code
    assert rest_code == sample.rest_code
    assert synth.requests == [], f"{sample.name}: 被拒绝的渲染不得触达合成器"


@pytest.mark.anyio
async def test_both_doors_render_the_same_accepted_request(parity_app) -> None:
    """Refusal parity is worthless if an accepted render differs between doors."""
    app, synth = parity_app
    response = TestClient(app).post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": _TEXT,
            "voice": "narrator",
            "response_format": "wav",
        },
    )
    assert response.status_code == 200
    assert response.content[:4] == b"RIFF"

    client = SpeechRailClient(transport=httpx.ASGITransport(app=app))
    try:
        rendered = await mcp_synthesize(
            client,
            text=_TEXT,
            voice="narrator",
            output_format="wav",
        )
    finally:
        await client.aclose()

    written = await asyncio.to_thread(Path(str(rendered["audio_path"])).read_bytes)
    assert written == response.content
    assert [request.voice for request in synth.requests] == ["narrator", "narrator"]
