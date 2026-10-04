---
title: "SpeechRail 高 ROI 进化 — 实施结果与验收对照"
status: implemented
created: 2026-10-03
reviewed_ref: be75055cc0a5f7f044ae56c955896812a1d69915
plan: docs/implementation/2026-10-03-roi-evolution-luna-guide.md
verification_date: 2026-10-03
---

# 实施结果与验收对照

本文件对照 `2026-10-03-roi-evolution-luna-guide.md` 的八个工作包，逐条说明**实际改了什么**、
**哪条命令证明它**、以及**哪些结论仍然没有证据**。只写已经跑过的结果；没有实测的一律留在
"未验证"里，不因为测试全绿就往上抬。

## 1. 工作包状态

| 包 | 状态 | 主要落点 |
|---|---|---|
| A 作品库事务与恢复 | 已实施 | `CreativeWorkStore.swift`（journal、隔离区、启动恢复、同 ID 幂等） |
| B1 服务端配方 | 已实施 | `domain/render_recipe.py`、`application/render_recipe.py`、`application/render_receipts.py` |
| B2 执行侧采样事实 | 已实施 | `domain/tts_sampling.py`、`backends/qwen3_tts_worker.py`、`backends/qwen3_tts.py` |
| B3 App/作品投影 | 已实施（两项要求未交付，见 #191 #189） | `ServiceContractTypes.swift`、`CreatorServiceClient.swift`、`ServiceAPIClient.swift` |
| C 文档与事实对齐 | 已实施（门禁只覆盖 current-boundaries，api-contract 侧未扩，见 #192） | `docs/architecture/current-boundaries.md`、`scripts/check_current_boundaries_contract.py`、`docs/users/api-contract.md`、`contracts/openapi.yaml` |
| D 段落重做与导出 | 已实施 | `DubbingProjectStore.swift`、`AppModel.swift`、`CreatorSurfaceViews.swift` |
| E 提词器场景 | 确定性部分已实施 | `TeleprompterSessionLifecycleTests.swift` 等；真实设备与真实口播仍未验证 |
| F 首次结果引导 | 已实施 | `FirstResultReadiness.swift`、`ServiceOverviewView.swift` |
| G 跨接口一致 | 已实施 | `tests/test_interface_parity.py`、`AppModelTests.swift` |
| H 职责与错误归属 | 已实施 | 段落返修的存储失败不再被当成创作服务失败（`AppModel.dubbingErrorMessage`） |

## 2. 验收标准逐条对照

### ① 保存、删除、改名与重启恢复

`works.json` 的原子替换是唯一逻辑提交点；`.transactions/<txID>/journal.json` 记录中间态，
`.recovery/<txID>/` 承接已提交但未完成的删除。启动、读、写都先过恢复。同 ID 同内容返回原
记录，不同内容返回 `workConflict`。

证明：`CreativeWorkStoreTests`（39 条，覆盖 ENOSPC / EACCES / 中断 / 重启后二次恢复幂等）。

审查中补齐了四处「守卫在、但没被考到」的落盘边界：

- **音频文件名必须由标识符推导。** `isSafeIdentifier(work.id)` 只管住了 `id`，
  `audioFileName` 是另一个同样被拼进路径的字段。放它过去，一个合法 `id` 配一个
  `../escaped.wav` 就能把音频写到作品目录之外——#161 那条防线挡的是路径逃逸，
  守卫却落在第二个字段上，此前没有任何用例走过它。
- **保存与读取都不接受空音频。** 保存 0 字节会让作品出现在列表里却放不出声音；
  读取 0 字节若不报 `audioUnavailable`，空数据会直接交给播放器。
- **改名同样收敛长度。** `clampedTitle` 只在 `rename` 一处被调用，
  超长标题此前可以原样写进索引。

保存过一次作品之后，后续生成失败**必须仍然看得见**。配音台的结果位此前是一条互斥链
（`待保存 / 上次成品 / 失败提示`），而 `lastCreatedWork` 只在删除那件作品时才清空——
于是它会永远遮住失败，而"保存过至少一件作品"恰恰是配音台的正常状态。用户按下生成、
按钮转一圈恢复原样，既没有新成品，也没有任何提示。

结果位因此收敛成模型上的 `DubbingDeskSlot`，**枚举里没有失败分支**：失败与结果是并排的
两件事，不是互斥的三选一，"旧成品遮住新失败"在类型上就不可能发生。视图只读这个投影
和 `creatorMessage`，不再自己串 `if let`。

