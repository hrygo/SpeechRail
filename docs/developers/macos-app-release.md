---
title: "SpeechRail macOS App 分发与签名"
status: active
version: "0.5.7"
date: 2026-09-24
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
| `SpeechRail.app` | SwiftUI 菜单栏/设置与会话控制面 | 用户按需打开 | **否** | 不加载模型，不启动服务；不在后台采集或播放音频，只有用户主动启用音色克隆、试听或会话功能时才按功能持有设备；会话 PCM 不落盘 |
| `com.speechrail.desktop.control` | Distribution App bundle 内的 `SpeechRailControlAgent` + `SMAppService` plist | XPC 控制 helper | 仅签名 Distribution 由 `SMAppService` 注册 | 不拥有 8201，不创建第二个 ASGI/worker，不替换服务 runtime |
| `com.speechrail.desktop.local-control` | Debug/Release App bundle 内的 `XPCServices/*.xpc` | 按需 XPC 控制 helper | 由 `NSXPCConnection(serviceName:)` 按需启动 | 不注册登录项，不拥有 8201，不创建第二个 ASGI/worker |
| `com.speechrail` | Python managed service LaunchAgent | SpeechRail 服务 | **是** | 不依赖 App 是否打开 |

`SpeechRail.app` 退出、更新或注销 control-agent 都不得停止、删除或覆盖 `com.speechrail`、`runtime/current`、selection、模型、私有 `.env` 或日志。服务发布与 App 发布可以独立回滚；联合发布时先完成服务 wheel 的 preflight/运行态验收，再验收 App 控制链路。

### 发布范围

“从制品安装”默认选择 `combined`；仅在用户明确限定单项时选择 `service-only` 或 `app-only`。

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

### 本机替换：用户自行验收

适用于已授权的本机 Debug/Release App-only 替换，且用户明确自行验收；不适用于 Distribution、服务替换或联合发布。
完成条件是正确产物已安装、静态校验通过且旧版可恢复，不包含 UI、控制链路或语音质量验收。

1. **定位一次。**核对目标路径（默认 `~/Applications/SpeechRail.app`）、现存候选 bundle 和来源证据。有对应最后一次源码改动的成功构建记录且产物仍在时复用；仅“文件较新”不够。源码变化、产物缺失或来源不明时才构建一次，不重跑已有且仍有效的测试。`macos_app_build.sh` 的普通 build 会清理临时 DerivedData，不能把已清理的验证产物当成可安装包。
2. **准备并校验。**核对候选显示名、bundle identifier、version/build、目标平台，并执行 `scripts/macos_app_verify_local_xpc.sh <候选 SpeechRail.app>`。旧安装归档到仓库外 ZIP，检查归档完整性并记录哈希；新候选已有 bundle 时无需为了本机替换额外压缩再解压。将候选准备到安装目录同一文件系统的唯一临时父目录，子目录始终叫 `SpeechRail.app`，例如 `<临时父目录>/SpeechRail.app`；验证脚本拒绝其他 bundle 名称。所有暂存路径先确认不覆盖既有内容，失败清理/恢复处理在创建暂存产物前就绪。
3. **退出并替换。**核实运行中 App 与随包 helper 的实际路径/身份，正常退出旧 App 并有界等待；不能只凭进程名判断归属，也不自动强杀。退出失败则保持旧安装并报告，不循环重试。将旧 bundle 暂存到同文件系统的唯一目录，再把新 bundle 重命名到安装路径；安装或静态校验失败则恢复旧 bundle。始终不触碰服务 runtime、selection、模型或登录项。
4. **验证并交还。**核对安装路径的身份/version/build、签名与内嵌 XPC，并确认安装内容对应已验证候选；归档后源包未变时不重复计算同一归档哈希。成功后清理本次事务创建的暂存副本，保留旧版 ZIP 回退点；运行 `scripts/macos_app_verify_single_install.sh <安装路径>`，确认 LaunchServices 仅登记该正式 App 且无 UI test runner 登记。若检查失败，只在任务授权覆盖时清理经确认归属、无进程使用的 SpeechRail 生成副本：对精确路径执行 LaunchServices 注销后直接删除，避免移入废纸篓造成再次发现；不清空整个废纸篓或触碰无关 App。未授权清理时报告重复路径并停止。不启动新 App，不查 `/health`、`/readyz`、服务 PID/端口或执行 UI `status`/`preflight`；检查通过后立即报告“已安装、未启动、待用户验收”、安装路径、版本和回退点，然后停止。

