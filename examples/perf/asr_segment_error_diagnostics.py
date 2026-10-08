"""Bounded, text-free diagnostic output for a chosen optimal CER alignment.

Input text remains in caller memory. Outputs contain only counts, normalized
positions, sample watermarks and whole-output/segment digests. A text alignment does
not establish where in the audio a recognition error occurred.
"""

import hashlib
import json
from contextlib import contextmanager
from pathlib import Path

try:
    from . import realtime_asr_benchmark as benchmark
    from .asr_quality import _characters, character_error_metrics
except ImportError:  # Direct execution from examples/perf.
    import realtime_asr_benchmark as benchmark
    from asr_quality import _characters, character_error_metrics

_MAX_CHARACTERS = 1024
_ORIGINAL_EVIDENCE_CLASS = benchmark.ASREvidence


class DiagnosticASREvidence(_ORIGINAL_EVIDENCE_CLASS):
    def score(self, reference, **kwargs):
        budget = kwargs.get("effective_max_segment_ms")
        if (
            self.resource_only or not self.require_boundaries
            or type(budget) is not int or budget <= 0
        ):
            raise ValueError("diagnostic requires bounded quality evidence")
        # Retain all existing barrier, input, terminal, CER and punctuation
        # gates; add localization only after the original score succeeds.
        report = super().score(reference, **kwargs)
        segments = [{
            "start_sample": span[0], "end_sample": span[1],
            "terminal_text": self.terminals[item],
            "preview_text": self.previews.get(item),
        } for item, span in sorted(self.boundaries.items(), key=lambda pair: pair[1])]
        diagnostic = segment_error_diagnostics(
            reference, segments,
            expected_wire_samples=kwargs["expected_wire_samples"],
            max_segment_ms=budget,
        )
        if any(report[key] != diagnostic[key] for key in (
            "character_errors", "reference_characters",
            "hypothesis_characters", "normalization",
        )):
            raise ValueError("diagnostic disagrees with public event score")
        punctuation_gold = kwargs.get("punctuation_reference_text")
        if punctuation_gold is not None:
            report["punctuation_reference_exact_sha256"] = _digest(punctuation_gold)
        return {**report, "segment_diagnostic": diagnostic}


@contextmanager
def diagnostic_evidence_context():
    """Use only in an isolated diagnostic process, never the live v4 driver."""
    if benchmark.ASREvidence is not _ORIGINAL_EVIDENCE_CLASS:
        raise RuntimeError("another diagnostic collector is already installed")
    benchmark.ASREvidence = DiagnosticASREvidence
    try:
        yield
    finally:
        if benchmark.ASREvidence is not DiagnosticASREvidence:
            raise RuntimeError("diagnostic collector changed during probe")
        benchmark.ASREvidence = _ORIGINAL_EVIDENCE_CLASS


