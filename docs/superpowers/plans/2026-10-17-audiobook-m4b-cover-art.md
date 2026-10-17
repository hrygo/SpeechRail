---
title: "有声书 M4B 封面（Cover Art）实施方案"
status: active
version: "1.0.0"
date: 2026-10-17
audience: "系统架构师、Python 媒体子系统与 macOS 核心开发者、产品决策者"
---

# SpeechRail 有声书 M4B 封面（Cover Art）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「有声书工坊」的整本 M4B 导出可选地写入用户提供的封面图（cover art），在 Apple 图书／播客播放器中可见，同时保持无封面路径与当前输出逐字节一致。

**Architecture:** 封面只作为 `books/<book_id>/cover/` 下的书籍自有静态资产存在，经 `audiobook_media_export_v2` 清单以「相对路径 + 图像 SHA-256」传给既有的受控 XPC 媒体子系统；Python `encoder.py` 在既有 FFmpeg 封装（FFMETADATA 章节轨 + `aac` + `faststart+disable_chpl`）上追加一个 attached-picture 视频流，Swift `AudiobookMediaVerifier` 用 AVFoundation 复核封面存在／缺失状态。

**Tech Stack:** Python 3.14（`uv`、pytest、ruff、mypy）· FFmpeg（经 `discover_media_toolchain` 定位，不下载）· Swift 6 / SwiftUI framework target + XCTest（SwiftPM 与 Xcode 双跑）· AVFoundation。

**Spec:** `docs/audits/2026-10-17-speechrail-voicestudio-competitive-research.md`（§4 P0-2、§5.1）与 `docs/audits/2026-10-17-speechrail-elevenlabs-absorption-plan.md`（P0 候选边界）。**注意：这两份文件当前只存在于主工作区 `codex/speechrail-ux-redesigns` 的工作树（一份已跟踪并修改、一份未跟踪），不在本分支内；实施者需回主工作区只读查阅，不得复制或提交到本分支。**

---

## 0. 本文件性质、授权边界与事实来源

- 本文件是**方案（plan）**，只定义要做什么、改哪些文件、用什么测试证明。**成文轮未修改任何产品代码／契约／测试／其他文档，未新增或运行任何测试，未运行 build／服务／模型／benchmark／UI 自动化，未提交或推送。**
- 核验基线：SpeechRail `codex/speechrail-ux-redesigns` @ `4b52697e`（核验日期 2026-10-17）。所有 `path:line` 结论均在该提交上直接读取源码得到。
- 证据分层沿用竞品报告的约定：**【代码实测】**＝直接读源码；**【报告观点】**＝审计报告的判断，本轮未逐条复现；**【待定】**＝需产品决策或实测升级。
- **结构化核对边界（诚实披露）**：本轮 `codebase-memory` MCP 的图查询（`search_graph` 等）在 Code Mode 运行时返回不可解析的载荷，无法作为独立证据；工具侧自动注入的图符号上下文仅确认了 `TtsTextPlanner`（`src/speechrail/domain/tts_text_planner.py`，Class）、`AudiobookExportManifestPayload`（`macos/.../MediaExportTypes.swift`，Struct）、`AudiobookExportController`（Class）、`AudiobookDomain.intermediateSampleRate`（Variable）与 `audiobook-workshop` 相关 Section。**本节结构性结论以 `4b52697e` 上的直接源码读取为准**，未依赖图查询。

---

## 1. 三候选比较与推荐

三个 P0 候选来自竞品报告 §4/§5。下表把报告观点与本轮代码事实对齐，并按「本项目实际收益 / 代码改动面 / 接口与数据风险 / 未决产品决定」四轴比较。

| 轴 | P0-1 通用成品响度处理 | **P0-2 M4B 封面** | P0-3 密集脚本感知分块 |
|---|---|---|---|
| 实际收益【报告观点+代码实测】 | 中。让成品电平一致、减少后期；但**不得**以 ACX 为卖点（ACX 明确限制未授权 TTS/AI 音频，且 RMS 与 LUFS 不可直接互换）。 | **高**。M4B 是旗舰交付物，已有章节轨与书名元数据；封面是播放器里最直接可见的成品感提升，且不改动共享 TTS/planner 路径。 | 中，且**未经证明**。报告自身指出 VoiceStudio 做法是"整段密度门控、非逐块自适应"，收益需离线评估才能确认。 |
| 代码改动面【代码实测】 | `media/encoder.py`（loudnorm 单遍/两遍 + 采样率恢复 + `dual_mono`）、`manifest.py`（新档位字段）、Swift payload + 导出 UI 开关。两遍需测量回传与降级策略。 | `media/manifest.py`（v2 schema + 封面允许路径/摘要）、`media/encoder.py`（追加 attached-pic 输入与映射）、Swift `MediaExportTypes`/`AudiobookExportController`/`AudiobookMediaVerifier` + 一个新封面资产存储 + 导出 Sheet 一个选择行。**全部落在既有有声书导出管线内，不触碰 REST/Realtime 契约与共享 planner。** | `domain/tts_text_planner.py`（密度维度）、`render_recipe` 的 planner revision、`capability_snapshot`、用户文档，以及 REST/Realtime/有声书 timing 的大量回归。**爆炸半径覆盖整条 TTS 路径。** |
| 接口与数据风险【代码实测】 | 高。目标单位（RMS/LUFS/peak）、测量范围（单章/整书）、是否保持章间相对响度都未定；loudnorm 动态模式可能升采样到 192 kHz；成品归一可能与既有"按请求冻结增益"并存造成二次归一争议（`docs/architecture/quality-voice-capabilities.md:163` 明载"只做一次基于有效语音的增益/响度处理，避免重复归一"）。 | 中且**有界**。核心风险是 manifest schema 演进（当前只认 `audiobook_media_export_v1`）与旧服务版本漂移下的**静默丢封面**；可通过 v2 版本协商 + verifier 兜底做成 fail-loud。封面是嵌入在 m4b 内的二进制，输出 SHA-256 天然覆盖它，不新增独立安装物。 | 高。planner 版本号是对外可见语义（`docs/users/effective-capabilities.md:135-141` 的 `operations.tts_text_planner`），且坐标语义被 timing sidecar 与 App 角色边界共享；改错会污染多处坐标。 |
| 未决产品决定 | **多**：目标单位、测量范围、单/两遍、默认值、是否保持相对响度、与"只做一次归一"的关系。 | **少（1 个主决定）**：坏封面策略（fail-loud vs 省略并警告）。其余（封面来源、MP3 范围）由本方案给出推荐默认。 | **多**：阈值、是否逐块决策、是否引入不可发音合并/丢弃、是否触及最大 240 上限。 |
| 结论 | 先补齐产品决策，暂不实施 | **推荐优先实施** | 先做离线评估，暂不实施 |

### 1.1 已核实的报告观点与代码事实差异

| 报告表述 | 本轮代码事实 | 处置 |
|---|---|---|
| "`audiobook_media_export_v1` 是**闭合 schema**，拒绝未知 schema" | 准确但需限定：`manifest.py:186-190` 拒绝**不同的 `schema_version` 字符串**；对**顶层未知键是忽略**（全程 `payload.get(...)`），并非 `additionalProperties: false` 式整体封闭。【代码实测】 | 这恰好是"静默丢封面"风险的来源，故本方案采用 v2 版本协商而非"加个可选字段" |
| "`encoder.py` 未发现 `loudnorm`/`lufs`/`acx`/`cover`/`artwork`" | 成立。`src/` 内 `\bloudnorm\b|attached_pic|dual_mono|artwork|LUFS` 零命中；m4b argv 仅 `-map 0:a:0 -map_metadata 1 -map_chapters 1` 三路映射并带 `-vn`。【代码实测】 | 确认从零新增封面能力；并确认需要**去掉 `-vn`** 才能挂 attached picture |
| "输入路径仅允许 book-owned WAV" | 成立。`manifest.py:99-133` 要求相对路径恰为 `books/<book_id>/audio/<file>.wav`（4 段、`.wav` 结尾），并拒符号链接、越界、非普通文件。【代码实测】 | 封面需要**新增一类允许路径**（`books/<book_id>/cover/`），不能复用 WAV 规则 |
| "planner 默认上限 240 codepoints，无密度维度" | 成立。`TtsTextPlanner.max_chars: int = 240`，`PLANNER_VERSION = "tts_bounded_v1"`；`render_preparation.py:41,82` 以默认值实例化；`effective-capabilities.md:135-141` 已对外声明。【代码实测】 | 作为 P0-3 的评估基线 |
| "嵌入封面属 ffmpeg 常规能力" | 方向正确，但**非零风险**：需新增第二路输入并移除 `-vn`，改动 `-map` 集合；`-movflags +faststart+disable_chpl` 与音频参数须保持不变。【代码实测】 | 在本计划中把精确 argv 定为固定决策 |

