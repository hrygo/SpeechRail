import json
import logging
from collections.abc import Iterator
from datetime import date
from pathlib import Path

import pytest

from speechrail.domain.errors import BackendNotReadyError
from speechrail.observability.logging import event
from speechrail.observability.metrics import Metrics


def test_observability_uses_low_cardinality_metadata_only(caplog: object) -> None:
    metrics = Metrics()
    metrics.increment("requests", "success")
    assert metrics.snapshot() == {"requests:success": 1}

    logger = logging.getLogger("speechrail.test")
    event(logger, "request", request_id="req_1", model="model", transcript="private")
    assert BackendNotReadyError().code == "backend_not_ready"


def test_access_event_keeps_bounded_fields_and_drops_sensitive_values(
    caplog: pytest.LogCaptureFixture,
) -> None:
    from speechrail.observability.logging import access

    logger = logging.getLogger("speechrail.test.access")
    with caplog.at_level(logging.INFO, logger=logger.name):
        access(
            logger,
            timestamp="2026-09-08T00:00:00Z",
            request_id="req_test",
            route="/v1/audio/speech",
            status=503,
            outcome="error",
            duration_ms=12.5,
            error_code="backend_timeout",
            tts_warm=False,
            Authorization="Bearer secret",
            body="private audio",
            voice="custom-secret",
        )

    record = caplog.records[-1].speechrail
    assert record == {
        "timestamp": "2026-09-08T00:00:00Z",
        "request_id": "req_test",
        "route": "/v1/audio/speech",
        "status": 503,
        "outcome": "error",
        "duration_ms": 12.5,
        "error_code": "backend_timeout",
        "tts_warm": False,
    }
    assert "secret" not in str(record)
    assert "private" not in str(record)
    assert "custom-secret" not in str(record)


def test_metrics_endpoint_prometheus_format() -> None:
    from fastapi.testclient import TestClient

    from speechrail.app import create_app
    from speechrail.config import Settings

    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "text/plain" in response.headers["content-type"]
    text = response.text
    assert "speechrail_governor_active_requests" in text
    assert "speechrail_governor_pending_requests" in text
    assert "speechrail_health_status" in text


def test_http_access_record_is_emitted_with_request_id_and_error_code(
    caplog: pytest.LogCaptureFixture,
) -> None:
    from fastapi.testclient import TestClient

    from speechrail.app import create_app
    from speechrail.config import Settings

    with caplog.at_level(logging.INFO, logger="speechrail.app"), TestClient(
        create_app(Settings(qwen3_model_dir=None, qwen3_python=None))
    ) as client:
        response = client.get("/readyz", headers={"X-Request-ID": "req_access"})

    assert response.status_code == 503
    records = [
        record.speechrail
        for record in caplog.records
        if record.name == "speechrail.app" and hasattr(record, "speechrail")
    ]
    assert len(records) == 1
    assert records[0]["request_id"] == "req_access"
    assert records[0]["route"] == "/readyz"
    assert records[0]["status"] == 503
    assert records[0]["outcome"] == "completed"
    assert records[0]["error_code"] == "backend_not_ready"
    assert records[0]["tts_warm"] is False


def test_metrics_endpoint_json_format() -> None:
    from fastapi.testclient import TestClient

    from speechrail.app import create_app
    from speechrail.config import Settings

    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))
    response = client.get("/metrics", headers={"Accept": "application/json"})
    assert response.status_code == 200
    assert "application/json" in response.headers["content-type"]
    data = response.json()
    assert "active_requests" in data
    assert "pending_requests" in data
    assert "workers" in data
    assert "health" in data
    assert data["health"]["asr"] is False
    assert "counters" in data
    assert "histograms" in data
    assert "resources" in data
    assert "physical_memory_bytes" in data["resources"]


def test_metrics_engine_counter_gauge_histogram() -> None:
    """Verify the Metrics engine primitives work correctly."""
    m = Metrics()

    # Counter
    m.inc("test_counter", endpoint="/test")
    m.inc("test_counter", amount=2.0, endpoint="/test")

    # Gauge
    m.set_gauge("test_gauge", 42.0)
    m.inc_gauge("test_gauge", 8.0)
    m.dec_gauge("test_gauge", 10.0)

    # Histogram
    m.observe("test_hist", 0.5, (0.1, 0.5, 1.0))
    m.observe("test_hist", 0.05, (0.1, 0.5, 1.0))

    text = m.render_prometheus()
    assert "test_counter" in text
    assert "3" in text  # 1 + 2
    assert "test_gauge" in text
    assert "40" in text  # 42 + 8 - 10
    assert "test_hist_bucket" in text
    assert "test_hist_count" in text
    assert "+Inf" in text


