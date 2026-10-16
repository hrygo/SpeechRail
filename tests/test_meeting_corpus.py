import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from examples.perf.prepare_meeting_corpus import (
    asr_reference,
    excerpt_end,
    rttm_intervals,
    textgrid_intervals,
)


def test_event_markers_are_not_scored_as_spoken_silence_or_english_words():
    assert asr_reference([(0, 1, "anonymous", "<sil>合成<%>文字<#><$><->")]) == "合成文字"
    with pytest.raises(ValueError, match="marker"):
        asr_reference([(0, 1, "anonymous", "<unknown>")])


def test_safe_end_does_not_cut_overlapping_utterances():
    assert excerpt_end([(599, 603), (602, 606), (606.5, 608)]) == 606
    with pytest.raises(ValueError):
        excerpt_end([(599, 721)])


def test_textgrid_does_not_invent_word_times_and_preserves_escaped_quotes():
    raw = '''item [1]:
        class = "IntervalTier"
        name = "anonymous"
        intervals [1]:
            xmin = 0
            xmax = 2.5
            text = "合成""引用"""
        intervals [2]:
            xmin = 2.5
            xmax = 3
            text = ""
    '''
    assert textgrid_intervals(raw) == [(0, 2.5, "anonymous", '合成"引用"')]
    assert rttm_intervals("SPEAKER test 1 0 2.5 <NA> <NA> R1 <NA> <NA>") == [(0, 2.5, "R1")]
