# 实时字幕定向捕获与双语流式翻译：实施与审查记录（2026-10-26）

对应方案：[`2026-10-25-app-targeted-realtime-captions-redesign.md`](../superpowers/plans/2026-10-25-app-targeted-realtime-captions-redesign.md)（工作区为 v3.1.0）
规范依据：[`2026-10-16-meeting-caption-asr-design.md`](../superpowers/specs/2026-10-16-meeting-caption-asr-design.md) §11（客户端规则）
分支与基线：`feat/app-targeted-realtime-captions`，基线提交 `acef1db8`。本文记录的全部改动**都在工作区，未提交、未推送**。

本文只记录两件事：**这次落地了什么**，以及**验证到什么程度**。所以证据分三类写清：确定性回归（可重跑）、静态核验（读代码/配置）、未验证（必须真机或真实播放）。

---

## 1. 落地范围

| 方案条目 | 落点 | 状态 |
| --- | --- | --- |
| Task 2/3：Stage 1 单飞预览 + LocalAgreement-2 软前缀锚定 | `macos/SpeechRailApp/SpeechRailApp/CaptionTranslator.swift` | 代码就绪，单测覆盖 |
| Task 2/3：Stage 2 前 3 句双语平行上下文精翻 | 同上 + `CaptionSession.didSaveTranscript` | 代码就绪，单测覆盖 |
| Task 3：定稿瞬间继承预览译文（无白屏交接） | `CaptionSession.swift` | 代码就绪，单测覆盖 |
| Task 3：未定稿原文「稳定前缀 + 浮动尾部」视觉分层 | `CaptionSession.swift`（`partialStablePrefixLength`、`sourceTiering`）+ `CaptionBandWindow.swift`（`tieredSourceText`） | 代码就绪，单测覆盖（投影层） |
| §11 铁律 1/2：双语平行 Context、防自污染 | `CaptionSession.didSaveTranscript` | 代码就绪，单测覆盖 |
| §11 铁律 4：Stage 2 失败兜底、不卡在「翻译中」 | `CaptionTranslator.translateCompletedLine` | 代码就绪，单测覆盖 |
| Task 4：窗口拾取器 / 15Hz 跟随 / 吸附与自由悬浮 | `CaptionWindowPicker.swift`、`TargetWindowTracker.swift`、`CaptionBandWindow.swift` | 代码就绪，**无自动化覆盖（App-only）** |
| Task 4：底边不动、预排版算高 | `CaptionBandWindow.swift`（`applyMetrics` 只改 `size.height`；`visualRowCount` 用 `boundingRect`） | 静态核验 |
| Task 1：Schema v15、双语 SRT 导出 | 基线提交已含；本次补导出投影单测 | `macos/SpeechRailApp/SpeechRailMacControlTests/MeetingRecoveryMaterialTests.swift` |
| Task 5：工程清单同步 | `Package.swift` / `project.pbxproj`（基线已含） | `scripts/check_macos_test_target_coverage.py` = OK |

---

## 2. 审查发现并修复的缺陷

2.1–2.5 都是**基线提交引入**的（不是本轮新写出来的），审查时按"这段代码真的能跑出方案承诺的行为吗"逐条追下来；2.6 是基线提交里 App 目标**根本编译不过**的三处错误。

### 2.1 吸附状态机会在第一次改帧时把自己踢出吸附态（major，直接废掉 DoD-2）

- 症状：字幕带贴在目标窗口上之后不再跟随；移动/缩放目标窗口没有反应；工具条的「吸附回窗口」也救不回来。
- 触发路径：`TargetWindowTracker` 首次探测到目标窗口 → `handleTargetGeometryChanged` 用 `setFrame` 摆位 → AppKit 为这次**程序化改帧**发 `NSWindowDidMoveNotification` → `windowDidMove` 里原先无条件执行 `placementMode = .freeFloatingPinned` + `tracker.stopTracking()`。
- 依据：`setFrame` 会触发 `windowDidMove`，社区成熟做法（如 Raycast 风格非激活 `NSPanel` 的实现）正是用"与上次落点比对"来区分自己搬的和用户拖的，并明确警告否则会形成 `resize → move → re-anchor` 反馈环。
- 修法：`CaptionBandWindow.swift` 增加 `isApplyingTargetGeometry`（盖住同步到达的通知）与 `lastDockedOrigin`（盖住异步到达的通知，容差 1pt，记录 AppKit **真正**落下的原点而非请求值）。

### 2.2 切目标或点「吸附回窗口」不重挂跟踪器（major，DoD-2 的显式验收项）

