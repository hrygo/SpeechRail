"""Issue #116: isolated IPC, lane-specific health and private failure attribution."""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys
from io import BytesIO
from pathlib import Path
from typing import Any

import pytest
import yaml
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from speechrail.app import create_app
from speechrail.backends.qwen3_tts import (
    Qwen3TtsBackendConfig,
    Qwen3TtsCapabilityRouter,
    Qwen3TtsWorker,
)
from speechrail.config import Settings
from speechrail.config.model_catalog import VOICE_DESIGN_ARTIFACT_KEY
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.tts_errors import TtsBackendError
from speechrail.infrastructure.voice_registry import FileVoiceRegistry as VoiceRegistry
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    WorkerTransportError,
    offline_environment,
)
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_DETAIL = "private-input-and-model-path-must-not-leak"
PREVIEW = {
    "model": "tts-1",
    "input": "测试设计通道。",
    "instruction": "自然清晰的中文声音。",
    "response_format": "wav",
}


def test_worker_main_keeps_python_and_native_diagnostics_out_of_protocol(tmp_path: Path) -> None:
    """Use the real entry point and pipes, with no vendor imports or model loading."""
    source = BytesIO()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(tmp_path),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    for request_id in ("first", "second"):
        write_frame(
            source,
            {
                "version": PROTOCOL_VERSION,
                "type": "synthesize",
                "request_id": request_id,
                "text": "测试。",
                "voice": "serena",
                "speed": 1.0,
                "instruction": "清晰的声音。",
            },
        )
    script = """
import os
import sys
from speechrail.backends import qwen3_tts_worker as worker

worker._apply_metal_limits = lambda *args: None
worker._clear_metal_cache = lambda: None
worker._identity_matches_tts = lambda *args, **kwargs: True

class Engine:
    identity = worker.TtsWorkerIdentity(
        device="mps", dtype="float16", sample_rate=24000,
        family="qwen3_tts", model_variant="voice_design",
    )

    def synthesize(self, text, **kwargs):
        print("fake generator diagnostic", flush=True)
        os.write(1, b"native generator diagnostic\\n")
        yield b"\\x00\\x00"

def factory(path):
    print("fake loader diagnostic", flush=True)
    os.write(1, b"native loader diagnostic\\n")
    return Engine()

worker.main(
    ["--model-dir", sys.argv[1], "--device", "mps", "--sample-rate", "24000"],
    engine_factory=factory,
)
"""
    result = subprocess.run(
        [sys.executable, "-c", script, str(tmp_path)],
        input=source.getvalue(),
        capture_output=True,
        env=offline_environment(ROOT),
        cwd=ROOT,
        timeout=10,
        check=True,
    )
    output = BytesIO(result.stdout)
    assert read_frame(output)["type"] == "ready"
    for request_id in ("first", "second"):
        audio = read_frame(output)
        assert audio["request_id"] == request_id
        assert audio["_binary"] == b"\x00\x00"
        assert read_frame(output) == {
            "version": PROTOCOL_VERSION,
            "type": "completed",
            "request_id": request_id,
        }
    assert read_frame(output) is None
    for diagnostic in (
        b"fake loader diagnostic",
        b"native loader diagnostic",
        b"fake generator diagnostic",
        b"native generator diagnostic",
    ):
        assert diagnostic in result.stderr
        assert diagnostic not in result.stdout


