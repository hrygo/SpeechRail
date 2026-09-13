---
title: "SpeechRail macOS App 分发与签名"
status: active
version: "0.2.0"
date: 2026-09-13
---

# SpeechRail macOS App 分发与签名

## 当前状态

当前开发机按无 Apple Developer ID 模式运行：Debug/Release 使用 ad hoc 本地签名构建并关闭 Hardened Runtime，测试脚本默认保留该本地签名，以便 Xcode UI test runner 正常加载 `Testing.framework` 运行库；不会生成可分发的 archive，不会上传 notarization，也不会修改钥匙串或用户的登录项。只有显式设置 `SPEECHRAIL_MACOS_SIGNED_TESTS=0` 才会请求 unsigned test bundle；Distribution 配置才启用 Hardened Runtime。

这不等同于可交付给其他 Mac 的发布包。站外直接分发仍保留 Developer ID Application + notarization 路径，待用户准备 Apple Developer 账号、证书和 notarization credential 后再启用。

## 发布边界与制品

| 制品 | 内容 | 实际 owner | 登录启动 | 不能做什么 |
|---|---|---|---|---|
| `SpeechRail.app` | SwiftUI 菜单栏/设置控制面 | 用户按需打开 | **否** | 不采集/播放音频，不加载模型，不启动服务 |
| `com.speechrail.desktop.control` | App bundle 内的 `SpeechRailControlAgent` + `SMAppService` plist | XPC 控制 helper | 可由 `SMAppService` 单独注册 | 不拥有 8201，不创建第二个 ASGI/worker，不替换服务 runtime |
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
scripts/macos_app_test.sh
```

本地测试不需要 Developer ID。测试使用 `--ui-test` fake transport，不注册生产 helper、不启动 `com.speechrail`、不下载模型。测试脚本使用一次性临时 DerivedData，结束时注销本次构建 App/runner 的 LaunchServices 注册并清理测试产物；不会把测试 App 留在用户目录或仓库中。Distribution archive/export 仍只在显式指定的输出路径保留。

归档前先确认版本字段已经进入实际构建设置：

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp -configuration Distribution -showBuildSettings \
  | rg 'MARKETING_VERSION|CURRENT_PROJECT_VERSION'
```

若没有同时得到两项有效值，先补齐 Xcode build settings，再继续发布；禁止用默认 `1.0` 或 Finder 显示名代替 App 版本。归档后从 `Contents/Info.plist` 读取并记录 `CFBundleDisplayName`、`CFBundleIdentifier`、`CFBundleShortVersionString` 和 `CFBundleVersion`，期望显示名为 `SpeechRail`、bundle identifier 为 `com.speechrail.desktop`。

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
3. 打开同一路径的 App，确认显示名、bundle identifier、version/build 和 control-agent 状态；用 UI 执行一次 `status`/`preflight` 只读控制，必要的 mutation 必须有单独授权。App 通过 `SMAppService` 管理 `com.speechrail.desktop.control`，不手工复制 plist、不直接调用 `launchctl`。
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
