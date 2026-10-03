---
title: "提词器用户旅程优化：Luna 执行方案"
status: proposed
version: "0.1.0"
date: 2026-10-03
---

# 提词器用户旅程优化：Luna 执行方案

- 原始材料：[按用户旅程优化的详细方案](SpeechRail_Teleprompter_User_Journey_Executable_Plan_2026-10-03.md)。原文件从 Downloads 原样移动至本目录，SHA-256 为 `9c42bf2bf62976d6e97444e8c77c57f1896e6cbd62f39151d869d38169430bc0`。
- 本地核验日期：2026-10-03，Asia/Shanghai；分支 `main`，HEAD `be75055cc0a5f7f044ae56c955896812a1d69915`，与原材料固定基线一致。未核验远端是否有后续提交。
- 本轮交付：文档移动、当前实现分析与执行方案落盘。未修改业务代码，未运行测试、构建、模型调用、UI 自动化或服务操作，未提交、推送或创建 Issue/PR。
- 开始分析时工作区已有未跟踪文件 `docs/implementation/2026-10-03-roi-evolution-luna-guide.md`；本轮未读取或修改它。后续执行不得将它纳入本任务提交。
- 原材料中的角色分工、Issue/PR 流程、性能目标与执行命令是建议，不构成用户授权。本文件中所有新增类型、方法和测试名均明确标为拟新增。

## 1. 问题结论

推荐沿现有架构完成三条闭环：**输入能保存；跟随证据正确；开台与接管容易理解**。不重建生成框架、跟读框架或逐句审阅系统。

已确认的优先问题：

1. 即启编辑区的 `quickDraftText`/`quickDraftTitle` 属于 View 的 `@State`，提交按钮之前没有进入 Session/Store；已建稿件的自动保存不能证明这部分输入可恢复。
2. `receiveSnapshot` 对后缀截断后的稳定前缀使用 `min`，没有减去被丢弃的 Unicode scalar 数。
3. `mayConfirm` 把同位置 final 与向后重读混在一个高门槛分支；空 final 清理候选后直接返回，未明确撤销旧的“已跟上”呈现。
4. 当前候选界面是一个全文 `TextEditor`。`preparedText` 只取 speak 块，而开台前无条件调用 `updatePreparedDraftText`，后者重建全为 speak 的块。原材料设想的段落用途菜单不能直接叠在这条路径上。
5. 原稿开台仍是次动作；已有稿件的“直接使用原稿”只生成版本，未立即开台。首次与已有稿件默认路径不一致。
6. 舞台主要根据 `voiceAssistState` 与 `hasHeardSpeech` 显示“语音跟随中”，没有充分体现 reducer 的定位证据；状态栏与错误内容条件插入正文上方，存在几何变化风险。

第 1、4、6 项的用户端现象尚未实机复现；本文件把代码路径与可验证风险分开陈述。稳定前缀公式错误可由静态反例确定，不能靠降低匹配阈值解决。

实施分层：

| 里程碑 | 工作包 | 退出条件 |
|---|---|---|
| M0 内容与控制安全 | TP-01～04，附候选采用安全回归 | 首次输入进入保存闭环；截断与 final 的确定性回归通过；旧事件不能恢复语音控制 |
| M1 默认用户旅程 | TP-05～09、TP-12 | 无 AI/麦克风可直接开台；候选修改可撤销；失败动作、状态与持久化结果一致 |
| M2 阅读质量证据 | TP-10～11 | 数字/重复句事件回归完成；回放报告口径明确；真实质量单独按授权验证 |
| M3 条件增强 | TP-13～15 | 仅有实测瓶颈或明确需求时进入；无证据则记 `deferred` |

## 2. 当前实现与根因

### 2.1 历史决定与当前证据

> 🧠 **From Hindsight memory (AI 提词器瘦身：删除逐句对照与审阅工作流)** — 历史决定是删除逐句审阅与内容范围选择，由 AI 提供完整候选、用户整体阅稿兜底；跟读定位和人工读法保留。历史清理稿件的授权不适用于本次任务。

已用当前 `TeleprompterSession.Phase.prepared`、active 提词器文档和候选 View 核对这一方向。原材料 §4 的“事实复核”“逐段原文对照”不能被解释为重新建立强制审阅、事实风险队列或 `phase.review`。

记忆页另有两条过时描述：声称内部 `reduce` 已删除、`TeleprompterV2SelectionRevision` 仍保留。本地核验表明 Pipeline 仍运行跨窗 `reduce`；已核验的 Domain/Store/Pipeline 中 selection 快照字段已移除，处理顺序使用 `orderedUnitIDs`。已向本项目记忆写入 Correction；复查知识页尚未反映更新，执行以当前源码与 active 文档为准。

图谱项目为 `Users-hrygo-Documents-SpeechRail`，generation 为 `2026-10-01T23:35:51Z`。已做 `check_index_coverage`：Session/View/Pipeline 显示 `metadata_changed`，SessionLifecycleTests 的 1959～1960 行为 `parse_partial`；相关源码及缺口已直接读取。图谱仅用于定位，不据此声称整仓完整或没有其他问题。

### 2.2 定位表

下表路径均相对仓库根目录，实施时按符号定位，不依赖固定行号。

