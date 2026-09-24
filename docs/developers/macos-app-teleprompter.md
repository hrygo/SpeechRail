---
title: "SpeechRail macOS App AI 提词器"
status: active
version: "0.4.2"
date: 2026-09-24
---

# SpeechRail macOS App AI 提词器

AI 提词器是 macOS App 内的直播准备、手动提词与可选语音辅助能力。它面向主播本人：用户在独立舞台窗口中看到稿件；语音开启时只显示最小采集状态，直播软件只应采集摄像头或目标内容窗口，不采集提词器舞台或整屏。

> 舞台交互、快捷键、控制显隐和语音生命周期以 [`提词器舞台：手动优先、语音辅助工程规格`](../superpowers/specs/2026-09-24-teleprompter-manual-first-design.md) 为准；本文说明当前实现边界与验证状态。

## 产品边界

- 输入为用户粘贴的纯文本，或导入 `TXT` / `Markdown` 文件。
- AI 仅由用户主动触发；短稿一次窗口请求，长稿按最多 24 个本地单元逐窗口处理。正常整理每窗分成两个有界请求：`teleprompter.grouping.v1` 只分配连续来源区间，`teleprompter.rewrite.v1` 只按程序分配的 `block_id` 生成朗读候选。原文、UTF-16 范围和来源组由本地程序持有；可恢复的单窗失败会逐字保留原文并标记待确认，不把回退计作 AI 成功。
- 原稿无需 AI 即可开始；草稿自动保存，AI 标注是可选步骤，建议经用户确认后才成为活动版本。跟读期间固定版本，不允许切稿或编辑。
- 默认手动：打开舞台不申请麦克风、不连接 ASR，也不要求 AI 整理；语音跟随只能由用户显式开启，手动接管后立即撤销旧的语音推进权并释放本功能占用。
- 运行时复用现有 `MicrophoneCapture`、`RealtimeASRClient` 和 `SessionCoordinator`，但不创建 `SessionStore` 会话行，也不保存 PCM、摄像头画面、直播画面或完整 ASR 文本。
- 不包含 TTS、摄像头采集、直播推流、全局提词热键或云端稿件同步。

## 用户旅程

1. 从侧边栏打开「AI 提词器」，新建、粘贴或导入稿件；草稿无需先生成版本即可保存。
2. 点击「打开提词器」直接进入可手动阅读的舞台；此动作不会申请麦克风或连接 ASR，AI 朗读标注也不会阻塞开始。
3. 如使用 AI，先看懂“已经完成什么、原稿有没有被改、下一步要做什么”，再审阅朗读稿；默认路径使用普通用户语言，高级的拆分、合并和来源编辑收进“编辑本段”等渐进式披露入口。确认采用前可查看原文对照、修改、保留原文或跳过；编辑段落时清空对应旧辅助标注。
4. 在显示设置中选择 1／2／3 行并调整字号、背景透明度（0–100%）；三行模式上方显示已读行、中间显示当前行、下方预览下一行。正文按可用宽度自然折行并映射回稿件；三行在稿首／稿尾留空槽，避免当前行跳位。舞台按行数与字号调整高度，最多 360pt；绿色缩放横向铺满屏幕可用宽度。控制区首次展示 2 秒，指针进入操作区后显示，离开后 250ms 隐藏；正文布局和键盘可达性不随控制显隐变化。
5. 使用空格/→/↓/PageDown 下一行，←/↑/PageUp 上一行，Home/End 首末行；`⌘⌥←/→` 是应用菜单中的上一行／下一行快捷键。控制按钮和所有快捷键统一移动到对应行的原稿位置；「查阅全稿」仍提供完整段落滚动与文本选择。短暂脱稿时保持位置，需要语音协助时再点击「开启语音跟随」。
6. 开启语音后，会话从当前段建立一条 pipeline；任何手动定位立即进入手动态、废弃旧 generation，并异步停止本功能麦克风、上传、drain/clear 和占用。只有明确点击「恢复/重试语音跟随」才可再次启动。
7. 到达末行、反复下一行或读完末行都不会自动弹出总结或关闭窗口；用户点「关闭」、按 Esc 或关闭窗口时统一停止并释放提词器自己的资源，保留阅读位置。直播软件必须选择摄像头或目标内容窗口，不分享包含提词器的屏幕。不能依赖 `NSWindow.sharingType = .none` 隐藏窗口；当前 Apple 文档已将该值标注为系统不再使用的旧常量。

## 模块边界

