"""Private, offline protocol host for one local Qwen3-TTS model process."""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Literal, Protocol

from speechrail.domain.tts import generation_token_budget, get_voice_profile, normalize_tts_text
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

TTS_BACKEND_ID = "mlx-qwen3-tts-voice-design"


def _snapshot_is_quantized(model_dir: Path) -> bool:
    """True when the snapshot ships pre-quantized weights (e.g. an ``-8bit`` MLX snapshot)."""
    try:
        config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    except Exception:
        return False
    return bool(config.get("quantization") or config.get("quantization_config"))


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


class TtsWorkerEngine(Protocol):
    identity: TtsWorkerIdentity

    def synthesize(
        self, text: str, *, voice: str, speed: float, language: str
    ) -> Iterator[bytes]: ...


EngineFactory = Callable[[Path], TtsWorkerEngine]
ModelLoader = Callable[[str], Any]


class MlxVoiceDesignEngine:  # pragma: no cover - requires separately authorized model runtime.
    """MLX Qwen3-TTS VoiceDesign engine isolated in the worker process."""

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
        try:
            if load_fn is None:
                from mlx_audio.tts.utils import load  # type: ignore[import-not-found]

                load_fn = load
            self._numpy = numpy_module or __import__("numpy")
            self._model = load_fn(str(model_dir))
        except Exception as exc:
            raise RuntimeError("mlx_qwen3_tts_runtime_unavailable") from exc
        model_type = getattr(getattr(self._model, "config", None), "tts_model_type", None)
        if model_type != "voice_design":
            raise RuntimeError("unsupported_tts_model_type")
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
            dtype="int8" if _snapshot_is_quantized(model_dir) else (
                "float16" if device == "mps" else "float32"
            ),
            sample_rate=sample_rate,
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
        yield from self._generate(clean_text, voice=voice, speed=speed, language=language)

    def _generate(
        self, text: str, *, voice: str, speed: float, language: str
    ) -> Iterator[bytes]:
        profile = get_voice_profile(voice)
        for result in self._model.generate(
            text=text,
            voice=None,
            instruct=profile.instruction,
            speed=speed,
            lang_code=language,
            max_tokens=generation_token_budget(text),
            repetition_penalty=self._repetition_penalty,
            temperature=self._temperature,
            top_p=self._top_p,
            stream=True,
            streaming_interval=self._chunk_ms / 1000,
        ):
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
    return lambda model_dir: MlxVoiceDesignEngine(
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
    snapshot_quantized = _snapshot_is_quantized(model_dir)
    expected_dtype = (
        "int8"
        if snapshot_quantized
        else ("float16" if device == "mps" else "float32")
    )
    if (
        identity.device != device
        or identity.dtype != expected_dtype
        or identity.sample_rate != sample_rate
    ):
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "backend_identity_mismatch"},
        )
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "ready",
            "backend": identity.backend,
            "device": identity.device,
            "dtype": identity.dtype,
            "sample_rate": identity.sample_rate,
            "model_loaded": True,
        },
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
