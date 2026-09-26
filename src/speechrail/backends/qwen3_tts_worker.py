"""Private, offline protocol host for one local Qwen3-TTS model process."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import math
import sys
import traceback
from collections import Counter, OrderedDict
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Literal, Protocol

from speechrail.backends.model_identity import inspect_model, read_quantization
from speechrail.backends.qwen3_native import snapshot_is_quantized
from speechrail.backends.qwen3_tts_stream_host import (
    FRAME_STREAM_DONE,
    FRAME_STREAM_ERROR,
    FRAME_STREAM_START,
    STREAM_FRAME_TYPES,
    TTS_STREAM_PROTOCOL_VERSION,
    IncrementalModelSession,
    StreamFrame,
    StreamPump,
    TtsStreamHost,
    parse_stream_command,
)
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.domain.tts import (
    VOICE_ID_RE,
    VoiceProfile,
    VoiceStoreUnavailableError,
    apply_crossfade,
    generation_token_budget,
    get_voice_profile,
    normalize_tts_text,
    resolve_voice,
)
from speechrail.domain.tts_errors import TTS_PARAMETER_ERROR_CODES
from speechrail.domain.tts_loudness import StreamingPcm16LoudnessController
from speechrail.domain.tts_request import validate_tts_parameters
from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    TtsStreamOptions,
)
from speechrail.domain.tts_text_planner import TtsTextPlanner
from speechrail.domain.tts_timing import TtsTimingChunk, TtsTimingSidecar
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

TTS_BACKEND_ID = "mlx-qwen3-tts"
_CLONE_LOUDNESS_CHUNK_MS = 200
# How long the model thread may wait for the parent to accept one output
# frame before the parent is treated as a stopped consumer.
_OUTPUT_SUBMIT_TIMEOUT_SECONDS: float = DEFAULT_TTS_STREAM_LIMITS.slow_consumer_seconds
_CLONE_TEMPERATURE = 0.1
_CLONE_TOP_P = 0.95


def _stable_worker_error_code(exc: BaseException) -> str:
    """Expose only an allowlisted semantic code over the private IPC frame."""

    code = str(exc).strip().splitlines()[0].strip()
    if code in TTS_PARAMETER_ERROR_CODES:
        return code
    return "worker_inference_error"


def _clone_generation_seed(*, voice: str, text: str, ref_text: str) -> int:
    """Derive a stable per-voice seed without retaining or logging request text."""

    del text
    material = "\x1f".join((voice, ref_text)).encode("utf-8")
    digest = hashlib.blake2s(material, digest_size=4).digest()
    return int.from_bytes(digest, "little")


def _seed_clone_generation(*, voice: str, text: str, ref_text: str) -> None:
    """Seed MLX's request-local sampling stream when the optional runtime exists."""

    try:
        import mlx.core as mx  # type: ignore[import-not-found]

        mx.random.seed(_clone_generation_seed(voice=voice, text=text, ref_text=ref_text))
    except Exception:
        # The worker still has to start in environments without the vendor runtime;
        # the production MLX path provides the deterministic seed operation.
        pass


def _clear_metal_cache() -> None:
    import gc
    try:
        import mlx.core as mx  # type: ignore[import-not-found]

        # Prefer the non-deprecated API; mx.metal.clear_cache is deprecated on mlx>=0.32.
        if hasattr(mx, "clear_cache"):
            mx.clear_cache()
        elif hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
            mx.metal.clear_cache()
    except Exception:
        pass
    gc.collect()


def _apply_metal_limits(cache_limit_mb: int = 256, memory_limit_mb: int = 0) -> None:
    try:
        import mlx.core as mx

        if cache_limit_mb > 0:
            if hasattr(mx, "metal") and hasattr(mx.metal, "set_cache_limit"):
                mx.metal.set_cache_limit(cache_limit_mb * 1024 * 1024)
            elif hasattr(mx, "set_cache_limit"):
                mx.set_cache_limit(cache_limit_mb * 1024 * 1024)
        if memory_limit_mb > 0:
            if hasattr(mx, "metal") and hasattr(mx.metal, "set_memory_limit"):
                mx.metal.set_memory_limit(memory_limit_mb * 1024 * 1024)
            elif hasattr(mx, "set_memory_limit"):
                mx.set_memory_limit(memory_limit_mb * 1024 * 1024)
    except Exception:
        pass


@dataclass(frozen=True, slots=True)
class TtsWorkerIdentity:
    device: str
    dtype: str
    sample_rate: int
    backend: str = TTS_BACKEND_ID
    family: str | None = None
    model_variant: str | None = None
    quantization_bits: int | None = None
    quantization_group_size: int | None = None
    weight_fingerprint: str | None = None


class TtsWorkerEngine(Protocol):
    identity: TtsWorkerIdentity

    def synthesize(
        self,
        text: str,
        *,
        voice: str,
        speed: float,
        language: str,
        instruction: str | None = None,
        seed: int | None = None,
        ref_audio: str | None = None,
        ref_text: str | None = None,
        profile: VoiceProfile | None = None,
    ) -> Iterator[bytes]: ...


EngineFactory = Callable[[Path], TtsWorkerEngine]
ModelLoader = Callable[[str], Any]
_MISSING = object()


def _loader_sources(model: object) -> tuple[object, ...]:
    model_config = getattr(model, "config", None)
    return (
        getattr(model, "model_info", None),
        model_config,
        model,
    )


def _loader_value(sources: tuple[object, ...], names: tuple[str, ...]) -> object:
    for source in sources:
        if source is None:
            continue
        for name in names:
            if isinstance(source, Mapping):
                value = source.get(name, _MISSING)
            else:
                value = getattr(source, name, _MISSING)
            if value is not _MISSING and value is not None:
                return value
    return _MISSING


