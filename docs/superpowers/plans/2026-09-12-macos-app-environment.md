# SpeechRail macOS App Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 SpeechRail 建立可签名、可测试、可直接分发的 macOS App 开发环境，并完成首版控制面骨架：App 可查看服务状态、启动/停止/重启服务、查看并切换 `light`/`balanced`/`quality` profile，同时不复制 SpeechRail runtime、worker 或模型。

**Architecture:** `SpeechRailApp` 是 SwiftUI 控制面；签名的 `SpeechRailControlAgent` 由 `SMAppService` 管理并通过受签名验证的 XPC 暴露有限命令；Agent 使用绝对路径调用现有 managed Python CLI；`com.speechrail` 仍是唯一的 ASR/TTS 服务 LaunchAgent 和生命周期所有者。UI 与服务端通过 loopback HTTP 读取公开状态，所有改变本机服务状态的操作经过 XPC Agent 串行执行。

**Tech Stack:** Xcode 26.6 stable, Swift 6.3, SwiftUI, Observation, XPC (`XPCSession`/`XPCPeerRequirement`), `SMAppService`, Hardened Runtime, Developer ID Application signing, notarization, Python 3.12, `uv`, existing SpeechRail service CLI, Swift Testing/XCTest.

**Spec:** `docs/superpowers/specs/2026-09-12-macos-app-environment-design.md`

## Global Constraints

- [ ] 保持 Python `>=3.12,<3.13`、`uv` 和现有 PEP 621 配置不变。
- [ ] 保持唯一的 `com.speechrail` 服务实例和唯一 ASGI worker；App/Agent 不启动第二个 worker，不复制模型进程。
- [ ] App 不采集麦克风、不播放音频、不读取远程音频 URL、不运行 LLM；不添加 microphone、network server 或不必要的 Sandbox entitlement。
- [ ] Agent 只允许固定命令和固定 profile enum，使用绝对 executable path 与 argument array，不经 shell，不接受任意 executable/argv。
- [ ] 默认使用 loopback 与现有 app home；UI test、集成测试和本地 smoke 使用临时 app home、端口与隔离 label，不能接触生产模型、`.env`、日志或 `com.speechrail`。
- [ ] 不在仓库写入 API key、Authorization、真实模型路径、私有 `.env`、原始音频、转写全文、日志或构建产物。
- [ ] Apple 平台行为以当前 Xcode SDK 编译与运行结果为准；文档建议、当前实测和推断在交付报告中分开说明。

---

## Task 1: 确认并安装本机 Apple 开发工具链

**Files:** 无仓库文件；只改变本机开发工具安装状态。

- [ ] 确认当前机器为 Apple Silicon、macOS 26.x，记录 Swift、`uv`、Python、`xcode-select` 和 SDK 现状。
- [ ] 通过 Apple 官方渠道安装 Xcode 26.6 stable；不安装 Xcode 27 RC，不引入第三方项目生成器作为构建前置依赖。
- [ ] 将 active developer directory 切换到 `/Applications/Xcode.app/Contents/Developer`，接受许可并确认 `xcodebuild -version`、`xcodebuild -showsdks`、`swift --version` 可用。
- [ ] 确认 `xcodebuild -runFirstLaunch` 已完成；确认可用 macOS SDK 至少为 26.5，并保留 macOS 14 deployment target 的编译能力。
- [ ] 检查本机是否存在 Developer ID signing identity；只记录 identity 数量、team identifier 是否可用和是否存在 notarization keychain profile，不输出证书名称、账号或 token。

**Verification:**

```bash
xcodebuild -version
xcodebuild -showsdks
swift --version
security find-identity -p codesigning -v
```

通过标准：full Xcode 可执行、macOS SDK 可发现、Swift 6.3 可用；签名身份缺失不阻塞本地开发，但会标为分发前置条件。

---

## Task 2: 建立 Xcode 工程、target 和构建配置

**Files:**

- `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`
- `macos/SpeechRailApp/SpeechRailApp/App.swift`
- `macos/SpeechRailApp/SpeechRailControlKit/`
- `macos/SpeechRailApp/SpeechRailControlAgent/`
- `macos/SpeechRailApp/SpeechRailAppTests/`
- `macos/SpeechRailApp/SpeechRailAppUITests/`
- `macos/SpeechRailApp/Config/Debug.xcconfig`
- `macos/SpeechRailApp/Config/Release.xcconfig`
- `macos/SpeechRailApp/Config/Distribution.xcconfig`
- `macos/SpeechRailApp/Entitlements/SpeechRailApp.entitlements`
- `macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist`
- `macos/SpeechRailApp/TestPlans/SpeechRailApp.xctestplan`