| 位置 | 已核验行为 | 原因与处理 |
|---|---|---|
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift`：`welcomeHub`、`submitInstantDraft`、`loadStarterTemplate` | 即启字段只在本地 View；提交才创建文档；示例直接创建另一稿 | 非空输入应取得正常文档身份，替换输入前提交当前稿 |
| 同文件：`workbenchActionRow` | draft 的 AI 是 primary/⌘⏎；原稿是 secondary；prepared 开台前同步全文编辑缓存 | 统一开台入口；结构化块不能再被全文缓存覆盖 |
| `TeleprompterSession.swift`：`updateSourceText`、`scheduleDraftSave`、`load`、`invalidateAnalysis` | 已建稿件 500ms 防抖；`load` 先取消待保存任务再载入新稿 | 在待保存窗口内切稿可能丢最后一次编辑；需测试并在身份切换前 flush |
| 同文件：`preparedText`、`updatePreparedDraftText` | 仅拼 speak 正文；全文编辑按空行重建块，全部 `.speak`；区间使用 `para.count` | 丢失原块 ID/用途/来源；Character 数不能作为原稿 UTF-16 来源区间 |
| 同文件：`setBlockDisposition` | cue/skip 清空朗读正文，回 speak 从 `rawSourceText` 恢复 | 现有不变量应保留；撤销需恢复切换前改写正文，不能只反向改 enum |
| 同文件：`acceptPendingVersion`、`useDeterministicFallback` | 已有保存失败完整回滚 | 复用并补增量测试，不重复实现事务 |
| 同文件：`openForManualReading`、`openForManualReadingIfNeeded` | 手动开台无需采集；不自动采用未确认 AI 候选 | 所有开台动作汇合于此及既有 StageWindow 路径 |
| `TeleprompterFollowController.swift`：`receiveSnapshot` | 先 `suffix(2048)`，再 `min(stable, retainedScalarCount)`；nil/0 进入同一个匹配分支 | 原始坐标与截断坐标混用；证据缺失与明确无稳定前缀混用 |
| 同文件：`mayConfirm`、`receiveCompleted` | 非 forward 一律要求 0.95/6 matches；空 tokens 清候选就返回 | 同位确认被当成重读；空 final 未表达未确认 |
| 同文件：`TeleprompterRealtimeFollowAdapter.apply` | 成功主要由视口/状态/分数变化推导 | committed 同位确认可以不移动视口，必须由实际决策表达 |
| `TeleprompterSession.swift`：`handle`、`syncFollowState` | adapter outcome 未被用于呈现；completed 后根据 uncertainty 改 phase | 新未确认结果需贯穿 Session 与舞台；不能只修 reducer |
| `TeleprompterVoiceAssistLifecycle.swift` 与 Session 的 `requestVoiceStop` | generation 同步撤销，停止异步执行，有 stopFailed | 当前主干正确，补组合回归；避免另建控制权系统 |
| `TeleprompterStageView.swift`：`stageContent`、`statusText`、键盘处理器 | 状态区域条件挂载；following/stopping 共用主要文案；局部键只部分检查焦点 | 几何与焦点需单独验证，不能由业务单测证明视觉无跳动 |
| `TeleprompterV2Store.swift`：`save`、`validate`、`atomicWrite` | `formatVersion=3`；不覆盖不可读/未来版本；原子保存 | 保持持久化结构；新流程不需要清理已有稿件 |
| `TeleprompterDomain.swift`：`TeleprompterAIDataFlowDisclosure` | 确认键已绑定 endpoint/model；prepare 与 annotate 共用；说明仍写逐组对照 | 不是缺少接收方隔离，而是需补用途边界与真实文案 |
| `TeleprompterPreparationPipeline.swift` | grouping/rewrite、protected literals、有界恢复、原文 fallback、跨窗 reduce 与脱敏观察已存在 | TP-07 是闭环对齐，不重新创建整套验证器 |
| `TeleprompterReplayEvaluator.swift` | 已有事件/延迟样本分母、未推进/未恢复/草稿素材告警 | 扩展未确认与证据异常；不能另建一套评测器 |

### 2.3 缺陷与假设的边界

- F03：原文 3000 个单 scalar Character，保留后 2048 个，丢弃 952；稳定前缀 1500 在保留文本中只能覆盖 548。当前算出 1500，属于确定的坐标错误。
- F04：同 item snapshot“欢迎”已试探前进，final“欢迎”落在同一位置；当前逻辑进入重读门槛。需先测试断言 snapshot 确实推进，再断言 final 是否提交，避免假通过。
- F05：空 final 不提交 committed 是正确的；问题是没有明确未确认原因，可能继续沿用 tracking 文案。契约要求对已展示 hypothesis 的空 final 给保留/可读提示，不要求保存完整转写。
- F02：静态代码没有即启草稿保存路径；是否存在其他视图缓存或生命周期保留须由定向回归与授权的实际操作验证。
- 新发现 N01：prepared 开台无条件重建纯文本块，即使用户没有改字也会执行。应增加“未经编辑采用保留块”的回归，而不是仅修改段落标签。
- 新发现 N02：编辑后不足 500ms 切稿会先取消保存。需测“重载后内容”与失败时当前稿身份，不能只断言内存字段。
- F09：源码条件布局证明存在重排路径，但没有实测当前行基线位移；几何验收保持 `not_run`。

## 3. 目标行为

1. 首次输入和既有稿件都可保存、复制、重试；仅在 Store 成功后显示“已保存”。用户正常切页、切稿和开台不能取消最后一份待保存修订。
2. 原稿阶段唯一 `⌘⏎` 主动作是“打开提词器”；AI 整理为可选次动作。候选阶段唯一主动作是“用这份稿”，成功采用后开台。空稿不可开台。
3. 手动开台不调用 LLM、麦克风、ASR 或服务启停。目标时长无效不得阻塞原稿手动阅读。
4. 候选是一份可通读稿，保持段落身份和用途；cue/skip 正文仍可查看。用户整体采用即可，不设逐句必审或“事实已核实”保证。
5. 稳定前缀严格换算；非法证据暂停该事件的自动推进。nil、0、合法正值有明确策略。
6. 同 item 同位 final 可确认 committed，视口不重复移动；向后重读继续受强证据门禁。空 final 保位、不提交、给出“本句未确认”。
7. 人工操作立即撤销语音控制；停止失败保持真实状态；旧事件、旧连接和旧后台结果均不能推进。
8. 试读区分采集、识别与定位；不开台计时、不移动阅读位置、不创建会话记录。任一失败都保留手动阅读入口。
9. 临时语音/错误状态不推挤阅读行；键盘操作尊重输入和控制焦点，Reduce Motion 下不产生位移动画。
10. 关闭与重新打开保留同版本位置和显示偏好，恢复手动态。末行不自动退出、开麦或弹复盘。

## 4. 推荐解决方案

### 4.1 复用与修改边界

继续使用 Session、V2Store、FollowController、VoiceAssistLifecycle、Aligner、RealtimeClient seam、TrialReadingSheet 和 ReplayEvaluator。

只拟新增三类内部表达：

- Session 保存状态与稿件编辑修订号，用于区分 dirty/saving/saved/failed，不修改公共 HTTP/WS 契约。
- reducer 的明确决策结果，用于区分试探、确认、未确认和忽略，保留既有位置字段。
- 候选块编辑的有界撤销快照，绑定 document/candidate 身份，防止跨稿撤销。

不新增 parallel cursor、事件总线、事实风险检测器、选稿范围层、云同步或新的模型路径。除非现有 schema 确实不能表达授权目标，否则不改变 `formatVersion=3`。

### 4.2 对原材料的裁决

| 原材料建议 | 本执行方案 |
|---|---|
| TP-01 草稿恢复 | 实施；同时补保存 flush，复用正常文档存储 |
| TP-02～04 跟读正确性/控制权 | 优先实施；明确同位确认、空 final 与证据策略 |
| TP-05 默认入口 | 实施；原稿直接开台成为主路径 |
| TP-06 候选审核 | 改为整体阅稿与段落编辑，不恢复已删除审阅系统；先修 N01 |
| TP-07 事实/生成质量 | 保留现有结构、来源、protected literals 与 fallback；不新建语义事实打分/阻断系统 |
| TP-08～09 试读/舞台 | 先复用链路，再对齐状态、焦点和布局 |
| TP-10～12 场景、测量、继续 | 确定性回归实施；真实测量另行授权 |
| TP-13～15 优化/别名分支/复盘 | 条件或后续决策，不能当作本轮必做功能 |
| Issue、Draft PR、push | 当前未授权；执行方案不自动开启远端工作流 |

内部跨窗 reduce 保持现状：它已检查接缝并有 unchecked 结果，不新增用户可选“压缩”。原材料“不为凑时长删减内容”作为提示词与用户说明约束；不据此擅自删除现有阶段或重写 timing policy。

### 4.3 候选编辑的取舍

推荐单栏、连续呈现的段落编辑器：每段正文可改、用途为一个小菜单，高级动作渐进披露。其优点是 block ID、来源与用途可稳定保留。完整文本看起来仍是一份稿，不重建密集卡片与双栏审阅。

“继续用一个纯 TextEditor 并用文本 diff 猜来源”会把此次任务扩大为任意编辑的来源重映射算法；“每次重建全 speak”会丢用途。两者都不作为默认实现。跨段粘贴先作为单块正文编辑；拆分、合并复用现有显式方法。

## 5. 详细实施步骤

以下步骤供 Luna **获得后续实施授权后**执行，当前全部为待执行。

### E0：核对基线与范围

在仓库根目录核对 `git status --short --branch`、`git rev-parse HEAD`，重新检查相关文件变化。若基线变化，只重核受影响步骤；原材料相同 SHA 不是将来仍有效的保证。

按文件串行推进：Session/View 的各单元不要同时写入。无须创建子代理；本方案不授权委派。若与其他任务同文件并行修改，暂停该处，核实后续修改范围。

完成条件：记录实际基线、已有改动、将修改的文件和验证范围。没有完成 E0 不进入写入。

### E1：草稿所有权、真实保存状态与 flush（TP-01，N02）

文件：`TeleprompterSession.swift`、`TeleprompterView.swift`、`TeleprompterSessionLifecycleTests.swift`，仅现有存储不能表达时才改 `TeleprompterV2Store.swift`。

1. 先用当前 harness 写首次编辑持久化和防抖窗口内切稿的定向回归。首次编辑需通过拟新增 Session 编辑入口测试，不用“直接调用 createDocument”冒充 View 即启路径。
2. 将即启编辑的所有权移到 Session。拟新增 `updateQuickDraft(title:sourceText:)`：第一份有效非空输入建立普通 document ID；后续修改同一份文档，不能每个按键建一份。
3. View 使用同一个编辑绑定。布局判断优先识别 Session 当前内存稿件，不因 `documents` 列表读盘失败为空而切回另一个空编辑区。首字创建后不得重置输入、选区或焦点；实际焦点表现留给授权走查。
4. 保留 500ms 保存防抖，增加拟新增 `flushPendingDraftSave() throws`；`load`、新建/导入/示例替换、开台与 AI 输入快照前先提交当前待保存修订，再取消旧任务。
5. flush 失败时保留当前 document、内存文本、dirty 状态、复制与重试入口，不继续切换身份。加载示例保留原稿为正常稿件，不自动删除。
6. 拟新增保存状态包含文档 ID 与本地修订号。成功只确认写出的那一修订；取消和失败不能标成 saved。复用 `save` 清失败态的行为。
7. 页面离开尽力 flush；异常退出只承诺最后确认落盘的修订。原稿含暂时无效输入时，保留内存和复制入口，展示未保存，不通过 trim 或删除字符伪造成功。

完成条件：临时目录中新 Session 可重载最后已保存稿；失败不换稿；重试清失败态；同一编辑只用一个 ID。

建议逻辑提交点：`fix: preserve teleprompter drafts across navigation`，是否创建本地 commit 见 §9。

### E2：稳定前缀坐标与证据分类（TP-02、F06）

文件：`TeleprompterFollowController.swift`、`TeleprompterFollowControllerTests.swift`；需要 transport 身份回归时增补现有 `macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift`。

1. 先补 3000/2048/1500 回归和 Unicode 复合字符回归。保留已有 `anOutOfRangeStablePrefixPausesInsteadOfAligningUnrevisedText` 与 `aLongHypothesisWhoseStablePrefixExceedsTheStoredBoundIsNotAnAnomaly`。
2. `receiveSnapshot` 先针对 raw scalar count 校验，再计算截断映射，按 §6.1 实现。
3. `stable=0` 或合法前缀全部被截断：可以更新候选/预览文本，但不移动视口、不提交 committed、不显示已定位。nil 暂保留现有有界试探，绝不能标成稳定证据。
4. 非法负数/越界：记录异常、保位，不能降为 nil 后拿全文推进。生产 decoder 已把非法前缀变成 `invalid_hypothesis`，纯 reducer 与 replay 仍需防御。
5. 同一 item 的 revision 递增时比较已证明稳定的可保留重叠片段。若改写，记录异常并停用该 item 的 snapshot 推进，等待合法 final 或用户接管；不能立刻“重新相信”下一份 partial。
6. 仅保存有界片段及 scalar 起止坐标，不缓存无限增长的 utterance。RealtimeClient 的 `eventState.acceptHypothesis` 已校验 task/epoch/session/generation；本次不为稳定前缀额外发明服务器字段。

完成条件：548 换算正确；明确 0 和被截断的稳定区间不推进；nil 路径仍可在合法短距离证据下工作；无异常被静默掩盖。

建议提交点：`fix: map stable evidence into retained hypothesis coordinates`。

### E3：同位 final、空 final 与明确决策（TP-03）

文件：`TeleprompterFollowController.swift`、`TeleprompterSession.swift`、`TeleprompterReplayEvaluator.swift` 及三者对应测试。

1. 先补 snapshot“欢迎”→同 item final“欢迎”的短句回归；断言 committed 前后、viewport 不重复移动。
2. 为 Item 保存最近一次有效试探位置/证据身份，拟新增内部 `TeleprompterFollowDecision`。接收方法返回实际决定，`@discardableResult` 只用于无需消费结果的调用点。
3. 拆开 `mayConfirm`：同位合法确认、向前有界推进、向后强证据重读。相等不等于 backward；同位分支要求同 item 当前有效试探且 fresh final 本身也满足匹配证据，不把已退休/弱匹配 final 无条件提交。
4. `receiveCompleted` 空 canonical tokens：保持 viewport 和 committed，清候选，产生 `finalUnconfirmed`；若此前有非空假设，置未确认状态/原因。没有先前内容的空 completed 不制造“用户说过话”的结论。
5. Adapter 由返回决定产生 outcome。拟增加 `.confirmed`/`.unconfirmed` 等内部结果；位置没变但 committed 被确认也必须可观察，ignored 只表示未生效事件。同步更新所有 switch 与测试。
6. Session 的 `handle`/`syncFollowState` 消费结果，不能再用“视口动了”或 `hasHeardSpeech=true` 等同定位成功。舞台给“本句未确认，位置已保持”，不展示或落盘全文 ASR。
7. ReplayEvaluator 增加未确认 final/稳定异常聚合计数；采用 §6.5 的明确报告版本处理。空 final 不记为成功确认、不要放进成功延迟分母。

完成条件：短句同位可提交；重复/迟到/手动撤权 final 被忽略；空 final 无伪确认；真正 backward 门槛没有被放宽。

建议提交点：`fix: distinguish teleprompter confirmation from rereading`。

### E4：控制权与停止失败组合回归（TP-04）

文件：`TeleprompterSessionLifecycleTests.swift`、`TeleprompterVoiceAssistLifecycleTests.swift`；仅回归暴露缺陷时修改 Session/Lifecycle/Realtime seam。

复用 harness 的 fake source/client、`TestGate`、coordinator 与临时 Store。组合 E3 事件与手动定位、延迟连接、停止失败、重复关闭、重新打开。

必须覆盖：接管在 await 前使 generation 失效；旧空 final 不覆盖新状态；旧连接完成只清理旧资源；stopFailed 不开启第二条 pipeline；重试成功才允许新启动；停止不影响其他功能占用。

区分“本地资源已释放”和“上行完成屏障失败”。`finishStageClose` 在 source/client/coordinator 均清理后回 off 可以成立，不能因 drain 失败永久宣称麦克风仍在采集；反之资源未知不得伪装 off。

完成条件：现有 `manualTakeoverInvalidatesOldPipeline`、`lateConnectAfterManualTakeoverIsReleased`、`stopFailureBlocksASecondPipeline` 等回归及新增组合通过。

建议提交点：仅有新回归时 `test: protect teleprompter authority across final and stop races`。

### E5：默认开台路径与失败恢复（TP-05）

文件：`TeleprompterView.swift`、`TeleprompterSession.swift`、`TeleprompterDomain.swift`、`TeleprompterAnalysisTests.swift`、SessionLifecycleTests。

1. 即启与 draft 都使用“打开提词器”primary/唯一 `⌘⏎`；“整理朗读稿”secondary。原稿动作只调用持久化边界与 `showStage`，由现有手动入口生成确定性版本。
2. ready/ended 的开台也注册一个一致快捷键；prepared 主动作改“用这份稿”，采用成功后调用 `showStage`。每个相位同屏只注册一个 `⌘⏎`。
3. blocked 横幅中的原稿恢复动作与常驻底座共享同一处理入口；blocked 时不能仅隐藏底座而失去开台、保存重试或复制。
4. AI 与语音错误不得封锁可读原稿；保存失败按 E1 保留内容与恢复入口，不越过事务把失败说成成功。
5. 更新 AI disclosure，删除“逐组审阅”描述，明确准备原稿与朗读标注是两种用途。拟新增 purpose 参数，确认键继续以 endpoint/model/purpose 的散列隔离；旧键不推导新用途已同意。禁止把 endpoint 或正文写入 key。
6. 用 fake preparationClient/audio factory/client 断言手动路径调用计数为 0；错误提示只输出应用自己的分类，不回显 HTTP body。

完成条件：无 AI 配置可一次开台；无隐式权限申请；快捷键相位一致；路由或用途变化重新披露。

建议提交点：`feat: make manual teleprompter opening the default journey`。

### E6：保留候选块、段落用途与撤销（TP-06、N01）

文件：`TeleprompterView.swift`、`TeleprompterSession.swift`、`TeleprompterPreparationDomain.swift`（仅新增快照类型必要时）、SessionLifecycleTests/V2StoreTests。

1. 先补未经编辑的候选采用不改变 block IDs、source ranges、cue/skip 与 rawSourceText 的回归。包括 View 主动作当前无条件全文回写的路径。
2. `workbenchPreparedContent` 改连续段落编辑，使用 readingBlocks 稳定 ID。speak 展示/edit text；cue/skip 展示 rawSourceText 并保持只读正文，用途仍可改。
3. 每段用途使用显式菜单“照念／只作提示／跳过”，当前状态可见；全段正文与来源身份始终保留。高级结构动作仅复用现有菜单与 Session 方法，不新增逐句 UI。
4. 移除 prepared 主动作的 `updatePreparedDraftText(localPreparedText)`；删除本路径的双层全文防抖与缓存。段落编辑直接汇入 Session 的保存时序。仅 UI 缓存不足以替代 flush。
5. 拟新增有界 `TeleprompterPreparedEditSnapshot`：保存完整 readingBlocks、pendingVersion 和相关预算状态，绑定 document ID/candidate ID。一次操作前取快照；撤销恢复切换前改写正文、origin、用途与来源，随后重新保存。
6. `setBlockDisposition`/`updateBlockText` 等入口补 `canEdit`、phase 与候选身份守卫。所有 speak 必须非空；cue/skip text 必须为空；全 skip 时不允许开台并说明“还没有可朗读的段落”。
7. 来源区间只能引用不可变原稿 UTF-16。修改朗读文字不改变 sourceRange；拆/合操作走显式来源语义。当前 `updatePreparedDraftText` 的 Character 伪来源逻辑在新路径移除，不能改成 UTF-16 长度后继续假装它来自原稿。
8. 采用沿用现有保存失败回滚；保存失败仍保留候选和撤销能力。切稿/放弃/重新整理时清理对应撤销历史，不能跨身份恢复。

完成条件：无需编辑即可原样采用；用途可选可撤销；“改写文本→skip→撤销”恢复的是改写文本；emoji 编辑后来源合法；采用失败完整保留。

建议提交点：`fix: retain prepared block identity through edits and adoption`。

### E7：生成失败说明、试读与舞台呈现（TP-07～09）

按三组自洽单元串行实施，不把全部 UI 和 Pipeline 改成一个大包。

**E7a 生成链路**：`TeleprompterPreparationPipeline.swift`/Prompts、Session 的 `aiFailureMessage` 与 View 的 fallback 横幅。

- 用现有 `TeleprompterAIObservability.errorCode`、`LLMError` 与真实 HTTP 分类生成文案；取消、未配置、认证、限流、额度耗尽、格式不符、本地保存失败分别表达。
- 删除“最常见原因是请求过于频繁”的无证据推断。局部 fallback 表述“部分内容保留原稿”，边界 unchecked 表述未完成检查，不标整稿 AI 成功。
- 复用 protected literals、source window 覆盖与 generation 守卫；只补本次涉及的数字、漏窗/重复窗与迟到结果测试。不添加 `SemanticRiskDetector` 或保证否定/限定词语义等价的宣传。
- 保留跨窗 reduce；取消保持原稿与已落盘候选，未完成窗口不能冒充完整可采用稿。保存已有有效候选与“采用不完整结果”是两回事。

**E7b 试读**：`TeleprompterTrialReadingSheet.swift`、`TeleprompterTimingPolicy.swift`、Session 的 trial 方法及相关测试。

- 复用两种模式与三段证据，不新增预检窗口。电平≠识别，识别≠定位；没有 recognized/matched 样本不产生校准成功。
- 校准来源沿用现有 provenance；未校准/不确定分别显示估算和无法可靠估计。打开 sheet 不采集，明确按钮才开始。
- 失败不给 AI/模型配置向导挡住开台；离开或关闭只停止 trial 自己的资源。

**E7c 舞台**：StageView、StageInteractionPolicy、StageSettings、DesignTokens、FollowPresentation。

- 生命周期表示控制权；reducer 决策表示当前位置证据。按 §6.4 输出统一文案，following 不能只因收到一次识别就显示已定位。
- `stageContent` 将临时状态从正文测量链移出：常驻既有辅助槽，错误在控制/覆盖层渐进展开，正文固定基线；错误全文必须可键盘/VoiceOver 访问，不能用 24pt 槽裁掉长错误。
- 复用当前 `stageAuxiliaryBarHeight=24`、`stageControlAreaHeight=48`，不要复制历史文档的 64pt。新视觉值集中声明并同步设计系统。
- 统一 `acceptsReadingKeyCommands` 守卫到上下行、空格、j/k、Home/End 等；控制焦点或输入焦点存在时不穿透。v/m 也不得劫持文本输入。
- 设置弹层关闭后，仅舞台仍为有效操作目标时恢复阅读焦点；ASR 回调不能夺焦点。镜像不反转前后行命令语义。

完成条件：生成失败分类有依据；试读证据和校准不混淆；状态呈现单测通过；UI 编译验证完成。实机几何/焦点仍须单独走查。

建议提交点：生成说明、试读呈现、舞台状态分别一个逻辑主题。

### E8：关闭、继续与测量（TP-10～12）

文件：Session、稿件列表/ready 页、Normalizer/Aligner、ReplayEvaluator/ReplayTool 及对应测试。

1. `saveProgress` 持久化的是用户阅读锚点 `viewportAnchor`，不是假装所有试探都已确认。保留 version/segment/UTF-16 身份；展示“继续上次位置／从头开始”。
2. “从头开始”复用 `restartToBeginning`；“继续”复用 `restoredReadingPosition`。重开不启语音；跨版本 offset 只在正文相同条件下复用，保留已有保守迁移。
3. 保存进度失败应显示位置未保存；复制稿件、手动阅读与再次保存可用。将内存锚点和最后落盘锚点区分，不显示“已保存”。
4. 数字合法等价与错误值成对测试；重复句与单 token 近/远场成对测试。先证明确有有效候选再测门禁，不靠“根本没匹配上”证明安全。
5. 扩展现有延迟统计：客户端接收→决策仍用 ContinuousClock；它不是读者读到→舞台显示的端到端时延。实际显示确认需要授权测量，未授权保持 `not_run`。
6. replay 保留每一失败 episode、样本分母、无样本 null 与草稿告警；不得以“全部不动”换取 0 误跳。
7. 单独获得真人音频/质量基准授权后，同一素材比较 baseline/candidate；保留逐场景与失败记录。5人×6个约3分钟场景合计约90分钟录音，另需标注时间；不是默认测试成本。

完成条件：重新载入恢复合法位置与手动态；数字/重复句回归通过；报告不混淆事件数和可测样本数；真实质量状态如实标注。

建议提交点：位置继续、场景回归、测量报告分别成原子单元。

### E9：条件增强（TP-13～15）

- TP-13：只有 E8 发现匹配/主线程/队列瓶颈才改；任务若移到后台，提交时同时检查 generation、冻结版本、item/revision 与当前锚点。可合并 mutable snapshot，但不得丢 final/failed/屏障。
- TP-14：只有成对真人样本证明收益才试验局部别名双路径；不顺序拼接两份 token，不全局替换拼音，不改用户原稿。
- TP-15：需后续产品范围确认，再增加工作台可选聚合复盘；不在台上弹出，不保存全文/PCM，不制造演讲评分。

没有上述证据或授权时，E9 的正确完成方式是记录 `deferred` 与所缺条件，不生产“为了完成路线图”的实现。

## 6. 关键实现说明

### 6.1 稳定前缀公式与有界比较

```text
rawCount = rawText.unicodeScalars.count
validate 0 <= stable <= rawCount             // nil 单独处理
retained = String(rawText.suffix(2048))        // Character 截断，保留完整字形
retainedCount = retained.unicodeScalars.count
droppedCount = rawCount - retainedCount
retainedStable = clamp(stable - droppedCount, 0, retainedCount)
```

匹配取 `retained.unicodeScalars.prefix(retainedStable)`，不能用 `String.prefix` 按 Character 消费 scalar 长度。后续定位仍由 Canonicalizer/Aligner 映射到原稿 UTF-16，不把 ASR scalar 坐标写成舞台坐标。

Item 拟保存 raw scalar 数、丢弃起点、raw stable 长度、可保留稳定片段及 `snapshotEvidenceInvalid`。比较的是相同 item 原始坐标中的重叠稳定片段；截断使无法比较的部分不产生“全文稳定验证通过”。retire/reset 时删除这些内存证据。

### 6.2 同位确认判定

```text
if event is rejected/retired/stale/manual:
    ignored