- 症状：点「吸附回窗口」只改了 `placementMode`，跟踪器仍是停止状态；带子开着时重新选目标窗口同样不跟。
- 触发路径：`updateTrackingState()` 原先只在 `show()` 里调用一次；工具栏按钮与 `selectTarget` 都只写 `session.placementMode` / `session.audioTarget`。
- 修法：`CaptionBandView` 增加 `onTrackingChange` 回传，用 `.onChange(of: session.audioTarget)` 与 `.onChange(of: session.placementMode)` 收口到同一条重挂路径。

### 2.3 吸附期间以 15Hz 写 `UserDefaults`，并覆盖用户选定的悬浮位置（minor，但有持续 IO 与状态污染）

- 触发路径：吸附态每帧改帧都会走 `windowDidMove` / `windowDidResize` → `remember(panel)` 写 `defaults`；写进去的是目标窗口推出来的位置，用户之前挑好的自由悬浮位置因此丢失。
- 修法：`remember(_:)` 在吸附态直接返回；`windowDidMove` 里把"转自由悬浮"放在 `remember` 之前，保证用户拖动那一次仍然记得住。

### 2.4 陈旧预览草稿会跨句泄漏（major，会显示上一句的译文）

- 症状：预览被拒绝/丢弃之后（`partialText` 清零但不走定稿），下一句外语定稿会继承**上一句**的预览译文。`chineseOnly` 档下那是屏幕上唯一内容，等于给用户看错句，直到 Stage 2 落地才纠正。
- 触发路径：草稿原先只按"最近一次到达"存（`lastPartialTranslatedText`），无法判断它出自哪一句；`commit()` 与"预览被丢弃"都表现为 `partialText` 变空。
- 修法：草稿改存 `(sourceText, translatedText)`，继承前要求与定稿句有足够长的公共前缀（短句按自身长度自适应），并叠加"中文句与仅原文档不继承"的判据（`CaptionSession.inheritableDraftTranslation`，7 条断言覆盖：同句继承、短句继承、异句不继承、中文不继承、混说不继承、仅原文不继承、无草稿不继承）。

### 2.5 `dockedHorizontalMargin` 声明了却从未使用（minor，窄窗口下带子会探出目标窗口）

- 触发路径：吸附横向位置原先就是 `targetFrame.midX - width / 2`，没有夹取；目标窗口比字幕带窄时（例如窄播放器窗口）带子会横向伸出窗口之外。
- 修法：抽出 `CaptionBandWindowController.dockedFrame(targetFrame:bandSize:screens:)`，先按 `dockedHorizontalMargin` 夹进目标窗口，再兜一层所在屏幕的可视区；目标窗口比带子还窄时退回"以窗口中线对齐"，由屏幕那一层决定最终位置。

### 2.6 顺带修掉的 App 目标编译错误（基线提交从未编译过 App 目标）

`swift test` 只编译 SPM 目标，而 `CaptionWindowPicker.swift`、`CaptionSessionProductionWiring.swift`、`CaptionBandWindow.swift` 都在 `Package.swift` 的 `exclude` 列表里（只在 Xcode 目标编译），所以这三处错误此前没有任何门禁能发现：

1. `CaptionWindowPicker.swift` 引用了不存在的 `SpeechRailDesignTokens.Color.hairline` → 改用 `Color.separator` + `Stroke.hairline`。
2. `CaptionSessionProductionWiring.swift` 在非隔离类里用 `@MainActor` 类型的属性初值 → 采集适配器整体 `@MainActor`（`start()/stop()` 是协议里的 `async` 要求，该 witness 形式已用 `swiftc -swift-version 6` 单独验证合法）。
3. 同文件同步调用 `actor LLMProvider` 的方法 → 加一层 Task 桥接，消费端终止即取消 provider 侧流。

---

## 3. 静态可核验的验收面

