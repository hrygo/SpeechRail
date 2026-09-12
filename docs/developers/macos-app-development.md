---
title: "SpeechRail macOS App 开发与测试"
status: active
version: "0.1.0"
date: 2026-09-12
---

# SpeechRail macOS App 开发与测试

## 工具链

- Xcode 26.6 stable，Swift 6.3，macOS deployment target 14.0，首期只构建 `arm64`。
- Python 仍固定为 `>=3.12,<3.13`，使用仓库现有 `uv` 环境。
- 运行 App 前，首次安装 Xcode 的管理员需要在本机接受 Apple 许可；不要把管理员密码写入脚本或仓库。
- 当前本机不依赖 Apple Developer ID；Debug/Release 可用 ad hoc 本地签名且关闭 Hardened Runtime，测试脚本显式使用 unsigned build，Distribution 才启用 Hardened Runtime 并保留发布模板。

## 边界

`SpeechRail` 是控制面，不是 ASR/TTS runtime。它不采集麦克风、不播放音频、不加载模型，也不直接执行 `launchctl`。`SpeechRailControlAgent` 由 `SMAppService` 管理，通过受签名约束的 XPC 接收固定命令，再委托现有 managed Python CLI。实际服务仍由唯一的 `com.speechrail` user LaunchAgent 运行。

App 默认只读 loopback 的公开状态端点；模型目录、`.env`、日志、原始音频、完整转写和 API key 均留在 App bundle 之外。

## 本地开发

1. 在 Xcode 中打开 `macos/SpeechRailApp/SpeechRailApp.xcodeproj`，选择 `SpeechRailApp` scheme。
2. Debug/Release 默认使用 `Sign to Run Locally` 的 ad hoc 本地签名；测试脚本默认关闭签名，若本机后来配置了 development signing，可设置 `SPEECHRAIL_MACOS_SIGNED_TESTS=1` 运行签名测试。
3. 修改 Python 服务后先执行 `uv sync --extra dev`，再运行 `scripts/macos_app_test.sh` 与 Python 定向测试。
4. UI test 通过 `--ui-test` 使用 fake transport；不会注册生产 helper、启动 `com.speechrail` 或访问真实模型。

## 测试隔离

- Swift unit tests 只使用 in-process fake runner/transport。
- UI/integration tests 使用 fake transport、临时 app home、端口和 helper label；测试结束必须注销临时 LaunchAgent 并清理临时目录。
- 真实 `SMAppService` register/unregister 和真实 `com.speechrail` smoke 只在单独、明确授权的本机验收中执行。
- profile apply 仍由 Python transaction journal、preflight、public smoke 和 rollback 决定成功与否；App 不自行推断模型能力。

## 常见恢复

- Agent 显示为 disabled 或 requires approval：打开 System Settings 的 Login Items & Extensions，检查 `SpeechRailControlAgent` 的用户批准状态，然后回到 App 重试。
- managed runtime 缺失：先运行 `speechrail service preflight --app-home "$SPEECHRAIL_APP_HOME"`，不要让 App 下载模型或创建第二个 runtime。
- 服务不 ready：检查现有 `com.speechrail` 状态、端口和 `/health`/`/readyz`；App 退出不会自动停止服务。

## 验收命令

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

分发签名、archive、notarization 和回滚流程见 `docs/developers/macos-app-release.md`。