### ② 制作配方贯通

REST 完整性回执产出 `plan_id` 与 `recipe`；`recipe` 在请求时缺少执行侧事实，因此先为
`partial`，随后由两处迟到观察补齐：`model.engine_revision`（worker 身份）与
`parameters.seed_policy` / `observed_sampling_parameters`（**本次实际使用的采样器**）。
seed 只有真正下发到采样流才记为固定策略；运行时装不上确定性采样时如实记为
`unseeded_sampler`，配方仍可为 `complete`，但不代表可重现。

App 侧把配方投影成强类型快照随作品冻结，回执缺失时保留完整音频并把 `provenance` 标成
`partial` / `unavailable`，老作品读作 `legacyUnknown`，不回填历史身份。

「追溯完整」由**四个**条件共同成立：`state == .complete`、`digest != nil`、
**`missing_fields` 为空**、**`audio.pcm_sha256` 存在**。

前两个是服务端对自身的评定，只有第三个是客户端独立解码出来的信号。正因为第三个
独立，**三者必须一致**：一份自称 `complete` 却仍列着缺失事实的回执会被判为
`partial`（`recipe_incomplete_…`），而不是被显示成追溯完整——否则 `verified` 就只是
"服务端这么说的"。

第四个条件回答的是另一件事：配方齐全只说明服务端描述**执行过程**的事实齐全，与
「App 手里的这段音频就是它渲染的那段」是两件事。没有音频摘要就没有任何可追溯的
对象，因此 `"audio": {}` 也只能是 `partial`（`audio_digest_missing`）。

**尚未做到的一步**：`pcm_sha256` 目前只是被搬运，从未与 App 实际收到的字节比对。
实施方案 §5 B3 要求「保存 `audio_file_sha256`，再从真实 PCM 计算 hash 与回执
`pcm_sha256` 比对」，这一步未落地，也没有文档说明它被放弃。因此当前 `.verified`
的准确含义是"服务端对执行过程的描述自洽，且回执带了一个未经校验的音频摘要"，
而不是"端到端字节一致"。补这一步要先定执行边界与失败处置，见 #189。

**另一处未交付**：方案 §6.2 要求「App 持久化快照至少包含 recipe、plan 完整 digest、
request/receipt ID、receipt 终态、观测音色/model revision、PCM hash/边界、实际 WAV 文件
hash、provenance state/reason」。实测 `CreativeWork`、`RenderProvenanceSnapshot`、
`DubbingCandidate` 三处持久化结构里**没有 request ID、没有 receipt ID、没有回执终态**。
因此 `ServiceAPIClient.fetchReceipt(id:)` 与 `fetchReceipt(byRequestID:)` 这两个入口拿不到
可用 ID——方案 §2 那句「App 的 render/work ID 是本地用户操作身份，不能替代服务执行身份」
在数据层没有任何落点。终态只在**非**终态分支以 `reason=receipt_status_<wire>` 的形式出现，
`completed` 分支不落盘。

已落地的其余各项：recipe、`plan_sha256`、观测音色 revision（`voice_revision`）、观测 model
revision（配方 `model.artifact_revision` / `model.engine_revision`）、`pcm_sha256`、
`audio_file_sha256`（提交时由作品库对真实文件计算）、provenance state/reason。方案里的
「PCM …边界」一词未定义具体字段，无法判定是否已交付，此处不作结论。见 #196。

证明：`tests/test_render_recipe.py`、`tests/test_render_receipts.py`、
`tests/test_render_receipt_routes.py`、`tests/test_tts_sampling.py`、
`tests/test_qwen3_tts_worker.py`、Swift `ServiceContractTests` / `CreativeWorkStoreTests`。

App 侧「回执缺失不丢音频、不伪造身份」此前没有测试守着，本次补上三条并实测通过：

- `testMissingReceiptKeepsTheFullAudioAndNeverInventsAnIdentity`：回执 404 时音频完整保留，
  `provenance` 为 `.unavailable` / `receipt_unavailable`，`planID`、配方与摘要全为 nil；
- `testPendingReceiptKeepsTheAudioAndNamesTheUnfinishedState`：回执 pending 时音频保留，
  `provenance` 为 `.partial` / `receipt_status_pending`；
