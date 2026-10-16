// External, opt-in TXT corpus regression against the production module.
import CoreFoundation
import Foundation
import SpeechRailAppSupport

struct CaseFailure: Error { let detail: String }
func require(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
    if !condition() { throw CaseFailure(detail: detail) }
}
func digest(_ text: String, excludingWhitespace: Bool = false) -> String {
    let value: String
    if excludingWhitespace {
        value = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }))
    } else { value = text }
    return AudiobookDigest.sha256Hex(Data(value.utf8))
}
func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
func normalizedLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}
struct CorpusManifest: Decodable {
    struct Book: Decodable {
        let name: String
        let sha256: String
        let bytes: Int
        let chapterNumbers: [Int]?
        let leadingChapter: Bool?
        let chapterTitles: [String]?
        let expectedRepeatedContentGroups: Int
    }
    let schemaVersion: Int
    let files: [Book]
}
func compactTitle(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
    }))
}
func chapterNumber(_ title: String) -> Int? {
    let expression = try! NSRegularExpression(pattern: "^第([零〇○一二三四五六七八九十百千万0-9]+)回")
    guard let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
          let range = Range(match.range(at: 1), in: title) else { return nil }
    let text = String(title[range])
    if let number = Int(text) { return number }
    let digits: [Character: Int] = ["零": 0, "〇": 0, "○": 0, "一": 1, "二": 2,
        "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]
    if !text.contains(where: { units[$0] != nil }) {
        return text.reduce(0) { $0 * 10 + (digits[$1] ?? $1.wholeNumberValue ?? 0) }
    }
    var total = 0
    var digit = 0
    for character in text {
        if let unit = units[character] {
            total += max(1, digit) * unit
            digit = 0
        } else if let value = digits[character] ?? character.wholeNumberValue { digit = value }
        else { return nil }
    }
    return total + digit
}
let environment = ProcessInfo.processInfo.environment
if ["CI", "GITHUB_ACTIONS"].contains(where: {
    ["1", "true", "yes", "on"].contains(environment[$0, default: ""].lowercased())
}) {
    emit(["status": "skipped", "reason": "ci"])
    exit(0)
}
try require(CommandLine.arguments.count == 3, "expected_corpus_directory_and_manifest")
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let manifest = try decoder.decode(CorpusManifest.self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
try require(manifest.schemaVersion == 1 && manifest.files.count == 5, "invalid_corpus_manifest")
let fixedBookID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
let fixedSourceID = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
var failures = 0
var executed = 0

for expectation in manifest.files {
    let file = root.appendingPathComponent(expectation.name)
    let raw = try Data(contentsOf: file)
    try require(raw.count == expectation.bytes && AudiobookDigest.sha256Hex(raw) == expectation.sha256,
                "corpus_fingerprint_mismatch: \(expectation.name)")
    let decoded = try AudiobookTXTImporter.strictDecode(raw, as: .utf8)
    let lf = normalizedLineEndings(decoded)
    var variants: [(String, Data, AudiobookTextEncoding, String)] = [
        ("original", raw, .utf8, decoded),
        ("newline-lf", Data(lf.utf8), .utf8, lf),
        ("newline-crlf", Data(lf.replacingOccurrences(of: "\n", with: "\r\n").utf8), .utf8,
            lf.replacingOccurrences(of: "\n", with: "\r\n")),
        ("newline-cr", Data(lf.replacingOccurrences(of: "\n", with: "\r").utf8), .utf8,
            lf.replacingOccurrences(of: "\n", with: "\r")),
        ("utf8-bom", Data([0xEF, 0xBB, 0xBF]) + Data(lf.utf8), .utf8, lf),
        ("utf16-le", Data([0xFF, 0xFE]) + lf.data(using: .utf16LittleEndian)!, .utf16LE, lf),
        ("utf16-be", Data([0xFE, 0xFF]) + lf.data(using: .utf16BigEndian)!, .utf16BE, lf)
    ]
    if let gb = lf.data(using: gbEncoding), String(data: gb, encoding: gbEncoding) == lf {
        variants.append(("gb18030", gb, .gb18030, lf))
    } else {
        emit(["file": file.lastPathComponent, "variant": "gb18030", "status": "skipped",
              "reason": "lossless_encoding_unavailable"])
    }
    var baselineTextDigest: String?
    var baselineParagraphDigest: String?
    var baselineTitles: [String]?
    var baselineContentDigest: String?
    for (variant, bytes, encoding, expectedText) in variants {
        executed += 1
        do {
            let preview: AudiobookImportPreview
            var confirmedEncoding = false
            do {
                preview = try AudiobookTXTImporter.prepare(
                    rawData: bytes, suggestedTitle: file.deletingPathExtension().lastPathComponent,
                    originalFileName: file.lastPathComponent)
            } catch AudiobookImportError.encodingSelectionRequired(let candidates) {
                try require(variant == "gb18030" && candidates.contains(.gb18030),
                            "unexpected_encoding_confirmation")
                confirmedEncoding = true
                preview = try AudiobookTXTImporter.prepare(
                    rawData: bytes, suggestedTitle: file.deletingPathExtension().lastPathComponent,
                    originalFileName: file.lastPathComponent, encoding: .gb18030)
            }
            let source = preview.sourceIndex
            try require(preview.originalBytes == bytes, "original_bytes_changed")
            try require(preview.detectedEncoding == encoding, "wrong_detected_encoding")
            try require(preview.canonicalUTF8 == Data(expectedText.utf8), "canonical_text_changed")
            try require(!source.paragraphs.isEmpty && !preview.chapters.isEmpty, "empty_preparation")
            try source.validateCoverage(source.paragraphs.map(\.sourceRange), exclusions: [])
            try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: source)
            let prepared = try source.normalizedText(in: source.wholeRange)
            let contentHash = digest(expectedText, excludingWhitespace: true)
            try require(digest(prepared, excludingWhitespace: true) == contentHash, "normalized_content_loss_or_reorder")
            try require(!prepared.contains("\r"), "normalized_cr_remaining")
            let paragraphTexts = source.paragraphs.map(\.text).joined(separator: "\n\n")
            try require(prepared == paragraphTexts, "paragraph_projection_mismatch")

            let planned = try AudiobookChapterPlanner.chapters(source: source, bookID: fixedBookID, sourceID: fixedSourceID)
            let repeated = try AudiobookChapterPlanner.chapters(source: source, bookID: fixedBookID, sourceID: fixedSourceID)
            try require(planned == repeated, "chapter_planning_nondeterministic")
            let titles = preview.chapters.map(\.title)
            if let expectedTitles = expectation.chapterTitles {
                try require(titles.map(compactTitle) == expectedTitles.map(compactTitle),
                            "chapter_titles_mismatch: actual=\(titles)")
            }
            if let expectedNumbers = expectation.chapterNumbers {
                let leading = expectation.leadingChapter == true ? 1 : 0
                try require(leading == 0 || titles.first == "开篇", "leading_chapter_missing")
                let actual = titles.dropFirst(leading).map { chapterNumber($0) ?? -1 }
                try require(actual == expectedNumbers, "chapter_numbers_mismatch: actual=\(actual)")
                try require(!titles.contains { $0.contains("話說") || $0.contains("话说") },
                            "chapter_title_absorbed_body")
                try require(!titles.contains { $0.range(of: #"\s[話话卻却且]$"#, options: .regularExpression) != nil },
                            "chapter_title_absorbed_wrapped_body_opening")
            }
            try require(preview.repeatedContentWarnings.count == expectation.expectedRepeatedContentGroups,
                        "repeated_content_warning_mismatch: actual=\(preview.repeatedContentWarnings.count)")
            if !preview.repeatedContentWarnings.isEmpty {
                try require(!preview.canConfirmImport, "repeated_content_confirmation_bypassed")
                var confirmed = preview
                confirmed.hasConfirmedRepeatedContent = true
                try require(confirmed.canConfirmImport && confirmed.chapters == preview.chapters &&
                            confirmed.originalBytes == bytes && confirmed.canonicalUTF8 == preview.canonicalUTF8,
                            "confirmation_changed_source_or_chapters")
            }

            var atomCount = 0
            var overBudgetAtomCount = 0
            var maxAtomScalars = 0
            var overBudgetAtoms: [[String: Any]] = []
            var allAtomIDs = Set<UUID>()
            var normalizedAtoms = ""
            var chapterInfo: [[String: Any]] = []
            for chapter in preview.chapters {
                let atoms = try source.buildAtoms(for: chapter)
                try source.validateCoverage(atoms.map(\.sourceRange), exclusions: [], in: chapter.sourceRange)
                try require(!atoms.isEmpty, "empty_chapter_atoms")
                if variant == "original" {
                    let repeatedAtoms = try source.buildAtoms(for: chapter)
                    try require(atoms == repeatedAtoms, "atom_ids_nondeterministic")
                }
                var chapterAtoms = ""
                for atom in atoms {
                    let count = try source.scalarCount(in: atom.sourceRange)
                    try require(count > 0, "empty_atom")
                    maxAtomScalars = max(maxAtomScalars, count)
                    if count > AudiobookLimits.maxAtomScalars {
                        overBudgetAtomCount += 1
                        if overBudgetAtoms.count < 5 {
                            overBudgetAtoms.append([
                                "chapter": chapter.title, "ordinal": atom.ordinal, "scalars": count,
                                "lower": atom.sourceRange.lowerBound, "upper": atom.sourceRange.upperBound
                            ])
                        }
                    }
                    try require(allAtomIDs.insert(atom.id).inserted, "duplicate_atom_id")
                    let text = try source.normalizedText(in: atom.sourceRange)
                    chapterAtoms.append(text)
                }
                let chapterText = try source.text(in: chapter.sourceRange)
                try require(digest(chapterAtoms, excludingWhitespace: true) ==
                            digest(chapterText, excludingWhitespace: true), "atom_projection_content_changed")
                normalizedAtoms.append(chapterAtoms)
                let previewPrepared = try preview.textPreview(for: chapter.id)
                let previewRaw = try preview.textPreview(for: chapter.id, originalLayout: true)
                try require(digest(previewPrepared, excludingWhitespace: true) ==
                            digest(previewRaw, excludingWhitespace: true), "chapter_preview_content_changed")
                try require(previewRaw.unicodeScalars.count <= AudiobookLimits.maxPreviewScalars,
                            "chapter_preview_scalar_budget_exceeded")
                atomCount += atoms.count
                if variant == "original" {
                    chapterInfo.append([
                        "title": chapter.title, "ordinal": chapter.ordinal,
                        "lower": chapter.sourceRange.lowerBound, "upper": chapter.sourceRange.upperBound,
                        "scalars": try source.scalarCount(in: chapter.sourceRange),
                        "atoms": atoms.count
                    ])
                }
            }
            try require(digest(normalizedAtoms, excludingWhitespace: true) == contentHash,
                        "whole_book_atom_projection_content_changed")
            let preparedDigest = digest(prepared)
            let paragraphDigest = digest(paragraphTexts)
            var variantWarnings: [String] = []
            if variant == "original" {
                baselineTextDigest = preparedDigest
                baselineParagraphDigest = paragraphDigest
                baselineTitles = titles
                baselineContentDigest = contentHash
            } else {
                if preparedDigest != baselineTextDigest { variantWarnings.append("normalized_layout_differs_from_original") }
                if paragraphDigest != baselineParagraphDigest { variantWarnings.append("paragraph_boundaries_differ_from_original") }
                if titles != baselineTitles { variantWarnings.append("chapter_titles_differ_from_original") }
                try require(contentHash == baselineContentDigest, "variant_content_changed")
            }
            try require(variantWarnings.isEmpty, "variant_structure_changed: \(variantWarnings)")
            var result: [String: Any] = [
                "file": file.lastPathComponent, "variant": variant,
                "status": overBudgetAtomCount == 0 ? "passed" : "failed",
                "encoding": preview.detectedEncoding.rawValue, "layout": source.layoutProfile.rawValue,
                "raw_bytes": bytes.count, "raw_sha256": AudiobookDigest.sha256Hex(bytes),
                "canonical_scalars": source.scalarCount, "paragraphs": source.paragraphs.count,
                "joined_line_breaks": source.joinedLineBreakCount, "chapters": preview.chapters.count,
                "atoms": atomCount, "max_atom_scalars": maxAtomScalars,
                "over_budget_atom_count": overBudgetAtomCount, "over_budget_atoms": overBudgetAtoms,
                "encoding_explicitly_confirmed": confirmedEncoding, "normalized_sha256": preparedDigest,
                "chapter_expectations_verified": true,
                "repeated_content_groups": preview.repeatedContentWarnings.count,
                "content_sha256": contentHash, "variant_warnings": variantWarnings,
                "paragraph_max_scalars": source.paragraphs.map { $0.text.unicodeScalars.count }.max() ?? 0,
                "isolated_title_candidates": source.paragraphs.filter(\.isIsolatedTitleCandidate).count
            ]
            if overBudgetAtomCount > 0 {
                failures += 1
                result["reason"] = "atom_scalar_budget_exceeded"
            }
            if variant == "original" {
                result["chapter_details"] = chapterInfo
            }
            emit(result)
        } catch {
            failures += 1
            let reason = (error as? CaseFailure)?.detail ?? String(describing: error)
            emit(["file": file.lastPathComponent, "variant": variant, "status": "failed", "reason": reason])
        }
    }
}
emit(["summary": true, "files": manifest.files.count, "cases": executed, "failures": failures])
if failures > 0 { exit(1) }
