"""Deterministic unit and integration tests for zero-shot voice cloning in SpeechRail."""

from __future__ import annotations

import io
import subprocess
import wave
from collections.abc import AsyncIterator
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

import speechrail.backends.qwen3_tts_worker as worker_module
from speechrail.app import create_app
from speechrail.backends.model_identity import SnapshotIdentity
from speechrail.backends.qwen3_tts_worker import MlxVoiceDesignEngine
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.config import Settings
from speechrail.config.model_catalog import QuantizationSpec, load_catalog
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import (
    VoiceRegistry,
    transcode_and_validate_clone_audio,
)


def _generate_test_wav(duration_seconds: float = 3.0, sample_rate: int = 24_000) -> bytes:
    """Generate in-memory mono PCM16 WAV bytes for testing."""
    num_samples = int(duration_seconds * sample_rate)
    samples = np.zeros(num_samples, dtype="<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(samples.tobytes())
    return buf.getvalue()


class CapturingSpeechSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="test_clone_resp", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def _make_test_client(
    tmp_path: Path, preset_id: str = "quality"
) -> tuple[TestClient, VoiceRegistry]:
    preset = load_catalog().preset(preset_id)
    storage_path = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)

    settings = Settings(
        qwen3_model_dir=tmp_path / preset.asr,
        qwen3_python=None,
        qwen3_tts_model_dir=tmp_path / preset.tts,
        qwen3_tts_python=None,
    )
    app = create_app(settings, tts_synthesizer=CapturingSpeechSynthesizer())
    return TestClient(app), registry


# ===================== 1. Domain & VoiceRegistry =====================


def test_voice_registry_cloned_profile_lifecycle(tmp_path: Path) -> None:
    storage_path = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)

    wav_bytes = _generate_test_wav(duration_seconds=5.0)
    profile = registry.create_cloned_profile(
        name="我的专属克隆",
        ref_text="白日依山尽，黄河入海流。",
        audio_bytes=wav_bytes,
        voice_id="my_custom_clone_1",
        duration_seconds=5.0,
    )

    assert profile.id == "my_custom_clone_1"
    assert profile.name == "我的专属克隆"
    assert profile.mode == "clone"
    assert profile.ref_text == "白日依山尽，黄河入海流。"
    assert profile.duration_seconds == 5.0
    assert profile.audio_path is not None
    assert Path(profile.audio_path).is_file()

    # Verify retrieval
    retrieved = registry.get_profile("my_custom_clone_1")
    assert retrieved.id == profile.id
    assert retrieved.mode == "clone"

    # Verify deletion & unlinking
    registry.delete_custom_profile("my_custom_clone_1")
    assert not Path(profile.audio_path).is_file()
    with pytest.raises(ValueError, match="unknown preset voice"):
        registry.get_profile("my_custom_clone_1")


def test_voice_registry_security_validations(tmp_path: Path) -> None:
    storage_path = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    wav_bytes = _generate_test_wav(duration_seconds=3.0)

    # Empty name
    with pytest.raises(ValueError, match="voice name must not be empty"):
        registry.create_cloned_profile(
            name="",
            ref_text="test",
            audio_bytes=wav_bytes,
            duration_seconds=3.0,
        )

    # Empty ref_text
    with pytest.raises(ValueError, match="ref_text must not be empty"):
        registry.create_cloned_profile(
            name="test",
            ref_text="",
            audio_bytes=wav_bytes,
            duration_seconds=3.0,
        )

    # Path traversal voice_id
    with pytest.raises(ValueError, match="regex"):
        registry.create_cloned_profile(
            name="test",
            ref_text="test",
            audio_bytes=wav_bytes,
            voice_id="../../evil_voice",
            duration_seconds=3.0,
        )

    # System voice override
    with pytest.raises(ValueError, match="cannot override system voice"):
        registry.create_cloned_profile(
            name="test",
            ref_text="test",
            audio_bytes=wav_bytes,
            voice_id="serena",
            duration_seconds=3.0,
        )