| 模块 | 责任 |
|---|---|
| `TeleprompterDomain.swift` | 稿件、版本、段落、暂停提示、运行状态与对齐结果类型 |
| `TeleprompterNormalizer.swift` / `TeleprompterSegmenter.swift` | 中英文归一化、填充词过滤、确定性分段和 UTF-16 原文区间 |
| `TeleprompterPreparationPrompts.swift` / `TeleprompterPreparationPipeline.swift` | 整理的 grouping/rewrite/reduce prompt、严格 JSON decoder、预算、取消、局部恢复与原子装配 |
| `TeleprompterAnalysis.swift` | 已确认朗读稿的可选 AI 朗读标注，不与整理 workflow 混用 |
| `TeleprompterStore.swift` | Application Support 下单稿件 JSON、原子保存、运行进度和 Markdown 导出 |
| `TeleprompterFollowController.swift` | partial/completed 事件与跟读、暂停、手动接管状态机 |
| `TeleprompterVoiceAssistLifecycle.swift` | 显式启停、generation token、停止失败重试与旧回调失效的纯状态机 |
| `TeleprompterStageInteractionPolicy.swift` | 舞台控制显隐原因与 2s/250ms/4s 时序契约 |
| `TeleprompterRealtimeClientProtocol.swift` | Session 测试 seam：让生产 Realtime 生命周期可直接注入 fake client |
| `TeleprompterSession.swift` | MainActor 会话编排、服务/麦克风门禁、Realtime 生命周期和失败降级 |
| `TeleprompterView.swift` | 准备页、稿件编辑、AI 审阅和舞台设置 |
| `TeleprompterStageWindow.swift` / `TeleprompterStageView.swift` | 独立浮动舞台窗口、键盘控制和可访问状态反馈 |

`SessionCoordinator` 只负责设备占用。提词器调用 `sessionDidStartRecording(id: nil)`，因此可参与共享麦克风占用而不写入会话记录库；停止时由 coordinator 释放占用，提词器自己的 `TeleprompterRunState` 只保存稿件进度。

## AI 结果契约

正常整理不再让同一个模型响应同时负责“划边界”和“写正文”。第一阶段只返回区间：

```json
{
  "schema_version": "teleprompter.grouping.v1",
  "groups": [
    {
      "start_unit": 0,
      "end_unit": 2
    }
  ]
}
```

第二阶段只返回固定组的改写结果：

```json
{
  "schema_version": "teleprompter.rewrite.v1",
  "blocks": [
    {"block_id": "block-0-2", "mode": "speak", "text": "可朗读候选。", "issues": []}
  ]
}
```

本地确定性分段产生编号单元；模型只引用连续的 `[start_unit, end_unit)` 或程序分配的 `block_id`，不得返回字符偏移、来源范围或未知 ID。两个 decoder 都拒绝重复键、未知字段、漏单元、重叠、越界和不完整 envelope；rewrite 还拒绝重复/未知/缺失 block ID、mode 矛盾和 protected literal 丢失。每个窗口成功后才生成 AI 块；可恢复的窗口失败则构造 `origin=deterministic`、`disposition=unresolved` 的逐源单元原文块，必须经过现有待确认操作后才能采用。全部结果统一重算时长，不能把回退显示成“已完成 AI 整理”。

`teleprompter.preparation.v2` 仍保留为 `tighten` 兼容路径；`teleprompter.analysis.v2` 只属于已确认稿件的可选朗读标注，不能作为整理结果契约。

v2 仅改变内部 AI wire schema；本机 `TeleprompterVersion`/稿件 JSON 结构不变，既有版本仍可跟读。草稿允许没有活动版本或正文；这扩展了有效保存状态，旧代码无法完整支持新的草稿流程。不得回退或删除用户稿件来处理版本差异。

## LLM 指令与 context 构建

