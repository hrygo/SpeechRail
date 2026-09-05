from __future__ import annotations

import httpx
import pytest

from speechrail.config.model_catalog import SourceLocation
from speechrail.service.modelscope import ModelScopeDownloader


def _source(**changes: str) -> SourceLocation:
    values = {
        "provider": "modelscope",
        "repository": "mlx-community/Qwen3-ASR-0.6B-8bit",
        "revision": "a" * 40,
    }
    values.update(changes)
    return SourceLocation.model_validate(values)


def _unsafe_source(**changes: str) -> SourceLocation:
    values = {
        "provider": "modelscope",
        "repository": "mlx-community/Qwen3-ASR-0.6B-8bit",
        "revision": "a" * 40,
    }
    values.update(changes)
    return SourceLocation.model_construct(**values)


def test_downloader_streams_exact_immutable_modelscope_file_and_closes() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, content=b"abcdef")

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        downloader = ModelScopeDownloader(client=client, chunk_size=2)
        stream = downloader.download(_source(), "nested/config.json")
        assert b"".join(stream) == b"abcdef"
        stream.close()

    assert len(requests) == 1
    request = requests[0]
    assert request.url.scheme == "https"
    assert request.url.host == "modelscope.cn"
    assert request.url.path == "/api/v1/models/mlx-community/Qwen3-ASR-0.6B-8bit/repo"
    assert request.url.params["Revision"] == "a" * 40
    assert request.url.params["FilePath"] == "nested/config.json"


@pytest.mark.parametrize(
    ("source", "path"),
    [
        (_source(provider="huggingface"), "config.json"),
        (_unsafe_source(revision="main"), "config.json"),
        (_unsafe_source(repository="bad repository"), "config.json"),
        (_source(), "../secret"),
        (_source(), "/absolute"),
        (_source(), "dir\\file"),
    ],
)
def test_downloader_rejects_untrusted_source_or_path(
    source: SourceLocation, path: str
) -> None:
    with httpx.Client(
        transport=httpx.MockTransport(lambda request: httpx.Response(200))
    ) as client, pytest.raises(ValueError):
        ModelScopeDownloader(client=client).download(source, path)


def test_downloader_redacts_remote_error() -> None:
    with httpx.Client(
        transport=httpx.MockTransport(lambda request: httpx.Response(503, text="remote secret"))
    ) as client, pytest.raises(ValueError, match="model source unavailable") as exc_info:
        ModelScopeDownloader(client=client).download(_source(), "config.json")
    assert "remote secret" not in str(exc_info.value)
