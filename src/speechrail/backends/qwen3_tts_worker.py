"""Private, offline protocol host for one local Qwen3-TTS model process."""

from __future__ import annotations

import argparse
import hashlib
import sys
import traceback
from collections import Counter, OrderedDict
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Literal, Protocol

from speechrail.backends.model_identity import inspect_model, read_quantization
from speechrail.backends.qwen3_native import snapshot_is_quantized
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.domain.tts import (
    VoiceStoreUnavailableError,
    apply_crossfade,
    bounded_sentences,
    generation_token_budget,
    get_voice_profile,
    normalize_tts_text,
)
from speechrail.domain.tts_loudness import StreamingPcm16LoudnessController
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

TTS_BACKEND_ID = "mlx-qwen3-tts"
_CLONE_LOUDNESS_CHUNK_MS = 200
_CLONE_TEMPERATURE = 0.1
_CLONE_TOP_P = 0.95


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
    expected_dtype = "int8" if bits is not None or snapshot_is_quantized(model_dir) else (
        "float16" if device == "mps" else "float32"
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
    variant: str, voice: str, *, instruction: str | None = None
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
        binding = resolve_binding(variant, voice)
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
        # Pre-quantized snapshots keep an int8 backbone; codec/embeddings stay bf16.
        self.identity = TtsWorkerIdentity(
            device=device,
            dtype="int8" if expected.quantization.bits is not None else (
                "float16" if device == "mps" else "float32"
            ),
            sample_rate=sample_rate,
            family=expected.family,
            model_variant=expected.variant,
            quantization_bits=expected.quantization.bits,
            quantization_group_size=expected.quantization.group_size,
            weight_fingerprint=expected.weight_fingerprint,
        )
        if warmup:
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
    ) -> Iterator[bytes]:
        clean_text = normalize_tts_text(text)
        if not clean_text:
            return
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

        try:
            for sentence in bounded_sentences(clean_text):
                self._delivery_stats["planner_chunks"] += 1
                for pcm in self._generate(
                    sentence,
                    voice=voice,
                    speed=speed,
                    language=language,
                    instruction=instruction,
                    seed=seed,
                    ref_audio=ref_audio,
                    ref_text=ref_text,
                ):
                    if not pcm:
                        continue
                    if loudness_controller is not None:
                        pending_clone_pcm.extend(pcm)
                        while len(pending_clone_pcm) >= clone_chunk_bytes:
                            clone_pcm = bytes(pending_clone_pcm[:clone_chunk_bytes])
                            del pending_clone_pcm[:clone_chunk_bytes]
                            clone_pcm = loudness_controller.process(clone_pcm)
                            if clone_pcm:
                                yield prepare_output(clone_pcm)
                        continue
                    yield prepare_output(pcm)
            if loudness_controller is not None and pending_clone_pcm:
                clone_pcm = loudness_controller.process(bytes(pending_clone_pcm))
                if clone_pcm:
                    yield prepare_output(clone_pcm)
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
    ) -> Iterator[bytes]:
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
            variant = self.identity.model_variant or "voice_design"
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

        variant = self.identity.model_variant or "voice_design"
        if variant == "custom_voice" and seed is not None:
            raise ValueError("custom_voice_seed_unsupported")
        condition = generation_condition(variant, voice, instruction=instruction)
        used_temperature = self._temperature
        if variant == "voice_design":
            if instruction is None:
                if seed is not None:
                    raise ValueError("voice_design_seed_requires_instruction")
                profile = get_voice_profile(voice)
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
    """Serve only framed local IPC; no request can select a model or URL."""
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
    ready: dict[str, object] = {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "backend": identity.backend,
        "device": identity.device,
        "dtype": identity.dtype,
        "sample_rate": identity.sample_rate,
        "model_loaded": True,
    }
    ready.update(_ready_identity_fields(identity))
    write_frame(
        output_stream,
        ready,
    )
    while frame := read_frame(input_stream):
        if frame.get("type") == "trim_memory":
            # Fire-and-forget: no confirmation frame so the framing of the next
            # synthesize response is never pushed out of alignment.
            _clear_metal_cache()
            continue
        request_id = frame.get("request_id") if isinstance(frame.get("request_id"), str) else None
        try:
            (
                request_id,
                text,
                voice,
                speed,
                language,
                ref_audio,
                ref_text,
                instruction,
                seed,
            ) = _decode_synthesis_request(frame)
            synth_kwargs: dict[str, Any] = {
                "voice": voice,
                "speed": speed,
                "language": language,
            }
            if ref_audio is not None or ref_text is not None:
                synth_kwargs["ref_audio"] = ref_audio
                synth_kwargs["ref_text"] = ref_text
            if instruction is not None:
                synth_kwargs["instruction"] = instruction
            if seed is not None:
                synth_kwargs["seed"] = seed
            for index, pcm in enumerate(
                engine.synthesize(text, **synth_kwargs)
            ):
                if not pcm or len(pcm) % 2:
                    raise ProtocolError("invalid PCM chunk")
                write_frame(
                    output_stream,
                    {
                        "version": PROTOCOL_VERSION,
                        "type": "audio",
                        "request_id": request_id,
                        "chunk_index": index,
                    },
                    binary_payload=pcm,
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
            write_frame(
                output_stream,
                completed,
            )
            _clear_metal_cache()
        except ProtocolError:
            write_frame(
                output_stream,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "error",
                    "code": "worker_invalid_request",
                    "request_id": request_id,
                },
            )
            _clear_metal_cache()
        except VoiceStoreUnavailableError:
            write_frame(
                output_stream,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "error",
                    "code": "voice_store_unavailable",
                    "request_id": request_id,
                },
            )
            _clear_metal_cache()
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            write_frame(
                output_stream,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "error",
                    "code": "worker_inference_error",
                    "message": str(exc),
                    "request_id": request_id,
                },
            )
            _clear_metal_cache()


def _decode_synthesis_request(
    frame: dict[str, object],
) -> tuple[str, str, str, float, str, str | None, str | None, str | None, int | None]:
    request_id = frame.get("request_id")
    text = frame.get("text")
    voice = frame.get("voice")
    speed = frame.get("speed")
    language = frame.get("language", "auto")
    ref_audio = frame.get("ref_audio")
    ref_text = frame.get("ref_text")
    instruction = frame.get("instruction")
    seed = frame.get("seed")
    if (
        frame.get("version") != PROTOCOL_VERSION
        or frame.get("type") != "synthesize"
        or not isinstance(request_id, str)
        or not request_id
        or not isinstance(text, str)
        or not text.strip()
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

    return (
        request_id,
        text,
        voice,
        float(speed),
        language.strip(),
        validated_ref_audio,
        validated_ref_text,
        validated_instruction,
        validated_seed,
    )


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
