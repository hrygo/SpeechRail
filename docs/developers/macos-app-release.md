---
title: "SpeechRail macOS App 分发与签名"
status: active
version: "0.5.3"
date: 2026-09-17
---

# SpeechRail macOS App 分发与签名

## 当前状态

当前开发机按无 Apple Developer ID 模式运行：Debug/Release 使用 ad hoc 本地签名构建并关闭 Hardened Runtime，测试脚本默认保留该本地签名，以便 Xcode UI test runner 正常加载 `Testing.framework` 运行库；不会生成可分发的 archive，不会上传 notarization，也不会修改钥匙串或用户的登录项。只有显式设置 `SPEECHRAIL_MACOS_SIGNED_TESTS=0` 才会请求 unsigned test bundle；Distribution 配置才启用 Hardened Runtime。

本地安装的 Debug/Release App 使用 `Contents/XPCServices/com.speechrail.desktop.local-control.xpc` 按需启动控制 helper，不注册 `SMAppService`，也不会修改 Distribution 的登录项记录。只有 Distribution 包在具备 Team ID 和签名时，才使用 `SMAppService` LaunchAgent；App 先呈现系统授权状态，只有用户明确点击启用时才注册，这一步不代表 ad hoc 包具备 Developer ID 分发资格。

这条本地控制通道依赖 App 的 bundle 签名：helper 在 `SPEECHRAIL_ALLOW_UNSIGNED_XPC=1` 下把对端固定为 `identifier "com.speechrail.desktop"`（即 `SpeechRailControlKit` 的 `ControlConstants.appBundleIdentifier`），所以 App 的签名标识必须等于它的 bundle identifier。用 `CODE_SIGNING_ALLOWED=NO` 构建时只剩 linker 写进二进制的 ad-hoc 签名：签名标识变成 `PRODUCT_NAME`（`SpeechRail`）、`Info.plist` 未绑定、没有 `Contents/_CodeSignature/CodeResources`。XPC 的 peer 校验会以 `errSecCSReqFailed`（`xpc_support_check_token ... status: -67050`）拒绝每一个请求，App 侧表现为主界面「控制通道不可用」、诊断页「操作未完成，请重试或打开系统诊断」，而 REST 只读信息仍然正常。Debug/Release 构建因此必须保持签名开启（`CODE_SIGN_IDENTITY=-`，无需证书），并由 `scripts/macos_app_verify_local_xpc.sh` 在打包前把关。

这不等同于可交付给其他 Mac 的发布包。站外直接分发仍保留 Developer ID Application + notarization 路径，待用户准备 Apple Developer 账号、证书和 notarization credential 后再启用。

## 发布边界与制品

| 制品 | 内容 | 实际 owner | 登录启动 | 不能做什么 |
|---|---|---|---|---|
| `SpeechRail.app` | SwiftUI 菜单栏/设置控制面 | 用户按需打开 | **否** | 不加载模型，不启动服务；不在后台采集或播放音频（只在音色克隆页按下录制时采集麦克风，播放只在用户点「播放 / 试听」时发生） |
| `com.speechrail.desktop.control` | Distribution App bundle 内的 `SpeechRailControlAgent` + `SMAppService` plist | XPC 控制 helper | 仅签名 Distribution 由 `SMAppService` 注册 | 不拥有 8201，不创建第二个 ASGI/worker，不替换服务 runtime |
| `com.speechrail.desktop.local-control` | Debug/Release App bundle 内的 `XPCServices/*.xpc` | 按需 XPC 控制 helper | 由 `NSXPCConnection(serviceName:)` 按需启动 | 不注册登录项，不拥有 8201，不创建第二个 ASGI/worker |
| `com.speechrail` | Python managed service LaunchAgent | SpeechRail 服务 | **是** | 不依赖 App 是否打开 |

`SpeechRail.app` 退出、更新或注销 control-agent 都不得停止、删除或覆盖 `com.speechrail`、`runtime/current`、selection、模型、私有 `.env` 或日志。服务发布与 App 发布可以独立回滚；联合发布时先完成服务 wheel 的 preflight/运行态验收，再验收 App 控制链路。

