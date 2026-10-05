import Foundation
import SpeechRailAppSupport

/// Deterministic teleprompter replay runner.
///
/// It replays a recorded event manifest through the production follow adapter
/// and controller and writes a redacted aggregate report. It never records
/// audio, never downloads or switches a model, never touches the network, and
/// refuses to run without an explicit manifest that carries dataset and
/// version records.
private let usage = """
    teleprompter-replay — 提词器语音跟随确定性回放

    用法：
      teleprompter-replay --manifest <path> [--output <path>]
      teleprompter-replay --help

    参数：
      --manifest <path>  仓库外的回放素材 manifest（JSON）。必填；缺失或不合规时直接失败，
                         不会自动录音、不会猜测数据集版本。
      --output <path>    报告输出路径。默认打印到标准输出。

    素材要求（schema teleprompter.replay.v1）：
      dataset_revision / baseline_commit / candidate_commit / policy_revision 必填，
      segments 为冻结稿件，events 为按接收顺序记录的事件，labels 为人工标注的
      意图与阅读位置。

      labels[].intent 取值：\(TeleprompterReplayManifest.Intent.manifestValues.joined(separator: " / "))
      （区分大小写，按上面写法）。
      labels[].expected_segment_index 标的是**读者当时已经读到的段落**，不是系统
      确认到的段落：正常跟随时，把它挂在读者刚进入该段的那个事件上，系统在
      后续事件才追上来的那一段差值才计入跟随延迟。挂到系统已追上的那个事件
      会让延迟恒为 0，看起来「没有延迟」其实是没有样本。
      segment 0 是回放起点，系统一开始就在 0，因此第 0 段不会产生延迟样本。

    草稿约定：
      dataset_revision 以 -draft 结尾表示这份素材的标注**尚未经人工逐条确认**。
      素材工具默认加这个后缀，只有传 --confirm-reviewed 才去掉；手工改过 labels
      不会改这个字符串。回放器不拒绝草稿，但报告的 caveats 第一条会写明
      「本报告的数字不能作为质量结论」——**报告信的是这个后缀，不是你有没有
      真的看过**。

    输出（schema teleprompter.eval.v2）：仅聚合计数与版本信息，不含音频、完整正文或转写。
    新增聚合 unconfirmed_final_count（有假设后的空 final）、
    stable_prefix_contract_anomaly_count（稳定前缀契约异常）；输入仍为
    teleprompter.replay.v1。
    未运行的状态是 not_run，不会用 0 冒充没有错误。
    """

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("teleprompter-replay: " + message + "\n").utf8))
    exit(2)
}

/// Foundation's `localizedDescription` for a decoding failure is the same
/// sentence for every malformed manifest, so a typo in one field gives the
/// caller nothing to act on. Name the field and, for the enumerated intents,
/// the accepted values.
private func describeDecodingFailure(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else {
        return error.localizedDescription
    }
    let context: DecodingError.Context? = switch decodingError {
    case let .keyNotFound(_, context),
         let .typeMismatch(_, context),
         let .valueNotFound(_, context),
         let .dataCorrupted(context):
        context
    @unknown default:
        nil
    }
    guard let context else { return error.localizedDescription }
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    let location = path.isEmpty ? "manifest 顶层" : "字段 \(path)"
    var description = "\(location)：\(context.debugDescription)"
    if path.hasSuffix("intent") {
        let accepted = TeleprompterReplayManifest.Intent.manifestValues
            .joined(separator: " / ")
        description += "（接受的取值：\(accepted)）"
    }
    return description
}

private func parseArguments(_ arguments: [String]) throws -> (manifest: URL, output: URL?) {
    var manifest: URL?
    var output: URL?
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--manifest":
            index += 1
            guard index < arguments.count else { fail("--manifest 需要一个路径") }
            manifest = URL(fileURLWithPath: arguments[index])
        case "--output":
            index += 1
            guard index < arguments.count else { fail("--output 需要一个路径") }
            output = URL(fileURLWithPath: arguments[index])
        default:
            if arguments[index].hasPrefix("--manifest=") {
                manifest = URL(fileURLWithPath: String(arguments[index].dropFirst("--manifest=".count)))
            } else if arguments[index].hasPrefix("--output=") {
                output = URL(fileURLWithPath: String(arguments[index].dropFirst("--output=".count)))
            } else {
                fail("无法识别的参数 \(arguments[index])")
            }
        }
        index += 1
    }
    guard let manifest else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        fail("缺少 --manifest；本工具不会自行录音或推断数据集版本")
    }
    return (manifest, output)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let options = try parseArguments(arguments)
    let data: Data
    do {
        data = try Data(contentsOf: options.manifest)
    } catch {
        fail("读不到素材 manifest：\(error.localizedDescription)")
    }
    let manifest: TeleprompterReplayManifest
    do {
        manifest = try JSONDecoder().decode(TeleprompterReplayManifest.self, from: data)
    } catch {
        fail("素材 manifest 不是合法的 \(TeleprompterReplayManifest.schemaVersion)：\(describeDecodingFailure(error))")
    }
    let report: TeleprompterReplayEvaluator.Report
    do {
        report = try TeleprompterReplayEvaluator.evaluate(manifest)
    } catch {
        fail("回放被拒绝：\(error)")
    }
    let encoded = try JSONSerialization.data(
        withJSONObject: report.jsonObject,
        options: [.prettyPrinted, .sortedKeys]
    )
    if let output = options.output {
        try encoded.write(to: output)
    } else {
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    fail("\(error)")
}
