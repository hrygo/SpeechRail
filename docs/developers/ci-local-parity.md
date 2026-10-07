---
title: "本地与 GitHub CI 一致性：PR #341 分析"
status: active
version: "1.0.0"
date: 2026-10-07
---

# 本地与 GitHub CI 一致性

## PR #341 的直接原因

2026-10-07 核验，PR head 为 `0277bf0ffe19560686abffdadc34047697e9ef67`。
GitHub CI run `37623123708` 的 `Quality Gates` job `112798072751` 在
`Check macOS test target coverage parity` 失败：

```text
SelectionLoadTests.swift exists but the Xcode unit-test target does not compile it;
`xcodebuild test` silently runs fewer suites than `swift test`
```

同一 run 的 `Swift Package Tests` 和 `macOS App Build` 均成功。
`Gate Summary` 因 `Quality Gates` 失败而失败；它不是第二个独立缺陷。
Python 测试和 wheel 打包因该 PR 只涉及 Swift/UI/设计文档而被正确跳过。

证据入口：

- [PR #341](https://github.com/hrygo/SpeechRail/pull/341) 的原始验证说明。
- [Quality Gates 日志](https://github.com/hrygo/SpeechRail/actions/runs/37623123708/job/112798072751)。
- `scripts/check_macos_test_target_coverage.py` 的实际清单比对规则。
- `macos/SpeechRailApp/Package.swift` 与 Xcode `project.pbxproj`。

## 为什么本地通过没有覆盖这个错误

PR 原始本地验证说明列出的检查是定向 `swift test --filter`、Debug App 构建和
`git diff origin/main...HEAD --check`。这组检查全部通过，仍不足以称为完整 CI 通过。

| 检查 | 实际证明的内容 | 对这次漏项的结果 |
|---|---|---|
| 定向 SwiftPM 测试 | 过滤出的测试可编译且通过；测试 target 自动收集目录中的 Swift 文件 | 新文件自动进入，测试可通过 |
| Xcode App 构建 | App target 和其依赖可编译、链接 | 不编译单元测试 target，无法发现漏注册 |
| `git diff --check` | 差异没有空白错误 | 不理解 Xcode target 的测试成员 |
| 测试清单门禁 | SwiftPM 目录与 Xcode 单测 Sources phase 一致，只有明确 allowlist 例外 | 准确发现 `SelectionLoadTests.swift` 漏注册 |

项目保留 SwiftPM 和 Xcode 两份测试入口。当前 Xcode 工程使用显式文件引用及 Sources phase，
新增磁盘文件不会自动进入该 target。这次新增测试只更新了磁盘，没有更新第二份清单。
GitHub 专门执行清单门禁，本地验证记录遗漏它，形成了错误的“检查已等价”预期。

开发文档此前也各自维护简化的命令块，部分只检查 `ruff src tests` 或只列
OpenAPI lint，没有覆盖 GitHub 中的所有独立检查。这是流程容易再次漏项的原因。
没有证据表明本次失败由 macOS/Ubuntu、编译缓存或依赖版本差异造成；
同一 PR 源码在本 Mac 直接运行清单检查，也稳定复现同一条错误。

## 提交、依赖和缓存的差异如何判断

GitHub 这次实际 checkout 的是 PR 合并预览
`69a31f4958ff9b10f6f1abd1d05ff9c93904d27b`，日志记录其父输入为上述 PR head 和
base `3a4cb71357095cdb5a92d05630e86a07d4c9a27d`。PR head 本身已经包含该 base；
两者经 GitHub commit API 与本地 Git 核对，tree SHA 均为
`0f9ba0dd4ca7b563a5942aa1265779b0263c0aed`，合并预览不是直接原因。

对于其他失败，需要先比对 source tree，而不是只对照分支名。main 在本地验证之后推进，
会让 PR 合并预览包含不同输入。`git diff --check` 也要检查实际 PR 差异，不能只检查干净工作区。

GitHub Quality job 使用 Ubuntu 24.04、Python 3.14.7、uv 0.12.13 及锁定依赖；
本机使用 macOS 27、Swift 6.4、uv 0.12.18。工具链差异可能影响其他检查，
但本次失败脚本只读取跟踪文件，无平台编译、网络或缓存依赖，不能将其归因于环境。
本机 App 构建通过同样不能证明 GitHub 的 macOS 26 工具链构建通过。

## 本次修复与防复发

1. 将 `SelectionLoadTests.swift` 加入 Xcode 测试文件组和单测 Sources phase，
   保留原清单门禁与 allowlist，没有减少检查范围。
2. 新增 `scripts/ci_quality_gate.sh`，本地与 GitHub `quality` job 调用同一份命令。
   锁定依赖后所有 Python 检查使用 `--no-sync`；每项有独立日志 group，失败立即返回。
3. `macos_app_build.sh` 创建产物前运行清单门禁，让原有本地构建命令也能拦住漏注册。
4. 更新开发指南、贡献指南及测试规范，区分 Quality Gates、测试、覆盖率与 App 构建。
5. 增加确定性回归，检查质量脚本在依赖、Lint、清单、pytest、空白检查失败时
   保留失败退出码并停止后续步骤；构建前置检查失败时不能启动 Xcode。

本地使用：

```bash
bash scripts/ci_quality_gate.sh --base-ref origin/main
swift test --package-path macos/SpeechRailApp --filter 'TeleprompterSessionLifecycleTests|SelectionLoadTests'
bash scripts/macos_app_build.sh --configuration Debug
```

`origin/main` 必须先同步；定向 Swift 测试只证明所选范围。完整 CI 结论仍须对应提交在
GitHub 的全部选中 job 成功，不能由这些本地命令替代。

## review bot 的两个应用缺陷

`discardPendingVersion()` 清空已保存的候选稿却未安排保存，`draftSaveState` 仍为 clean；
新的切稿优化于是跳过写盘，重新打开原稿后恢复被丢弃的候选。修复为清空候选后安排保存，
让防抖保存及切稿前 flush 共用既有流程，继续保留干净切稿不重复写盘的优化。
磁盘重载回归在修复前失败，修复后通过。

助手记录加载失败的提示此前只在 `liveChatWorkbenchCard` 渲染，而失败后页面可能
处于 review 或 ready。修复为页面级错误提示，保留失败目标及重试入口；
无当前记录时继续显示明确失败页，已有记录时保留旧正文。快速切换、返回当前记录、
关闭回看与离开页面仍由请求代次失效旧回复，不让迟到错误覆盖最新选择。

## 验证边界

首次修复推送 `77dd60c6` 后，GitHub run `37634015020` 的质量门禁与 Swift 测试通过，
完整 Python 测试发现一处遗漏：`test_github_workflows.py` 仍要求分人回归路径直接出现
在 workflow YAML 中，没有随共享脚本迁移更新断言。结果为 1 failed、3645 passed、
1 skipped。本地运行该测试也复现同一失败，仍属于验证范围遗漏。
后续修复检查 workflow 实际调用共享脚本，再校验脚本内保留两个分人回归入口；
共享质量门禁同时运行 workflow、质量脚本、App 构建前置、测试清单与变更范围回归。
补充修复后的本地共享门禁全部通过，其中 CI/workflow 回归 64 个、分人契约回归 20 个。

2026-10-07 本地确定性验证：86 个 Swift 定向测试、46 个 CI/清单测试，
共用质量门禁（含 20 个分人契约回归）通过。Xcode 工程通过 `plutil -lint`。
Debug App 使用仓库包装脚本构建，结果为 `BUILD SUCCEEDED`，临时构建产物由脚本清理。
共用脚本和构建脚本通过 `bash -n`，workflow YAML 及共用入口引用解析通过。
以上不代表真实 UI、VoiceOver、模型质量、性能或长时稳定性验收。
本地验证阶段没有修改服务运行态、安装 App、运行 UI 自动化或发布远端修改；
新的 GitHub CI 结果须在修复提交推送后另行核验。
