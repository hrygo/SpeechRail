import Foundation
import SpeechRailAppSupport

/// VA-17b 语音助手确定性回放 runner：只读仓库外 manifest，输出脱敏聚合。
/// 不录音、不下载模型、不联网；缺失素材或版本记录时直接失败。
private let usage = """
    assistant-replay — 语音助手离线回放评估

    用法：
      assistant-replay --manifest <path> [--output <path>]
      assistant-replay --help

    参数：
      --manifest <path>  仓库外的回放素材 manifest（JSON，schema assistant.replay.v1）。必填。
      --output <path>    报告输出路径。默认打印到标准输出。

    素材要求：
      dataset_revision / baseline_commit / policy_revision 必填，
      events 为按接收顺序记录的回放事件（turn/播放/封存身份与交付状态）。
      仓库内仅 schema 与工具；素材路径/正文不进交付报告。

    输出（schema assistant.eval.v1）：仅聚合计数与版本信息，不含音频、完整正文或转写。
    未运行的状态是 not_run，不会用 0 冒充没有错误。
    """

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("assistant-replay: " + message + "\n").utf8))
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
    let manifest: AssistantReplayEvaluator.Manifest
    do {
        manifest = try JSONDecoder().decode(AssistantReplayEvaluator.Manifest.self, from: data)
    } catch {
        fail("素材 manifest 不是合法的 \(AssistantReplayEvaluator.schemaVersion)：\(error.localizedDescription)")
    }
    let report: AssistantReplayEvaluator.Report
    do {
        report = try AssistantReplayEvaluator.evaluate(manifest)
    } catch {
        fail("回放被拒绝：\(error)")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(report)
    if let output = options.output {
        try encoded.write(to: output)
    } else {
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    fail("\(error)")
}
