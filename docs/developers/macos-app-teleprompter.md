---
title: "SpeechRail macOS App AI 提词器"
status: active
version: "0.3.4"
date: 2026-09-24
---

# SpeechRail macOS App AI 提词器

AI 提词器是 macOS App 内的直播准备与跟读能力。它面向主播本人：用户在独立舞台窗口中看到稿件和跟读状态，直播软件只应采集摄像头或目标内容窗口，不采集提词器舞台或整屏。

## 产品边界

- 输入为用户粘贴的纯文本，或导入 `TXT` / `Markdown` 文件。
- AI 仅由用户主动触发；短稿一次窗口请求，长稿按最多 24 个本地单元逐窗口处理。正常整理每窗分成两个有界请求：`teleprompter.grouping.v1` 只分配连续来源区间，`teleprompter.rewrite.v1` 只按程序分配的 `block_id` 生成朗读候选。原文、UTF-16 范围和来源组由本地程序持有；可恢复的单窗失败会逐字保留原文并标记待确认，不把回退计作 AI 成功。
- 原稿无需 AI 即可开始；草稿自动保存，AI 标注是可选步骤，建议经用户确认后才成为活动版本。跟读期间固定版本，不允许切稿或编辑。
- 运行时复用现有 `MicrophoneCapture`、`RealtimeASRClient` 和 `SessionCoordinator`，但不创建 `SessionStore` 会话行，也不保存 PCM、摄像头画面、直播画面或完整 ASR 文本。
- 不包含 TTS、摄像头采集、直播推流、全局提词热键或云端稿件同步。

## 用户旅程

1. 从侧边栏打开「AI 提词器」，新建、粘贴或导入稿件；草稿无需先生成版本即可保存。
2. 点击「打开舞台并开始跟读」即可直接进入舞台；AI 朗读标注是可选准备步骤，不会阻塞开始。
3. 如使用 AI，先看懂“已经完成什么、原稿有没有被改、下一步要做什么”，再审阅朗读稿；默认路径使用普通用户语言，高级的拆分、合并和来源编辑收进“编辑本段”等渐进式披露入口。确认采用前可查看原文对照、修改、保留原文或跳过；编辑段落时清空对应旧辅助标注。
4. 调整字号、背景透明度和显示段数；也可以先点击「只打开提词窗口」检查版式。舞台以完整语义段落自然换行，只显示当前段与有限的下一段；跟读对齐仍在内部保留字词坐标，不把对齐切片直接铺到用户视野。
5. 短暂脱稿时保持位置，读回附近稿件后继续；可以点击某段、使用方向键选择起讲段，再点击「开始/继续跟读」。
6. 暂停/手动期间停止上传新音频；继续前完成旧 ASR item 的 drain/clear 屏障。服务断开后释放设备占用，保留手动阅读，并可重新开始。
7. 直播软件必须选择摄像头或目标内容窗口，不分享包含提词器的屏幕。不能依赖 `NSWindow.sharingType = .none` 隐藏窗口；当前 Apple 文档已将该值标注为系统不再使用的旧常量。

## 模块边界

| 模块 | 责任 |
|---|---|
| `TeleprompterDomain.swift` | 稿件、版本、段落、暂停提示、运行状态与对齐结果类型 |
| `TeleprompterNormalizer.swift` / `TeleprompterSegmenter.swift` | 中英文归一化、填充词过滤、确定性分段和 UTF-16 原文区间 |
| `TeleprompterPreparationPrompts.swift` / `TeleprompterPreparationPipeline.swift` | 整理的 grouping/rewrite/reduce prompt、严格 JSON decoder、预算、取消、局部恢复与原子装配 |
| `TeleprompterAnalysis.swift` | 已确认朗读稿的可选 AI 朗读标注，不与整理 workflow 混用 |
| `TeleprompterStore.swift` | Application Support 下单稿件 JSON、原子保存、运行进度和 Markdown 导出 |
| `TeleprompterFollowController.swift` | partial/completed 事件与跟读、暂停、手动接管状态机 |
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

舞台在完整语义段落间滚动，当前段内的已读文字随 UTF-16 位置变化；字词对齐切片只服务跟读控制器，不作为独立视觉行。近距离重读可以回退；较远跳读需手动选段，当前没有全文语义重定位。暂停/手动操作退休已知 item，恢复时由会话层 drain/clear 排除尚未收到的旧事件；连接 generation 排除已关闭连接的迟到结果。暂停后 final 不得把 UI 改成手动态。

运行中不调用 LLM，不保存音频或转写。稿件和最后段落位置持久化；句内位置仅在本次运行内保留。AI、服务或识别失败均不阻止用户手动看稿。

## 跟读验收边界

