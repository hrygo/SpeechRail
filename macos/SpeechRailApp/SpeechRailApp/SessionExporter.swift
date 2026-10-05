import Foundation
#if canImport(AppKit)
import AppKit
#endif

// 记录库的导出物（`SESSIONS-SPEC` §6.2 的三条设计判断之三、§6.3.2 的页脚）。
//
// 两件事按规矩来：
//   1. **时间码从 `line.t_start / t_end` 取**（§6.5），不在这里重新算。写进这两列的是
//      **相对会话开始的墙钟秒**（`CaptionSession` 的口径），所以暂停或续接留下的空档在
//      导出物里是**看得见的跳变**，而不是被抹平成连续——那正是 §16.7 要的证据。
//      （上一版注释写的是"墙钟不进导出物"，与落库实现相反，已改。）
//   2. **导出的是文字记录，不是音频**。原始音频本来就不留存，所以导出物里没有它，
//      也没有任何密钥、完整 prompt 或 embedding（项目约束：这些没有列可写）。

public enum SessionExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case srt
    case plainText
    case json

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .markdown: "Markdown"
        case .srt: "SRT 字幕"
        case .plainText: "纯文本"
        case .json: "JSON"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .srt: "srt"
        case .plainText: "txt"
        case .json: "json"
        }
    }

    /// 三种能力默认落在哪一档：会议给 Markdown（纪要与转录都要看），字幕给 SRT，
    /// 助手给纯文本。用户仍可在保存面板里改格式——这里只是默认值。
    public static func preferred(for kind: SessionKind) -> SessionExportFormat {
        switch kind {
        case .meeting: .markdown
        case .captions: .srt
        case .assistant: .plainText
        case .teleprompter: .plainText
        }
    }
}

/// 导出用的输入。把「读库」与「拼文本」分开，导出器因此不依赖 `SessionStore`，
/// 可以拿一段固定的数据直接核对输出（这一层没有副作用）。
public struct SessionExportPayload: Sendable {
    public var record: SessionRecord
    public var lines: [TranscriptLine]
    public var speakerNames: [String: String]
    public var minutes: MinutesVersion?

    public init(
        record: SessionRecord,
        lines: [TranscriptLine],
        speakerNames: [String: String] = [:],
        minutes: MinutesVersion? = nil
    ) {
        self.record = record
        self.lines = lines
        self.speakerNames = speakerNames
        self.minutes = minutes
    }

    var title: String {
        if let title = record.title, !title.isEmpty { return title }
        return record.startedAt.formatted(date: .numeric, time: .shortened)
    }

    /// 匿名标签 → 用户手写的名字。**正文一个字不动**，只换显示（§15.3 第 2 条）。
    ///
    /// `speaker` 但没有标签时给**空串**：字幕那一档（没开分人）每一行都写「说话人：」
    /// 是噪声，不是信息——没有任何东西可供区分时，导出物里就不该出现这一栏。
    func speakerText(for line: TranscriptLine) -> String {
        switch line.role {
        case .user: return "你"
        case .assistant: return "助手"
        case .speaker:
            guard let label = line.speakerLabel else { return "" }
            return speakerNames[label] ?? "说话人 \(label)"
        }
    }

    /// 行首的前缀（带冒号）。空串表示这一行没有归属信息，正文直接开头。
    func speakerPrefix(for line: TranscriptLine) -> String {
        let text = speakerText(for: line)
        return text.isEmpty ? "" : "\(text)："
    }
}

public enum SessionExporter {
    public static func export(_ payload: SessionExportPayload, as format: SessionExportFormat) -> String {
        switch format {
        case .markdown: markdown(payload)
        case .srt: srt(payload)
        case .plainText: plainText(payload)
        case .json: json(payload)
        }
    }

