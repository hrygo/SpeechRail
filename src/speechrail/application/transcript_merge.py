"""Merge bounded-window transcription results on one absolute sample timeline."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final

from speechrail.application.audio_stream import PcmBlock
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment, TranscriptWord

_SAMPLE_RATE: Final = 16_000
_TOKEN_WINDOW: Final = 8
_MAX_CUMULATIVE_TEXT_CHARS: Final = 100_000
_TOKEN_RE = re.compile(
    r"[^\W\s\u3400-\u4dbf\u4e00-\u9fff_]+(?:[.'’\-][^\W\s\u3400-\u4dbf\u4e00-\u9fff_]+)*|"
    r"[\u3400-\u4dbf\u4e00-\u9fff]|"
    r"[^\w\s]",
    re.UNICODE,
)


@dataclass(frozen=True, slots=True)
class _Token:
    value: str
    start: int
    end: int


def offset_ms(local_ms: int, start_sample: int) -> int:
    """将窗口内毫秒偏移映射到 16 kHz 源音频的绝对毫秒轴。"""

    if (
        isinstance(local_ms, bool)
        or not isinstance(local_ms, int)
        or local_ms < 0
        or isinstance(start_sample, bool)
        or not isinstance(start_sample, int)
        or start_sample < 0
    ):
        raise ValueError("invalid_transcript_offset")
    return local_ms + round(start_sample * 1000 / _SAMPLE_RATE)


def _sample_ms(sample: int) -> int:
    return round(sample * 1000 / _SAMPLE_RATE)


def _tokens(text: str) -> tuple[_Token, ...]:
    return tuple(
        _Token(match.group(), match.start(), match.end())
        for match in _TOKEN_RE.finditer(text)
    )


def _is_cjk(token: str) -> bool:
    return len(token) == 1 and "\u3400" <= token <= "\u9fff"


def _is_strong_single_overlap(token: str) -> bool:
    if any(char.isdigit() for char in token):
        return True
    if any("A" <= char <= "Z" for char in token):
        return True
    if any(char in ".·'’-" for char in token):
        return True
    return bool(len(token) >= 2 and any(ord(char) > 127 and not _is_cjk(char) for char in token))


def _overlap_count(previous: tuple[_Token, ...], current: tuple[_Token, ...]) -> int:
    previous_tail = previous[-_TOKEN_WINDOW:]
    current_head = current[:_TOKEN_WINDOW]
    for count in range(min(len(previous_tail), len(current_head)), 0, -1):
        left = tuple(token.value.casefold() for token in previous_tail[-count:])
        right = tuple(token.value.casefold() for token in current_head[:count])
        if left != right:
            continue
        if count >= 2:
            return count
        token = current_head[0].value
        if _is_strong_single_overlap(token):
            return 1
        if _is_cjk(token):
            # A single CJK character is too ambiguous to delete at a boundary.
            return 0
        return 0
    return 0


def _join_text(left: str, right: str) -> str:
    if not left:
        return right.strip()
    if not right:
        return left.strip()
    has_space_gap = left[-1].isspace() or right[0].isspace()
    left = left.rstrip()
    right = right.lstrip()
    if not left:
        return right
    if not right:
        return left
    if has_space_gap:
        return f"{left} {right}"
    left_char = left[-1]
    right_char = right[0]
    if (left_char.isalnum() and right_char.isalnum()) and not (
        _is_cjk(left_char) or _is_cjk(right_char)
    ):
        return f"{left} {right}"
    if right_char in ".,!?;:%)]}，。！？；：、）】》」』":
        return left + right
    if left_char in ".,!?;:%)]}" and right_char.isalnum() and not _is_cjk(right_char):
        return f"{left} {right}"
    return left + right


def _dedup_text(
    previous: str,
    current: str,
    previous_tail: tuple[_Token, ...],
) -> tuple[str, tuple[_Token, ...]]:
    if not previous:
        current_tokens = _tokens(current)
        return current.strip(), current_tokens[-_TOKEN_WINDOW:]
    if not current:
        return previous, previous_tail
    current_tokens = _tokens(current)
    count = _overlap_count(previous_tail, current_tokens)
    if count:
        suffix_start = current_tokens[count - 1].end
        current = current[suffix_start:]
    remaining = current_tokens[count:]
    return (
        _join_text(previous, current),
        (*previous_tail, *remaining)[-_TOKEN_WINDOW:],
    )


def _owns_interval(
    start_ms: int,
    end_ms: int,
    core_start_ms: int,
    core_end_ms: int,
) -> bool:
    if core_start_ms >= core_end_ms:
        return False
    midpoint = start_ms if end_ms == start_ms else (start_ms + end_ms) // 2
    return core_start_ms <= midpoint < core_end_ms


def _validate_result_for_block(block: PcmBlock, result: TranscriptResult) -> None:
    if not isinstance(block, PcmBlock) or not isinstance(result, TranscriptResult):
        raise ValueError("merge_window_mismatch")
    window_end_sample = block.start_sample + len(block.pcm) // 2
    if block.core_end_sample > window_end_sample:
        raise ValueError("merge_window_mismatch")
    if block.core_end_sample <= block.core_start_sample:
        raise ValueError("merge_core_discontinuity")
    window_duration_ms = _sample_ms(window_end_sample - block.start_sample)
    if result.duration_ms > window_duration_ms:
        raise ValueError("merge_window_mismatch")
    previous_start_ms = 0
    for segment in result.segments:
        if (
            segment.end_ms > window_duration_ms
            or segment.end_ms > result.duration_ms
            or segment.start_ms < previous_start_ms
        ):
            raise ValueError("merge_window_mismatch")
        previous_start_ms = segment.start_ms
    previous_start_ms = 0
    for word in result.words:
        if (
            word.end_ms > window_duration_ms
            or word.end_ms > result.duration_ms
            or word.start_ms < previous_start_ms
        ):
            raise ValueError("merge_window_mismatch")
        previous_start_ms = word.start_ms


@dataclass(frozen=True, slots=True)
class _WindowOutput:
    segments: tuple[TranscriptSegment, ...]
    words: tuple[TranscriptWord, ...]
    text: str
    has_timestamps: bool


def _window_output(block: PcmBlock, result: TranscriptResult) -> _WindowOutput:
    _validate_result_for_block(block, result)
    core_start_ms = _sample_ms(block.core_start_sample)
    core_end_ms = _sample_ms(block.core_end_sample)
    segments: list[TranscriptSegment] = []
    words: list[TranscriptWord] = []
    for segment in result.segments:
        start_ms = offset_ms(segment.start_ms, block.start_sample)
        end_ms = offset_ms(segment.end_ms, block.start_sample)
        if _owns_interval(start_ms, end_ms, core_start_ms, core_end_ms):
            segments.append(
                segment.model_copy(
                    update={
                        "start_ms": start_ms,
                        "end_ms": end_ms,
                    }
                )
            )
    for word in result.words:
        start_ms = offset_ms(word.start_ms, block.start_sample)
        end_ms = offset_ms(word.end_ms, block.start_sample)
        if _owns_interval(start_ms, end_ms, core_start_ms, core_end_ms):
            words.append(word.model_copy(update={"start_ms": start_ms, "end_ms": end_ms}))
    if segments:
        text = ""
        for segment in segments:
            text = _join_text(text, segment.text)
    elif words:
        text = ""
        for word in words:
            text = _join_text(text, word.word)
    elif result.segments or result.words:
        # 带时间戳但当前窗全部落在 overlap 内时, 不重复追加窗口全文。
        text = ""
    else:
        text = result.text
    return _WindowOutput(
        segments=tuple(segments),
        words=tuple(words),
        text=text,
        has_timestamps=bool(result.segments or result.words),
    )


class TranscriptMerger:
    """增量合并结果, 只保存文本、时间结果和窗口边界, 不持有 PCM。"""

    __slots__ = (
        "_failed",
        "_finished_result",
        "_has_windows",
        "_language",
        "_language_consistent",
        "_last_core_end_sample",
        "_last_window_end_sample",
        "_segments",
        "_tail_tokens",
        "_text",
        "_window_count",
        "_words",
    )

    def __init__(self) -> None:
        self._failed: ValueError | None = None
        self._finished_result: TranscriptResult | None = None
        self._has_windows = False
        self._last_core_end_sample = 0
        self._last_window_end_sample = 0
        self._language: str | None = None
        self._language_consistent = True
        self._window_count = 0
        self._segments: list[TranscriptSegment] = []
        self._words: list[TranscriptWord] = []
        self._tail_tokens: tuple[_Token, ...] = ()
        self._text = ""

    def _raise_if_unavailable(self) -> None:
        if self._failed is not None:
            raise ValueError("merge_failed") from self._failed
        if self._finished_result is not None:
            raise ValueError("merger_finished")

    def add(self, block: PcmBlock, result: TranscriptResult) -> None:
        """校验并加入一个按源窗口顺序到达的结果。"""

        self._raise_if_unavailable()
        try:
            if not isinstance(block, PcmBlock) or not isinstance(result, TranscriptResult):
                raise ValueError("merge_window_mismatch")
            if self._has_windows:
                if block.core_start_sample != self._last_core_end_sample:
                    raise ValueError("merge_core_discontinuity")
            elif block.core_start_sample != 0:
                raise ValueError("merge_core_discontinuity")
            output = _window_output(block, result)
            if (
                self._segments
                and output.segments
                and output.segments[0].start_ms < self._segments[-1].start_ms
            ):
                raise ValueError("merge_segment_order")
            for index in range(1, len(output.segments)):
                if output.segments[index].start_ms < output.segments[index - 1].start_ms:
                    raise ValueError("merge_segment_order")
            self._segments.extend(output.segments)
            self._words.extend(output.words)
            has_overlap = self._has_windows and (block.start_sample < self._last_window_end_sample)
            if output.has_timestamps:
                self._text = _join_text(self._text, output.text)
                self._tail_tokens = (
                    *self._tail_tokens,
                    *_tokens(output.text),
                )[-_TOKEN_WINDOW:]
            elif has_overlap:
                self._text, self._tail_tokens = _dedup_text(
                    self._text,
                    output.text,
                    self._tail_tokens,
                )
            else:
                self._text = _join_text(self._text, output.text)
                self._tail_tokens = (
                    *self._tail_tokens,
                    *_tokens(output.text),
                )[-_TOKEN_WINDOW:]
            if len(self._text) > _MAX_CUMULATIVE_TEXT_CHARS:
                raise ValueError("merge_text_too_long")
            if self._window_count == 0:
                self._language = result.language
                if result.language is None:
                    self._language_consistent = False
            else:
                if result.language is None or result.language != self._language:
                    self._language_consistent = False
            self._window_count += 1
            self._last_core_end_sample = block.core_end_sample
            self._last_window_end_sample = block.start_sample + len(block.pcm) // 2
            self._has_windows = True
        except ValueError as error:
            self._failed = error
            raise

    def finish(self, request_id: str, model_id: str) -> TranscriptResult:
        """完成合并并生成最终结果; 重复调用返回同一冻结结果。"""

        if self._failed is not None:
            raise ValueError("merge_failed") from self._failed
        if self._finished_result is not None:
            return self._finished_result
        if not isinstance(request_id, str) or not request_id:
            raise ValueError("merge_request_id_invalid")
        if not isinstance(model_id, str) or not model_id:
            raise ValueError("merge_model_id_invalid")
        language = (
            self._language
            if (self._language_consistent and self._window_count > 0 and self._language is not None)
            else None
        )
        result = TranscriptResult(
            request_id=request_id,
            model_id=model_id,
            text=self._text,
            language=language,
            duration_ms=_sample_ms(self._last_core_end_sample),
            segments=tuple(
                segment.model_copy(update={"id": index})
                for index, segment in enumerate(self._segments)
            ),
            words=tuple(self._words),
        )
        self._finished_result = result
        return result


def merge_results(
    blocks: tuple[PcmBlock, ...] | list[PcmBlock],
    results: tuple[TranscriptResult, ...] | list[TranscriptResult],
    *,
    request_id: str | None = None,
    model_id: str | None = None,
) -> TranscriptResult:
    """合并一组窗口结果, 失败时不返回部分成功结果。"""

    if len(blocks) != len(results):
        raise ValueError("merge_window_mismatch")
    if not blocks:
        if request_id is None or model_id is None:
            raise ValueError("merge_identity_required")
        return TranscriptResult(
            request_id=request_id,
            model_id=model_id,
            duration_ms=0,
        )
    merger = TranscriptMerger()
    for block, result in zip(blocks, results, strict=True):
        merger.add(block, result)
    first_result = results[0]
    return merger.finish(
        request_id if request_id is not None else first_result.request_id,
        model_id if model_id is not None else first_result.model_id,
    )
