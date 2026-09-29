"""The Swift follow-controller tests must not cite regressions that do not exist.

The stage report's condition 45 is "a ledger reference resolves to nothing". A
later review found the same failure one layer down, in a Swift doc comment that
the report then repeated: both cited
`distantFullSentenceCannotDragTheViewportBackwards` as an existing regression.
No function by that name was ever defined in the repository's history
(`git log --all -S'func distantFullSentence...' ` is empty). The real backward
regression is `rereadDoesNotRollBackAcrossDistantParagraphs`.

The coverage is real; the pointer is dangling. A handoff engineer who follows
the citation finds nothing and reasonably concludes the backward direction is
untested. This test keeps every ``@Test``-shaped backticked citation in the
controller tests resolvable to a real ``@Test func`` in the same file, so the
class of defect cannot recur silently.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CONTROLLER_TESTS = (
    REPO_ROOT
    / "macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift"
)
SOURCE_ROOT = REPO_ROOT / "macos/SpeechRailApp/SpeechRailApp"

_TEST_FUNC_RE = re.compile(r"@Test\s+func\s+([A-Za-z0-9_]+)")
_BACKTICK_RE = re.compile(r"`([A-Za-z][A-Za-z0-9_]{6,})`")


def _declared_test_names() -> set[str]:
    return set(_TEST_FUNC_RE.findall(CONTROLLER_TESTS.read_text(encoding="utf-8")))


def _production_names() -> set[str]:
    """Every identifier the code under test actually declares.

    The test file cites two different kinds of name in its comments: its own
    sibling regressions, and fields of the controller it exercises
    (`localAdvanceTokenRadius`, `provisionalMinimumMatches`, `eventIDs`,
    `retired`). Both kinds have to resolve, but only the first kind is a test
    pointer -- so the check accepts either, which is why an earlier, looser
    version of this test reported four false positives before the criterion was
    pinned down.
    """
    names: set[str] = set()
    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        names.update(re.findall(r"\b(?:let|var|func|case)\s+([A-Za-z_][A-Za-z0-9_]*)", text))
        names.update(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[A-Za-z_]", text))
    return names


def test_the_controller_test_file_exists() -> None:
    assert CONTROLLER_TESTS.is_file(), CONTROLLER_TESTS


def test_no_comment_cites_a_name_that_resolves_to_nothing() -> None:
    """Every backticked camelCase name must resolve to a test or to the source.

    The file cites its sibling regressions by name in comments so a reader can
    find them. When one of those names is wrong the citation rots silently: the
    tests still pass, the comment still reads as authoritative, and the missing
    coverage is only discovered by whoever later follows the pointer. Requiring
    the citation to resolve here is what turns that silent rot into a red test.

    The criterion has to cover both kinds of citation, which is exactly what the
    first version of this check got wrong: it demanded every name be an
    ``@Test func`` and so flagged four legitimate controller fields.
    """
    declared = _declared_test_names()
    production = _production_names()
    dangling = sorted(
        name
        for name in set(_BACKTICK_RE.findall(CONTROLLER_TESTS.read_text(encoding="utf-8")))
        if name not in declared and name not in production
    )
    assert dangling == [], (
        "comment cites names that are neither a test here nor an identifier in "
        "the code under test: "
        f"{dangling}; declared here: {sorted(declared)}"
    )


def test_the_backward_regression_named_in_the_comment_is_the_real_one() -> None:
    """Pin the concrete instance so the general check above cannot be gamed.

    ``rereadDoesNotRollBackAcrossDistantParagraphs`` is the test that actually
    proves a distant whole-paragraph re-read cannot drag the viewport back. The
    comment used to name ``distantFullSentenceCannotDragTheViewportBackwards``
    instead, which never existed. If someone renames the real test this fails
    rather than leaving the comment quietly pointing at nothing again.
    """
    declared = _declared_test_names()
    assert "rereadDoesNotRollBackAcrossDistantParagraphs" in declared
    assert "distantFullSentenceCannotDragTheViewportBackwards" not in declared


def test_the_controller_test_file_covers_both_directions() -> None:
    """The gap the dangling citation papered over was a one-directional suite.

    Condition 60/§2.14 recorded that only the backward direction had coverage.
    The forward test was added in ``e3a48345``; this asserts both directions
    still have a named regression so the claim in the comment stays true.
    """
    declared = _declared_test_names()
    assert "aDistantForwardPhraseCannotDragTheViewportAhead" in declared
    assert "rereadDoesNotRollBackAcrossDistantParagraphs" in declared