### 1.2 推荐结论

**优先实施 P0-2（M4B 封面）**，理由是四条同时成立：①收益直接作用于旗舰交付物且用户可见；②改动完全局限在既有有声书导出管线内，不扰动共享 TTS/planner 与任何公共 REST/Realtime 契约；③风险可以用"v2 版本协商 + verifier 兜底"收敛为有界、fail-loud；④未决产品决定最少（实质只有一个：坏封面策略）。

P0-1 与 P0-3 的后续进入条件见 §4，二者与 P0-2 **相互独立**，互不为前置。

---

## Global Constraints

以下为跨任务必须遵守的项目级约束（值取自当前仓库事实源，逐条为硬约束）：

- Python `>=3.14,<3.15`；依赖与虚拟环境一律经 `uv`（PEP 621）。
- 请求路径**不得**下载模型、读取远程音频 URL 或静默访问网络；封面必须是本机书籍自有文件。
- 日志／fixture／报告**不得**记录 API key、`Authorization`、原始音频、Base64、完整 prompt／转写、embedding、实名 speaker 或绝对模型路径。封面二进制**不得**进入日志、fixture 或测试制品。
- 模型 snapshot、`.env`、音频、日志、custom voice、benchmark 原始制品只放仓库外；本方案不得把这些写进仓库。
- 一次只运行一个服务与一个 ASGI worker；本方案不新增常驻模型、不新增推理并发。
- 公共错误使用稳定 envelope 并含 request ID；本方案**不新增**公共 HTTP/Realtime 字段或事件。
- 会产出 `.app` 的构建／测试必须走仓库包装脚本，不得裸跑 `xcodebuild` 留下可被 LaunchServices 识别的副本。
- **UI 自动化（XCUITest／点击驱动／窗口断言／录屏）必须由当前用户逐次明确授权**；skill、计划与发布流程不构成授权。
- macOS UI 遵循 `docs/developers/macos-app-design-system.md`；运行时设计 Token 唯一声明点是 `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`；页面不得散落裸视觉常量。
- 界面文案按目标受众用用户语言，先说明"发生了什么／是否需确认／下一步"；高级项渐进披露。
- 文档命名：本计划属 `docs/superpowers/plans/`，格式 `YYYY-MM-DD-<slug>.md`。
- **双构建清单同步**：新增 macOS 源码文件必须同时登记到 `Package.swift` 的 `SpeechRailAppSupport.sources` 与 `project.pbxproj`（app `Sources` + 单测 `Test Sources`）；新增测试文件必须被 Xcode 单测 target 编译，否则 `scripts/check_macos_test_target_coverage.py` 失败。本方案通过"不新增测试文件"把该面收敛为一个新源码文件的登记。

## Review Focus

以下五类输入或失败模式，是规格未逐条列举、但最可能在使用中咬人的地方（按可能性降序）。每一项都在 §3 的对应任务里有断言它的测试：

1. 用户选了一个**明显不是图片**的文件（`.txt`／`.heic`／`.pdf`）→ 期望**明确失败并说明原因**，而不是静默导出无封面书。
2. 用户选的图片**损坏或不可解码**（截断的 jpg）→ 期望导出失败并给出可理解原因，而不是产出无封面或损坏的 m4b。
3. 导出目标服务是**旧版本**（不认 `audiobook_media_export_v2`）而请求带封面 → 期望**可见失败**（提示更新服务），而不是静默丢掉封面后报成功。
4. **分章 MP3 请求同时带封面** → 期望在写清单前就明确拒绝并解释（本阶段 M4B 专属），而不是把封面塞进 MP3 或被忽略。
5. 封面在 `prepare` 之后、`commit` 之前**被外部改动或删除** → 期望以已记录的存在性／SHA-256 核对发现并拒绝安装，且**不覆盖**目标文件。

---

## 2. 推荐项（P0-2）的文件结构与改动面

**Python（`src/speechrail/media/`，无新文件）**
- `manifest.py`（改）：新增 `audiobook_media_export_v2`、封面允许路径与摘要校验、封面体积上限、v1/v2 一致性规则。
- `encoder.py`（改）：m4b 路径在有封面时追加 attached-picture 输入与映射；无封面路径 argv 与今天逐项一致。

**Swift（源码）**
- `macos/SpeechRailApp/SpeechRailControlKit/MediaExportTypes.swift`（改）：`AudiobookExportManifestPayload.CoverItem` 与可选 `cover`，以及 schema 版本随封面切换。
- `macos/SpeechRailApp/SpeechRailApp/AudiobookCoverAssetStore.swift`（**新建**）：书籍自有封面资产的安全落盘与读取。
- `macos/SpeechRailApp/SpeechRailApp/AudiobookExportController.swift`（改）：`prepare` 透传封面、`AudiobookPreparedExport.expectsArtwork`、MP3+封面预拒绝。
- `macos/SpeechRailApp/SpeechRailApp/AudiobookMediaVerifier.swift`（改）：AVFoundation 复核 artwork 存在／缺失，并对外暴露 `artworkPresent`。
- `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkshopView.swift`（改）：导出 Sheet 增加封面选择行（`selectedProfile` 当前在 `:354`；该 Sheet 在 UX 规格中名为 `AudiobookExportSheet`）。
- `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift`（改）：`prepareExport(...)` 增加封面参数与状态（当前见 `:2822`；控制器构造在 `:374`）；`trashBook`/`restoreTrashedBook` 产品路径见 `:859`/`:882`。

**Swift（构建清单，必须改）**
- `macos/SpeechRailApp/Package.swift`（**改**）：`SpeechRailAppSupport` target 使用 `path: "SpeechRailApp"`，**同时**有 `exclude:`（`:41-89`）**与显式 `sources:` 列表**（`:90-264`）。因此**新源码不会自动发现，必须把 `"AudiobookCoverAssetStore.swift"` 加入该 `sources:` 数组**（放在 `AudiobookDomain.swift` 附近，与其它 `Audiobook*` 条目同区）。
- `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`（**改**）：`AudiobookCoverAssetStore.swift` 需按现有模式登记——新增一条 `PBXFileReference`，并各新增一条 `PBXBuildFile` 编入 app target 的 `Sources` phase 与 Xcode 单测 target 的 `Test Sources` phase（沿用 `AudiobookMediaVerifier.swift`/`AudiobookExportController.swift` 的既有三件套写法，当前见 pbxproj `:329-330`、`:372-373`、`:494-497`、`:903-904`），并加入对应 group。