- `testCompletedReceiptWithAPartialRecipeKeepsTheAudioAndWithholdsTheDigest`：终态但配方
  partial 时保留已观察到的执行事实，摘要为 nil，并断言缺失字段。

审查中发现 `plan_id` 的组成字段与「配方在真实发音词典下如何记录」都没有测试守着：
把 `voice.mode`、`model.role`、`model.artifact`、`pronunciation_revision`、`channels`
逐个从 plan 载荷里删掉，全套测试仍然全绿；把路由里的 `raw_text` 换成
`acoustic_text`、把 `_optional_summary_str` 改成恒返回 `None`，同样全绿——
后者会让「用过发音替换」的渲染如实报成 `unused`，产出一个描述从未发生过的渲染的
完整配方与摘要。本次补上：

- `test_every_execution_parameter_changes_the_digest_and_the_plan` 扩到 plan 载荷的每一个字段，
  逐字段变异均会变红；
- `test_recipe_separates_the_caller_text_from_what_the_pronunciation_set_produced`：经真实
  `PronunciationRegistry` 建集并应用，断言 `raw_text_sha256` 是调用方原文、
  `acoustic_text_sha256` 是真正下发到合成器的文本、词典 id 与 revision 如实记录，
  且此时配方可以 `complete`；
- `test_a_render_without_a_pronunciation_set_says_so_explicitly`：`unused` 是观察到的事实，
  与「这一项缺失」不是同一句话；
- 回执路由测试补上 `plan_sha256` 与 `plan_id` 前缀的一致性断言——该字段此前只有
  Swift 夹具在用，服务端从未断言过。

这层强类型投影本身也曾整段零覆盖。五个变异在补测前全部全绿：

- `JSONValue.stringValue` 不再拒空串 → 配方里会出现 `""` 这样的「标识符」；
- `JSONValue.intValue` 对非整数不再拒绝 → `24000.5` 被截断成 `24000`；
- `ReceiptStatus.wireValue` 把未知状态塌成 `pending` → 排查时指向一个没发生过的状态；
- `missingFields` 解码时过滤空串 → 一份仍列着缺失项的配方被当成没有缺失；
- `RenderRecipeSnapshot.==` 少比 `pronunciationRevision` 或 `seedPolicy` → 换了词典、
  换了采样器的两次渲染被说成同一份配方。最后一条尤其难抓：往返测试用的就是这个
  `==`，而编码与解码对同一个字段永远一致，缺一项也照样通过。

因此相等关系改为**逐字段考**——每个事实各造一份只差这一项的配方，断言判为不同。

采样事实这条链上也有两处只测了一半：

- **「运行时没能播种」只有 `custom_voice` 一条路径有对照。** 把
  `_seed_clone_generation` 改成恒返回 `True`，全套测试仍然全绿——克隆渲染会如实报成
  `clone_reference_derived` 并附上一个具体 seed，而那个 seed 从未进入采样流。配方因此
  对一段不可重现的音频声称可重现。本次补上克隆路径与 voice-design profile seed 两条
  「没有 MLX 运行时」的对照，并断言 profile 的 temperature 仍如实上报。
- **worker 帧进入配方的那道缝此前没有任何测试。** `Qwen3TtsWorker._store_sampling_observation`
  与 `take_sampling_observation` 零覆盖：去掉 64 条上限、把 `pop` 换成 `get`、
  把校验失败改写成一条伪造观测，三者全绿。本次补上正常上报且只消费一次、
  六组不可校验的报告被丢弃但音频照常送达、以及保留条数有界。

### ③ 段落修改、采用/撤销与导出

项目持有完整配方；候选只有在配方摘要与段落文本都一致时才可采用。段落边界只来自文稿
（先按换行、再按句末标点、最后按字数），**不产生任何时间戳**，因此也不生成伪字幕。导出
音频只由被采用的候选按顺序拼接（重写 WAV header，不做 crossfade、不用静音补时长），
正文只包含这些段落；只要有一段没采用版本就拒绝导出。

审查中又发现这条链上有四处「文档写了、测试没考」：

- **重做的语速取自 `recipe.effectiveSpeed`，但从不断言。** 测试助手
  `dubbingRecipe` 把 `effectiveSpeed` 硬编码成 `1.0`，恰好等于实现里的兜底值
  `?? 1.0`——两边一起退化，把速度换成常量 `1.0` 全套测试仍然全绿。语速对不上时，
  候选摘要与项目摘要不再相等，采用会被判成「制作条件与当前项目不一致」：用户先看到
  「已生成新版本」，采用时却被拒。本次用 `1.25` 的配方补上断言，并顺带验证采用能成功。
