import Foundation
import SpeechRailControlKit

/// T12：有声书导出控制器（整本 M4B 完整门禁、分章 MP3 实际与遗漏清单、XPC 媒体操作与原子覆盖提交）。
public enum AudiobookExportProfile: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case m4b = "m4b"
    case chapterMP3 = "chapter_mp3"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .m4b: "整本有声书（.m4b）"
        case .chapterMP3: "分章节音频包（.mp3）"
        }
    }

    public var subtitle: String {
        switch self {
        case .m4b: "包含章节目录与书名元数据，适合 Apple 图书及播客播放器（需全书所有章节均为最新完整音频）。"
        case .chapterMP3: "按所选已就绪章节分别生成 MP3 文件及章节清单，未就绪章节将明确列出遗漏原因。"
        }
    }
}

public struct AudiobookOverwriteConsent: Codable, Equatable, Sendable {
    public let destinationURL: URL
    public let existingFileSize: Int64
    public let existingModificationDate: Date?
    public let existingSHA256: String?

    public init(
        destinationURL: URL,
        existingFileSize: Int64,
        existingModificationDate: Date? = nil,
        existingSHA256: String? = nil
    ) {
        self.destinationURL = destinationURL.standardizedFileURL
        self.existingFileSize = existingFileSize
        self.existingModificationDate = existingModificationDate
        self.existingSHA256 = existingSHA256
    }

    public static func capture(at url: URL) throws -> AudiobookOverwriteConsent {
        let standardized = url.standardizedFileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: standardized.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modDate = attrs[.modificationDate] as? Date
        var isDir: ObjCBool = false
        let sha: String?
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
           !isDir.boolValue,
           let data = try? Data(contentsOf: standardized)
        {
            sha = AudiobookDigest.sha256Hex(data)
        } else {
            sha = nil
        }
        return AudiobookOverwriteConsent(
            destinationURL: standardized,
            existingFileSize: size,
            existingModificationDate: modDate,
            existingSHA256: sha
        )
    }
}

public struct AudiobookPreparedExport: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let bookID: UUID
    public let productionRevisionID: UUID
    public let profile: AudiobookExportProfile
    public let bookTitle: String
    public let author: String?
    public let exportedChapters: [AudiobookChapter]
    public let omittedChapters: [AudiobookOmittedChapterRecord]
    public let stageURL: URL
    public let expectedFrameCount: Int64
    public let expectedSampleRate: Int
    public var verification: AudiobookMediaVerification?

    public init(
        requestID: UUID,
        bookID: UUID,
        productionRevisionID: UUID,
        profile: AudiobookExportProfile,
        bookTitle: String,
        author: String?,
        exportedChapters: [AudiobookChapter],
        omittedChapters: [AudiobookOmittedChapterRecord],
        stageURL: URL,
        expectedFrameCount: Int64,
        expectedSampleRate: Int = AudiobookLimits.intermediateSampleRate,
        verification: AudiobookMediaVerification? = nil
    ) {
        self.requestID = requestID
        self.bookID = bookID
        self.productionRevisionID = productionRevisionID
        self.profile = profile
        self.bookTitle = bookTitle
        self.author = author
        self.exportedChapters = exportedChapters
        self.omittedChapters = omittedChapters
        self.stageURL = stageURL
        self.expectedFrameCount = expectedFrameCount
        self.expectedSampleRate = expectedSampleRate
        self.verification = verification
    }
}

