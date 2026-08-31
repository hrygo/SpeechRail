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