class _Transport:
    def __init__(self, variant: str) -> None:
        self.variant = variant
        self.alive = False
        self.fail_initialize = False
        self.fail_delivery = False
        self.fail_send = False
        self.failure: Exception = ProtocolError(PRIVATE_DETAIL)
        self.response_id = ""
        self._handshake = True
        self._audio_sent = False

    async def start(self) -> None:
        self.alive = True
        self._handshake = True

    async def send(self, payload: dict[str, Any]) -> None:
        if payload["type"] == "synthesize":
            if self.fail_send:
                raise self.failure
            self.response_id = payload["request_id"]
            self._audio_sent = False

    async def receive(self) -> dict[str, Any]:
        if self._handshake:
            if self.fail_initialize:
                raise self.failure
            self._handshake = False
            return {
                "type": "ready",
                "backend": "mlx-qwen3-tts",
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
                "model_loaded": True,
                "model_variant": self.variant,
                "profile_snapshot_version": 1,
            }
        if self.fail_delivery:
            raise self.failure
        if not self._audio_sent:
            self._audio_sent = True
            return {
                "type": "audio",
                "request_id": self.response_id,
                "chunk_index": 0,
                "_binary": b"\x00\x00",
            }
        return {"type": "completed", "request_id": self.response_id}

    async def abort(self) -> None:
        self.alive = False


def _worker(tmp_path: Path, variant: str, *, voice_store=None) -> tuple[Qwen3TtsWorker, _Transport]:
    snapshot = tmp_path / variant
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}", encoding="utf-8")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=ROOT,
            python_executable=Path(sys.executable),
            model_dir=snapshot,
            model_variant=variant,  # type: ignore[arg-type]
            device="mps",
        ),
        voice_leases=voice_store
        if voice_store is not None
        else VoiceRegistry.open(tmp_path / "voices.json", tmp_path / "voices"),
    )
    transport = _Transport(variant)
    worker._transport = transport  # type: ignore[assignment]
    return worker, transport


def _client(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, *, with_design: bool = True
) -> tuple[TestClient, Qwen3TtsCapabilityRouter, _Transport | None]:
    registry = VoiceRegistry.open(tmp_path / "voices.json", voices_dir=tmp_path / "voices")
    primary, _ = _worker(tmp_path, "custom_voice", voice_store=registry)
    workers = {"tts_custom_voice": primary}
    design = None
    if with_design:
        design_worker, design = _worker(tmp_path, "voice_design", voice_store=registry)
        workers["voice_design"] = design_worker
    router = Qwen3TtsCapabilityRouter(workers, voice_directory=registry)
    settings = Settings(
        api_key=None,
        qwen3_model_dir=None,
        qwen3_python=None,
        qwen3_tts_python=None,
        qwen3_tts_model_dir=primary.config.model_dir,
        selection_schema_version=2,
        selection_asr_spec="quality",
        selection_tts_spec="quality",
        asr_artifact_key=required_spec_artifact("quality", "asr"),
        tts_artifact_key=required_spec_artifact("quality", "tts_custom_voice"),
        voice_design_artifact_key=VOICE_DESIGN_ARTIFACT_KEY if with_design else None,
        worker_idle_timeout_seconds=0,
    )

    class Asr:
        async def transcribe(self, request: object) -> None:
            raise AssertionError("a failed design must not invoke ASR")

    return (
        TestClient(
            create_app(
                settings, tts_synthesizer=router, batch_transcriber=Asr(), voice_store=registry
            )
        ),
        router,
        design,
    )


def _validate_contract(schema_name: str, payload: dict[str, Any]) -> None:
    contract = yaml.safe_load((ROOT / "contracts/openapi.yaml").read_text(encoding="utf-8"))
    schema = {
        "$ref": f"#/components/schemas/{schema_name}",
        "components": contract["components"],
    }
    Draft202012Validator(schema).validate(payload)