确定性 fake-event 测试只证明 canonicalization、位置决策、snapshot 替换、final 确认和乱序恢复逻辑；不证明麦克风采集、Realtime ASR 识别准确率、视觉呈现或长时间运行质量。实音频验收应覆盖目标语言、数字/日期/货币、邮箱、产品名与领域词，并分别统计空转写、截断、延迟和位置恢复；snapshot 修订必须按全文替换来评估。当前跟读是文本相似度驱动的短语/字符范围定位，不提供词级时间戳；精确词级跟随需要未来 ASR 时间戳或声学强制对齐能力。

## 设计 token 约束

所有提词器新增尺寸、字号、行距、背景透明度范围、内容最大宽度、视线吸顶偏移、窗口 autosave 名称均位于 `SpeechRailDesignTokens.Teleprompter`。舞台视觉窗口使用语义段落，不直接展示内部对齐切片；改变字体不会改变匹配坐标。
- **标题输入几何**：工作台稿件名称复用统一可编辑输入槽；`workbenchDocumentTitleMinimumWidth` 保证至少 200pt 可读宽度，高度采用 `Control.prominentHeight`（40pt），作为工作台主要编辑入口给予更舒展的点击与聚焦空间；窄窗时将字数与状态降到第二行。
- **无级视效调节**：独立舞台的「视效」弹层提供字号与背景透明度连续滑杆，不设置 `step`；字号读数保留 0.1pt，背景透明度读数保留 0.01 控制百分比。快捷预设只作为便捷入口，不限制滑杆取值。
- 准备页「原稿」编辑区固定在 `sourceEditorMinimumHeight`–`sourceEditorMaximumHeight`（144–360pt）范围内，默认取 `sourceEditorIdealHeight`（260pt）；超过上限后由原生 `TextEditor` 内部滚动。
- 首次使用 AI 整理前，用面向普通用户的确认说明解释发送内容、触发时机、不会发送的音视频内容，以及本机/网络服务和保存策略的差异；不要把 `Responses-compatible endpoint`、`store=false` 等实现术语直接暴露给用户。
- **视线吸顶与视线锚点**：`stageTopInset = 48`，窗口首发吸顶在主屏上沿中央，紧贴摄像头下方，减少主播看词时的眼神偏移；
- **语义段落窗口**：舞台默认只呈现当前段与下一段（`stageMinimumVisibleSegmentCount...stageMaximumVisibleSegmentCount = 1...2`），不把已读段和远处段落留在主视觉中；
- **背景透光方向**：用户调高「背景透明度」时舞台更通透；控件值通过 `backgroundTransparency = 1 - opacity` 映射到既有存储值，持久化格式不变。读数是连续的控制百分比，不等同于颜色层和系统材质叠加后的实际视觉透光率；调节只作用于舞台底色和材质叠层，正文与控件自身 alpha 不变；
- **当前段强调与朗读提示**：当前段使用 `stageCurrentRailWidth` 竖直导轨与 `stageCurrentBackgroundOpacity` 极轻底色；未读部分正文使用 `ink` 高对比字色，AI 关键词（`keywords`）使用 `rail` 强调，中长停顿（`pauseHint`）以轻量胶囊徽标直观展现换气节奏；下一段提供余光预读并支持点击直接切换起讲段；
- **节奏与状态看板 HUD**：舞台顶栏集成动态拾音/跟读状态胶囊、支持时间 vs 文本双轨进度对照的细窄进度条（进度轨叠加目标时间刻度针）、实时量化节拍差指示胶囊（`stagePaceIndicatorPadding*`）与轻量运行计时器（显示已朗读时间与预估剩余时间/超时警示），供演说者精准把控时长；
- **全生命周期能力驱动的演说旅程（5 阶段深度服务）**：
  1. **登台前候场待命**：顶栏呈现「候场待命 · 空格开讲」，首段高亮标注「开篇起讲 · 第 1 段」锁定视觉起点；支持 ⌘A 全稿查阅与悬停选段起讲，支持 ⌘-/⌘= 缩放字号与 ⌘[/⌘] 快捷调节背景透明度，窗口尺寸实时记忆，消除登台设置焦虑；
  2. **冷启动起讲确认**：空格开讲进入跟读状态后，未捕获到首字前明确呈现「麦克风就绪 · 请起讲」，直观确认音频链路正常；捕捉到第一句瞬间咬合对齐并切换为翡翠绿「正在跟读」，段落侧边垂直导轨稳固锚定当前段，开启已读灰度淡出与未读高对比显示；
  3. **行进中节拍掌控与停顿指引**：
     - **双轨量化节拍差（Pace Delta）**：不仅提供「超前 / 滞后 / 吻合 / 测速中」定性状态，更基于当前段落完成比率与耗时进度，实时计算精确时差（如「超前 +24s」/「滞后 -18s」），并在进度条中以微型刻度针呈现时间 vs 文本完成度的双轨对照，让演讲者在 0.1 秒余光中精准掌控剩余时间的分配；
     - **段末节奏与停顿指引（End-of-segment Pause Guidance）**：摒弃与视线脱节的顶部虚夸标签，在当前段落正文末尾直接呈现客观实用的停顿建议（如「⏱ 段末留白 1 秒 · 稍作换气再接下段」/「⏱ 段末驻足 2 秒 · 让要点落地再开下段」），与演讲者读完句末标点时的自然视线无缝重合，真正辅助演说呼吸与气场把控；
  4. **脱稿即兴与精准归队（Off-script Retention & Seamless Re-entry）**：
     - 演说者临场插话、回答提问或自由发挥时，跟读平滑驻留在脱稿断点，不跳段、不乱滚；
     - 顶栏横幅与正文紧密协同：横幅直观提示「脱稿发挥中 · 读出下划线「xxx…」即可自动归队」，正文中对应断点处的前 8–10 字自动呈现高亮下划线（归队切入点），演讲者视线回到屏幕时瞬间锁定下一个发音单词，一读即接；
  5. **完稿复盘与能力反哺（Post-speech Review & Calibration Closed Loop）**：
     - 演说结束呈现结构化「演说复盘与节奏分析」专业看板，清晰呈现 4 项核心数据：实际用时（对比计划与百分比）、实测语速（WPM 与基准差异）、完成段数（总字数）、节拍评估；
     - 提供「复制复盘报告」一键将结构化演说报告写入剪贴板，便于演说者、教练或主播归档沉淀；
     - 当实测语速与设定基准存在偏差且样本充分时，提供「更新个人语速基准」一键采纳，直接将实测语速反哺至个人校准系数（`calibrationFactor`），闭环提升后续排稿预估与跟读准确度；