    /// 建议的文件名（保存面板的默认值）：`<kind>-<标题或首句摘要>-<yyyyMMdd-HHmm>.<ext>`（§16.4）。
    ///
    /// 文件名里不放 UUID——UUID 是库内主键，用户要在 Finder 里认出这个文件靠的是标题与时间。
    public static func suggestedFileName(_ payload: SessionExportPayload, as format: SessionExportFormat) -> String {
        let kindSlug = payload.record.kind.rawValue
        let titleSlug = fileNameStem(payload)
        return "\(kindSlug)-\(titleSlug)-\(fileStamp(payload.record.startedAt)).\(format.fileExtension)"
    }

    /// 标题；没有标题就用首句摘要，两者都没有才退到时间。
    private static func fileNameStem(_ payload: SessionExportPayload) -> String {
        let candidate: String
        if let title = payload.record.title, !title.isEmpty {
            candidate = title
        } else if let firstLine = payload.lines.first(where: { !$0.text.isEmpty }) {
            candidate = String(firstLine.text.prefix(24))
        } else {
            candidate = payload.record.startedAt.formatted(date: .numeric, time: .shortened)
        }
        // 换行与路径分隔符在文件名里没有意义；空名会让文件名退化成 `meeting--20260918-1645.md`，
        // 所以兜一个固定词。
        let cleaned = candidate
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 名字太长两边都看不全：库里那条记录才是完整的那一份，文件名截断即可。
        return cleaned.isEmpty ? "session" : String(cleaned.prefix(60))
    }