def _loader_quantization(sources: tuple[object, ...]) -> QuantizationSpec | None:
    declarations: list[QuantizationSpec] = []
    for source in sources:
        if source is None:
            continue
        for field_name in ("quantization", "quantization_config"):
            if isinstance(source, Mapping):
                raw = source.get(field_name, _MISSING)
            else:
                raw = getattr(source, field_name, _MISSING)
            if raw is _MISSING or raw is None:
                continue
            if isinstance(raw, QuantizationSpec):
                declarations.append(raw)
            elif isinstance(raw, Mapping):
                declarations.append(read_quantization({field_name: raw}))
            else:
                raise RuntimeError("backend_identity_mismatch: invalid loader quantization")

        if isinstance(source, Mapping):
            bits = source.get("quantization_bits", _MISSING)
            group_size = source.get("quantization_group_size", _MISSING)
        else:
            bits = getattr(source, "quantization_bits", _MISSING)
            group_size = getattr(source, "quantization_group_size", _MISSING)
        if bits is not _MISSING or group_size is not _MISSING:
            declarations.append(
                read_quantization(
                    {
                        "quantization": {
                            "bits": None if bits is _MISSING else bits,
                            "group_size": None if group_size is _MISSING else group_size,
                        }
                    }
                )
            )

    if not declarations:
        return None
    first = declarations[0]
    if any(
        (item.bits, item.group_size) != (first.bits, first.group_size)
        for item in declarations[1:]
    ):
        raise RuntimeError("backend_identity_mismatch: loader quantization conflict")
    return first


def _identity_quantization(identity: object) -> tuple[int | None, int | None]:
    bits = getattr(identity, "quantization_bits", None)
    group_size = getattr(identity, "quantization_group_size", None)
    if bits is not None and (
        not isinstance(bits, int) or isinstance(bits, bool) or bits not in {4, 8}
    ):
        raise ValueError("invalid TTS worker quantization bits")
    if group_size is not None and (
        not isinstance(group_size, int) or isinstance(group_size, bool) or group_size <= 0
    ):
        raise ValueError("invalid TTS worker quantization group size")
    if bits is None and group_size is not None:
        raise ValueError("unquantized TTS worker cannot report group size")
    if bits is not None and group_size is None:
        raise ValueError("quantized TTS worker must report group size")
    return bits, group_size


def _expected_tts_dtype(model_dir: Path, device: str) -> str:
    """Return the dtype actually represented by the local TTS snapshot."""

    try:
        quantization = inspect_model(model_dir).quantization
    except Exception:
        return (
            "int8"
            if snapshot_is_quantized(model_dir)
            else ("float16" if device == "mps" else "float32")
        )
    if quantization.bits is not None:
        return "int8"
    if quantization.dtype in {"bf16", "bfloat16"}:
        return "bfloat16"
    return "float16" if device == "mps" else "float32"


def _identity_matches_tts(
    identity: object, *, device: str, sample_rate: int, model_dir: Path
) -> bool:
    try:
        bits, _ = _identity_quantization(identity)
    except ValueError:
        return False
    family = getattr(identity, "family", None)
    variant = getattr(identity, "model_variant", None)
    if family is not None and family != "qwen3_tts":
        return False
    if variant is not None and variant not in {"voice_design", "custom_voice", "base"}:
        return False
    expected_dtype = (
        "int8" if bits is not None else _expected_tts_dtype(model_dir, device)
    )
    return (
        getattr(identity, "device", None) == device
        and getattr(identity, "dtype", None) == expected_dtype
        and getattr(identity, "sample_rate", None) == sample_rate
    )


def _ready_identity_fields(identity: object) -> dict[str, object]:
    fields: dict[str, object] = {}
    for attribute in (
        "family",
        "model_variant",
        "quantization_bits",
        "quantization_group_size",
        "weight_fingerprint",
    ):
        value = getattr(identity, attribute, None)
        if value is not None:
            fields[attribute] = value
    return fields


def generation_condition(
    variant: str, voice: str, *, instruction: str | None = None,
    profile: VoiceProfile | None = None,
) -> dict[str, object]:
    """根据模型变体解析生成条件 (音色或提示词指令)。"""

    if instruction is not None:
        if variant != "voice_design":
            raise ValueError("voice preview requires voice_design variant")
        normalized = instruction.strip()
        if not normalized:
            raise ValueError("voice preview instruction must not be blank")
        return {"instruct": normalized}

    try:
        binding = resolve_binding(variant, voice, profile=profile)
    except ValueError as exc:
        raise ValueError(f"unsupported voice or variant: {voice}") from exc
    condition: dict[str, object] = {"voice": binding.speaker}
    if binding.instruction is not None:
        condition["instruct"] = binding.instruction
    return condition


