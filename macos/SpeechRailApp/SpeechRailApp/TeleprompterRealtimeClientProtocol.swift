import Foundation
import SpeechRailControlKit

/// Recognition hints negotiated before the first PCM frame. Both fields are
/// optional on the wire: an empty keyword list means "no hint", and a `nil`
/// language leaves the server default in place.
public struct TeleprompterRealtimeConfiguration: Sendable, Equatable {
    public var language: String?
    public var keywords: [String]

    public init(language: String? = nil, keywords: [String] = []) {
        self.language = language
        self.keywords = keywords
    }

    public static let contractMaxKeywords = 128
    public static let contractMaxKeywordLength = 1000
    public static let contractLanguageRange = 2...24

    /// The recognition language is an advanced hint: `nil` keeps whatever the
    /// server defaults to, which is right for most scripts. The picker is
    /// therefore collapsed into a labelled menu rather than sitting on the
    /// default reading path.
    public static let preferredSpeechLanguageDefaultsKey =
        "speechrail.teleprompter.preferredSpeechLanguage.v1"

    public struct SpeechLanguageChoice: Identifiable, Hashable, Sendable {
        public let code: String
        public let label: String
        public var id: String { code }
    }

    public static let speechLanguageChoices: [SpeechLanguageChoice] = [
        .init(code: "zh", label: "中文"),
        .init(code: "en", label: "English"),
        .init(code: "ja", label: "日本語"),
        .init(code: "ko", label: "한국어"),
        .init(code: "yue", label: "粤语")
    ]

    public static func label(forSpeechLanguage code: String) -> String? {
        speechLanguageChoices.first { $0.code == code }?.label
    }

    /// Keeps only values the wire contract accepts, so a bad setting degrades
    /// to "no hint" instead of failing the connection.
    public var sanitized: TeleprompterRealtimeConfiguration {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = (trimmedLanguage.map {
            $0.count >= Self.contractLanguageRange.lowerBound
                && $0.count <= Self.contractLanguageRange.upperBound
        } ?? false) ? trimmedLanguage : nil
        var seen: Set<String> = []
        let keywords = keywords.compactMap { keyword -> String? in
            let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value.count <= Self.contractMaxKeywordLength,
                  seen.insert(value).inserted
            else { return nil }
            return value
        }
        return .init(
            language: language,
            keywords: Array(keywords.prefix(Self.contractMaxKeywords))
        )
    }
}

/// Minimal seam for the Realtime transport used by the teleprompter.
///
/// Production uses the existing `RealtimeASRClient`; tests can inject a fake
/// actor to prove that late connects and stop failures cannot leave a hidden
/// capture owner behind.
public protocol TeleprompterRealtimeClientProtocol: Sendable {
    func connect() async throws
    func events() async -> RealtimeEventStream<RealtimeASRClient.Event>
    func append(_ pcm: Data) async throws
    func drainAndClear(timeout: Duration) async throws
    func close() async
}

extension RealtimeASRClient: TeleprompterRealtimeClientProtocol {}
