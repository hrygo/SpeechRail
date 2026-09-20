import Foundation

/// 开发者文档的**内容**。这是一份应用内的接入说明，不是契约的副本：
/// 每条事实都对着仓库里的契约写（`contracts/openapi.yaml`、`contracts/realtime-openai.md`、
/// `docs/users/`），并且只写「客户端需要知道的」——服务端内部的 worker、队列与调度不在这里
/// （REDESIGN-SPEC §13.3）。
struct DeveloperDocTopic: Identifiable, Equatable, Sendable {
    struct Endpoint: Equatable, Sendable {
        let method: String
        let path: String
        let detail: String
    }

    enum Block: Equatable, Sendable {
        case paragraph(String)
        case bullets([String])
        case code(language: String, lines: [String])
        case endpoints([Endpoint])
        case note(String)
    }

    let id: String
    let title: String
    let summary: String
    /// SF Symbol；与 Figma 稿里 `DOC_TOPICS` 的 lucide 图标一一对应。
    let systemImage: String
    let blocks: [Block]
}

enum DeveloperDocsCatalog {
    /// 服务地址的事实来源：应用自己连的就是这个回环地址 + 端口。
    static let loopbackBaseURL = "http://127.0.0.1:8201"
    static let openAICompatBaseURL = "http://127.0.0.1:8201/v1"

