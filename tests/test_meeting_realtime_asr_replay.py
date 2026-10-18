"""Formal session replay with synthetic PCM and fake inference only."""

from __future__ import annotations

import asyncio
import json
import math
import random
import struct
from dataclasses import replace

import pytest
from meeting_evaluation_identity import MeetingCandidateSpec
from meeting_realtime_asr_replay import (
    _Terminals,
    inverse_embed_pcm16,
    realtime_replay_preset,
    replay_realtime_session,
)
from probe_meeting_asr_quality import ASR_SCORER, AsrCase, RuntimeObservation

from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.domain.asr_window import WindowDecodeObservation, WindowDecodeResult
from speechrail.domain.audio_timeline import RationalResampler


class Decoder:
    def __init__(self, *, block=False, observation=True):
        self.block = block
        self.observation = observation
        self.entered = asyncio.Event()
        self.calls = []
        self.closed = False

    async def decode(self, request):
        self.calls.append(request)
        self.entered.set()
        if self.block:
            await asyncio.Event().wait()
        return WindowDecodeResult(
            request.identity,
            request.attempt_id,
            request.input_span,
            "甲乙" if request.kind == "review" else "不评分的预览",
            request.language,
            request.kind == "review",
            WindowDecodeObservation(request.kind, 32, finish_reason="eos", truncated=False)
            if self.observation
            else None,
        )

    async def close(self):
        self.closed = True


class Factory:
    ready = True

    def __init__(self, **kwargs):
        self.sessions = []
        self.kwargs = kwargs
        self.created = asyncio.Event()

    def create(self, *, identity):
        decoder = Decoder(**self.kwargs)
        self.sessions.append(decoder)
        self.created.set()
        return decoder


class Aligner:
    word_alignment_ready = True

    def __init__(self):
        self.calls = 0

    async def align(self, request):
        self.calls += 1
        raise RuntimeError("unavailable synthetic boundary")


def setup(**kwargs):
    factory, aligner = Factory(**kwargs), Aligner()
    services = build_app_services(
        Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            asr_revision_windows_enabled=True,
            realtime_vad_engine="legacy",
            qwen3_streaming_max_new_tokens=128,
        ),
        AppOverrides(window_asr_factory=factory, text_aligner=aligner),
    )
    candidate = MeetingCandidateSpec(
        implementation_id="synthetic-formal",
        adapter_sha256="a" * 64,
        sdk_revision="fixture",
        worker_sha256="b" * 64,
        model_revision="fixture",
        model_files_sha256={"weights.bin": "c" * 64},
        dtype="fixture",
        preset=realtime_replay_preset(services, language="Chinese"),
        compute_units="fixture",
        decoder={"max_tokens": 128, "timestamps": False},
        attribution={"algorithm": "none"},
        scorer=ASR_SCORER,
    )
    return services, factory, aligner, candidate


def case(samples=16001, reference="甲乙"):
    pcm = struct.pack(
        f"<{samples}h",
        *(round(20000 * math.sin(2 * math.pi * 220 * index / 16000)) for index in range(samples)),
    )
    return AsrCase("synthetic", "d" * 64, pcm, reference, "unambiguous")


def observe(candidate):
    return lambda: RuntimeObservation(candidate.as_dict(), "fake")


@pytest.mark.parametrize("samples", [1, 2, 3, 511, 512, 513, 16001])
@pytest.mark.parametrize("packet", [1, 37, 768])
def test_inverse_embedding_exactly_roundtrips_extremes_random_odd_and_flush(samples, packet):
    rng = random.Random(samples)
    values = ([32767, -32768, 0] + [rng.randrange(-32768, 32768) for _ in range(samples)])[:samples]
    pcm = struct.pack(f"<{samples}h", *values)
    wire = inverse_embed_pcm16(pcm)
    resampler = RationalResampler(24000, 16000)
    recovered = (
        b"".join(
            resampler.process(wire[i : i + packet * 2]) for i in range(0, len(wire), packet * 2)
        )
        + resampler.flush()
    )
    assert recovered == pcm