- [ ] 用 Xcode 原生工程创建 `SpeechRailApp`，并加入 `SpeechRailControlKit` framework、`SpeechRailControlAgent` executable、unit test target 和 UI test target。
- [ ] 使用 `com.speechrail.desktop` 作为 App bundle identifier，使用 `com.speechrail.desktop.control` 作为 Agent Mach service/LaunchAgent label；所有标识符集中在配置文件或构建设置中，代码不散落硬编码。
- [ ] 所有 target 设置 `MACOSX_DEPLOYMENT_TARGET = 14.0`、Apple Silicon `arm64`、Swift 6 language mode、严格并发检查；Debug/Release/Distribution 三套配置显式分离。
- [ ] App target 开启 Hardened Runtime；App Sandbox 保持关闭并在配置注释中说明这是 direct Developer ID distribution 的边界决定，不为 App Store 伪造兼容性。
- [ ] 不添加 microphone entitlement、`NSMicrophoneUsageDescription`、JIT、unsigned executable、DYLD/library validation 等例外；只有后续实测确有需要时才单独评审例外。
- [ ] 将 Agent executable 复制到 App `Contents/Resources/SpeechRailControlAgent`，将 `com.speechrail.desktop.control.plist` 复制到 `Contents/Library/LaunchAgents/`；plist 使用 `BundleProgram`，不使用旧式 `Program`。
- [ ] 将 Swift source、资源、测试计划和配置纳入工程；DerivedData、`.build`、`.swiftpm`、`xcuserdata`、archive、export 和 notarization 输出保持忽略。
- [ ] 在空白界面显示工具链状态和“尚未连接”状态，确保新工程可启动后再接入真实控制面。

**Verification:**

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp \
  -configuration Debug \
  -sdk macosx \
  build
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

通过标准：Debug build 成功，App bundle 含正确 Agent 和 helper plist，所有路径是 bundle-relative 或由构建设置注入的绝对路径。

---

## Task 3: 先以测试锁定 ControlKit 公共协议

**Files:**

- `macos/SpeechRailApp/SpeechRailControlKit/ControlTypes.swift`
- `macos/SpeechRailApp/SpeechRailControlKit/ControlErrors.swift`
- `macos/SpeechRailApp/SpeechRailControlKit/ControlTransport.swift`
- `macos/SpeechRailApp/SpeechRailAppTests/ControlKitTests.swift`

- [ ] 先写失败测试，覆盖 schema version、profile enum、command allow-list、request ID round-trip、稳定错误码和 operation snapshot 的 Codable round-trip。
- [ ] 定义 `Sendable`、`Codable` 的公共类型，协议形状固定如下：

```swift
public enum SpeechRailProfile: String, Codable, CaseIterable, Sendable {
    case quality
    case balanced
    case light
}

public enum ControlCommand: String, Codable, Sendable {
    case status
    case start
    case stop
    case restart
    case preflight
    case profileList
    case profileStatus
    case profileApply
    case profileRollback
    case operationStatus
    case operationCancel
}

public struct ControlRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let command: ControlCommand
    public let profile: SpeechRailProfile?
    public let confirmation: Bool
}

public enum ControlErrorCode: String, Codable, Sendable {
    case invalidRequest
    case unauthorizedPeer
    case backendBusy
    case operationInProgress
    case managedRuntimeMissing
    case commandFailed
    case serviceUnavailable
    case unsupported
}

public struct OperationSnapshot: Codable, Sendable {
    public let operationID: UUID
    public let command: ControlCommand
    public let state: OperationState
    public let errorCode: ControlErrorCode?
}

public protocol SpeechRailControlTransport: Sendable {
    func send(_ request: ControlRequest) async throws -> ControlResponse
}
```

- [ ] 为 `ServiceSnapshot`、`ProfileSummary`、`ProfileSnapshot` 和 `ControlResponse` 定义有限、可脱敏的数据结构；不允许 `Any`、原始 JSON 字符串或绝对模型路径进入 UI 协议。
- [ ] 将机器输出 schema version 固定为 `1`；未知 command、缺少 required profile、取消不可取消操作和旧 schema 都映射为稳定错误码。
- [ ] 运行测试使其由红转绿；再提取 JSON/XPC 传输共用的编码逻辑，保持协议与 transport 解耦。

**Verification:**

```bash
xcodebuild test -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp \
  -destination 'platform=macOS'
```

---