- **`clip(fromWAV:)` 不校验 `fmt ` 的 format code。** μ-law / A-law 的
  `channels=1`、`bitsPerSample=16`，只有 format code 不是 1；放它过去，
  `makeWAV` 会把压缩字节原样写进一个自称 16 bit PCM 的容器——正是注释里
  「听起来不对却能播放的成品」。本次补上 format code=7 必须被拒。
- **`fmt ` 里的位深此前被当作常量 16。** 测试用的 WAV 助手把 format code 写死为 1、
  且只造 16 bit 的文件，所以「照实读出位深」这条路径没有被考过：把它改成硬编码 `16`
  全套测试仍然全绿。24 bit 的段落会被当成 16 bit，字节数与采样率都不变，拼出来的成品
  能播放，只是速度与音色全错。本次补上 24 bit 的读取与拒绝。
- **`adoptedScript` 与 `undoAdoption()` 的公开契约各缺一条断言。** 前者必须只投影
  已采用段落的正文；后者在历史为空时必须**什么都不做**——清空采用项会让那一段
  静默从成品里消失，用户不报错，只是导出的正文短了一段。

header 的采样率、位深、声道**来自候选 WAV 自己的 `fmt ` 声明**，不是导出层的常量：
拼接前解析各段格式，格式不一致或不是单声道 16 bit 正采样率就显式失败并给出可执行文案，
不做隐式转换。猜错采样率不会报错，只会让成品语速与音高整体错位，属于最难察觉的一类失败。

App 的「段落返修…」入口在作品详情动作区；重做、采用、撤销、导出在弹层首屏，候选版本收在
每段的展开区；导出经 `NSOpenPanel` 选目录后写出 WAV + TXT 两份文件。

入口按事实出现：没有配方摘要的作品（老记录读作 `legacyUnknown`）不显示「段落返修…」，
因为那件作品的重做必然被拒——摆出一个点下去一定失败的动作，比不摆更糟。判据是
`RenderProvenanceSnapshot.supportsSegmentRedo`，落在模型上因而可测；
`startDubbingSegmentRedo` 里的摘要守卫保留为纵深防御。

拒绝时给出的理由必须指向真正的责任方：「列表没读到」与「这件作品用的音色不在列表里」
是两件事。前者是我们还不知道，音色可能完全正常；说成后者会让用户去「音色库」修一个
根本没坏的音色。「音色在列表里但当前不可用」是第三种情况，单独一句话。

恢复路径读 journal 时也必须把 journal 当作**不可信输入**。写入侧
`publishedAudioFileName` 恒等于 `"<已校验 candidateID>.wav"`，但恢复随后要拿它拼出
路径并**删除该文件**，不能假设它是自己写的。此前只校验了 `schemaVersion` 与
`transactionID`，文件名原样使用；`isSymbolicLink` 挡不住 `../`——那不是符号链接，
就是一个普通文件。结果是篡改过的 journal 能让下次启动删掉项目目录之外的文件。
姊妹存储 `CreativeWorkStore` 的同名 journal 有 `audioFileName == "\(workID).wav"`
 这条绑定，配音项目这边原先没有。

文案提到的成因必须与用户实际能修的方向一致。`invalidIdentifier` 表达的是**数据
不自洽**（重试无用，要重新生成这一段），此前却被说成「检查磁盘权限和可用空间」；
而真正的磁盘满与没权限不走 `DubbingProjectError`——`DubbingProjectStore` 不包装
底层 I/O，`CocoaError` 原样冒出来——落到笼统的「段落操作失败，请重试」。两边正好
错位：文案承诺的排查方向，恰恰是唯一拿不到那条文案的场景。

弹层副标题里那半句也遵守同一条区分。此前它是 `dubbingProjectVoiceName ?? "原音色"`，
而 nil 有四种来源（配方没记录 / 列表没读到 / 音色不在列表里 / 列表读到了但查不到）。
一律说成「原音色」是一句没有依据的断言；其中「音色不在列表里」尤其糟：副标题刚承诺
一个音色，紧接着第一次返修就被 `startDubbingSegmentRedo` 拒绝，用户看到自相矛盾。
现由 `DubbingProjectVoice.resolve` 给出四种互不相同的说法。