def test_metrics_record_asr_records_rtf() -> None:
    """Verify record_asr populates RTF histogram."""
    m = Metrics()
    m.record_asr(audio_duration_sec=10.0, inference_duration_sec=1.0)
    text = m.render_prometheus()
    assert "speechrail_asr_processed_audio_seconds_total" in text
    assert "speechrail_asr_inference_duration_seconds" in text
    assert "speechrail_asr_rtf" in text


def test_metrics_record_tts_records_rtf() -> None:
    """Verify TTS RTF is derived from measured inference and audio durations."""
    m = Metrics()
    m.record_tts(
        voice_class="system",
        char_count=10,
        audio_duration_sec=2.0,
        inference_duration_sec=1.0,
    )
    text = m.render_prometheus()

    assert 'speechrail_tts_rtf_bucket{le="0.5",voice_class="system"} 1' in text
    assert 'speechrail_tts_rtf_count{voice_class="system"} 1' in text


def test_realtime_phase_metrics_use_a_bounded_phase_label() -> None:
    metrics = Metrics()
    metrics.record_realtime_phase("asr_admission", 0.04)
    metrics.record_realtime_phase("send", 0.01)
    text = metrics.render_prometheus()

    assert "speechrail_realtime_phase_duration_seconds_bucket" in text
    assert 'phase="asr_admission"' in text
    assert 'phase="send"' in text


def test_delivery_metrics_keep_alignment_and_tts_events_low_cardinality() -> None:
    metrics = Metrics()

    metrics.record_alignment_event("fixed_text_completed")
    metrics.record_alignment_event("fixed_text_unavailable")
    metrics.record_tts_delivery_event("planner_chunk", amount=2)
    metrics.record_tts_delivery_event("reference_cache_hit")
    metrics.record_tts_delivery_event("clone_loudness_request")
    metrics.record_tts_delivery_event("clone_loudness_calibrated")
    metrics.record_tts_delivery_event("clone_loudness_peak_ceiling", amount=2)
    metrics.record_tts_delivery_event("abort_fallback")
    metrics.record_tts_delivery_event("reload")

    text = metrics.render_prometheus()
    assert 'speechrail_asr_alignment_events_total{event="fixed_text_completed"} 1' in text
    assert 'speechrail_asr_alignment_events_total{event="fixed_text_unavailable"} 1' in text
    assert 'speechrail_tts_delivery_events_total{event="planner_chunk"} 2' in text
    assert 'speechrail_tts_delivery_events_total{event="reference_cache_hit"} 1' in text
    assert 'speechrail_tts_delivery_events_total{event="clone_loudness_request"} 1' in text
    assert 'speechrail_tts_delivery_events_total{event="clone_loudness_calibrated"} 1' in text
    assert 'speechrail_tts_delivery_events_total{event="clone_loudness_peak_ceiling"} 2' in text
    assert 'speechrail_tts_delivery_events_total{event="abort_fallback"} 1' in text
    assert 'speechrail_tts_delivery_events_total{event="reload"} 1' in text


def test_metrics_escapes_label_values() -> None:
    """Verify label values with special chars stay parser-compatible."""
    m = Metrics()
    m.inc("esc_counter", **{"endpoint": 'weird"path\\with\nnewline'})
    text = m.render_prometheus()
    assert 'weird\\"path\\\\with\\nnewline' in text


def test_metrics_governor_uses_class_label() -> None:
    """Verify governor gauges and rejections share the low-cardinality class label."""
    from types import SimpleNamespace

    m = Metrics()
    snap = SimpleNamespace(active_realtime=1, active_batch=0, pending_realtime=0, pending_batch=0)
    text = m.render_prometheus(governor_snapshot=snap)
    assert 'speechrail_governor_active_requests{class="realtime"} 1' in text


@pytest.fixture
def restore_logging() -> Iterator[None]:
    """Undo the process-wide logging configuration installed by a test."""
    root = logging.getLogger()
    handlers = list(root.handlers)
    level = root.level
    vendor = logging.getLogger("uvicorn.access")
    vendor_handlers = list(vendor.handlers)
    vendor_propagate = vendor.propagate
    vendor_level = vendor.level
    yield
    for handler in list(root.handlers):
        if handler not in handlers:
            root.removeHandler(handler)
            handler.close()
    root.handlers = handlers
    root.setLevel(level)
    vendor.handlers = vendor_handlers
    vendor.propagate = vendor_propagate
    vendor.setLevel(vendor_level)