class MlxQwenTtsEngine:  # pragma: no cover - requires separately authorized model runtime.
    """MLX Qwen3-TTS engine isolated in the worker process."""

    def __init__(
        self,
        model_dir: Path,
        *,
        device: Literal["mps", "cpu"],
        sample_rate: int = 24_000,
        chunk_ms: int = 100,
        repetition_penalty: float = 1.25,
        temperature: float = 0.85,
        top_p: float = 0.95,
        load_fn: ModelLoader | None = None,
        numpy_module: Any | None = None,
        audio_loader_fn: Any | None = None,
        reference_cache_entries: int = 2,
        warmup: bool = True,
    ) -> None:
        expected = inspect_model(model_dir)
        if expected.family != "qwen3_tts" or expected.variant not in (
            "voice_design",
            "custom_voice",
            "base",
        ):
            raise RuntimeError("backend_identity_mismatch: unsupported TTS snapshot identity")
        try:
            if load_fn is None:
                from mlx_audio.tts.utils import load  # type: ignore[import-not-found]

                load_fn = load
            self._numpy = numpy_module or __import__("numpy")
            self._model = load_fn(str(model_dir))
        except Exception as exc:
            raise RuntimeError("mlx_qwen3_tts_runtime_unavailable") from exc
        if audio_loader_fn is None:
            try:
                mod = __import__(
                    "mlx_audio.tts.models.qwen3_tts.qwen3_tts",
                    fromlist=["load_audio"],
                )
                audio_loader_fn = getattr(mod, "load_audio", None)
            except Exception:
                pass
        self._audio_loader_fn = audio_loader_fn
        model_type = getattr(getattr(self._model, "config", None), "tts_model_type", None)
        if model_type is not None and model_type != expected.variant:
            raise RuntimeError("backend_identity_mismatch: loader variant mismatch")
        loader_sources = _loader_sources(self._model)
        loaded_family = _loader_value(loader_sources, ("family", "model_type"))
        if loaded_family is not _MISSING and loaded_family != expected.family:
            raise RuntimeError("backend_identity_mismatch: loader family mismatch")
        loaded_quantization = _loader_quantization(loader_sources)
        if loaded_quantization is not None and (
            loaded_quantization.bits,
            loaded_quantization.group_size,
        ) != (expected.quantization.bits, expected.quantization.group_size):
            raise RuntimeError("backend_identity_mismatch: loader quantization mismatch")
        if sample_rate != 24_000:
            raise RuntimeError("qwen3_tts_output_invalid")
        if chunk_ms <= 0:
            raise ValueError("chunk_ms must be positive")
        if not 0 <= reference_cache_entries <= 8:
            raise ValueError("reference_cache_entries must be between 0 and 8")
        self._sample_rate = sample_rate
        self._chunk_ms = chunk_ms
        self._repetition_penalty = repetition_penalty
        self._temperature = temperature
        self._top_p = top_p
        # ICL reference arrays are sensitive and may be sizeable. They stay
        # only in this worker process, have a tiny LRU bound, and invalidate
        # whenever the source file identity changes.
        self._reference_cache_entries = reference_cache_entries
        self._reference_audio_cache: OrderedDict[tuple[str, int, int], Any] = OrderedDict()
        self._delivery_stats: Counter[str] = Counter()
        self._last_timing_sidecar: dict[str, object] | None = None
        # Pre-quantized snapshots keep an int8 backbone; codec/embeddings stay bf16.
        self.identity = TtsWorkerIdentity(
            device=device,
            dtype=_expected_tts_dtype(model_dir, device),
            sample_rate=sample_rate,
            family=expected.family,
            model_variant=expected.variant,
            quantization_bits=expected.quantization.bits,
            quantization_group_size=expected.quantization.group_size,
            weight_fingerprint=expected.weight_fingerprint,
        )
        # Base is clone-only: it has no system speaker that can be used for a
        # generic warmup.  Calling the shared default-voice path here makes the
        # worker fail before it can accept a legitimate ref_audio/ref_text
        # request.  Model loading and identity validation above are the safe
        # Base startup warmup; the first legal clone request performs acoustic
        # initialization.
        if warmup and expected.variant != "base":
            for _ in self._generate("预热。", voice="default", speed=1.0, language="auto"):
                pass
            self.consume_delivery_stats()

    def synthesize(
        self,
        text: str,
        *,
        voice: str,
        speed: float,
        language: str,
        instruction: str | None = None,
        seed: int | None = None,
        ref_audio: str | None = None,
        ref_text: str | None = None,
        profile: VoiceProfile | None = None,
    ) -> Iterator[bytes]:
        self._last_timing_sidecar = None
        clean_text = normalize_tts_text(text)
        if not clean_text:
            return
        if profile is None and instruction is None and ref_audio is None and ref_text is None:
            # Legacy private callers still receive one request-local recipe, never
            # a fresh registry resolution for each acoustic chunk.
            profile = get_voice_profile(voice)
        first_chunk = True
        loudness_controller = (
            StreamingPcm16LoudnessController(
                sample_rate=self._sample_rate,
                freeze_gain_after_calibration=True,
            )
            if ref_audio is not None or ref_text is not None
            else None
        )
        pending_clone_pcm = bytearray()
        clone_chunk_bytes = self._sample_rate * _CLONE_LOUDNESS_CHUNK_MS // 1000 * 2

        def prepare_output(pcm: bytes) -> bytes:
            nonlocal first_chunk
            if first_chunk:
                pcm = apply_crossfade(
                    pcm,
                    sample_rate=self._sample_rate,
                    fade_ms=5,
                    fade_in=True,
                    fade_out=False,
                )
                first_chunk = False
            return pcm

        plan = TtsTextPlanner().plan(clean_text)
        timing_chunks: list[TtsTimingChunk] = []
        source_sample_cursor = 0
        emitted_samples = 0
        try:
            for planned_chunk in plan.chunks:
                self._delivery_stats["planner_chunks"] += 1
                chunk_start_sample = source_sample_cursor
                for pcm in self._generate(
                    planned_chunk.spoken_text,
                    voice=voice,
                    speed=speed,
                    language=language,
                    instruction=instruction,
                    seed=seed,
                    ref_audio=ref_audio,
                    ref_text=ref_text,
                    profile=profile,
                ):
                    if not pcm:
                        continue
                    source_sample_cursor += len(pcm) // 2
                    if loudness_controller is not None:
                        pending_clone_pcm.extend(pcm)
                        while len(pending_clone_pcm) >= clone_chunk_bytes:
                            clone_pcm = bytes(pending_clone_pcm[:clone_chunk_bytes])
                            del pending_clone_pcm[:clone_chunk_bytes]
                            clone_pcm = loudness_controller.process(clone_pcm)
                            if clone_pcm:
                                output = prepare_output(clone_pcm)
                                emitted_samples += len(output) // 2
                                yield output
                        continue
                    output = prepare_output(pcm)
                    emitted_samples += len(output) // 2
                    yield output
                timing_chunks.append(
                    TtsTimingChunk(
                        planner_chunk=planned_chunk.index,
                        text_start=planned_chunk.source_start,
                        text_end=planned_chunk.source_end,
                        audio_start_sample=chunk_start_sample,
                        audio_end_sample=source_sample_cursor,
                    )
                )
            if loudness_controller is not None and pending_clone_pcm:
                clone_pcm = loudness_controller.process(bytes(pending_clone_pcm))
                if clone_pcm:
                    output = prepare_output(clone_pcm)
                    emitted_samples += len(output) // 2
                    yield output
            if emitted_samples != source_sample_cursor:
                raise RuntimeError("tts_timing_sample_mismatch")
            self._last_timing_sidecar = TtsTimingSidecar(
                sample_rate=self._sample_rate,
                text_length=len(clean_text),
                total_samples=emitted_samples,
                chunks=tuple(timing_chunks),
            ).model_dump(mode="json")
        finally:
            if loudness_controller is not None:
                self._delivery_stats["clone_loudness_requests"] += 1
                consume_stats = getattr(loudness_controller, "consume_stats", None)
                stats = consume_stats() if callable(consume_stats) else {}
                if isinstance(stats, dict):
                    if stats.get("calibrated"):
                        self._delivery_stats["clone_loudness_calibrated"] += 1
                    peak_count = stats.get("peak_ceiling")
                    if isinstance(peak_count, int) and peak_count > 0:
                        self._delivery_stats["clone_loudness_peak_ceiling"] += peak_count
                loudness_controller.reset()

    def _generate(
        self,
        text: str,
        *,
        voice: str,
        speed: float,
        language: str,
        instruction: str | None = None,
        seed: int | None = None,
        ref_audio: str | None = None,
        ref_text: str | None = None,
        profile: VoiceProfile | None = None,
    ) -> Iterator[bytes]:
        variant = self.identity.model_variant or "voice_design"
        is_clone = ref_audio is not None or ref_text is not None
        validated = validate_tts_parameters(
            model_variant=variant,  # type: ignore[arg-type]
            is_clone=is_clone,
            speed=speed,
            language=language,
            instruction=instruction,
            seed=seed,
        )
        speed = validated.speed
        language = validated.language
        if ref_audio is not None or ref_text is not None:
            # The Base reference-clone contract accepts neither SpeechRail speaking-rate
            # controls nor VoiceDesign instructions. Reject them at the adapter
            # boundary so a successful response never hides an ignored option.
            if speed != 1.0:
                raise ValueError("clone_speed_unsupported")
            if instruction is not None:
                raise ValueError("clone_instruction_unsupported")
            if seed is not None:
                raise ValueError("clone_seed_unsupported")
            if not ref_audio:
                raise RuntimeError("failed to load reference audio: file missing")
            if ref_text is None or not ref_text.strip():
                raise RuntimeError("failed to load reference text: text missing")
            if self._audio_loader_fn is None:
                raise RuntimeError("mlx_qwen3_tts_audio_loader_unavailable")
            audio_array = self._load_reference_audio(ref_audio)
            if variant != "base":
                raise RuntimeError("voice_clone_requires_base_model")

            _seed_clone_generation(voice=voice, text=text, ref_text=ref_text)

            for result in self._model.generate(
                text=text,
                ref_audio=audio_array,
                ref_text=ref_text,
                lang_code=language,
                max_tokens=generation_token_budget(text),
                stream=True,
                streaming_interval=self._chunk_ms / 1000,
                temperature=_CLONE_TEMPERATURE,
                top_p=_CLONE_TOP_P,
                repetition_penalty=max(self._repetition_penalty, 1.5),
            ):
                pcm = self._to_pcm(result)
                if pcm:
                    yield pcm
            return

        if variant == "custom_voice" and seed is not None:
            raise ValueError("custom_voice_seed_unsupported")
        if profile is None and instruction is None and variant == "voice_design":
            profile = get_voice_profile(voice)
        condition = generation_condition(variant, voice, instruction=instruction, profile=profile)
        used_temperature = self._temperature
        if variant == "voice_design":
            if instruction is None:
                if seed is not None:
                    raise ValueError("voice_design_seed_requires_instruction")
                assert profile is not None
                used_temperature = profile.temperature
                seed = profile.seed
            try:
                import mlx.core as mx  # type: ignore[import-not-found]

                if seed is not None:
                    mx.random.seed(seed)
            except Exception:
                pass
        call_kwargs: dict[str, object] = {
            "text": text,
            "speed": speed,
            "lang_code": language,
            "max_tokens": generation_token_budget(text),
            "repetition_penalty": self._repetition_penalty,
            "temperature": used_temperature,
            "top_p": self._top_p,
            "stream": True,
            "streaming_interval": self._chunk_ms / 1000,
        }
        if "voice" in condition:
            call_kwargs["voice"] = condition["voice"]
        if "instruct" in condition:
            call_kwargs["instruct"] = condition["instruct"]
        for result in self._model.generate(**call_kwargs):
            pcm = self._to_pcm(result)
            if pcm:
                yield pcm

    def open_incremental_session(
        self,
        *,
        voice: str,
        speed: float,
        language: str,
        instruction: str | None = None,
        seed: int | None = None,
        ref_audio: str | None = None,
        ref_text: str | None = None,
        profile: VoiceProfile | None = None,
    ) -> IncrementalModelSession:
        """Open one append-only generation on this process's single MLX model.

        Conditioning is frozen exactly like ``_generate``: CustomVoice resolves a
        verified speaker, Base resolves a clone reference, and VoiceDesign stays
        fail-closed because its instruction path has no verified incremental role.
        """

        from speechrail.backends.qwen3_tts_incremental import (
            open_vendor_incremental_session,
        )
        from speechrail.domain.tts_stream import TtsStreamError

        variant = self.identity.model_variant or "voice_design"
        is_clone = ref_audio is not None or ref_text is not None
        if variant not in {"custom_voice", "base"}:
            raise TtsStreamError(
                "tts_streaming_unsupported",
                "the voice design variant has no incremental generation path",
            )
        if variant == "base" and not is_clone:
            raise TtsStreamError(
                "tts_streaming_unsupported",
                "the base variant requires a clone reference for incremental generation",
            )
        validated = validate_tts_parameters(
            model_variant=variant,  # type: ignore[arg-type]
            is_clone=is_clone,
            speed=speed,
            language=language,
            instruction=instruction,
            seed=seed,
        )
        if is_clone:
            if not ref_audio:
                raise RuntimeError("failed to load reference audio: file missing")
            if ref_text is None or not ref_text.strip():
                raise RuntimeError("failed to load reference text: text missing")
            audio_array = self._load_reference_audio(ref_audio)
            # The append-only path cannot know the full text at seed time, so the
            # reference-derived seed keeps one clone voice stable across requests.
            _seed_clone_generation(voice=voice, text="", ref_text=ref_text)
            return open_vendor_incremental_session(
                self._model,
                variant="base",
                language=validated.language,
                ref_audio=audio_array,
                ref_text=ref_text,
            )
        if profile is None and instruction is None:
            profile = get_voice_profile(voice)
        condition = generation_condition(
            "custom_voice", voice, instruction=instruction, profile=profile
        )
        speaker = condition.get("voice")
        if not isinstance(speaker, str) or not speaker:
            raise TtsStreamError(
                "tts_streaming_unsupported",
                "the resolved voice has no verified custom speaker",
            )
        return open_vendor_incremental_session(
            self._model,
            variant="custom_voice",
            speaker=speaker,
            language=validated.language,
        )

    def _load_reference_audio(self, ref_audio: str) -> Any:
        """Read one local ICL reference with bounded, revision-aware caching."""

        path = Path(ref_audio)
        try:
            resolved = path.resolve(strict=True)
            stat = resolved.stat()
        except OSError as exc:
            raise RuntimeError("failed to load reference audio: file missing") from exc
        if not resolved.is_file():
            raise RuntimeError("failed to load reference audio: file missing")

        key = (str(resolved), stat.st_mtime_ns, stat.st_size)
        cached = self._reference_audio_cache.get(key)
        if cached is not None:
            self._delivery_stats["reference_cache_hits"] += 1
            self._reference_audio_cache.move_to_end(key)
            return cached
        if self._reference_cache_entries:
            self._delivery_stats["reference_cache_misses"] += 1

        # A profile may be replaced in place. Drop every obsolete generation
        # of this path before loading the new one, rather than retaining its
        # decoded voice reference until ordinary LRU eviction.
        for stale_key in tuple(self._reference_audio_cache):
            if stale_key[0] == key[0]:
                del self._reference_audio_cache[stale_key]
                self._delivery_stats["reference_cache_evictions"] += 1
        loader = self._audio_loader_fn
        if loader is None:
            raise RuntimeError("mlx_qwen3_tts_audio_loader_unavailable")
        try:
            audio_array = loader(
                str(resolved),
                sample_rate=self._sample_rate,
                volume_normalize=False,
            )
        except Exception as exc:
            raise RuntimeError(f"failed to decode reference audio: {exc}") from exc
        if audio_array is None or getattr(audio_array, "size", 1) == 0:
            raise RuntimeError("failed to decode reference audio: empty array")

        if self._reference_cache_entries:
            self._reference_audio_cache[key] = audio_array
            self._reference_audio_cache.move_to_end(key)
            while len(self._reference_audio_cache) > self._reference_cache_entries:
                self._reference_audio_cache.popitem(last=False)
                self._delivery_stats["reference_cache_evictions"] += 1
        return audio_array

    def consume_timing_sidecar(self) -> dict[str, object] | None:
        """Return the completed request timing metadata exactly once."""

        sidecar = self._last_timing_sidecar
        self._last_timing_sidecar = None
        return dict(sidecar) if sidecar is not None else None

    def consume_delivery_stats(self) -> dict[str, int]:
        """Return per-request aggregate delivery counters and reset them."""
        result = {
            name: count
            for name in (
                "planner_chunks",
                "reference_cache_hits",
                "reference_cache_misses",
                "reference_cache_evictions",
                "clone_loudness_requests",
                "clone_loudness_calibrated",
                "clone_loudness_peak_ceiling",
                "float_overrange_chunks",
            )
            if (count := int(self._delivery_stats.get(name, 0))) > 0
        }
        self._delivery_stats.clear()
        return result

    def _to_pcm(self, result: Any) -> bytes:
        result_sample_rate = int(result.sample_rate)
        if result_sample_rate != self._sample_rate:
            raise RuntimeError("qwen3_tts_output_invalid_sample_rate")
        samples = self._numpy.asarray(result.audio, dtype=self._numpy.float32).reshape(-1).copy()
        if samples.size == 0:
            return b""
        finite = self._numpy.isfinite(samples)
        if bool(self._numpy.any(finite & (self._numpy.abs(samples) > 1.0))):
            # Diagnostic only: PCM16 quantization below is still the established
            # contract. Real-model evidence decides whether protection must move
            # into the float domain before any future acoustic behavior change.
            self._delivery_stats["float_overrange_chunks"] += 1
        samples = self._numpy.nan_to_num(samples, nan=0.0, posinf=1.0, neginf=-1.0)
        if bool(getattr(result, "is_final_chunk", False)):
            non_silent = self._numpy.flatnonzero(self._numpy.abs(samples) > 1e-3)
            if non_silent.size == 0:
                return b""
            keep_samples = self._sample_rate * 100 // 1000
            end = min(samples.size, int(non_silent[-1]) + 1 + keep_samples)
            samples = samples[:end]
            fade_len = min(samples.size, self._sample_rate * 5 // 1000)
            if fade_len > 0:
                fade_curve = self._numpy.linspace(1.0, 0.0, fade_len, dtype=self._numpy.float32)
                samples[-fade_len:] *= fade_curve
        return bytes(
            self._numpy.clip(samples * 32767.0, -32768.0, 32767.0).astype("<i2").tobytes()
        )


MlxVoiceDesignEngine = MlxQwenTtsEngine


def _default_engine_factory(  # pragma: no cover - requires separately authorized model runtime.
    device: Literal["mps", "cpu"],
    *,
    sample_rate: int,
    chunk_ms: int,
    repetition_penalty: float,
    temperature: float,
    top_p: float,
    warmup: bool,
) -> EngineFactory:
    return lambda model_dir: MlxQwenTtsEngine(
        model_dir,
        device=device,
        sample_rate=sample_rate,
        chunk_ms=chunk_ms,
        repetition_penalty=repetition_penalty,
        temperature=temperature,
        top_p=top_p,
        warmup=warmup,
    )


def serve(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    model_dir: Path,
    device: Literal["mps", "cpu"],
    sample_rate: int,
    engine_factory: EngineFactory,
) -> None:
    """Serve only framed local IPC; no request can select a model or URL.

    This function's thread is the single owner of MLX state.  A reader thread
    decodes commands into a bounded queue and a writer thread owns stdout, so
    appending text or cancelling still works while the model is mid-step and a
    parent that stops reading can never wedge inference.
    """
    start = read_frame(input_stream)
    if (
        start is None
        or start.get("version") != PROTOCOL_VERSION
        or start.get("type") != "start"
        or start.get("model_dir") != str(model_dir)
        or start.get("device") != device
        or start.get("sample_rate") != sample_rate
    ):
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_start"},
        )
        return
    try:
        engine = engine_factory(model_dir)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_load_error"},
        )
        return
    identity = engine.identity
    if not _identity_matches_tts(
        identity, device=device, sample_rate=sample_rate, model_dir=model_dir
    ):
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "backend_identity_mismatch"},
        )
        return
    opener = getattr(engine, "open_incremental_session", None)
    ready: dict[str, object] = {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "backend": identity.backend,
        "device": identity.device,
        "dtype": identity.dtype,
        "sample_rate": identity.sample_rate,
        "model_loaded": True,
        "profile_snapshot_version": 1,
    }
    if callable(opener):
        # Negotiated per transport instead of bumping the shared ASR/TTS
        # protocol number, which producers and consumers pin together.
        ready["tts_stream_protocol"] = TTS_STREAM_PROTOCOL_VERSION
    ready.update(_ready_identity_fields(identity))
    write_frame(output_stream, ready)

    pump = StreamPump(input_stream, output_stream)
    pump.start()
    try:
        _serve_frames(pump, engine, opener if callable(opener) else None)
    finally:
        pump.stop()