    private static func fileStamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0
        )
    }

    // MARK: - Markdown

    private static func markdown(_ payload: SessionExportPayload) -> String {
        var rows: [String] = []
        rows.append("# \(payload.title)")
        rows.append("")
        rows.append("| 项 | 值 |")
        rows.append("|---|---|")
        rows.append("| 类型 | \(payload.record.kind.title) |")
        rows.append("| 开始 | \(payload.record.startedAt.formatted(date: .abbreviated, time: .standard)) |")
        if let endedAt = payload.record.endedAt {
            rows.append("| 结束 | \(endedAt.formatted(date: .abbreviated, time: .standard)) |")
            rows.append("| 时长 | \(SessionCoordinator.formatted(endedAt.timeIntervalSince(payload.record.startedAt))) |")
        } else {
            // 未封存的记录导出来是「还没结束」，不是「00:00」——后者会让人以为这场会议没录上。
            rows.append("| 时长 | 未结束 |")
        }
        rows.append("| 音频来源 | \(payload.record.audioSource.title) |")
        rows.append("| 识别精度 | \(payload.record.engineProfile) |")
        rows.append("| 说话人 | \(diarizationText(payload.record)) |")
        if let voice = payload.record.voice {
            rows.append("| 音色 | \(voice.name ?? voice.id) |")
        }
        if let persona = payload.record.persona {
            rows.append("| 角色 | \(persona.title) |")
        }
        if payload.record.endedReason != .user {
            rows.append("| 结束方式 | \(payload.record.endedReason.title) |")
        }
        rows.append("")
        rows.append("> 记录只保存在这台 Mac 上；原始音频不留存。")

        if let body = payload.minutes?.body, !body.isEmpty {
            rows.append("")
            rows.append("## 纪要（第 \(payload.minutes?.version ?? 1) 版）")
            rows.append("")
            rows.append(body)
        }

        rows.append("")
        rows.append("## 文字记录")
        rows.append("")
        for line in payload.lines {
            let timecode = line.tStart.map { "[\(Self.clock($0))] " } ?? ""
            let flags = lineFlags(line)
            let speaker = payload.speakerText(for: line)
            let lead = speaker.isEmpty ? "" : "**\(speaker)**\(flags)："
            rows.append("- \(timecode)\(lead)\(line.text)")
        }
        rows.append("")
        return rows.joined(separator: "\n")
    }

    private static func diarizationText(_ record: SessionRecord) -> String {
        switch record.diarization {
        case .active: "标出说话人"
        case .off: "不标出谁在说话"
        case .degraded: record.diarizationNote ?? "中途停了"
        case .unavailable: record.diarizationNote ?? "当前档位不支持"
        }
    }

    // MARK: - SRT

    private static func srt(_ payload: SessionExportPayload) -> String {
        var blocks: [String] = []
        var previousEnd: TimeInterval = 0
        for (index, line) in payload.lines.enumerated() {
            let start = line.tStart ?? previousEnd
            // 没有 `t_end` 的行（例如打字提问）给 2 秒：SRT 的时间段不能为零长度。
            var end = line.tEnd ?? (start + 2)
            // 合出来的尾不能盖住下一段的头：SRT 的同一时刻只能有一条字幕在屏上，
            // 否则播放器会两条叠着显示。有真实时间码的那一段永远优先。
            let nextStart = payload.lines.indices.contains(index + 1)
                ? payload.lines[index + 1].tStart
                : nil
            if let nextStart, nextStart > start, nextStart < end {
                end = nextStart
            }
            if end <= start { end = start + 0.5 }
            previousEnd = end
            let text = "\(payload.speakerPrefix(for: line))\(line.text)"
            blocks.append(
                """
                \(index + 1)
                \(srtTimecode(start)) --> \(srtTimecode(end))
                \(text)
                """
            )
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func srtTimecode(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int(((total - floor(total)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, min(millis, 999))
    }

    // MARK: - 纯文本 / JSON

    private static func plainText(_ payload: SessionExportPayload) -> String {
        let header = "\(payload.title)\n\(payload.record.kind.title) · \(payload.record.startedAt.formatted(date: .abbreviated, time: .shortened))\n"
        let body = payload.lines.map { line in
            let timecode = line.tStart.map { "[\(Self.clock($0))] " } ?? ""
            return "\(timecode)\(payload.speakerPrefix(for: line))\(line.text)"
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    private static func json(_ payload: SessionExportPayload) -> String {
        var root: [String: Any] = [
            "schema": "speechrail.session.export/1",
            "id": payload.record.id,
            "kind": payload.record.kind.rawValue,
            "title": payload.title,
            "state": payload.record.state.rawValue,
            "started_at": payload.record.startedAt.timeIntervalSince1970,
            "engine_profile": payload.record.engineProfile,
            "audio_source": payload.record.audioSource.rawValue,
            "diarization": payload.record.diarization.rawValue,
            "end_reason": payload.record.endedReason.rawValue,
            // 显示名单独给一份：正文里存的是匿名标签，改名不改正文。
            "speaker_names": payload.speakerNames,
            "lines": payload.lines.map { line -> [String: Any] in
                var item: [String: Any] = [
                    "ordinal": line.ordinal,
                    "role": line.role.rawValue,
                    "speaker_label": jsonText(line.speakerLabel),
                    "text": line.text,
                    "source": line.source.rawValue,
                    "status": line.status.rawValue,
                    "interrupted": line.isInterrupted,
                    "device_switch": line.isDeviceSwitch,
                    "starred": line.isStarred
                ]
                if let tStart = line.tStart { item["t_start"] = tStart }
                if let tEnd = line.tEnd { item["t_end"] = tEnd }
                if let quality = line.timingQuality { item["timing_quality"] = quality.rawValue }
                return item
            }
        ]
        if let endedAt = payload.record.endedAt {
            root["ended_at"] = endedAt.timeIntervalSince1970
        }
        if let voice = payload.record.voice {
            root["voice"] = ["id": voice.id, "name": jsonText(voice.name)]
        }
        if let persona = payload.record.persona {
            root["persona"] = ["id": persona.id, "title": persona.title]
        }
        if let minutes = payload.minutes {
            // MA-19：跨新库往返后版本、来源与行动身份不漂移。`id` 是版本身份，
            // `created_at` 供复核判断（修订晚于创建即需复核），缺一不可。
            root["minutes"] = [
                "id": minutes.id,
                "version": minutes.version,
                "status": minutes.status.rawValue,
                "body": jsonText(minutes.body),
                "created_at": minutes.createdAt.timeIntervalSince1970
            ]
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}\n"
        }
        return text + "\n"
    }

    // MARK: - 小工具

    /// JSON 里的 `null`。不能直接写 `text ?? NSNull()`：`??` 要求两侧同型，
    /// `String` 与 `NSNull` 合不到一起，编译不过。
    private static func jsonText(_ text: String?) -> Any {
        text ?? NSNull()
    }

    /// 转录列表里的 `[mm:ss]`（与页面上显示的一致）。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func lineFlags(_ line: TranscriptLine) -> String {
        var flags: [String] = []
        if line.isInterrupted { flags.append("被打断") }
        if line.isDeviceSwitch { flags.append("换了设备") }
        if line.isStarred { flags.append("星标") }
        return flags.isEmpty ? "" : "（\(flags.joined(separator: " · "))）"
    }
}

// MARK: - 系统保存面板

#if canImport(AppKit)
/// 导出走系统保存面板（§6.2 第三条判断：不做自绘下拉里的伪保存）。
@MainActor
public enum SessionExportPanel {
    /// 返回是否真的写了文件；用户取消返回 `false`。
    @discardableResult
    public static func write(_ payload: SessionExportPayload, as format: SessionExportFormat) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SessionExporter.suggestedFileName(payload, as: format)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let text = SessionExporter.export(payload, as: format)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            // 写失败要说清是哪一步失败：磁盘满、目标只读、文件名非法，处理方式不一样。
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "导出失败"
            alert.informativeText = "没能写入「\(url.lastPathComponent)」。\(error.localizedDescription)"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return false
        }
    }
}
#endif

// MARK: - 知识归档包读写（MA-19 / MC-66、MC-71）
//
// 这一层只做文件与编解码，**不碰记录库**：读库在 `SessionStore` 侧，
// 落盘与校验在这里。分开是为了让"包里有什么"这件事能被单独测——
// 攻击面（路径穿越、超大包、断引用）全在这一层，不必先造一个库。
public enum KnowledgeArchiveFileIO {
    /// 导入上限。做成可传入的值，是为了让"超大包被拒"这条能被测到：
    /// 真造一个 64 MiB 的包来测，既慢又不必要。
    public struct Limits: Sendable {
        /// 单文件上限。一份会议纪要正常是几十 KB；64 MiB 已经大到不像人了写的。
        public var maxFileBytes: Int
        /// 整个包的上限。三份文件加起来超了就是异常，不做逐个解压再累加。
        public var maxPackageBytes: Int
        /// 标识长度上限。库内 id 都是 UUID 或短前缀，超过这个长度就不是本 App 写的。
        public var maxIdentifierLength: Int

        public init(
            maxFileBytes: Int = 64 * 1024 * 1024,
            maxPackageBytes: Int = 96 * 1024 * 1024,
            maxIdentifierLength: Int = 200
        ) {
            self.maxFileBytes = maxFileBytes
            self.maxPackageBytes = maxPackageBytes
            self.maxIdentifierLength = maxIdentifierLength
        }

        public static let standard = Limits()
    }

    public static let allowedFileNames: Set<String> = [
        KnowledgeArchiveManifest.manifestFileName,
        KnowledgeArchiveManifest.markdownFileName,
        KnowledgeArchiveManifest.structuredFileName
    ]

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 写一个包。**先写暂存目录再改名**：中途崩了不会留下半个包被当成能导入的东西。
    ///
    /// 目标已存在直接失败——覆盖一份用户可能还留着、或者已经分享出去的包，
    /// 比导出失败更糟（MA-19 回退条款）。
    @discardableResult
    public static func write(
        manifest: KnowledgeArchiveManifest,
        payload: KnowledgeArchivePayload,
        markdown: String,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = directory.appendingPathComponent(
            packageName(for: manifest),
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw KnowledgeArchiveError.destinationExists(destination.lastPathComponent)
        }
        let staging = directory.appendingPathComponent(".\(packageName(for: manifest)).staging", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let structuredData = try encoder().encode(payload)
        let markdownData = Data(markdown.utf8)
        // 文件大小由写盘这一层实测填进清单：清单自己写一个数不算证据。
        // 清单本身不在 `files` 里——它写自己时还不知道自己多大。
        var manifest = manifest
        manifest.files = [
            KnowledgeArchiveFile(name: KnowledgeArchiveManifest.markdownFileName, byteCount: markdownData.count),
            KnowledgeArchiveFile(name: KnowledgeArchiveManifest.structuredFileName, byteCount: structuredData.count)
        ]
        let manifestData = try encoder().encode(manifest)
        try structuredData.write(to: staging.appendingPathComponent(KnowledgeArchiveManifest.structuredFileName))
        try manifestData.write(to: staging.appendingPathComponent(KnowledgeArchiveManifest.manifestFileName))
        try markdownData.write(to: staging.appendingPathComponent(KnowledgeArchiveManifest.markdownFileName))

        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw KnowledgeArchiveError.readFailed("归档包发布失败：\(error.localizedDescription)")
        }
        return destination
    }

    /// 包名从文档标题与版本号来。**不放 UUID**：用户在 Finder 里认这个包靠的是
    /// "哪场会的第几版"，不是一串随机字符。
    public static func packageName(for manifest: KnowledgeArchiveManifest) -> String {
        let raw = manifest.documentTitle ?? manifest.documentID
        let stem = sanitize(raw).isEmpty ? "meeting" : sanitize(raw)
        return "\(stem)-v\(manifest.selectedVersion).\(KnowledgeArchiveManifest.directoryExtension)"
    }

    private static func sanitize(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(48))
    }

    /// 读一个包并做完所有校验。**只读，不写任何地方**。
    ///
    /// 校验顺序是有意的：先看目录里有什么（路径穿越、符号链接、未知条目），
    /// 再看大小，然后才解 JSON。反过来就是先让不可信内容进内存再问安不安全。
    public static func readPackage(
        at url: URL,
        fileManager: FileManager = .default,
        limits: Limits = .standard
    ) throws -> KnowledgeArchivePackageRead {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw KnowledgeArchiveError.malformedPackage("不是一个目录")
        }
        let entries = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var totalBytes = 0
        var files: [String: URL] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            // 目录名本身由写入方决定，读取方不接受"../.." 这种名字。
            guard !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else {
                throw KnowledgeArchiveError.entryRejected(name)
            }
            guard allowedFileNames.contains(name) else {
                throw KnowledgeArchiveError.entryRejected(name)
            }
            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true {
                throw KnowledgeArchiveError.entryRejected("\(name)（符号链接）")
            }
            let size = values?.fileSize ?? 0
            guard size <= limits.maxFileBytes else {
                throw KnowledgeArchiveError.payloadTooLarge(size)
            }
            totalBytes += size
            guard totalBytes <= limits.maxPackageBytes else {
                throw KnowledgeArchiveError.payloadTooLarge(totalBytes)
            }
            files[name] = entry
        }
        guard let manifestURL = files[KnowledgeArchiveManifest.manifestFileName],
              let structuredURL = files[KnowledgeArchiveManifest.structuredFileName] else {
            throw KnowledgeArchiveError.malformedPackage("缺 manifest.json 或 structured.json")
        }
        guard let markdownURL = files[KnowledgeArchiveManifest.markdownFileName] else {
            throw KnowledgeArchiveError.malformedPackage("缺 minutes.md")
        }

        let manifest: KnowledgeArchiveManifest
        let payload: KnowledgeArchivePayload
        do {
            manifest = try decoder().decode(
                KnowledgeArchiveManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            payload = try decoder().decode(
                KnowledgeArchivePayload.self,
                from: Data(contentsOf: structuredURL)
            )
        } catch let error as KnowledgeArchiveError {
            throw error
        } catch {
            throw KnowledgeArchiveError.malformedPackage(error.localizedDescription)
        }
        guard manifest.schema == KnowledgeArchiveManifest.schemaID else {
            throw KnowledgeArchiveError.malformedPackage("schema 不认识：\(manifest.schema)")
        }
        guard payload.schema == KnowledgeArchivePayload.schemaID else {
            // v2 包缺正文出处（body_origin）与改稿血缘（parent_minutes_id），
            // 按默认导入会把用户写的正文标成 AI 整理——所以宁可拒掉，也不猜。
            // 用户侧动作只有一句话：用新版重新导出一次。
            if payload.schema == "speechrail.meeting.knowledge-archive.payload/2" {
                throw KnowledgeArchiveError.malformedPackage(
                    "这个包是旧格式（payload/2），缺正文出处与改稿血缘，直接导入会把你写过的正文标成 AI 整理。请用新版重新导出一次再导入"
                )
            }
            throw KnowledgeArchiveError.malformedPackage("载荷 schema 不认识：\(payload.schema)")
        }

        // 清单说的字节数与实际文件对不上：包被截断或被改过，两种都不该当可用包。
        let actual: [String: Int] = [
            KnowledgeArchiveManifest.markdownFileName: (try? markdownURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0,
            KnowledgeArchiveManifest.structuredFileName: structuredDataSize(structuredURL)
        ]
        for file in manifest.files {
            guard let size = actual[file.name], size == file.byteCount else {
                throw KnowledgeArchiveError.malformedPackage("\(file.name) 的实际大小与清单不符")
            }
        }

        let markdown = (try? String(contentsOf: markdownURL, encoding: .utf8)) ?? ""
        try validate(payload, limits: limits)
        return KnowledgeArchivePackageRead(manifest: manifest, payload: payload, markdown: markdown)
    }

    private static func structuredDataSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// 包内一致性校验。**引用必须落在包里**：锚点指着包里没有的修订，
    /// 导入之后就是一个指不到东西的指针——那正是"看起来成功、实际不能用"。
    static func validate(_ payload: KnowledgeArchivePayload, limits: Limits = .standard) throws {
        var identifiers = [payload.document.id] + payload.minutes.map(\.id) + payload.lines.map(\.id)
            + payload.snapshots.map(\.id) + payload.revisions.map(\.id) + payload.items.map(\.id)
            + payload.items.flatMap { $0.anchors.map(\.id) } + payload.windows.map(\.id)
        if let sessionID = payload.session?.id { identifiers.append(sessionID) }
        for id in identifiers {
            try validateIdentifier(id, limits: limits)
        }

        let minutesIDs = Set(payload.minutes.map(\.id))
        let lineIDs = Set(payload.lines.map(\.id))
        let revisionIDs = Set(payload.revisions.map(\.id))
        let snapshotIDs = Set(payload.snapshots.map(\.id))
        let itemIDs = Set(payload.items.map(\.id))

        guard payload.document.sourceSessionID == payload.session?.id else {
            throw KnowledgeArchiveError.brokenReference("文档声明的来源会话与包里的会话对不上")
        }
        for line in payload.lines {
            guard line.sessionID == payload.session?.id else {
                throw KnowledgeArchiveError.brokenReference("行 \(line.id) 不属于包里的会话")
            }
        }
        for snapshot in payload.snapshots {
            guard snapshot.documentID == payload.document.id else {
                throw KnowledgeArchiveError.brokenReference("快照 \(snapshot.id) 不属于包里的文档")
            }
            for revisionID in snapshot.lineRevisionIDs where !revisionIDs.contains(revisionID) {
                throw KnowledgeArchiveError.brokenReference("快照 \(snapshot.id) 引用了包里没有的行修订")
            }
        }
        for revision in payload.revisions {
            guard lineIDs.contains(revision.lineID) else {
                throw KnowledgeArchiveError.brokenReference("行修订 \(revision.id) 指向包里没有的行")
            }
        }
        for minutes in payload.minutes {
            guard minutes.sessionID == payload.session?.id else {
                throw KnowledgeArchiveError.brokenReference("纪要 \(minutes.id) 不属于包里的会话")
            }
            if let snapshotID = minutes.snapshotID, !snapshotIDs.contains(snapshotID) {
                throw KnowledgeArchiveError.brokenReference("纪要 \(minutes.id) 指向包里没有的来源快照")
            }
        }
        for item in payload.items {
            guard minutesIDs.contains(item.minutesID) else {
                throw KnowledgeArchiveError.brokenReference("结论条目 \(item.id) 指向包里没有的纪要版本")
            }
            for anchor in item.anchors {
                guard itemIDs.contains(anchor.itemID) else {
                    throw KnowledgeArchiveError.brokenReference("证据锚点 \(anchor.id) 指向包里没有的结论条目")
                }
                if let revisionID = anchor.revisionID, !revisionIDs.contains(revisionID) {
                    throw KnowledgeArchiveError.brokenReference("证据锚点 \(anchor.id) 指向包里没有的行修订")
                }
                if let lineID = anchor.lineID, !lineIDs.contains(lineID) {
                    throw KnowledgeArchiveError.brokenReference("证据锚点 \(anchor.id) 指向包里没有的转录行")
                }
                if let snapshotID = anchor.snapshotID, !snapshotIDs.contains(snapshotID) {
                    throw KnowledgeArchiveError.brokenReference("证据锚点 \(anchor.id) 指向包里没有的来源快照")
                }
            }
        }
        for window in payload.windows {
            guard minutesIDs.contains(window.minutesID) else {
                throw KnowledgeArchiveError.brokenReference("分窗记录 \(window.id) 指向包里没有的纪要版本")
            }
        }
    }

    static func validateIdentifier(_ id: String, limits: Limits = .standard) throws {
        guard !id.isEmpty else {
            throw KnowledgeArchiveError.invalidIdentifier("有对象没有 id")
        }
        guard id.count <= limits.maxIdentifierLength else {
            throw KnowledgeArchiveError.invalidIdentifier("id 过长")
        }
        guard !id.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw KnowledgeArchiveError.invalidIdentifier("id 含控制字符")
        }
    }
}

