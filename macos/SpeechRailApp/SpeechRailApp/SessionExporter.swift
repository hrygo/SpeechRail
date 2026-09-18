import AppKit
import Foundation

// 记录库的导出物（`SESSIONS-SPEC` §6.2 的三条设计判断之三、§6.3.2 的页脚）。
//
// 两件事按规矩来：
//   1. **时间码从 `line.t_start / t_end` 取**（§6.5）。墙钟只用于列表排序与标题，
//      不进导出物——否则「换一次设备」或「续接一次」都会让字幕时间轴跳一下。
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
        rows.append("| 运行档位 | \(payload.record.engineProfile) |")
        rows.append("| 分人 | \(diarizationText(payload.record)) |")
        if let voice = payload.record.voice {
            rows.append("| 音色 | \(voice.name ?? voice.id) |")
        }
        if let persona = payload.record.persona {
            rows.append("| 人设 | \(persona.title) |")
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
        rows.append("## 转录")
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
        case .active: "已开启"
        case .off: "未开启"
        case .degraded: record.diarizationNote ?? "已降级"
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
            root["minutes"] = [
                "version": minutes.version,
                "status": minutes.status.rawValue,
                "body": jsonText(minutes.body)
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
