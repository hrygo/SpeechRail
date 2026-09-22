import Foundation
import SpeechRailControlKit

// 本机服务的凭据。**REST 与 WebSocket 共用这一份解析**：`/v1/realtime` 的握手在配置了
// key 时必须带 `Authorization: Bearer`，否则以 1008 关闭（`contracts/realtime-openai.md`
// 的「连接与认证」）。两处各读一次环境变量就会漂移，所以它单独成一个文件。
//
// 它**只解析、不落盘、不打印**：key 只活在内存里，传到请求头为止。

/// 本机服务的凭据解析：受管 app home 的 `config/.env` 优先，环境变量只作为
/// 没有受管配置时的 fallback。这样 GUI 进程不会把启动它的旧环境变量误当成当前服务 key。
///
/// 它不是 REST 客户端私有的：`/v1/realtime` 的 WebSocket 握手用**同一个 key**
/// （契约：配置 key 时握手必须携带 `Authorization: Bearer`，否则以 1008 关闭），
/// 所以这一处必须是两边共用的一份解析。
enum SpeechRailAPICredentialProvider {
    private static let apiKeyName = "SPEECHRAIL_API_KEY"
    private static let appHomeName = "SPEECHRAIL_APP_HOME"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let appHome = managedAppHome(environment: environment)
        let managedKey = readEnvFile(
            at: appHome
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent(".env")
        )
        return ServiceCredentialPolicy.preferredKey(
            environmentKey: environment[apiKeyName].flatMap(validated),
            managedKey: managedKey
        )
    }

    private static func managedAppHome(environment: [String: String]) -> URL {
        if let configured = environment[appHomeName]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("SpeechRail", isDirectory: true)
    }

    private static func readEnvFile(at url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard name == apiKeyName else { continue }
            return parseValue(String(line[line.index(after: separator)...]))
        }
        return nil
    }

    private static func parseValue(_ value: String) -> String? {
        var parsed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = parsed.first, first == "'" || first == "\"" {
            let start = parsed.index(after: parsed.startIndex)
            if let closing = parsed[start...].firstIndex(of: first) {
                let suffix = parsed[parsed.index(after: closing)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if suffix.isEmpty || suffix.hasPrefix("#") {
                    parsed = String(parsed[start..<closing])
                }
            }
        } else if let comment = parsed.range(of: " #") {
            parsed = String(parsed[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return validated(parsed)
    }

    private static func validated(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\r"), !trimmed.contains("\n") else {
            return nil
        }
        return trimmed
    }
}