class _OutputClosedError(RuntimeError):
    """The parent stopped reading this worker's stdout."""


def _emit(
    pump: StreamPump,
    payload: dict[str, object],
    binary: bytes | None = None,
    *,
    on_sent: Callable[[], None] | None = None,
    timeout: float = _OUTPUT_SUBMIT_TIMEOUT_SECONDS,
) -> None:
    frame = StreamFrame(payload, binary=binary, on_sent=on_sent)
    if _bypasses_audio_queue(payload):
        submitted = pump.submit_terminal(frame)
    else:
        submitted = pump.submit(frame, timeout=timeout)
    if not submitted:
        raise _OutputClosedError("the parent stopped reading worker output")


def _bypasses_audio_queue(payload: dict[str, object]) -> bool:
    """Whether one frame must not wait behind its own queued PCM.

    Cancellation and unrecoverable failure end the utterance: their terminal has
    to leave even when the caller stopped draining audio.  A normal ``completed``
    terminal deliberately stays in order behind the tail PCM it still owns.
    """

    frame_type = payload.get("type")
    if frame_type == FRAME_STREAM_ERROR and payload.get("terminal") is True:
        return True
    return frame_type == FRAME_STREAM_DONE and payload.get("terminal") == "cancelled"


def _emit_frame(pump: StreamPump, frame: StreamFrame) -> None:
    """Forward a host frame verbatim, keeping its delivery callback.

    Audio frames retire the pending-audio budget through ``on_sent`` once the
    writer really put them on the wire.  Rebuilding the frame without that
    callback leaks the budget and turns a healthy stream into
    ``tts_backpressure``.
    """

    _emit(pump, frame.payload, frame.binary, on_sent=frame.on_sent)


