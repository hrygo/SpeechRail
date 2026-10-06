"""Vendor-neutral policy for bounded realtime ASR segments."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal

ASRFinalization = Literal["full_segment", "streaming_finalize"]
_ASR_POLICY_FIELDS = frozenset(
    {
        "preview_interval_ms",
        "max_segment_ms",
        "finalization",
        "final_deadline_ms",
    }
)


def _strict_integer(value: object, *, field: str, minimum: int, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{field} must be an integer of at least {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{field} must be no greater than {maximum}")
    return value


@dataclass(frozen=True, slots=True)
class ASRPolicy:
    """Immutable, application-neutral ASR policy carried by a Realtime session."""

    preview_interval_ms: int = 1_000
    max_segment_ms: int = 20_000
    finalization: ASRFinalization = "full_segment"
    final_deadline_ms: int | None = None

    def __post_init__(self) -> None:
        _strict_integer(
            self.preview_interval_ms,
            field="preview_interval_ms",
            minimum=100,
            maximum=5_000,
        )
        _strict_integer(
            self.max_segment_ms,
            field="max_segment_ms",
            minimum=1_000,
            maximum=30_000,
        )
        if self.max_segment_ms < self.preview_interval_ms:
            raise ValueError("max_segment_ms must be at least preview_interval_ms")
        if not isinstance(self.finalization, str) or self.finalization not in {
            "full_segment",
            "streaming_finalize",
        }:
            raise ValueError("finalization must be full_segment or streaming_finalize")
        if self.final_deadline_ms is not None:
            _strict_integer(
                self.final_deadline_ms,
                field="final_deadline_ms",
                minimum=1,
            )

    @classmethod
    def from_mapping(
        cls,
        value: Mapping[str, object],
        *,
        request_timeout_ms: int | None = None,
    ) -> ASRPolicy:
        """Parse a closed wire object, rejecting unknown fields and coercions."""
        if not isinstance(value, Mapping):
            raise ValueError("ASR policy must be an object")
        if any(not isinstance(field, str) for field in value):
            raise ValueError("ASR policy field names must be strings")
        unknown = sorted(set(value) - _ASR_POLICY_FIELDS)
        if unknown:
            raise ValueError(f"unsupported ASR policy field: {unknown[0]}")
        policy = cls(**dict(value))  # type: ignore[arg-type]
        if request_timeout_ms is not None:
            policy.effective_deadline_ms(request_timeout_ms=request_timeout_ms)
        return policy

    def effective_deadline_ms(self, *, request_timeout_ms: int) -> int:
        """Return the configured final deadline, bounded by request timeout."""
        timeout = _strict_integer(
            request_timeout_ms,
            field="request_timeout_ms",
            minimum=1,
        )
        if self.final_deadline_ms is not None and self.final_deadline_ms > timeout:
            raise ValueError("final_deadline_ms must not exceed the request timeout")
        return self.final_deadline_ms if self.final_deadline_ms is not None else timeout

    def to_wire_dict(
        self,
        *,
        effective_max_segment_ms: int,
        request_timeout_ms: int | None,
    ) -> dict[str, object]:
        """Serialize effective session values without mutating the request policy."""
        effective = _strict_integer(
            effective_max_segment_ms,
            field="effective_max_segment_ms",
            minimum=1_000,
            maximum=self.max_segment_ms,
        )
        result: dict[str, object] = {
            "preview_interval_ms": self.preview_interval_ms,
            "max_segment_ms": self.max_segment_ms,
            "finalization": self.finalization,
            "effective_max_segment_ms": effective,
        }
        if request_timeout_ms is not None:
            result["final_deadline_ms"] = self.effective_deadline_ms(
                request_timeout_ms=request_timeout_ms
            )
        elif self.final_deadline_ms is not None:
            result["final_deadline_ms"] = self.final_deadline_ms
        return result


def resolve_effective_max_segment_ms(
    policy: ASRPolicy,
    *,
    service_max_segment_ms: int,
    capability_max_segment_ms: int | None,
    decoder_max_segment_ms: int,
) -> int:
    """Resolve a hard segment duration from the request and all resource bounds."""
    if not isinstance(policy, ASRPolicy):
        raise ValueError("policy must be an ASRPolicy")
    service_limit = _strict_integer(
        service_max_segment_ms,
        field="service_max_segment_ms",
        minimum=1_000,
    )
    decoder_limit = _strict_integer(
        decoder_max_segment_ms,
        field="decoder_max_segment_ms",
        minimum=1_000,
    )
    limits = [policy.max_segment_ms, service_limit, decoder_limit]
    if capability_max_segment_ms is not None:
        limits.append(
            _strict_integer(
                capability_max_segment_ms,
                field="capability_max_segment_ms",
                minimum=1_000,
            )
        )
    return min(limits)
