---
title: "有声书工坊（Audiobook Workshop）测试与验收交接手册"
status: active
audience: "QA 测试团队、客户端验收工程师、发布门禁负责人"
version: "1.0.0"
date: 2026-10-14
---

# 🧪 有声书工坊（Audiobook Workshop）测试与验收交接手册

本文档面向负责执行自动化测试、编译验证、性能压测与桌面人工走查的测试团队。有声书工坊（T01–T14）的全部业务代码、SwiftUI 视图、Python 媒体导出管线、单元测试与端到端验收测试代码均已落盘并通过静态契约检查；测试团队可按本手册分阶段执行验证并记录实测证据。

## 1. 已完成的静态门禁基线（已验证通过）

在交接前，以下静态契约门禁已在本机验证通过：

| 检查项 | 命令 | 状态与结论 |
|---|---|---|
| macOS 路由与快捷键契约 | `python3 scripts/check_macos_route_contract.py` | **PASS**（15 个路由枚举、15 个快捷键规格、15 项 UI 测试入口、15 项设计矩阵对齐） |
| Xcode 单测 Target 覆盖率检查 | `python3 scripts/check_macos_test_target_coverage.py` | **PASS**（全部 13 个 `Audiobook*Tests.swift` 及 22 个核心源文件均已同步注册到 `Package.swift` 与 `project.pbxproj`） |
| Git 差异格式与空白检查 | `git diff --check` | **PASS**（无尾随空格或冲突标记） |

## 2. 自动化测试清单与执行命令

### 2.1 Python 媒体导出套件（T11）

覆盖 `audiobook_media_export_v1` 清单解析、路径越界/符号链接拦截、分块 SHA-256 校验、48 kHz WAV 流式拼接、M4B 章节轨 (`chpl`) 与分章 MP3 编码及 `ffprobe` 校验：

```bash
# 1. 代码风格与静态类型检查
uv run --no-sync ruff check src/speechrail/media src/speechrail/cli.py \
  tests/test_media_manifest.py tests/test_media_encoder.py tests/test_media_commands.py
uv run --no-sync mypy src/speechrail/media src/speechrail/cli.py

# 2. 运行 Python 媒体导出单元测试（含 300 章 M4B / MP3 合成校验）
uv run --no-sync pytest --no-cov \
  tests/test_media_manifest.py \
  tests/test_media_encoder.py \
  tests/test_media_commands.py -v
```

**重点验收点**：
- `tests/test_media_manifest.py`：拒绝 `../` 越界、拒绝符号链接、拒绝非本 `book_id` 目录下的 WAV、拒绝 SHA-256 不匹配的篡改音频、拒绝 >64 MiB 的超大 manifest。
- `tests/test_media_encoder.py`：验证 300 章合成 M4B 的章节数 (`len(chapters) == 300`)、采样率 (`48000 Hz`)、时长误差 (`<= 250ms`)，以及分章 MP3 的文件数量与 `manifest.json` 完整性。
- `tests/test_media_commands.py`：验证 `speechrail media encode-audiobook` CLI JSON 输出契约与错误码映射。

### 2.2 SwiftPM 模块级确定性单元测试（T01–T14）

所有有声书工坊核心逻辑均位于 `SpeechRailAppSupport` 与 `SpeechRailControlAgentCore`，不依赖真实网络、真实大模型或扬声器硬件，可通过 `swift test` 按模块筛选或全量执行：

```bash
# 全量运行有声书工坊 SwiftPM 测试套件
swift test --package-path macos/SpeechRailApp --filter "Audiobook|LLMProviderTests|ServiceContractTests|AppModelTests|AgentCoreTests|WindowLayoutPolicyTests"
```

也可以按任务模块逐项执行并记录结果：

