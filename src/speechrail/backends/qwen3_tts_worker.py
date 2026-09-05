"""Private, offline protocol host for one local Qwen3-TTS model process."""

from __future__ import annotations

import argparse
import sys
import traceback
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Final, Literal, Protocol

from speechrail.backends.model_identity import inspect_model, read_quantization
from speechrail.backends.qwen3_native import snapshot_is_quantized
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.domain.tts import (
    apply_crossfade,
    bounded_sentences,
    generation_token_budget,
    get_voice_profile,
    normalize_tts_text,
)
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

TTS_BACKEND_ID = "mlx-qwen3-tts-voice-design"


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
        self, text: str, *, voice: str, speed: float, language: str
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
    if variant is not None and variant not in {"voice_design", "custom_voice"}:
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


_CUSTOM_VOICE_SPEAKERS: Final[dict[str, str]] = {
    "default": "Serena",
    "warm": "Serena",
    "bright": "Vivian",
    "calm": "Uncle_Fu",
}


def generation_condition(variant: str, voice: str) -> dict[str, object]:
    """根据模型变体解析生成条件 (音色或提示词指令)。"""

    if variant == "custom_voice":
        if voice not in _CUSTOM_VOICE_SPEAKERS:
            raise ValueError(f"unknown voice: {voice}")
        return {"voice": _CUSTOM_VOICE_SPEAKERS[voice]}
    if variant == "voice_design":
        try:
            profile = get_voice_profile(voice)
        except Exception as exc:
            raise ValueError(f"unknown voice: {voice}") from exc
        return {"voice": None, "instruct": profile.instruction}
    raise ValueError(f"unsupported variant: {variant}")


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
        warmup: bool = True,
    ) -> None:
        expected = inspect_model(model_dir)
        if expected.family != "qwen3_tts" or expected.variant not in (
            "voice_design",
            "custom_voice",
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
        self._sample_rate = sample_rate
        self._chunk_ms = chunk_ms
        self._repetition_penalty = repetition_penalty
        self._temperature = temperature
        self._top_p = top_p
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

    def synthesize(
        self, text: str, *, voice: str, speed: float, language: str
    ) -> Iterator[bytes]:
        clean_text = normalize_tts_text(text)
        if not clean_text:
            return
        first_chunk = True
        for sentence in bounded_sentences(clean_text):
            for pcm in self._generate(sentence, voice=voice, speed=speed, language=language):
                if not pcm:
                    continue
                if first_chunk:
                    pcm = apply_crossfade(
                        pcm,
                        sample_rate=self._sample_rate,
                        fade_ms=5,
                        fade_in=True,
                        fade_out=False,
                    )
                    first_chunk = False
                yield pcm

    def _generate(
        self, text: str, *, voice: str, speed: float, language: str
    ) -> Iterator[bytes]:
        variant = self.identity.model_variant or "voice_design"
        condition = generation_condition(variant, voice)
        call_kwargs: dict[str, object] = {
            "text": text,
            "speed": speed,
            "lang_code": language,
            "max_tokens": generation_token_budget(text),
            "repetition_penalty": self._repetition_penalty,
            "temperature": self._temperature,
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
            request_id, text, voice, speed, language = _decode_synthesis_request(frame)
            for index, pcm in enumerate(
                engine.synthesize(text, voice=voice, speed=speed, language=language)
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
            write_frame(
                output_stream,
                {"version": PROTOCOL_VERSION, "type": "completed", "request_id": request_id},
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
        except Exception:
            traceback.print_exc(file=sys.stderr)
            write_frame(
                output_stream,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "error",
                    "code": "worker_inference_error",
                    "request_id": request_id,
                },
            )
            _clear_metal_cache()


def _decode_synthesis_request(frame: dict[str, object]) -> tuple[str, str, str, float, str]:
    request_id = frame.get("request_id")
    text = frame.get("text")
    voice = frame.get("voice")
    speed = frame.get("speed")
    language = frame.get("language", "auto")
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
    return request_id, text, voice, float(speed), language.strip()


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