def test_formal_session_scores_only_sealed_body_checks_pcm_and_leaves_services_usable():
    async def scenario():
        services, factory, _, candidate = setup()
        original_factory = services.window_asr_factory
        data = case()
        result = await replay_realtime_session(
            data, candidate, services, observe=observe(candidate), wire_packet_samples=37
        )
        assert result["quality_evidence_valid"]
        assert result["metrics"]["normalized"]["cer"] == 0
        assert result["coverage_samples"] == result["expected_samples"] == 16001
        assert result["runtime_identity_verified"] is False
        assert result["certification_eligible"] is False
        assert result["a0_execution"] == "not_certified"
        assert result["diagnostics"]["session_policy_verified"] is True
        assert result["diagnostics"]["ingress"]["produced_wire_samples"] == 24001
        assert result["diagnostics"]["ingress"]["consumed_wire_samples"] == 24001
        assert services.window_asr_factory is original_factory
        assert factory.sessions[0].closed
        for request in factory.sessions[0].calls:
            assert (
                request.pcm16
                == data.pcm16[request.input_span.start * 2 : request.input_span.end * 2]
            )
            assert request.context == "" and request.language == "Chinese"
        serialized = json.dumps(result, ensure_ascii=False)
        assert "甲乙" not in serialized and "不评分的预览" not in serialized
        assert "base64" not in serialized and "/private" not in serialized
        other = original_factory.create(identity=factory.sessions[0].calls[0].identity)
        await other.close()
        assert len(factory.sessions) == 2
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith("formal-asr-")]

    asyncio.run(scenario())


@pytest.mark.parametrize("tail_samples", [1, 2, 3, 511, 512, 513])
@pytest.mark.parametrize("wire_packet", [37, 768])
def test_formal_decode_preserves_random_extreme_and_odd_pcm_through_wire_flush(
    tail_samples, wire_packet
):
    async def scenario():
        services, factory, _, candidate = setup()
        rng = random.Random(tail_samples)
        tail = ([32767, -32768] + [rng.randrange(-32768, 32768) for _ in range(tail_samples)])[
            :tail_samples
        ]
        data = replace(
            case(4096),
            pcm16=case(4096).pcm16
            + struct.pack(
                f"<{tail_samples}h",
                *tail,
            ),
        )
        result = await replay_realtime_session(
            data,
            candidate,
            services,
            observe=observe(candidate),
            wire_packet_samples=wire_packet,
        )
        assert result["quality_evidence_valid"]
        assert factory.sessions[0].calls
        assert (
            max(request.input_span.end for request in factory.sessions[0].calls)
            == 4096 + tail_samples
        )
        for request in factory.sessions[0].calls:
            assert (
                request.pcm16
                == data.pcm16[request.input_span.start * 2 : request.input_span.end * 2]
            )

    asyncio.run(scenario())


@pytest.mark.parametrize("change", ["window", "vad", "language", "context", "tokens", "timestamps"])
def test_actual_settings_and_frozen_session_policy_mismatch_fails_before_decode(change):
    async def scenario():
        services, factory, _, candidate = setup()
        preset, decoder = candidate.as_dict()["preset"], dict(candidate.decoder)
        if change == "window":
            preset["window_policy"]["owned_ms"] = 4000
        elif change in {"vad", "language", "context"}:
            preset[change] = "different"
        elif change == "tokens":
            decoder["max_tokens"] = 64
        else:
            decoder["timestamps"] = True
        frozen = replace(candidate, preset=preset, decoder=decoder)
        # Language is configurable; the recorded session must receive that language.
        if change in {"language", "tokens"}:
            result = await replay_realtime_session(
                case(), frozen, services, observe=observe(frozen)
            )
            assert result["diagnostics"]["session_policy_verified"]
            if change == "language":
                assert factory.sessions[0].calls[0].language == "different"
        else:
            with pytest.raises(ValueError):
                await replay_realtime_session(case(), frozen, services, observe=observe(frozen))
            assert not factory.sessions

    asyncio.run(scenario())


