---
title: "SpeechRail macOS App AI 提词器"
status: active
version: "0.5.13"
date: 2026-09-29
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

1. 从侧边栏打开「AI 提词器」，新建、粘贴或导入稿件；草稿无需先生成版本即可保存。「复制稿件内容」在任何时候都必须拿得到内容——存盘失败时稿件只在内存里，此时读者最需要的恰恰是把稿子拿走，因此它像两条导出路径一样回落到原稿正文，不得像 `exportMarkdown()` 那样直接放弃。存盘失败时工作台会给出「重试保存」；**该按钮成功后必须清掉失败态**，否则这个恢复入口永远恢复不了，读者只能去按旁边的 ✕ 手动关掉。「直接使用原稿」是 AI 不可用时的主恢复路径，存盘失败时必须整体回滚——**恢复按钮正是 `blocked` 非空时才渲染的**，把它清空等于把读者唯一的出路也一起收走；按钮本身也不得用 `try?` 吞掉错误，读者需要知道这次为什么没成。
2. 点击「打开提词器」直接进入可手动阅读的舞台；此动作不会申请麦克风或连接 ASR，AI 朗读标注也不会阻塞开始。舞台或语音会话开着时切换稿件会被拒绝——这是为了不让旧事件推进新稿；**拒绝必须出声**：返回 `TeleprompterTextError.sessionBusy` 并提示先关掉提词窗口，不得静默返回或 `try?` 吞掉，否则读者只会以为应用卡了。
3. 如使用 AI，先看懂“已经完成什么、原稿有没有被改、下一步要做什么”，再审阅朗读稿；默认路径使用普通用户语言，高级的拆分、合并和来源编辑收进“编辑本段”等渐进式披露入口。确认采用前可查看原文对照、修改、保留原文或跳过；编辑段落时清空对应旧辅助标注。采用候选版本是这条路径上唯一**不可重做**的编辑——候选一旦离开内存，审阅结果就不在屏幕上了。因此存盘失败时必须整体回滚：审阅页与候选版本留在原处、「采用」按钮仍可按，读者腾出磁盘空间后能再试一次，而不是只丢一次工作。**同一份不可重做性也约束「选择范围」**：改范围会作废按旧范围算出的分段，读者已逐条处理过的审阅随之消失。因此 `updateContentSelection` 在 `hasReviewDecisionsAtRisk`（候选版本仍在、且已有被处理过的审阅项）时抛 `reviewDecisionsWouldBeDiscarded` 且不动任何状态，由界面先确认再走 `applyContentSelectionAfterConfirmation`；刚整理完尚未处理、或候选已被采用时**不拦**——那时丢掉的是 AI 的建议或已落进确认版本的判断，不是工作。
4. 在显示设置中先选场景：「镜头口播」是舒适窄栏加三行，「讲台阅读」更大字号、更宽行与两行，「自定义」保留用户自己的列宽、字号与行数。预设只改列宽、字号与行数，窗口宽度、透明度和行距不动；手动调过其中任何一项就自动变为「自定义」，预设不会与手动设置互相覆盖。正文列宽与窗口宽度分开：窗口再宽，正文也保持 680pt／820pt 的可读行长，不铺满超宽屏；窗口变窄时列宽跟随收窄。三行模式上方显示已读行、中间显示当前行、下方预览下一行；正文按列宽自然折行并映射回稿件；三行在稿首／稿尾留空槽，避免当前行跳位。舞台按行数与字号调整高度，最多 360pt；绿色缩放横向铺满屏幕可用宽度。控制区首次展示 2 秒，指针进入操作区后显示，离开后 250ms 隐藏；正文布局和键盘可达性不随控制显隐变化。开启 Reduce Motion 时舞台不做位移动画，阅读位置仍照常更新。
5. 使用空格/→/↓/PageDown 下一行，←/↑/PageUp 上一行，Home/End 首末行；`⌘⌥←/→` 是应用菜单中的上一行／下一行快捷键。控制按钮和所有快捷键统一移动到对应行的原稿位置；「查阅全稿」仍提供完整段落滚动与文本选择。查阅全稿或手动滚动之后，控制栏出现「回到朗读位置」，把舞台收回当前朗读行；它不恢复语音推进权，语音仍需显式开启。短暂脱稿时保持位置，需要语音协助时再点击「开启语音跟随」。
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
| `TeleprompterStageSettings.swift` | 舞台显示设置：场景预设、正文列宽（与窗口宽度分离）、字号、透明度、行数与 Reduce Motion 动效策略 |
| `TeleprompterRealtimeClientProtocol.swift` | Session 测试 seam：让生产 Realtime 生命周期可直接注入 fake client |
| `TeleprompterSession.swift` | MainActor 会话编排、服务/麦克风门禁、Realtime 生命周期和失败降级 |
| `TeleprompterView.swift` | 准备页、稿件编辑、AI 审阅和舞台设置 |
| `TeleprompterStageWindow.swift` / `TeleprompterStageView.swift` | 独立浮动舞台窗口、键盘控制和可访问状态反馈 |
| `TeleprompterReplayEvaluator.swift` / `TeleprompterReplayTool` | 确定性回放评估器与 CLI：用生产跟随路径重放带版本记录的语料，只输出脱敏聚合 |

