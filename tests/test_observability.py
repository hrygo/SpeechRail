import logging

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