**测试（不新增测试文件，全部落在已登记文件）**
- `macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift`（既有，Task 3）
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookStoreTests.swift`（既有，Task 4 与封面生命周期回归；`AudiobookProjectStore` 级）
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookExportTests.swift`（既有，Task 5/6）
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookWorkflowTests.swift`（既有，Task 7；`AudiobookWorkflowModel` 级）

> `SpeechRailMacControlTests` target 在 `Package.swift` 中只有 `path:`、无 `sources`/`exclude`，SPM 会自动发现新测试文件；但 Xcode 侧需显式 phase 登记，且 `scripts/check_macos_test_target_coverage.py` 会强制"磁盘上的每个测试文件都必须被 Xcode 单测 target 编译"（`UNIT_TEST_TARGET_NAME = "SpeechRailAppTests"`）。**故本方案不新增 Swift 测试文件**，避免为此再改 pbxproj（取代方案：若坚持新建 `AudiobookCoverAssetStoreTests.swift`，必须同时在 pbxproj 的 `Test Sources` phase 与 group 登记，否则该检查会失败）。

**文档同步（实施阶段，不是本轮）**
- `docs/developers/macos-app-audiobook.md` §1.3／§2（媒体子系统与不变量）、`docs/architecture/audiobook-workshop.md` §2.6（受控 XPC 媒体封装）、`docs/developers/audiobook-workshop-testing-handover.md`（测试清单）。

### 2.1 复核补充：项目实际约束（第二轮，已核实）

以下四条为主工作区对照 `4b52697e` 源码核实的事实，并已并入上面的文件列表与任务步骤：

1. **双构建清单**：SwiftPM 侧 `SpeechRailAppSupport` 用**显式 `sources`**（非自动发现），`SpeechRailMacControlTests` 用自动发现；Xcode 侧 `project.pbxproj` 用显式 `PBXBuildFile`/`PBXFileReference`/group/source phase，且有声书 app 文件同时编入 app 与单测 target。**新源码文件必须同时登记到 `Package.swift` 的 `sources` 与 `project.pbxproj` 两处。**
2. **trash 生命周期自然携带封面**（【代码实测】）：`AudiobookProjectStore.trashBook(id:)`（`:1752`）把整个 `books/<id>` 目录 `moveItem` 到 `<root>/.trash/<uuid>-<ts>`，并写入 `trash-snapshot.json`/`trash-meta.json`；`restoreTrashedBook(id:)`（`:1819`）把该目录整体移回并删除两个 sidecar；`permanentlyDeleteTrashedBook(id:)`（`:1853`）删除废纸篓目录。因此 `books/<id>/cover/` **无需任何新代码即随书移动/恢复/删除**。产品路径 `AudiobookWorkflowModel.trashBook`/`restoreTrashedBook` 见 `:859`/`:882`。
3. **工作区切书路径**：`AudiobookWorkflowModel` 的 `selectedBook`/`surfaceMode` 与 `trashBook`/`restoreTrashedBook` 是既有切书入口；封面选择必须按 book 归属（Task 7）。
4. **`FakeMediaRunner.raise_on_final_encode` 已存在**（【代码实测】`tests/test_media_encoder.py:54` 定义、`:82-83` 使用）：Task 2 的失败用例**可直接复用**该受控失败属性，无需新增 fake。

---

## 3. 任务（按 TDD，逐任务可独立评审）

> 每个任务的「Interfaces」块是相邻任务获知名称与类型的唯一途径。所有路径相对于仓库根。

### Task 1：Python 清单支持 v2 封面（`audiobook_media_export_v2`）

**Files:**
- Modify: `src/speechrail/media/manifest.py`
- Test: `tests/test_media_manifest.py`

**Interfaces:**
- Consumes: 无（起点）。
- Produces:
  - 常量 `MANIFEST_SCHEMA_VERSION_V1 = "audiobook_media_export_v1"`、`MANIFEST_SCHEMA_VERSION_V2 = "audiobook_media_export_v2"`、`SUPPORTED_MANIFEST_SCHEMA_VERSIONS: frozenset[str] = frozenset({MANIFEST_SCHEMA_VERSION_V1, MANIFEST_SCHEMA_VERSION_V2})`、`MAX_COVER_BYTES: int`（建议 `8 * 1024 * 1024`，见 §5 决定 D3）。
  - 冻结 dataclass `MediaCoverEntry(relative_path: str, image_sha256: str)`。
  - `MediaExportManifest.cover: MediaCoverEntry | None`（新增字段，`None` 表示无封面）。
  - 私有常量 `_ALLOWED_COVER_SUFFIXES: frozenset[str] = frozenset({".jpg", ".jpeg", ".png"})`。
  - 内部复用现有 `_SAFE_REL_PATH_RE`、`_reject_symlinks_on_chain`、`sha256_file_chunked`，并新增 `_validate_owned_cover_path(relative_path, *, book_id, audiobooks_root) -> Path`。
  - 规则：`schema_version == v1` 时**存在 `cover` 键即拒绝**；`schema_version == v2` 时**必须存在合法 `cover`**；`profile == "chapter_mp3"` 且 `schema_version == v2` 一律拒绝（本阶段 M4B 专属）。

- [ ] **Step 1: 写失败测试**（`tests/test_media_manifest.py`，沿用现有 `_make_wav_bytes`/`_write_manifest` 辅助）

新增用例与断言（样式沿用现有 `pytest.raises(MediaManifestError)` + `exc.value.error_code`）：
- `test_manifest_v1_without_cover_still_loads_unchanged`：现有 payload 不变 → `loaded.cover is None` 且其余字段一致（回归保护）。
- `test_manifest_v1_rejects_a_cover_field`：v1 + `cover` 键 → `error_code == "invalid_request"`。
- `test_manifest_v2_requires_valid_cover_and_verifies_its_sha256`：在 `books/<book_id>/cover/cover.jpg` 写入字节并给出正确 `image_sha256` → 加载成功且 `loaded.cover.image_sha256 == 期望值`；把 `image_sha256` 改成 `"0"*64` → `error_code == "integrity_mismatch"`。
- `test_manifest_v2_rejects_cover_outside_book_cover_dir_or_wrong_extension`：`books/<other_book_id>/cover/cover.jpg`、`books/<book_id>/cover/cover.gif`、`books/<book_id>/cover/../cover.jpg`、`books/<book_id>/audio/cover.jpg` 四种 → 均 `error_code == "invalid_request"`。
- `test_manifest_v2_rejects_oversize_or_missing_cover`：封面字节数 > `MAX_COVER_BYTES` → `invalid_request`；引用不存在的封面文件 → `integrity_mismatch`；封面为符号链接 → `invalid_request`。
- `test_manifest_v2_with_chapter_mp3_profile_is_rejected`：`profile == "chapter_mp3"` + v2 → `invalid_request`。

- [ ] **Step 2: 运行测试确认失败**

Run: `uv run --extra dev pytest tests/test_media_manifest.py -q --no-cov`
Expected: 新增用例 FAIL（`MediaExportManifest` 无 `cover` 字段 / v2 不被接受）

- [ ] **Step 3: 实现**

在 `manifest.py` 内：加入上述常量与 `MediaCoverEntry`；`MediaExportManifest` 增加 `cover: MediaCoverEntry | None = None`；把 `load_manifest` 中 `payload.get("schema_version") != MANIFEST_SCHEMA_VERSION` 的分支改为对 `SUPPORTED_MANIFEST_SCHEMA_VERSIONS` 的成员判断，并按 v1/v2 规则校验 `cover`。封面校验复用既有三段式（字符白名单 / 段与扩展名 / 符号链接与存在性），再对 `books/<book_id>/cover/` 前缀、`_ALLOWED_COVER_SUFFIXES`、`MAX_COVER_BYTES` 与 `sha256_file_chunked` 做核对。`MediaExportManifest` 的返回处带上 `cover`。

- [ ] **Step 4: 运行测试确认通过**

Run: `uv run --extra dev pytest tests/test_media_manifest.py -q --no-cov`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add src/speechrail/media/manifest.py tests/test_media_manifest.py
git commit -m "feat: accept audiobook export cover in manifest v2"
```

---

### Task 2：Python 编码器在 M4B 内嵌入封面

**Files:**
- Modify: `src/speechrail/media/encoder.py`
- Test: `tests/test_media_encoder.py`

**Interfaces:**
- Consumes: `MediaExportManifest.cover: MediaCoverEntry | None`（Task 1）。
- Produces: 无新公开符号；行为契约——当 `manifest.cover is not None` 且 `profile == "m4b"` 时，M4B 的 FFmpeg argv **恰好**如下变化（其余不变）。