`SessionCoordinator` 只负责设备占用。提词器调用 `sessionDidStartRecording(id: nil)`，因此可参与共享麦克风占用而不写入会话记录库；停止时由 coordinator 释放占用，提词器自己的 `TeleprompterRunState` 只保存稿件进度。

## 回放素材怎么写

`teleprompter-replay` 的素材 manifest 写在仓库外，由人标注。两个约定不写对不会报错，只会让报告全零，因此值得单独说明：

- `labels[].expected_segment_index` 标的是**读者当时已经读到的段落**，不是系统确认到的段落。跟随延迟是「读者进入某段」到「系统追上这一段」之间的差值；把标签挂到系统已经追上的那个事件上，延迟会恒为 0，看上去「没有延迟」，实际是**没有样本**。
- 第 0 段是回放起点，系统一开始就在 0，因此第 0 段不产生延迟样本。验证跟随延迟至少要有一个非 0 段。

`labels[].intent` 只接受 `read`／`improvise`／`reRead`／`manualJump`（区分大小写）。取值列表由 `TeleprompterReplayManifest.Intent.manifestValues` 单独声明，CLI 的帮助文本和报错信息都从它读，改动时三者不会漂移。

素材写错时 CLI 以退出码 2 拒绝，并指出具体字段与合法取值；不会产出可被误当作质量成绩的部分结果。跑之前先确认 `status` 不是 `not_run`。

报告里每个安全数字都由标注推导：严重误推进只在 `improvise` 标注下计数，跟随与恢复延迟只在 `read` 标注带 `expected_segment_index` 时才有样本。素材里一条 `improvise` 都没有，误推进数就恒为 0——报告会明确写出「该检测项未被触发，不表示跟随不会越权推进」；同理，没有带位置的 `read` 标注时会写明分位为 null 只是未测量。**要让一次回放真正充当验收，素材必须包含即兴段与带位置的跟读段**，否则得到的只是一份没问过问题的答卷。

反方向同样要挡住：**标注齐全、跟随却一次没动**。报告里的 `advanced_event_count` 统计实际把阅读位置往前推的事件数；当它为 0 而样本数大于 0 时，报告会写明「0 次严重误推进只说明跟随没有动过，不表示跟随可用」。没有这一条，一条冻住的跟随路径可以带着「零误跳、零停顿、零告警」的结果去验收——每个数字都是真的，合起来描述的却是「什么都没发生」。素材为空（0 个事件）时报「0/0」没有意义，因此该提示只在有样本时出现。