else if final tokens empty:
    keep viewport and committed
    unconfirmed only when prior nonempty evidence existed
else if final position == viewport and matches this item's valid preview:
    require fresh final's admissible local evidence
    update committed; keep viewport
else if final is forward:
    existing bounded advance rule
else:
    existing strong reread rule
```

禁止把“不是 forward”全部命名为 controlled reread。新 item 刚好匹配同坐标不能借用旧 item 的 preview；弱 final 不因 snapshot 曾高分而被强行确认。

`mayAdvance` 中现有 unique 快捷分支也要以 TP-10 的近/远单 token 对照审计；本计划不先扩大单 token 放行策略。新确认规则不得绕过距离、唯一性与匹配长度约束。

### 6.3 保存与撤销语义

拟新增 `TeleprompterDraftSaveState` 可表达 `dirty`、`saving`、`saved`、`failed`，关联 document/revision。本地 Store 目前同步写入；不要为了动画另建异步落盘链，造成过期成功回调。

保存成功才推进 persisted revision；flush 失败先保留旧身份。候选采用失败沿用完整事务恢复。撤销恢复全快照，而不是把 skip 切回 speak 后从 rawSourceText 重新拼一份。

候选编辑的原稿范围始终是 `[start,end)` UTF-16；正文变长不改变原稿来源。拟新增编辑状态和撤销历史只存内存，不加入用户文件格式。

### 6.4 状态优先级与文案

| 有证据的状态 | 用户文案 |
|---|---|
| 生命周期 off，手动阅读 | 手动提词 |
| 正在申请采集/连接 | 正在开启语音跟随… |
| 实际采集，无有效识别结果 | 麦克风使用中，请开始朗读 |
| 已识别但未定位/证据不足 | 正在定位，位置已保持 |
| 当前 generation 有有效位置证据 | 语音跟随中 |
| 有假设的空 final | 本句未确认，位置已保持 |
| 人工接管 | 已切到手动 |
| 正在停止 | 正在关闭语音，仍可手动提词 |
| 资源尚未确认释放 | 语音关闭未完成，请重试 |
| 语音链路失败 | 语音暂不可用，仍可手动提词 |

停止失败/blocked、未确认、定位不足的说明优先于旧 tracking。显示“麦克风使用中”须读取实际采集，不根据连接成功推断。相似度不显示为概率。

### 6.5 回放报告与性能门槛

E3 增加字段时，若执行时确认 `teleprompter.eval.v1` 没有严格下游消费者，仍明确升级输出至拟新增 `teleprompter.eval.v2` 并同步 CLI help/测试/文档；输入 `teleprompter.replay.v1` 保持现有结构。若发现实际消费者，先核实其更新范围，不默默破坏依赖。

拟新增聚合：`unconfirmed_final_count`、`stable_prefix_contract_anomaly_count`。不包含 item IDs、正文、文本哈希、音频或私人路径。

原材料的 P95 ≤50ms 本地处理、≤1.5s 端到端、≥95%回稿恢复、≤1s开台、≤100ms手动响应均为候选目标。先取得 baseline，再决定是否可作为门槛；算法回归通过不能替代真实测量。

## 7. 测试方案

使用现有 Swift Testing 与 fake transport/临时 Store；不下载模型、不调用云端、不使用私人音频。下列测试名是拟新增建议名，执行时可按套件习惯调整。

| 文件/套件 | 新增或补强场景 | 必须断言 |
|---|---|---|
| `TeleprompterSessionLifecycleTests.swift` | `quickDraftSurvivesSessionReload`、`switchingDocumentFlushesPendingEdit`、`failedFlushPreservesCurrentDocument` | 真正重载内容、同一 ID、旧身份保留、失败后可复制可重试 |
| 同上 | `adoptingUneditedCandidatePreservesBlocks`、`dispositionUndoRestoresRewrittenText` | blocks/来源/用途不变；撤销恢复原改写正文，而非 raw fallback |
| 同上 | `candidateEditsAreRejectedWhileStageIsOpen` | 不可编辑时任何段落方法都不改变版本 |
| `TeleprompterFollowControllerTests.swift` | `retainedStablePrefixSubtractsDroppedScalars` | 3000/2048/1500→548；稳定尾后不可推进 |
| 同上 | 复合 emoji、组合重音、前缀全被截断、原文合法长前缀 | Character/scalar/UTF-16 分开；不误判原文合法值越界 |
| 同上 | nil、0、负数、越界、稳定区间改写、新 revision | nil 有界试探；0/非法不推进；异常可观察；重复 revision 不追加 |
| 同上 | `sameItemShortFinalConfirmsWithoutMovingViewport` | 先证明 snapshot 推进；final 提交同位；无二次视口推进 |
| 同上 | `emptyFinalAfterPreviewIsUnconfirmed` | committed 不变；保位；未确认；无先前文本的空 final 不虚构发言 |
| 同文件 Adapter 套件 | 同位确认、相同位置重复 final、退休 item | outcome 表示实际确认；重复/旧事件 ignored |
| Session/Lifecycle 套件 | 旧空 final、延迟连接、重复接管、stopFailed→retry→new start | 控制权同步撤销；无第二条 pipeline；资源/占用真实 |
| `TeleprompterPreparationPipelineTests.swift` / PromptsTests | 局部 fallback、reduce unchecked、取消、重复/缺失 ID、protected 数字丢失 | 回退单列；不误报完整成功；原稿保留；严格 decoder 不放松 |
| `TeleprompterAnalysisTests.swift` | endpoint/model/purpose 确认隔离、原稿开台不触发 AI | 确认不能跨用途复用；散列不泄漏 endpoint；模型调用数 0 |
| `TeleprompterTimingPolicyTests.swift` / Session trial 用例 | 有电平无文字、有文字无定位、无校准、关闭释放 | 三段独立；无伪校准；位置/计时/SessionStore 不变 |
| `TeleprompterStageSettingsTests.swift` / InteractionPolicyTests | 文案优先级、输入焦点规则、Reduce Motion、位置重映射 | 纯状态规则可测；不冒充实际画面/键盘验收 |
| `TeleprompterNormalizerTests.swift` / `TeleprompterAlignerTests.swift` | 3.5/三点五、50%/百分之五十及 35、万元/亿元、负号反例 | 正确等价保留原稿范围；冲突数值不形成强等价 |
| 同上及 FollowControllerTests | 重复开场、后续区分词、近/远单 token、真正重读 | 不远跳；足够证据后能恢复；不能以全部冻结证明安全 |
| `TeleprompterReplayEvaluatorTests.swift` | 新计数、未推进、无恢复样本、draft素材、失败分母 | v2 schema 正确；无样本 null；失败不从分母消失 |
| `TeleprompterV2StoreTests.swift` / Session | 改完稿重载、候选采用失败、Unicode来源、未来版本隔离 | format 3 仍可读；失败不覆盖已有文件；来源合法 |

优先保留现有保护测试：`manualOpenHasNoAudioSideEffects`、`aStoreFailureWhileAcceptingKeepsTheDraftOnScreen`、`aSuccessfulExplicitSaveClearsTheStoreFailure`、`manuscriptTextStaysReachableWhileStoreFails`、`closeAndReopenPreservesPosition`。新增用例应测试行为与失败路径，不只镜像新增 enum。

所有本节场景本轮均未运行。UI 验收不得由源字符串扫描或编译通过替代。

## 8. 验收标准

### 8.1 运行入口

在仓库根目录执行；**以下为后续获授权后的命令，本轮未执行**。选择本单元实际涉及的套件，不默认运行全套：

```bash
git status --short --branch
git rev-parse HEAD

