---
title: "SpeechRail macOS App 开发测试环境与控制面设计"
status: active
audience: "核心开发者、macOS App 开发者、发布维护者"
version: "0.1.0"
date: 2026-09-12
---

# SpeechRail macOS App 开发测试环境与控制面设计

## 1. 目标与范围

本设计准备 SpeechRail 的首个原生 macOS App 开发、测试和直接分发环境，并为 App 首期从 UI 启停服务、执行 `preflight`、切换 `light` / `balanced` / `quality` profile 建立安全边界。

首期 App 是本机控制面，不是新的语音运行时。ASR/TTS 模型、Python managed runtime、CoreML bundle、音频采集与会议业务继续由现有 SpeechRail 服务和调用方负责。App 不复制服务生命周期、profile journal、资源调度或推理逻辑。

首期分发目标是站外 Developer ID + notarization；Mac App Store 沙盒化不属于本阶段交付。

## 2. 当前事实与约束

- 仓库当前 `main` 已有一个用户提交的 Antigravity 文档提交；本任务从独立短期分支继续，不重写历史。
- 仓库已有 `native/diarization` SwiftPM 包，`Package.swift` 使用 Swift tools 6.0、最低 macOS 14，并固定 FluidAudio revision；它是服务的 native worker，不是 GUI App target。
- 当前受管服务由 `com.speechrail` 用户级 LaunchAgent 托管，实际 Python executable 位于 managed app home 的 `runtime/current/.venv/bin/python`；服务、profile apply/rollback 和事务 journal 已在 Python 侧有回归测试。
- `create_launch_agent_manager`、`LaunchAgentServiceController` 和 `apply_prepared_profile` 是现有生命周期与 profile 切换的事实入口。App 不直接调用 `launchctl`，helper 也不重写这些规则。
- 2026-09-12 本机实测为 `arm64`、macOS 26.6.2、Swift 6.3.3、Xcode 26.6；active developer directory 为 `/Applications/Xcode.app/Contents/Developer`，可用 macOS SDK 为 26.5。当前没有有效的 code-signing identity，因此本阶段按无 Apple Developer ID 的本地开发模式验收。
- 项目现有边界要求默认 loopback、单一 SpeechRail 服务和单一 ASGI worker；模型、音频、私有配置和日志不进入仓库或 App bundle。

## 3. 方案比较与决策

### 3.1 方案 A：纯 SwiftUI 控制面

App 只通过 HTTP 查询健康状态，服务仍完全由 CLI 管理。它最容易启用 App Sandbox，但不能满足首期 UI 启停和 profile 切换要求，因此不采用。

### 3.2 方案 B：SwiftUI + `SMAppService` 控制 helper + 现有服务桥接（采用）

App 通过 `SMAppService` 注册一个随 App 分发的用户级 `SpeechRailControlAgent`。App 使用 XPC 发送固定的控制命令；helper 使用绝对路径和参数白名单调用当前 managed Python CLI，复用既有 `com.speechrail` LaunchAgent、`ServiceLifecycle`、profile transaction journal、preflight、public smoke 和 rollback。

该方案满足 UI 直接控制，同时把高风险的文件路径、`launchctl`、模型供给和服务重启留在单一受控边界内。现有 `com.speechrail` 仍是实际 SpeechRail 服务的唯一 owner；control agent 只负责受认证的控制请求，不启动第二个 ASGI worker。

### 3.3 方案 C：把 Python runtime、模型和服务全部塞入 App bundle

该方案会把模型体积、外部 snapshot、worker 进程、代码签名、升级回滚和内存治理全部耦合到 App，且与现有 managed release / 外部模型边界冲突。本阶段明确不采用。

## 4. 目标架构

```text
SpeechRail
  ├─ SwiftUI settings window + MenuBarExtra
  ├─ URLSession → http://127.0.0.1:8201
  │                /health /readyz /v1/models /v1/voices /metrics
  └─ NSXPCConnection → com.speechrail.desktop.control
                    └─ SpeechRailControlAgent
                         └─ fixed argv → managed Python CLI
                              └─ existing com.speechrail LaunchAgent
                                   └─ one SpeechRail ASGI process + workers
```

### 4.1 GUI App

- 使用 SwiftUI `MenuBarExtra` 提供常驻状态、启动/停止、重启、profile 入口和打开设置窗口的入口；复杂状态放在普通设置窗口中。
- 使用 Observation 管理 UI state；服务状态、profile 状态和控制 operation 都是可观察模型，View 不直接持有进程或文件句柄。
- 使用 `URLSession` 查询现有安全诊断端点。App 只接收脱敏能力状态，不读取 `.env`、model path、原始日志、音频或转写文本。
- App 只提供 `arm64` 首期制品，最低 macOS 14.0，与 SpeechRail Apple Silicon 运行时定位一致。

### 4.2 ControlAgent

