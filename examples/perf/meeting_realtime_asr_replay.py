"""Development replay through the actual OpenAIRealtimeSession owners.

The caller provides already-constructed, ready AppServices and frozen AsrCase /
candidate data. This library has no model-startup, installation or holdout CLI.
Only the window factory is decorated on a dataclasses.replace snapshot; shared
workers, governor, admission and lifecycle remain the caller's objects.

24 kHz wire audio uses an exact inverse-embedding for the current linear
24k-to-16k resampler: each 16 kHz pair (a,b) becomes (a,b,b), with an odd final
sample retained once. This is deliberately NOT acoustic resampling or real
24 kHz capture. Actual decode PCM is checked against the original 16 kHz case.
Production VAD, speech admission and boundary review operate after that same
production resampler. This version-bound diagnostic cannot certify actual A0,
runtime provenance, real capture latency or P95.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import math
import time
from collections.abc import AsyncGenerator, AsyncIterator, Awaitable, Callable, Coroutine, Iterator
from contextlib import aclosing
from dataclasses import replace
from pathlib import Path
from typing import Any, Literal, cast
from uuid import uuid4

from meeting_evaluation_identity import (
    MeetingCandidateSpec,
    canonical_digest,
    validate_execution_identity,
)
from meeting_pcm_feed import PcmChunk, PcmSequenceVerifier
from probe_meeting_asr_quality import (
    AsrCase,
    RuntimeObservation,
    _callback,
    _RecordedSession,
    _report,
    _settings,
    _validate_timeout,
)

import speechrail.application.realtime_asr as asr_module
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppServices
from speechrail.domain.asr_window import (
    WindowDecodeRequest,
    WindowDecodeResult,
    WindowIdentity,
    WindowPolicy,
)
from speechrail.domain.ports import WindowAsrFactory, WindowAsrSession
from speechrail.runtime.cleanup import join_cleanup

_ENDPOINTING: dict[str, object] = {
    "mode": "server_vad",
    "threshold": 0.5,
    "prefix_padding_ms": 300,
    "silence_duration_ms": 400,
}
_MAPPING = "exact_inverse_embedding_current_linear_resampler_v1"


def inverse_embed_pcm16(pcm16: bytes) -> bytes:
    """Losslessly embed 16 kHz pairs for this production resampler only.

    Pairwise blocks must start at an even kernel sample; only the final block
    may contain an odd count. Arbitrary wire packet splits are then safe.
    No signal processing or plausible 24 kHz reconstruction is claimed.
    """
    if not isinstance(pcm16, bytes) or len(pcm16) % 2:
        raise ValueError("embedding requires whole PCM16 samples")
    wire = bytearray()
    for offset in range(0, len(pcm16), 4):
        pair = pcm16[offset : offset + 4]
        wire.extend(pair)
        if len(pair) == 4:
            wire.extend(pair[2:])
    return bytes(wire)


def _vad_policy(services: AppServices) -> dict[str, object]:
    settings = services.settings
    return {
        "engine": "silero" if settings.resolves_to_silero_vad else "legacy",
        "speech_admission": settings.realtime_speech_admission_enabled,
        "shadow_enabled": settings.realtime_vad_shadow_enabled,
        # Bind configuration without disclosing an absolute private path.
        # This digest is not a claim about model-file contents or provenance.
        "configured_model_locator_sha256": canonical_digest(
            {
                "locator": str(settings.realtime_vad_model_path)
                if settings.realtime_vad_model_path is not None
                else None,
            }
        ),
        "endpointing": dict(_ENDPOINTING),
        "input_domain": "kernel_pcm16_16000",
    }


def realtime_replay_preset(services: AppServices, *, language: str | None = None) -> dict[str, Any]:
    """Freeze this diagnostic's actual settings before inspecting any output."""
    return {
        "window_policy": WindowPolicy.for_scene("meeting").to_wire_dict(),
        "vad": canonical_digest(_vad_policy(services)),
        "language": language,
        "context": "empty",
    }


class _SessionSlot:
    def __init__(self) -> None:
        self.inner: WindowAsrSession | None = None

    async def decode(self, request: WindowDecodeRequest) -> WindowDecodeResult:
        if self.inner is None:
            raise RuntimeError("window session has not been constructed")
        return await self.inner.decode(request)

    async def close(self) -> None:
        if self.inner is not None:
            await self.inner.close()


