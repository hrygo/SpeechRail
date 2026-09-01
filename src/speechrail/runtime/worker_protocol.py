"""Versioned, length-prefixed IPC frames for private inference workers."""

from __future__ import annotations

import json
import struct
from collections.abc import Mapping
from typing import BinaryIO

MAX_FRAME_BYTES = 64 * 1024 * 1024
PROTOCOL_VERSION = 1


class ProtocolError(ValueError):
    """Worker IPC was malformed, incomplete, or violates size constraints."""


def encode_frame(payload: Mapping[str, object]) -> bytes:
    """Serialize one length-prefixed JSON frame; shared by sync and async paths."""

    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if not 0 < len(body) <= MAX_FRAME_BYTES:
        raise ProtocolError("invalid worker frame size")
    return struct.pack(">I", len(body)) + body


def decode_frame_body(body: bytes) -> dict[str, object]:
    """Validate and decode one JSON frame body; shared by sync and async paths."""

    if not 0 < len(body) <= MAX_FRAME_BYTES:
        raise ProtocolError("invalid worker frame size")
    try:
        decoded = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("invalid worker frame JSON") from exc
    if not isinstance(decoded, dict):
        raise ProtocolError("worker frame must be an object")
    return {str(key): value for key, value in decoded.items()}


def _read_exact(stream: BinaryIO, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = stream.read(size - len(chunks))
        if not chunk:
            raise ProtocolError("truncated worker frame")
        chunks.extend(chunk)
    return bytes(chunks)


def read_frame(stream: BinaryIO) -> dict[str, object] | None:
    header = stream.read(4)
    if not header:
        return None
    if len(header) != 4:
        raise ProtocolError("truncated worker frame header")
    size = struct.unpack(">I", header)[0]
    if not 0 < size <= MAX_FRAME_BYTES:
        raise ProtocolError("invalid worker frame size")
    return decode_frame_body(_read_exact(stream, size))


def write_frame(stream: BinaryIO, payload: Mapping[str, object]) -> None:
    stream.write(encode_frame(payload))
    stream.flush()