本机开发替换不自动 bump 版本，不代表正式发布通过。唯一登记检查限定在 SpeechRail bundle identifier，不做全盘 App 清理；既有副本仅在用户授权范围覆盖清理时处理。清理前核实精确路径、版本/来源和进程占用；清理后再次运行唯一登记检查。安装成功与用户验收通过必须分别表述。

### GitHub 制品安装

本项目的“从制品安装”默认安装**全套：服务 wheel + macOS App（combined）**，不是 App-only。
只有用户明确要求“只装 App”或“只装服务”才缩小范围；单个资产链接不自动缩小范围，应定位同一发布的配套制品。
这是安装入口，不是再次发布或本地重建。制品名称与校验文件以
[Release workflow](../../.github/workflows/release.yml) 和安装时的远端元数据为准：

| 来源 | 锁定的身份 | 全套下载集 |
|---|---|---|
| GitHub Release | 确认的仓库、release/tag、对应 commit 和两个目标 asset ID | 同一 release 的 `speechrail-<version>-*.whl`、`SpeechRail-<version>-macOS-arm64.dmg` 与 `SHA256SUMS` |
| GitHub Actions | 确认的仓库、workflow、run ID/attempt、head SHA 和两个 artifact ID；相关构建/验证成功且 artifacts 未过期 | 同一发布 run 的 `speechrail-wheel`（wheel + `wheel.SHA256`）和 `speechrail-macos-dmg`（DMG + `dmg.SHA256`）；不使用未通过最终验证的 `speechrail-wheel-candidate` |