- 作为 App bundle 内的 signed executable，放在 `Contents/Resources`；LaunchAgent plist 放在 `Contents/Library/LaunchAgents`，使用 `BundleProgram`，由 `SMAppService.agent(plistName:)` 注册。
- 以当前登录用户运行，不使用 root，不安装 `LaunchDaemon`。
- 通过 Mach service 接收 XPC 请求；首期以 macOS 14 可用的 `NSXPCConnection` 承载版本化 Codable `Data` envelope，操作集合固定为：`status`、`start`、`stop`、`restart`、`preflight`、`profileList`、`profileStatus`、`profileApply`、`profileRollback`、`operationStatus`、`operationCancel`。macOS 26 的新 Swift `XPCSession` peer API 不作为最低系统版本的必要依赖。
- helper 串行执行会改变运行态或配置的操作；同一时间只允许一个 mutation。profile apply 作为异步 operation，返回 opaque `operation_id` 和脱敏阶段状态，不把完整子进程输出传给 UI。
- helper 只接受固定的 profile enum 和布尔确认，不接受任意 executable、shell 字符串、模型路径、日志路径或任意 `app_home`。首期 app home 固定为用户的 `~/Library/Application Support/SpeechRail`；现有自定义路径用户先继续使用 CLI。
- helper 使用 `Process` 直接传递 argv，禁止 `shell`、`system()`、字符串拼接命令和隐式网络下载。实际 profile 供给仍由用户明确触发的既有 Python 命令完成。
- App 与 helper 使用同一 Developer Team 签名；helper 通过 `NSXPCConnection.setCodeSigningRequirement` 对 XPC peer 做 code-signing / team identity 校验，拒绝未授权调用方。该 API 在 macOS 13 已可用，满足最低 macOS 14；`XPCPeerRequirement` 仅作为 macOS 26 可选实现，不写入最低版本路径。

### 4.3 Python 兼容边界

为避免解析人类可读 CLI 文本，Python CLI 增加向后兼容的机器输出选项；默认人类输出保持不变。机器输出只包含 schema version、command、safe status、profile id、operation id、error code 和阶段，不包含绝对路径、Authorization、模型文件名、原始音频、完整转写或完整日志。

helper 调用的 Python 入口始终是当前 managed runtime 的绝对路径，并使用 `-I -m speechrail`。服务启停继续走已有 `LaunchAgentServiceController`；profile apply 继续走已有事务状态机，成功必须经过 preflight、重启和 public smoke，失败必须执行既有 rollback 或明确进入 `NOT_READY`。

## 5. 安全、权限与隐私

- 未来 Distribution 使用站外直接分发，App 和 helper 开启 Hardened Runtime；只增加经实际功能证明必要的例外，不启用 JIT、unsigned executable memory、DYLD environment variables 或 library validation 例外。当前无 Apple Developer ID 的 Debug/Release 本地 bundle 为支持 ad hoc 独立启动而关闭 Hardened Runtime；该本地配置不代表可分发产物。
- 首期不启用 App Sandbox。这是为了让控制 helper 访问现有用户级 managed runtime、app home 和 LaunchAgent 兼容布局；该取舍只适用于 Developer ID 直发，不代表未来 App Store 方案。
- App 不采集麦克风、不播放音频、不读取任意用户文件，因此不加入麦克风、文件、网络 server 或 Automation 权限，也不加入 `NSMicrophoneUsageDescription`。音频权限仍由未来真正负责录音的调用方申请。
- `127.0.0.1:8201` 是唯一默认服务地址；App 不允许用户输入远程 URL，也不在请求路径触发下载。
- helper、GUI 和 Python CLI 的日志只记录 operation type、safe status、error code、duration 和脱敏 request/operation id；动态路径、token、音频、转写和模型内容全部视为 private。
- App 退出不等于停止 SpeechRail 服务。菜单栏和设置页必须明确显示后台服务状态，并提供显式停止入口；用户也能在 System Settings 的 Login Items 中禁用 control agent。

## 6. 开发与测试环境

### 6.1 工具链

- 安装 Xcode 26.6 stable，并将其设为 active developer directory；不使用 Xcode 27 RC 作为基线。
- 保留现有 Swift 6.3.3 / SwiftPM 工具链，执行 `native/diarization` 的现有 SwiftPM 测试作为独立门禁。
- 新 App 使用 Xcode project 和 shared scheme，不把 GUI App 伪装成普通 SwiftPM executable；首期不引入第三方 Swift UI 依赖。
- Debug、Release、Distribution 使用共享 `.xcconfig`；Team ID、签名 identity、notary profile 名称只从本机或 CI secret 注入，不提交真实值。

### 6.2 Target 布局

```text
macos/SpeechRailApp/
  SpeechRailApp.xcodeproj
  SpeechRailApp/                 # GUI App target
  SpeechRailControlKit/         # XPC message types, state reducers, client protocol
  SpeechRailControlAgent/       # SMAppService LaunchAgent target
  SpeechRailMacControlTests/     # XCTest unit-test sources for SpeechRailAppTests target
  SpeechRailAppUITests/          # XCTest UI tests
  Resources/LaunchAgents/        # control-agent plist
  Config/                        # Debug / Release / Distribution xcconfig
  Entitlements/                  # minimal direct-distribution entitlements
  SpeechRailApp.xctestplan       # deterministic local test plan
```

