# 有声书工坊与音色工作流进一步优化实施方案 (Implementation Plan)

> **For agentic workers:** 本文档记录有声书工坊全流程自动化与音色机器验收上线后的进一步优化方案。按文件所有权与模块边界分阶段执行，以定向 fake 测试为先导，改动保持向后兼容或契约对齐，严格复用 `SpeechRailDesignTokens` 与原生组件。不自动提交、发布或操作服务。

**Goal:** 补齐全流程自动化的最后体验断点（人工消歧后自动锁定、克隆质检可操作引导、试听缓冲加载动效、主角专属音色优雅降级），消除用户指南与实际 UI 的微小偏差，并在算法与类型系统层面强化鲁棒性。

**Architecture:**
- 保持 macOS SwiftUI $\rightarrow$ `AudiobookWorkflowModel` / `VoiceWorkflowModel` $\rightarrow$ 控制器 $\rightarrow$ SQLite / 音色仓库的清晰单向数据流。
- 原文区间保持 $[startByte, endByte)$ 只读零改写与规范化内存投影。
- 坚决遵循“傻瓜化”与“渐进式披露”原则，首屏保持单主动作自适应推进。

**Tech Stack:** Swift 6 (`@Observable`, Sendable)、macOS 26+、SwiftUI、SQLite (WAL)、Python 3.14 (FastAPI + Pydantic v2)。

**Reference Specs:**
- 用户指南：`docs/users/audiobook-workshop.md`
- 架构设计：`docs/developers/macos-app-audiobook.md`、`docs/developers/macos-app-design-system.md`
- 算法规范：`docs/developers/audiobook-mass-casting-spec.md`
- 既有审计：`docs/audits/2026-10-15-audiobook-workshop-review.md`

---

## 阶段一：高优先级体验闭环与文档对齐 (Phase 1: High Priority)

### Task 1: 人工消歧归零后自动锁定角色与直达制作

**背景与痛点：**
当前「分析全书」在全书零歧义时已实现自动调用 `confirmCastAndAudition()` 并直通「开始制作章节」。但当分析后存在待确认对白（`unknownSpeakerCount > 0`）时，用户进入正文逐一指派角色；当指派完**最后一条**未知对白后，全书待确认数归零，但系统停留在当前状态，用户仍需手动移动鼠标到右侧面板寻找按钮触发确认。

