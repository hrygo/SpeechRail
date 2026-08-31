"""SpeechRail runtime configuration."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal
from urllib.parse import urlsplit

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from speechrail.runtime.resource_governor import GovernorLimits


class Settings(BaseSettings):
    """Validated, environment-backed service configuration."""

    model_config = SettingsConfigDict(env_prefix="SPEECHRAIL_", env_file=".env", extra="ignore")

    service_name: str = "speechrail"
    version: str = "0.1.0"
    host: str = "127.0.0.1"
    port: int = Field(default=8201, ge=1, le=65535)
    model_id: str = "speechrail/qwen3-asr-1.7b"
    tts_model_id: str = "speechrail/qwen3-tts"
    tts_voice_ids: tuple[str, ...] = ("default",)
    qwen3_tts_model_dir: Path | None = None
    qwen3_tts_python: Path | None = None
    tts_allow_model_downloads: bool = False
    tts_sample_rate: int = Field(default=24_000, ge=8_000, le=48_000)
    wlk_streaming_url: str | None = None
    diarization_model_path: Path | None = None
    diarization_max_buffer_bytes: int = Field(default=8_388_608, ge=2, le=64_000_000)
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
    dtype: Literal["float16", "float32"] = "float16"
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
    legacy_wlk_enabled: bool = True
    legacy_query_token_enabled: bool = False

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

    @field_validator("diarization_model_path")
    @classmethod
    def require_absolute_diarization_model(cls, value: Path | None) -> Path | None:
        if value is not None and not value.is_absolute():
            raise ValueError("diarization_model_path must be an external absolute path")
        return value

    @field_validator("wlk_streaming_url")
    @classmethod
    def validate_wlk_streaming_url(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().rstrip("/")
        parsed = urlsplit(normalized)
        if (
            parsed.scheme not in {"ws", "wss"}
            or parsed.hostname is None
            or parsed.username is not None
            or parsed.password is not None
        ):
            raise ValueError("wlk_streaming_url must be a credential-free ws(s) URL")
        return normalized

    @model_validator(mode="after")
    def validate_exposure(self) -> Settings:
        if self.host not in {"127.0.0.1", "::1", "localhost"} and not self.api_key:
            raise ValueError("api_key is required when binding outside loopback")
        if self.device == "mps" and self.dtype != "float16":
            raise ValueError("MPS profile requires float16")
        if self.device == "cpu" and self.dtype != "float32":
            raise ValueError("CPU profile requires float32")
        if self.realtime_reserved_capacity >= self.runtime_total_capacity:
            raise ValueError("realtime_reserved_capacity must be lower than runtime_total_capacity")
        if not self.tts_voice_ids or any(not voice.strip() for voice in self.tts_voice_ids):
            raise ValueError("tts_voice_ids must contain non-empty preset voices")
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