同理，**方案 §11.7 的「回稿恢复 P95」门槛在没量到样本时必须自己说明**：全程直读、一次没脱稿的素材会得到 `reanchor_latency_p50/p95 = null` 与 `reanchor_timeout_count = 0`，报告会写明该门槛本次未被测量。判据是**分位本身有没有样本**，不是素材里有没有 `reRead` 标注——恢复样本来自 `reanchorStartedAt`，而 `improvise` 事件在没有推进时也会设它，所以「没有 `reRead` 标注」的素材同样可能量出恢复延迟。

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

AI 调用成功之后、本地存盘失败的那一段，责任必须说给磁盘，不能说给 AI：读者若被告知「AI 没能整理、可以重试」，会白等一次同样会失败的调用。此时内存里的改动也必须回滚——留着就会在下一次无关保存（改目标时长、采用候选版本、关闭舞台写进度）时悄悄生效，变成**报告了失败却真的落地**，比一条干脆报错的提示更难查。同理，存盘失败不得让界面显示已生效的朗读提示。

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

### 读法别名（#110）

有些词识别器会稳定听错——产品名、内部术语、人名地名。`TeleprompterAcceptedReading` 允许读者登记「屏幕上写 A，我实际念 B」，**绑定到某个段落内的一处 UTF-16 范围**，并连同当时的显示文本一起保存。对齐时用读法的值去匹配，位置仍落在显示文本上：稿件、导出与逐字记录一个字都不改。方案 §5.6 明确不得全局替换，因此别名只作用于确认的那一段。

入口在稿件就绪页表头的「读法标注」，是渐进式披露的进阶操作，不占「选起讲段」这条默认路径。读者填「屏幕上的词」与「我会念成」两个字段，由会话层解析出现位置，界面不自行计算偏移。

几条规则是实测换来的：

- **替换而非追加**。同时保留两种读法会抬高匹配窗口的分母，把本来精确的匹配打到 0.75，两种读法一起变差。
- **数值必须无损**。`50%` → `百分之五十` 放行；`大约一半`、`百分之六十` 一律拒绝，否则别名就成了绕过保真闸门的通道。
- **一处一议**。同一个词在一段里出现多次时拒绝并要求用更长的词组限定，不猜是哪一处；跨段同词则始终在被选中的那一段内解析。
- **正文一改即失效**。别名记录了当时的显示文本，正文被改后校验失败，匹配时整条丢弃，不会指向别的词。
- 念显示文本时置信度从 1.0 降到 0.875，仍高于 0.72 的前进门槛——这是「替换而非追加」的已知代价。

`TeleprompterAcceptedReadingRejection` 是唯一的失败出口，共 13 种原因，界面按普通用户语言逐条映射，不暴露内部术语。**新增与移除走同一套原因**——移除原本只返回一个 `Bool`，把「舞台开着不能改」「这条读法已经不在」「存盘失败」三种情况一并说成「没有保存成功，请重试」，而舞台开着时重试多少次都不会成功。存盘与读盘都会校验别名，因此旧稿没有该键也照常打开（M-01）。

失败归因必须说对人：「现在还不能改」（舞台开着或上一步没收尾）、「找不到这一段内容」（稿件已切换）、「没有保存成功，稿件内容未改动」（磁盘空间或文件夹权限）与「这段正文已经变了」是四件不同的事，不能共用一句「重新打开窗口再试」——尤其磁盘写失败与正文无关，让用户重开窗口只会白等一场。存盘失败时内存中的读法会一并回滚，界面上不会留下一条下次打开就不存在的标注。

## 跟读验收边界

确定性 fake-event 测试只证明 canonicalization、位置决策、snapshot 替换、final 确认和乱序恢复逻辑；不证明麦克风采集、Realtime ASR 识别准确率、视觉呈现或长时间运行质量。实音频验收应覆盖目标语言、数字/日期/货币、邮箱、产品名与领域词，并分别统计空转写、截断、延迟和位置恢复；snapshot 修订必须按全文替换来评估。当前跟读是文本相似度驱动的短语/字符范围定位，不提供词级时间戳；精确词级跟随需要未来 ASR 时间戳或声学强制对齐能力。

读法别名的匹配效果同样只由确定性测试证明，**没有实音频验证**：读者登记的读法能否真的抵消真实识别器的误听，未测。