**涉及文件：**
- `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift`
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookWorkflowTests.swift`

**技术方案：**
1. 在 `AudiobookWorkflowModel.updateDialogueCharacter(annotationID:characterID:)` 与消歧处理成功的回调路径中，计算变更后的未确认台词数；
2. 当且仅当 `previousUnknownCount > 0 && currentUnknownCount == 0`，且全书所有出场角色均已具备合法声线绑定时：
   - 自动在后台调用 `await self.confirmCastAndAudition()`；
   - 若自动锁定成功且 `workbenchTab == .preparation`：
     - 将顶部 `bannerMessage` 设置为：“全部台词已确认完毕，角色与音色已自动锁定，可直接开始制作章节。”；
     - 主按钮自适应亮起「开始制作章节」；
3. 若自动锁定因存储或并发冲突失败，设置 `errorMessage` 明确说明失败原因，保留人工重试入口，不得静默吞掉异常。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-1.1 (状态跃迁断言)**：在正文消歧场景中，当未确认台词数从 $1 \rightarrow 0$ 时，无需用户点击任何额外按钮，`isAuditionConfirmedForSelectedBook` 自动变为 `true`，且 `selectedBook?.confirmedAuditionVoiceSetDigest` 不为空。
- [ ] **AC-1.2 (UI 主动作自适应)**：确认完成后，工作台操作栏右下角主按钮的标识符为 `audiobook-start-production-action-button`，文字标签为「开始制作章节」，图标为 `play.circle.fill`。
- [ ] **AC-1.3 (提示文案)**：顶部 Banner 显示：“全部台词已确认完毕，角色与音色已自动锁定，可直接开始制作章节。”，且无报错红字。
- [ ] **AC-1.4 (负向防误触发)**：若仍有 $\ge 1$ 条对白未确认，或存在未绑定音色的角色，消歧单条操作后**不得**触发锁定，主按钮保持为「一键智能配声」或待确认状态。
- [ ] **AC-1.5 (自动化单测)**：在 `AudiobookWorkflowTests` 中新增用例 `testResolvingLastUnknownSpeakerAutoConfirmsCastAndEnablesProduction`，模拟单条未知对白被指派为已知角色，断言自动触发锁定且代次递增。

---

### Task 2: 同步用户使用指南与最新 UI 交互

**背景与痛点：**
`docs/users/audiobook-workshop.md` 第 37 行仍保留了旧版的交互描述（“在人物与声音中为旁白和主要角色选择声音……再点击应用配声方案。试听满意后点击确认配声”），与当前收敛后的「一键智能配声 $\rightarrow$ 开始制作章节」以及「更多整理…」折叠菜单不一致。

**涉及文件：**
- `docs/users/audiobook-workshop.md`

**技术方案：**
1. 将第三步“全书角色梳理与音色试听”更新为当前实际行为：
   - 描述「分析全书」的一键推进流水线（对白提取 $\rightarrow$ 二次消歧 $\rightarrow$ 补全六类群像 $\rightarrow$ 生成核心主角音色 $\rightarrow$ 防撞音预绑定）；
   - 明确零歧义时自动锁定与直达制作的特性；
   - 明确有歧义时的快速定位流程，以及消除完毕后的自动锁定；
2. 更新操作栏收敛描述：
   - 记录主操作按钮的自适应演变（「一键智能配声」 $\rightarrow$ 「开始制作章节」）；
   - 明确「更多整理…」折叠菜单所包含的高级操作（补全群像、主角定制、按声部批量配声、合并/拆分角色、撤销配声）；
3. 检查并运行 `python scripts/check_user_doc_contract.py` 确保文档检查通过。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-2.1 (步骤描述对齐)**：用户指南第三节不再出现“在试听与分配说明中比较同一段原文……再点击应用配声方案”这一旧流程，准确描述“全书分析一键到底”及“开始制作章节”主按钮自适应行为。
- [ ] **AC-2.2 (菜单操作对齐)**：文档中明确记载「更多整理…」折叠菜单位置及其 5 项子操作（补全六类群像、为主角生成专属音色、按声部批量配音、合并/拆分角色、撤销上次配声）。
- [ ] **AC-2.3 (自动化契约检查)**：运行 `uv run --no-sync python scripts/check_user_doc_contract.py` 退出码为 0，契约覆盖项 100% 匹配。

---

## 阶段二：算法与容错增强 (Phase 2: Algorithms & Robustness)

### Task 3: 声音克隆质量未通过时的具体排障指引

**背景与痛点：**
`VoiceCloneView` 在克隆注册后自动启动 `checkVoiceOutput` 探针，但当探针未通过时，目前仅展示“配音效果检查未通过：\(message)”与“重新检查”按钮。如果由于参考音频底层信噪比低或静音截断失败，用户盲目重复点击重新检查无法解决问题。

**涉及文件：**
- `macos/SpeechRailApp/SpeechRailApp/VoiceCloneView.swift`
- `macos/SpeechRailApp/SpeechRailMacControlTests/AppModelTests.swift`

**技术方案：**
1. 解析 `checkVoiceOutput` 返回的错误码或错误消息关键词；
2. 在 `StatusBanner` 中追加排障建议引导卡片：
   - 若为 `snr` / 噪音问题：提示“参考音频环境噪音偏高，建议在安静环境下录制，或使用降噪后的音频”；
   - 若为 `duration` / 时长问题：提示“参考音频有效语音过短，建议提供 5～15 秒连续自然语流”；
   - 若为 `silence` / 静音问题：提示“参考音频首尾包含过多静音，建议裁剪后再试”；
3. 保留“重新检查”动作的同时，提供“重新录制/选择音频”直达动作。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-3.1 (噪音错误排障映射)**：当返回包含 `snr` 或 `noise` 时，Banner 提示包含“环境噪音偏高，建议在安静环境下录制”。
- [ ] **AC-3.2 (时长错误排障映射)**：当返回包含 `duration` 或 `short` 时，Banner 提示包含“有效语音过短，建议提供 5～15 秒连续自然语流”。
- [ ] **AC-3.3 (静音截断排障映射)**：当返回包含 `silence` 时，Banner 提示包含“包含过多静音，建议裁剪”。
- [ ] **AC-3.4 (操作可用性)**：横幅同时展示「重新检查」按钮与「重新录制」直达操作，点击「重新录制」重置克隆步骤并保留名称。
- [ ] **AC-3.5 (单测覆盖)**：`AppModelTests` 中针对三种典型错误码断言 UI 引导文案与动作状态。

---

### Task 4: 主角专属音色生成的优雅降级与进度通知

**背景与痛点：**
长篇小说主要角色较多时，自动为核心主角生成定制音色会串行经历多次模型调用与机器复验。若其中某位角色因算力超时或机器复验不达标而未能生成专属音色，目前虽然能捕获异常继续下一位，但用户无法得知哪些角色回退到了群像音色。

**涉及文件：**
- `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift`
- `macos/SpeechRailApp/SpeechRailMacControlTests/AppModelTests.swift`

**技术方案：**
1. 在 `createExclusiveVoicesForLeadCharacters` 中收集生成结果指标：`attemptedCount`、`succeededCount`、`fallbackCount` 与具体角色名；
2. 若存在部分回退，在分析完成后的 Banner 中精准呈现：
   - 示例：“已为 3 位主要角色生成专属音色；角色「贾宝玉」已自动回退至高质量青年群像音色”；
3. 在角色卡片展开详情中，若该角色使用的是自动回退的群像音色，在“专属定制…”菜单旁提供显式重试标识。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-4.1 (无异常全成功)**：所有主角定制均成功时，Banner 说明为：“已为 N 名主要角色生成专属音色”。
- [ ] **AC-4.2 (部分失败降级文案)**：若 $M$ 个角色定制失败，流水线**不中断**，Banner 准确报告成功数与回退角色名单（如“已为 2 名主角生成专属音色，1 名角色（张三）已回退为青年男声群像音色”）。
- [ ] **AC-4.3 (无声线缺失)**：降级角色的音色绑定必须指向合法的已注册六类群像音色，不得出现 `binding == nil` 的非法状态。
- [ ] **AC-4.4 (单测断言)**：新增用例模拟第 2 位主角设计 API 超时，验证流水线成功完成，全书无未绑定角色，降级角色正确绑定群像音色。

---

### Task 5: DSATUR 在极端低音色池下的色数预警与扩展引导

**背景与痛点：**
当用户本地可用音色极少（如仅 2~3 个），但作品中有多位次要角色同场对话时，DSATUR 算法受限于可用颜色数小于图的色数（Chromatic Number），必然产生同场撞音，并在卡片上出现多个黄色冲突告警。

**涉及文件：**
- `macos/SpeechRailApp/SpeechRailApp/AudiobookCastRegistry.swift`
- `macos/SpeechRailApp/SpeechRailApp/AudiobookBookWorkspaceView.swift`
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookCastTests.swift`