成品文件名还必须**看得见**：作品名来自文稿首行，用户写什么都会进来，而以点开头的名字
在 macOS 上是隐藏文件——导出提示「已导出 …」，用户回到自己选的目录却什么也没看到。
因此导出名去掉前导点，全是非法字符或全是点时退回默认名，超长收敛到 80 字。

导出是**两份文件**，写入失败必须说清是第几步失败的。音频落地、正文失败（路径被同名目录
占住、或写第二份时磁盘满）之后，目标目录里躺着的是一份**没有对应文案的成品**；此时若沿用
「请确认目标位置可写」，用户会去检查一个其实可写的目录。因此第二步失败单独给出「已写入
音频、正文没能写入」，并保留待导出内容，让用户换个位置就能重试，不必从头重做。

证明：`DubbingProjectStoreTests`（27）、`DubbingSegmentPlannerTests`（4）、
`AppModelTests` 中的 13 条段落返修用例；`scripts/macos_app_build.sh --configuration Debug` 构建通过。

### ④ 提词器场景

停顿、重读、脱稿、回稿、掉线、手动接管六个场景在**一次运行**里串跑，验证状态不互相污染：
证据不足时不前进、脱稿不推进、读到下一段才推进、重读不甩到后面、掉线释放占用并保留用户
位置、接管后迟到事件不再移动位置、关闭后连接与采集各只释放一次。

证明：`TeleprompterSessionLifecycleTests.oneReadingRunKeepsPositionHonestAcrossEveryScenario`；
各场景的单点回归见 `TeleprompterFollowControllerTests`（44）与
`TeleprompterReplayEvaluatorTests`（32）。

「不得移动位置」这类否定断言前，都会先等
`session.followLatencyDiagnostics.alignmentSampleCount` 涨到对应值——会话每消费一条
completed 转写恰好记录一个对齐样本，因此这个计数是**事件确实已被处理**的确定性证据。
早期版本用固定 120ms 睡眠守卫否定断言，事件尚未处理时也会通过，等于给这一项上了假保险。
同文件的 `waitFor` 助手原先在超时后什么都不做，已改为超时即记录失败。

**未验证**：真实口播录音、蓝牙/USB 拔插重连、长时间运行。这些需要设备与真实模型授权。

### ⑤ 首次结果、升级恢复与跨接口一致

`FirstResultReadiness` 是一份只读投影：每一步只有在有**正面证据**时才算满足，
`/readyz=200` 不构成任何一步的完成；"还没读到"与"已确认缺失"分开呈现。它不安装、不下载、
不改配置，缺口直接给出"去处理"的目标页。

跨接口一致由共享拒绝表证明：REST 与 MCP 打同一个 app 实例，7 组样例（空文稿、空音色、
未知音色、越界语速、未知输出格式、未知校验策略、过期音色 revision）必须在同一事实上被拒绝，
且都不得触达合成器；合法请求则两个入口都渲染。App 侧在发出请求之前拒绝同一批无效渲染，
不留下任何"待保存"残留。

四个步骤各自区分「已确认的缺口」与「还没有结论」：服务探针读到失败、模型状态明确、
音色列表读失败都是前者；服务状态未读到、模型状态 `.unknown`、音色列表已读到但能力快照
未确认是后者。前者进入 `blockingSteps` 并配一个可执行的下一步，后者进入 `unknownSteps`。
把后者算成前者会催用户去修一个他还没有资格判断的东西——这条区分此前只有服务与模型两步
被断言，音色那一步的未知分支没有用例；补上后逐条变异均会变红。

音色列表的 `unknown` 与 `loading` 也属于后者：App 一启动就是这个值，此前它们落进
`default` 分支，被说成「还没有可用于配音的音色，先在『音色库』里准备一个」——
用户可能明明有音色，却被推去重新做一个。

这张卡只在**有确定缺口**时出现（`hasActionableSteps`）。全是未知的时候它只剩一个标题、
一条分隔线和零行内容，而文案还在说「先处理下面确定缺的东西」。这条判据落在
`FirstResultReadiness` 上而不是视图条件里，因此可被测试直接考到。