**固定 argv 决策（m4b + 封面）**——在当前 argv（`encoder.py:442-479`）基础上：
- 输入顺序：`concat.txt`（索引 0）、`chapters.ffmeta`（索引 1）、`<cover 绝对路径>`（索引 2，置于 `chapters.ffmeta` 之后）。
- 映射：`-map 0:a:0`（不变）＋ 新增 `-map 2:v:0`、`-c:v copy`、`-disposition:v:0 attached_pic`。
- **移除** `-vn`（当前 `:465`）；因为需要保留 attached-picture 视频流。
- 保持逐项不变：`-f concat -safe 0`、`-f ffmetadata`、`-map_metadata 1`、`-map_chapters 1`、`-c:a aac`、`-b:a 128k`、`-ar 48000`、`-ac 1`、`-movflags +faststart+disable_chpl`、输出名 `book.m4b`、`-progress pipe:1`。
- 无封面时 argv **完全等于今天**（不新增任何参数）。

- [ ] **Step 1: 写失败测试**（复用 `FakeMediaRunner`，断言 `runner.recorded_argv[-1]`；受控失败属性 `raise_on_final_encode` **已存在于 `tests/test_media_encoder.py:54` 并在 `:82-83` 使用**，按其既有语义直接复用，无需新增 fake 或 subclass）

- `test_encode_m4b_with_cover_adds_attached_pic_and_drops_vn`：构造 v2 清单（`cover` 指向临时 `books/<book_id>/cover/cover.jpg`），断言最终 argv 同时含 `"2:v:0"`、`"-disposition:v:0"`、`"attached_pic"`、`"-c:v"`＋`"copy"`、封面绝对路径，且 **`"-vn" not in argv`**；并断言 `"+faststart+disable_chpl" in argv`、`"-map_chapters" in argv`。
- `test_encode_m4b_without_cover_argv_is_unchanged`：v1 清单 → 断言最终 argv 不含 `"2:v:0"`／`"attached_pic"`／`"-c:v"`，且 **`"-vn" in argv`**（守住现状）。
- `test_encode_chapter_mp3_profile_never_receives_a_cover`：直接构造 `profile="chapter_mp3"`（绕过 Task 1 拒绝，仅验证编码器不读封面）→ 断言所有 argv 不含 `attached_pic`；`result.relative_outputs` 仍为分章 MP3 清单。
- `test_encode_cover_embed_failure_cleans_stage`：让 `FakeMediaRunner.raise_on_final_encode = MediaEncodeError("ffmpeg exited with non-zero status", error_code="command_failed")` 且有封面 → 断言抛 `MediaEncodeError`、`error_code == "command_failed"`、且 `exports/<request_id>/stage` 不存在、原始 WAV 未被改动。

- [ ] **Step 2: 运行测试确认失败**

Run: `uv run --extra dev pytest tests/test_media_encoder.py -q --no-cov`
Expected: 新增用例 FAIL（argv 未含 attached-pic 映射）

- [ ] **Step 3: 实现**

在 `encode()` 的 m4b 分支内，按封面存在与否构造 argv：有封面时解析 `audiobooks_root / manifest.cover.relative_path` 为绝对路径并追加输入与映射、去掉 `-vn`；无封面时保持现有 argv 逐字不变。封面文件的存在性与 SHA-256 已在 `load_manifest` 校验，编码器不重复下载或联网；失败路径沿用既有 `except BaseException: shutil.rmtree(stage_dir)` 清理。

- [ ] **Step 4: 运行测试确认通过**

Run: `uv run --extra dev pytest tests/test_media_encoder.py tests/test_media_manifest.py -q --no-cov`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add src/speechrail/media/encoder.py tests/test_media_encoder.py
git commit -m "feat: embed cover art in audiobook m4b export"
```

---

### Task 3：Swift 清单载荷支持封面与版本切换

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailControlKit/MediaExportTypes.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `AudiobookExportManifestPayload.CoverItem`（`Codable, Equatable, Sendable`）：`relativePath: String`、`imageSHA256: String`，`CodingKeys` 为 `relative_path`、`image_sha256`。
  - `AudiobookExportManifestPayload.cover: CoverItem?`。
  - `schemaVersion` 由 `cover` 决定：`cover == nil ? "audiobook_media_export_v1" : "audiobook_media_export_v2"`；`init` 去掉 `schemaVersion` 形参（改为内部计算），新增 `cover: CoverItem? = nil`。

- [ ] **Step 1: 写失败测试**（`ControlKitTests.swift`）

- `testExportManifestPayloadUsesV1WithoutCoverAndV2WithCover`：无封面 → `payload.schemaVersion == "audiobook_media_export_v1"` 且 `payload.cover == nil`；带封面 → `"audiobook_media_export_v2"`。
- `testExportManifestPayloadRoundTripsCoverThroughControlWireCodec`：用该文件既有的 `ControlWireCodec` 编码再解码 → `decoded.cover?.relativePath`／`decoded.cover?.imageSHA256` 与原值相等，且 `decoded.schemaVersion == "audiobook_media_export_v2"`。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --package-path macos/SpeechRailApp --filter ControlKitTests`
Expected: FAIL（`CoverItem` 未定义 / 无 `cover` 字段）

- [ ] **Step 3: 实现**

按 Interfaces 定义 `CoverItem` 与 `cover`，并让 `schemaVersion` 随 `cover` 计算。核对全仓没有其它构造点在传 `schemaVersion`（当前构造点见 `AudiobookExportController.prepare`，不传该参数）。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path macos/SpeechRailApp --filter ControlKitTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add macos/SpeechRailApp/SpeechRailControlKit/MediaExportTypes.swift macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift
git commit -m "feat: carry optional m4b cover in the export manifest payload"
```

---

### Task 4：Swift 书籍自有封面资产存储（含构建清单登记）

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/AudiobookCoverAssetStore.swift`
- Modify: `macos/SpeechRailApp/Package.swift`（`SpeechRailAppSupport.sources` 加入 `"AudiobookCoverAssetStore.swift"`）
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`（`PBXFileReference` + app `Sources` 与单测 `Test Sources` 各一条 `PBXBuildFile` + group）
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookStoreTests.swift`（既有；不新建测试文件）

**Interfaces:**
- Produces:
  - `public struct AudiobookCoverAsset: Codable, Equatable, Sendable { public let bookID: UUID; public let relativePath: String; public let fileSHA256: String; public let byteCount: Int64 }`（`bookID` 供 Task 7 校验归属）
  - `public enum AudiobookCoverAssetError: LocalizedError, Equatable, Sendable { case unsupportedType; case tooLarge(Int64); case unreadable; case notRegularFile }`
  - `public enum AudiobookCoverLimits { public static let maxBytes: Int64 = 8 * 1024 * 1024; public static let allowedExtensions: Set<String> = ["jpg", "jpeg", "png"] }`
  - `public actor AudiobookCoverAssetStore`（`init(root: URL)`，`root` 为 `<app_home>/audiobooks`）：
    - `func install(bookID: UUID, sourceURL: URL) throws -> AudiobookCoverAsset`（校验后复制到 `<root>/books/<book_id>/cover/cover.<ext>`，先写同一目录下临时文件再原子替换）
    - `func existing(bookID: UUID) throws -> AudiobookCoverAsset?`
    - `func remove(bookID: UUID) throws`
- 安全规则：拒绝符号链接源与目标、拒绝空文件与超 `AudiobookCoverLimits.maxBytes`、扩展名必须在允许集合内；不写 SQLite（本阶段封面不进入作品 schema，见 §5 决定 D1）；不新增 `.trash` 逻辑——封面目录随 `books/<id>` 由既有 trash 生命周期携带（§2.1 第 2 条）。

- [ ] **Step 1: 写失败测试**（追加到既有 `AudiobookStoreTests` 类）