**技术方案：**
1. 在 `AudiobookCastRegistry.makeCastingPlan` 中，统计同场硬冲突边数。若存在不可避免的硬冲突（即冲突角色无法在现有音色池内找到无冲突染色）：
   - 在 `AudiobookCastingPlan` 中标记 `hasUnavoidableSceneConflicts = true`；
2. 工作台检测到该标记时，在操作栏上方呈现轻量引导条：
   - “当前音色数量不足以完全避开同场角色撞音，建议在「更多整理…」中点击「补全六类群像」扩展音色库。”；
3. 一旦用户补全群像音色，自动重新触发 DSATUR 着色消除冲突。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-5.1 (色数预警触发)**：当可用音色数 $<$ 冲突图最大团（Clique）大小时，生成的 `AudiobookCastingPlan.hasUnavoidableSceneConflicts` 必为 `true`。
- [ ] **AC-5.2 (UI 引导条呈现)**：工作台操作栏上方显式展示 `attention` 语义引导条，文案提示“建议在「更多整理…」中点击「补全六类群像」扩展音色库”。
- [ ] **AC-5.3 (预警自动消除)**：当群像补全完成后重新跑排音，若冲突边降为 0，引导条自动隐退。
- [ ] **AC-5.4 (定向测试)**：在 `AudiobookCastTests` 中构造 4 角色同场图与 2 音色池夹具，断言 `hasUnavoidableSceneConflicts == true` 且算法在有限 workBudget 内收敛。

