import Foundation

public struct TeleprompterAnalysisRequest: Sendable {
    public let sourceText: String
    public let language: String?
    public let style: String?

    public init(sourceText: String, language: String?, style: String?) {
        self.sourceText = sourceText
        self.language = language
        self.style = style
    }
}

public struct TeleprompterAnalysis: Codable, Equatable, Sendable {
    public static let schemaVersion = "teleprompter.analysis.v1"

    public let schemaVersion: String
    public let segments: [TeleprompterSegment]

    public init(schemaVersion: String = TeleprompterAnalysis.schemaVersion, segments: [TeleprompterSegment]) {
        self.schemaVersion = schemaVersion
        self.segments = segments
    }
}

public struct TeleprompterAnalysisDecoder: Sendable {
    public init() {}

    public func decode(_ json: String, sourceText: String) throws -> TeleprompterAnalysis {
        do {
            let data = Data(json.utf8)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.schemaVersion == TeleprompterAnalysis.schemaVersion,
                  !payload.segments.isEmpty else {
                throw TeleprompterTextError.invalidAnalysis
            }

            var segments: [TeleprompterSegment] = []
            var previousEnd = -1
            for (ordinal, payloadSegment) in payload.segments.enumerated() {
                let range = TeleprompterSourceRange(
                    start: payloadSegment.sourceStart,
                    end: payloadSegment.sourceEnd
                )
                guard !payloadSegment.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !payloadSegment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      range.isValid(in: sourceText),
                      range.start >= previousEnd,
                      let sourceRange = stringRange(range, in: sourceText),
                      TeleprompterNormalizer.normalize(String(sourceText[sourceRange]))
                        == TeleprompterNormalizer.normalize(payloadSegment.text),
                      let pauseHint = TeleprompterPauseHint(rawValue: payloadSegment.pauseHint)
                else {
                    throw TeleprompterTextError.invalidAnalysis
                }

                segments.append(
                    TeleprompterSegment(
                        id: payloadSegment.id,
                        ordinal: ordinal,
                        sourceRange: range,
                        text: payloadSegment.text,
                        keywords: payloadSegment.keywords,
                        matchPhrases: payloadSegment.matchPhrases,
                        pauseHint: pauseHint
                    )
                )
                previousEnd = range.end
            }

            return TeleprompterAnalysis(segments: segments)
        } catch let error as TeleprompterTextError {
            throw error
        } catch {
            throw TeleprompterTextError.invalidAnalysis
        }
    }

    private func stringRange(
        _ sourceRange: TeleprompterSourceRange,
        in sourceText: String
    ) -> Range<String.Index>? {
        let lower = String.Index(utf16Offset: sourceRange.start, in: sourceText)
        let upper = String.Index(utf16Offset: sourceRange.end, in: sourceText)
        guard lower.utf16Offset(in: sourceText) == sourceRange.start,
              upper.utf16Offset(in: sourceText) == sourceRange.end else {
            return nil
        }
        return lower..<upper
    }

    private struct Payload: Decodable {
        let schemaVersion: String
        let segments: [SegmentPayload]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case segments
        }
    }

    private struct SegmentPayload: Decodable {
        let id: String
        let sourceStart: Int
        let sourceEnd: Int
        let text: String
        let keywords: [String]
        let matchPhrases: [String]
        let pauseHint: String

        enum CodingKeys: String, CodingKey {
            case id
            case sourceStart = "source_start"
            case sourceEnd = "source_end"
            case text
            case keywords
            case matchPhrases = "match_phrases"
            case pauseHint = "pause_hint"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            sourceStart = try container.decode(Int.self, forKey: .sourceStart)
            sourceEnd = try container.decode(Int.self, forKey: .sourceEnd)
            text = try container.decode(String.self, forKey: .text)
            keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
            matchPhrases = try container.decodeIfPresent([String].self, forKey: .matchPhrases) ?? []
            pauseHint = try container.decode(String.self, forKey: .pauseHint)
        }
    }
}

public struct TeleprompterAIClient: Sendable {
    public typealias Completion = @Sendable (String) async throws -> String

    private let completion: Completion
    private let decoder: TeleprompterAnalysisDecoder

    public init(
        completion: @escaping Completion,
        decoder: TeleprompterAnalysisDecoder = .init()
    ) {
        self.completion = completion
        self.decoder = decoder
    }

    public func analyze(_ request: TeleprompterAnalysisRequest) async throws -> TeleprompterAnalysis {
        guard !TeleprompterNormalizer.tokens(request.sourceText).isEmpty else {
            throw TeleprompterTextError.emptySource
        }
        let response = try await completion(Self.prompt(for: request))
        return try decoder.decode(response, sourceText: request.sourceText)
    }

    public static func prompt(for request: TeleprompterAnalysisRequest) -> String {
        let language = request.language ?? "跟随原稿"
        let style = request.style ?? "自然、适合口语表达"
        return """
        你是提词稿整理器。只对用户提供的原稿做可追溯的分段、关键词、可接受口语表达和停顿建议，不新增事实、不扩写内容。
        输出严格 JSON，schema_version 必须是 \(TeleprompterAnalysis.schemaVersion)，字段为 segments；每个段落必须包含 id、source_start、source_end、text、keywords、match_phrases、pause_hint。source_start/source_end 使用原稿 UTF-16 偏移，text 必须来自对应原文范围，pause_hint 只能是 short、medium 或 long。
        语言偏好：\(language)
        表达偏好：\(style)

        原稿：
        \(request.sourceText)
        """
    }
}