def run_diagnostic_probe(manifest, **kwargs):
    """Run in its own managed probe process; never label it as a frozen matrix."""
    if kwargs.get("resource_only", False) is not False:
        raise ValueError("diagnostic requires quality mode")
    if type(kwargs.get("sessions")) is not int or kwargs["sessions"] <= 0:
        raise ValueError("diagnostic sessions must be a positive integer")
    if type(kwargs.get("warmup")) is not bool:
        raise ValueError("diagnostic warmup must be a boolean")
    document = json.loads(Path(manifest).read_bytes())
    if (
        not isinstance(document, dict)
        or not isinstance(document.get("asr_policy"), dict)
        or "max_segment_ms" not in document["asr_policy"]
    ):
        raise ValueError("diagnostic requires an explicit bounded ASR policy")
    from speechrail.domain.asr_policy import ASRPolicy

    ASRPolicy.from_mapping(document["asr_policy"])
    source_paths = [
        Path(__file__),
        Path(benchmark.__file__),
        Path(_characters.__code__.co_filename),
    ]
    source_sha256 = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in source_paths
    }
    original_writer = benchmark.write_result

    def tag(payload):
        if (
            payload.get("tool") != "speechrail-bench-realtime-asr"
            or type(payload.get("schema_version")) is not int
            or payload["schema_version"] not in (1, 2)
        ):
            raise ValueError("unexpected diagnostic source result")
        if source_sha256 != {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in source_paths
        }:
            raise ValueError("diagnostic source changed during probe")
        return {
            **payload,
            "tool": "speechrail-asr-segment-diagnostic",
            "diagnostic_schema_version": 2,
            "source_result_schema_version": payload["schema_version"],
            "source_result_tool": payload["tool"],
            "diagnostic_source_sha256": source_sha256,
            "frozen_v4_matrix_scope": False,
            "acoustic_latency_gate": "not_evaluated",
        }

    def persist(payload, output):
        original_writer(tag(payload), output)

    with diagnostic_evidence_context():
        benchmark.write_result = persist
        try:
            report = benchmark.run_manifest_asr_benchmark(manifest, **kwargs)
        finally:
            if benchmark.write_result is not persist:
                raise RuntimeError("diagnostic writer changed during probe")
            benchmark.write_result = original_writer
    return tag(report)


def _digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _aligned_edits(reference, hypothesis):
    table = [list(range(len(hypothesis) + 1))]
    for row, left in enumerate(reference, 1):
        costs = [row]
        for column, right in enumerate(hypothesis, 1):
            costs.append(min(
                costs[-1] + 1,
                table[row - 1][column] + 1,
                table[row - 1][column - 1] + (left != right),
            ))
        table.append(costs)
    row, column = len(reference), len(hypothesis)
    edits = []
    tied_steps = 0
    while row or column:
        choices = []
        if row and column:
            same = reference[row - 1] == hypothesis[column - 1]
            if table[row][column] == table[row - 1][column - 1] + (not same):
                choices.append(("match" if same else "substitution", row - 1, column - 1))
        if row and table[row][column] == table[row - 1][column] + 1:
            choices.append(("deletion", row - 1, column))
        if column and table[row][column] == table[row][column - 1] + 1:
            choices.append(("insertion", row, column - 1))
        if not choices:
            raise ValueError("no optimal alignment step")
        tied_steps += len(choices) > 1
        # Diagonal, then deletion, then insertion. This chooses one optimal
        # alignment without claiming the reference has unique attribution.
        kind, prior_row, prior_column = choices[0]
        if kind != "match":
            edits.append({
                "kind": kind,
                "reference_range": [prior_row, row],
                "hypothesis_range": [prior_column, column],
            })
        row, column = prior_row, prior_column
    return list(reversed(edits)), tied_steps, table[-1][-1]