`SpeechRail` 不链接 `native/diarization` 或任何模型 SDK；该 package 继续独立构建并随服务 wheel/release 处理。

### 6.3 测试分层

1. XCTest unit tests：覆盖 XPC 消息编码、code-signing requirement 配置、peer rejection、状态 reducer、profile enum、错误映射和 operation 状态机；所有外部进程和网络均 fake。
2. XCTest UI Tests：覆盖首次启动、helper 未注册、服务未就绪、启动/停止/重启、profile apply confirmation、失败回滚和后台服务被用户禁用的界面状态。使用 `--ui-test` 注入 deterministic fake transport，不能触碰真实 LaunchAgent。
3. ControlAgent integration：使用独立 Mach service label、临时 app home、临时 port 和 fake managed Python runner；禁止写入生产 `~/Library/Application Support/SpeechRail`、生产 `com.speechrail` 或真实模型目录。
4. Authorized local smoke：单独、显式执行签名 debug App 的 `SMAppService` register/unregister，以及真实 `com.speechrail` start/stop/profile 操作；每次操作前显示目标 label 和 app home，结束后核对 PID、端口、`/health`、`/readyz` 和 profile 状态。
5. CI：保留现有 Python Ubuntu/macOS jobs，新增 macOS App job 执行 Xcode build/test、unsigned archive preflight 和 entitlements 检查；真实模型、真实 LaunchAgent、Developer ID 私钥和 notarization 不进入普通 PR job。

## 7. 签名、归档与分发门禁

1. Debug：无 Apple Developer ID 时使用 ad hoc 本地签名，关闭 Hardened Runtime，允许调试器附加；不把开发 entitlement 带入分发产物。
2. Release：未来 Distribution 对 App、ControlAgent 及所有 nested code 分别签名，启用 Hardened Runtime 和 secure timestamp；不使用 `codesign --deep` 作为签名流程。当前本地 Release 与 Debug 同样采用 ad hoc、关闭 Hardened Runtime。
3. Archive：使用 `xcodebuild archive` 生成 archive，再用 `-exportArchive` 的 Developer ID 方式导出。
4. Verify：对 App、helper、nested code 逐项执行签名验证，并用 `spctl --assess` 检查 Gatekeeper 策略；核对 `SMAppService` plist 的 `BundleProgram` 和 bundle-relative 路径。
5. Notarize：使用 `notarytool` 的 keychain profile 上传 zip/DMG；等待 notarization 成功后 staple ticket，再在干净目录验证打开和 helper 注册。
6. 回退：App release、Python managed release、selection journal 和外部模型保持独立；App 更新失败不能覆盖旧服务 runtime 或旧 profile。

## 8. 实施顺序

1. 安装并验证 Xcode 26.6，确认 macOS 14 SDK、Swift compiler、`xcodebuild`、`xcrun`、codesigning 和 host macOS test destination 可用。
2. 建立 Xcode project、shared scheme、targets、xcconfig、最小 Hardened Runtime 配置、helper plist 和 test plan。
3. 建立 `SpeechRailControlKit` 的协议与 fake transport，先用 Swift Testing 锁定状态和错误行为。
4. 建立 ControlAgent 的 `NSXPCListener`、固定命令 runner 和 `SMAppService` register/status/unregister 流程；先只接 fake runner。
5. 给 Python CLI 增加机器输出并补契约测试，再接入真实 managed runtime 命令；保持默认 CLI 文本输出兼容。
6. 建立 UI 状态流和 XCTest UI 测试；加入测试隔离保护，验证不会操作生产 label/home。
7. 建立本地 `xcodebuild test`、SwiftPM test、Python gate 和 macOS App CI job。
8. 在有 Developer ID identity 后执行签名、archive、`spctl` 和 notarization dry run；没有 identity 时只能报告 unsigned archive 结果，不伪造分发就绪。

## 9. 验收标准

- 本机 `xcodebuild -version`、`swift --version`、macOS 14 SDK 查询和 `xcodebuild test` 均成功。
- App、ControlAgent、unit test、UI test 四类 target 能在共享 scheme 下编译；Xcode project 不依赖仓库外的绝对源码路径。
- UI 启停请求只能经 XPC helper 到达既有 Python lifecycle；App 源码中不存在 `launchctl`、任意 shell 或模型路径读取。
- profile apply 的成功/失败状态与 Python journal 一致；失败不会留下第二个服务实例，且 UI 能展示 rollback / `NOT_READY`。
- 测试默认不注册生产 `SMAppService`、不写生产 app home、不访问真实模型、不下载权重、不记录敏感音频或完整文本。
- Developer ID 归档能在无 `--deep` 的情况下验证所有 nested code；notarization 使用 keychain credential，不在仓库、命令参数或日志中出现私钥/token。

## 10. 参考资料

- [Apple Xcode SDK and system requirements](https://developer.apple.com/xcode/system-requirements)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Creating XPC services](https://developer.apple.com/documentation/xpc/creating-xpc-services)
- [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection)
- [Managing ongoing background processes in your Mac](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac)
- [Configuring the Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Adding tests to your Xcode project](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project)