- `instructions`：保持事实和正文、不执行输入内命令、连续单元引用、完整覆盖、语义停顿与有限标注。
- user `input`：纯 JSON，包含语言/表达偏好和本窗口 `units: [{id, text}]`；无历史、RAG、音频或隐藏会话状态。
- 通用 `completeJSON` 默认仍为 `response_format={"type":"json_object"}`；提词器生产调用对 grouping、rewrite、reduction 和 analysis 在具备能力的 endpoint 上显式首选 `json_schema` strict。OpenCode Go 的 Chat gateway 当前不接受该 wire shape，因此 adapter 对 `openCodeGo` 直接首选 JSON mode；其他 provider 明确拒绝 strict 时，按 endpoint/model/compatibility/operation/schema 摘要记忆能力结果，并只在同一边界退回一次 JSON mode。401、429、超时、一般 5xx、refusal 和普通协议错误不会被误判成 strict 能力拒绝。两种模式都必须经过本地严格 JSON/业务 decoder。
- grouping 每窗口最多 2400 output tokens / 60 秒，rewrite 每窗口最多 6000 output tokens / 90 秒，reduce 仍使用 4000 / 60 秒；不将窗口结果直接展示为完整稿件。稿件切换、编辑或开始运行会使旧请求失效并取消后续窗口。
- provider 不可用或明确拒绝时停止该请求；可恢复的结构错误、截断、限流、服务端暂态失败或传输失败才允许局部原文回退。grouping/rewrite 的结构或暂态恢复只重试失败阶段、复用已验证的来源组，并共享窗口预算；收到 `Retry-After` 时等待且可取消。首次发送的说明与按 endpoint/model 保存的确认保持原有流程。

## 位置跟读与恢复

对齐单位为讲稿中的中文字符、英文完整词，以及受限语法识别出的数值表达，而非 ASR turn 或 UI 段落；每个单位保留讲稿 UTF-16 原文范围。不再全局删除英文词内部的 `um` 或正文中的“然后”。确定性等价覆盖服务端已测试的年份、百分比、小数和常见单位形式（例如“二零二六年/2026年”“百分之五十/50%”“三点一四/3.14”“十个人/10个人”）；年份中的逐位数字“〇”也按零字本地对齐（如“二〇二六年/2026年”），不改变服务端 ITN 规则。不声称支持所有数值读法或声学逐字时间戳。

`TeleprompterAligner` 使用有界半全局编辑距离：输入最多保留 72 个 canonical unit，默认搜索锚点前 80、后 320 个 unit，允许插入、删除和替换；候选位置不再要求 ASR 最后一个 token 与稿件尾 token 完全相等。少于三单位也会尝试对齐；一至二单位只在锚点附近具备唯一证据或明显胜过竞争位置时推进，重复短语保持原位。多处相似位置差距不足也保持原位。该分数是启发式匹配值，不是校准概率。

Realtime 的 delta 按 `itemID` 累积，revisioned snapshot 按全文替换；`eventID` 用于有界重复抑制，已终结 item 或较旧 item 的迟到 final 不得覆盖较新的确认位置。高置信 partial 可以暂定推进，final 才确认；一次 final 未匹配时保留最后确认位置并进入“追赶”状态，连续两次未匹配转为自由发挥。之后读回唯一、向前或锚点附近的稿件片段即可重新锚定。短片段若位置含糊则暂存有限上下文，不会因重复短语随机跳转。阈值是可注入策略的初始值，不是实音频质量结论；转写正文、item/event ID 和 PCM 都不落日志或持久化。 舞台状态胶囊区分“等待声音请开讲…”“听见你了，正在跟上稿件…”“跟读咬合”“正在跟上稿件”和“自由发挥中”，暂停与手动浏览时也显示对应状态；主舞台不展示识别原文、置信度或协议事件名。

正常阅读舞台按当前字号与可用宽度展示 1／2／3 条实际排版行，当前原文位置以段落索引与 UTF-16 偏移定位；三行时上行为已读上下文、中行为当前行、下行为下一行。行列表是派生展示缓存，不进入稿件持久化。显式「查阅全稿」仍按完整语义段落滚动并允许原生文本选择；字词对齐切片只服务跟读控制器，不作为独立视觉行。语音跟读仍依据既有段落与 UTF-16 位置推进。手动定位、全稿滚动接管或关闭会同步撤销语音推进权，退休已知 item；会话层 drain/clear 排除尚未收到的旧事件，generation token 排除已关闭连接的迟到结果。手动接管后 final 不得把 UI 改回跟读态，也不得自动恢复采集。末行不触发完稿页或自动关闭；舞台计时按一次打开到关闭连续计算，不随语音启停重置。

运行中不调用 LLM，不保存音频或转写。稿件和最后段落位置持久化；句内位置仅在本次运行内保留。AI、服务或识别失败均不阻止用户手动看稿。

## 跟读验收边界

确定性 fake-event 测试只证明 canonicalization、位置决策、snapshot 替换、final 确认和乱序恢复逻辑；不证明麦克风采集、Realtime ASR 识别准确率、视觉呈现或长时间运行质量。实音频验收应覆盖目标语言、数字/日期/货币、邮箱、产品名与领域词，并分别统计空转写、截断、延迟和位置恢复；snapshot 修订必须按全文替换来评估。当前跟读是文本相似度驱动的短语/字符范围定位，不提供词级时间戳；精确词级跟随需要未来 ASR 时间戳或声学强制对齐能力。

