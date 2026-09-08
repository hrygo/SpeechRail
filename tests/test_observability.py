import logging

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