def test_voice_registry_cross_process_mtime_reload(tmp_path: Path) -> None:
    storage_path = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    reg1 = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    reg2 = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)

    wav_bytes = _generate_test_wav(duration_seconds=4.0)
    # reg1 adds profile
    reg1.create_cloned_profile(
        name="动态克隆",
        ref_text="科技浪潮，改变生活。",
        audio_bytes=wav_bytes,
        voice_id="dyn_clone_1",
        duration_seconds=4.0,
    )

    # reg2 should see it dynamically via mtime check without restart
    profile2 = reg2.get_profile("dyn_clone_1")
    assert profile2.id == "dyn_clone_1"
    assert profile2.name == "动态克隆"


# ===================== 2. Audio Transcoding & Validation =====================


def test_transcode_and_validate_clone_audio_duration_bounds() -> None:
    # 1. Too short (< 2.0s)
    short_wav = _generate_test_wav(duration_seconds=1.5)
    with patch("subprocess.run") as mock_run:
        mock_run.return_value = SimpleNamespace(returncode=0, stdout=short_wav, stderr=b"")
        with pytest.raises(ValueError, match="too short"):
            transcode_and_validate_clone_audio(b"fake_raw_audio")

    # 2. Too long (> 45.0s)
    long_wav = _generate_test_wav(duration_seconds=46.0)
    with patch("subprocess.run") as mock_run:
        mock_run.return_value = SimpleNamespace(returncode=0, stdout=long_wav, stderr=b"")
        with pytest.raises(ValueError, match="too long"):
            transcode_and_validate_clone_audio(b"fake_raw_audio")

    # 3. Valid duration (e.g. 5.0s)
    valid_wav = _generate_test_wav(duration_seconds=5.0)
    with patch("subprocess.run") as mock_run:
        mock_run.return_value = SimpleNamespace(returncode=0, stdout=valid_wav, stderr=b"")
        wav_out, dur = transcode_and_validate_clone_audio(b"fake_raw_audio")
        assert len(wav_out) == len(valid_wav)
        assert abs(dur - 5.0) < 0.1


def test_transcode_accepts_pipe_wav_with_unknown_riff_sizes() -> None:
    pipe_wav = bytearray(_generate_test_wav(duration_seconds=5.0))
    pipe_wav[4:8] = b"\xff\xff\xff\xff"
    data_offset = pipe_wav.find(b"data")
    assert data_offset > 0
    pipe_wav[data_offset + 4 : data_offset + 8] = b"\xff\xff\xff\xff"

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = SimpleNamespace(
            returncode=0,
            stdout=bytes(pipe_wav),
            stderr=b"",
        )
        wav_out, duration = transcode_and_validate_clone_audio(b"fake_raw_audio")

    assert len(wav_out) == len(pipe_wav)
    assert duration == pytest.approx(5.0, abs=0.1)


def test_transcode_and_validate_clone_audio_errors() -> None:
    # Empty audio
    with pytest.raises(ValueError, match="empty"):
        transcode_and_validate_clone_audio(b"")

    # Audio file > 15MB
    with pytest.raises(ValueError, match="exceeds 15MB"):
        transcode_and_validate_clone_audio(b"x" * (16 * 1024 * 1024))

    # ffmpeg not found
    with patch("subprocess.run", side_effect=FileNotFoundError), pytest.raises(
        RuntimeError, match="ffmpeg_not_found"
    ):
        transcode_and_validate_clone_audio(b"valid_data")

    # ffmpeg timeout
    with (
        patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="ffmpeg", timeout=10)),
        pytest.raises(ValueError, match="timed out"),
    ):
        transcode_and_validate_clone_audio(b"valid_data")


# ===================== 3. VoiceBinding Resolution =====================