class _LanguageRecorder(_RecordedSession):
    language: str | None = None

    async def decode(self, request: WindowDecodeRequest) -> WindowDecodeResult:
        if request.language != self.language:
            self.failures.add("decode_language_mismatch")
            raise ValueError("decode differs from frozen language")
        return await super().decode(request)


class _RecordedFactory:
    def __init__(self, factory: WindowAsrFactory, recorder: _RecordedSession, slot: _SessionSlot):
        self.factory, self.recorder, self.slot = factory, recorder, slot

    @property
    def ready(self) -> bool:
        return getattr(self.factory, "ready", False) is True

    async def prepare(self) -> None:
        prepare = getattr(self.factory, "prepare", None)
        if prepare is not None:
            await prepare()

    def create(self, *, identity: WindowIdentity) -> WindowAsrSession:
        if self.slot.inner is not None:
            raise RuntimeError("diagnostic allows exactly one window session")
        self.slot.inner = self.factory.create(identity=identity)
        return self.recorder


class _IngressFullError(RuntimeError):
    pass


class _Terminals:
    """Consume events immediately; retain only bounded sealed body and counts."""

    def __init__(self, samples: int, failures: set[str]) -> None:
        self.samples, self.failures = samples, failures
        self.covered = self.sealed = self.events = self.text_length = 0
        self.finals: list[str] = []
        self.expected_session: dict[str, Any] | None = None
        self.session_policy_verified = False

    def _kernel(self, value: Any) -> int:
        if type(value) is not int or not 0 <= value <= self.samples * 3 // 2:
            raise ValueError("invalid wire boundary")
        kernel = (value * 2 + 2) // 3
        if value != kernel * 3 // 2:
            raise ValueError("wire boundary does not map to kernel samples")
        return kernel

    async def send(self, event: dict[str, Any]) -> int:
        self.events += 1
        if self.events > 65536:
            raise ValueError("diagnostic event count exceeded")
        kind = event.get("type")
        if kind == "session.updated":
            payload = event["session"]
            if self.expected_session is None or any(
                payload[key] != value for key, value in self.expected_session.items()
            ):
                raise ValueError("effective protocol session differs from frozen settings")
            self.session_policy_verified = True
        if kind == "error" or str(kind).endswith("transcription.failed"):
            self.failures.add("protocol_or_transcription_failed")
        if kind not in {
            "speechrail.transcription.window.sealed",
            "speechrail.transcription.window.failed",
        }:
            return self.events
        closed = event["closed_span"]
        start, end = self._kernel(closed["start"]), self._kernel(closed["end"])
        if start != self.sealed or end <= start:
            raise ValueError("terminal gap or duplicate")
        frontier = start
        for entry in event["coverage"]:
            left, right = self._kernel(entry["span"]["start"]), self._kernel(entry["span"]["end"])
            if left != frontier or not left < right <= end:
                raise ValueError("terminal coverage gap or duplicate")
            if entry["outcome"] not in {"speech", "silence", "failed"}:
                raise ValueError("unknown terminal coverage outcome")
            frontier = right
            if entry["outcome"] == "failed":
                self.failures.add("terminal_failed")
        if frontier != end:
            raise ValueError("terminal coverage does not cover closed span")
        if event.get("failed_items"):
            self.failures.add("terminal_failed")
        final_frontier = start
        for unit in sorted(
            event.get("final_units", []), key=lambda unit: unit["owned_span"]["start"]
        ):
            owned = unit["owned_span"]
            left, right = self._kernel(owned["start"]), self._kernel(owned["end"])
            if not final_frontier <= left < right <= end:
                raise ValueError("final unit overlaps or is outside terminal")
            final_frontier = right
            text = unit["text"]
            if not isinstance(text, str) or self.text_length + len(text) > 10000:
                raise ValueError("sealed text exceeds scoring bound")
            self.text_length += len(text)
            self.finals.append(text)
            if len(self.finals) > 4096:
                raise ValueError("sealed unit budget exceeded")
        self.covered += end - start
        self.sealed = end
        return self.events