def _emit_best_effort(
    pump: StreamPump, payload: dict[str, object], binary: bytes | None = None
) -> None:
    with contextlib.suppress(_OutputClosedError):
        _emit(pump, payload, binary)


def _emit_frame_best_effort(pump: StreamPump, frame: StreamFrame) -> None:
    with contextlib.suppress(_OutputClosedError):
        _emit_frame(pump, frame)


def _worker_error_frame(
    request_id: str | None, code: str, *, version: int = PROTOCOL_VERSION
) -> dict[str, object]:
    return {
        "version": version,
        "type": "error",
        "code": code,
        "request_id": request_id,
    }


def _stream_error_frame(
    request_id: str | None,
    code: str,
    *,
    terminal: bool,
    sequence: int | None = None,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "version": PROTOCOL_VERSION,
        "type": FRAME_STREAM_ERROR,
        "request_id": request_id,
        "code": code,
        "terminal": terminal,
    }
    if sequence is not None:
        payload["sequence"] = sequence
    return payload


def _serve_frames(
    pump: StreamPump,
    engine: TtsWorkerEngine,
    opener: Callable[..., IncrementalModelSession] | None,
) -> None:
    """The model loop: one frame at a time, one utterance at a time."""

    while True:
        frame = pump.poll(timeout=None)
        if frame is None:
            if pump.read_error is not None:
                traceback.print_exception(pump.read_error, file=sys.stderr)
            return
        try:
            _dispatch_frame(pump, engine, opener, frame)
        except _OutputClosedError:
            return


