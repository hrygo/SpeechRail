---
title: "SpeechRail macOS App 开发与测试"
status: active
version: "0.3.0"
date: 2026-09-13
---

# SpeechRail macOS App 开发与测试

## 工具链

- Xcode 26.6 stable，Swift 6.3，macOS deployment target 14.0，首期只构建 `arm64`。
- Python 仍固定为 `>=3.12,<3.13`，使用仓库现有 `uv` 环境。
- 运行 App 前，首次安装 Xcode 的管理员需要在本机接受 Apple 许可；不要把管理员密码写入脚本或仓库。
- 当前本机不依赖 Apple Developer ID；Debug/Release 可用 ad hoc 本地签名且关闭 Hardened Runtime。无 Team ID 时，Debug/Release 使用 App bundle 内的 XPC service，避免把 ad hoc helper 交给 macOS 的 `SMAppService` Launch Constraint；Distribution 才启用 Hardened Runtime 并使用签名的 `SMAppService`。

## 边界

`SpeechRail` 是控制面，不是 ASR/TTS runtime。它不采集麦克风、不播放音频、不加载模型，也不直接执行 `launchctl`。Distribution 的 `SpeechRailControlAgent` 由 `SMAppService` 管理；本机 Debug/Release 则使用 `Contents/XPCServices/com.speechrail.desktop.local-control.xpc` 按需启动同一控制代码，通过 XPC 接收固定命令，再委托现有 managed Python CLI。实际服务仍由唯一的 `com.speechrail` user LaunchAgent 运行。

App 默认只读 loopback 的公开状态端点；模型目录、`.env`、日志、原始音频、完整转写和 API key 均留在 App bundle 之外。

## 发布与运行态关系

- `com.speechrail` 是实际服务 owner，必须由服务发布/安装流程负责登录常驻；`SpeechRail.app` 只是按需打开的控制面，不是登录启动项。
- `com.speechrail.desktop.control` 是 Distribution 中由 App 通过 `SMAppService` 管理的独立 XPC helper；它不拥有 8201、不加载模型、不创建第二个服务实例。
- `com.speechrail.desktop.local-control` 是 Debug/Release 内嵌的 XPC service，仅在 App 需要控制操作时由系统按需启动；它不注册登录项、不依赖 Developer ID，也不拥有 8201。两种模式都复用同一个 `SpeechRailControlAgentCore` 和 XPC 协议。
- 签名 Distribution App 启动和控制操作前会以嵌入 helper 的 SHA-256 指纹维护 `SMAppService` 注册状态；首次安装、替换 bundle 或 helper 发生变化时，只对原本已启用的 item 做一次注销/重新注册，刷新 macOS 的 launch constraint，不覆盖用户在系统设置中的禁用/待批准状态。本机 Debug/Release 不走这条注册路径。
- `service-only`、`app-only` 和 `combined` release 允许独立回滚。联合发布必须先验收 service wheel，再验收 App 的 `status`/`preflight` 控制链路；发布、安装、清理和回滚统一见 [macOS App 分发与签名](macos-app-release.md) 与 [版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md)。

## 本地开发

1. 在 Xcode 中打开 `macos/SpeechRailApp/SpeechRailApp.xcodeproj`，选择 `SpeechRailApp` scheme。
2. Debug/Release 默认使用 `Sign to Run Locally` 的 ad hoc 本地签名；测试脚本默认保留签名，以满足当前 Xcode UI test runner 的 `Testing.framework` 运行库要求。只有明确需要未签名 bundle 时才设置 `SPEECHRAIL_MACOS_SIGNED_TESTS=0`。
3. 修改 Python 服务后先执行 `uv sync --extra dev`，再运行 `scripts/macos_app_test.sh` 与 Python 定向测试。
4. UI test 通过 `--ui-test` 使用 fake transport；不会注册生产 helper、启动 `com.speechrail` 或访问真实模型。Debug build 和 UI test 使用一次性临时 DerivedData，命令结束会注销本次构建 App 的 LaunchServices 注册并清理 App/runner；不会留下可搜索的测试 App。

## 测试隔离

- Swift unit tests 只使用 in-process fake runner/transport。
- UI/integration tests 使用 fake transport、临时 app home、端口和 helper label；测试结束必须注销临时 LaunchAgent 并清理临时目录。
- 真实 `SMAppService` register/unregister 只在签名 Distribution 验收中执行；本机 Debug/Release 走内嵌 XPC service。真实 `com.speechrail` smoke 仍只在单独、明确授权的本机验收中执行。
- profile apply 仍由 Python transaction journal、preflight、public smoke 和 rollback 决定成功与否；App 不自行推断模型能力。

## 控制操作错误契约

- managed CLI 在成功和失败时都必须优先输出 `schema_version=1` 的 JSON envelope；非零退出码不能替代 envelope 中的 `error_code`、`message` 和 `status`。
- Agent 调用 managed Python 时必须使用 `python -m speechrail ...`，不能把 CLI 的第一个子命令直接作为 Python 脚本路径；参数数组保持逐项传递，不经过 shell。
- `SpeechRailControlAgent` 即使子进程退出码非零，也先解析 stdout 的机器输出；只有输出无效时才使用限长、脱敏后的 stderr 尾行作为兜底，不把路径、凭据或完整 traceback 传给 UI。
- 异步 profile operation 的 `OperationSnapshot` 必须保留 `phase`、`errorCode` 和 `message`，并由 `operationStatus` 返回；App 收到 `failed`/`cancelled` 终态必须显示可读原因和错误码，不能只显示 `managed command failed`。
- 每个 XPC 请求都有有限超时；helper 无法启动或无响应时，App 显示可恢复的控制面错误，不得无限等待。切换类 mutation 不在未知提交状态下自动重放，避免重复执行。
- UI 测试中的 fake transport 必须覆盖一次失败终态；真实安装包验收仍需额外执行一次 App → XPC → managed CLI → `com.speechrail` 的切档往返，不能把 fake UI test 视为生产链路证明。
- 档位选择器首次显示以服务返回的 active profile 为准；切档失败回滚后重新同步 active profile，避免把默认 `balanced` 当成用户选择。

## 常见恢复

- Distribution Agent 显示为 disabled 或 requires approval：打开 System Settings 的 Login Items & Extensions，检查 `SpeechRailControlAgent` 的用户批准状态，然后回到 App 重试。
- 本机 Debug/Release 不应依赖 Login Items 中的 control helper。若旧 ad hoc 版本留下了失败的 `SMAppService` 记录，当前本地模式启动时会尽力注销旧记录，再使用内嵌 XPC service；不要手工复制 plist 或直接启动第二个 Agent。
- 替换签名 Distribution App 后，App 会检测 helper 指纹并刷新 `SMAppService` 注册；仍失败时看 App 展示的 phase/error code。
- managed runtime 缺失：先运行 `speechrail service preflight --app-home "$SPEECHRAIL_APP_HOME"`，不要让 App 下载模型或创建第二个 runtime。
- 服务不 ready：检查现有 `com.speechrail` 状态、端口和 `/health`/`/readyz`；App 退出不会自动停止服务。

## 验收命令

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

分发签名、archive、notarization 和回滚流程见 `docs/developers/macos-app-release.md`。