def test_resolve_binding_voice_cloning(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:

    storage_path = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    test_reg = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", test_reg)
    monkeypatch.setattr(
        "speechrail.backends.qwen3_voice_binding.get_voice_profile", test_reg.get_profile
    )

    wav_bytes = _generate_test_wav(duration_seconds=3.0)
    test_reg.create_cloned_profile(
        name="测试音色",
        ref_text="这是测试引导句。",
        audio_bytes=wav_bytes,
        voice_id="test_binding_clone",
        duration_seconds=3.0,
    )

    # 1. Quality tier (voice_design): supports cloning
    binding_qd = resolve_binding("voice_design", "test_binding_clone")
    assert binding_qd.is_clone is True
    assert binding_qd.ref_audio_path is not None
    assert binding_qd.ref_text == "这是测试引导句。"
    assert binding_qd.capabilities.supports_clone is True

    # 2. Balanced tier (custom_voice): does not support cloning
    with pytest.raises(ValueError, match="requires voice_design variant"):
        resolve_binding("custom_voice", "test_binding_clone")


# ===================== 4. Worker & ICL Execution =====================


class FakeIclGenerationResult:
    sample_rate = 24_000
    audio = np.array([0.1, 0.2, 0.3, 0.4], dtype=np.float32)
    is_final_chunk = True


class FakeIclMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def __init__(self) -> None:
        self.icl_calls: list[dict[str, object]] = []

    def _generate_icl(self, **kwargs: object):
        self.icl_calls.append(kwargs)
        yield FakeIclGenerationResult()


class FakePreviewMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def __init__(self) -> None:
        self.generate_calls: list[dict[str, object]] = []

    def generate(self, **kwargs: object):
        self.generate_calls.append(kwargs)
        yield FakeIclGenerationResult()


def test_mlx_voice_design_engine_accepts_ephemeral_preview_instruction(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    model = FakePreviewMlxModel()
    monkeypatch.setattr(
        worker_module,
        "inspect_model",
        lambda _: SnapshotIdentity(
            family="qwen3_tts",
            variant="voice_design",
            quantization=QuantizationSpec(bits=8, group_size=64, format="mlx"),
            weight_fingerprint="shape:" + ("p" * 64),
        ),
    )
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        sample_rate=24_000,
        load_fn=lambda _: model,
        numpy_module=np,
        warmup=False,
    )

    chunks = list(
        engine.synthesize(
            "试听这一句。",
            voice="serena",
            speed=1.0,
            language="zh",
            instruction="温暖自然的中文女声。",
            seed=12345,
        )
    )

    assert chunks
    assert len(model.generate_calls) == 1
    call = model.generate_calls[0]
    assert call["instruct"] == "温暖自然的中文女声。"
    assert "voice" not in call


def test_mlx_voice_design_engine_routes_icl_generation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    model = FakeIclMlxModel()
    ref_audio_file = tmp_path / "ref.wav"
    ref_audio_file.write_bytes(_generate_test_wav(duration_seconds=2.5))

    monkeypatch.setattr(
        worker_module,
        "inspect_model",
        lambda _: SnapshotIdentity(
            family="qwen3_tts",
            variant="voice_design",
            quantization=QuantizationSpec(bits=8, group_size=64, format="mlx"),
            weight_fingerprint="shape:" + ("c" * 64),
        ),
    )
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        sample_rate=24_000,
        load_fn=lambda _: model,
        numpy_module=np,
        audio_loader_fn=lambda p, sample_rate: np.zeros(100, dtype=np.float32),
        warmup=False,
    )

    chunks = list(
        engine.synthesize(
            "测试克隆语音生成。",
            voice="clone_sample",
            speed=1.0,
            language="zh",
            ref_audio=str(ref_audio_file),
            ref_text="参考朗读文本",
        )
    )

    assert len(chunks) == 1
    assert len(model.icl_calls) == 1
    call = model.icl_calls[0]
    assert call["text"] == "测试克隆语音生成。"
    assert call["ref_text"] == "参考朗读文本"
    assert call["language"] == "zh"
    assert call["stream"] is True