public enum AudiobookExportError: LocalizedError, Equatable, Sendable {
    case fullBookExportBlocked(reasons: [AudiobookOmittedChapterRecord])
    case noExportableChaptersSelected
    case mediaToolUnavailable(String)
    case exportCancelled
    case verificationFailed(String)
    case overwriteConsentRequired(URL)
    case destinationModifiedAfterConsent(URL)
    case commitFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .fullBookExportBlocked(reasons):
            let summary = reasons.prefix(3).map { "\($0.chapterTitle)（\($0.reason)）" }.joined(separator: "、")
            return "整本 M4B 导出要求全书所有章节均为最新完整音频；当前受阻章节：\(summary)。"
        case .noExportableChaptersSelected:
            return "所选范围内没有可导出的已完成章节。"
        case let .mediaToolUnavailable(detail):
            return "导出工具不可用：\(detail)。已有章节音频仍可正常收听。"
        case .exportCancelled:
            return "导出已取消，未生成或覆盖任何目标文件。"
        case let .verificationFailed(reason):
            return "导出产物校验未通过：\(reason)"
        case .overwriteConsentRequired:
            return "目标位置已存在同名文件，需要您的明确覆盖确认。"
        case .destinationModifiedAfterConsent:
            return "目标文件在您确认覆盖后已被其他程序修改，为保护原文件已中止覆盖。"
        case let .commitFailed(detail):
            return "导出文件保存失败：\(detail)"
        }
    }
}