1. **一次选定。**用户指定 tag/run/asset 就按该来源获取，不改选同名或“最近”产物。仅说 GitHub 安装且未指定来源时优先正式 Release；要求“最新”时查询当时的非草稿、非预发布 Release 并报告所选 tag，再固定两个具体 assets，下载中不继续追逐 latest。预发布或 Actions 按用户指定范围选择；目标不唯一才询问。全套两个制品必须对应同一发布版本和源码身份，不拼接不同 tag/run 的产物。远端制品不含未发布的本地 UI 修改，若用户同时要求安装这些修改，先解决来源冲突。
2. **成套下载与校验。**使用已连接 GitHub 工具或已有认证的 CLI，将两个制品及校验文件下载到仓库外唯一目录；已缓存的同身份制品通过摘要校验即可复用，不下载无关 artifacts 或源码。Release 从 `SHA256SUMS` 提取两个目标文件各自唯一、精确文件名条目核对 SHA-256；显式单项安装时仅核对该项，不为校验补下未请求的另一项。Actions 若下载 ZIP，仅安全解出目标 artifacts 到临时目录，拒绝越界路径，分别用 `wheel.SHA256` 和 `dmg.SHA256` 校验内层制品；外层 ZIP digest 不能替代内层摘要。校验文件只当数据读取。条目缺失/重复、下载不完整、版本不配套或摘要不符时停止，尚不退出 App 或停止服务。
3. **提前准备两个候选。**核对 wheel 的包身份/版本与所选发布证据；用 `hdiutil attach -readonly -nobrowse` 将 DMG 挂载到本次唯一挂载点，预设失败时 detach。将卷内 `SpeechRail.app` 准备到安装目录同一文件系统的暂存父目录，bundle 名保持 `SpeechRail.app`；核对其身份/version/build、平台、签名与内嵌 XPC。DMG 的 `Applications` 链接不改变默认 `~/Applications/SpeechRail.app` 目标。版本与所选 release/tag 或 run 证据对应，不与当前工作区 `pyproject.toml` 强行比较。无需重打 ZIP、重签名、pull/切换源码或本地重建/跑测试。
4. **先服务，再 App。**两个制品准备好后，按 [发布 Skill 第 3 节](../../.agents/skills/speechrail-release/SKILL.md#3-安全替换-managed-服务) 与 operator contract 确认 managed runtime、活动请求/客户端及回退点，使用受支持的安装入口替换服务、启动并验证 ready 和身份；不套用 App-only 跳过服务检查的规则。服务通过后，复用上方 App 快路径第 2 步的旧版备份及第 3–4 步替换/静态验证，跳过已完成的候选检查和本地构建定位。显式单项请求只执行对应事务。“我来验收”不取消服务安装验证，但 App 交互/视觉验收由用户进行，不自动启动 App 或执行 UI 自动化。
5. **按单元收尾。**服务失败则停止，不替换 App，按服务回滚流程处理；服务成功、App 失败则只恢复旧 App，不自动回退已通过的服务。卸载本次 DMG、清理本次暂存，保留两套回退点、来源/tag 或 run/artifact 身份和两个制品哈希；卸载失败单独报告，不强制卸载其他卷。立即分别报告服务版本与 ready/身份结果、App 版本与安装结果、回退点和待用户验收项；任何一项失败都不能报告“全套安装完成”。

全套安装不自动切换 profile、下载模型、注册全新服务或执行性能/质量基准；全新机器另走首装流程，
缺少必要模型/配置时说明阻碍，不静默改变用户运行配置。必要 smoke 仍按原授权范围执行，不把 ready 当作质量验收。
当前工作流交付 ad hoc App，同源 checksum 证明完整性，不等于 Developer ID 身份、公证或 Gatekeeper 放行。
不得删除 quarantine、关闭 Gatekeeper 或重签名绕过安全提示；遇到阻止时说明来源和签名状态，交由用户按系统流程决定。
制品缺失、过期或构建未完成时保持原安装，报告具体阻碍；不无限轮询、不擅自 rerun workflow、
换 run/版本、改为本地重建或只装其中一项充当全套。

### 正式发布与另行授权的运行验收

以下按发布单元及验收授权选用，不是本机替换的必跑清单。UI 自动化仍须当前用户明确要求；
未获 UI 验收授权时交由用户执行，不因 SOP 步骤自行接管窗口。

1. 联合发布先完成服务的 `/health`、`/readyz`、`/v1/models`、`/v1/voices` 和目标 smoke；App 不能替代服务验收。
2. 退出旧 `SpeechRail.app`，将最终 ZIP 解出到临时目录，确认 bundle identity/version 后，只安装一个 bundle 到用户路径 `~/Applications/SpeechRail.app`；若使用其他路径，必须在 evidence 中明确记录。上一版本保留为 ZIP/归档制品，不作为第二个长期可执行 `.app`。
3. 在运行验收范围已获授权时打开同一路径的 App，确认显示名、bundle identifier、version/build 和 control-agent 状态；用 UI 执行一次 `status`/`preflight` 只读控制，必要的 mutation 必须有单独授权。Debug/Release 应验证内嵌 `com.speechrail.desktop.local-control.xpc`；签名 Distribution 才通过 `SMAppService` 管理 `com.speechrail.desktop.control`。两种模式都不手工复制 plist、不直接调用 `launchctl`。
4. 联合发布或明确要求检查服务独立运行时，关闭 App 后再次检查 `com.speechrail`、唯一 8201 listener、`/health` 和 `/readyz`；App/Agent 退出不能停止服务。
5. 按已授权范围清理本次可确认归属的 staging、DerivedData、`build/macos-derived-data`、未交付 archive/export 和旧测试 bundle；保留最终 ZIP、哈希、签名/公证结果及脱敏 evidence。不要删除服务 app home、`runtime/releases`、模型、selection、私有配置或日志，也不要全局重置 LaunchServices。

```bash
mdfind 'kMDItemCFBundleIdentifier == "com.speechrail.desktop"'
mdfind 'kMDItemFSName == "SpeechRailApp.app"'
```

上面的 Spotlight 查询用于已授权的 bundle 整理，不是本机替换的默认门禁。清理本次产物后核对唯一安装路径
（默认 `~/Applications/SpeechRail.app`）；搜索结果可能仍含既有构建副本或缓存，须核实实际路径和存在性，
不能仅据此判定安装失败。Finder 出现多个 App 时，区分安装、DerivedData、archive/export 与 staging，
只处理已确认归属且获授权的副本，不盲删。正式交付包仍不得使用旧 `SpeechRailApp.app` 命名。

## 回滚

- **App-only 失败**：退出新 App，将上一份已验证 ZIP 恢复到同一安装路径；按 `SMAppService`/System Settings 核对 control-agent 状态，服务 `runtime/current`、selection、模型和 `com.speechrail` 不变。
- **服务-only 失败**：按 [版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md) 恢复旧 `runtime/current`、selection 和 LaunchAgent；不要为了服务回滚删除 App。
- **联合发布失败**：服务验收通过而 App/XPC 失败时只回滚 App；服务失败时先恢复服务，再按需要恢复兼容 App。不能用 App 回滚替代服务回滚，也不能因 App 安装失败删除服务数据。

回滚验证仍按原任务范围：App-only 用户自行验收只复核安装路径、version/build、签名与内嵌 XPC，保持 App 未启动；运行验收或联合发布才执行已授权的 helper/服务独立运行与 health/ready 检查。保留失败制品和原因摘要。

## 参考

- [SpeechRail 版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md)
- [SpeechRail macOS App 开发与测试](macos-app-development.md)
- [本机 operator contract](../../.agents/skills/speechrail-local-deploy/references/operator-contract.md)
- [Apple：SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple：Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