| 任务编号 | 测试 Suite 名称 | 覆盖的核心契约与边界用例 | 单项执行命令 |
|---|---|---|---|
| **T01** | `AudiobookSourceTests` | UTF-8 半开字节区间 `[startByte, endByte)`、非标量边界拒绝、大文件分块读取不常驻内存、稳定哈希 | `swift test --package-path macos/SpeechRailApp --filter AudiobookSourceTests` |
| **T02** | `AudiobookImportTests` | UTF-8 / BOM / UTF-16LE / UTF-16BE / GB18030 流式转码、CRLF/CR 归一化、>64 MiB 拒绝、中英文章节识别、序章合并、无标题长文按句切分 | `swift test --package-path macos/SpeechRailApp --filter AudiobookImportTests` |
| **T03** | `AudiobookStoreTests` | SQLite WAL + 外键约束、1,000 段批量读写、`AudiobookAssetJournal` 崩溃恢复（清理 staged 与孤儿 WAV，保护已采用与可撤销历史 WAV） | `swift test --package-path macos/SpeechRailApp --filter AudiobookStoreTests` |
| **T04** | `AudiobookAnalysisPromptTests` & `LLMProviderTests` | `LLMModule.audiobook` 专用/全局回退与未配置拦截、章节理解与角色合并 JSON 契约、越界字节区间与无效置信度拒绝 | `swift test --package-path macos/SpeechRailApp --filter "AudiobookAnalysisPromptTests|LLMProviderTests"` |
| **T05** | `AudiobookAnalysisTests` | 跨章同名/别名合并、低置信度对白标记 `needsConfirmation` 并默认回退旁白、断点续跑与模型身份变更失效 | `swift test --package-path macos/SpeechRailApp --filter AudiobookAnalysisTests` |
| **T06** | `AudiobookCastTests` | 角色重命名/合并/拆分、单段台词改派、音色推荐打分、试听样本缓存、旁白+必选角色确认与试听门禁 | `swift test --package-path macos/SpeechRailApp --filter AudiobookCastTests` |
| **T07** | `AudiobookInvalidationTests` | ≤280 UTF-8 字节句子安全切分、单段重派/单角色换音色/章节拆分合并的最小脏标记传播（不重跑无关章节） | `swift test --package-path macos/SpeechRailApp --filter AudiobookInvalidationTests` |
| **T08** | `AudiobookProductionTests` & `ServiceContractTests` | 能力快照版本锁定、串行 TTS 合成、8 MiB 响应体积上限护栏、48 kHz 单声道 WAV 落盘、静音/削波检测、暂停/恢复与崩溃续作 | `swift test --package-path macos/SpeechRailApp --filter "AudiobookProductionTests|ServiceContractTests"` |
| **T09** | `AudiobookRevisionTests` | 单段重录候选生成、新旧候选试听对比、原子采用切换、一键撤销恢复原版、历史候选保护 | `swift test --package-path macos/SpeechRailApp --filter AudiobookRevisionTests` |
| **T10** | `AudiobookListeningTests` & `AppModelTests` | `SharedPlaybackOwner` 唯一播放权抢占、收听/试听自动暂停后台合成、跨切片无缝推进、章节跳转、断点续听持久化 | `swift test --package-path macos/SpeechRailApp --filter "AudiobookListeningTests|AppModelTests"` |
| **T12** | `AudiobookExportTests` & `AgentCoreTests` | `encodeAudiobookMedia` XPC 命令白名单与参数校验、输入 WAV 哈希/帧数预检、M4B/MP3 产物二次校验、损坏产物拦截 | `swift test --package-path macos/SpeechRailApp --filter "AudiobookExportTests|AgentCoreTests"` |
| **T13** | `AudiobookWorkflowTests` & `WindowLayoutPolicyTests` | `AudiobookWorkflowModel` 四阶段流转、书架/工作台/收听模式切换、响应式窗口布局契约 | `swift test --package-path macos/SpeechRailApp --filter "AudiobookWorkflowTests|WindowLayoutPolicyTests"` |
| **T14** | `AudiobookAcceptanceTests` | 端到端全链路闭环验收（导入 → 分章 → AI 理解 → 角色绑定与试听门禁 → 章节合成 → 单段重录采用与撤销 → 收听进度 → M4B/MP3 导出） | `swift test --package-path macos/SpeechRailApp --filter AudiobookAcceptanceTests` |