- **DoD-1（权限）静态面成立**：整个 `macos/` 下 `CGRequestScreenCaptureAccess`、`SCShareableContent`、`SCStream`、`CGWindowListCreateImage`、`CGDisplayCreateImage`、`CGPreflightScreenCaptureAccess` **各 0 处命中**；字幕链路（`Caption*.swift`、`TargetWindowTracker.swift`）**0 处** Accessibility API（唯二命中在 `DictationSystemIntegrations.swift`，属听写输入，与字幕无关）；`macos/SpeechRailApp/SpeechRailApp/Info.plist` 含 `NSAudioCaptureUsageDescription`。窗口枚举只读 `kCGWindowNumber`/`kCGWindowOwnerPID`/`kCGWindowBounds`/`kCGWindowLayer`/`kCGWindowAlpha`，`kCGWindowName` 仅出现在注释里。
- **DoD-3 参数**：`partialDebounce` 默认 450ms、`minimumPartialDeltaChars` 默认 10、标点边界（`,.;?!，。；？！、`）可越过字符增量门槛；Stage 2 上下文取 `suffix(3)` 且 `filter { $0.id != command.lineID }`；Stage 1 上下文取 `suffix(2)`。
- **跨应用常驻前提**：面板 `hidesOnDeactivate = false`、`orderFrontRegardless()`、`collectionBehavior` 含 `.canJoinAllSpaces` 与 `.fullScreenAuxiliary`；跟随定时器在 main queue 上，不受前台焦点影响。
- **底边锚定**：`applyMetrics` 只改 `frame.size.height`（不动 `origin.y`），高度来自 `visualRowCount` + `boundingRect` 的真实可用宽度测算。
- **红线 3（不改服务端与 `/v1/realtime` 契约）成立**：改动只落在 `macos/` 与 `docs/`，`contracts/`、`src/`、`tests/` **零改动**；`RealtimeASRClient` 未被修改，线上字段与 `language: nil`（服务端 30 语种 auto）保持不变。`scripts/check_realtime_contract.py` 需要 `uv` 环境（本机直接 `python3` 跑会缺 `speechrail` 模块）本轮未跑，契约未变这一点以上面的改动范围为准。
- **定向采集链路完整（客户端侧）**：`AppAudioTapChunkSource` → `AudioSourceCoordinator.Selection(usesMicrophone: false, systemApps: [选中应用])` → `SystemAudioCapture.Selection(bundleIDs:)` → XPC helper → `CoreAudioTapCapture.Configuration(bundleIDs:)`。即选中的 bundleID 一路传到 CoreAudio tap 配置，不是"整机拿一路音频再筛"；bundleID 到进程的解析（含 helper 进程）已有 `AudioSampleRingTests` 覆盖。

### 3.1 规范 §11 条目逐条对账

| 规范条目 | 代码落点 | 覆盖方式 |
| --- | --- | --- |
| §11.1-2 稳定前缀 / 活跃尾部（预留末尾 4~6 字符或 1~2 拉丁词） | `CaptionPartialStability`：`volatileTailReserve = 5`、LCP、末尾拉丁词整体回退 | 单测 3 项（CJK、拉丁词回退、过短/无变化不分层） |
| §11.1-2 分层渲染（稳定区提对比度、尾部次级浅色） | `CaptionBandContent.sourceTiering` + `CaptionBandWindow.tieredSourceText`（稳定=正文色，尾部=`inkTertiary`） | 单测 3 项（主行、次行、无前缀时整行同色） |
| §11.1-2 底边锚定与预排版算高 | `applyMetrics` 只改 `size.height`；`visualRowCount` 走 `NSAttributedString.boundingRect` + 真实可用宽度 | 静态核验 |
| §11.2 铁律 1 双语平行滑窗 | `CaptionContextTurn.formattedPromptLine`（`原文：… → 译文：…`）；Stage 2 取 `suffix(3)`、Stage 1 取 `suffix(2)` | 单测 2 项（含 Prompt 分段断言） |
| §11.2 铁律 2 严格排除当前句 | 在 `apply` **之前**取 `lines.filter { $0.id != command.lineID }.suffix(3)` | 同上的"只带前一句"断言 |
| §11.2 铁律 3 软前缀锚定（含倒装/否定可重排） | `stabilizedDraftPrefix`（LocalAgreement-2，回退 2 字）+ `priorDraftTranslation` → 【当前句已上屏草稿】；`systemInstructions` 第 3 条写明"核心语义与极性未反转则沿用，否则重排" | 单测 2 项（回退语义、跨轮次传递 nil→草稿→稳定前缀） |
| §11.2 铁律 4 定稿交接与兜底 | `inheritableDraftTranslation` + `isTranslating: true`；失败时保留已到达前缀或 Stage 1 草稿 | 单测 5 项（含"没有客户端也不白屏"、"失败即终态不卡翻译中"） |

---

## 4. 验证证据（2026-10-26 06:11–06:46，Asia/Shanghai）

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 1 | `python3 scripts/check_macos_test_target_coverage.py` | `macos-test-target-coverage: OK` |
| 2 | `swift test --package-path macos/SpeechRailApp`（全量） | exit 0；XCTest `Executed 2109 tests, with 4 tests skipped and 0 failures`；Swift Testing `Test run with 691 tests in 66 suites passed`；失败标记 0 |
| 3 | `git diff --check` | 无输出（并顺手清掉 `design.md` 末尾多出的空行） |
| — | `bash scripts/macos_app_build.sh --configuration Debug` | `** BUILD SUCCEEDED **`（§2.6、§2.4、§7 三轮修复后各跑一次） |