同一条区分也适用于**配音台的音色选择器**。它此前直接问 `availableVoices.isEmpty`，
把「还没读到」「读取失败」「确实没有可用音色」三种状态拿到同一句话
「服务当前没有返回可用于配音的音色」，并把用户送去「音色创作」——而读取失败时他
很可能本来就有音色，创建一个新的解决不了一次失败。`refreshCreatorVoices()` 的 catch
分支会清空列表并置 `.failed`，所以这是真实状态而非理论情形。

判定因此下沉为 `CreatorVoicePickerState.resolve(loadState:voices:)`：`loadState` 的四个
取值全部列举、没有 `default`（漏掉一个会被安静地当成"没有音色"，也就是这个缺陷本身），
「没读到」给的动作是**重新加载**，只有「确实没有」才指向音色创作。音色库页面此前已经
这样区分了，配音台选择器是同族里最后一处漏网。

**未验证**：升级失败的端到端恢复需要真实安装/回滚授权（见 `.agents/skills/speechrail-release`）。
本次只交付 App 侧"服务不可达时如实说明缺口"的行为。

### ⑥ 定向测试、契约、构建与文档

见第 3 节的命令与结果。`docs/users/api-contract.md` 已补齐采样事实的语义（含
`unseeded_sampler` 也可以是 complete）。

**未交付：这些新字段没有语义门禁。** 方案 §5 C2 的范围包含 `api-contract.md` 与
`check_user_doc_contract.py`，第 5 条要求「读取 parser 能校验的契约字段，并用坏文档
fixture 证明它会失败」。实际只扩展了 `check_current_boundaries_contract.py`：

```
grep -cE "recipe|seed_policy|pcm_sha256|provenance" \
  scripts/check_openapi_contract.py scripts/check_user_doc_contract.py
→ 0 / 0
```

两个门禁分别只校验路径/方法/状态码/security 与路径/错误码/模型别名，**都不读 schema
属性**。因此本次新增的 `recipe`（`required` 四个键、`schema_version` const、
`state` enum、`digest` pattern）与文档里的 4 个 `seed_policy` 取值**没有任何自动检查**。

当前**没有实际漂移**——第 ② 节已逐条核实契约与文档的断言与代码一致。缺的是门禁：
将来一次改动即可让文档与代码静默矛盾而没有测试变红。见 #192。

## 3. 本次验证结果（2026-10-03，Swift 侧末次复核 2026-10-04）

```text
swift test --package-path macos/SpeechRailApp --skip-update
  → 541 XCTest + 384 swift-testing，0 失败

scripts/macos_app_build.sh --test-unit
  → 514 XCTest + 384 swift-testing，0 失败（TEST SUCCEEDED）

scripts/macos_app_build.sh --configuration Debug
  → BUILD SUCCEEDED

uv run --no-sync --extra dev pytest \
  tests/test_current_boundaries_contract.py tests/test_interface_parity.py \
  tests/test_qwen3_tts_worker.py tests/test_render_receipt_routes.py \
  tests/test_render_receipts.py tests/test_render_recipe.py \
  tests/test_tts_sampling.py tests/test_pronunciation_routes.py \
  -q --no-cov
  → 128 passed

uv run --no-sync --extra dev ruff check src/speechrail tests
  → All checks passed!

uv run --no-sync python scripts/check_openapi_contract.py       → OK
uv run --no-sync python scripts/check_user_doc_contract.py       → OK
uv run --no-sync python scripts/check_version_consistency.py     → OK
uv run --no-sync python scripts/check_current_boundaries_contract.py → OK
uv run --no-sync mypy src/speechrail                               → Success, 158 files
```

`mypy` 2.3.1 已离线安装并通过（158 个文件无问题）。工程文件方面，本 PR 新增的
`DubbingProjectStore.swift` / `FirstResultReadiness.swift` / `DubbingProjectStoreTests.swift`
都同时进了 `App Sources` 与 `Unit Test Sources`，不再出现 `Skipping duplicate build file` 警告
（`MeetingView.swift` 在 `App Sources` 里仍有一条重复条目，但它在 `origin/main` 上就已存在，
且当前 Xcode 实跑不产生该警告，本次不动）。

补充（超出定向范围，仅作旁证）：`pytest tests/ --no-cov` 全量 → 3152 passed, 1 skipped
（运行 exit=0）。

以上命令在 2026-10-03 **全部重跑复核**，数字与首次记录一致，无回归。
2026-10-04 改动集中在 `ServiceAPIClient.provenance(for:)`、`FirstResultReadiness` 相关用例与
采样/配方测试，上列 Swift、pytest、ruff 与四个契约脚本、mypy 命令已全部重跑并按上表更新。
`scripts/macos_app_build.sh` 的两条入口当日已重跑，结果见上表。

