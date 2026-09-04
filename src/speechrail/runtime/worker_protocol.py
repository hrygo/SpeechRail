"""Versioned, length-prefixed IPC frames for private inference workers."""

from __future__ import annotations

import json
import struct
from collections.abc import Mapping
from typing import BinaryIO

# Sized so the default max_audio_seconds (3600s of 16kHz mono PCM16 = 115.2MB)
# plus the JSON header slack fits a single frame; Settings rejects larger values.
MAX_FRAME_BYTES = 128 * 1024 * 1024
PROTOCOL_VERSION = 1


class ProtocolError(ValueError):
    """Worker IPC was malformed, incomplete, or violates size constraints."""


def encode_frame(payload: Mapping[str, object], binary_payload: bytes | None = None) -> bytes:
    """Serialize one length-prefixed JSON or binary-mixed frame; shared by sync and async paths."""

    json_bytes = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    bin_len = len(binary_payload) if binary_payload else 0
    if bin_len == 0:
        total_len = len(json_bytes)
        if not 0 < total_len <= MAX_FRAME_BYTES:
            raise ProtocolError("invalid worker frame size")
        return struct.pack(">I", total_len) + json_bytes

    total_len = 4 + len(json_bytes) + bin_len
    if not 0 < total_len <= MAX_FRAME_BYTES:
        raise ProtocolError("invalid worker frame size")
    return struct.pack(">II", total_len, len(json_bytes)) + json_bytes + binary_payload  # type: ignore[operator]


def decode_frame_body(body: bytes) -> dict[str, object]:
    """Validate and decode one JSON or binary-mixed frame body; shared by sync and async paths."""

    if not 0 < len(body) <= MAX_FRAME_BYTES:
        raise ProtocolError("invalid worker frame size")

    # Binary-mixed frame: first 4 bytes are json_size, followed by JSON and binary payload.
    if len(body) >= 5 and body[0] != 0x7B:  # 0x7B is '{'
        try:
            json_size = struct.unpack(">I", body[:4])[0]
            if 0 < json_size <= len(body) - 4:
                json_part = body[4 : 4 + json_size]
                binary_part = body[4 + json_size :]
                decoded = json.loads(json_part.decode("utf-8"))
                if isinstance(decoded, dict):
                    res = {str(key): value for key, value in decoded.items()}
                    res["_binary"] = binary_part
                    return res
        except Exception:
            pass

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


def write_frame(
    stream: BinaryIO, payload: Mapping[str, object], binary_payload: bytes | None = None
) -> None:
    stream.write(encode_frame(payload, binary_payload=binary_payload))
    stream.flush()