@pytest.mark.parametrize("phase", ["initialize", "send", "deliver"])
@pytest.mark.parametrize("cause", ["protocol", "exit", "timeout"])
def test_design_failure_is_attributed_and_does_not_hide_runtime_health(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
    phase: str,
    cause: str,
) -> None:
    client, router, design = _client(tmp_path, monkeypatch)
    assert design is not None
    flag = {"initialize": "fail_initialize", "send": "fail_send", "deliver": "fail_delivery"}
    setattr(design, flag[phase], True)
    stage = "initialize" if phase == "initialize" else "deliver"
    if cause == "exit":
        design.failure = WorkerTransportError(
            PRIVATE_DETAIL,
            diagnostic_class="worker_eof",
            exit_code=7,
            exception_type="ModuleNotFoundError",
        )
    elif cause == "timeout":
        design.failure = TimeoutError(PRIVATE_DETAIL)
    with client:
        asyncio.run(router.start())
        before = client.get("/health").json()
        assert before["tts_warm"] is True
        assert before["tts_design"] == {
            "configured": True,
            "ready": False,
            "state": "cold",
            "last_error": None,
        }
        failed = client.post("/v1/voices/previews", json=PREVIEW)
        assert failed.status_code == 503
        error = failed.json()["error"]
        assert error["code"] == (
            "backend_timeout" if cause == "timeout" else "tts_transport_failed"
        )
        assert error["diagnostic_class"] == {
            "protocol": "worker_protocol_invalid",
            "exit": "worker_eof",
            "timeout": "worker_timeout",
        }[cause]
        assert error["worker"]["role"] == "voice_design"
        assert error["worker"]["stage"] == stage
        if cause == "exit":
            assert error["worker"]["exit_code"] == 7
            assert error["worker"]["exception_type"] == "ModuleNotFoundError"
        assert error["worker"]["attempt_id"].startswith("tts_attempt_")
        assert error["request_id"] == failed.headers["X-Request-ID"]
        _validate_contract("ErrorBody", failed.json())
        health = client.get("/health").json()
        assert health["tts_ready"] is True
        assert health["tts_warm"] is True
        assert health["tts_design"]["state"] == "failed"
        assert health["tts_design"]["ready"] is False
        assert health["tts_design"]["last_error"] == {
            "code": error["code"],
            "diagnostic_class": error["diagnostic_class"],
            "worker": error["worker"],
        }
        _validate_contract("HealthResponse", health)
        assert PRIVATE_DETAIL not in json.dumps(health)
        assert PRIVATE_DETAIL not in failed.text
        assert PRIVATE_DETAIL not in caplog.text
        assert "role=voice_design" in caplog.text
        assert f"stage={stage}" in caplog.text

        design.fail_initialize = design.fail_delivery = design.fail_send = False
        recovered = client.post("/v1/voices/previews", json=PREVIEW)
        assert recovered.status_code == 200
        assert recovered.content[:4] == b"RIFF"
        assert client.get("/health").json()["tts_design"] == {
            "configured": True,
            "ready": True,
            "state": "ready",
            "last_error": None,
        }
        asyncio.run(router.evict_warm_capability())
        cooled = client.get("/health").json()["tts_design"]
        assert cooled["state"] == "cold"
        assert cooled["last_error"] is None