## Task 4: 为现有 Python CLI 增加兼容的机器输出

**Files:**

- `src/speechrail/cli.py`
- `tests/test_cli_machine_output.py`
- 必要时：`src/speechrail/service/profile_commands.py`、`tests/test_profile_commands.py`

- [ ] 先增加失败测试，锁定默认人类可读输出不变，`--json` 输出只含稳定字段、无 ANSI、无绝对路径、无 secret、无原始错误堆栈。
- [ ] 为 `service status/start/stop/restart/preflight` 和 `profile list/status/apply/rollback` 增加兼容的 `--json` 选项；默认调用方式与现有脚本完全兼容。
- [ ] 机器输出统一为：`schema_version`、`command`、`status`、必要的公开状态字段、`request_id`（如已有 request context）；失败时使用 `error_code` 和短 `message`。
- [ ] `profile apply` 继续要求 CLI 的 `--yes` 确认；机器输出明确区分 `accepted`、`running`、`committed`、`failed`，不把子进程退出码单独当成成功证据。
- [ ] 为 managed runtime 委托路径保留 `-I -m speechrail` 和现有 app home 语义；不通过 shell 拼接命令，不改变已有 launchd 生命周期所有权。
- [ ] 运行 Python 定向测试后，再运行既有 service/profile 测试，确认无破坏性公共变更。

**Verification:**

```bash
uv run --extra dev pytest tests/test_cli_machine_output.py tests/test_profile_commands.py
uv run --extra dev ruff check src/speechrail/cli.py tests/test_cli_machine_output.py
```

---

## Task 5: 实现 ControlAgent 的固定命令执行与串行 operation actor

**Files:**

- `macos/SpeechRailApp/SpeechRailControlAgent/AgentMain.swift`
- `macos/SpeechRailApp/SpeechRailControlAgent/AgentCommandRunner.swift`
- `macos/SpeechRailApp/SpeechRailControlAgent/AgentOperationStore.swift`
- `macos/SpeechRailApp/SpeechRailControlAgent/AgentRuntimeLocator.swift`
- `macos/SpeechRailApp/SpeechRailAppTests/AgentCommandRunnerTests.swift`
- `macos/SpeechRailApp/SpeechRailAppTests/AgentOperationStoreTests.swift`

- [ ] 先写 fake runner 测试：每个 enum command 生成预期的 argv；profile apply 缺少 profile/确认时拒绝；任意传入 executable、shell metacharacter 和仓库相对路径均不可进入执行器。
- [ ] 实现 `ManagedCommand` enum 和 `ManagedRuntimeLocator`，从显式 app home 计算 `runtime/current/.venv/bin/python`；不扫描无关目录，不从 PATH 猜测运行时。
- [ ] 实现基于 `Process` 的 runner，仅传入绝对 executable URL 和 `[String]` arguments；stdout/stderr 只保存在 operation 内存快照中，返回前按允许字段解析并清洗。
- [ ] 用 actor 实现 operation store：`status/start/stop/restart/preflight/profileList/profileStatus/profileRollback` 串行；`profileApply` 启动受控异步 operation；同一时刻第二个 mutation 返回 `operationInProgress`。
- [ ] 对 `operationCancel` 实现明确语义：只取消尚未提交的本地 process/等待；若现有 Python profile workflow 已进入不可回滚阶段，返回稳定 `unsupported` 或 `operationInProgress`，不伪造取消成功。
- [ ] Agent 启动时不主动加载模型；只在请求到达时委托现有 CLI。Agent 崩溃或退出不停止 `com.speechrail`，服务生命周期仍由现有 managed LaunchAgent 控制。
- [ ] 完成 Agent executable 入口和最小 graceful shutdown；不使用 fork、daemonize、`system()` 或长期后台子进程替代 XPC。

**Verification:**

```bash
xcodebuild test -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp \
  -only-testing:SpeechRailAppTests/AgentCommandRunnerTests \
  -only-testing:SpeechRailAppTests/AgentOperationStoreTests \
  -destination 'platform=macOS'
```

---

## Task 6: 接入受签名验证的 XPC 和 `SMAppService`

**Files:**

- `macos/SpeechRailApp/SpeechRailControlKit/XPCControlTransport.swift`
- `macos/SpeechRailApp/SpeechRailControlAgent/XPCControlService.swift`
- `macos/SpeechRailApp/SpeechRailControlAgent/XPCPeerPolicy.swift`
- `macos/SpeechRailApp/SpeechRailApp/ControlAgentRegistration.swift`
- `macos/SpeechRailApp/SpeechRailAppTests/XPCControlTests.swift`
- `macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist`

