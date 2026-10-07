"""Pure normalization of finite, adapter-selected loader observations.

Collectors choose source order; adapters retain family/variant/compute policy.
Missing and None are unobserved here. A concrete null bits/group declaration
is explicitly unquantized. Snapshot declarations retain their stricter complete
comparison in model_identity.read_quantization.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum

from speechrail.backends.model_identity import read_quantization, validate_quantization_pair
from speechrail.config.model_catalog import QuantizationSpec


class _Missing(Enum):
    VALUE = "missing"


MISSING = _Missing.VALUE


@dataclass(frozen=True, slots=True)
class LoaderSource:
    """A collector's fixed provenance label and its Mapping/attribute object."""

    name: str
    metadata: object


def _field(metadata: object, name: str) -> object:
    return metadata.get(name, MISSING) if isinstance(metadata, Mapping) else getattr(
        metadata, name, MISSING
    )


def loader_value(sources: tuple[LoaderSource, ...], names: tuple[str, ...]) -> object:
    for source in sources:
        if source.metadata is None:
            continue
        for name in names:
            value = _field(source.metadata, name)
            if value is not MISSING and value is not None:
                return value
    return MISSING


def _declaration(raw: object, *, source: str, field: str) -> QuantizationSpec:
    try:
        # Instances can carry legal Pydantic types yet an unsupported bit width
        # or missing pair. They must pass the same rules as Mapping metadata.
        if isinstance(raw, QuantizationSpec):
            raw = raw.model_dump()
        if not isinstance(raw, Mapping):
            raise ValueError("invalid declaration shape")
        return read_quantization({field: raw})
    except ValueError as exc:
        # Provenance is a fixed collector label, never a payload/model path.
        raise RuntimeError(
            f"backend_identity_mismatch: invalid loader quantization ({source}.{field})"
        ) from exc


def loader_quantization(sources: tuple[LoaderSource, ...]) -> QuantizationSpec | None:
    declarations: list[tuple[str, QuantizationSpec]] = []
    for source in sources:
        if source.metadata is None:
            continue
        for field in ("quantization", "quantization_config"):
            raw = _field(source.metadata, field)
            if raw is not MISSING and raw is not None:
                declarations.append((
                    source.name, _declaration(raw, source=source.name, field=field),
                ))
        bits = _field(source.metadata, "quantization_bits")
        group_size = _field(source.metadata, "quantization_group_size")
        if bits is not MISSING or group_size is not MISSING:
            declarations.append((source.name, _declaration(
                {"bits": None if bits is MISSING else bits,
                 "group_size": None if group_size is MISSING else group_size},
                source=source.name, field="quantization",
            )))
    if not declarations:
        return None
    first_source, first = declarations[0]
    for source_name, item in declarations[1:]:
        if (item.bits, item.group_size) != (first.bits, first.group_size):
            raise RuntimeError(
                "backend_identity_mismatch: loader quantization conflict "
                f"({first_source}, {source_name})"
            )
    return first


def identity_quantization(identity: object) -> tuple[int | None, int | None]:
    """Validate the pair already emitted by a worker's ready identity."""
    return validate_quantization_pair(
        getattr(identity, "quantization_bits", None),
        getattr(identity, "quantization_group_size", None),
    )
