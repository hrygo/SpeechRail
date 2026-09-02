"""SpeechRail runtime configuration."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal, Self

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from speechrail.domain.resource_limits import GovernorLimits
from speechrail.domain.tts import VOICE_PROFILES


class Settings(BaseSettings):
    """Validated, environment-backed service configuration."""

    model_config = SettingsConfigDict(env_prefix="SPEECHRAIL_", env_file=".env", extra="ignore")

    @classmethod
    def from_env_file(cls, env_file: Path | None = None) -> Self:
        """Load settings from an explicit file or preserve the development default."""
        if env_file is None:
            return cls()
        return cls(_env_file=env_file)  # type: ignore[call-arg]

    service_name: str = "speechrail"
    version: str = "1.3.1"
    host: str = "127.0.0.1"
    port: int = Field(default=8201, ge=1, le=65535)
    model_id: str = "speechrail/qwen3-asr-1.7b"
    tts_model_id: str = "speechrail/qwen3-tts"
    tts_voice_ids: tuple[str, ...] = ("default", "warm", "bright", "calm")
    qwen3_tts_model_dir: Path | None = None
    qwen3_tts_python: Path | None = None
    tts_allow_model_downloads: bool = False
    tts_sample_rate: int = Field(default=24_000, ge=8_000, le=48_000)
    tts_chunk_ms: int = Field(default=100, ge=10, le=2_000)
    tts_repetition_penalty: float = Field(default=1.25, ge=1.0, le=2.0)
    tts_temperature: float = Field(default=0.85, gt=0.0, le=2.0)
    tts_top_p: float = Field(default=0.95, gt=0.0, le=1.0)
    tts_warmup_on_start: bool = True
    realtime_asr_backend: Literal["disabled", "native"] = "disabled"
    qwen3_streaming_mode: Literal["windowed", "causal"] = "windowed"
    qwen3_streaming_chunk_sec: float = Field(default=2.0, gt=0, le=30)
    qwen3_streaming_left_context_sec: float = Field(default=12.0, ge=0, le=60)
    qwen3_streaming_right_context_ms: int = Field(default=640, ge=0, le=10_000)
    qwen3_streaming_hold_back_words: int = Field(default=6, ge=0, le=64)
    qwen3_streaming_stable_iterations: int = Field(default=2, ge=1, le=16)
    qwen3_streaming_max_new_tokens: int = Field(default=256, ge=32, le=2048)
    qwen3_streaming_context: str = ""
    diarization_model_path: Path | None = None
    diarization_embedding_model_path: Path | None = None
    diarization_max_buffer_bytes: int = Field(default=8_388_608, ge=2, le=64_000_000)
    diarization_max_groups: int = Field(default=64, ge=1, le=4096)
    diarization_group_ttl_seconds: float = Field(default=900, gt=0, le=86_400)
    diarization_similarity_threshold: float = Field(default=0.8, gt=0, le=1)
    job_spool_dir: Path | None = None
    job_poll_seconds: float = Field(default=0.1, gt=0, le=60)
    compatibility_model_ids: tuple[str, ...] = (
        "Qwen3-ASR-1.7B",
        "qwen3-asr-1.7b",
        "whisper-1",
    )
    api_key: str | None = None
    allowed_origins: tuple[str, ...] = ()
    backend_ready: bool = False
    qwen3_model_dir: Path | None = None
    qwen3_python: Path | None = None
    allow_model_downloads: bool = False
    device: Literal["mps", "cpu"] = "mps"
    dtype: Literal["float16", "float32", "int8"] = "float16"
    mlx_cache_limit_mb: int = Field(default=256, ge=0, le=65536)
    mlx_memory_limit_mb: int = Field(default=0, ge=0, le=131072)
    worker_lazy_load: bool = False
    worker_idle_timeout_seconds: float = Field(default=300.0, ge=0.0, le=86_400)
    max_queue_size: int = Field(default=8, ge=1, le=1024)
    max_upload_bytes: int = Field(default=536_870_912, ge=1)
    max_audio_seconds: int = Field(default=3600, ge=1)
    max_realtime_frame_bytes: int = Field(default=160_000, ge=2, le=4_000_000)
    max_realtime_buffer_bytes: int = Field(default=8_388_608, ge=2, le=64_000_000)
    realtime_outbound_max_events: int = Field(default=8, ge=1, le=1_024)
    runtime_total_capacity: int = Field(default=4, ge=2, le=128)
    realtime_reserved_capacity: int = Field(default=1, ge=1, le=127)
    runtime_max_pending_per_class: int = Field(default=8, ge=1, le=1024)
    batch_aging_seconds: float = Field(default=30, gt=0, le=3600)
    request_timeout_seconds: float = Field(default=120, gt=0, le=3600)

    @field_validator("api_key", mode="before")
    @classmethod
    def blank_api_key_is_unset(cls, value: Any) -> Any:
        return None if value == "" else value

    @field_validator("job_spool_dir")
    @classmethod
    def require_absolute_job_spool(cls, value: Path | None) -> Path | None:
        if value is not None and not value.is_absolute():
            raise ValueError("job_spool_dir must be an external absolute path")
        return value

    @field_validator("diarization_model_path", "diarization_embedding_model_path")
    @classmethod
    def require_absolute_diarization_model(cls, value: Path | None) -> Path | None:
        if value is not None and not value.is_absolute():
            raise ValueError("diarization model paths must be external absolute paths")
        return value

    @model_validator(mode="after")
    def validate_exposure(self) -> Settings:
        if self.host not in {"127.0.0.1", "::1", "localhost"} and not self.api_key:
            raise ValueError("api_key is required when binding outside loopback")
        if self.device == "mps" and self.dtype not in {"float16", "int8"}:
            raise ValueError("MPS profile requires float16 or int8")
        if self.device == "cpu" and self.dtype not in {"float32", "int8"}:
            raise ValueError("CPU profile requires float32 or int8")
        if self.realtime_asr_backend == "native":
            if self.qwen3_python is None:
                raise ValueError(
                    "realtime_asr_backend=native requires qwen3_python"
                )
            if self.qwen3_model_dir is None:
                raise ValueError(
                    "realtime_asr_backend=native requires qwen3_model_dir"
                )
        if self.realtime_reserved_capacity >= self.runtime_total_capacity:
            raise ValueError("realtime_reserved_capacity must be lower than runtime_total_capacity")
        if (
            self.diarization_embedding_model_path is not None
            and self.diarization_model_path is None
        ):
            raise ValueError("diarization_embedding_model_path requires diarization_model_path")
        if not self.tts_voice_ids or any(
            not voice.strip() or voice not in VOICE_PROFILES for voice in self.tts_voice_ids
        ):
            raise ValueError("tts_voice_ids must contain registered preset voices")
        if self.tts_sample_rate != 24_000:
            raise ValueError("tts_sample_rate must be 24000 for the public PCM profile")
        return self

    @property
    def governor_limits(self) -> GovernorLimits:
        """Translate validated service settings into the runtime admission limits."""
        return GovernorLimits(
            total_capacity=self.runtime_total_capacity,
            realtime_reserved_capacity=self.realtime_reserved_capacity,
            max_pending_per_class=self.runtime_max_pending_per_class,
        )


__all__ = ["Settings"]