- [ ] 先用 fake/in-process transport 写客户端和 Agent handler 测试，验证 request ID、错误映射、单次响应、operation polling 和断开重连。
- [ ] 在编译可用的 macOS 14 API 范围内采用 `XPCSession` 与 `XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier:)`；若 SDK 实测 API 形状不同，只在该隔离层按 SDK 适配，不改变 ControlKit 协议。
- [ ] Agent listener 设置 same-team/signing-identifier peer requirement；拒绝未签名、错误 team 或错误 bundle signing identifier 的 peer，并返回 `unauthorizedPeer`，不执行命令。
- [ ] App 侧用 `SMAppService.agent(plistName:)` 注册、查询 `status`、注销 helper；注册/注销错误在 UI 显示可操作提示，引导用户查看 System Settings 的 Login Items & Extensions。
- [ ] App 首次控制操作前确保 helper 已注册；重复注册必须幂等。注销 helper 不停止现有 `com.speechrail` 服务，不删除 app home 或模型。
- [ ] 所有 XPC 入参在 Agent 边界重新校验，不信任 UI 已做过的 enum/confirmation 检查。
- [ ] 实测 bundle layout、Mach service、SMAppService status 与 helper 启停；不使用 `codesign --deep` 作为验证或签名方案。

**Verification:**

```bash
codesign --verify --strict --verbose=2 build/Release/SpeechRailApp.app
codesign --display --requirements :- build/Release/SpeechRailApp.app/Contents/Resources/SpeechRailControlAgent
plutil -lint build/Release/SpeechRailApp.app/Contents/Library/LaunchAgents/com.speechrail.desktop.control.plist
```

---

## Task 7: 构建 SwiftUI 控制面和隔离的 UI test seam

**Files:**

- `macos/SpeechRailApp/SpeechRailApp/App.swift`
- `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- `macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift`
- `macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift`
- `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift`
- `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`
- `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`
- `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

- [ ] 先写 UI test 断言：状态可见、profile 三档可见、启动/停止按钮存在、切换需要确认、运行中显示进度、错误显示稳定 message；测试以 launch argument `--ui-test` 启用。
- [ ] 使用 `@Observable` model 管理状态，明确 `idle/loading/running/succeeded/failed`，避免在 View 中直接启动 Process 或改变服务状态。
- [ ] 使用 `MenuBarExtra` 提供常驻菜单栏控制，并提供标准设置窗口；除非产品另行决定，不设置 `LSUIElement` 隐藏 Dock/窗口入口。
- [ ] App 通过 `URLSession` 仅读取测试或配置注入的 `http://127.0.0.1:$SPEECHRAIL_PORT/health`、`/readyz`、`/v1/models`、`/v1/voices`；不接受 UI 任意 URL。
- [ ] App 通过 XPC 发起 start/stop/restart/profile apply/rollback；profile apply 使用 polling 展示 operation 状态，禁止阻塞主线程。
- [ ] light/balanced/quality 的可用能力和说明来自 `profile list`/`profile status`，不在 UI 猜测 aligner、diarization 或 TTS 能力。
- [ ] 对 backend 未准备、`backend_busy`、runtime missing、helper disabled、权限拒绝、网络超时分别显示用户可理解的恢复动作；日志使用 `OSLog`，默认隐去 request ID 以外的敏感值。
- [ ] UI test 使用 fake transport 与临时 HTTP server seam；不注册真实 helper、不启动 `com.speechrail`、不访问真实模型。

**Verification:**

```bash
xcodebuild test -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp \
  -testPlan SpeechRailApp \
  -destination 'platform=macOS'
```

---

## Task 8: 建立 macOS 集成测试、构建脚本和 CI 门禁

**Files:**

- `macos/SpeechRailApp/SpeechRailAppIntegrationTests/`
- `scripts/macos_app_test.sh`
- `scripts/macos_app_build.sh`
- `.github/workflows/ci.yml`
- `.gitignore`（仅在确有缺口时追加）
- `docs/developers/macos-app-development.md`