## 设计 token 约束

所有提词器新增尺寸、字号、行距、背景透明度范围、内容间距、视线吸顶偏移和窗口 autosave 名称位于 `SpeechRailDesignTokens.Teleprompter`。正常阅读舞台以 `TeleprompterStageLineLayout` 得到的实际显示行为单位，显示条数为 1／2／3，默认 3 行；每行映射回原稿段落索引和 UTF-16 范围。全稿模式仍展示完整语义段落，不展示内部跟读对齐切片；正文填满舞台可用宽度。

- **手动优先的阅读层**：正文、错误提示和最小辅助条是阅读层；操作栏是独立控制层。手动打开、翻段、滚轮接管和语音启停都不改变正文几何。
- **控制显隐**：首次打开展示 2s，指针离开后延迟 250ms 隐藏；错误提示独立保留 4s。指针位于舞台、控制焦点存在、popover/menu 打开、VoiceOver 开启、键盘主动请求或用户选择「始终显示控制」时保持可见。所有时长集中在 `TeleprompterStageInteractionPolicy`，不允许页面散落第二套数值。
- **紧凑预留，不重排**：顶部辅助条只在计时/进度或实际采集状态需要时显示，固定 `stageAuxiliaryBarHeight`（24pt）；底部控制区固定 `stageControlAreaHeight`（48pt）。隐藏只撤下操作内容与无障碍子树，保留紧凑槽位避免台词跳动；隐藏控件不响应点击。
- **最小辅助状态**：只有实际采集时显示「麦克风使用中」角标；计时与进度默认关闭，用户开启 `showClockAndProgress` 后才显示。两者都不以常驻节奏评价、段末训导或状态看板抢占台词。
- **末段即正文**：舞台没有自动完稿、复盘或末段关闭分支。用户关闭、按 Esc、窗口系统关闭和程序关闭统一调用 `closeStage()`，释放本功能的麦克风、client 与 coordinator 占用，同时保留阅读位置。
- **键盘与菜单**：舞台阅读区域在用户显式打开窗口后获得键盘焦点；空格/→/↓/PageDown 下一显示行，←/↑/PageUp 上一显示行，Home/End 首末行，Esc 关闭。设置控件或弹层获得焦点时不执行阅读命令；关闭设置后焦点返回阅读区。Tab 请求显示控制区，应用菜单仍提供全部核心动作；菜单上一行/下一行分别使用 `⌘⌥←` / `⌘⌥→`，不占用全局裸方向键；关闭使用 Command-Esc。字号与背景透明度的 Command-=/-/0 和 Command-[/] 是舞台内辅助快捷键；不再用 Command-A 切换全稿，也不让空格隐式开启语音。
- **语音与设置**：语音按钮状态来自 `TeleprompterVoiceAssistLifecycle`；`off`、`starting`、`following`、`stopping`、`stopFailed`、`pausedByUser`、`unavailable` 都必须有明确文案。`alwaysShowControls` 与 `showClockAndProgress` 使用独立 UserDefaults 键，默认关闭，旧版本可忽略。
- **窗口边界**：舞台是独立 `NSPanel`；用户从提词器入口打开时成为 key window 以确保局部快捷键可用，不在正文更新或后台语音回调时抢焦点。最大化经标准 frame 策略横向铺满屏幕可用宽度，高度不超过 `stageMaximumHeight`（360pt），并保留普通尺寸；读取设置时不会重置窗口。窗口只复用系统材质、语义色、系统按钮和既有 `Corner`/`Spacing`/`Typography`，不为隐藏控制新增自绘玻璃或裸视觉常量。

## 验收与限制

2026-09-21：使用合成文本、fake completion 和临时目录执行聚焦测试；新增 grouping/rewrite schema、重复键/未知字段/范围覆盖、strict 能力记忆与退回、`Retry-After` 等待、rewrite 阶段级重试、局部原文回退、部分窗口失败、Reduce 保留叶子和脱敏诊断覆盖。App Debug 编译用于检查会话和 SwiftUI 接线；不代表实际视觉或真实模型跟读质量验收。

```bash
swift test --package-path macos/SpeechRailApp --filter Teleprompter
scripts/macos_app_build.sh --configuration Debug
```