/// 读出来并已通过校验的包。
public struct KnowledgeArchivePackageRead: Sendable {
    public var manifest: KnowledgeArchiveManifest
    public var payload: KnowledgeArchivePayload
    public var markdown: String

    public init(manifest: KnowledgeArchiveManifest, payload: KnowledgeArchivePayload, markdown: String) {
        self.manifest = manifest
        self.payload = payload
        self.markdown = markdown
    }
}

// MARK: - 归档包里的可读纪要（MA-19 / MC-66）
//
// `minutes.md` 的要求只有一条：**脱离这个 App 也能读懂**。所以它不写
// 内部字段名、不写库 id 当标题之外的东西、不假设读者知道什么叫"覆盖账本"。
// 需要精确核对来源与状态的人去看 `structured.json`，那是给工具读的。
public enum KnowledgeArchiveMarkdown {
    public static func render(
        manifest: KnowledgeArchiveManifest,
        payload: KnowledgeArchivePayload
    ) -> String {
        var rows: [String] = []
        let title = manifest.documentTitle ?? payload.document.title ?? "会议纪要"
        rows.append("# \(title)")
        rows.append("")

        let selected = payload.minutes.first { $0.id == manifest.selectedMinutesID }
        rows.append("| 项 | 值 |")
        rows.append("|---|---|")
        rows.append("| 纪要版本 | 第 \(manifest.selectedVersion) 版\(adoptedSuffix(manifest)) |")
        if let occurredAt = payload.document.occurredAt {
            rows.append("| 会议时间 | \(stamp(occurredAt)) |")
        }
        if let createdAt = selected?.createdAt {
            rows.append("| 整理时间 | \(stamp(createdAt)) |")
        }
        rows.append("| 归档范围 | \(manifest.scope.title) |")
        rows.append("| 导出时间 | \(stamp(manifest.createdAt.timeIntervalSince1970)) |")
        rows.append("")

        let items = payload.items
            .filter { $0.minutesID == manifest.selectedMinutesID }
            .sorted { $0.sortOrder < $1.sortOrder }
        if !items.isEmpty {
            rows.append("## 结论与待办")
            rows.append("")
            let execution = Self.currentExecutionByKey(payload.execution)
            for item in items {
                rows.append(
                    "- \(kindTitle(item.kind))：\(item.text)\(verdictSuffix(item.verdict))"
                        + executionSuffix(execution[item.itemKey])
                )
                for anchor in item.anchors {
                    guard let quote = anchor.quote, !quote.isEmpty else { continue }
                    let time = anchor.startSeconds.map { " \(SessionExporter.clock($0))" } ?? ""
                    rows.append("  > \(quote.trimmingCharacters(in: .whitespacesAndNewlines))\(time)")
                }
            }
            rows.append("")
        }

        if let body = selected?.body, !body.isEmpty {
            rows.append("## 纪要正文")
            rows.append("")
            rows.append(body)
            rows.append("")
        }

        if !payload.lines.isEmpty {
            rows.append("## 引用的原句")
            rows.append("")
            for line in payload.lines.sorted(by: { $0.ordinal < $1.ordinal }) {
                let timecode = line.tStart.map { "[\(SessionExporter.clock($0))] " } ?? ""
                let speaker = speakerText(line, names: payload.speakerNames)
                let lead = speaker.isEmpty ? "" : "**\(speaker)**："
                rows.append("- \(timecode)\(lead)\(line.text)")
            }
            rows.append("")
        }

        rows.append("---")
        rows.append("")
        rows.append(
            "本纪要由 SpeechRail 在这台 Mac 上整理；原始音频不留存。"
                + "归档包里另有 `structured.json`，记录每一版结论依据的原句与状态。"
        )
        return rows.joined(separator: "\n") + "\n"
    }