方案自己写明的逐任务门禁也**原样**跑过一遍：Step 1.5 `--filter "SessionStore|SessionExporter"` = 18 项通过；Step 2.3 `--filter CaptionTranslatorTests` = 14 项通过；Step 3.2 `--filter CaptionSession` = 46 项通过。

其中一处需要留意的**门禁假覆盖**：本仓库没有名为 `SessionExporter` 的测试套件，Step 1.5 的过滤器里 `SessionExporter` 实际匹配 0 项——只跑它会让人以为"双语导出已验证过"。双语 SRT 的投影断言实际落在 `MeetingRecoveryMaterialTests` 里（本次补的三档显示模式用例），全量门禁 2 才覆盖得到。

新增/改写的测试：`CaptionTranslatorTests.swift`（14 项：软锚定跨轮次、LocalAgreement 回退、失败兜底不卡「翻译中」、无客户端继承草稿、Prompt 三段式与双语上下文、稳定前缀三种边界）、`CaptionSessionLifecycleTests.swift`（分层投影 3 项、显示模式投影 1 项、回显不转圈 1 项、防自污染与草稿交接 3 项、可继承草稿判据 8 条断言）、`MeetingRecoveryMaterialTests.swift`（双语 SRT 三种显示模式投影）。

---

## 5. 独立红队复查（第二轮，子代理）

第二轮由一次**独立**的对抗式复查完成（子代理、只读、不构建、只针对 6 个源文件 + 3 个测试文件的完整 diff，不给它作者的结论）。它交出 7 条，其中 1 条是 blocker。以下按它的编号记录结论与处理：

| # | 复查结论 | 处理 |
| --- | --- | --- |
| 1 | **blocker**：「仅中文」档把**外语原文**当译文画了出来 | 已修：投影层只在「原文真的上屏」时构造分层；渲染层加不变量（分层拼不回本格文本就整行同色），把"错挂"降级成"没分层" |
| 2 | **major**：Stage 2 终态回调抹掉刚继承的草稿，"零白屏"被自己撤销 | 已修：终态以 `终稿 ?? 继承草稿` 收口，并把兜底草稿一并持久化 |
| 3 | minor：窄目标窗口的退化分支不居中，带子向右探出 | 已修：放不下时保持以窗口中线对齐，再交给屏幕可视区夹取 |
| 4 | minor：吸附态拖左/上边缘缩放被当成"用户拖动"而脱离 | 已修：活体缩放期间不改模式；`place(panel)` 对未上屏面板是否发通知无法静态判定，列入 §6 |
| 5 | minor：分层索引与显示串不同源 | 未改代码：确认为默认关闭的实验路径，且在该路径上前缀长度恒为 0（partial 事件被挡在门外），记入 §7 |
| 6 | nit：模型原样回显时该行永久「翻译中」 | 已修：「是否还在翻」与「显示去重」分成两个判据 |
| 7 | nit：短促预览草稿仍可跨句继承 | 已修：门槛加绝对下限（4 字符）并要求"几乎逐字"；`.failed` 等非正式终态一并清草稿 |

**缺陷 1 的机理**值得单独记一句：视觉分层本质是"某根字符串的切分"，而渲染层在拿到分层时会直接渲染分层里的两段文本。只要投影层把"原文的分层"挂到了"显示译文的格子"上，渲染层就会拿英文覆盖中文。**这类错误的正确兜底是让渲染层不信任分层**，所以两处都改了——只改一处，下次换个模式又会复发。

**变异验证（证明新测试不是空断言）**：把缺陷 1、2 的修复分别回退后重跑，两条新测试都如期变红；缺陷 2 的失败信息正是 `translatedText = nil`（草稿被抹掉）。恢复代码后重跑全绿。新增用例 `testBandContentChineseOnlyWithTranslationNeverTiersSourceOverTranslation`、`testFinalizedLineKeepsInheritedDraftWhenStageTwoFailsBeforeAnyDelta`（构造"预览还在飞 → 精翻一上来就失败"的时序，这正是原先测试用 `stallForever` 恰好绕过去的那条路径）。

**复查未能证伪的部分**（它逐条检查过，我据此保留结论）：跟踪器自搬不会自脱离、切目标与「吸附回窗口」确实重挂、吸附态不写 `UserDefaults`、继承判据主体成立、屏幕夹取有效；另外核过 `sessionColumns` 20 列与 `listSessions` 子查询下标、全仓无 `kCGWindowName` 读取、桥接取消可传导到 provider、`commonPrefix` 两侧都按 `Character` 计数、词回退循环有界。