- `testCoverAssetInstallCopiesValidatedCoverIntoBookOwnedDirectoryAtomically`：临时 jpg 字节 → `install` 后文件位于 `books/<book_id>/cover/cover.jpg`，`asset.bookID == book_id`，`asset.relativePath == "books/<book_id>/cover/cover.jpg"`，`asset.fileSHA256` 与源 SHA-256 相等，且目录内无遗留 `.tmp*`。
- `testCoverAssetInstallRejectsUnsupportedExtensionSymlinkAndOversizeInput`：`.gif` → `unsupportedType`；> `maxBytes` → `tooLarge`；符号链接源 → `notRegularFile`；空文件 → `unreadable`。
- `testCoverAssetExistingIsNilBeforeInstallAndReportsAfter`。
- `testCoverAssetRemoveDeletesOnlyTheBookOwnedCoverFile`：安装后 `remove` → `existing` 为 `nil`，且书籍 `audio/` 下既有文件未被触碰。
- `testTrashAndRestorePreserveBookCoverAndPermanentDeleteRemovesIt`（**与既有 `testTrashBookPreservesOriginalExportsAndDubbing` 同文件相邻**）：安装封面 → `trashBook` 后 `books/<id>` 不存在且废纸篓目录内含 `cover/cover.jpg` → `restoreTrashedBook` 后 `existing(bookID:)` 仍返回同一 `fileSHA256` → 再次 `trashBook` + `permanentlyDeleteTrashedBook` 后封面文件消失。**不涉及 SQLite/schema 断言**。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookStoreTests`
Expected: FAIL（`AudiobookCoverAssetStore` 未定义）

- [ ] **Step 3: 实现源码并登记构建清单**

按 Interfaces 实现 `AudiobookCoverAssetStore.swift`；路径拼接复用既有书籍目录约定（`<root>/books/<book_id>/...`，与候选音频 `audio/` 同级），原子写采用同目录临时文件 + `replaceItemAt`（与 `AudiobookExportController.commit` 的兄弟临时文件模式一致）。
随后**必须**完成两处登记，否则 SwiftPM 会因 `sources` 未列而忽略该文件（app 侧不被编译）、Xcode 会因 phase 未登记而不编入：
1. `Package.swift`：在 `SpeechRailAppSupport` 的 `sources:` 数组内加入 `"AudiobookCoverAssetStore.swift"`。
2. `project.pbxproj`：新增 `PBXFileReference`，并各新增一条 `PBXBuildFile` 编入 app target 的 `Sources` phase 与 Xcode 单测 target 的 `Test Sources` phase，再加入对应 group——写法与 `AudiobookMediaVerifier.swift`/`AudiobookExportController.swift` 现有条目一致。

- [ ] **Step 4: 运行测试与构建清单检查**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookStoreTests`
Expected: PASS
Run: `python3 scripts/check_macos_test_target_coverage.py`
Expected: 通过（未新增测试文件，登记面未漂移）

- [ ] **Step 5: 提交**

```bash
git add macos/SpeechRailApp/SpeechRailApp/AudiobookCoverAssetStore.swift \
  macos/SpeechRailApp/Package.swift \
  macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj \
  macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookStoreTests.swift
git commit -m "feat: add book-owned audiobook cover asset store"
```

---

### Task 5：Swift 导出控制器透传封面并预拒绝 MP3+封面

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookExportController.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookExportTests.swift`

**Interfaces:**
- Consumes: `AudiobookCoverAsset`（Task 4，携带 `bookID`）、`AudiobookExportManifestPayload.CoverItem`（Task 3）。
- Produces:
  - `AudiobookPreparedExport.expectsArtwork: Bool`（新增，默认 `false`）。
  - `AudiobookExportError` 新增 `case coverNotSupportedForProfile`（`errorDescription` 用用户语言，例如"分章 MP3 导出暂不支持封面；封面仅用于整本 M4B。"）与 `case coverBookMismatch`（例如"所选封面不属于当前书籍；请重新选择。"）。
  - `prepare(bookID:chapterIDs:profile:cover:)`：新增形参 `cover: AudiobookCoverAsset? = nil`。
  - 不变量：构建 payload 前必须校验 `cover.bookID == bookID`，不一致即拒绝——封面只能属于导出的那本书。

- [ ] **Step 1: 写失败测试**

- `testPrepareRejectsCoverWithChapterMP3ProfileBeforeWritingManifest`：`profile == .chapterMP3` 且 `cover != nil` → 抛 `AudiobookExportError.coverNotSupportedForProfile`；且 `exports/<request_id>/request.json` **未被写出**（在写清单前拒绝）。
- `testPrepareRejectsCoverBelongingToAnotherBook`：`cover.bookID != bookID` → 抛 `AudiobookExportError.coverBookMismatch`，且不写出清单。
- `testPrepareWritesV2ManifestWithCoverPathAndSha`：注入 `customStageEncoder` 捕获 `AudiobookExportManifestPayload` → `schemaVersion == "audiobook_media_export_v2"`，`cover?.relativePath == cover.relativePath`，`cover?.imageSHA256 == cover.fileSHA256`。
- `testPreparedExportCarriesExpectsArtworkMatchingCover`：带封面 → `prepared.expectsArtwork == true`；不带 → `false`。
- `testPrepareWithoutCoverKeepsV1Manifest`：`cover == nil` → 捕获到的 payload `schemaVersion == "audiobook_media_export_v1"` 且 `cover == nil`。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookExportTests`
Expected: FAIL（无 `cover` 形参与 `expectsArtwork`）

- [ ] **Step 3: 实现**

在 `prepare` 开头依次做两项预拒绝：①`profile == .chapterMP3 && cover != nil` → `coverNotSupportedForProfile`；②`cover != nil && cover.bookID != bookID` → `coverBookMismatch`。校验通过后把 `cover` 映射为 `AudiobookExportManifestPayload.CoverItem(relativePath: cover.relativePath, imageSHA256: cover.fileSHA256)` 传入 payload；把 `expectsArtwork: cover != nil` 写入 `AudiobookPreparedExport`。其余导出门禁（采用候选 SHA、章节帧数、stage 校验、原子提交）**不改**。同时核实 `AgentCommandRunner` 把 `MediaManifestError`（v2 不被旧服务识别）映射成的失败信封，并在 App 侧把该失败转成用户语言提示（**不要**新增任何"静默降级为无封面"的路径）。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookExportTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add macos/SpeechRailApp/SpeechRailApp/AudiobookExportController.swift macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookExportTests.swift
git commit -m "feat: pass optional cover through the audiobook export controller"
```

---

### Task 6：Swift 校验器复核封面存在／缺失

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookMediaVerifier.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookExportTests.swift`

**Interfaces:**
- Consumes: `AudiobookPreparedExport.expectsArtwork`（Task 5）。
- Produces:
  - `AudiobookMediaVerification.artworkPresent: Bool`（新增；自定义 `init(from:)`，缺失键解码为 `false`）。
  - `verify(url:expected:)` 新规则：`expected.expectsArtwork == true` 时 **必须**能读到 artwork，否则抛 `verificationFailed`；`== false` 时 **不得**存在 artwork，否则抛 `verificationFailed`。

- [ ] **Step 1: 写失败测试**

- `testMediaVerifierRequiresArtworkWhenExpected`：用无封面的可播放 M4B 夹具 + `expectsArtwork == true` → 抛 `.verificationFailed`。
- `testMediaVerifierRejectsUnexpectedArtworkWhenNotExpected`：用含 artwork 的 M4B 夹具 + `expectsArtwork == false` → 抛 `.verificationFailed`。
- `testMediaVerifierReportsArtworkPresenceForCoverEmbeddedM4B`：含 artwork 的 M4B + `expectsArtwork == true` → 通过且 `verification.artworkPresent == true`。