- **盲操与舞台快捷微调**：
  - **防眩光双层 HUD 材质**：采用 `canvas` 底色叠合系统 `ultraThinMaterial` 毛玻璃，无论悬浮在纯白 Keynote 幻灯片、深色 IDE 还是复杂视频窗口上方，文字与关键提示均具备清晰阅读对比度；
  - **段落悬停交互与即时定点**：全稿查阅与候场模式下，鼠标悬停即呈现柔和卡片高亮与「由此段起讲」提示，支持一键点击或双击立即将选中段落设定为开讲锚点；
  - **提词关键词粗体高亮**：关键词不仅以强调色标出，更以加粗字重（`stronglyEmphasized`）突出，方便演说者 0.2 秒余光快速捕捉核心要点；
  - **连续视效调节与快捷预设**：操控栏的「视效」弹层提供字号和背景透明度无级滑杆，透明度读数越高代表背景越通透；另保留 4 个透明度预设与 `⌘[` / `⌘]` 快捷微调，方便演说中快速校正。预设不限制滑杆精度；
  - **演说翻页笔与键盘全域盲操**：除点击外，深度支持主流蓝牙/无线演示翻页笔（`↑` / `↓`、`PageUp` / `PageDown` 上下段翻页，`Home` / `End` 首末段跳跃），提供 `⌘=` / `⌘-` / `⌘0` 字号缩放与复位、`⌘A` 全稿查阅切换，以及复盘小结页敲击空格键（`␣`）直接重新开讲；
  - **窗口尺寸实时双向记忆**：窗口边框拖拽缩放时通过 `windowDidResize` 实时回写并持久化 `settings.width`，重启提词器后无缝继承演说者偏好的舞台宽度；
- 页面复用现有 `Typography`、`Spacing`、`Color`、`Corner`、`speechRailSurface` 和系统按钮样式，不在视图中新增颜色、圆角或散落视觉常量。窗口以 macOS 26+ 的系统 `NSPanel`、`ultraThinMaterial` 和原生键盘快捷键为基线。

## 验收与限制

2026-09-21：使用合成文本、fake completion 和临时目录执行聚焦测试；新增 grouping/rewrite schema、重复键/未知字段/范围覆盖、strict 能力记忆与退回、`Retry-After` 等待、rewrite 阶段级重试、局部原文回退、部分窗口失败、Reduce 保留叶子和脱敏诊断覆盖。App Debug 编译用于检查会话和 SwiftUI 接线；不代表实际视觉或真实模型跟读质量验收。

```bash
swift test --package-path macos/SpeechRailApp --filter Teleprompter
scripts/macos_app_build.sh --configuration Debug
```

未执行真实麦克风、真实 LLM 效果、Realtime 端到端、OBS/会议软件可见性或 UI 自动化。仍需测量首轮/恢复后完成率、AI/原文回退占比、事实审阅、误跳、位置滞后、脱稿恢复耗时、手动纠正频率和滚动观感。没有新增 ASR 模型、强制对齐器、全局热键或提纲语义跟读。

回退时仅撤回本轮源码差异，保留稿件 JSON；不可整文件还原并行任务的修改，也不可将 AI v2 输出交给旧 v1 decoder。

2026-09-24：跟读闭环改为确定性 ITN 等价、尾词容错和短片段消歧；加入确认位置迟滞、自由发挥/重新锚定及共享 Realtime 事件 reducer。合成文本与 fake-event 验证不代表真实音频识别或视觉验收。
