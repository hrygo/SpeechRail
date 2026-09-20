import Foundation

public enum TeleprompterNormalizer {
    private static let fillerPhrases = [
        "嗯", "呃", "额", "然后", "就是", "那个", "其实", "uh", "um", "er"
    ]

    public static func normalize(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    public static func tokens(_ text: String) -> [String] {
        var folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        for phrase in fillerPhrases {
            folded = folded.replacingOccurrences(of: phrase, with: " ")
        }

        var cleaned = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || isPunctuationOrSymbol(scalar) {
                cleaned.append(" ")
            } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                cleaned.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }

        var result: [String] = []
        var latinBuffer = ""
        func flushLatin() {
            guard !latinBuffer.isEmpty else { return }
            result.append(latinBuffer)
            latinBuffer.removeAll(keepingCapacity: true)
        }

        for scalar in cleaned {
            if isCJK(scalar) {
                flushLatin()
                result.append(String(scalar))
            } else if scalar.properties.isWhitespace {
                flushLatin()
            } else {
                latinBuffer.append(contentsOf: String(scalar))
            }
        }
        flushLatin()
        return result
    }

    private static func isPunctuationOrSymbol(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }
}