### 发布范围

- `service-only`：只构建/安装服务 wheel；服务 PATCH 不因“配套”重建 App。
- `app-only`：只构建 App；前提是当前服务支持 App 所需的 XPC `schema_version`、固定命令集合和 machine-output 字段。
- `combined`：服务 wheel 与 App 同一批次发布，使用同一个 release evidence，但保留两套独立 rollback point。

App 正式发布必须有可审计的 `CFBundleShortVersionString`（用户可见版本）和 `CFBundleVersion`（单调递增 build）。缺失、仍为 Xcode 默认值或无法关联到 commit/release evidence 时，发布失败；不能用 Finder 显示名、文件时间或 ZIP 文件名代替版本。

## 本地无证书开发

```bash
scripts/macos_app_build.sh --configuration Debug
# scripts/macos_app_test.sh  # XCTest/UI test：接管前台窗口/输入，仅在当前用户明确要求时运行
```

UI 自动化测试（XCTest/UI test，含 `scripts/macos_app_test.sh`）会接管前台窗口、焦点和输入，仅在当前用户明确要求时逐次运行（见 [AGENTS.md](../../AGENTS.md) 硬约束），不因生产分发或验收流程自动触发；默认不执行，并在结果中记为未验证项。

本地测试不需要 Developer ID。测试使用 `--ui-test` fake transport，不注册生产 helper、不启动 `com.speechrail`、不下载模型。测试脚本使用一次性临时 DerivedData，结束时注销本次构建 App/runner 的 LaunchServices 注册并清理测试产物；不会把测试 App 留在用户目录或仓库中。Distribution archive/export 仍只在显式指定的输出路径保留。

## GitHub Actions unsigned DMG

匹配 `pyproject.toml` 版本的 `vX.Y.Z` tag 会触发 Release workflow。workflow 在 `macos-26` arm64 runner 上用 `Release` 配置和 `ARCHS=arm64` 构建 App，并保持 ad hoc 本地签名开启（沿用 `Release.xcconfig` 的 `CODE_SIGN_IDENTITY=-`，不需要证书或 provisioning）；随后 `scripts/macos_app_verify_local_xpc.sh` 核对签名标识、签名有效性和内嵌 local XPC helper 是否满足上面的控制通道约束，再由 `scripts/macos_app_create_dmg.sh` 生成压缩 DMG。DMG 只包含 `SpeechRail.app` 和指向 `/Applications` 的符号链接，并随 wheel 与 `SHA256SUMS` 上传到 GitHub Release。

该 DMG 文件本身未签名、未 notarize，包内的 App 只有 ad hoc 本地签名，不代表 Developer ID 发布验收。首次从互联网下载后打开时，macOS 可能显示无法验证开发者或无法检查恶意软件的提示；确认制品来源和 checksum 后，按系统设置“隐私与安全性”中的“仍要打开”流程放行。受企业策略管理的 Mac 可能不允许此覆盖。正式面向不熟悉终端用户的分发仍必须走下面的 Developer ID + notarization 路径。

本地只打包一个已经生成的 App 时可以执行：

```bash
scripts/macos_app_create_dmg.sh \
  --app-path "/path/to/SpeechRail.app" \
  --version "2.6.0" \
  --output-path "/path/outside/repository/SpeechRail-2.6.0-macOS-arm64.dmg"
```

`scripts/macos_app_create_dmg.sh` 会核对 App bundle identifier、`CFBundleShortVersionString`、`CFBundleVersion` 和 DMG 内容，并拒绝覆盖已有输出文件。它不签名、不修改钥匙串、不注册 LaunchAgent，也不改变服务 runtime；打包前用 `scripts/macos_app_verify_local_xpc.sh <SpeechRail.app>` 验证签名身份和 local XPC helper，避免把控制通道已经失效的 App 装进 DMG：