夹具纪律（沿用该套件既有约定，见 `docs/developers/macos-app-audiobook.md` §末）：章节媒体夹具由 AVFoundation 动态生成合成 AAC，再用 PATH 中的 `ffmpeg` 按产品封装方式生成 QuickTime 章节轨；**找不到 `ffmpeg` 时明确跳过该正例，不下载依赖**。含 artwork 的正例同样需要 `ffmpeg` 注入封面；负例不需要。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookExportTests`
Expected: FAIL（未校验 artwork）

- [ ] **Step 3: 实现**

在 M4B 分支用 `AVURLAsset.load(.commonMetadata)` 取 `AVMetadataItem.metadataItems(from:filteredByIdentifier: .commonIdentifierArtwork)`；按 `expected.expectsArtwork` 判存在性；把结果写入 `AudiobookMediaVerification.artworkPresent`。保持既有的音轨／编码／时长／章节／输出 SHA 校验不变。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookExportTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add macos/SpeechRailApp/SpeechRailApp/AudiobookMediaVerifier.swift macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookExportTests.swift
git commit -m "feat: verify m4b artwork presence against the export request"
```

---

### Task 7：导出 Sheet 的封面选择（渐进披露，按书归属）

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkshopView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookWorkflowTests.swift`（既有；不新建测试文件）

**Interfaces:**
- Consumes: `AudiobookCoverAssetStore`（Task 4）、`prepare(cover:)`（Task 5）、`AudiobookCoverAsset.bookID`（Task 4）。
- Produces:
  - `AudiobookWorkflowModel.exportCover: AudiobookCoverAsset?`（可观察状态）与 `func setExportCover(sourceURL: URL) async`、`func clearExportCover() async`。
  - `AudiobookWorkflowModel.prepareExport(profile:chapterIDs:)` 在已有签名基础上读取 `exportCover` 并透传。
  - 归属不变量（三条）：①`exportCover` 始终以 `selectedBook?.id` 为作用域；②切换 `selectedBook`（或经既有 `trashBook`/`restoreTrashedBook` 路径离开该书籍）时，**必须**清空 `exportCover` 或按新书籍重新加载 `existing(bookID:)`，不得把上一本书的封面带到新书；③`prepareExport` 在构造 payload 前以 `exportCover.bookID == selectedBook?.id` 复核，不一致则丢弃并走 `clearExportCover()`（不把陈旧封面写进清单，最终一致性由 Task 5 的 `coverBookMismatch` 兜底）。

- [ ] **Step 1: 写失败测试（确定性、非 UI）**

- `testPrepareExportForwardsSelectedCoverToController`：`setExportCover` 后调用 `prepareExport(profile: .m4b, chapterIDs:)` → 注入的 `customStageEncoder` 捕获到的 payload 为 v2 且 `cover` 指向已安装路径。
- `testSwitchingToChapterMP3ClearsTheSelectedCover`：先设封面再切 profile → `exportCover == nil`，下一次 `prepareExport(.chapterMP3, ...)` 的 payload 为 v1 且 `cover == nil`。
- `testSwitchingBooksClearsOrReloadsTheSelectedCover`（**切书隔离回归**）：为书 A 设置封面后把选择切到书 B → `exportCover` 为 `nil`（或等于 B 自己的封面，若 B 已有），**且绝不为 A 的封面**；随后对 B 调 `prepareExport` 得到的 payload 不含 A 的封面路径。再切回 A → 得到 A 的封面（经 `existing(bookID:)` 重新加载），而非 B 的。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookWorkflowTests`
Expected: FAIL（`exportCover` 未定义）

- [ ] **Step 3: 实现**

Workflow 侧加 `exportCover` 状态与两个方法（委托 `AudiobookCoverAssetStore`），并在既有切书/离开书籍路径（`selectedBook` 变更、`trashBook`、`restoreTrashedBook`）上**清空 `exportCover` 或按新书重新加载**，保证封面按书归属；`prepareExport` 在构造 payload 前复核 `exportCover.bookID == selectedBook?.id`。导出 Sheet 加一行「封面」：`fileImporter(allowedContentTypes: [.jpeg, .png])`、当前封面缩略图预览、`清除` 操作、错误就地提示；`profile == .chapterMP3` 时该行**不显示**（渐进披露）。文案用用户语言，说明"将随整本 M4B 一起写入封面，播放器可显示"；不引入新的视觉常量，复用既有 Token 与共享组件；保持键盘可达与 VoiceOver 语义。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path macos/SpeechRailApp --filter AudiobookWorkflowTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add macos/SpeechRailApp/SpeechRailApp/AudiobookWorkshopView.swift \
  macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift \
  macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookWorkflowTests.swift