- [ ] 写一个无模型的集成 harness：临时 app home、临时 port、临时 helper label/Mach service、fake Python executable/runner；测试后清理临时目录和 LaunchAgent registration。
- [ ] `scripts/macos_app_test.sh` 使用可移植的 `xcodebuild test` 参数，支持显式 `-scheme`、`-destination` 和 test plan，不写入用户 home 的生产目录。
- [ ] `scripts/macos_app_build.sh` 支持 Debug build、Release archive 和指定 export options；默认只 build，不自动上传、不自动 notarize、不修改钥匙串。
- [ ] CI 增加 macOS App job：固定 Xcode 版本/SDK 约束、build、unit/UI/integration tests、plist lint、`git diff --check`；不依赖 Developer ID secret，不下载模型。
- [ ] 开发文档记录安装前置、目录结构、启动测试、隔离规则、sign/notarize 前置以及常见的 helper disabled 处理；不写本机绝对缓存路径、证书名称或密钥。
- [ ] 运行本地测试一次，并确认 CI YAML 解析、Xcode scheme/test plan 可发现。

**Verification:**

```bash
scripts/macos_app_test.sh
scripts/macos_app_build.sh --configuration Debug
```

---

## Task 9: Developer ID 签名、archive、notarization 验证流程

**Files:**

- `macos/SpeechRailApp/Config/Distribution.xcconfig`
- `macos/SpeechRailApp/ExportOptions.plist.example`
- `scripts/macos_app_archive.sh`
- `scripts/macos_app_verify_distribution.sh`
- `docs/developers/macos-app-release.md`

- [ ] 将 team ID、signing identity、bundle identifier、export method 作为 CI/user-provided build settings；不把证书名、Apple ID、app-specific password、API key 或 keychain profile 写入仓库。
- [ ] archive/export 时分别对 App、framework、Agent、嵌套 helper/resource code 签名并验证；不使用 `codesign --deep` 掩盖嵌套签名错误。
- [ ] Hardened Runtime 及 secure timestamp 在分发配置中显式开启；只允许 Developer ID Application direct distribution。
- [ ] 在有身份和 notarization credential 的机器上执行 `notarytool submit --keychain-profile "$KEYCHAIN_PROFILE_NAME"`、`stapler staple`、`spctl --assess`；无 credential 时只完成本地签名前置检查并准确报告未验证项。
- [ ] 验证 App bundle 内 helper plist 使用 `BundleProgram`、helper 的 team/signing identifier 与 App 一致，SMAppService 注册后 helper 可响应 XPC。
- [ ] 记录可重复的回滚方式：移除新 App/Agent registration，恢复上一版本 App bundle；不删除 SpeechRail app home、models 或现有 `com.speechrail` runtime。

**Verification:**

```bash
scripts/macos_app_archive.sh --configuration Release
scripts/macos_app_verify_distribution.sh path/to/SpeechRailApp.app
```

---

## Task 10: 全量验收、证据整理与提交

**Files:**

- `docs/developers/macos-app-development.md`
- `docs/developers/macos-app-release.md`
- `docs/superpowers/plans/2026-09-12-macos-app-environment.md`
- 仅包含上述任务实际需要的源代码、测试和配置

- [ ] 按 TDD 顺序完成所有新增行为的定向测试、集成测试和 UI test；失败时先定位根因再修复，不以重试替代证据。
- [ ] 执行 SpeechRail 完整 Python gate：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

- [ ] 执行 macOS 相关 gate：

```bash
xcodebuild test -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp \
  -testPlan SpeechRailApp \
  -destination 'platform=macOS'
plutil -lint deploy/macos/com.speechrail.plist.example
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

- [ ] 若授权且本机已有外部 runtime，只做非敏感短音频公共 ASR/TTS smoke；不因 App 验收而改变 profile、下载模型或修改 production service。
- [ ] 检查 `git status --short`、staged diff、敏感字段、未跟踪构建产物和并行改动；确认没有 `.env`、模型、音频、日志、archive、export 或 notarization artifact 入库。
- [ ] 更新本计划勾选状态与开发/发布文档的实测结果；只在对应工作真正完成后勾选。
- [ ] 使用一个逻辑 commit 表达 macOS App 环境主题，提交前运行 `git diff --staged --check`；不强推送、不覆盖已有用户提交。

**最终通过标准:**

- Xcode 26.6 stable 与 macOS SDK 可用；Debug build 和无模型测试可重复。
- App/Agent/ControlKit 的 bundle、签名、XPC peer policy、SMAppService plist layout 经实测。
- UI 能通过隔离 seam 覆盖服务状态、三档 profile 和常见错误；生产运行态未被测试污染。
- Python 默认 CLI 兼容，机器输出可被 Agent 稳定解析；现有 OpenAPI、服务边界和 `com.speechrail` lifecycle 未被破坏。
- 分发流程在有用户提供 signing/notarization credentials 时可运行；缺 credential 的本机明确记录为待办前置而不是伪造“已公证”。