```bash
scripts/macos_app_verify_local_xpc.sh "/path/to/SpeechRail.app"
```

归档前先确认版本字段已经进入实际构建设置：

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp -configuration Distribution -showBuildSettings \
  | rg 'MARKETING_VERSION|CURRENT_PROJECT_VERSION'
```

若没有同时得到两项有效值，先补齐 Xcode build settings，再继续发布；禁止用默认 `1.0` 或 Finder 显示名代替 App 版本。归档后从 `Contents/Info.plist` 读取并记录 `CFBundleDisplayName`、`CFBundleIdentifier`、`CFBundleShortVersionString` 和 `CFBundleVersion`，期望显示名为 `SpeechRail`、bundle identifier 为 `com.speechrail.desktop`。

`MARKETING_VERSION` 必须与 `pyproject.toml` 的 `[project].version` 一致，DMG 脚本会据此拒绝版本不符的构建；
这条约束现在由 `scripts/check_version_consistency.py` 覆盖（三个 build configuration 都要命中），
漏 bump 会在仓库门禁和本地预检失败，而不是等到 tag 触发的 Release 在 `Create and verify unsigned DMG` 才暴露。

## Developer ID 发布前置

发布机需要具备：

- Apple Developer 账号及目标 App 的 Team ID；
- `Developer ID Application` 证书及对应私钥；
- 可被 `notarytool` 使用的 Keychain profile；
- 与 `com.speechrail.desktop`、`com.speechrail.desktop.control` 对应的签名配置。

Team ID、证书名称、Apple ID、app-specific password、API key 和 Keychain profile 名称都只通过用户本机环境或钥匙串传入，不写入仓库。不要把真实 `ExportOptions.plist` 提交到仓库；以 `macos/SpeechRailApp/ExportOptions.plist.example` 为模板，在仓库外复制并替换占位值。

## Archive / export / verify

准备好签名身份后，在仓库根目录执行；用 `--export-path` 指向仓库外的显式目录。脚本生成的 `build/SpeechRail.xcarchive` 是仓库内的临时构建产物，验收后必须清理或移到证据目录，避免被 Finder/LaunchServices 当成已安装 App：

```bash
export SPEECHRAIL_TEAM_ID="<your-team-id>"
scripts/macos_app_archive.sh \
  --export-options "/path/outside/repository/ExportOptions.plist" \
  --export-path "/path/outside/repository/macos-export"
scripts/macos_app_verify_distribution.sh \
  "/path/outside/repository/macos-export/SpeechRail.app"
```

`macos_app_verify_distribution.sh` 会逐项验证 App、嵌套 framework、Agent executable 以及 LaunchAgent plist，不使用 `codesign --deep` 掩盖嵌套代码签名问题。验证项包括：

- Hardened Runtime 和签名完整性；
- App bundle 内 `SpeechRailControlAgent` 存在且可执行；
- helper plist 位于 `Contents/Library/LaunchAgents/`；
- helper plist 使用 `BundleProgram`，而不是旧式 `Program`；
- Distribution 构建不会保留本地 `SPEECHRAIL_ALLOW_UNSIGNED_XPC` 开发开关；
- 构建时若有 Team ID，会把它注入 helper 环境，供 Agent 生成 same-team XPC requirement。

## Notarization

压缩导出的 App 后，通过 Keychain profile 调用 `notarytool` 上传；成功后 staple，再用 `stapler validate`、`spctl --assess` 和 `codesign --verify --strict` 验证，最后重新生成交付 ZIP。不要使用已废弃的 `altool`：

```bash
ditto -c -k --keepParent \
  "/path/outside/repository/macos-export/SpeechRail.app" \
  "/path/outside/repository/SpeechRail-<version>-submit.zip"
xcrun notarytool submit \
  "/path/outside/repository/SpeechRail-<version>-submit.zip" \
  --keychain-profile "$SPEECHRAIL_NOTARY_PROFILE" --wait