def _dispatch_frame(
    pump: StreamPump,
    engine: TtsWorkerEngine,
    opener: Callable[..., IncrementalModelSession] | None,
    frame: dict[str, object],
) -> None:
    frame_type = frame.get("type")
    if frame_type == "trim_memory":
        # Fire-and-forget: no confirmation frame so the framing of the next
        # response is never pushed out of alignment.
        _clear_metal_cache()
        return
    if frame_type in STREAM_FRAME_TYPES:
        if opener is None:
            request_id = frame.get("request_id")
            _emit(
                pump,
                _stream_error_frame(
                    request_id if isinstance(request_id, str) else None,
                    "tts_streaming_unsupported",
                    terminal=True,
                ),
            )
            return
        if frame_type != FRAME_STREAM_START:
            request_id = frame.get("request_id")
            _emit(
                pump,
                _stream_error_frame(
                    request_id if isinstance(request_id, str) else None,
                    "tts_input_closed",
                    terminal=False,
                ),
            )
            return
        _run_stream(pump, opener, frame)
        return
    _run_synthesize(pump, engine, frame)


def _open_stream_session(
    opener: Callable[..., IncrementalModelSession],
    fields: _SynthesisFields,
    frame: dict[str, object],
) -> IncrementalModelSession:
    """Resolve the frozen conditioning the caller sent and open model state."""

    profile = _decode_profile_snapshot(frame.get("voice_profile"), voice=fields.voice)
    kwargs: dict[str, Any] = {
        "voice": fields.voice,
        "speed": fields.speed,
        "language": fields.language,
    }
    if profile is not None:
        if fields.ref_audio is not None or fields.ref_text is not None:
            raise ProtocolError("invalid voice profile snapshot")
        kwargs["profile"] = profile
    if fields.ref_audio is not None or fields.ref_text is not None:
        kwargs["ref_audio"] = fields.ref_audio
        kwargs["ref_text"] = fields.ref_text
    if fields.instruction is not None:
        kwargs["instruction"] = fields.instruction
    if fields.seed is not None:
        kwargs["seed"] = fields.seed
    return opener(**kwargs)