## 设计 token 约束

所有提词器新增尺寸、字号、行距、背景透明度范围、内容间距、视线吸顶偏移和窗口 autosave 名称位于 `SpeechRailDesignTokens.Teleprompter`。正常阅读舞台以 `TeleprompterStageLineLayout` 得到的实际显示行为单位，显示条数为 1／2／3，默认 3 行；每行映射回原稿段落索引和 UTF-16 范围。全稿模式仍展示完整语义段落，不展示内部跟读对齐切片。

- **场景预设与正文列宽**：正文列宽是独立设置（`stageDefaultContentWidth` 680pt，范围 360–1200pt），与窗口宽度分开保存。`TeleprompterStagePreset.camera` 应用 680pt／1.0 倍字号／3 行，`.podium` 应用 820pt／1.25 倍字号／2 行，`.custom` 不改任何值。窗口宽度、背景透明度与行距不属于预设。`TeleprompterStageLayoutPolicy.contentLayoutWidth` 决定实际排版宽度：窗口更窄时跟随窗口（不小于 1pt），窗口更宽时保持请求列宽，因此超宽屏不会把一行拉长。字号或列宽变化后按稿件坐标重算显示行，阅读位置不依赖旧行号。
- **快捷恢复**：只有「查阅全稿」且当前没有语音跟随时，控制栏才出现「回到朗读位置」；点击后退出全稿浏览并滚回当前朗读行，不恢复语音推进权。可见性由 `TeleprompterStageRecoveryPresentation` 单点判定。
- **Reduce Motion**：`TeleprompterStageMotionPolicy.scrollAnimation(reduceMotion:)` 在 Reduce Motion 开启时返回 `nil`，舞台不做位移动画但位置照常更新。

