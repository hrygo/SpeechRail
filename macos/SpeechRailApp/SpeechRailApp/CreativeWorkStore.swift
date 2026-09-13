import Foundation

public struct CreativeWork: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let scriptText: String
    public let voiceID: String
    public let voiceName: String
    public let createdAt: Date
    public let durationSeconds: Double?
    public let audioFileName: String

    public init(
        id: String,
        title: String,
        scriptText: String,
        voiceID: String,
        voiceName: String,
        createdAt: Date = Date(),
        durationSeconds: Double? = nil,
        audioFileName: String
    ) {
        self.id = id
        self.title = title
        self.scriptText = scriptText
        self.voiceID = voiceID
        self.voiceName = voiceName
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.audioFileName = audioFileName
    }
}

public enum CreativeWorkStoreError: Error, LocalizedError, Sendable {
    case invalidWorkID
    case storageUnavailable
    case audioUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidWorkID:
            "作品标识无效"
        case .storageUnavailable:
            "作品存储暂时不可用"
        case .audioUnavailable:
            "作品音频暂时不可用"
        }
    }
}

@MainActor
public final class CreativeWorkStore {
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let resolvedDirectory = directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpeechRail/Works", isDirectory: true)
        self.directory = resolvedDirectory
        self.indexURL = resolvedDirectory.appendingPathComponent("works.json")
    }

    public func list() throws -> [CreativeWork] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CreativeWork].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    public func save(_ work: CreativeWork, audioData: Data) throws {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        guard !audioData.isEmpty else {
            throw CreativeWorkStoreError.audioUnavailable
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
            try audioData.write(to: audioURL, options: [.atomic])

            var works = try list()
            works.removeAll { $0.id == work.id }
            works.append(work)
            works.sort { $0.createdAt > $1.createdAt }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(works).write(to: indexURL, options: [.atomic])
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    public func loadAudio(for work: CreativeWork) throws -> Data {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
        do {
            let data = try Data(contentsOf: audioURL)
            guard !data.isEmpty else { throw CreativeWorkStoreError.audioUnavailable }
            return data
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.audioUnavailable
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }
}