未执行真实麦克风、真实 LLM 效果、Realtime 端到端、OBS/会议软件可见性或 UI 自动化。仍需测量首轮/恢复后完成率、AI/原文回退占比、事实审阅、误跳、位置滞后、脱稿恢复耗时、手动纠正频率和滚动观感。没有新增 ASR 模型、强制对齐器、全局热键或提纲语义跟读。

回退时仅撤回本轮源码差异，保留稿件 JSON；不可整文件还原并行任务的修改，也不可将 AI v2 输出交给旧 v1 decoder。

2026-09-24：跟读闭环改为确定性 ITN 等价、尾词容错和短片段消歧；加入确认位置迟滞、自由发挥/重新锚定及共享 Realtime 事件 reducer。合成文本与 fake-event 验证不代表真实音频识别或视觉验收。

2026-09-24：工作台稿件名称改用共享单行输入配方 `.speechRailSingleLineInput(.regular)`，统一 12pt 横向文字内边距与 34pt 最小高度；同一配方已覆盖全 App 28 处单行输入（证据与范围见 [`macOS App 设计系统与 Token`](macos-app-design-system.md) §6）。`swift test --package-path macos/SpeechRailApp` 110 项测试 / 12 个 suite 全部通过；完整 Xcode App Debug 构建在受限环境里既被 SwiftPM manifest 的 `sandbox-exec` 阻止、也因 GitHub 依赖解析被拒，未完成桌面视觉走查或 UI 自动化；真实观感与窄窗布局仍需人工验证。

2026-09-24 20:28：舞台落地为「手动优先、语音辅助」。`TeleprompterSessionLifecycleTests` 覆盖手动打开零音频副作用、不采用未确认 AI 草稿、旧事件失效、延迟连接释放、幂等关闭、停止失败 fail-closed、位置保留与计时连续；新增 interaction/lifecycle 纯策略回归。`swift test` 共 128 项 / 15 个 suite 全部通过；88 个 App Swift 源文件经 `swiftc -disable-sandbox -typecheck -swift-version 6 -target arm64-apple-macos26.0` 退出码 0，仅 1 条既存 `maxTokens` 弃用警告。三项新增生产文件已加入 `SpeechRailApp.xcodeproj` 的 App target 与 Sources phase，`plutil -lint project.pbxproj` 通过；完整 Xcode App Debug 构建仍未执行：仓库包装脚本的审批通道返回内部错误；UI 淡出几何、焦点/Tab、VoiceOver、Reduce Motion、真实麦克风、真实服务端到端与窄窗观感均未验证，不能由单测或类型检查推断通过。

2026-09-24 21:20：第二轮 review 修复完成。手动同段定位保留阅读偏移，跨段定位回到段首；键盘请求的控制显隐会在焦点或指针离开后正常结束；准备中/关闭中的手动打开分别返回忙碌/关闭错误；关闭语音后舞台保持手动；移除整段点击劫持，改为非当前段定位按钮；工作台语音操作按真实生命周期显示关闭/恢复/重试停止/重试语音；删除呼吸光效、脱稿归队、节奏看板和自动复盘等旧 UI 死代码；舞台菜单命令仅在舞台可见时出现且不再占用全局方向键。`swift test --disable-sandbox --package-path macos/SpeechRailApp --filter Teleprompter` 共 135 项 / 15 个 suite 全部通过；新测试文件与生产依赖已接入 `SpeechRailAppTests` Unit Test Sources，`plutil -lint project.pbxproj` 通过。21:26 `scripts/macos_app_build.sh --configuration Debug` BUILD SUCCEEDED；21:29 Xcode Unit Test-only TEST SUCCEEDED（135 项 / 15 suite）。UI 淡出几何、焦点/Tab、VoiceOver、Reduce Motion、真实麦克风与真实服务端到端仍未执行。

2026-09-24 23:55 起：提词器舞台布局改为真实排版行，显示 1／2／3 条并以段落索引 + UTF-16 偏移导航；快捷键与菜单按行移动；透明度范围扩至 100%；工作台行数设置同步改名；标准窗口缩放横向铺满可用屏幕，并限制最大窗框高度。`TeleprompterStageSettingsTests` 23 项、`TeleprompterSessionLifecycleTests` 13 项和 `Teleprompter` 全部 142 项 / 15 suites 均通过；`scripts/macos_app_build.sh --configuration Debug` BUILD SUCCEEDED。上述是 Swift Testing 与 App 编译证据；由于项目要求逐次授权前台 UI 自动化，本轮未做桌面视觉、键盘焦点、VoiceOver、Reduce Motion 或真实麦克风验收，不能推断这些项目通过。