- **手动优先的阅读层**：正文、错误提示和最小辅助条是阅读层；操作栏是独立控制层。手动打开、翻段、滚轮接管和语音启停都不改变正文几何。
- **控制显隐**：首次打开展示 2s，指针离开后延迟 250ms 隐藏；错误提示独立保留 4s。指针位于舞台、控制焦点存在、popover/menu 打开、VoiceOver 开启、键盘主动请求或用户选择「始终显示控制」时保持可见。所有时长集中在 `TeleprompterStageInteractionPolicy`，不允许页面散落第二套数值。
- **紧凑预留，不重排**：顶部辅助条只在计时/进度或实际采集状态需要时显示，固定 `stageAuxiliaryBarHeight`（24pt）；底部控制区固定 `stageControlAreaHeight`（48pt）。隐藏只撤下操作内容与无障碍子树，保留紧凑槽位避免台词跳动；隐藏控件不响应点击。
- **最小辅助状态**：只有实际采集时显示「麦克风使用中」角标；计时与进度默认关闭，用户开启 `showClockAndProgress` 后才显示。两者都不以常驻节奏评价、段末训导或状态看板抢占台词。
- **末段即正文**：舞台没有自动完稿、复盘或末段关闭分支。用户关闭、按 Esc、窗口系统关闭和程序关闭统一调用 `closeStage()`，释放本功能的麦克风、client 与 coordinator 占用，同时保留阅读位置。
- **键盘与菜单**：舞台阅读区域在用户显式打开窗口后获得键盘焦点；空格/→/↓/PageDown 下一显示行，←/↑/PageUp 上一显示行，Home/End 首末行，Esc 关闭。设置控件或弹层获得焦点时不执行阅读命令；关闭设置后焦点返回阅读区。Tab 请求显示控制区，应用菜单仍提供全部核心动作；菜单上一行/下一行分别使用 `⌘⌥←` / `⌘⌥→`，不占用全局裸方向键；关闭使用 Command-Esc。字号与背景透明度的 Command-=/-/0 和 Command-[/] 是舞台内辅助快捷键；不再用 Command-A 切换全稿，也不让空格隐式开启语音。
- **语音与设置**：语音按钮状态来自 `TeleprompterVoiceAssistLifecycle`；`off`、`starting`、`following`、`stopping`、`stopFailed`、`pausedByUser`、`unavailable` 都必须有明确文案。`alwaysShowControls` 与 `showClockAndProgress` 使用独立 UserDefaults 键，默认关闭，旧版本可忽略；`contentWidth` 与 `preset` 也是独立键，缺省时按「镜头口播」读取，旧设置不需要迁移。
- **失败归因要说对人**：输入设备启动失败或格式不兼容归入 `BlockReason.inputDeviceUnavailable`，文案说明是麦克风并保留底层错误信息，同时继续提供手动看稿；只有 ASR 服务本身的问题才用 `serviceNotReady`。任何失败都不得推进稿件、不得留在已连接状态，并必须释放本功能的占用、连接与采集。
- **时长估计要说明它是推的还是量的**：倍率 `1.0` 既是「没人试读过」的默认值，也可能恰好是某次试读的真实结果，只看倍率无法区分。`TeleprompterCalibrationSource` 因此显式记录来源（`.uncalibrated` / `.manualTrial(durationSeconds:)`），`TeleprompterTimingPolicy.estimateDuration` 与 `evaluatePreflight` 据此给出 `EstimateResult.isCalibrated`；试读采用时写入 `.manualTrial`，「恢复默认语速」写回 `.uncalibrated`——那是一次选择，不是一次测量。未校准时两处时长展示都要标注：内容选择页的预计用时，以及工作台预检结论——后者经 `PreflightConclusion.showsDurationEstimate` 区分，带分钟数的结论才标，「无内容」「目标无效」「无法预估」本身没有时长数字，不加标注以免变成噪声。校准入口常驻并显示「未试读校准」，不使用 `.healthy` 语气冒充已测。倍率不落盘，因此没有存储迁移。
- **语音辅助试读（#112）**：试读 sheet 有「手动计时 / 语音辅助」两种方式，是两次独立动作。语音辅助走既有 coordinator 与 client 构造路径（同一套权限、设备租约、显式语言与术语），因此本机麦克风仍只有一个 owner；打开窗口本身不碰麦克风，必须按下试读按钮才开始。它不进 `.following`、不移动阅读位置、不起运行计时、不写进度、不建 `SessionStore` 行，结束时经 coordinator 归还租约。证据只记计数不记正文：`TeleprompterSpeechTrialEvidence` 分开记 `recognizedUnits` 与 `matchedUnits`，界面把「麦克风 / 识别 / 定位」三段链路分别报出来——#112 明确不能只以输入电平证明识别和定位成功。`TeleprompterCalibrationSource` 因此新增 `.speechTrial(durationSeconds:recognizedUnits:)`，与 `.manualTrial` 区分：后者只证明读者按了开始和结束，前者还证明采集、识别与定位当时是通的。没识别到内容的试读**不产生倍率**（`TeleprompterSpeechTrialEvidence.calibrationFactor` 返回 nil），一个没听到东西的试读若也产出倍率，等于用一次失败的采集冒充一次测量。
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

2026-09-28：按 [`AI 提词器优化方案`](../../implementation/SpeechRail_AI_Teleprompter_Implementation_Plan_2026-09-28.md) 完成 #113 场景预设、正文列宽与「回到朗读位置」，并把 69 项场景台账中 13 项「未覆盖／部分」全部用具名回归收敛（详见 [`阶段实施报告`](../../implementation/SpeechRail_AI_Teleprompter_Stage_Report_2026-09-28.md)）。同轮修复五个既有缺陷：保真门禁两侧提取口径不一致、改稿后旧候选块与审阅条目残留、输入设备失败被归因为 ASR 服务、回放报告把运行绝对时刻当成跟随延迟、错误停顿在进入阅读瞬间即被计数；另由 Xcode 构建查出新测试文件被挂进 App 源码组（`plutil -lint` 与 SwiftPM 都发现不了），以及测试闸门 `TestGate` 不记开启状态、导致 Xcode 单元测试在全量并行时挂死（首轮曾误判为 App 测试宿主不退出，实际单测 target 无 `TEST_HOST`、App 从未启动，见阶段报告 §2 第 9 条）。`swift test --package-path macos/SpeechRailApp` 201 项 / 16 套件通过；`pytest tests/test_resource_governor.py tests/test_teleprompter_latency_probe.py` 36 项通过；`swift build --product teleprompter-replay` 成功；`scripts/macos_app_build.sh --configuration Debug` BUILD SUCCEEDED（本轮文件 0 warning）；`scripts/macos_app_build.sh --configuration Debug --test-unit` TEST SUCCEEDED（XCTest 344 项、Swift Testing 201 项 / 16 套件，0 failures，exit 0）；`git diff --check` 通过。台账为通过 66、部分 2（R-04 真实拔插、R-07 长时运行）、未覆盖 0、未执行 1（U-10 真实窗口）。仍未执行且不得据此宣称通过：UI 视觉走查与 UI 自动化、真实音频时延基线、真人表达验收、§11.7 的全部质量门槛。

