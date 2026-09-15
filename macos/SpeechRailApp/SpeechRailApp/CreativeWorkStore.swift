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

public extension CreativeWork {
    /// `m:ss`, or nil while the duration has not been read from the audio.
    var durationText: String? {
        guard let durationSeconds else { return nil }
        let totalSeconds = max(0, Int(durationSeconds.rounded()))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    /// Filesystem-safe stem for exporting this work.
    var exportBaseName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "SpeechRail-作品" : String(cleaned.prefix(80))
    }
}

public enum CreativeWorkStoreError: Error, LocalizedError, Sendable {
    case invalidWorkID
    case invalidTitle
    case storageUnavailable
    case audioUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidWorkID:
            "作品标识无效"
        case .invalidTitle:
            "作品名称不能为空"
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
            try writeIndex(works)
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    /// Removes a work and the audio file it owns. The audio goes first: a
    /// failure then leaves an index entry that still resolves, instead of an
    /// orphaned file no longer reachable from the list (REDESIGN-SPEC §7.4).
    public func delete(_ work: CreativeWork) throws {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        do {
            var works = try list()
            guard let index = works.firstIndex(where: { $0.id == work.id }) else { return }
            let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
            if fileManager.fileExists(atPath: audioURL.path) {
                try fileManager.removeItem(at: audioURL)
            }
            works.remove(at: index)
            try writeIndex(works)
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    /// Renames a work without touching its audio: the file keeps the
    /// identifier-based name, so a rename never moves bytes on disk
    /// (REDESIGN-SPEC §7.4).
    @discardableResult
    public func rename(_ work: CreativeWork, title: String) throws -> CreativeWork {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CreativeWorkStoreError.invalidTitle
        }
        do {
            var works = try list()
            guard let index = works.firstIndex(where: { $0.id == work.id }) else {
                throw CreativeWorkStoreError.invalidWorkID
            }
            let existing = works[index]
            let updated = CreativeWork(
                id: existing.id,
                title: String(trimmed.prefix(Self.titleMaximumLength)),
                scriptText: existing.scriptText,
                voiceID: existing.voiceID,
                voiceName: existing.voiceName,
                createdAt: existing.createdAt,
                durationSeconds: existing.durationSeconds,
                audioFileName: existing.audioFileName
            )
            works[index] = updated
            try writeIndex(works)
            return updated
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    /// Absolute location of a saved work's audio, without reading it.
    public func audioURL(for work: CreativeWork) throws -> URL {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw CreativeWorkStoreError.audioUnavailable
        }
        return audioURL
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

    private func writeIndex(_ works: [CreativeWork]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder
                .encode(works.sorted { $0.createdAt > $1.createdAt })
                .write(to: indexURL, options: [.atomic])
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }

    private static let titleMaximumLength = 120
}