swift test --package-path macos/SpeechRailApp \
  --filter 'TeleprompterFollowControllerTests|TeleprompterRealtimeFollowAdapterTests'

swift test --package-path macos/SpeechRailApp \
  --filter 'TeleprompterSessionLifecycleTests|TeleprompterVoiceAssistLifecycleTests|TeleprompterV2StoreTests'

swift test --package-path macos/SpeechRailApp \
  --filter 'TeleprompterPreparationPipelineTests|TeleprompterPreparationPromptsTests|TeleprompterAnalysisTests'

swift test --package-path macos/SpeechRailApp \
  --filter 'TeleprompterTimingPolicyTests|TeleprompterStageSettingsTests|TeleprompterStageInteractionPolicyTests'

swift test --package-path macos/SpeechRailApp \
  --filter 'TeleprompterCanonicalizerTests|TeleprompterPositionTests|TeleprompterReplayEvaluatorTests'
```

预期是命中的目标用例实际执行、0 failures。过滤后 0 tests 不是通过；执行者核对实际 suite/test 名。NormalizerTests 的真实套件名为 `TeleprompterCanonicalizerTests`，AlignerTests 为 `TeleprompterPositionTests`，不能按文件名凭空假定过滤器。

View/TrialReadingSheet 不在当前 SwiftPM sources 清单；SwiftPM 测试不足以验证全部 UI 编译。只有获得 App 构建授权后先读 release skill，再使用现有包装入口：

```bash
scripts/macos_app_build.sh --configuration Debug
```

不裸跑 `xcodebuild`，不自动安装 .app。新建 Swift 文件必须同步 SwiftPM 明确 sources 与 Xcode 项目；使用现有文件可免去无收益的工程文件改动。

已授权且提供仓库外 manifest 时才运行回放：

```bash
swift run --package-path macos/SpeechRailApp teleprompter-replay --help