def test_mlx_voice_design_engine_rejects_missing_audio_or_text(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        worker_module,
        "inspect_model",
        lambda _: SnapshotIdentity(
            family="qwen3_tts",
            variant="voice_design",
            quantization=QuantizationSpec(bits=8, group_size=64, format="mlx"),
            weight_fingerprint="shape:" + ("c" * 64),
        ),
    )
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        sample_rate=24_000,
        load_fn=lambda _: FakeIclMlxModel(),
        numpy_module=np,
        audio_loader_fn=lambda p, sample_rate: np.zeros(100, dtype=np.float32),
        warmup=False,
    )

    # Missing audio file
    with pytest.raises(RuntimeError, match="failed to load reference audio: file missing"):
        list(
            engine.synthesize(
                "测试",
                voice="test",
                speed=1.0,
                language="zh",
                ref_audio=str(tmp_path / "non_existent.wav"),
                ref_text="朗读文本",
            )
        )

    # Loader returns empty array
    valid_file = tmp_path / "ref.wav"
    valid_file.write_bytes(b"dummy")
    engine_broken_loader = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        sample_rate=24_000,
        load_fn=lambda _: FakeIclMlxModel(),
        numpy_module=np,
        audio_loader_fn=lambda p, sample_rate: None,
        warmup=False,
    )
    with pytest.raises(RuntimeError, match="failed to decode reference audio: empty array"):
        list(
            engine_broken_loader.synthesize(
                "测试",
                voice="test",
                speed=1.0,
                language="zh",
                ref_audio=str(valid_file),
                ref_text="朗读文本",
            )
        )


# ===================== 5. HTTP API Endpoints =====================


def test_api_voices_clone_prompts() -> None:
    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))
    resp = client.get("/v1/voices/clone/prompts")
    assert resp.status_code == 200
    body = resp.json()
    assert body["object"] == "list"
    assert len(body["data"]) >= 4
    prompt_ids = {p["id"] for p in body["data"]}
    expected_prompts = {
        "poetry_tang",
        "prose_technology",
        "daily_dialogue",
        "philosophical_exploration",
    }
    assert expected_prompts.issubset(prompt_ids)


def test_api_voices_clone_success_in_quality_tier(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, reg = _make_test_client(tmp_path, "quality")
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: reg)
    monkeypatch.setattr(
        "speechrail.backends.qwen3_voice_binding.get_voice_profile", reg.get_profile
    )

    wav_bytes = _generate_test_wav(duration_seconds=4.0)

    # Mock transcode_and_validate_clone_audio to return the sample wav
    monkeypatch.setattr(
        "speechrail.domain.tts.transcode_and_validate_clone_audio",
        lambda *args, **kwargs: (wav_bytes, 4.0),
    )

    resp = client.post(
        "/v1/voices/clone",
        data={
            "name": "我的数字分身",
            "ref_text": "白日依山尽，黄河入海流。",
            "id": "my_clone_v1",
        },
        files={"audio": ("sample.wav", wav_bytes, "audio/wav")},
    )

    assert resp.status_code == 201
    created = resp.json()
    assert created["id"] == "my_clone_v1"
    assert created["name"] == "我的数字分身"
    assert created["mode"] == "clone"
    assert created["ref_text"] == "白日依山尽，黄河入海流。"
    assert created["duration_seconds"] == 4.0
    assert created["available"] is True
    assert created["variant"] == "voice_design"
    assert created["capabilities"]["supports_clone"] is True

    # Verify voice appears in /v1/voices
    voices = client.get("/v1/voices").json()["data"]
    cloned_entry = next((v for v in voices if v["id"] == "my_clone_v1"), None)
    assert cloned_entry is not None
    assert cloned_entry["mode"] == "clone"
    assert cloned_entry["available"] is True


def test_api_voices_clone_rejected_in_balanced_tier(tmp_path: Path) -> None:
    client, _reg = _make_test_client(tmp_path, "balanced")
    wav_bytes = _generate_test_wav(duration_seconds=3.0)

    resp = client.post(
        "/v1/voices/clone",
        data={
            "name": "尝试在均衡档克隆",
            "ref_text": "测试",
        },
        files={"audio": ("sample.wav", wav_bytes, "audio/wav")},
    )

    assert resp.status_code == 400
    err = resp.json()["error"]
    assert err["code"] == "voice_cloning_unsupported"
    assert "quality" in err["message"]