### 2.3 Xcode App 构建与 Xcode 单测目标验证

验证 SwiftUI 视图层 (`AudiobookWorkshopView`、`AudiobookBookShelfView`、`AudiobookBookWorkspaceView`、`AudiobookListeningView`) 在 `SpeechRailApp` target 下的完整编译及 Xcode 单测 target 闭环：

```bash
# 1. 编译 Debug 版 SpeechRailApp 并校验证书/签名与测试 target 覆盖
bash scripts/macos_app_build.sh --configuration Debug

# 2. 执行 Xcode 单测 target（可选，验证 Xcode 工程与 SwiftPM 一致性）
bash scripts/macos_app_build.sh --configuration Debug --test-unit
```

## 3. 桌面端人工 UI/UX 与真机听感验收清单

自动化测试通过后，请客户端测试同学在 macOS 26 真机上按以下清单走查 UI/UX 与真实模型体验：

1. **导航与快捷键 (`⌘5`)**：
   - 启动 `SpeechRail.app`，核对左侧边栏「创作」分组第 5 项为 **有声书工坊**（图标 `books.vertical`），按 `⌘5` 可直接切入；
   - 核对主菜单 `View` 下「有声书工坊」快捷键显示为 `⌘5`，顶部工具栏 `PageIdentityToolbarItem` 正确显示「有声书工坊」且正文不重复大标题。
2. **外观、动态字体与辅助功能**：
   - 在 Light / Dark 外观下分别核对书架卡片、四阶段步骤条、角色卡片、章节制作列表、720pt 段落返修弹窗与收听传输条的表面层级（`Color.canvas` / `Color.field` / `Color.recessedField` / `Color.inputField`）；
   - 开启 **Reduce Motion（减弱动态效果）** 后切换工作台阶段、打开/收起右侧详情面与收听视图，确认动画干净降级为即时切换；
   - 开启 **VoiceOver** 走查章节列表、角色卡「待确认」胶囊、段落行「重录」按钮与底部收听控制条，确认每个纯图标动作均有明确中文无障碍标签。
3. **真实 TXT 书稿与本地 Qwen3-TTS / LLM 全流程走查**：
   - 准备一本含多章节与人物对白的中文 `.txt` 小说（建议 3–5 章，涵盖旁白与 3 个以上角色）导入；
   - 在「设置 ▸ 助手」配置可用 LLM 后执行「开始全书角色分析」，核对角色提取、别名合并与「待确认」低置信度标注是否直观易懂；
   - 为旁白与主角绑定不同音色并点击「生成试听样本」，验证未完成试听确认前「生成全书」按钮给出明确引导提示；
   - 合成 1–2 章后进入 **收听模式**，验证正文随声音高亮滚动、切换倍速、关闭重开 App 后从上次停留位置继续播放；
   - 在收听模式或章节制作页对某一段点击「重录」，生成新候选并试听对比，点击「采用」后再点「撤销」，确认音频立即切回原版且无需重做整章；
   - 导出 `.m4b` 与分章 `.mp3`，在 macOS Finder QuickLook 或 Apple Books 中打开 `.m4b`，核对章节书签跳转与音质表现。

## 4. 问题记录模板与回滚指引

测试团队在执行过程中如发现失败项，请按以下格式记录并反馈：
- **复现阶段**：（Python 媒体测试 / SwiftPM 某 Suite / Xcode 构建 / 真机 UI 走查）
- **复现命令与日志摘要**：附上完整终端输出或截图
- **书稿样本特征**：编码格式、文件大小、章节数（切勿在公开 Issue 中上传受版权保护的完整商业书稿）
- **独立回滚边界**：有声书工坊的数据独立存储在 `<app_home>/audiobooks/`（`audiobooks.sqlite3` 及 `books/`、`exports/` 子目录），不影响配音台 (`dubbing/`)、音色库 (`voices/`) 或会议记录 (`sessions/`)。