def test_configure_logging_writes_rotated_service_and_access_logs(
    tmp_path: Path, restore_logging: None
) -> None:
    """Both files are created: readable lines and one JSON object per record."""
    from speechrail.observability.logging import access, configure_logging

    handles = configure_logging(tmp_path / "logs", console=False)

    assert handles is not None
    logger = logging.getLogger("speechrail.test.rotation")
    logger.info("service started")
    access(
        logger,
        timestamp="2026-09-16T00:00:00Z",
        request_id="req_file",
        route="/v1/audio/speech",
        status=200,
        outcome="completed",
        duration_ms=812.5,
        error_code=None,
        tts_warm=True,
        worker_state="active",
        Authorization="Bearer secret",
    )

    service_text = handles.service_log.read_text(encoding="utf-8")
    assert "service started" in service_text
    assert "request_id=req_file" in service_text
    assert "duration_ms=812.5" in service_text
    assert "secret" not in service_text

    records = [
        json.loads(line) for line in handles.access_log.read_text(encoding="utf-8").splitlines()
    ]
    assert [record["event"] for record in records] == ["http_access"]
    assert records[0]["route"] == "/v1/audio/speech"
    assert records[0]["status"] == 200
    assert records[0]["duration_ms"] == 812.5
    assert "secret" not in json.dumps(records)
    assert handles.service_log.stat().st_mode & 0o777 == 0o600
    assert handles.access_log.stat().st_mode & 0o777 == 0o600


def test_configure_logging_fails_open_when_the_directory_is_unusable(
    tmp_path: Path, restore_logging: None
) -> None:
    """An unusable log directory keeps the previous logging configuration."""
    from speechrail.observability.logging import configure_logging

    blocked = tmp_path / "blocked"
    blocked.write_text("not a directory", encoding="utf-8")
    root = logging.getLogger()
    before = list(root.handlers)

    assert configure_logging(blocked, console=False) is None
    assert list(root.handlers) == before


def test_access_records_reach_a_handler_and_the_file(tmp_path: Path, restore_logging: None) -> None:
    """Regression: ``http_access`` used to be emitted with no handler at all."""
    from fastapi.testclient import TestClient

    from speechrail.app import create_app
    from speechrail.config import Settings
    from speechrail.observability.logging import configure_logging

    handles = configure_logging(tmp_path / "logs", console=False)
    assert handles is not None
    with TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None))) as client:
        response = client.get("/readyz", headers={"X-Request-ID": "req_file"})

    assert response.status_code == 503
    records = [
        json.loads(line) for line in handles.access_log.read_text(encoding="utf-8").splitlines()
    ]
    http_access = [record for record in records if record["event"] == "http_access"]
    assert http_access
    assert http_access[-1]["request_id"] == "req_file"
    assert http_access[-1]["route"] == "/readyz"
    assert http_access[-1]["status"] == 503


def _rollup(tmp_path: Path, metrics: Metrics, **overrides: object):
    from speechrail.observability.rollup import MetricsRollup, RollupContext, RollupResources

    arguments: dict[str, object] = {
        "directory": tmp_path / "metrics-rollup",
        "metrics": metrics,
        "context": lambda: RollupContext(
            workers={"asr": "active"},
            ready={"asr": True, "tts": False},
            active_requests=1,
            pending_requests=2,
            total_capacity=4,
            allow_heavy_overlap=True,
        ),
        "resources": lambda: RollupResources(
            physical_footprint_bytes=2048,
            footprint_complete=True,
            footprint_process_count=2,
            declared_footprint_bytes=1024,
        ),
        "service_version": "2.6.5",
        "profile": "quality",
    }
    arguments.update(overrides)
    return MetricsRollup(**arguments)  # type: ignore[arg-type]


def _rollup_file(tmp_path: Path) -> Path:
    from datetime import UTC, datetime

    return tmp_path / "metrics-rollup" / f"{datetime.now(UTC).date().isoformat()}.jsonl"