2026-09-28（第二轮）：按 Issue 正文逐条复核实现（此前只核对了标题与状态），发现 #111 步骤 5「未经有效试读使用默认估计并标明不确定性」与验收「试读校准复用既有类型与入口；手动计时、语音辅助试读的证据来源清晰」未实现，已补齐：新增 `TeleprompterCalibrationSource` 与 `EstimateResult.isCalibrated`，试读采用写入 `.manualTrial(durationSeconds:)`、「恢复默认语速」写回 `.uncalibrated`，未试读时预计用时标注「（未试读校准）」且校准入口常驻。`swift test --package-path macos/SpeechRailApp` 204 项 / 16 套件通过；`scripts/macos_app_build.sh --configuration Debug --test-unit` TEST SUCCEEDED（XCTest 344 项、Swift Testing 204 项 / 16 套件，0 failures，exit 0）。语音辅助试读目前不存在，未为对齐措辞虚构路径。

2026-09-29（第三轮）：端到端跑 `teleprompter-replay` 时发现素材 intent 契约与工具帮助文本不一致——`--help` 写 `re_read`／`manual_jump`，解码器只接受 `reRead`／`manualJump`，且失败信息是 Foundation 的通用句子，不指字段也不给合法取值。此前所有测试都用 Swift 构造枚举，没有字符串往返，所以没暴露。已让 `Intent` 显式钉住 raw value，并由 `manifestValues` 统一供给帮助文本与报错；解码失败改为指出字段与可接受取值；补两条回归钉住拼写。另新增「回放素材怎么写」一节：`expected_segment_index` 标的是读者已读到的段落而非系统确认到的段落，挂到系统已追上的事件会让延迟恒为 0 且不报错，第 0 段不产生延迟样本。CLI 与单测同形核对复现了单测断言的 400／1100 ms，确认 runner 驱动的是生产跟随路径。`swift test --package-path macos/SpeechRailApp` 206 项 / 16 套件通过；Xcode 单测 target TEST SUCCEEDED（XCTest 344 项、Swift Testing 206 项 / 16 套件，0 failures，exit 0）。

2026-09-29（第四轮）：对抗性探测保真门禁时发现一处 fail-open——`TeleprompterProtectedContentValidator` 比较受保护原子的序列，提取器看不见的数字在两侧都不产生原子，精确序列比较因此得出「没有变化」。实测确认静默放行的包括 `1080p` → `4K`、`4K` → `8K`、`1e10` → `2e10`、`0x1F` → `0x2F`，以及 `29.97fps` 只抽出 `29`。根因是数字模式末尾的 `(?![A-Za-z0-9])` 拒绝任何紧跟 ASCII 字母的数字。已补进制前缀、指数与紧邻 ASCII 单位后缀；首部 lookbehind 保留，`A1`／`GPT4`／`ISO8601` 仍不产生数值原子。中文数字互改（`五十` → `五十一`）仍不受门禁保护，作为具名回归 `chineseNumeralsRemainOutsideTheHardGateByDesign` 钉成已知边界——直接加正则会大面积误拦 `第一次` → `首次` 这类无损改写。`swift test --package-path macos/SpeechRailApp` 213 项 / 16 套件通过；Xcode 单测 target TEST SUCCEEDED（XCTest 344 项、Swift Testing 213 项 / 16 套件，0 failures，exit 0）。