2026-10-04 第 27 轮（#204，段落重做的 generation 守卫）再次全量重跑：Swift 侧
535 / 508 XCTest + 379 swift-testing、pytest 3152 passed、`ruff`、`mypy` 均通过。
本轮只改测试与本文档，`AppModel.swift` 与 `origin/main` 逐字节一致；本轮同时补测并关闭了
#197、#198（校验代码此前已在 `render_receipts.py` 落地，遗留的是两个 issue 未关）。

2026-10-04 第 28 轮（#205，`CreativeWorkStore` 按 ID 定位作品）再次全量重跑：Swift 侧
537 / 510 XCTest + 379 swift-testing、`macos_app_build.sh --configuration Debug`
BUILD SUCCEEDED。Python 侧本轮无改动，沿用第 27 轮实测的 3152 passed。
本轮只改测试与本文档，`CreativeWorkStore.swift` 与 `origin/main` 逐字节一致。

2026-10-04 第 29 轮（#206，`DubbingProjectStore` 按 ID 定位项目）再次全量重跑：Swift 侧
539 / 512 XCTest + 379 swift-testing、`macos_app_build.sh --configuration Debug`
BUILD SUCCEEDED，`DubbingProjectStoreTests` 逐套件对账 SPM 27 / Xcode 27 一致。
Python 侧本轮无改动，沿用第 27 轮实测的 3152 passed。
本轮只改测试与本文档，`DubbingProjectStore.swift` 与 `origin/main` 逐字节一致。

2026-10-04 第 30 轮（#207，提词器五处「按 ID 定位」查找）再次全量重跑：
539 / 512 XCTest + **384** swift-testing、`macos_app_build.sh --configuration Debug`
BUILD SUCCEEDED。新增五条都是 swift-testing，故 XCTest 计数不变，swift-testing 379 → 384。
Python 侧本轮无改动，沿用第 27 轮实测的 3152 passed。
本轮只改测试与本文档，`TeleprompterSession.swift` / `TeleprompterV2Store.swift`
与 `origin/main` 逐字节一致。五处中四处确认是缺陷并补了用例；第五处
（`validateImmutableSourceRevisions` 的按 id 查找）经验证与「永远取第 0 条」
**语义等价**——`validate` 要求单元的 `sourceRevisionID` 等于所属修订 id，
不同 id 的修订其 `sourceUnits` 必然不等，两种实现结局一致，故不作为缺陷记录。

2026-10-04 第 31 轮（#208，`CreatorServiceClient` 两个 fail-closed 默认值）再次全量重跑：
541 / 514 XCTest + 384 swift-testing、Debug BUILD SUCCEEDED，
`StreamingTtsCapabilitiesTests` 逐套件对账 SPM 6 / Xcode 6 一致。
Python 侧本轮无改动，沿用第 27 轮实测的 3152 passed。
本轮只改测试与本文档，`CreatorServiceClient.swift` 与 `origin/main` 逐字节一致。

### 3.0 两条 macOS 测试门禁的覆盖差异（2026-10-04 实测）

macOS 侧有两个入口：`swift test`（SPM，**CI 只跑这一条**）与
`scripts/macos_app_build.sh --test-unit`（`xcodebuild test`，仅本机复跑）。
`ci.yml` 因 `xcodebuild test` 在 CI 上会复现 lost-wakeup 挂死而跳过它，理由是
「SwiftPM 已经跑过同一个测试目录」。就覆盖面而言这个理由成立——`swift test` 是超集，
CI 不漏跑任何用例——但「同一个目录」这个前提并不成立：两者编译的源文件集合不同，
**跑到的用例数也就不同**。2026-10-04 逐套件对账后的实测差额：

| 套件 | `swift test` | `--test-unit` | 差额原因 |
| --- | --- | --- | --- |
| `ServiceContractTests` | 57 | 57 | 已对齐 |
| `CreativeWorkStoreTests` | 39 | 39 | 已对齐 |
| `RealtimeContractTests` | 41 | 41 | 已对齐 |
| `ModelNamePresentationTests` | 9 | 0 | 整文件不在 Xcode `Unit Test Sources` |
| `ModelReadinessPresentationTests` | 11 | 0 | 同上 |
| `WindowLayoutPolicyTests` | 7 | 0 | 同上 |
| `DubbingProjectStoreTests` | 27 | 27 | 已对齐 |
| **XCTest 合计** | **541** | **514** | |
| swift-testing 合计 | 384 | 384 | 一致 |