def test_rollup_records_interval_deltas_without_leaking_paths(tmp_path: Path) -> None:
    """One line per interval carries the usage, latency and capacity deltas."""
    metrics = Metrics()
    rollup = _rollup(tmp_path, metrics)
    rollup.write_interval()

    metrics.record_http_request("/v1/audio/speech", "POST", 200, 0.41)
    metrics.record_http_request("/v1/audio/transcriptions", "POST", 500, 2.4)
    metrics.record_http_request("/health", "GET", 200, 0.002)
    metrics.record_tts(
        voice_class="system", char_count=12, audio_duration_sec=2.5, inference_duration_sec=0.41
    )
    metrics.record_asr(audio_duration_sec=30.0, inference_duration_sec=2.4)
    metrics.record_governor_rejection("batch_tts")
    rollup.write_interval()

    lines = _rollup_file(tmp_path).read_text(encoding="utf-8")
    first, second = (json.loads(line) for line in lines.splitlines())

    assert first["requests"]["http_total"] == 0
    assert second["schema_version"] == 1
    assert second["kind"] == "metrics_rollup"
    assert second["requests"] == {
        "http_total": 3,
        "speech_total": 2,
        "tts": 1,
        "asr": 1,
        "failed": 1,
        "client_errors": 0,
        "by_status": {"200": 2, "500": 1},
        "by_endpoint": {
            "/health": 1,
            "/v1/audio/speech": 1,
            "/v1/audio/transcriptions": 1,
        },
    }
    assert second["audio_seconds"] == {"tts": 2.5, "asr": 30.0}
    assert second["latency_ms"]["tts"]["count"] == 1
    assert second["latency_ms"]["tts"]["avg"] == 410.0
    assert second["latency_ms"]["asr"]["avg"] == 2400.0
    assert second["latency_ms"]["by_endpoint"]["/v1/audio/speech"]["p95"] == 487.5
    assert second["capacity"]["queue_rejections"] == 1
    assert second["capacity"]["active_peak"] == 1
    assert second["capacity"]["allow_heavy_overlap"] is True
    assert second["memory"]["physical_footprint_bytes"] == 2048
    assert second["workers"]["states"] == {"asr": "active"}
    assert second["ready"] == {"asr": True, "tts": False}
    assert str(Path.home()) not in lines
    assert (tmp_path / "metrics-rollup").stat().st_mode & 0o777 == 0o700


def test_rollup_purges_files_past_the_retention_window(tmp_path: Path) -> None:
    """Retention is enforced by filename date without reading file contents."""
    directory = tmp_path / "metrics-rollup"
    directory.mkdir()
    (directory / "2026-08-01.jsonl").write_text("{}\n", encoding="utf-8")
    (directory / "2026-09-10.jsonl").write_text("{}\n", encoding="utf-8")
    (directory / "notes.txt").write_text("keep me", encoding="utf-8")
    rollup = _rollup(tmp_path, Metrics(), retention_days=30)

    removed = rollup.purge(date(2026, 9, 16))

    assert [path.name for path in removed] == ["2026-08-01.jsonl"]
    assert sorted(path.name for path in directory.iterdir()) == ["2026-09-10.jsonl", "notes.txt"]


def test_rollup_loop_appends_one_line_per_interval(tmp_path: Path) -> None:
    """The background task writes on its own, without an external trigger."""
    import asyncio

    rollup = _rollup(tmp_path, Metrics(), interval_seconds=0.05, sample_seconds=0.01)
    written = asyncio.run(_run_rollup_for(rollup, 0.24))

    assert written >= 1
    # `flush` waits for an append it interrupted, so the file and the counter
    # cannot disagree once `stop()` has returned.
    assert len(_rollup_file(tmp_path).read_text(encoding="utf-8").splitlines()) == written


def test_rollup_retries_a_failed_append_without_losing_counts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failed append extends the next interval instead of dropping counts."""
    import asyncio

    import speechrail.observability.rollup as rollup_module

    metrics = Metrics()
    rollup = _rollup(tmp_path, metrics)
    original_append = rollup_module.MetricsRollup._append
    attempts: list[int] = []

    def flaky_append(path: Path, record: dict) -> None:
        attempts.append(len(attempts))
        if len(attempts) == 2:
            raise OSError("disk full")
        original_append(path, record)

    monkeypatch.setattr(
        rollup_module.MetricsRollup, "_append", staticmethod(flaky_append)
    )
    assert asyncio.run(rollup.flush()) is not None

    metrics.record_http_request("/v1/audio/speech", "POST", 200, 0.5)
    assert asyncio.run(rollup.flush()) is None
    assert rollup.failures == 1

    metrics.record_http_request("/v1/audio/speech", "POST", 200, 0.5)
    assert asyncio.run(rollup.flush()) is not None

    lines = _rollup_file(tmp_path).read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    assert json.loads(lines[1])["requests"]["tts"] == 2


async def _run_rollup_for(rollup, seconds: float) -> int:
    import asyncio

    await rollup.start()
    await asyncio.sleep(seconds)
    await rollup.stop()
    return rollup.written
