"""Negotiated revision windows must fail closed before audio capture."""

import json
from copy import deepcopy
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from speechrail.application.capability_snapshot import asr_operations
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    apply_session_update,
)

MODEL = "speechrail/qwen3-asr-1.7b"


def request(scene="caption"):
    return {
        "type": "session.update",
        "event_id": "evt-window",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": 24000},
                    "transcription": {"model": MODEL},
                }
            },
            "speechrail": {
                "task": "caption",
                "window": {"mode": "revision_window_v1", "scene": scene},
            },
        },
    }


def apply(event, *, ready=True):
    return apply_session_update(
        event,
        session_id="session-window",
        asr_model=MODEL,
        registered_asr=frozenset({MODEL}),
        revision_window_ready=ready,
    )


@pytest.mark.parametrize(
    "scene,owned,max_decode", [("caption", 4000, 14000), ("meeting", 20000, 24000)]
)
def test_window_is_explicitly_negotiated_with_effective_policy(scene, owned, max_decode):
    response, config = apply(request(scene))
    extension = response["session"]["speechrail"]
    assert "asr" not in extension
    assert extension["window"]["mode"] == "revision_window_v1"
    assert extension["window"]["scene"] == scene
    assert extension["window"]["policy"]["owned_ms"] == owned
    assert extension["window"]["policy"]["max_decode_ms"] == max_decode
    assert extension["window"]["policy"]["finalization_budget_ms"] > 0
    assert config["window_scene"] == scene


def test_unready_window_cannot_start_and_legacy_mode_remains_available():
    with pytest.raises(RealtimeAdapterError) as error:
        apply(request(), ready=False)
    assert error.value.code == "unsupported_operation"
    event = request()
    del event["session"]["speechrail"]["window"]
    response, config = apply(event, ready=False)
    assert "window" not in response["session"]["speechrail"]
    assert not config.get("window_scene")


@pytest.mark.parametrize(
    "value",
    [
        None,
        True,
        {},
        {"mode": "other", "scene": "caption"},
        {"mode": "revision_window_v1", "scene": True},
        {"mode": "revision_window_v1", "scene": "caption", "owned_ms": 2000},
    ],
)
def test_window_rejects_unknown_shape_and_client_policy_values(value):
    event = request()
    event["session"]["speechrail"]["window"] = value
    with pytest.raises(RealtimeAdapterError):
        apply(event)


def test_window_and_old_policy_are_mutually_exclusive():
    event = request()
    event["session"]["speechrail"]["asr"] = {}
    with pytest.raises(RealtimeAdapterError):
        apply(event)


@pytest.mark.parametrize(
    "missing", ["revision_window_enabled", "window_decode_ready", "word_alignment_ready", "ready"]
)
def test_window_capability_requires_all_actual_dependencies(missing):
    facts = {
        "available": True,
        "ready": True,
        "revision_window_enabled": True,
        "window_decode_ready": True,
        "word_alignment_ready": True,
    }
    supported = asr_operations(facts)["realtime_transcription"]["revision_window"]
    assert supported["status"] == "supported"
    assert supported["modes"] == ["revision_window_v1"]
    facts[missing] = False
    assert (
        asr_operations(facts)["realtime_transcription"]["revision_window"]["status"]
        == "unsupported"
    )


def test_schema_accepts_window_negotiation_and_rejects_mixed_policy():
    schema = json.loads(
        (Path(__file__).parents[1] / "contracts/realtime-events.schema.json").read_text()
    )
    validator = Draft202012Validator(schema)
    event = request()
    assert not list(validator.iter_errors(event))
    mixed = deepcopy(event)
    mixed["session"]["speechrail"]["asr"] = {}
    assert list(validator.iter_errors(mixed))