def test_actual_boundary_fallback_attempts_are_recorded_and_eos_proven():
    async def scenario():
        services, factory, aligner, candidate = setup()
        result = await replay_realtime_session(
            case(25 * 16000, "甲乙甲乙"), candidate, services, observe=observe(candidate)
        )
        assert aligner.calls > 0
        assert result["quality_evidence_valid"]
        assert result["actual_decode_calls"] == len(factory.sessions[0].calls)
        assert result["decode_evidence"]["attempts_with_unknown_limit"] == 0
        assert result["decode_evidence"]["token_limit_hit"] is False

    asyncio.run(scenario())


def test_queue_full_fails_without_drops_passing_and_joins_blocked_consumer(monkeypatch):
    original = OpenAIRealtimeSession.handle

    async def blocked(self, event, **kwargs):
        if event["type"] == "input_audio_buffer.append":
            await asyncio.Event().wait()
        return await original(self, event, **kwargs)

    monkeypatch.setattr(OpenAIRealtimeSession, "handle", blocked)

    async def scenario():
        services, factory, _, candidate = setup()
        result = await replay_realtime_session(
            case(), candidate, services, observe=observe(candidate), queue_capacity=1
        )
        assert not result["quality_evidence_valid"]
        assert "ingress_queue_full" in result["failures"]
        assert factory.sessions[0].closed
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith("formal-asr-")]

    asyncio.run(scenario())


@pytest.mark.parametrize("cancel", [False, True])
def test_timeout_or_cancellation_joins_inference_ingress_and_close(cancel):
    async def scenario():
        services, factory, _, candidate = setup(block=True)
        task = asyncio.create_task(
            replay_realtime_session(
                case(),
                candidate,
                services,
                observe=observe(candidate),
                total_timeout_seconds=0.05 if not cancel else 30,
                decode_timeout_seconds=0.2,
            )
        )
        if cancel:
            async with asyncio.timeout(2):
                await factory.created.wait()
                await factory.sessions[0].entered.wait()
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
        else:
            result = await task
            assert "replay_timeout" in result["failures"]
            assert not result["quality_evidence_valid"]
        assert factory.sessions[0].closed
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith("formal-asr-")]

    asyncio.run(scenario())


def test_paced_input_clock_advances_independently_and_never_claims_p95():
    async def scenario():
        services, _, _, candidate = setup()
        now, waits = [0.0], []

        async def pace(seconds):
            waits.append(seconds)
            now[0] += seconds
            await asyncio.sleep(0)

        result = await replay_realtime_session(
            case(),
            candidate,
            services,
            observe=observe(candidate),
            input_mode="realtime",
            clock=lambda: now[0],
            pace=pace,
        )
        assert sum(waits) == pytest.approx(24001 / 24000)
        assert result["diagnostics"]["input_clock"] == "injected"
        assert result["diagnostics"]["timing_scope"] == "diagnostic_not_capture_or_p95"

    asyncio.run(scenario())


def test_missing_decode_evidence_and_all_silence_do_not_pass():
    async def scenario():
        services, _, _, candidate = setup(observation=False)
        result = await replay_realtime_session(
            case(), candidate, services, observe=observe(candidate)
        )
        assert "decode_limit_not_observed" in result["failures"]
        silent = replace(case(), pcm16=bytes(16001 * 2))
        result = await replay_realtime_session(
            silent, candidate, services, observe=observe(candidate)
        )
        assert result["actual_decode_calls"] == 0
        assert result["coverage_samples"] == 16001
        assert not result["quality_evidence_valid"]

    asyncio.run(scenario())