2026-09-29（第五轮）：对抗性审查回放报告时发现，报告无法区分「测得为零」与「检测项从未被触发」——`harmfulJumpCount` 只在 `improvise` 标注下递增，延迟分位只在 `read` 标注带 `expected_segment_index` 时才有样本。一份不含 `improvise` 标注的素材会输出 `harmful_jump_count: 0` 与 `status: deterministic_replay`，读起来像一次干净验收，实际误推进检测从未触发；这正是「不以全部停住换取安全」在测量仪器层面的缺口。已在 caveat 层补上说明，不改 `teleprompter.eval.v1` schema。过程中先被这个现象误导过一次——把「读者在朗读」的素材标成 `improvise` 导致报告如实报出 1 次误推进，追踪控制器后确认行为正确（从锚点开始逐字连续的 final 按方案 §8.9 属于 continuous advance）。`swift test --package-path macos/SpeechRailApp` 212 项 / 16 套件通过；Xcode 单测 target TEST SUCCEEDED（XCTest 344 项、Swift Testing 212 项 / 16 套件，0 failures，exit 0）。

2026-09-29（第六轮）：审查验收标准 3 的「迁移失败保留原数据」时发现，#110 验收里点名的「写入失败不丢数据」此前没有任何回归覆盖——已有回归`sourceRevisionIsImmutableAndInvalidSaveLeavesPreviousBytesUntouched` 只覆盖写入**之前**的校验失败，不可变源版本不匹配时根本走不到写文件。真正的提交路径既无接缝也无覆盖：`atomicWrite` 是 fileprivate，`FileManager.replaceItemAt` 在 Swift 里也不可覆写。结论是测试缺口而非缺陷——`atomicWrite` 先写临时文件再 `replaceItemAt`，catch 只删临时文件、不碰目标文件。已用只读目录构造同一类失败补上回归（磁盘满／权限拒绝正是该验收项指的场景），断言抛出 `atomicWriteFailed`、原始字节逐字节不变、原稿仍可读、不残留 `.tmp`；root 绕过目录权限，测试显式跳过而不是假装通过。`swift test --package-path macos/SpeechRailApp` 213 项 / 16 套件通过；Xcode 单测 target TEST SUCCEEDED（XCTest 344 项、Swift Testing 213 项 / 16 套件，0 failures，exit 0）。

2026-09-29（第七轮）：#110 的读法别名此前只有领域层与对齐器，**没有任何界面入口**——`confirmReading` 无调用方，功能等于不存在。按项目「首屏只留当前任务必需动作、进阶操作渐进式披露」的约束，入口放在稿件就绪页表头的「读法标注」次级按钮，弹窗内用「屏幕上的词／我会念成」两个字段，由会话层 `resolveDisplayTerm` 解析段内出现位置，界面不自行计算 UTF-16 偏移；就绪列表每段本身已是一个 Button，内联控件会形成嵌套按钮并破坏键盘与 VoiceOver 可达性，因此不放在段内。同一词在一段中出现多次时拒绝并提示改用更长词组，不猜；跨段同词始终在被选中段内解析。`TeleprompterSourceRange` 增加 `Hashable` 供 `ForEach` 使用。新文件 `TeleprompterReadingAliasSheet.swift` 已显式注册进 `project.pbxproj`（本工程无文件系统同步组，漏注册会静默不参与 App target 编译）；`scripts/macos_app_build.sh --configuration Debug` BUILD SUCCEEDED 证明注册生效——SwiftPM 不编译 `TeleprompterView.swift` 与各 sheet，视图层只有 Xcode 一条门禁。设计 token 新增 `readingAliasSheet*` 与 `readingAliasListMaximumHeight` 并按规则同步设计系统文档。证据用变异探针核过：22 次变异带基线自检与已知应杀变异，首轮 5 条存活补 4 条回归（别名 span 自身位置从未被断言、跨数值边界整条作废、失效别名不入 token 流、存盘拒绝重叠别名），另 5 次针对按词解析，4 杀 1 存活——存活那条是 `trimmed` 空值守卫，实测 `NSString.range(of: "")` 返回 `NSNotFound`，且零宽范围会被 `isValid` 再拒一层，属冗余守卫而非测试盲区，按纵深防御保留。`swift test --package-path macos/SpeechRailApp` 248 项 / 16 套件通过；Xcode 单测 target TEST SUCCEEDED（0 failures，exit 0）。**未做 U-10 界面走查、VoiceOver 朗读与真实音频验证**——别名能否真的抵消真实识别器的误听仍未测。