@pytest.mark.parametrize("samples", [511, 512, 513, 16001])
@pytest.mark.parametrize("packet", [37, 768])
def test_window_route_owns_raw_resampler_tail_exactly_once(samples, packet):
    import asyncio
    import base64

    from speechrail.application.realtime_openai import OpenAIRealtimeSession
    from speechrail.application.services import AppOverrides, build_app_services
    from speechrail.config import Settings
    from speechrail.domain.audio_timeline import RationalResampler
    from test_asr_window_coordinator import Decoder

    class Factory:
        ready = True

        def __init__(self):
            self.decoder = Decoder()

        def create(self, *, identity):
            return self.decoder

    class Aligner:
        word_alignment_ready = True

    async def scenario():
        events = []

        async def send(event):
            events.append(event)
            return len(events)

        factory = Factory()
        services = build_app_services(
            Settings(qwen3_model_dir=None, qwen3_python=None, asr_revision_windows_enabled=True),
            AppOverrides(window_asr_factory=factory, text_aligner=Aligner()),
        )
        session = OpenAIRealtimeSession(services, session_id="window-route", send=send)
        event = request("meeting")
        event["session"]["audio"]["input"]["transcription"]["model"] = services.settings.model_id
        event["session"]["audio"]["input"]["turn_detection"] = None
        await session.handle(event)
        wire = bytes(index % 256 for index in range(samples * 2))
        reference = RationalResampler(24000, 16000)
        expected = reference.process(wire) + reference.flush()
        try:
            for offset in range(0, len(wire), packet * 2):
                await session.handle(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(wire[offset : offset + packet * 2]).decode(),
                    }
                )
            await session.handle(
                {
                    "type": "input_audio_buffer.commit",
                    "event_id": "commit-window",
                    "speechrail": {"request_receipt": True},
                }
            )
            reviews = [call for call in factory.decoder.calls if call.kind == "review"]
            assert len(reviews) == 1
            assert reviews[0].pcm16 == expected
            assert reviews[0].input_span.end == len(expected) // 2
            assert len([e for e in events if e["type"].endswith("completed")]) == 1
            receipt = next(
                e for e in events if e["type"] == "speechrail.input_audio_buffer.committed"
            )
            assert receipt["accepted_samples"] == samples
            assert receipt["sealed_through_sample"] == samples
            window_events = [
                e for e in events if str(e["type"]).startswith("speechrail.transcription.window.")
            ]
            assert receipt["sealed_through_sample"] == window_events[-1]["sealed_through_sample"]
            assert receipt["window_revision"] == window_events[-1]["window_revision"]
            validator = Draft202012Validator(
                json.loads(
                    (
                        Path(__file__).parents[1] / "contracts/realtime-events.schema.json"
                    ).read_text()
                )
            )
            for sequence, emitted in enumerate(events, 1):
                validator.validate(
                    {
                        "session_id": "window-route",
                        "event_id": f"server-{sequence}",
                        "sequence": sequence,
                        **emitted,
                    }
                )
        finally:
            await session.close()

    asyncio.run(scenario())


def test_server_vad_commit_cannot_reuse_sealed_silence_as_next_speech_prefix():
    import asyncio
    import base64

    from realtime_wire import server_vad
    from speechrail.application.realtime_openai import OpenAIRealtimeSession
    from speechrail.application.services import AppOverrides, build_app_services
    from speechrail.config import Settings
    from test_asr_window_coordinator import Decoder
    from test_realtime_vad_bargein import _wire_speech_frame

    class Factory:
        ready = True

        def create(self, *, identity):
            return Decoder()

    class Aligner:
        word_alignment_ready = True

        async def align(self, request):
            raise RuntimeError("synthetic boundary unavailable")

    async def scenario():
        events = []

        async def send(event):
            events.append(event)
            return len(events)

        services = build_app_services(
            Settings(
                qwen3_model_dir=None,
                qwen3_python=None,
                asr_revision_windows_enabled=True,
                realtime_speech_admission_enabled=True,
            ),
            AppOverrides(window_asr_factory=Factory(), text_aligner=Aligner()),
        )
        session = OpenAIRealtimeSession(services, session_id="window-vad-barrier", send=send)
        event = request()
        event["session"]["audio"]["input"]["transcription"]["model"] = services.settings.model_id
        event["session"]["speechrail"]["endpointing"] = server_vad(
            threshold=0.3,
            prefix_padding_ms=300,
            silence_duration_ms=400,
        )
        await session.handle(event)
        try:
            silence = bytes(768 * 12 * 2)
            speech = _wire_speech_frame() * 6
            for index, wire in enumerate((silence, speech)):
                await session.handle(
                    {"type": "input_audio_buffer.append", "audio": base64.b64encode(wire).decode()}
                )
                await session.handle(
                    {
                        "type": "input_audio_buffer.commit",
                        "event_id": f"barrier-{index}",
                        "speechrail": {"request_receipt": True},
                    }
                )
            assert [e for e in events if e["type"] == "error"] == []
            receipts = [e for e in events if e["type"] == "speechrail.input_audio_buffer.committed"]
            assert len(receipts) == 2
            assert receipts[-1]["sealed_through_sample"] == (len(silence) + len(speech)) // 2
            terminals = [e for e in events if e["type"].endswith("window.sealed")]
            assert terminals[-1]["closed_span"]["start"] >= len(silence) // 2
            assert terminals[-1]["final_units"]
        finally:
            await session.close()

    asyncio.run(scenario())