本 PR 新增的 12 条 `ServiceContractTests` 中有 3 条（回执缺失 / 回执未终态 / 回执配方残缺）
原先被 `#if SWIFT_PACKAGE` 挡在 `xcodebuild test` 之外，现已解除，回归由两条门禁共同覆盖。
残留的 27 条属于既有结构：`ModelNamePresentation` / `ModelReadinessPresenter` 定义在
`ModelManagementView.swift`，该文件被 SPM 显式 `exclude`，动它需要拆分符号，超出本 PR 范围。
见 #194。

### 3.1 一处刻意留下的边界：App 不判断「升级是否失败过」

App 目前能读到服务事实只有 `service_instance_epoch` 与 `catalog_revision`；
按契约，**服务不暴露自己的 release 版本**，因此 App 无法区分「升级失败并回退到上一
 runtime」与「正常重启」。用 epoch 变化去推断就属于伪造未知身份，因此没有这样实现。

方案 F 的完成条件是「失败保留旧 runtime/selection，恢复后完成首条真实结果；产品不以
readyz 200 结束」，由 `FirstResultReadiness` 达成。若要让 App **显式提示**「刚才的升级失败并
已回退」，需要在能力快照里新增一个服务自报版本字段并同步契约、测试与文档——这属于公共接口
变更，需要单独授权后再做。

## 4. 数据格式、迁移与回退

- `works.json` 数组格式未变；旧记录缺 `provenance` 时读作 `legacyUnknown`，不补写磁盘。
- `projects.json`（配音项目）是**新文件**，删掉它只影响段落返修，不影响作品库。
- `recipe` 为新增可选字段。写入后不要把运行中的旧 App 当作安全回退：旧 App 读得懂未知字段，
  但在改名重写索引时可能丢掉它们。需要回退时先备份 `~/Library/Application Support/SpeechRail/`。
- 删除作品的音频进入 `.recovery/`，不自动清理；需要时由用户显式处理。

**未交付：索引的"未来 schema"守卫。** 方案 §5 B3 第 7 条要求「未知未来 snapshot schema
保留原索引，不覆盖降级保存」。实现里**索引层没有版本概念**——`CreativeWork` 没有版本
字段，只有 journal 有 `schemaVersion` 守卫——因此程序**无法检测**未来版本。索引走
「有类型解码 → 重新编码」，Swift `Codable` 按构造丢弃未知键。实测：注入一个当前版本
不认识的字段，一次改名后即消失（`contains_future_field=false`），无任何提示。

上面那条"不要把旧 App 当作安全回退"是**人的纪律**；这里是**程序行为**，二者不是一回事。
自动守卫涉及版本字段的位置与失败模式，需单独决策，见 #191。

**未交付：`pcm_sha256` 的字节比对。** 方案 §5 B3 同样要求「保存 `audio_file_sha256`，
再从真实 PCM 计算 hash 与回执 `pcm_sha256` 比对」。该步未落地且此前未披露；现全仓只有
搬运没有比较。当前 `.verified` 的准确含义见第 ② 节，见 #189。

## 5. 未验证与风险

1. 真实模型音质、真实音色一致性、长时间运行稳定性：全部未验证。
2. 设备掉线/重连与真实口播的听审：未验证（确定性回归只覆盖状态机）。
3. 安装、升级、回滚与发布：未执行，需专项授权。
4. UI 自动化与截图核对：未执行（需逐次授权）。本轮三处视图层修复——结果位与失败
   并排呈现、音色选择器空态、段落返修副标题——都只有模型层证据：判定已下沉为可测
   投影并被变异测试考到，**实际渲染效果未经核对**。
5. 段落拼接的响度与韵律是否自然，只能靠听审；本轮只保证"导出的音频就是被采用的样本，
   按顺序拼接"。
6. `seed_policy=unseeded_sampler` 的渲染不可逐位重现；不得据此承诺复用或缓存。

## 6. 并行改动与提交状态

全部改动位于分支 `codex/roi-evolution`，以 PR 形式提交（基线 `be75055`）；未合并、未发布、
未改动任何运行态。主分支工作区在实现期间未被触碰。