    static let topics: [DeveloperDocTopic] = [
        DeveloperDocTopic(
            id: "quickstart",
            title: "快速开始",
            summary: "改 base_url 就能用的最小示例",
            systemImage: "play.circle",
            blocks: [
                .paragraph(
                    "服务默认只监听回环地址，端口 8201；任何 OpenAI 兼容客户端把 base_url "
                    + "指到 http://127.0.0.1:8201/v1 即可接入，不需要改模型名，"
                    + "也不需要感知 worker 的加载、换档或回收。"
                ),
                .code(language: "Python · OpenAI SDK", lines: [
                    "from openai import OpenAI",
                    "",
                    "client = OpenAI(base_url=\"http://127.0.0.1:8201/v1\",",
                    "                api_key=\"not-needed-for-loopback\")",
                    "",
                    "with open(\"meeting.wav\", \"rb\") as audio:",
                    "    print(client.audio.transcriptions.create(",
                    "        model=\"whisper-1\", file=audio).text)"
                ]),
                .code(language: "curl · 语音合成", lines: [
                    "curl -sS http://127.0.0.1:8201/v1/audio/speech \\",
                    "  -H 'Content-Type: application/json' \\",
                    "  -d '{\"model\":\"tts-1\",\"voice\":\"serena\",",
                    "       \"input\":\"你好，这里是 SpeechRail。\"}' \\",
                    "  -o hello.mp3"
                ]),
                .note(
                    "调用前先读 GET /health 与 GET /readyz：/readyz 只表示 ASR 或 TTS 至少一个可用，"
                    + "要哪一项能力就查对应字段。"
                )
            ]
        ),
        DeveloperDocTopic(
            id: "endpoints",
            title: "接口一览",
            summary: "REST 与 WebSocket 的入口与用途",
            systemImage: "server.rack",
            blocks: [
                .endpoints([
                    .init(method: "GET", path: "/health", detail: "服务、档位与各项能力的就绪状态"),
                    .init(method: "GET", path: "/readyz", detail: "ASR 或 TTS 至少一个可用时的 200"),
                    .init(method: "GET", path: "/metrics", detail: "Prometheus 文本指标，本机采集用"),
                    .init(method: "GET", path: "/v1/models", detail: "模型与 supports_preview / clone / instruction 声明"),
                    .init(method: "GET", path: "/v1/speechrail/capabilities", detail: "一次 effective_capabilities_v1 原子能力快照；只读，不启动 worker"),
                    .init(method: "GET", path: "/v1/speechrail/voices", detail: "不含来源正文的安全音色发现列表"),
                    .init(method: "GET", path: "/v1/speechrail/voices/{voice_id}", detail: "按 canonical ID 或 alias 读取安全音色发现详情"),
                    .init(method: "POST", path: "/v1/audio/transcriptions", detail: "上传音频取文本，可选词级时间戳与匿名分人"),
                    .init(method: "POST", path: "/v1/audio/speech", detail: "文本合成音频：mp3 / opus / aac / flac / wav / pcm"),
                    .init(method: "GET", path: "/v1/voices", detail: "系统音色与已保存的自定义音色"),
                    .init(method: "POST", path: "/v1/voices/previews", detail: "按描述即时试听，不保存（quality）"),
                    .init(method: "POST", path: "/v1/voices/designs", detail: "生成参考并注册音色（quality）"),
                    .init(method: "POST", path: "/v1/voices/clone", detail: "用参考录音注册音色（quality）"),
                    .init(method: "GET", path: "/v1/voices/clone/prompts", detail: "官方提词稿列表"),
                    .init(method: "POST", path: "/v1/voices/clone/validate", detail: "只跑质量门，不创建档案"),
                    .init(method: "PATCH", path: "/v1/voices/{voice_id}", detail: "改名称；instruction 音色还能改描述与 seed"),
                    .init(method: "DELETE", path: "/v1/voices/{voice_id}", detail: "删除自定义音色，系统音色受保护"),
                    .init(method: "POST", path: "/v1/voices/{voice_id}/quality-runs", detail: "对已有音色跑输出质量探针"),
                    .init(method: "WS", path: "/v1/realtime", detail: "全双工流式识别与合成（唯一 WebSocket）")
                ]),
                .note(
                    "可选的 owner-scoped /v1/jobs（含 /{job_id}/result）只在服务开启作业队列时存在，"
                    + "普通客户端用上面的同步接口就够。/v1/models 与 /v1/voices 仍是兼容投影；"
                    + "需要跨对象同代一致性时使用 /v1/speechrail/capabilities，不要拼接多次读取。"
                )
            ]
        ),
        DeveloperDocTopic(
            id: "realtime",
            title: "实时语音",
            summary: "全双工流式 ASR/TTS 的协议子集",
            systemImage: "waveform.path.ecg",
            blocks: [
                .paragraph(
                    "/v1/realtime 只实现 OpenAI Realtime 的识别与合成子集，外加一个命名空间化的"
                    + "分人开关。它不承载 LLM 回复、tool call、播放与会议策略——那些属于调用方。"
                ),
                .bullets([
                    "会话配置、音频追加与提交沿用 Realtime 的消息名；服务端用 Server VAD 判定语音起止。",
                    "识别结果按转写事件返回；合成按音频增量事件返回，客户端自己负责播放与打断。",
                    "分人能力按档位发布，只输出会话级匿名标签，不提供实名或跨会话身份。",
                    "能力未就绪时服务端在会话开始时给出稳定错误码，而不是静默丢帧。"
                ]),
                .note("完整消息表与字段语义见仓库里的 contracts/realtime-openai.md。")
            ]
        ),
        DeveloperDocTopic(
            id: "voices",
            title: "音色与克隆",
            summary: "系统音色、声音设计、参考录音注册",
            systemImage: "waveform.badge.plus",
            blocks: [
                .paragraph(
                    "/v1/voices 把音色分成三类：system（内置）、instruction（按描述生成）与 "
                    + "clone（参考音频复刻）。后两类都以 VoiceProfile 返回，带 mode 与 quality 报告。"
                ),
                .bullets([
                    "系统音色用 canonical 名称或 OpenAI 标准别名调用；客户端应选 available=true 的那条。",
                    "声音设计（/v1/voices/designs）让服务端生成参考音频并注册，需要 quality 档。",
                    "参考录音注册（/v1/voices/clone）接受 2–45 秒、不超过 15 MB 的音频，"
                    + "服务端统一转码成 24 kHz 单声道参考。",
                    "ref_text 必须是用户实际朗读的内容：服务端用它核对参考音频，匹配不上不会注册。",
                    "quality.status 为 warn 时音色仍会创建并如实返回；reject 时以 voice_quality_reject 拒绝。"
                ]),
                .code(language: "curl · 参考录音注册", lines: [
                    "curl -sS http://127.0.0.1:8201/v1/voices/clone \\",
                    "  -H 'Idempotency-Key: 8f2c…' \\",
                    "  -F audio=@reference.wav \\",
                    "  -F ref_text=\"白日依山尽，黄河入海流。\" \\",
                    "  -F name=\"我的声音\""
                ]),
                .note(
                    "响应丢失时用同一个 Idempotency-Key 与同一个 id 重试：服务端认得这是同一次注册，"
                    + "不会建出第二个音色。"
                )
            ]
        ),
        DeveloperDocTopic(
            id: "profiles",
            title: "分档能力对照",
            summary: "light / balanced / quality 的差异",
            systemImage: "slider.horizontal.3",
            blocks: [
                .bullets([
                    "light：只有识别与合成，没有 aligner，也没有分人。",
                    "balanced：aligner-q8，可匿名分人。",
                    "quality：aligner-bf16，可匿名分人；语音设计与参考录音复刻只在这一档发布。"
                ]),
                .paragraph(
                    "档位改变的是服务端发布的能力，不是客户端接口形状：三个档位共用同一套 REST 与 "
                    + "WebSocket 契约，普通 UI 按 /v1/models 的 capabilities 决定展示哪些入口；"
                    + "需要一次同代、可缓存的完整发现结果时读取 /v1/speechrail/capabilities，"
                    + "其 schema_version 固定为 effective_capabilities_v1。"
                ),
                .note(
                    "词级时间戳由识别模型原生提供，不依赖 aligner；分人运行时只输出 session 级匿名标签，"
                    + "不管理实名与声纹库。"
                )
            ]
        ),
        DeveloperDocTopic(
            id: "mcp",
            title: "MCP 接入",
            summary: "给 Agent 的 stdio 与 streamable-http",
            systemImage: "shippingbox",
            blocks: [
                .paragraph(
                    "speechrail-mcp 是一个无状态 REST 代理：它不导入服务应用、不加载模型，"
                    + "只是把本机服务的能力以工具形式交给 Agent。"
                ),
                .code(language: "Codex · ~/.codex/config.toml", lines: [
                    "[mcp_servers.speechrail]",
                    "command = \"~/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail-mcp\"",
                    "env = { SPEECHRAIL_BASE_URL = \"http://127.0.0.1:8201/v1\" }"
                ]),
                .bullets([
                    "stdio 是默认传输，不监听任何端口；streamable-http 用 --transport streamable-http "
                    + "--host 127.0.0.1 --port 8202 启动，供同机客户端连接 http://127.0.0.1:8202/mcp。",
                    "describe() 保留 legacy models/voices/readiness 字段，同时尽力附带一次 "
                    + "effective_capabilities_v1；旧服务只有在 404/405 或未知 schema 时才回退为空。",
                    "Realtime 不经代理：流式会话仍直接连 /v1/realtime。"
                ]),
                .note(
                    "远程或 Web 端 Agent 不能直连回环地址，需要用受信任的 HTTPS 隧道把 "
                    + "streamable-http 暴露出去；配置细节见 docs/users/mcp-agent-integration.md。"
                )
            ]
        ),
        DeveloperDocTopic(
            id: "errors",
            title: "错误与排查",
            summary: "统一错误信封与常见码的下一步",
            systemImage: "exclamationmark.triangle",
            blocks: [
                .paragraph("所有错误都是同一个信封，并且一定带 request_id："),
                .code(language: "JSON", lines: [
                    "{",
                    "  \"error\": {",
                    "    \"message\": \"TTS is not configured\",",
                    "    \"type\": \"server_error\",",
                    "    \"code\": \"backend_not_ready\",",
                    "    \"request_id\": \"req_01J…\",",
                    "    \"retryable\": true",
                    "  }",
                    "}"
                ]),
                .bullets([
                    "backend_not_ready：先看 /readyz 与模型页，模型没准备好时不要重试风暴。",
                    "backend_busy / queue_full：服务按 retryable 与 Retry-After 提示退避重试。",
                    "voice_cloning_unsupported：当前档位不发布复刻能力，切到 quality 再试。",
                    "audio_too_short / audio_too_long：参考音频要在 2–45 秒之间。",
                    "voice_quality_reject：参考音频没过质量门（噪声、削波或内容不匹配），重新录一段。",
                    "invalid_api_key：非回环部署时 Authorization: Bearer 没配对，检查服务配置。"
                ]),
                .note("诊断页可以复制一份脱敏现场：档位、worker 状态、错误码与 request_id，不含路径与音频。")
            ]
        ),
        DeveloperDocTopic(
            id: "security",
            title: "安全与部署",
            summary: "回环默认、密钥与日志脱敏",
            systemImage: "checkmark.shield",
            blocks: [
                .bullets([
                    "默认只绑定回环；要暴露给其他主机必须配置 SPEECHRAIL_API_KEY 并改用 Bearer 鉴权，"
                    + "密钥不能放在 URL query 里。",
                    "请求路径不会下载模型、不会读取远程音频 URL，也不会静默访问网络。",
                    "日志与诊断报告不含密钥、Authorization、原始音频、Base64、完整转写与绝对模型路径。",
                    "一次只运行一个服务与一个 ASGI worker：吞吐靠模型本身，不靠复制进程。"
                ]),
                .paragraph(
                    "音频、模型、私有配置与 benchmark 原始制品都在仓库之外；应用侧只保存用户的作品与音色档案。"
                )
            ]
        )
    ]
}