def _run_stream(
    pump: StreamPump,
    opener: Callable[..., IncrementalModelSession],
    frame: dict[str, object],
) -> None:
    request_id = frame.get("request_id")
    response_id = frame.get("response_id")
    if not isinstance(request_id, str) or not request_id:
        return
    try:
        parse_stream_command(frame)
        fields = _decode_synthesis_fields(
            frame, expected_type=FRAME_STREAM_START, require_text=False
        )
        if not isinstance(response_id, str) or not response_id:
            raise ProtocolError("incremental stream start requires a response_id")
    except ProtocolError:
        _emit(
            pump,
            _stream_error_frame(request_id, "worker_invalid_request", terminal=True),
        )
        return
    try:
        session = _open_stream_session(opener, fields, frame)
    except VoiceStoreUnavailableError:
        _emit(
            pump,
            _stream_error_frame(request_id, "voice_store_unavailable", terminal=True),
        )
        return
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _emit(
            pump,
            _stream_error_frame(request_id, "worker_inference_error", terminal=True),
        )
        return

    options = TtsStreamOptions(
        request_id=request_id,
        response_id=response_id,
        voice=fields.voice,
        language=fields.language,
        speed=fields.speed,
    )
    try:
        host = TtsStreamHost(session, options)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        with contextlib.suppress(Exception):
            session.close()
        _emit(
            pump,
            _stream_error_frame(request_id, "worker_inference_error", terminal=True),
        )
        return
    try:
        _drive_stream(pump, host)
    finally:
        host.close()


def _drive_stream(pump: StreamPump, host: TtsStreamHost) -> None:
    """Interleave bounded model steps with control frames from the parent."""

    for outbound in host.started_frames():
        _emit_frame(pump, outbound)
    request_id = host.options.request_id
    try:
        while True:
            if pump.cancel_pending and pump.cancel_request_id == request_id:
                for outbound in host.cancel():
                    _emit_frame(pump, outbound)
                pump.acknowledge_cancel(request_id)
                return
            if _drain_stream_commands(pump, host):
                return
            if host.terminal is not None:
                return
            result = host.step()
            for outbound in result.frames:
                _emit_frame(pump, outbound)
            if result.terminal or host.terminal is not None:
                return
            if not result.waiting_for_text:
                continue
            frame = pump.poll(timeout=host.timeout_remaining())
            if frame is None:
                if (
                    pump.at_eof
                    or pump.read_error is not None
                    or pump.write_error is not None
                ):
                    for outbound in host.cancel():
                        _emit_frame_best_effort(pump, outbound)
                    return
                for outbound in host.expire():
                    _emit_frame(pump, outbound)
                return
            if _apply_stream_frame(pump, host, frame):
                return
    finally:
        # A cancel that the priority flag observed is still sitting in the
        # inbound queue; leaving it there would answer the next utterance for a
        # request this worker already finished.
        pump.discard_ended_stream(request_id)


def _drain_stream_commands(pump: StreamPump, host: TtsStreamHost) -> bool:
    """Apply every already-queued command; ``True`` means the stream ended."""

    while True:
        frame = pump.poll(timeout=0)
        if frame is None:
            return host.terminal is not None
        if _apply_stream_frame(pump, host, frame):
            return True


def _apply_stream_frame(
    pump: StreamPump, host: TtsStreamHost, frame: dict[str, object]
) -> bool:
    request_id = host.options.request_id
    try:
        command = parse_stream_command(frame)
    except ProtocolError:
        _emit(
            pump,
            _stream_error_frame(request_id, "worker_invalid_request", terminal=False),
        )
        return False
    if command.request_id != request_id:
        _emit(
            pump,
            _stream_error_frame(
                command.request_id, "tts_sequence_invalid", terminal=False
            ),
        )
        return False
    if command.kind == "cancel":
        for outbound in host.cancel():
            _emit_frame(pump, outbound)
        pump.acknowledge_cancel(request_id)
        return True
    if command.kind == "finish":
        assert command.last_sequence is not None
        for outbound in host.finish_input(command.last_sequence):
            _emit_frame(pump, outbound)
    elif command.kind == "text":
        assert command.sequence is not None and command.text is not None
        for outbound in host.accept_text(command.sequence, command.text):
            _emit_frame(pump, outbound)
    else:
        _emit(
            pump,
            _stream_error_frame(
                request_id, "worker_invalid_request", terminal=False
            ),
        )
        return False
    return host.terminal is not None


def _run_synthesize(
    pump: StreamPump, engine: TtsWorkerEngine, frame: dict[str, object]
) -> None:
    raw_request_id = frame.get("request_id")
    request_id: str | None = raw_request_id if isinstance(raw_request_id, str) else None
    try:
        fields = _decode_synthesis_request(frame)
        request_id = fields.request_id
        synth_kwargs: dict[str, Any] = {
            "voice": fields.voice,
            "speed": fields.speed,
            "language": fields.language,
        }
        profile = _decode_profile_snapshot(frame.get("voice_profile"), voice=fields.voice)
        if profile is not None:
            if fields.ref_audio is not None or fields.ref_text is not None:
                raise ProtocolError("invalid voice profile snapshot")
            synth_kwargs["profile"] = profile
        if fields.ref_audio is not None or fields.ref_text is not None:
            synth_kwargs["ref_audio"] = fields.ref_audio
            synth_kwargs["ref_text"] = fields.ref_text
        if fields.instruction is not None:
            synth_kwargs["instruction"] = fields.instruction
        if fields.seed is not None:
            synth_kwargs["seed"] = fields.seed
        for index, pcm in enumerate(engine.synthesize(fields.text, **synth_kwargs)):
            if not pcm or len(pcm) % 2:
                raise ProtocolError("invalid PCM chunk")
            _emit(
                pump,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "audio",
                    "request_id": request_id,
                    "chunk_index": index,
                },
                pcm,
            )
        consume_stats = getattr(engine, "consume_delivery_stats", None)
        stats = consume_stats() if callable(consume_stats) else {}
        completed: dict[str, object] = {
            "version": PROTOCOL_VERSION,
            "type": "completed",
            "request_id": request_id,
        }
        if stats:
            completed["delivery_stats"] = stats
        if fields.timing_mode == "chunk":
            consume_timing = getattr(engine, "consume_timing_sidecar", None)
            timing = consume_timing() if callable(consume_timing) else None
            if isinstance(timing, dict):
                completed["timing_sidecar"] = timing
            else:
                completed["timing_unavailable_reason"] = (
                    "backend_timing_metadata_unavailable"
                )
        _emit(pump, completed)
        _clear_metal_cache()
    except ProtocolError:
        _emit(pump, _worker_error_frame(request_id, "worker_invalid_request"))
        _clear_metal_cache()
    except VoiceStoreUnavailableError:
        _emit(pump, _worker_error_frame(request_id, "voice_store_unavailable"))
        _clear_metal_cache()
    except _OutputClosedError:
        raise
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        _emit(pump, _worker_error_frame(request_id, _stable_worker_error_code(exc)))
        _clear_metal_cache()