---

### Task 6: Swift API 客户端 Review 模式的编译期类型安全

**背景与痛点：**
目前 `ServiceAPIClient.validateVoiceDesignCandidate` 接收 `humanReview: VoiceDesignHumanReview?, automatedAcceptance: Bool` 两个分离参数，尽管运行期由后端 Pydantic 进行互斥校验，但在 Swift 客户端调用处允许传入非法组合。

**涉及文件：**
- `macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift`
- `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`
- `macos/SpeechRailApp/SpeechRailApp/VoiceWorkflowModel.swift`
- `macos/SpeechRailApp/SpeechRailMacControlTests/AppModelTests.swift`

**技术方案：**
1. 在 `CreatorServiceClient.swift` 定义严格互斥的枚举：
   ```swift
   public enum VoiceDesignValidationMode: Sendable, Equatable {
       case validationOnly
       case automatedAcceptance
       case manualReview(VoiceDesignHumanReview)
   }
   ```
2. 更新 `SpeechRailVoiceDesignClient` 接口协议签名：
   ```swift
   func validateVoiceDesignCandidate(
       id: String,
       testText: String?,
       capabilityKey: String?,
       mode: VoiceDesignValidationMode
   ) async throws -> VoiceDesignCandidate
   ```
3. 在 `ServiceAPIClient` 中将 `VoiceDesignValidationMode` 编码为请求体，杜绝非法参数共存，同时保留内部 UITest 存根与单元测试对齐。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-6.1 (编译期互斥保障)**：调用方无法同时指定 `automatedAcceptance` 与 `humanReview`，参数组合错误直接在编译阶段暴露。
- [ ] **AC-6.2 (协议与实现无缝解码)**：三种枚举模式分别编码为：
  - `.validationOnly` $\rightarrow$ `human_review: nil, automated_acceptance: false`
  - `.automatedAcceptance` $\rightarrow$ `human_review: nil, automated_acceptance: true`
  - `.manualReview(r)` $\rightarrow$ `human_review: r, automated_acceptance: false`
- [ ] **AC-6.3 (零破坏编译与测试)**：`ServiceAPIClient`、`UITestCreatorClient`、`VoiceWorkflowModel` 和 `AppModelTests` 均切换为新枚举签名，`swift test` 全部编译通过且原有 90 项单测无回归。

---

## 阶段三：交互细节润色 (Phase 3: UX & Micro-interactions)

### Task 7: 试听即时缓冲加载态动效

**背景与痛点：**
角色卡片右侧的试听按钮（`play.circle.fill`）在首次试听或未命中缓存时，需向后端申请合成试听音频（耗时约 200~500ms）。此期间按钮无视觉反馈，用户容易怀疑未触发而多次重复点击。

**涉及文件：**
- `macos/SpeechRailApp/SpeechRailApp/AudiobookBookWorkspaceView.swift`

**技术方案：**
1. 在视图局部状态增加 `@State private var auditionLoadingRoleID: UUID? = nil`；
2. 当用户点击试听：
   - 立即设置 `auditionLoadingRoleID = role.id`；
   - 试听按钮渲染微型 `ProgressView().controlSize(.small)` 代替播放图标；
3. 当音频首帧开始播放或播放器就绪后，重置 `auditionLoadingRoleID = nil` 并转入 `auditionPreviewRoleID = role.id`（呈现停止图标 `stop.circle.fill`）；若合成失败或取消则安全复位。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-7.1 (点击即时反馈)**：点击未缓存试听的角色试听按钮，按钮在 1 帧内变更为 `ProgressView`，禁用重复触发（防抖）。
- [ ] **AC-7.2 (播放态平滑切换)**：音频开始播放瞬间，`ProgressView` 平滑切换为 `stop.circle.fill`（颜色为 `SpeechRailDesignTokens.Color.attention`）。
- [ ] **AC-7.3 (异常与停止复位)**：点击停止按钮、试听播放结束或合成报错时，状态立即复位为默认的 `play.circle.fill`。
- [ ] **AC-7.4 (无障碍标签)**：加载中状态的无障碍标签为“正在生成试听音频…”。

