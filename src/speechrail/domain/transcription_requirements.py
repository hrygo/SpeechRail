"""Pure capability prerequisites, shared by HTTP and local-file transcription."""

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class TranscriptionRequirements:
    timestamps: bool = False
    diarization: bool = False

    @classmethod
    def for_response_format(cls, response_format: str) -> TranscriptionRequirements:
        return cls(
            timestamps=response_format in {"verbose_json", "srt", "vtt"},
            diarization=response_format == "diarized_json",
        )

    def missing_alignment_error(self, *, aligner_available: bool) -> str | None:
        if aligner_available:
            return None
        if self.diarization:
            return "diarization_not_available"
        if self.timestamps:
            return "timestamp_alignment_unavailable"
        return None