git commit -m "feat: let users attach a book-scoped cover in the export sheet"
```

> 说明：该任务的**界面视觉／无障碍验收**属 UI 走查范畴，需用户逐次明确授权后才能执行；本任务只要求确定性 Swift 单测通过，不得把"单测通过"当作"界面已验收"。

---

### Task 8：文档与测试清单同步

**Files:**
- Modify: `docs/developers/macos-app-audiobook.md`（§1.3 媒体子系统、§2 不变量）
- Modify: `docs/architecture/audiobook-workshop.md`（§2.6 受控 XPC 媒体封装）
- Modify: `docs/developers/audiobook-workshop-testing-handover.md`（测试命令与模块矩阵）

**Interfaces:**
- Consumes: Task 1–7 的实际接口与行为。
- Produces: 无代码符号；文档陈述与实现一致。

- [ ] **Step 1: 更新文档**

按当前实现陈述（不写"本轮新增"式过程叙述）：清单版本 `audiobook_media_export_v1`/`v2` 的语义、封面允许路径 `books/<book_id>/cover/<name>.<jpg|jpeg|png>` 与摘要校验、M4B 专属、MP3 明确不支持、无封面输出与先前一致、`AudiobookMediaVerifier` 复核 artwork。同步更新 `version`/`date`（仅在正文实质变化时）。

- [ ] **Step 2: 验证文档与版本一致性**

Run: `python3 scripts/check_version_consistency.py && python3 scripts/check_operator_docs.py`
Expected: 通过（无版本／引用漂移）

- [ ] **Step 3: 提交**

```bash
git add docs/developers/macos-app-audiobook.md docs/architecture/audiobook-workshop.md docs/developers/audiobook-workshop-testing-handover.md
git commit -m "docs: describe m4b cover export and its verification"
```

---

## 4. 另两项候选的后续进入条件（相互独立）

### 4.1 P0-1 通用成品响度处理

**进入条件（全部满足才立项）**
1. 产出决策记录，明确**目标单位**（RMS / LUFS / peak 之一或组合）、**测量范围**（单章 vs 整书）、**是否保持章间相对响度**、**单遍 vs 两遍**、**默认值**（建议默认 `off`）。
2. 明确它与既有"按请求冻结增益"的关系：`docs/architecture/quality-voice-capabilities.md:163` 已载"只做一次基于有效语音的增益/响度处理，避免重复归一"。若在导出层再做一次，必须说明这是"成品交付归一"而非重复归一，且不得改变流式冻结增益策略。
3. 明确两遍的测量回传与失败策略（测量失败是降级为单遍还是失败），以及 loudnorm 动态模式可能升采样到 192 kHz 时的**回采样到 48 kHz** 规则与 mono 输入 `dual_mono` 语义。
4. **不得**以 ACX 合规作为产品卖点或档位名；不承诺 `-19 LUFS` 等未在本项目目标机验证的数值。若确需贴近 ACX 电平，须分别验证 RMS、peak 与 noise-floor，并遵守 ACX 对未授权 TTS/AI 音频的限制。
5. 一旦立项，改动面以 `media/manifest.py`（可选字段）+ `media/encoder.py`（导出层单次处理）+ Swift payload/UI 为范围；`AudiobookMediaVerifier` 保持对该档位无感知。

### 4.2 P0-3 密集脚本感知分块

**进入条件（全部满足才立项）**
1. 先做**离线评估**：以现有 `TtsTextPlanner`（`tts_bounded_v1`，`max_chars = 240`）为基线，对简体中文、繁体中文、日文、韩文、英文及中英混排样本比较分块边界、chunk 数与截断/遗漏；阈值必须由证据选出，不得照搬 VoiceStudio 的整段密度门控。
2. 明确它**只**调整合成 chunk 规划，不与 HTTP 请求上限（4096）、Realtime append/pending 限额、vendor context budget、App 的 atom/fragment 预算混同。
3. 若引入密度维度：bump `PLANNER_VERSION`，同步 `render_recipe` 的 `planner_revision`/`planner_max_chars`、`docs/users/effective-capabilities.md` 中 `operations.tts_text_planner` 的表述与相关回归；**不要求** OpenAPI 变更（当前无该字段的契约证据）。
4. 保持正文保真、标点不丢、边界可追踪；App 角色边界、时间 sidecar 与 planner 坐标语义保持一致；**不得**改变只读源文本与半开字节区间模型。
5. 若考虑不可发音内容的合并/丢弃，必须另行证明"没有静默丢文"，并单独记录可见诊断；**不纳入第一阶段默认范围**。

---

## 5. 未决产品决策（需产品确认；本方案给出推荐默认）

| 编号 | 决策点 | 本方案默认 | 影响 |
|---|---|---|---|
| D1 | 封面资产来源与持久化：用户选择本机图片；单封面还是多封面；是否进 SQLite | 本机图片文件 → 复制为书籍自有 `cover/cover.<ext>`（单封面）；**不进 SQLite**，不改作品 schema | D1 若改多封面或入库，需新增 schema 迁移与恢复路径，属独立增量 |
| D2 | **坏封面策略**：fail-loud（推荐）vs 省略封面并警告 | **fail-loud**：非法类型/超限/不可解码一律失败并说明原因，绝不静默产出无封面书 | 与 SpeechRail 的 fail-closed 取向一致；若选"省略并警告"，须在 UI 明确告知未嵌入 |
| D3 | 封面约束范围 | 扩展名白名单 `jpg/jpeg/png` + `maxBytes = 8 MiB`；**不做** ACX 方形/≥2400×2400/位深校验 | 8 MiB 是工程上限，**不是** ACX 合规声明；ACX 相关校验需另行立项 |
| D4 | MP3 封面 | 本阶段**仅 M4B**；`chapter_mp3` + 封面在写清单前拒绝 | 回避 MP3 muxer 附图兼容风险；后续如需另立 |
| D5 | 版本协商方式 | 带封面时写 `audiobook_media_export_v2`；旧服务必须**可见失败**，不静默丢封面 | 避免"App 与服务 wheel 版本漂移"下的静默降级 |
| D6 | 是否在 `media capabilities` 暴露 `supports_cover` | 本阶段**不加**（避免改动 `MediaCapabilitiesSnapshot` 线格式） | 若加，需同步 Swift/ControlKit 与能力快照说明 |
| D7 | Swift 测试文件组织 | **不新增测试文件**：封面资产/生命周期测试进 `AudiobookStoreTests.swift`，导出/校验测试进 `AudiobookExportTests.swift`，工作流归属测试进 `AudiobookWorkflowTests.swift`（均为已登记文件） | 保持 Xcode 登记面只增加一个**源码**文件；若改为新建 `AudiobookCoverAssetStoreTests.swift`，须同时在 pbxproj `Test Sources` phase 与 group 登记，否则 `check_macos_test_target_coverage.py` 失败 |

---

## 6. 未来要添加的回归测试与验证命令（本轮不新增、不运行）

**测试清单（名称与断言见 §3 各任务的 Step 1）**

Python：
- `tests/test_media_manifest.py`：v1 回归不变、v1+cover 拒绝、v2 摘要校验、封面路径/扩展名/越界拒绝、超限/缺失/符号链接拒绝、MP3+v2 拒绝。
- `tests/test_media_encoder.py`：m4b+封面 argv（含 `2:v:0`/`attached_pic`/`-c:v copy`/去 `-vn`）、无封面 argv 不变、MP3 无封面、封面嵌入失败清理 stage。

Swift（全部落在既有已登记文件，**不新增测试文件**）：
- `ControlKitTests.swift`：v1/v2 切换、`cover` 经 `ControlWireCodec` 往返。
- `AudiobookStoreTests.swift`：封面资产安装原子性、类型/超限/符号链接/空文件拒绝、`existing`/`remove` 边界；**`testTrashAndRestorePreserveBookCoverAndPermanentDeleteRemovesIt`**（封面随 `books/<id>` 进入/移出 `.trash`，永久删除后消失；不涉及 SQLite/schema 断言）。
- `AudiobookExportTests.swift`：MP3+封面预拒绝、`coverBookMismatch` 预拒绝、v2 payload 内容、`expectsArtwork` 传递、verifier 需/禁 artwork、含封面正例报告 `artworkPresent`。
- `AudiobookWorkflowTests.swift`：`exportCover` 转发、切 `chapterMP3` 清除、**`testSwitchingBooksClearsOrReloadsTheSelectedCover`**（切书隔离：绝不把 A 的封面带到 B）。

**验证命令（实施阶段，按最小必要执行）**

```bash
# Python 定向
uv run --extra dev pytest tests/test_media_manifest.py tests/test_media_encoder.py tests/test_media_commands.py -q --no-cov
uv run --extra dev ruff check src tests
uv run --extra dev mypy src

# Swift（包装脚本优先；SwiftPM 单跑不产出 .app）
scripts/macos_app_test.sh
swift test --package-path macos/SpeechRailApp
swift test --package-path macos/SpeechRailApp --filter AudiobookStoreTests
swift test --package-path macos/SpeechRailApp --filter AudiobookWorkflowTests
python3 scripts/check_macos_test_target_coverage.py