public actor AudiobookExportController {
    public typealias StageEncoderHandler = @Sendable (
        AudiobookExportManifestPayload,
        URL
    ) async throws -> MediaExportResultSnapshot

    private let store: AudiobookProjectStore
    private let castController: AudiobookCastController
    private let revisionController: AudiobookRevisionController
    private let controlTransport: any SpeechRailControlTransport
    private let customStageEncoder: StageEncoderHandler?
    private var cancelledRequestIDs: Set<UUID> = []
    private var activeOperationIDByRequest: [UUID: String] = [:]

    public init(
        store: AudiobookProjectStore,
        castController: AudiobookCastController,
        revisionController: AudiobookRevisionController,
        controlTransport: any SpeechRailControlTransport = UnavailableControlTransport(),
        customStageEncoder: StageEncoderHandler? = nil
    ) {
        self.store = store
        self.castController = castController
        self.revisionController = revisionController
        self.controlTransport = controlTransport
        self.customStageEncoder = customStageEncoder
    }

    public func cancel(requestID: UUID) async {
        cancelledRequestIDs.insert(requestID)
        if let opID = activeOperationIDByRequest[requestID] {
            _ = try? await controlTransport.send(
                ControlRequest(
                    command: .operationCancel,
                    operationID: opID,
                    confirmation: false
                )
            )
        }
    }

    public func checkCapabilities() async -> MediaCapabilitiesSnapshot {
        do {
            let response = try await controlTransport.send(
                ControlRequest(command: .mediaCapabilities, confirmation: false)
            )
            if case let .capabilities(caps) = response.media {
                return caps
            }
        } catch {}
        return MediaCapabilitiesSnapshot(
            available: false,
            encoders: [],
            supportsM4B: false,
            supportsMP3: false
        )
    }

    public func prepare(
        bookID: UUID,
        chapterIDs: [UUID]?,
        profile: AudiobookExportProfile
    ) async throws -> AudiobookPreparedExport {
        let book = try await store.book(id: bookID)
        let allChapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
        let allCandidates = try await store.candidates(for: bookID)
        let candidatesByID = Dictionary(uniqueKeysWithValues: allCandidates.map { ($0.id, $0) })

        let requestedIDSet: Set<UUID>? = chapterIDs.map(Set.init)
        let isFullBookRequest = (profile == .m4b) || (requestedIDSet == nil)

        var exportedChapters: [AudiobookChapter] = []
        var omittedChapters: [AudiobookOmittedChapterRecord] = []
        var manifestChapters: [AudiobookExportManifestPayload.ChapterItem] = []
        var chapterRevisionsMap: [UUID: UUID] = [:]
        var totalFrames: Int64 = 0

        for chapter in allChapters {
            if let requestedIDSet, !requestedIDSet.contains(chapter.id) {
                omittedChapters.append(
                    AudiobookOmittedChapterRecord(
                        chapterID: chapter.id,
                        chapterTitle: chapter.title,
                        reason: "未勾选该章节"
                    )
                )
                continue
            }

            let chapterAnns = try await store.annotations(for: bookID, chapterID: chapter.id)
            if chapterAnns.isEmpty {
                omittedChapters.append(
                    AudiobookOmittedChapterRecord(
                        chapterID: chapter.id,
                        chapterTitle: chapter.title,
                        reason: "尚未完成全书分析"
                    )
                )
                continue
            }
            if chapterAnns.contains(where: { $0.assignment.isUnknown }) {
                omittedChapters.append(
                    AudiobookOmittedChapterRecord(
                        chapterID: chapter.id,
                        chapterTitle: chapter.title,
                        reason: "包含待确认说话人"
                    )
                )
                continue
            }

            guard let validCurrentRev = try await revisionController.currentChapter(
                bookID: bookID,
                chapterID: chapter.id
            ) else {
                let hasPrev = (try? await revisionController.previousListenableChapter(
                    bookID: bookID,
                    chapterID: chapter.id
                )) != nil
                omittedChapters.append(
                    AudiobookOmittedChapterRecord(
                        chapterID: chapter.id,
                        chapterTitle: chapter.title,
                        reason: hasPrev ? "角色或音色已修改，需更新本章音频" : "本章音频尚未制作完成"
                    )
                )
                continue
            }

            var fragmentItems: [AudiobookExportManifestPayload.FragmentItem] = []
            for binding in validCurrentRev.orderedBindings {
                guard let candidate = candidatesByID[binding.candidateID],
                      candidate.isReceiptVerified,
                      try await store.verifyCandidateAsset(candidate)
                else {
                    omittedChapters.append(
                        AudiobookOmittedChapterRecord(
                            chapterID: chapter.id,
                            chapterTitle: chapter.title,
                            reason: "片段音频资产缺失或未通过核验"
                        )
                    )
                    fragmentItems = []
                    break
                }
                fragmentItems.append(
                    AudiobookExportManifestPayload.FragmentItem(
                        fragmentID: binding.fragmentID,
                        candidateID: candidate.id,
                        relativePath: candidate.relativeAssetPath,
                        fileSHA256: candidate.fileSHA256,
                        pcmSHA256: candidate.pcmSHA256,
                        frameCount: candidate.frameCount,
                        sampleRate: candidate.sampleRate
                    )
                )
                totalFrames += candidate.frameCount
            }

            guard !fragmentItems.isEmpty else { continue }
            exportedChapters.append(chapter)
            chapterRevisionsMap[chapter.id] = validCurrentRev.id
            manifestChapters.append(
                AudiobookExportManifestPayload.ChapterItem(
                    chapterID: chapter.id,
                    ordinal: chapter.ordinal,
                    title: chapter.title,
                    fragments: fragmentItems
                )
            )
        }

        if isFullBookRequest && !omittedChapters.isEmpty {
            throw AudiobookExportError.fullBookExportBlocked(reasons: omittedChapters)
        }
        guard !exportedChapters.isEmpty else {
            throw AudiobookExportError.noExportableChaptersSelected
        }

        let prodRev = AudiobookProductionRevision(
            bookID: bookID,
            sourceID: book.sourceID,
            chapterRevisionIDsByChapter: chapterRevisionsMap
        )
        try await store.saveProductionRevision(prodRev, makeCurrent: isFullBookRequest)

        let requestID = UUID()
        cancelledRequestIDs.remove(requestID)

        let exportReqDir = store.rootURL
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportReqDir, withIntermediateDirectories: true)

        let manifest = AudiobookExportManifestPayload(
            requestID: requestID,
            bookID: bookID,
            sourceID: book.sourceID,
            productionRevisionID: prodRev.id,
            profile: profile.rawValue,
            bookTitle: book.title,
            author: book.author,
            chapters: manifestChapters
        )
        let manifestData = try ControlWireCodec.encode(manifest)
        let requestFileURL = exportReqDir.appendingPathComponent("request.json", isDirectory: false)
        try manifestData.write(to: requestFileURL, options: .atomic)

        let stageResult: MediaExportResultSnapshot
        if let customStageEncoder {
            stageResult = try await customStageEncoder(manifest, exportReqDir)
        } else {
            stageResult = try await executeMediaExportViaControlTransport(requestID: requestID)
        }

        if cancelledRequestIDs.contains(requestID) || Task.isCancelled {
            try? FileManager.default.removeItem(
                at: exportReqDir.appendingPathComponent("stage", isDirectory: true)
            )
            throw AudiobookExportError.exportCancelled
        }

        let stageTargetURL: URL
        if profile == .m4b {
            stageTargetURL = exportReqDir
                .appendingPathComponent("stage", isDirectory: true)
                .appendingPathComponent("book.m4b", isDirectory: false)
        } else {
            stageTargetURL = exportReqDir
                .appendingPathComponent("stage", isDirectory: true)
                .appendingPathComponent("chapters", isDirectory: true)
        }

        var prepared = AudiobookPreparedExport(
            requestID: requestID,
            bookID: bookID,
            productionRevisionID: prodRev.id,
            profile: profile,
            bookTitle: book.title,
            author: book.author,
            exportedChapters: exportedChapters,
            omittedChapters: omittedChapters,
            stageURL: stageTargetURL,
            expectedFrameCount: stageResult.totalFrameCount > 0 ? stageResult.totalFrameCount : totalFrames,
            expectedSampleRate: stageResult.sampleRate
        )
        let verification = try await AudiobookMediaVerifier.verify(url: stageTargetURL, expected: prepared)
        prepared.verification = verification
        return prepared
    }

    public func commit(
        _ prepared: AudiobookPreparedExport,
        destination: URL,
        overwriteConsent: AudiobookOverwriteConsent? = nil
    ) async throws {
        if cancelledRequestIDs.contains(prepared.requestID) || Task.isCancelled {
            throw AudiobookExportError.exportCancelled
        }

        let verification: AudiobookMediaVerification
        if let existing = prepared.verification {
            verification = existing
        } else {
            verification = try await AudiobookMediaVerifier.verify(url: prepared.stageURL, expected: prepared)
        }

        let fm = FileManager.default
        let standardizedDest = destination.standardizedFileURL
        let parentDir = standardizedDest.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: standardizedDest.path) {
            guard let consent = overwriteConsent,
                  consent.destinationURL == standardizedDest
            else {
                throw AudiobookExportError.overwriteConsentRequired(standardizedDest)
            }
            let currentIdentity = try AudiobookOverwriteConsent.capture(at: standardizedDest)
            if currentIdentity.existingFileSize != consent.existingFileSize
                || (consent.existingSHA256 != nil && currentIdentity.existingSHA256 != consent.existingSHA256)
            {
                throw AudiobookExportError.destinationModifiedAfterConsent(standardizedDest)
            }
        }

        let siblingTemp = parentDir.appendingPathComponent(
            ".\(standardizedDest.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fm.removeItem(at: siblingTemp) }

        if prepared.profile == .m4b {
            try fm.copyItem(at: prepared.stageURL, to: siblingTemp)
        } else {
            try fm.createDirectory(at: siblingTemp, withIntermediateDirectories: true)
            let mp3Files = try fm.contentsOfDirectory(at: prepared.stageURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "mp3" }
            for file in mp3Files {
                try fm.copyItem(
                    at: file,
                    to: siblingTemp.appendingPathComponent(file.lastPathComponent, isDirectory: false)
                )
            }
            // Write public chapter summary manifest (no source text or secret config!)
            let summaryObj: [String: Any] = [
                "book_title": prepared.bookTitle,
                "author": prepared.author as Any,
                "exported_chapters": prepared.exportedChapters.map { ["ordinal": $0.ordinal + 1, "title": $0.title] },
                "omitted_chapters": prepared.omittedChapters.map { ["title": $0.chapterTitle, "reason": $0.reason] }
            ]
            let summaryData = try JSONSerialization.data(withJSONObject: summaryObj, options: [.sortedKeys, .prettyPrinted])
            try summaryData.write(
                to: siblingTemp.appendingPathComponent("chapters-manifest.json", isDirectory: false),
                options: .atomic
            )
        }

        if cancelledRequestIDs.contains(prepared.requestID) || Task.isCancelled {
            throw AudiobookExportError.exportCancelled
        }

        // Re-verify overwrite target right before atomic swap
        if fm.fileExists(atPath: standardizedDest.path) {
            guard let consent = overwriteConsent else {
                throw AudiobookExportError.overwriteConsentRequired(standardizedDest)
            }
            let latestIdentity = try AudiobookOverwriteConsent.capture(at: standardizedDest)
            if latestIdentity.existingFileSize != consent.existingFileSize
                || (consent.existingSHA256 != nil && latestIdentity.existingSHA256 != consent.existingSHA256)
            {
                throw AudiobookExportError.destinationModifiedAfterConsent(standardizedDest)
            }
            _ = try fm.replaceItemAt(standardizedDest, withItemAt: siblingTemp)
        } else {
            try fm.moveItem(at: siblingTemp, to: standardizedDest)
        }

        let exportRecord = AudiobookExportRecord(
            bookID: prepared.bookID,
            productionRevisionID: prepared.productionRevisionID,
            profileRawValue: prepared.profile.rawValue,
            exportedChapterIDs: prepared.exportedChapters.map(\.id),
            omittedChapters: prepared.omittedChapters,
            finalFileSHA256: verification.fileSHA256,
            totalFrameCount: verification.frameCount,
            durationSeconds: verification.durationSeconds
        )
        try await store.saveExportRecord(exportRecord)
    }

    // MARK: - Private XPC Polling

    private func executeMediaExportViaControlTransport(
        requestID: UUID
    ) async throws -> MediaExportResultSnapshot {
        let startResponse: ControlResponse
        do {
            startResponse = try await controlTransport.send(
                ControlRequest(
                    command: .mediaExport,
                    mediaRequestID: requestID,
                    confirmation: true
                )
            )
        } catch {
            throw AudiobookExportError.mediaToolUnavailable("本机控制代理未连接")
        }

        if startResponse.status == .failed {
            if startResponse.errorCode == .unsupported || startResponse.errorCode == .managedRuntimeMissing || startResponse.errorCode == .codecUnavailable {
                throw AudiobookExportError.mediaToolUnavailable(startResponse.message ?? "当前运行时未包含媒体导出工具")
            }
            throw AudiobookExportError.commitFailed(startResponse.message ?? "导出启动失败")
        }

        if case let .exportResult(immediateResult) = startResponse.media {
            return immediateResult
        }

        guard let operationID = startResponse.operation?.operationID else {
            throw AudiobookExportError.mediaToolUnavailable("控制代理未返回有效的导出任务编号")
        }
        activeOperationIDByRequest[requestID] = operationID
        defer { activeOperationIDByRequest.removeValue(forKey: requestID) }

        while true {
            if cancelledRequestIDs.contains(requestID) || Task.isCancelled {
                _ = try? await controlTransport.send(
                    ControlRequest(command: .operationCancel, operationID: operationID, confirmation: false)
                )
                throw AudiobookExportError.exportCancelled
            }

            let statusResp = try await controlTransport.send(
                ControlRequest(command: .operationStatus, operationID: operationID, confirmation: false)
            )
            switch statusResp.status {
            case .committed, .completed:
                if case let .exportResult(result) = statusResp.media {
                    return result
                }
                throw AudiobookExportError.verificationFailed("导出操作完成但缺少媒体结果回执。")
            case .cancelled:
                throw AudiobookExportError.exportCancelled
            case .failed, .rolledBack, .unavailable:
                if statusResp.errorCode == .unsupported || statusResp.errorCode == .codecUnavailable {
                    throw AudiobookExportError.mediaToolUnavailable(statusResp.message ?? "缺少音频编码器")
                }
                throw AudiobookExportError.commitFailed(statusResp.message ?? "媒体编码过程失败")
            case .accepted, .running, .ok, .unchanged:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