2026-09-29（第八轮）：补上 #111／#112 唯一剩余的「语音辅助试读」——此前试读 sheet 只有手动秒表，文档里直接写着「语音辅助试读目前不存在」。新增 `startSpeechTrial()`／`stopSpeechTrial()`，走既有 coordinator 与 client 构造，因此权限、设备租约、显式语言与术语都只有一套；试读不进 `.following`、不动阅读位置、不起运行计时、不写进度、不建 `SessionStore` 行。写第一版时 `stopSpeechTrial()` 直接调 `stopCapture()`，回归当场抓到：`stopCapture` 只关掉会话自己的 client 与 source，**coordinator 仍持着设备租约**，麦克风会再也开不了下一次；改为经 `coordinator.stopCapture()` 归还。这条是测试先于提交发现的。证据只记计数不记正文（`recognizedUnits` / `matchedUnits` 分开），界面按「麦克风 / 识别 / 定位」三段分别报，不把输入电平说成识别成功。没听到内容的试读不产生倍率。变异探针 8 次变异 7 杀：首轮 4 条存活里 3 条是我自己的测试盲区（试读不推进阅读位置、采用闸门、试读沿用同一套识别配置），补断言后杀掉；其中「沿用同一套配置」那条首版变异改错了位置——改的是 `RealtimeASRClient` 兜底构造，而测试注入的 factory 根本不经过它，这种探针改与被测代码不相干，比没写更糟。剩余 1 条存活（把试读事件也喂给 `followAdapter`）已定位为结构性失效：`TeleprompterFollowController` 的每条接收路径都有 `guard mode == .following`，试读从不进入该模式，控制器会 retire 掉每个 item，按纵深防御记录。`swift test --package-path macos/SpeechRailApp` 253 项 / 16 套件通过；Xcode 单测 target TEST SUCCEEDED（XCTest 346 项，0 failures，exit 0）。**未做真实麦克风验证**——语音试读整条链路目前只有 fake transport 证据，真人语速下的识别与定位效果未测。
2026-09-29（第十七轮）：回放报告新增 `advanced_event_count`，并在跟随一次都没推进时写出告警——验收第 4 条要求「不以全部停住换取安全」，而此前标注齐全的素材上，一条冻住的跟随路径会输出「零误跳、零停顿、零告警」，每个数字都是真的，合起来描述的是「什么都没发生」。详见阶段报告 §2 第 52 条。
2026-09-29（第十七轮续）：回放报告新增恢复门槛告警——方案 §11.7 的回稿恢复 P95 在没量到样本时必须自己说明未被测量，否则 `null` 与 `0ms` 在报告里无法区分。判据是分位有无样本，不是素材有无 `reRead` 标注。详见阶段报告 §2 第 53 条。
2026-09-29（第十九轮）：改内容范围不再静默丢弃已完成的审阅——审阅是采用之后链路上最后一份不可重做的工作，而「选择范围」入口不看阶段、审阅页点得到。会话层改为抛 `reviewDecisionsWouldBeDiscarded` 并保持状态不变，界面确认后才走 `applyContentSelectionAfterConfirmation`；刚整理完未处理、或候选已被采用时不拦。详见阶段报告 §2 第 54 条。