## 6. 未验证项与阻塞

1. **DoD-1 的运行时面**：选择 Chrome/Safari/QuickTime 窗口时是否真的只弹"系统录音权限"。静态面已成立（见 §3），弹窗行为必须真机点一次才算。
2. **DoD-2 的运行时面**：15Hz 吸附跟随、拖动转自由悬浮、「吸附回窗口」归位、切到 Obsidian 时仍可见。§2.1–2.3 修完之后**最该先验的就是这一条**：它此前是被自己踢出吸附态的，改动只经静态审查与编译验证，没有实机观察。
3. **DoD-3/4 的运行时面**：真实播放中日英视频时的字级观感（无白屏交接、软锚定抑制跳变）、导出 `.srt` 在播放器里的表现。
4. **`scripts/macos_app_build.sh --test-unit` 在本机为红（环境级，非本改动引入）**：`xcodebuild: error: Failed to build project SpeechRailApp ... No test bundle product for testingSpecifier`，exit 70。对照实验：在 `HEAD` 的纯净 worktree 上跑同一条命令得到**完全相同**的错误，且发生在任何编译步骤之前；追加 `-only-testing:SpeechRailAppTests` 探针同样失败；`xcodebuild -showTestPlans` 能正常解析计划。日志同时给出 `CoreSimulator is out of date. Current version (1171.7.0) is older than build version (1174.9.2)`、`Simulator device support disabled`。结论：本机 Xcode 27 与已安装 CoreSimulator 版本不匹配，需要更新系统/Xcode 后重验；同一批测试源码已由门禁 2 全绿覆盖。没有改动工程、scheme 或 test plan——没有证据指向工程缺陷。
5. **首次显示是否会被自己踢出吸附态**（复查提出、静态无法判定）：`place(panel)` 在面板上屏前就 `setFrame`，若 AppKit 对未上屏窗口也发 `NSWindowDidMoveNotification`，首帧就会走"用户拖动"分支。现在的兜底是"原点仍等于吸附落点就忽略"，但未上屏时 `lastDockedOrigin` 还是 nil，判断不生效——必须真机看首显后的吸附图标。
6. **测试质量的两处已知弱点**（复查提出，未改）：`stallForever` 用例结束时不会取消挂住的 Task（未观察到跨测试干扰，但属于测试期泄漏）；`testFinalizedLineContextExcludesItselfAndCarriesBilingualHistory` 第二段断言用刚断言的数组重建 Prompt，接近同义反复。
7. **质量与性能未测量**：翻译质量（WER/CER 改善幅度）、首字与持续延迟、#372 的字幕端到端指标，本轮**没有任何测量**，方案与调研文档里的量化收益不能据此宣称成立。

---

## 7. 已知偏离

- `CaptionWindowPicker.swift` 内部仍有裸视觉常量（圆角 14、内边距、阴影半径）：这是基线提交的欠账，本轮只把不存在的颜色引用换成既有语义 Token，没有新增裸值；按红线 6 应另起一次 Token 登记 + 设计系统文档同步。
- `dockedFrame(...)` 与吸附状态机位于 App-only 文件，SPM 测试目标无法覆盖，因此只有编译与静态审查，没有单测。
- **视觉分层只覆盖经典路径**（复查缺陷 5 的精确定位）：修订窗口（`revisionWindowEnabled`，默认关闭的实验开关）下未定稿原文来自 `windowCapture.visibleUnits`，而稳定前缀长度由 `partialText` 推导；窗口路径把 partial 类事件都挡在门外（`guard windowCapture == nil else { return }`），于是 `partialStablePrefixLength` 恒为 0，该路径整行同色、不做分层。这是**明确降级**而不是错色：当索引与文本不同源时宁可让分层失效。
- **首屏引导的形态与方案字面不同**：Step 4.5 要求空态里放「选择应用窗口」主按钮 + 运行中应用快捷列表；实现是页头唯一主入口「开始字幕」（点击即 `promptSelectTarget()` 唤起拾取器），运行中应用快捷列表与「麦克风收音」在拾取器里（Step 4.2 的底部快捷栏 + 取消）。代码内注释写明理由：同一动作在空态再放一颗按钮等于两个入口，且「开始字幕」是设计稿页头的按钮名。能力等价、入口唯一，但**字面不符**，需产品确认取舍。
- 方案文档 §5 的 DoD 勾选框**保持未勾**：第 1–4 项都要求真机/真实播放，勾上等于替未执行的动作背书。