---

### Task 8: 角色卡片批量展开 / 折叠快捷控制

**背景与痛点：**
角色卡片采用渐进式披露极大净化了界面。但在全书选角复核阶段，专业用户有时希望一次性横向扫视所有角色的声学画像和原文依据，逐个点击展开效率较低。

**涉及文件：**
- `macos/SpeechRailApp/SpeechRailApp/AudiobookBookWorkspaceView.swift`

**技术方案：**
1. 在工作台「人物与声音」顶部的角色数量统计区（如“出场角色 (18)”）右侧，增加小巧的次级控制按钮：
   - 当展开角色数 $< \text{总角色数}$ 时，显示「全部展开」；
   - 当全部展开时，显示「全部收起」；
2. 内部通过 `withAnimation(.easeInOut(duration: 0.15))` 批量修改 `expandedRoleIDs` 集合；
3. 同时在「更多整理…」菜单中收录此操作，保持键盘与菜单可访问性。

**验收标准 (Acceptance Criteria):**
- [ ] **AC-8.1 (状态双向同步)**：
  - 点击「全部展开」，所有可见角色卡片的声学画像、原文依据与微调菜单立即展开；
  - 展开后按钮文字自动更新为「全部收起」；
  - 再次点击「全部收起」，所有卡片收敛至折叠胶囊态。
- [ ] **AC-8.2 (部分展开自适应)**：若用户手工展开了部分卡片（$0 < K < N$），顶栏按钮显示为「全部展开」，点击后补齐展开剩余卡片。
- [ ] **AC-8.3 (无视觉破坏)**：批量展开在 100+ 角色下界面无掉帧（滚动视图内部由 `LazyVStack` 保障复用），间距和内边距严格复用 `SpeechRailDesignTokens`。

---

## 全局硬性门禁与通过准则 (Global Hard Gates & Exit Criteria)

所有优化任务实施必须满足以下**全部 6 项硬性门禁**，任一项未达标均不得宣称任务完成：

1. **确定性测试与零外部依赖**：
   - 所有自动化用例必须使用 fake backend 与内存 SQLite 临时库；
   - 严禁下载外部模型、发起公网 HTTP 请求或读写本地未授权目录。
2. **零运行时告警与类型安全**：
   - SwiftPM 编译与 Xcode Debug 构建通过，无任何 Concurrency、Sendability 或未处理的可选型告警；
   - Python 代码通过 Mypy 全量类型检查（189 个源文件 0 错误）。
3. **Design Tokens 100% 遵从**：
   - 所有 UI 修改不得出现散落的裸颜色（`Color.red` / `Color.blue` 等）或裸数值边距；
   - 严格引用 `SpeechRailDesignTokens.swift` 中声明的语义颜色、间距标度与圆角形状。
4. **共享门禁回归 (Quality Gate)**：
   - 运行 `bash scripts/ci_quality_gate.sh --base-ref origin/main`：
     - Ruff 代码风格检查：通过
     - Mypy 静态类型检查：通过
     - 版本一致性检查：通过
     - OpenAPI 合规校验：通过
     - 用户文档覆盖与契约对齐：通过
     - macOS 测试 target 覆盖率：通过
     - macOS 路由契约：通过
5. **既有测试套件零回归**：
   - `swift test --package-path macos/SpeechRailApp --filter AppModelTests`：90/90 pass。
   - `swift test --package-path macos/SpeechRailApp --filter AudiobookAcceptanceTests`：100% pass。
   - Python 单元测试（`test_candidate_validation_usecase.py`、`test_voice_design_workflow.py`、`test_app_contract.py`）：全部 pass。
6. **Git 交付与隐私规范**：
   - Commit 信息符合 `<type>: <why>` 格式；
   - 提交前执行 `git diff --staged --check`，无多余空格与敏感字段泄漏；
   - 保护线性历史，禁止 force-push。