xcrun stapler staple \
  "/path/outside/repository/macos-export/SpeechRail.app"
xcrun stapler validate \
  "/path/outside/repository/macos-export/SpeechRail.app"
spctl --assess --type execute --verbose=2 \
  "/path/outside/repository/macos-export/SpeechRail.app"
codesign --verify --strict --verbose=2 \
  "/path/outside/repository/macos-export/SpeechRail.app"
ditto -c -k --keepParent \
  "/path/outside/repository/macos-export/SpeechRail.app" \
  "/path/outside/repository/SpeechRail-<version>.zip"
shasum -a 256 "/path/outside/repository/SpeechRail-<version>.zip"
```

当前无 Apple Developer ID 时，以上步骤属于未执行项；ad hoc 本地签名不能替代 Developer ID，不能把本地 build 说明为 Developer ID 已签名或已公证的分发包。

## 安装、验收与清理

1. 联合发布先完成服务的 `/health`、`/readyz`、`/v1/models`、`/v1/voices` 和目标 smoke；App 不能替代服务验收。
2. 退出旧 `SpeechRail.app`，将最终 ZIP 解出到临时目录，确认 bundle identity/version 后，只安装一个 bundle 到用户路径 `~/Applications/SpeechRail.app`；若使用其他路径，必须在 evidence 中明确记录。上一版本保留为 ZIP/归档制品，不作为第二个长期可执行 `.app`。
3. 打开同一路径的 App，确认显示名、bundle identifier、version/build 和 control-agent 状态；用 UI 执行一次 `status`/`preflight` 只读控制，必要的 mutation 必须有单独授权。Debug/Release 应验证内嵌 `com.speechrail.desktop.local-control.xpc`；签名 Distribution 才通过 `SMAppService` 管理 `com.speechrail.desktop.control`。两种模式都不手工复制 plist、不直接调用 `launchctl`。
4. 关闭 App 后再次检查 `com.speechrail`、唯一 8201 listener、`/health` 和 `/readyz`；App/Agent 退出不能停止服务。
5. 清理本次精确 staging、DerivedData、`build/macos-derived-data`、未交付 archive/export 和旧测试 bundle；保留最终 ZIP、哈希、签名/公证结果及脱敏 evidence。不要删除服务 app home、`runtime/releases`、模型、selection、私有配置或日志，也不要全局重置 LaunchServices。

```bash
mdfind 'kMDItemCFBundleIdentifier == "com.speechrail.desktop"'
mdfind 'kMDItemFSName == "SpeechRailApp.app"'
```

清理后第一条查询只应保留唯一安装路径（默认 `~/Applications/SpeechRail.app`），第二条应为空。Finder 仍出现多个 `SpeechRail.app` 时，先逐一列出实际路径，区分已安装 bundle、Xcode DerivedData、仓库 build 和解压 staging，再清理精确测试副本；旧 `SpeechRailApp` 命名出现时视为发布失败。

## 回滚

- **App-only 失败**：退出新 App，将上一份已验证 ZIP 恢复到同一安装路径；按 `SMAppService`/System Settings 核对 control-agent 状态，服务 `runtime/current`、selection、模型和 `com.speechrail` 不变。
- **服务-only 失败**：按 [版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md) 恢复旧 `runtime/current`、selection 和 LaunchAgent；不要为了服务回滚删除 App。
- **联合发布失败**：服务验收通过而 App/XPC 失败时只回滚 App；服务失败时先恢复服务，再按需要恢复兼容 App。不能用 App 回滚替代服务回滚，也不能因 App 安装失败删除服务数据。

回滚后重新执行 App version/build、helper 状态、唯一安装路径、App 退出后服务独立运行，以及服务 health/ready 检查。保留失败制品和原因摘要。

## 参考

- [SpeechRail 版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md)
- [SpeechRail macOS App 开发与测试](macos-app-development.md)
- [本机 operator contract](../../.agents/skills/speechrail-local-deploy/references/operator-contract.md)
- [Apple：SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple：Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
