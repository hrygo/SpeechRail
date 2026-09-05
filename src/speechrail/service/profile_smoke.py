"""Bounded public API smoke probe for one prepared ASR/TTS pair."""

from __future__ import annotations

import time
from collections.abc import Callable, Mapping

import httpx

from speechrail.domain.tts import DEFAULT_VOICE_ID
from speechrail.service.model_store import PreparedModelSet

_SMOKE_TTS_TEXT = "这是语音服务的切换验证，请清楚朗读这段普通话。"
_MAX_INFERENCE_ATTEMPTS = 3


class SmokeProbeError(RuntimeError):
    """The running service did not pass its bounded public API smoke."""


class _EmptyTranscriptError(SmokeProbeError):
    """One valid public ASR response contained no transcript text."""


class PublicApiSmokeProbe:
    """Validate health, catalogs, TTS and ASR without calling vendor APIs."""

    def __init__(
        self,
        *,
        client: httpx.Client,
        api_key: str | None = None,
        deadline_seconds: float = 300.0,
        poll_interval_seconds: float = 0.1,
        max_audio_bytes: int = 8 * 1024 * 1024,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        if deadline_seconds <= 0 or poll_interval_seconds <= 0 or max_audio_bytes <= 44:
            raise ValueError("invalid public smoke limits")
        if client.base_url.scheme != "http" or client.base_url.host not in {
            "127.0.0.1",
            "::1",
            "localhost",
        }:
            raise ValueError("public smoke client must use loopback HTTP")
        self._client = client
        self._headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._deadline_seconds = deadline_seconds
        self._poll_interval_seconds = poll_interval_seconds
        self._max_audio_bytes = max_audio_bytes
        self._clock = clock
        self._sleep = sleep

    @staticmethod
    def _json_mapping(response: httpx.Response) -> Mapping[str, object]:
        try:
            payload = response.json()
        except ValueError as exc:
            raise SmokeProbeError("public smoke returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise SmokeProbeError("public smoke returned invalid JSON")
        return payload

    def _wait_ready(self) -> None:
        deadline = self._clock() + self._deadline_seconds
        while True:
            try:
                health = self._client.get("/health")
                ready = self._client.get("/readyz")
                if (
                    health.status_code == 200
                    and self._json_mapping(health).get("status") == "ok"
                    and ready.status_code == 200
                    and self._json_mapping(ready).get("ready") is True
                ):
                    return
            except (httpx.HTTPError, SmokeProbeError):
                pass
            if self._clock() >= deadline:
                raise SmokeProbeError("service did not become ready before the smoke deadline")
            self._sleep(self._poll_interval_seconds)

    def _check_catalogs(self) -> None:
        try:
            models = self._client.get("/v1/models")
            voices = self._client.get("/v1/voices")
        except httpx.HTTPError as exc:
            raise SmokeProbeError("public catalogs are unavailable") from exc
        if models.status_code != 200 or voices.status_code != 200:
            raise SmokeProbeError("public catalogs are unavailable")
        model_data = self._json_mapping(models).get("data")
        voice_data = self._json_mapping(voices).get("data")
        model_ids: set[str] = set()
        if isinstance(model_data, list):
            for item in model_data:
                if isinstance(item, dict):
                    model_id = item.get("id")
                    if isinstance(model_id, str):
                        model_ids.add(model_id)
        if not isinstance(model_data, list) or not {"whisper-1", "tts-1"}.issubset(model_ids):
            raise SmokeProbeError("public model aliases are unavailable")
        if not isinstance(voice_data, list) or not any(
            isinstance(item, dict)
            and item.get("id") == DEFAULT_VOICE_ID
            and item.get("available") is True
            for item in voice_data
        ):
            raise SmokeProbeError("canonical default public voice is unavailable")

    def _tts_audio(self) -> bytes:
        try:
            with self._client.stream(
                "POST",
                "/v1/audio/speech",
                headers=self._headers,
                json={
                    "model": "tts-1",
                    "input": _SMOKE_TTS_TEXT,
                    "voice": DEFAULT_VOICE_ID,
                    "language": "zh",
                    "response_format": "wav",
                },
            ) as response:
                if response.status_code != 200 or not response.headers.get("X-Request-ID"):
                    raise SmokeProbeError("public TTS smoke failed")
                chunks: list[bytes] = []
                size = 0
                for chunk in response.iter_bytes():
                    size += len(chunk)
                    if size > self._max_audio_bytes:
                        raise SmokeProbeError("public TTS smoke exceeded its audio limit")
                    chunks.append(chunk)
        except httpx.HTTPError as exc:
            raise SmokeProbeError("public TTS smoke failed") from exc
        audio = b"".join(chunks)
        if len(audio) <= 44 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
            raise SmokeProbeError("public TTS smoke returned invalid WAV audio")
        return audio

    def _check_asr(self, audio: bytes) -> None:
        try:
            response = self._client.post(
                "/v1/audio/transcriptions",
                headers=self._headers,
                data={"model": "whisper-1", "response_format": "json", "language": "zh"},
                files={"file": ("speechrail-smoke.wav", audio, "audio/wav")},
            )
        except httpx.HTTPError as exc:
            raise SmokeProbeError("public ASR smoke failed") from exc
        if response.status_code != 200 or not response.headers.get("X-Request-ID"):
            raise SmokeProbeError("public ASR smoke failed")
        text = self._json_mapping(response).get("text")
        if not isinstance(text, str) or not text.strip():
            raise _EmptyTranscriptError("public ASR smoke returned empty text")

    def run(self, prepared: PreparedModelSet) -> None:
        if not prepared.prepared_id or not prepared.asr.key or not prepared.tts.key:
            raise SmokeProbeError("prepared profile identity is invalid")
        self._wait_ready()
        self._check_catalogs()
        for attempt in range(_MAX_INFERENCE_ATTEMPTS):
            try:
                self._check_asr(self._tts_audio())
            except _EmptyTranscriptError:
                if attempt + 1 == _MAX_INFERENCE_ATTEMPTS:
                    raise
            else:
                return


__all__ = ["PublicApiSmokeProbe", "SmokeProbeError"]
