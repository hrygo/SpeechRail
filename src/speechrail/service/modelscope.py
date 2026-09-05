"""Direct, bounded ModelScope streams for immutable catalog artifacts."""

from __future__ import annotations

import re
from collections.abc import Iterator
from pathlib import PurePosixPath

import httpx

from speechrail.config.model_catalog import SourceLocation

_REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_REVISION = re.compile(r"[0-9a-f]{40}")


class ModelScopeDownloader:
    """Stream exact ModelScope files into SpeechRail's verified staging area.

    The official Hub client materializes its own cache before returning a
    file. SpeechRail uses the same public download endpoint directly so an
    8 GB machine does not need a second full snapshot on disk; the model store
    remains responsible for size, SHA-256, cancellation and publication.
    """

    def __init__(self, *, client: httpx.Client, chunk_size: int = 1024 * 1024) -> None:
        if chunk_size <= 0:
            raise ValueError("download chunk size must be positive")
        self._client = client
        self._chunk_size = chunk_size

    @staticmethod
    def _validate(source: SourceLocation, relative_path: str) -> None:
        if (
            not isinstance(source, SourceLocation)
            or source.provider != "modelscope"
            or not _REPOSITORY.fullmatch(source.repository)
            or not _REVISION.fullmatch(source.revision)
        ):
            raise ValueError("unsupported model source")
        path = PurePosixPath(relative_path)
        if (
            not relative_path
            or "\\" in relative_path
            or path.is_absolute()
            or any(part in {"", ".", ".."} for part in path.parts)
        ):
            raise ValueError("invalid model file path")

    def download(self, source: SourceLocation, relative_path: str) -> Iterator[bytes]:
        self._validate(source, relative_path)
        url = f"https://modelscope.cn/api/v1/models/{source.repository}/repo"
        try:
            request = self._client.build_request(
                "GET",
                url,
                params={"Revision": source.revision, "FilePath": relative_path},
                headers={"Accept": "application/octet-stream"},
            )
            response = self._client.send(request, stream=True, follow_redirects=True)
        except httpx.HTTPError as exc:
            raise ValueError("model source unavailable") from exc
        if response.status_code != 200:
            response.close()
            raise ValueError("model source unavailable")

        def chunks() -> Iterator[bytes]:
            try:
                yield from response.iter_bytes(chunk_size=self._chunk_size)
            except httpx.HTTPError as exc:
                raise ValueError("model source unavailable") from exc
            finally:
                response.close()

        return chunks()


__all__ = ["ModelScopeDownloader"]