def test_missing_design_worker_has_explicit_health_without_loading(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, _router, _ = _client(tmp_path, monkeypatch, with_design=False)
    health = client.get("/health").json()
    assert health["tts_design"] == {
        "configured": False,
        "ready": False,
        "state": "unconfigured",
        "last_error": None,
    }
    _validate_contract("HealthResponse", health)


def test_design_loading_and_idle_exit_are_visible_and_restartable(tmp_path: Path) -> None:
    worker, transport = _worker(tmp_path, "voice_design")

    async def run() -> None:
        entered = asyncio.Event()
        release = asyncio.Event()
        original_receive = transport.receive

        async def gated_receive() -> dict[str, Any]:
            entered.set()
            await release.wait()
            return await original_receive()

        transport.receive = gated_receive  # type: ignore[method-assign]
        task = asyncio.create_task(worker.start())
        await entered.wait()
        assert worker.diagnostic_status == {
            "configured": True, "ready": False, "state": "loading", "last_error": None,
        }
        release.set()
        await task
        first_attempt = worker._worker_attempt_id
        transport.alive = False
        assert worker.diagnostic_status["state"] == "failed"
        assert worker.diagnostic_status["ready"] is False
        await worker.start()
        assert worker.ready
        assert worker._worker_attempt_id != first_attempt
        assert worker.diagnostic_status["last_error"] is None
        await worker.close()
        assert worker.diagnostic_status["state"] == "cold"

    asyncio.run(run())


def test_preview_uses_conservative_design_lane_instead_of_default_speaker_lane(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from speechrail.http.routes import audio as audio_routes

    def wrong_lane(*args: object) -> str:
        raise AssertionError("VoiceDesign must not resolve a runtime voice lane")

    monkeypatch.setattr(audio_routes, "tts_resource_key", wrong_lane)
    client, _router, _design = _client(tmp_path, monkeypatch)
    with client:
        response = client.post("/v1/voices/previews", json=PREVIEW)
    assert response.status_code == 200


def test_candidate_creation_uses_same_transport_status_and_diagnostics_as_preview(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, _router, design = _client(tmp_path, monkeypatch)
    assert design is not None
    design.fail_delivery = True
    with client:
        response = client.post(
            "/v1/voice-designs",
            json={
                "voice_id": "diagnostic_candidate",
                "name": "测试候选",
                "instruction": "自然清晰的中文声音。",
                "reference_text": "这是一段用于诊断设计通道的测试文本，请保持自然清晰的表达。",
                "language": "zh",
            },
        )
    assert response.status_code == 503
    error = response.json()["error"]
    assert error["code"] == "tts_transport_failed"
    assert error["worker"]["role"] == "voice_design"
    assert error["worker"]["stage"] == "deliver"
    assert PRIVATE_DETAIL not in response.text
    _validate_contract("ErrorBody", response.json())


def test_backend_error_keeps_worker_metadata_separate_from_private_detail() -> None:
    failure = TtsBackendError(
        "worker_frame_invalid", stage="initialize", public_code="tts_transport_failed",
        detail=PRIVATE_DETAIL,
        worker_role=PRIVATE_DETAIL,
        worker_attempt_id=PRIVATE_DETAIL,
        worker_exception_type=PRIVATE_DETAIL,
        worker_exit_code=True,
    )
    assert PRIVATE_DETAIL not in str(failure)
    assert PRIVATE_DETAIL not in json.dumps(failure.worker_diagnostics)
    assert failure.worker_diagnostics == {"stage": "initialize"}


def test_worker_exit_has_structured_cause_without_using_stderr_for_error_classification() -> None:
    script = (
        "import sys\n"
        f"print('ModuleNotFoundError: {PRIVATE_DETAIL}', file=sys.stderr, flush=True)\n"
        "sys.exit(7)\n"
    )
    transport = AsyncFramedWorkerProcess(
        WorkerProcessSpec(
            command=(sys.executable, "-c", script),
            cwd=ROOT,
            env=offline_environment(ROOT),
            io_timeout_seconds=5,
        )
    )

    async def run() -> None:
        try:
            await transport.start()
            with pytest.raises(ProtocolError) as caught:
                await transport.receive()
            assert caught.value.diagnostic_class == "worker_eof"
            assert caught.value.exit_code == 7
            assert caught.value.exception_type == "ModuleNotFoundError"
        finally:
            await transport.close()

    asyncio.run(run())


def test_worker_stderr_is_byte_bounded_and_not_logged_verbatim(
    caplog: pytest.LogCaptureFixture,
) -> None:
    script = (
        "import sys\n"
        "from speechrail.runtime.worker_protocol import write_frame\n"
        f"print('{PRIVATE_DETAIL}' * 4000, file=sys.stderr, flush=True)\n"
        "write_frame(sys.stdout.buffer, {'type': 'error', 'code': 'worker_load_error'})\n"
    )
    transport = AsyncFramedWorkerProcess(
        WorkerProcessSpec(
            command=(sys.executable, "-c", script),
            cwd=ROOT,
            env=offline_environment(ROOT),
            io_timeout_seconds=5,
        )
    )

    async def run() -> None:
        try:
            await transport.start()
            frame = await transport.receive()
            assert frame["code"] == "worker_load_error"
            assert PRIVATE_DETAIL in frame["stderr_tail"]
            assert len(frame["stderr_tail"].encode("utf-8")) <= 16 * 1024
            assert PRIVATE_DETAIL not in caplog.text
        finally:
            await transport.close()

    asyncio.run(run())