@pytest.mark.parametrize("field", ["_start_frames", "_sample_rate", "_threshold"])
def test_real_effective_admission_drift_cannot_be_hidden_by_observer_or_echo(monkeypatch, field):
    from speechrail.application.realtime_asr import RealtimeAsrOwner

    original = RealtimeAsrOwner.apply_endpointing

    def drift(self, update):
        original(self, update)
        setattr(self._speech_admission, field, 999)

    monkeypatch.setattr(RealtimeAsrOwner, "apply_endpointing", drift)

    async def scenario():
        services, factory, _, candidate = setup()
        result = await replay_realtime_session(
            case(), candidate, services, observe=observe(candidate)
        )
        assert not result["diagnostics"]["session_policy_verified"]
        assert not result["quality_evidence_valid"]
        assert "replay_failed" in result["failures"]
        assert not factory.sessions[0].calls and factory.sessions[0].closed

    asyncio.run(scenario())


def test_window_attempt_budget_is_independent_of_streaming_factory_configuration():
    async def scenario():
        services, _, _, candidate = setup()
        services = replace(
            services,
            settings=services.settings.model_copy(
                update={
                    "qwen3_streaming_max_new_tokens": 2048,
                }
            ),
        )
        candidate = replace(candidate, decoder={"max_tokens": 64, "timestamps": False})
        result = await replay_realtime_session(
            case(), candidate, services, observe=observe(candidate)
        )
        assert result["quality_evidence_valid"]
        assert result["decode_evidence"]["frozen_token_cap"] == 64
        assert {row["decode_max_new_tokens"] for row in result["decode_evidence"]["attempts"]} == {
            32
        }
        assert result["diagnostics"]["window_decoder_config_cap"] == "not_observed"
        assert result["runtime_identity_verified"] is False

    asyncio.run(scenario())


@pytest.mark.parametrize("cap", [128, 512, True, "128"])
def test_formal_replay_freezes_observed_window_cap_or_refuses_mismatch(cap):
    async def scenario():
        services, factory, _, candidate = setup()
        factory.window_decode_max_new_tokens = cap
        if type(cap) is not int or cap != 128:
            with pytest.raises(ValueError, match="window cap"):
                await replay_realtime_session(
                    case(), candidate, services, observe=observe(candidate)
                )
            assert not factory.sessions
        else:
            result = await replay_realtime_session(
                case(), candidate, services, observe=observe(candidate)
            )
            assert result["quality_evidence_valid"]
            assert result["diagnostics"]["window_decoder_config_cap"] == 128
            assert result["diagnostics"]["decode_cap_origin"] == "ready_factory_observation"
            assert result["runtime_identity_verified"] is False

    asyncio.run(scenario())


def test_changed_ready_window_cap_invalidates_replay_evidence():
    async def scenario():
        services, factory, _, candidate = setup()
        factory.window_decode_max_new_tokens = 128
        calls = 0

        def observer():
            nonlocal calls
            calls += 1
            if calls == 2:
                factory.window_decode_max_new_tokens = 256
            return RuntimeObservation(candidate.as_dict(), "fake")

        result = await replay_realtime_session(case(), candidate, services, observe=observer)
        assert "implementation_or_configuration_changed" in result["failures"]
        assert not result["quality_evidence_valid"]

    asyncio.run(scenario())


def test_input_error_is_sanitized_and_all_tasks_joined():
    async def scenario():
        services, factory, _, candidate = setup()

        async def fail(seconds):
            raise RuntimeError("private transcript /private/model and raw audio")

        result = await replay_realtime_session(
            case(),
            candidate,
            services,
            observe=observe(candidate),
            input_mode="realtime",
            pace=fail,
        )
        assert "replay_failed" in result["failures"]
        assert not result["quality_evidence_valid"]
        assert result["diagnostics"]["ingress"]["all_tasks_joined"]
        assert result["diagnostics"]["ingress"]["session_closed"]
        assert factory.sessions[0].closed
        assert "private" not in json.dumps(result)

    asyncio.run(scenario())


