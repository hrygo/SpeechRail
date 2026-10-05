import Foundation

/// 会前/会中的来源呈现门面（MA-10 / MC-01、MC-03、MC-04、MC-16、MC-74）。
///
/// 采集层知道的是 `phase` / `isPaused` / `isMicrophoneMuted` / `Selection`，
/// 用户需要知道的是"现在到底在录什么"。这两者之间的翻译全部收在这里，
/// 因为它有一条硬规矩：**界面说不出没有的事**。
///
/// 具体是这四条：
/// - 用户只勾了某个 App 的系统声音，就**不许提麦克风**——提了等于谎报采集范围（MC-03）；
/// - **电平不是识别，也不是已保存**。电平只说明"此刻有声音进来"（MC-74）；
/// - **静音麦克风 / 暂停全部 / 恢复是三件事**，合成一句"已暂停"会让用户
///   不知道自己停掉的是哪一路（MC-16）；
/// - 没开始就说没开始，不给"准备中"这种含糊说法（MC-01）。
struct MeetingSourcePresentation: Hashable, Sendable {
    /// 此刻真实在采集的路数。
    enum Capture: Hashable, Sendable {
        case notStarted
        case pausedAll
        case microphoneMuted
        case live
    }

    var capture: Capture
    /// 用户当时勾选的来源。暂停或静音**不改变它**——用户的选择要如实保留。
    var selection: Selection
    /// 识别连上了吗。**与采集是两回事**：采集在跑不等于在识别。
    var isRecognizing: Bool
    /// 落库确认过几行。**与电平也是两回事**：有电平不等于存下来了。
    var savedLineCount: Int

    /// 用户勾选的来源。**纯值**：呈现门面不持有采集层对象，
    /// 所以它能在没有 AppKit / AVFoundation 的测试环境里验。
    struct Selection: Hashable, Sendable {
        var usesMicrophone: Bool
        var systemAppNames: [String]

        init(usesMicrophone: Bool = true, systemAppNames: [String] = []) {
            self.usesMicrophone = usesMicrophone
            self.systemAppNames = systemAppNames
        }

        var isEmpty: Bool { !usesMicrophone && systemAppNames.isEmpty }
    }

    var isMicrophoneSelected: Bool { selection.usesMicrophone }
    var systemAppCount: Int { selection.systemAppNames.count }

    /// 一句话状态。**先说真实在录什么，再说别的**。
    var title: String {
        switch capture {
        case .notStarted: "还没开始"
        case .pausedAll: "已暂停全部"
        case .microphoneMuted where isMicrophoneSelected: "正在录音 · 麦克风已静音"
        case .microphoneMuted: "正在录音 · 只在录系统声音"
        case .live: "正在录音"
        }
    }

    /// 来源摘要。**只列真实在录的路**。
    var sourceSummary: String {
        guard capture != .notStarted else { return "尚未选择采集来源" }
        if capture == .pausedAll { return "当前没有在录：\(selectionLabel)" }

        var parts: [String] = []
        if selection.usesMicrophone {
            parts.append(capture == .microphoneMuted ? "麦克风（已静音）" : "麦克风")
        }
        // 没勾麦克风时，摘要里**完全不出现"麦克风"三个字**（MC-03）。
        if systemAppCount == 1, let name = selection.systemAppNames.first {
            parts.append("\(name) 的系统声音")
        } else if systemAppCount > 1 {
            parts.append("\(systemAppCount) 个 App 的系统声音")
        }
        return parts.isEmpty ? "没有在录的来源" : "正在录：" + parts.joined(separator: " + ")
    }

    /// 电平条旁边的说明。**电平只是电平**（MC-74）。
    ///
    /// 把它说成"识别中"或"已保存"，用户就会以为声音已经变成文字了——
    /// 而实际上识别断了、或者一行都还没落库，都是可能的。
    var levelCaption: String {
        switch capture {
        case .notStarted: "还没有开始采集"
        case .pausedAll: "已暂停，看不到电平"
        case .microphoneMuted where !isMicrophoneSelected:
            "只录系统声音，电平不代表麦克风"
        case .microphoneMuted:
            "麦克风已静音，电平来自系统声音"
        case .live:
            isRecognizing ? "电平表示此刻有声音进来，不代表已经转成文字" : "电平表示此刻有声音进来"
        }
    }

    /// 状态带上的事实条目。**分开说，不合成一个词**。
    var facts: [String] {
        var result: [String] = []
        switch capture {
        case .notStarted:
            result.append("没有采集，也没有识别")
        case .pausedAll:
            result.append("麦克风和系统声音都停了")
            result.append("暂停前后的句子不会拼在一起")
        case .microphoneMuted:
            if isMicrophoneSelected { result.append("麦克风已静音，系统声音仍在录") }
            else { result.append("只录系统声音") }
        case .live:
            break
        }
        if isRecognizing {
            result.append("识别连接已建立")
        } else if capture != .notStarted {
            // 采集在跑但没识别：这是两件事，说清楚省得用户以为已经出文字了。
            result.append("识别还没连上，文字不会自己出现")
        }
        if savedLineCount > 0 {
            result.append("已存下 \(savedLineCount) 句")
        } else if capture == .live {
            result.append("还没有存下任何一句")
        }
        return result
    }

    /// 勾选来源的人话。与采集层的 `Selection.label` 同一套词，
    /// 但这里自己算一遍：呈现门面不持有采集层对象。
    var selectionLabel: String {
        var parts: [String] = []
        if isMicrophoneSelected { parts.append("麦克风") }
        if systemAppCount == 1, let name = selection.systemAppNames.first {
            parts.append(name)
        } else if systemAppCount > 1 {
            parts.append("\(systemAppCount) 个 App")
        }
        return parts.isEmpty ? "没有选择来源" : parts.joined(separator: " + ")
    }

    /// 用户此刻能做的事。**恢复不是"取消静音"**：暂停全部之后要恢复全部，
    /// 只取消麦克风静音不等于把系统声音也放回来。
    var primaryAction: (title: String, kind: Kind)? {
        switch capture {
        case .notStarted: ("开始会议", .start)
        case .pausedAll: ("恢复录音", .resume)
        case .microphoneMuted: ("取消麦克风静音", .unmuteMicrophone)
        case .live: ("暂停全部", .pauseAll)
        }
    }

    enum Kind: Hashable, Sendable {
        case start
        case resume
        case unmuteMicrophone
        case pauseAll
    }

    /// 开始前的检查没过时，输入与来源**原样保留**（MC-04）。
    /// 这份草稿就是重试要用的东西，重置它等于让用户重打一遍。
    struct RetryDraft: Equatable, Sendable {
        var title: String
        var notes: String
        var selection: Selection
    }

    /// 检查失败之后回到这里：内容不变，来源不变，只多一条说清卡在哪。
    static func retryDraft(
        previous: RetryDraft,
        failure: String
    ) -> (draft: RetryDraft, message: String) {
        (previous, failure)
    }
}