@pytest.mark.anyio
async def test_qwen3_tts_client_packs_clone_metadata_into_frame(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from speechrail.backends.qwen3_tts import Qwen3TtsBackendConfig, Qwen3TtsWorker
    from speechrail.runtime.worker_protocol import PROTOCOL_VERSION

    storage_path = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    reg = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", reg)
    monkeypatch.setattr(
        "speechrail.backends.qwen3_voice_binding.get_voice_profile", reg.get_profile
    )

    wav_bytes = _generate_test_wav(duration_seconds=3.0)
    profile = reg.create_cloned_profile(
        name="测试",
        ref_text="引导文本",
        audio_bytes=wav_bytes,
        voice_id="clone_for_ipc",
        duration_seconds=3.0,
    )

    sent_frames: list[dict[str, object]] = []

    chunk_sent = False

    class FakeTransport:
        alive = True

        async def start(self) -> None:
            pass

        async def send(self, frame: dict[str, object]) -> None:
            sent_frames.append(frame)

        async def receive(self) -> dict[str, object]:
            nonlocal chunk_sent
            if len(sent_frames) == 1:
                # Ready handshake response
                from speechrail.backends.qwen3_tts_worker import TTS_BACKEND_ID

                return {
                    "version": PROTOCOL_VERSION,
                    "type": "ready",
                    "model_loaded": True,
                    "backend": TTS_BACKEND_ID,
                    "device": "mps",
                    "dtype": "float16",
                    "sample_rate": 24_000,
                }
            # Synthesis audio chunk response followed by completed
            if len(sent_frames) == 2:
                if not chunk_sent:
                    chunk_sent = True
                    return {
                        "version": PROTOCOL_VERSION,
                        "type": "audio",
                        "request_id": sent_frames[-1]["request_id"],
                        "chunk_index": 0,
                        "_binary": b"\x00\x00" * 100,
                    }
                return {
                    "version": PROTOCOL_VERSION,
                    "type": "completed",
                    "request_id": sent_frames[-1]["request_id"],
                }
            return {}

        async def abort(self) -> None:
            pass

    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    model_dir = tmp_path / "models" / "tts"
    model_dir.mkdir(parents=True)
    (model_dir / "config.json").write_text('{"tts_model_type": "voice_design"}')

    config = Qwen3TtsBackendConfig(
        repository_root=repo_root,
        python_executable=Path("/usr/bin/python3"),
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
    )
    worker = Qwen3TtsWorker(config)
    worker._transport = FakeTransport()  # type: ignore[assignment]
    worker.model_variant = "voice_design"

    request = SpeechRequest(
        text="合成这一句。",
        voice="clone_for_ipc",
        output_format="pcm16",
    )

    _chunks = [c async for c in worker.synthesize(request)]
    assert _chunks
    assert len(sent_frames) == 2
    synth_frame = sent_frames[1]
    assert synth_frame["type"] == "synthesize"
    assert synth_frame["voice"] == "clone_for_ipc"
    assert synth_frame["ref_audio"] == profile.audio_path
    assert synth_frame["ref_text"] == "引导文本"


def test_audio_speech_with_cloned_voice_across_tiers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # 1. Quality tier: clone is available, /v1/audio/speech accepts it
    client_q, reg_q = _make_test_client(tmp_path / "q", "quality")
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", reg_q)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: reg_q)
    monkeypatch.setattr(
        "speechrail.backends.qwen3_voice_binding.get_voice_profile", reg_q.get_profile
    )

    wav_bytes = _generate_test_wav(duration_seconds=3.0)
    reg_q.create_cloned_profile(
        name="品质音色",
        ref_text="测试",
        audio_bytes=wav_bytes,
        voice_id="quality_clone_voice",
        duration_seconds=3.0,
    )

    resp_q = client_q.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "播放测试音频",
            "voice": "quality_clone_voice",
        },
    )
    assert resp_q.status_code == 200

    # 2. Balanced tier: clone is unavailable, /v1/audio/speech rejects it with 400
    client_b, reg_b = _make_test_client(tmp_path / "b", "balanced")
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", reg_b)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: reg_b)
    monkeypatch.setattr(
        "speechrail.backends.qwen3_voice_binding.get_voice_profile", reg_b.get_profile
    )

    reg_b.create_cloned_profile(
        name="均衡音色",
        ref_text="测试",
        audio_bytes=wav_bytes,
        voice_id="balanced_clone_voice",
        duration_seconds=3.0,
    )

    resp_b = client_b.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "播放测试音频",
            "voice": "balanced_clone_voice",
        },
    )
    assert resp_b.status_code == 400
    err_b = resp_b.json()["error"]
    assert err_b["code"] == "voice_not_available"
