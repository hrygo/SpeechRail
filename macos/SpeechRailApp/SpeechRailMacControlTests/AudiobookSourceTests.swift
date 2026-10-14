import Foundation
import XCTest
@testable import SpeechRailAppSupport

final class AudiobookSourceTests: XCTestCase {
    func testScalarBoundariesAndLiteralReplacementCharacter() throws {
        let originalText = "第1章 雾港\r\n“你也看见灯了？”👩‍👩‍👧‍👦 café e\u{0301} 原文含\u{FFFD}符号。\n第二行。"
        let utf8 = Data(originalText.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let wholeRange = AudiobookSourceRange(lowerBound: 0, upperBound: Int64(utf8.count))

        XCTAssertEqual(try index.text(in: wholeRange), originalText)

        // Slicing inside a multi-byte UTF-8 scalar ("第" is 3 bytes at 0..<3) must throw.
        let midScalarRange = AudiobookSourceRange(lowerBound: 1, upperBound: Int64(utf8.count))
        XCTAssertThrowsError(try index.text(in: midScalarRange)) { error in
            XCTAssertEqual(error as? AudiobookSourceError, .nonScalarBoundary(1))
        }

        // Building atoms must preserve exact coverage and never slice inside a scalar.
        let chapter = AudiobookChapter(
            bookID: UUID(),
            sourceID: UUID(),
            ordinal: 0,
            title: "第1章 雾港",
            sourceRange: wholeRange
        )
        let atoms = try index.buildAtoms(for: chapter, maxAtomScalars: 12)
        XCTAssertFalse(atoms.isEmpty)
        try index.validateCoverage(atoms.map(\.sourceRange), exclusions: [])

        let reconstructed = try atoms.map { try index.text(in: $0.sourceRange) }.joined()
        XCTAssertEqual(reconstructed, originalText)
    }

    func testCoverageRejectsHoleOverlapAndDuplicate() throws {
        let originalText = "甲乙丙丁戊己庚辛壬癸"
        let utf8 = Data(originalText.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let total = Int64(utf8.count) // 10 CJK chars = 30 bytes

        let first = AudiobookSourceRange(lowerBound: 0, upperBound: 12)
        let secondWithHole = AudiobookSourceRange(lowerBound: 15, upperBound: total)
        XCTAssertThrowsError(try index.validateCoverage([first, secondWithHole], exclusions: []))

        let overlappingRanges = [
            AudiobookSourceRange(lowerBound: 0, upperBound: 15),
            AudiobookSourceRange(lowerBound: 12, upperBound: total),
        ]
        XCTAssertThrowsError(try index.validateCoverage(overlappingRanges, exclusions: []))

        let duplicateRanges = [
            AudiobookSourceRange(lowerBound: 0, upperBound: 15),
            AudiobookSourceRange(lowerBound: 0, upperBound: 15),
            AudiobookSourceRange(lowerBound: 15, upperBound: total),
        ]
        XCTAssertThrowsError(try index.validateCoverage(duplicateRanges, exclusions: []))

        // Explicit exclusion covers the gap [12, 15), making coverage valid.
        let explicitExclusion = AudiobookSourceRange(lowerBound: 12, upperBound: 15)
        XCTAssertNoThrow(try index.validateCoverage([first, secondWithHole], exclusions: [explicitExclusion]))
    }
}