    private static func adoptedSuffix(_ manifest: KnowledgeArchiveManifest) -> String {
        manifest.acceptedMinutesID == manifest.selectedMinutesID ? "（当前采用）" : ""
    }

    /// 每条 key 上**当前生效**的那条状态。
    ///
    /// 只认 `validTo == nil` 的：双时间日志里那些已失效的记录是历史，
    /// 把它们算成当前状态会让导出件显示一件早就改掉的事还挂着。
    public static func currentExecutionByKey(
        _ events: [ArchiveExecutionEvent]
    ) -> [String: ArchiveExecutionEvent] {
        var current: [String: ArchiveExecutionEvent] = [:]
        for event in events where event.validTo == nil {
            let existing = current[event.itemKey]
            if existing == nil
                || (event.validFrom, event.recordedAt) > (existing!.validFrom, existing!.recordedAt) {
                current[event.itemKey] = event
            }
        }
        return current
    }

    /// 执行状态的人话后缀。
    ///
    /// 不写会怎样：结构化 JSON 里有状态，`minutes.md` 里没有——
    /// 只看这份可读纪要的人会以为所有待办都还没做。**漏报和报错一样有害。**
    private static func executionSuffix(_ event: ArchiveExecutionEvent?) -> String {
        guard let event else { return "" }
        var parts: [String] = [statusTitle(event.status)]
        if let owner = event.ownerText, !owner.isEmpty { parts.append("负责人：\(owner)") }
        if let due = event.dueText, !due.isEmpty {
            parts.append("期限：\(due)")
        } else if let dueDate = event.dueDate {
            parts.append("期限：\(stamp(dueDate))")
        }
        return "（\(parts.joined(separator: " · "))）"
    }

    private static func statusTitle(_ status: String) -> String {
        ActionExecutionStatus(rawValue: status)?.title ?? status
    }

    private static func verdictSuffix(_ verdict: String?) -> String {
        guard let verdict else { return "" }
        switch verdict {
        case "supported": return "（已核对）"
        case "needsReview": return "（待核对）"
        case "rejected": return "（引用不成立，请复核）"
        default: return ""
        }
    }

    /// 条目种类沿用库里的 `minutes_item.kind` 取值（`overview` / `decision` /
    /// `action` / `open_question`）。这里只把它翻成人话，不另立一套名字。
    private static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "overview": "概述"
        case "decision": "结论"
        case "action": "待办"
        case "open_question": "待确认"
        default: "要点"
        }
    }

    private static func speakerText(_ line: ArchiveLine, names: [String: String]) -> String {
        guard let label = line.speakerLabel else { return "" }
        return names[label] ?? "说话人 \(label)"
    }

    private static func stamp(_ interval: TimeInterval) -> String {
        Date(timeIntervalSince1970: interval).formatted(date: .abbreviated, time: .shortened)
    }
}
