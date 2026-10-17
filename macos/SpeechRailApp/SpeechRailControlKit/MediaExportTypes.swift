import Foundation

public struct MediaCapabilitiesSnapshot: Codable, Equatable, Sendable {
    public let available: Bool
    public let encoders: [String]
    public let supportsM4B: Bool
    public let supportsMP3: Bool

    public init(
        available: Bool,
        encoders: [String],
        supportsM4B: Bool,
        supportsMP3: Bool
    ) {
        self.available = available
        self.encoders = encoders
        self.supportsM4B = supportsM4B
        self.supportsMP3 = supportsMP3
    }

    enum CodingKeys: String, CodingKey {
        case available
        case encoders
        case supportsM4B = "supports_m4b"
        case supportsMP3 = "supports_mp3"
    }
}

public struct MediaExportResultSnapshot: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let profile: String
    public let relativeOutputs: [String]
    public let totalFrameCount: Int64
    public let sampleRate: Int
    public let chapterCount: Int
    public let outputSHA256s: [String: String]

    public init(
        requestID: UUID,
        profile: String,
        relativeOutputs: [String],
        totalFrameCount: Int64,
        sampleRate: Int,
        chapterCount: Int,
        outputSHA256s: [String: String]
    ) {
        self.requestID = requestID
        self.profile = profile
        self.relativeOutputs = relativeOutputs
        self.totalFrameCount = totalFrameCount
        self.sampleRate = sampleRate
        self.chapterCount = chapterCount
        self.outputSHA256s = outputSHA256s
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case profile
        case relativeOutputs = "relative_outputs"
        case totalFrameCount = "total_frame_count"
        case sampleRate = "sample_rate"
        case chapterCount = "chapter_count"
        case outputSHA256s = "output_sha256s"
    }
}

public enum MediaControlPayload: Codable, Equatable, Sendable {
    case capabilities(MediaCapabilitiesSnapshot)
    case exportResult(MediaExportResultSnapshot)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let singleContainer = try decoder.singleValueContainer()
        switch kind {
        case "capabilities":
            self = .capabilities(try singleContainer.decode(MediaCapabilitiesSnapshot.self))
        case "export_result":
            self = .exportResult(try singleContainer.decode(MediaExportResultSnapshot.self))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown media payload kind \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .capabilities(snapshot):
            var container = encoder.container(keyedBy: CapabilityEncodingKeys.self)
            try container.encode("capabilities", forKey: .kind)
            try container.encode(snapshot.available, forKey: .available)
            try container.encode(snapshot.encoders, forKey: .encoders)
            try container.encode(snapshot.supportsM4B, forKey: .supportsM4B)
            try container.encode(snapshot.supportsMP3, forKey: .supportsMP3)
        case let .exportResult(result):
            var container = encoder.container(keyedBy: ExportResultEncodingKeys.self)
            try container.encode("export_result", forKey: .kind)
            try container.encode(result.requestID, forKey: .requestID)
            try container.encode(result.profile, forKey: .profile)
            try container.encode(result.relativeOutputs, forKey: .relativeOutputs)
            try container.encode(result.totalFrameCount, forKey: .totalFrameCount)
            try container.encode(result.sampleRate, forKey: .sampleRate)
            try container.encode(result.chapterCount, forKey: .chapterCount)
            try container.encode(result.outputSHA256s, forKey: .outputSHA256s)
        }
    }

    private enum CapabilityEncodingKeys: String, CodingKey {
        case kind
        case available
        case encoders
        case supportsM4B = "supports_m4b"
        case supportsMP3 = "supports_mp3"
    }

    private enum ExportResultEncodingKeys: String, CodingKey {
        case kind
        case requestID = "request_id"
        case profile
        case relativeOutputs = "relative_outputs"
        case totalFrameCount = "total_frame_count"
        case sampleRate = "sample_rate"
        case chapterCount = "chapter_count"
        case outputSHA256s = "output_sha256s"
    }
}

public struct AudiobookExportManifestPayload: Codable, Equatable, Sendable {
    public struct FragmentItem: Codable, Equatable, Sendable {
        public let fragmentID: UUID
        public let candidateID: UUID
        public let relativePath: String
        public let fileSHA256: String
        public let pcmSHA256: String
        public let frameCount: Int64
        public let sampleRate: Int

        public init(
            fragmentID: UUID,
            candidateID: UUID,
            relativePath: String,
            fileSHA256: String,
            pcmSHA256: String,
            frameCount: Int64,
            sampleRate: Int = 48_000
        ) {
            self.fragmentID = fragmentID
            self.candidateID = candidateID
            self.relativePath = relativePath
            self.fileSHA256 = fileSHA256
            self.pcmSHA256 = pcmSHA256
            self.frameCount = frameCount
            self.sampleRate = sampleRate
        }

        enum CodingKeys: String, CodingKey {
            case fragmentID = "fragment_id"
            case candidateID = "candidate_id"
            case relativePath = "relative_path"
            case fileSHA256 = "file_sha256"
            case pcmSHA256 = "pcm_sha256"
            case frameCount = "frame_count"
            case sampleRate = "sample_rate"
        }
    }

    public struct ChapterItem: Codable, Equatable, Sendable {
        public let chapterID: UUID
        public let ordinal: Int
        public let title: String
        public let fragments: [FragmentItem]

        public init(
            chapterID: UUID,
            ordinal: Int,
            title: String,
            fragments: [FragmentItem]
        ) {
            self.chapterID = chapterID
            self.ordinal = ordinal
            self.title = title
            self.fragments = fragments
        }

        enum CodingKeys: String, CodingKey {
            case chapterID = "chapter_id"
            case ordinal
            case title
            case fragments
        }
    }

    public struct CoverItem: Codable, Equatable, Sendable {
        public let relativePath: String
        public let imageSHA256: String

        public init(relativePath: String, imageSHA256: String) {
            self.relativePath = relativePath
            self.imageSHA256 = imageSHA256
        }

        enum CodingKeys: String, CodingKey {
            case relativePath = "relative_path"
            case imageSHA256 = "image_sha256"
        }
    }

    public static let v1SchemaVersion = "audiobook_media_export_v1"
    public static let v2SchemaVersion = "audiobook_media_export_v2"

    public let schemaVersion: String
    public let requestID: UUID
    public let bookID: UUID
    public let sourceID: UUID
    public let productionRevisionID: UUID
    public let profile: String
    public let bookTitle: String
    public let author: String?
    public let chapters: [ChapterItem]
    public let cover: CoverItem?

    public init(
        requestID: UUID,
        bookID: UUID,
        sourceID: UUID,
        productionRevisionID: UUID,
        profile: String,
        bookTitle: String,
        author: String? = nil,
        chapters: [ChapterItem],
        cover: CoverItem? = nil
    ) {
        self.schemaVersion = cover == nil ? Self.v1SchemaVersion : Self.v2SchemaVersion
        self.requestID = requestID
        self.bookID = bookID
        self.sourceID = sourceID
        self.productionRevisionID = productionRevisionID
        self.profile = profile
        self.bookTitle = bookTitle
        self.author = author
        self.chapters = chapters
        self.cover = cover
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case bookID = "book_id"
        case sourceID = "source_id"
        case productionRevisionID = "production_revision_id"
        case profile
        case bookTitle = "book_title"
        case author
        case chapters
        case cover
    }
}