# 下面两个变量由执行者设为实际获授权的仓库外路径。
swift run --package-path macos/SpeechRailApp teleprompter-replay \
  --manifest "$TELEPROMPTER_MANIFEST" \
  --output "$TELEPROMPTER_REPORT"
```

缺依赖不自动下载或转成全套构建；没有 manifest 不自行录音。真实 worker、性能基准、UI 自动化分别按适用专项授权执行。

### 8.2 可执行验收清单

- [ ] E1：首次输入重载可恢复；防抖期间切稿不丢已接收编辑；保存失败保留身份与复制，重试成功状态更新。
- [ ] E2：548 反例、Unicode、nil/0/非法、稳定改写回归通过，旧 revision 不追加。
- [ ] E3：同位短 final 提交而不重复移动；空 final 不提交且有提示；backward/远跳门槛不放松。
- [ ] E4：接管同步撤权；旧回调不能推进；stopFailed 不启动第二条 pipeline；重试与关闭幂等。
- [ ] E5：原稿开台调用 LLM/麦克风/ASR 计数均为 0；目标时长无效不阻塞手动；相位快捷键唯一。
- [ ] E6：未编辑候选采用保留块；用途撤销恢复准确；来源 UTF-16 合法；采用失败可重试。
- [ ] E7：错误分类与证据对应；试读不动位置；状态不伪确认；UI 包装构建完成后再记录编译通过。
- [ ] E8：重载恢复正确版本/位置与手动态；末行无自动关闭；数字/重复句与报告分母回归通过。
- [ ] 文档：同步 active 提词器说明、受影响的设计 Token/组件规范；若报告 schema 改变，同步 CLI 与报告文档。
- [ ] 实机走查（独立授权）：窄/宽窗口、稿首末、1/2/3行、语音启停/错误、popovers、输入焦点、VoiceOver、Reduce Motion。
- [ ] 真人质量（独立授权）：同样本 baseline/candidate，逐场景报告样本数、错误跳转、恢复失败、P50/P95；无样本写 N/A。
- [ ] 交付：记录实际 SHA、测试命令/用例数/结果、运行态动作、未验证项；有 commit 授权才报告 commit hash。

### 8.3 已有证据与未执行项

本轮已完成：本地 SHA/工作区核对、相关源码/契约/文档读取、图谱覆盖补证、原文件移动且 hash 一致、执行方案落盘。

本轮未完成也未声称完成：任何缺陷运行复现、自动化测试、App 构建、实际快捷键/屏幕几何/VoiceOver 检查、真人音频、延迟/质量/长期资源测量。原文与历史文档的测试数字不作为本轮成绩。

## 9. 风险与注意事项

1. **授权**：本轮只有整理与生成方案授权。后续实施授权仅覆盖明确范围及必要定向验证；UI 自动化每次都须当前用户消息明确要求，需先说明占用窗口与时长。
2. **Git**：`luna-guide` 默认建议小步自动本地提交，但本仓库 `AGENTS.md`“未被明确要求时不自动提交、推送或创建发布物”适用。故 §5 的提交点是建议，只有明确 commit 授权后执行；push/PR/merge/发布分别确认范围。不要从原材料“开 Draft PR”推导当前授权。
3. **数据**：不清理现有稿件，不重置 UserDefaults，不重用旧数据清理授权。默认保持 format 3；若实际必须升级，先给出迁移与回滚设计，保留仓库外数据备份，不能静默实施破坏性变更。
4. **内容语义**：段落编辑必须保持源修订与候选身份。cue/skip 不念不等于隐藏；撤销不能只恢复 enum；全稿纯文本重分段不能冒充来源映射。
5. **隐私**：fake 用人工构造文本；真实 WAV/manifest/日志在仓库外且另行授权。diagnostics 不保存完整 prompt、转写、正文、音频、文本哈希或 secrets。
6. **运行态**：不启停服务、切 profile、加载/卸载模型、安装 App 或替换 wheel。以后需要时先读 local-deploy/release/perf 对应 skill，不把 build 等同部署。
7. **兼容**：内部 outcome 与回放报告可标准化，不增加无依据 alias。持久化用户数据与实际下游消费者属于独立保护边界，不能借“不兼容旧行为”删除它们。
8. **质量**：更保守的 stable=0 策略可能降低短片段推进速度。先以正确性测试交付，真实回放验证质量取舍；不能虚构数值来承诺更快。
9. **回退**：没有持久化升级时恢复本任务代码即可，保留所有稿件和位置。已明确提交的单元可用受控 revert 回退；未提交时仅手工撤回自己的对应 hunk，保留并行改动。不得 `reset --hard` 或整文件覆盖。
10. **文档回退**：原方案可以原样移动回原 Downloads 路径，但先确认目标不存在；执行方案保留为 proposed 或按用户要求移入 archive，不擅自删除。

## 10. Luna 执行清单

- [ ] **E0**：取得后续实施范围，核对实际 HEAD/工作区与并行修改，记录证据日期；不得开始远端流程。
- [ ] **E1 / TP-01**：先写重载与 flush 失败回归，再统一草稿所有权；完成真实保存状态和保护性切稿。
- [ ] **E2 / TP-02**：修 scalar 截断公式，定义 nil/0/正值与稳定改写策略；通过坐标/边界回归。
- [ ] **E3 / TP-03**：分开同位/前进/重读；空 final 未确认贯穿 reducer→adapter→Session→报告。
- [ ] **E4 / TP-04**：补跨组件 race，确认同步撤权与资源清理；M0 只记录实际通过的安全用例。
- [ ] **E5 / TP-05**：原稿开台 primary，AI 可选；快捷键与恢复动作同源；披露按接收方/用途隔离。
- [ ] **E6 / TP-06**：移除全文回写造成的块重建，实施连续段落编辑与精确撤销；保持整体阅稿定位。
- [ ] **E7a / TP-07**：复用结构与保护校验，真实错误分类与 fallback/unchecked 说明；不重建事实审阅层。
- [ ] **E7b / TP-08**：试读三段证据与校准来源一致，失败不阻塞手动开台。
- [ ] **E7c / TP-09**：统一舞台状态、布局预留、焦点/键盘；获授权后完成 UI 包装构建，视觉验收分开报告。
- [ ] **E8 / TP-10～12**：数字与重复句回归、关闭继续、报告版本与分母；M2 真人样本未授权则记 `not_run`。
- [ ] **E9 / TP-13～15**：仅按瓶颈/质量证据与新增范围进入；否则记录 deferred。
- [ ] **文档**：同步 `docs/developers/macos-app-teleprompter.md`；视觉契约变更同步设计系统；报告变化同步 CLI/测试。正文实质修改才更新 date/version。
- [ ] **验证与提交**：按 §8 选择最小检查；明确授权 commit 后检查暂存 diff/`git diff --staged --check`/敏感信息，只提交本任务文件，每个逻辑主题一个 commit。
- [ ] **最终报告**：列实际改动、测试结果、验证时间、commit hash（如有）、实际运行态动作和所有未验证项。逻辑回归不写成真人跟读质量已通过。