def test_replay_policy_binds_implementation_mapping_configuration_and_input_mode():
    async def scenario():
        services, _, _, candidate = setup()
        one = await replay_realtime_session(case(), candidate, services, observe=observe(candidate))

        async def pace(seconds):
            await asyncio.sleep(0)

        two = await replay_realtime_session(
            case(),
            candidate,
            services,
            observe=observe(candidate),
            input_mode="realtime",
            pace=pace,
        )
        assert one["replay_policy_sha256"] != two["replay_policy_sha256"]
        sources = one["diagnostics"]["source_digests"]
        assert {
            "formal_replay",
            "backends/vad.py",
            "realtime/speech_admission.py",
            "application/asr_window_boundaries.py",
            "domain/audio_timeline.py",
        } <= sources.keys()
        assert all(len(value) == 64 for value in sources.values())
        assert "exact_inverse_embedding" in one["diagnostics"]["wire_mapping"]
        assert one["diagnostics"]["vad_input_domain"] == "kernel_pcm16_16000"

    asyncio.run(scenario())


def test_independent_input_clock_continues_while_consumer_is_blocked(monkeypatch):
    original = OpenAIRealtimeSession.handle

    async def scenario():
        services, _, _, candidate = setup()
        gate, produced = asyncio.Event(), asyncio.Event()
        now, appends = [0.0], [0]

        async def blocked(self, event, **kwargs):
            if event["type"] == "input_audio_buffer.append":
                appends[0] += 1
                await gate.wait()
            return await original(self, event, **kwargs)

        async def pace(seconds):
            now[0] += seconds
            if now[0] >= 1:
                produced.set()
            await asyncio.sleep(0)

        monkeypatch.setattr(OpenAIRealtimeSession, "handle", blocked)
        task = asyncio.create_task(
            replay_realtime_session(
                case(),
                candidate,
                services,
                observe=observe(candidate),
                input_mode="realtime",
                pace=pace,
                clock=lambda: now[0],
            )
        )
        try:
            async with asyncio.timeout(2):
                await produced.wait()
            assert appends[0] == 1
        finally:
            gate.set()
        result = await task
        assert result["quality_evidence_valid"]
        assert result["diagnostics"]["ingress"]["high_water_packets"] > 1

    asyncio.run(scenario())


@pytest.mark.parametrize("change", ["outcome", "overlap"])
def test_terminal_receiver_rejects_unknown_coverage_or_overlapping_final_units(change):
    async def scenario():
        event = {
            "type": "speechrail.transcription.window.sealed",
            "closed_span": {"start": 0, "end": 12},
            "coverage": [{"span": {"start": 0, "end": 12}, "outcome": "speech"}],
            "final_units": [
                {"owned_span": {"start": 0, "end": 6}, "text": "甲"},
                {"owned_span": {"start": 6, "end": 12}, "text": "乙"},
            ],
        }
        if change == "outcome":
            event["coverage"][0]["outcome"] = "unverified"
        else:
            event["final_units"][1]["owned_span"]["start"] = 3
        with pytest.raises(ValueError):
            await _Terminals(8, set()).send(event)

    asyncio.run(scenario())


def test_sealed_body_is_sorted_by_owned_sample_independently_of_wire_unit_order():
    async def scenario():
        receiver = _Terminals(8, set())
        await receiver.send(
            {
                "type": "speechrail.transcription.window.sealed",
                "closed_span": {"start": 0, "end": 12},
                "coverage": [{"span": {"start": 0, "end": 12}, "outcome": "speech"}],
                "final_units": [
                    {"owned_span": {"start": 6, "end": 12}, "text": "乙"},
                    {"owned_span": {"start": 0, "end": 6}, "text": "甲"},
                ],
            }
        )
        assert receiver.finals == ["甲", "乙"]

    asyncio.run(scenario())