def _packets(data: AsrCase, wire_packet_samples: int) -> Iterator[bytes]:
    # Fixed even source blocks keep conversion storage bounded to 24 KB.
    for start in range(0, len(data.pcm16), 16000):
        wire = inverse_embed_pcm16(data.pcm16[start : start + 16000])
        for offset in range(0, len(wire), wire_packet_samples * 2):
            yield wire[offset : offset + wire_packet_samples * 2]


async def _shared_packets(
    data: AsrCase,
    frames: AsyncIterator[PcmChunk],
    wire_packet_samples: int,
    verified: dict[str, int],
) -> AsyncGenerator[bytes]:
    """Keep one odd kernel sample across source boundaries for exact mapping."""
    carry = b""
    verifier = PcmSequenceVerifier(data.pcm16)
    try:
        async for frame in frames:
            verifier.accept(frame)
            verified.update(verifier.summary())
            block = carry + frame.pcm
            paired_bytes = len(block) // 4 * 4
            carry = block[paired_bytes:]
            wire = inverse_embed_pcm16(block[:paired_bytes])
            for offset in range(0, len(wire), wire_packet_samples * 2):
                yield wire[offset : offset + wire_packet_samples * 2]
        verifier.finish()
        if carry:
            yield inverse_embed_pcm16(carry)
    finally:
        close = getattr(frames, "aclose", None)
        if close is not None:
            await join_cleanup(asyncio.create_task(close(), name="formal-asr-source-close"))


def _failure_codes(error: BaseException) -> set[str]:
    if isinstance(error, BaseExceptionGroup):
        return set().union(*(_failure_codes(child) for child in error.exceptions))
    if isinstance(error, _IngressFullError):
        return {"ingress_queue_full"}
    if isinstance(error, TimeoutError):
        return {"replay_timeout"}
    return {"replay_failed"}


def _source_digests() -> dict[str, str]:
    root = Path(asr_module.__file__).parent.parent
    paths = {
        "formal_replay": Path(__file__),
        "shared_pcm_feed": Path(__file__).with_name("meeting_pcm_feed.py"),
        **{
            relative: root / relative
            for relative in (
                "application/realtime_openai.py",
                "application/realtime_asr.py",
                "application/asr_window_coordinator.py",
                "application/asr_window_boundaries.py",
                "application/services.py",
                "compatibility/openai_realtime.py",
                "backends/vad.py",
                "backends/neural_vad.py",
                "backends/qwen3_shared.py",
                "backends/qwen3_window.py",
                "backends/qwen3_worker.py",
                "realtime/speech_admission.py",
                "domain/audio_timeline.py",
                "domain/asr_window.py",
                "config/__init__.py",
            )
        },
    }
    return {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}


def _observed_window_cap(services: AppServices) -> int | None:
    cap = getattr(services.window_asr_factory, "window_decode_max_new_tokens", None)
    if cap is not None and (type(cap) is not int or not 32 <= cap <= 2048):
        raise ValueError("observed window cap must be an integer in 32–2048")
    return cap


def _configuration(services: AppServices) -> dict[str, object]:
    settings = services.settings
    return {
        "model_id": settings.model_id,
        "revision_windows_enabled": settings.asr_revision_windows_enabled,
        "vad": _vad_policy(services),
        "max_realtime_frame_bytes": settings.max_realtime_frame_bytes,
        "max_realtime_buffer_bytes": settings.max_realtime_buffer_bytes,
        "request_timeout_seconds": settings.request_timeout_seconds,
        # This is configuration only. The shared window owner's actual decoder
        # cap cannot be inferred from its streaming-factory configuration.
        "streaming_config_max_new_tokens_not_window_cap": settings.qwen3_streaming_max_new_tokens,
        "observed_window_decode_max_new_tokens": _observed_window_cap(services),
    }


