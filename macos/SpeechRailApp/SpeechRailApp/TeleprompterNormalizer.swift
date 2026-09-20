import Foundation

public enum TeleprompterNormalizer {
    public struct IndexedToken: Equatable, Sendable {
        public let value: String
        public let range: TeleprompterSourceRange
    }

    public static func normalize(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    public static func tokens(_ text: String) -> [String] {
        indexedTokens(text).map(\.value)
    }

    /// Fold individual graphemes while retaining their original UTF-16 range.
    /// Fillers are removed only as whole tokens, never inside English words.
    public static func indexedTokens(_ text: String) -> [IndexedToken] {
        var result: [IndexedToken] = []
        var buffer = ""
        var bufferStart = 0
        var bufferEnd = 0
        var offset = 0
        func flush() {
            if !buffer.isEmpty, !["uh", "um", "er", "嗯", "呃", "额"].contains(buffer) {
                result.append(.init(value: buffer, range: .init(start: bufferStart, end: bufferEnd)))
            }
            buffer = ""
        }
        for character in text {
            let raw = String(character)
            let end = offset + raw.utf16.count
            let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            for scalar in folded.unicodeScalars {
                if isCJK(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                    flush()
                    let value = String(scalar)
                    if !["嗯", "呃", "额"].contains(value) {
                        result.append(.init(value: value, range: .init(start: offset, end: end)))
                    }
                } else if CharacterSet.letters.contains(scalar) {
                    if buffer.isEmpty { bufferStart = offset }
                    buffer.append(contentsOf: String(scalar))
                    bufferEnd = end
                } else {
                    flush()
                }
            }
            offset = end
        }
        flush()
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }
}