def _decode_profile_snapshot(raw: object, *, voice: str) -> VoiceProfile | None:
    """Validate private IPC recipe fields without querying mutable voice storage."""
    if raw is None:
        return None
    keys = {"id", "mode", "instruction", "seed", "temperature"}
    if not isinstance(raw, dict) or set(raw) != keys:
        raise ProtocolError("invalid voice profile snapshot")
    identifier, mode = raw["id"], raw["mode"]
    instruction, seed, temperature = raw["instruction"], raw["seed"], raw["temperature"]
    if (
        not isinstance(identifier, str) or not VOICE_ID_RE.fullmatch(identifier)
        or identifier != resolve_voice(voice)
        or mode not in ("system", "instruction")
        or not isinstance(instruction, str) or not instruction.strip()
        or len(instruction) > 10_000 or type(seed) is not int or not 0 <= seed <= 2**32 - 1
        or type(temperature) not in (float, int)
        or not math.isfinite(temperature) or temperature < 0
    ):
        raise ProtocolError("invalid voice profile snapshot")
    return VoiceProfile(
        id=identifier, mode=mode, instruction=instruction, seed=seed,
        temperature=float(temperature),
    )


@dataclass(frozen=True, slots=True)
class _SynthesisFields:
    """Validated private synthesis fields shared by the batch and stream paths."""

    request_id: str
    text: str
    voice: str
    speed: float
    language: str
    ref_audio: str | None
    ref_text: str | None
    instruction: str | None
    seed: int | None
    timing_mode: str | None


def _decode_synthesis_fields(
    frame: dict[str, object],
    *,
    expected_type: str,
    require_text: bool = True,
) -> _SynthesisFields:
    """Validate one private synthesis-shaped frame without querying voice storage.

    The incremental ``tts_stream_start`` frame deliberately reuses this decoder
    so the two paths can never drift on speed, language, seed or instruction
    rules; only the presence of a text body differs.
    """

    request_id = frame.get("request_id")
    text = frame.get("text")
    voice = frame.get("voice")
    speed = frame.get("speed")
    language = frame.get("language", "auto")
    ref_audio = frame.get("ref_audio")
    ref_text = frame.get("ref_text")
    instruction = frame.get("instruction")
    seed = frame.get("seed")
    timing_mode = frame.get("timing_mode")
    if timing_mode not in (None, "chunk"):
        raise ProtocolError("invalid timing_mode in synthesize request")
    if (
        frame.get("version") != PROTOCOL_VERSION
        or frame.get("type") != expected_type
        or not isinstance(request_id, str)
        or not request_id
        or (
            require_text
            and (not isinstance(text, str) or not text.strip())
        )
        or (text is not None and not isinstance(text, str))
        or not isinstance(voice, str)
        or not voice.strip()
        or not isinstance(speed, (float, int))
        or not 0.25 <= float(speed) <= 4.0
        or not isinstance(language, str)
        or not language.strip()
        or len(language) > 64
    ):
        raise ProtocolError("invalid synthesize request")

    validated_ref_audio: str | None = None
    if ref_audio is not None:
        if not isinstance(ref_audio, str) or not ref_audio.strip():
            raise ProtocolError("invalid ref_audio in synthesize request")
        validated_ref_audio = ref_audio.strip()

    validated_ref_text: str | None = None
    if ref_text is not None:
        if not isinstance(ref_text, str):
            raise ProtocolError("invalid ref_text in synthesize request")
        validated_ref_text = ref_text

    validated_instruction: str | None = None
    if instruction is not None:
        if not isinstance(instruction, str) or not instruction.strip() or len(instruction) > 10_000:
            raise ProtocolError("invalid instruction in synthesize request")
        validated_instruction = instruction.strip()

    validated_seed: int | None = None
    if seed is not None:
        if (
            not isinstance(seed, int)
            or isinstance(seed, bool)
            or not 0 <= seed <= 2**32 - 1
        ):
            raise ProtocolError("invalid seed in synthesize request")
        validated_seed = seed

    return _SynthesisFields(
        request_id=request_id,
        text=text if isinstance(text, str) else "",
        voice=voice,
        speed=float(speed),
        language=language.strip(),
        ref_audio=validated_ref_audio,
        ref_text=validated_ref_text,
        instruction=validated_instruction,
        seed=validated_seed,
        timing_mode=timing_mode,
    )


def _decode_synthesis_request(frame: dict[str, object]) -> _SynthesisFields:
    return _decode_synthesis_fields(frame, expected_type="synthesize")


def main(argv: list[str] | None = None, *, engine_factory: EngineFactory | None = None) -> None:
    """Run the private local IPC service; public ASGI workers never import Qwen TTS."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", choices=("mps", "cpu"), required=True)
    parser.add_argument("--sample-rate", type=int, required=True)
    parser.add_argument("--chunk-ms", type=int, default=100)
    parser.add_argument("--repetition-penalty", type=float, default=1.25)
    parser.add_argument("--temperature", type=float, default=0.85)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--cache-limit-mb", type=int, default=256)
    parser.add_argument("--memory-limit-mb", type=int, default=0)
    parser.add_argument("--no-warmup", action="store_true")
    args = parser.parse_args(argv)
    _apply_metal_limits(args.cache_limit_mb, args.memory_limit_mb)
    model_dir = Path(args.model_dir).resolve(strict=True)
    device: Literal["mps", "cpu"] = args.device
    selected_factory = engine_factory or _default_engine_factory(
        device,
        sample_rate=args.sample_rate,
        chunk_ms=args.chunk_ms,
        repetition_penalty=args.repetition_penalty,
        temperature=args.temperature,
        top_p=args.top_p,
        warmup=not args.no_warmup,
    )
    serve(
        sys.stdin.buffer,
        sys.stdout.buffer,
        model_dir=model_dir,
        device=device,
        sample_rate=args.sample_rate,
        engine_factory=selected_factory,
    )


if __name__ == "__main__":  # pragma: no cover - subprocess entrypoint.
    main()