def _effective_policy(
    session: OpenAIRealtimeSession,
    services: AppServices,
    policy: WindowPolicy,
    language: str | None,
) -> dict[str, object]:
    owner = session._asr_owner
    window, vad, admission = owner._window, owner._vad, owner._speech_admission
    if (
        window is None
        or window.policy != policy
        or window._language != language
        or window._context != ""
        or admission is None
        or vad is None
    ):
        raise ValueError("actual window/VAD/admission differs from frozen settings")
    config = vad._config
    observed = {
        "engine": "silero" if services.settings.resolves_to_silero_vad else "legacy",
        "threshold": config.threshold,
        "sample_rate": config.sample_rate,
        "frame_samples": config.frame_samples,
        "shadow_enabled": owner._shadow_vad is not None,
        "admission_threshold": admission.threshold,
        "admission_stop_threshold": admission.stop_threshold,
        "admission_start_frames": admission._start_frames,
        "admission_stop_frames": admission._stop_frames,
        "admission_prefix_frames": admission._max_prefix_frames,
        "admission_frame_samples": admission._frame_samples,
        "admission_sample_rate": admission._sample_rate,
    }
    expected = {
        "engine": _vad_policy(services)["engine"],
        "threshold": 0.5,
        "sample_rate": 16000,
        "frame_samples": 512,
        "shadow_enabled": services.settings.realtime_vad_shadow_enabled,
        "admission_threshold": 0.5,
        "admission_stop_threshold": 0.35,
        "admission_start_frames": 3,
        "admission_stop_frames": 13,
        "admission_prefix_frames": 10,
        "admission_frame_samples": 512,
        "admission_sample_rate": 16000,
    }
    engine_class = (
        ("speechrail.backends.neural_vad", "SileroVadDetector")
        if services.settings.resolves_to_silero_vad
        else ("speechrail.backends.vad", "VoiceActivityDetector")
    )
    if observed != expected or (type(vad).__module__, type(vad).__name__) != engine_class:
        raise ValueError("effective VAD/admission configuration differs from frozen policy")
    if not services.settings.resolves_to_silero_vad and (
        config.prefix_padding_ms != _ENDPOINTING["prefix_padding_ms"]
        or config.silence_duration_ms != _ENDPOINTING["silence_duration_ms"]
    ):
        raise ValueError("effective VAD boundary configuration differs from frozen policy")
    return observed