def segment_error_diagnostics(
    reference, segments, *, expected_wire_samples, max_segment_ms
):
    if (
        type(expected_wire_samples) is not int or expected_wire_samples <= 0
        or type(max_segment_ms) is not int or max_segment_ms <= 0
        or not isinstance(reference, str)
        or not segments or len(segments) > 64
    ):
        raise ValueError("invalid diagnostic input")
    if len(reference) > 20_000:
        raise ValueError("diagnostic text exceeds bounds")
    normalized_reference = _characters(reference)
    normalized_segments = []
    report_segments = []
    raw_segments = []
    cursor = 0
    hypothesis_cursor = 0
    for ordinal, segment in enumerate(segments):
        start, end = segment["start_sample"], segment["end_sample"]
        text = segment["terminal_text"]
        preview = segment.get("preview_text")
        if (
            type(start) is not int or type(end) is not int
            or start != cursor or end <= start
            or end - start > max_segment_ms * 24 + 1
            or not isinstance(text, str)
            or preview is not None and not isinstance(preview, str)
        ):
            raise ValueError("invalid diagnostic segment coverage or budget")
        if len(text) > 20_000 or preview is not None and len(preview) > 20_000:
            raise ValueError("diagnostic text exceeds bounds")
        normalized = _characters(text)
        normalized_preview = _characters(preview) if preview is not None else None
        if (
            len(normalized) > _MAX_CHARACTERS
            or normalized_preview is not None and len(normalized_preview) > _MAX_CHARACTERS
        ):
            raise ValueError("diagnostic text exceeds bounds")
        raw_segments.append(text)
        normalized_segments.append(normalized)
        common_prefix = 0
        if normalized_preview is not None:
            for left, right in zip(normalized_preview, normalized, strict=False):
                if left != right:
                    break
                common_prefix += 1
        report_segments.append({
            "ordinal": ordinal,
            "start_sample": start, "end_sample": end,
            "hypothesis_range": [hypothesis_cursor, hypothesis_cursor + len(normalized)],
            "terminal_normalized_characters": len(normalized),
            "terminal_normalized_sha256": _digest(normalized),
            "terminal_exact_sha256": _digest(text),
            "preview_normalized_characters": (
                len(normalized_preview) if normalized_preview is not None else None
            ),
            "preview_normalized_sha256": (
                _digest(normalized_preview) if normalized_preview is not None else None
            ),
            "preview_exact_sha256": _digest(preview) if preview is not None else None,
            "final_revised_preview_characters": (
                len(normalized_preview) - common_prefix if normalized_preview is not None else None
            ),
            "chosen_alignment_edit_counts": {
                "substitution": 0, "deletion": 0, "insertion": 0,
            },
        })
        hypothesis_cursor += len(normalized)
        cursor = end
    if cursor != expected_wire_samples:
        raise ValueError("invalid diagnostic segment coverage or budget")
    normalized_hypothesis = "".join(normalized_segments)
    if normalized_hypothesis != _characters("".join(raw_segments)):
        raise ValueError("normalization crosses a segment boundary")
    if (
        not normalized_reference
        or max(len(normalized_reference), len(normalized_hypothesis)) > _MAX_CHARACTERS
    ):
        raise ValueError("diagnostic text exceeds bounds")
    quality = character_error_metrics(reference, "".join(raw_segments))
    edits, tied_steps, distance = _aligned_edits(
        normalized_reference, normalized_hypothesis
    )
    if distance != quality["character_errors"] or len(edits) != distance:
        raise ValueError("diagnostic alignment disagrees with shared CER")
    for edit in edits:
        position = edit["hypothesis_range"][0]
        owner = next((
            row["ordinal"] for row in report_segments
            if row["hypothesis_range"][0] <= position < row["hypothesis_range"][1]
        ), len(report_segments) - 1)
        possible = [owner]
        if edit["kind"] == "deletion":
            # A zero-width text deletion at an item boundary may belong to
            # either adjacent item. It has no observed acoustic timestamp.
            possible = sorted({
                row["ordinal"] for row in report_segments
                if row["hypothesis_range"][0] <= position <= row["hypothesis_range"][1]
            }) or [owner]
        edit["chosen_segment_ordinal"] = owner
        edit["possible_segment_ordinals"] = possible
        report_segments[owner]["chosen_alignment_edit_counts"][edit["kind"]] += 1
    return {
        "diagnostic_schema_version": 2,
        "reference_characters": quality["reference_characters"],
        "hypothesis_characters": quality["hypothesis_characters"],
        "character_errors": distance,
        "cer": quality["cer"],
        "normalization": quality["normalization"],
        "reference_normalized_sha256": _digest(normalized_reference),
        "hypothesis_normalized_sha256": _digest(normalized_hypothesis),
        "hypothesis_exact_sha256": _digest("".join(raw_segments)),
        "alignment_policy": "one_optimal_text_alignment",
        "alignment_tie_break": "diagonal_then_deletion_then_insertion",
        "chosen_alignment_tied_steps": tied_steps,
        "acoustic_error_attribution": "not_observed",
        "segments": report_segments,
        "edits": edits,
    }