# 文档与版本一致性
python3 scripts/check_version_consistency.py
python3 scripts/check_operator_docs.py
```

**本轮未执行**上述任何命令，也未新增任何测试。

---

## 7. 验收证据与回退

**验收证据（实施后按需授权执行）**
1. **离线性**：Python 侧以 `FakeMediaRunner` 断言 argv，证明"无封面＝逐项一致"与"有封面＝固定映射"，不依赖真实 ffmpeg。
2. **协议一致性**：`ControlKitTests` 证明 Swift 写出的 v1/v2 清单形状稳定。
3. **媒体事实**：`AudiobookMediaVerifier` 以 AVFoundation 读取真实 artwork 存在/缺失并据此拒绝，构成"即使 ffmpeg 静默丢图也失败"的兜底。
4. **端到端**：App 导出含封面 M4B 后，`AVURLAsset` 能读到 artwork；无封面导出与现状一致。**端到端与界面走查需按项目规则单独授权**。
5. **构建清单一致性**：`python3 scripts/check_macos_test_target_coverage.py` 通过；`swift test` 与 Xcode 单测均能编译新源码（证明 `Package.swift sources` 与 `project.pbxproj` 两处登记都被实际消费）。
6. **书籍生命周期**：`AudiobookStoreTests.swift` 证明封面随 `books/<id>` 进出 `.trash`，永久删除后被移除。
7. **不得据此宣称**：单次 smoke 不等于"封面在 Apple Books 正确显示"（需人工走查）；不构成任何 ACX／平台合规；不构成音质、性能或长稳结论。

**回退方式**
- 所有改动是**新增可选路径**：`prepare(cover: nil)` 即回到 v1 行为；封面不存在时不产生 v2 清单。
- Python 侧保留 v1 支持，删除封面文件即可恢复既有导出产物。
- 无 SQLite schema 迁移、无持久格式破坏；`AudiobookCoverAssetStore` 可整体移除而不影响既有导出（仅删一个 `cover/` 目录下的静态文件）。
- **回退必须同时撤销两处构建清单登记**：从 `Package.swift` 的 `SpeechRailAppSupport.sources` 与 `project.pbxproj`（`PBXFileReference`、两条 `PBXBuildFile`、group、两个 source phase）移除 `AudiobookCoverAssetStore.swift`，否则清单会引用不存在的文件而导致构建失败。
- 服务 wheel 回退到旧版本后，带封面的导出会**可见失败**（不静默丢封面），据此可判定是否需一并回退 App。

---

## 8. 自审（writing-plans Self-Review，第二轮重做）

1. **规格覆盖**：竞品报告 P0-2 的四条验收条件 → ①合法 jpg/png 时 m4b 含 artwork（Task 2/6/7）；②缺失/非法/超限/不可解码的稳定结果（Task 1/4/5，策略 D2 fail-loud）；③不提供封面时产物与现状一致（Task 2 的 argv 不变断言 + Task 5 的 v1 断言）；④manifest 仅接受书籍自有允许路径且校验摘要、verifier 明确验证 artwork 并保持音轨/章节/时长/SHA（Task 1/6）。报告 §5.1 的"Export manifest 扩展"先决条件 → Task 1/3/5 协同。**第二轮复核补充条款** → ①双构建清单 → §2 构建清单块 + Task 4 Step 3/4 + Global Constraints + §7 第 5 条；②trash 生命周期携带封面 → §2.1 第 2 条 + Task 4 的 `testTrashAndRestorePreserveBookCoverAndPermanentDeleteRemovesIt`；③按书归属与切书隔离 → Task 5 的 `coverBookMismatch` + Task 7 三条不变量与 `testSwitchingBooksClearsOrReloadsTheSelectedCover`；④`raise_on_final_encode` 已存在 → Task 2 Step 1 已按实测标注复用。无遗漏。
2. **步骤扫描**：每个 Step 是一个可判定结果的动作；未出现"处理边界情况""适当校验"等不决定任何事的表述；代码块只给签名／固定 argv／断言，未给函数体。Task 4 的登记步骤给出了**两处精确落点**，不含"视情况"式措辞。
3. **类型一致性**：`MediaCoverEntry.relative_path/image_sha256`（Task 1）＝`CoverItem.relative_path/image_sha256`（Task 3）＝`AudiobookCoverAsset.relativePath/fileSHA256`（Task 4，映射发生在 Task 5）；`AudiobookCoverAsset.bookID`（Task 4）在 Task 5 的 `coverBookMismatch` 与 Task 7 的归属复核中被消费；`expectsArtwork` 在 Task 5 定义、Task 6 消费；`artworkPresent` 在 Task 6 定义；`exportCover`/`setExportCover`/`clearExportCover` 在 Task 7 定义并在其测试中使用。命名跨任务一致。
4. **Review Focus**：五条命中写明，并各自归到任务——非图片文件（Task 4 的扩展名白名单 + Task 5）、损坏图片（Task 2 的 `command_failed` + Task 6 的 artwork 兜底）、旧服务版本（Task 5 的失败信封核实）、MP3+封面（Task 1/5）、prepare 后封面被改动（Task 1 的 SHA 校验 + Task 6 的 artwork 兜底 + 既有 commit 原子路径）。第二轮新增的两类（**封面跨书**、**trash/restore 后封面丢失**）分别由 Task 5/7 与 Task 4 的测试钉住。
5. **构建清单一致性**：本方案只新增一个**源码**文件，已明确其 `Package.swift sources` 与 `project.pbxproj`（app `Sources` + 单测 `Test Sources`）两处登记；测试全部落在既有已登记文件，故 `check_macos_test_target_coverage.py` 不因新增测试文件而漂移。回退步骤同样撤销这两处登记。
6. **比例**：本文件含三候选比较与两项进入条件，正文步骤以签名／argv／断言为主，未出现实现转写。

---

## 9. 事实来源与时点

**核验时点**：2026-10-17；SpeechRail `codex/speechrail-ux-redesigns` @ `4b52697e`。

**【代码实测】直接读取（本提交）**
- `src/speechrail/media/manifest.py`（`MANIFEST_SCHEMA_VERSION`、`MediaExportManifest`、`_validate_owned_relative_path`、`load_manifest`）。
- `src/speechrail/media/encoder.py`（`SAMPLE_RATE_HZ`/`CHANNELS`、`MediaEncodeError`、`read_wav_pcm16_frames`、m4b argv `:442-479`、mp3 argv、失败清理）。
- `src/speechrail/media/commands.py`（`run_media_capabilities`、`run_media_export`）。
- `src/speechrail/domain/tts_text_planner.py`（`PLANNER_VERSION`、`TtsTextPlanner.max_chars=240`）。
- `src/speechrail/application/render_preparation.py`（planner 实例化与 summary）。
- `macos/SpeechRailApp/SpeechRailControlKit/MediaExportTypes.swift`、`macos/SpeechRailApp/SpeechRailApp/AudiobookExportController.swift`（`prepare`/`commit`/`expectedStageOutputPaths`）、`AudiobookMediaVerifier.swift`。
- `docs/architecture/audiobook-workshop.md`（§2.4–§2.6）、`docs/developers/macos-app-audiobook.md`（§1.3、§2、文末测试纪律）、`docs/users/effective-capabilities.md`（§分句规划版本）、`docs/architecture/quality-voice-capabilities.md:163,167,191`。
- 测试：`tests/test_media_manifest.py`、`tests/test_media_encoder.py`、`tests/test_media_commands.py`、`tests/test_tts_text_planner.py`、`tests/test_tts_text_planner_raw_mapping.py`；Swift 测试类名 `AudiobookExportTests`、`ControlKitTests`、`AgentCoreTests`。
- 检索结论：`src/` 内 `\bloudnorm\b|attached_pic|dual_mono|artwork|LUFS` 零命中（支撑 §1.1 第二行）。

**【代码实测】第二轮复核新增（同一提交）**
- `macos/SpeechRailApp/Package.swift`：`SpeechRailAppSupport` 同时有 `exclude:`（`:41-89`）与显式 `sources:`（`:90-264`，含全部 `Audiobook*` 条目）；`SpeechRailMacControlTests` 只有 `path:`（`:286-294`）。
- `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`：`AudiobookMediaVerifier.swift`/`AudiobookExportController.swift` 的登记模式——`PBXFileReference`（`:903-904`）、app `Sources` 与单测 `Test Sources` 各一条 `PBXBuildFile`（`:329-330`/`:372-373`/`:494-497`）；据此确认新源码需两处 phase 登记。
- `scripts/check_macos_test_target_coverage.py`：`UNIT_TEST_TARGET_NAME = "SpeechRailAppTests"`（`:39`），规则为"磁盘上每个测试文件都必须被 Xcode 单测 target 编译，除非在 `ALLOWLIST` 中"（`:11-23`）；据此确认"不新增测试文件"是本方案把登记面收敛为一个源码文件的依据。
- `macos/SpeechRailApp/SpeechRailApp/AudiobookProjectStore.swift`：`trashBook(id:)`（`:1752`，整体 `moveItem books/<id>` → `.trash/<uuid>-<ts>` + `trash-snapshot.json`/`trash-meta.json`）、`restoreTrashedBook(id:)`（`:1819`）、`permanentlyDeleteTrashedBook(id:)`（`:1853`）。
- `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift`：`trashBook`（`:859`）/`restoreTrashedBook`（`:882`）产品路径。
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookStoreTests.swift`：既有 `final class AudiobookStoreTests: XCTestCase`（`:9`）与 `testTrashBookPreservesOriginalExportsAndDubbing`（`:1386`）——封面生命周期回归的落点。
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookWorkflowTests.swift`：工作流级 trash 用例（`:1167`）——切书隔离回归的落点。
- `tests/test_media_encoder.py`：`FakeMediaRunner.raise_on_final_encode` 定义（`:54`）与使用（`:82-83`）。

**【报告观点，本轮未逐条复现】**
- `docs/audits/2026-10-17-speechrail-voicestudio-competitive-research.md` §0.3、§4 P0-1/P0-2/P0-3、§5.1、§8；`docs/audits/2026-10-17-speechrail-elevenlabs-absorption-plan.md` §5。
- 二者为主工作区**工作树版本**（前者已跟踪并修改，后者未跟踪），**不在本分支**；本文件只引用其结论，未复制其内容。

**【待定】** 封面体积上限取值（D3）、坏封面策略（D2）、MP3 范围（D4）、版本协商最终形态（D5）、是否暴露 `supports_cover`（D6）。

**【工具边界】** `codebase-memory` MCP 图查询在 Code Mode 运行时返回不可解析载荷，未作为独立证据；详见 §0。