async def replay_realtime_session(
    data: AsrCase,
    spec: MeetingCandidateSpec,
    services: AppServices,
    *,
    observe: Callable[[], RuntimeObservation],
    input_mode: Literal["throughput", "realtime", "shared_pcm"] = "throughput",
    pcm_frames: AsyncIterator[PcmChunk] | None = None,
    wire_packet_samples: int = 2400,
    queue_capacity: int = 16,
    decode_timeout_seconds: float = 30,
    total_timeout_seconds: float = 900,
    pace: Callable[[float], Awaitable[None]] = asyncio.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    """Replay start/update/append/commit/close with bounded independent ingress.

    A full ingress queue fails the run; no frame is silently dropped or retried.
    TaskGroup joins producer and consumer on overflow, error, timeout and
    cancellation. Cancellation propagates only after production session cleanup.
    Observers must match the frozen spec before and after execution, but remain
    caller assertions: runtime_identity_verified/certification_eligible are false.
    Services must already be ready; update retains the production prepare path.
    """
    _validate_timeout(decode_timeout_seconds)
    if (
        type(total_timeout_seconds) not in {float, int}
        or not math.isfinite(total_timeout_seconds)
        or not 0 < total_timeout_seconds <= 1200
    ):
        raise ValueError("replay timeout must be finite and bounded to 1200 seconds")
    if type(wire_packet_samples) is not int or not 1 <= wire_packet_samples <= 24000:
        raise ValueError("wire packets must be bounded to one second")
    if type(queue_capacity) is not int or not 1 <= queue_capacity <= 64:
        raise ValueError("ingress capacity must be bounded to 1–64 packets")
    if input_mode not in {"throughput", "realtime", "shared_pcm"} or (
        (input_mode == "shared_pcm") != (pcm_frames is not None)
    ):
        raise ValueError("invalid input clock mode")
    policy, language = _settings(spec)
    if (
        spec.as_dict()["preset"] != realtime_replay_preset(services, language=language)
        or spec.decoder["timestamps"] is not False
        or not services.settings.realtime_speech_admission_enabled
    ):
        raise ValueError("frozen policy differs from actual service/session settings")
    if not services.revision_window_ready or services.window_asr_factory is None:
        raise ValueError("caller must supply an already-ready revision-window runtime")
    before = _callback(observe)
    validate_execution_identity(spec, before.identity)
    if not services.revision_window_ready:
        raise ValueError("runtime stopped during identity observation")
    observed_cap = _observed_window_cap(services)
    if observed_cap is not None and observed_cap != spec.decoder["max_tokens"]:
        raise ValueError("frozen decoder differs from observed ready window cap")
    source_digests = _source_digests()
    configuration = _configuration(services)
    slot = _SessionSlot()
    recorded = _LanguageRecorder(
        slot, data, decode_timeout_seconds, cast(int, spec.decoder["max_tokens"])
    )
    recorded.language = language
    decorated = replace(
        services,
        window_asr_factory=_RecordedFactory(
            services.window_asr_factory,
            recorded,
            slot,
        ),
    )
    terminals = _Terminals(len(data.pcm16) // 2, recorded.failures)
    session = OpenAIRealtimeSession(
        decorated, session_id="formal-asr-" + uuid4().hex, send=terminals.send
    )
    transcription: dict[str, object] = {"model": services.settings.model_id}
    if language is not None:
        transcription["language"] = language
    update: dict[str, Any] = {
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": 24000},
                    "transcription": transcription,
                    "turn_detection": None,
                }
            },
            "speechrail": {
                "task": "transcription",
                "window": {
                    "mode": "revision_window_v1",
                    "scene": "meeting",
                },
                "endpointing": dict(_ENDPOINTING),
            },
        },
    }
    terminals.expected_session = {
        "type": "transcription",
        "audio": update["session"]["audio"],
        "speechrail": {
            "task": "transcription",
            "tts": {"enabled": False},
            "alignment": {"enabled": False},
            "diarization": {"enabled": False},
            "endpointing": dict(_ENDPOINTING),
            "window": {
                "mode": "revision_window_v1",
                "scene": "meeting",
                "policy": policy.to_wire_dict(),
            },
        },
    }
    ingress: dict[str, Any] = {
        "capacity_packets": queue_capacity,
        "high_water_packets": 0,
        "produced_wire_samples": 0,
        "consumed_wire_samples": 0,
        "dropped_samples": 0,
        "all_tasks_joined": False,
        "session_closed": False,
    }
    queue: asyncio.Queue[bytes | None] = asyncio.Queue(queue_capacity)
    previous_clock: float | None = None
    shared_verified = {"frames_verified": 0, "samples_verified": 0}
    source_claimed = False

    def now() -> float:
        nonlocal previous_clock
        value = _callback(clock)
        if (
            type(value) not in {float, int}
            or not math.isfinite(value)
            or (previous_clock is not None and value < previous_clock)
        ):
            raise ValueError("input clock must be finite and monotonic")
        previous_clock = float(value)
        return float(value)

    def enqueue(packet: bytes) -> None:
        try:
            queue.put_nowait(packet)
        except asyncio.QueueFull:
            raise _IngressFullError("bounded replay ingress is full") from None
        ingress["produced_wire_samples"] += len(packet) // 2
        ingress["high_water_packets"] = max(ingress["high_water_packets"], queue.qsize())

    async def produce() -> None:
        nonlocal source_claimed
        if pcm_frames is not None:
            source_claimed = True
            async with aclosing(
                _shared_packets(data, pcm_frames, wire_packet_samples, shared_verified)
            ) as packets:
                async for packet in packets:
                    # A single source frame can contain many wire packets.
                    # Give the ready consumer one turn before treating a full
                    # queue as overload; never wait on put() or shift pacing.
                    if queue.full():
                        await asyncio.sleep(0)
                    enqueue(packet)
            await queue.put(None)
            return
        origin = now()
        scheduled = 0
        for packet in _packets(data, wire_packet_samples):
            scheduled += len(packet) // 2
            if input_mode == "realtime":
                await pace(max(0.0, origin + scheduled / 24000 - now()))
            else:
                await asyncio.sleep(0)
            enqueue(packet)
        await queue.put(None)

    async def consume() -> None:
        while (packet := await queue.get()) is not None:
            await session.handle(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(packet).decode("ascii"),
                }
            )
            ingress["consumed_wire_samples"] += len(packet) // 2
        await session.handle({"type": "input_audio_buffer.commit", "event_id": "formal-commit"})

    async def owned(target: Callable[[], Coroutine[Any, Any, None]], name: str) -> None:
        task = asyncio.create_task(target(), name=name + "-operation")
        try:
            await task
        except asyncio.CancelledError:
            current = asyncio.current_task()
            if current is not None and current.cancelling():
                raise
            raise RuntimeError("formal replay child cancelled itself") from None

    effective_policy: dict[str, object] | None = None
    try:
        async with asyncio.timeout(total_timeout_seconds):
            await session.start()
            await session.handle(update)
            effective_policy = _effective_policy(session, services, policy, language)
            if not terminals.session_policy_verified:
                raise ValueError("effective protocol session was not observed")
            async with asyncio.TaskGroup() as group:
                group.create_task(owned(produce, "formal-asr-producer"), name="formal-asr-producer")
                group.create_task(owned(consume, "formal-asr-consumer"), name="formal-asr-consumer")
            if (
                session._asr_owner._kernel_timeline.accepted_samples != len(data.pcm16) // 2
                or session._asr_owner.accepted_samples != len(data.pcm16) // 2 * 3 // 2
            ):
                recorded.failures.add("accepted_sample_mismatch")
    except Exception as error:
        recorded.failures.update(_failure_codes(error))
    finally:
        ingress["all_tasks_joined"] = True
        try:
            await join_cleanup(asyncio.create_task(session.close(), name="formal-asr-close"))
            ingress["session_closed"] = True
        except Exception:
            recorded.failures.add("session_cleanup_failed")
        while not queue.empty():
            queue.get_nowait()
        if pcm_frames is not None and not source_claimed:
            close_source = getattr(pcm_frames, "aclose", None)
            if close_source is not None:
                try:
                    await join_cleanup(
                        asyncio.create_task(close_source(), name="formal-asr-source-close")
                    )
                except Exception:
                    recorded.failures.add("source_cleanup_failed")
    after = _callback(observe)
    validate_execution_identity(spec, after.identity)
    if before.origin != after.origin:
        raise ValueError("execution evidence origin changed during replay")
    if ingress["produced_wire_samples"] != ingress["consumed_wire_samples"]:
        recorded.failures.add("ingress_not_fully_consumed")
    if _source_digests() != source_digests or _configuration(services) != configuration:
        recorded.failures.add("implementation_or_configuration_changed")
    result = _report(
        data,
        spec,
        recorded,
        after,
        text="".join(terminals.finals),
        coverage=terminals.covered,
        mode="formal_realtime_session_diagnostic",
        replay_policy={
            "wire_mapping": _MAPPING,
            "source_digests": source_digests,
            "configuration": configuration,
            "effective_policy": effective_policy,
            "wire_packet_samples": wire_packet_samples,
            "queue_capacity": queue_capacity,
            "input_mode": input_mode,
            "decode_timeout_seconds": decode_timeout_seconds,
            "total_timeout_seconds": total_timeout_seconds,
        },
        diagnostics={
            "session_policy_verified": terminals.session_policy_verified
            and effective_policy is not None,
            "effective_vad_admission": effective_policy,
            "configuration_sha256": canonical_digest(configuration),
            "decode_cap_origin": "ready_factory_observation"
            if observed_cap is not None
            else "frozen_caller_upper_bound_checked_per_attempt",
            "window_decoder_config_cap": observed_cap
            if observed_cap is not None
            else "not_observed",
            "cleanup_budget": "joined_production_close_may_wait_current_decode_timeout",
            "wire_mapping": _MAPPING,
            "source_digests": source_digests,
            "vad_input_domain": "kernel_pcm16_16000",
            "ingress": ingress,
            "shared_pcm": shared_verified if pcm_frames is not None else None,
            "input_clock": "external_shared_source_unverified"
            if pcm_frames is not None
            else "monotonic"
            if clock is time.monotonic
            else "injected",
            "input_mode": input_mode,
            "timing_scope": "diagnostic_not_capture_or_p95",
            "contextual_boundary_adapter": True,
        },
    )
    result["a0_execution"] = "not_certified"
    return result
