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
      意图（read / improvise / re_read / manual_jump）与阅读位置。

    输出（schema teleprompter.eval.v1）：仅聚合计数与版本信息，不含音频、完整正文或转写。
    未运行的状态是 not_run，不会用 0 冒充没有错误。
    """

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("teleprompter-replay: " + message + "\n").utf8))
    exit(2)
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
        fail("素材 manifest 不是合法的 \(TeleprompterReplayManifest.schemaVersion)：\(error.localizedDescription)")
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
