# SpeechRail AI 提词器：阶段实施报告

> 对应方案：`SpeechRail_AI_Teleprompter_Implementation_Plan_2026-09-28.md` v1.5  
> 报告日期：2026-09-28（Asia/Shanghai）；复审与收尾续至 2026-09-29  
> 实施分支：`codex/teleprompter-implementation`（worktree `.worktrees/teleprompter-implementation`）  
> 基线：`7468efb8c8282b119650fcb8e987a0d74f141e6a`；改动已提交到 `codex/teleprompter-implementation`，未推送、未发布  
> 状态：**部分交付**。安全、正确性与体验工作包均有确定性证据（69 项场景：通过 65、部分 3、未执行 1）；真实音频、真人表达与 UI 视觉验收未执行。**功能侧原以为已无已知缺口**：#110 读法别名与 #111／#112 语音辅助试读已于第十至十二轮补齐。但 2026-09-29 继续审查时，在**已关闭 issue 的交付范围内又找出 16 个真缺陷**（§2 第 41–56 条、§4.3），均为「先改状态后可能失败而失败不回滚」与「多个原因压成一个返回值或文案」。已全部修复并配回归与变异验证。第二十轮做了完成度审计（逐条核实 §2.4 证据是否支撑其结论），**未发现新缺陷**，新增两处经核实的排除（§2.7）。第二十七／二十八轮把这一族先后扩到 Python 跟随路径（§2.12）与 Swift 视图层与 sheet（§2.13），**两侧结论都是「已逐条读过的范围内未发现新缺陷」，且都写明了覆盖边界**；视图层那侧的函数归属仍是启发式，**零命中不足以证明干净**。**同类形态是否还有第五处，本轮仍没有证据能保证没有**。

## 1. 本轮实际完成的工作包

| Issue | 工作包 | 结果 | 主要改动 |
|---|---|---|---|
| #108 | 探针计时、终态与有界性 | 完成 | `tools/probe_teleprompter_latency.py`、schema 3、11 项回归 |
| #104 | 出现级保真门禁 | 完成 | `TeleprompterProtectedAtom`、完整 canonical 序列比对、rewrite/map/reduce 共用门禁 |
| #105 | partial/final 统一推进权限 | 完成 | 本地推进半径与 reanchor 门槛，partial 与 final 走同一 `mayAdvance` |
| #106 | hypothesis 证据透传 | 完成 | 内部 `RealtimeHypothesisEvidence`，wire 协议未新增事件 |
| #107 | 三位置分离 | 完成 | `committedPosition` / `hypothesisPosition` / `viewportAnchor` |
| #109 | 语义风险审阅 | 完成 | 主体—数值、条件、否定、比较、确定程度五类风险进入生产审阅 |
| #110 | 同版本句内进度、读法别名与安全恢复 | 完成 | `currentSegmentOffset`、纯函数恢复器、锁定文本偏移丢弃；**读法别名通道**：`TeleprompterAcceptedReading` 绑定段内一处 UTF-16 范围，稿件／导出／逐字记录一字不改，只改对齐时匹配什么（§2 第 37 条）；就绪页「读法标注」入口（§2 第 34、35 条） |
| #111 | 独立有损精简 | **实现完成，界面未走查** | `condense` 操作、锁定项、删除转 `skip` 与 `contentRemoved` 审阅、语速校准来源与未校准标注；有损确认入口、删减原文展示、**精简前的必讲段落标记**均已交付（§2 第 20、21 条）。方案 §5.7 的四步流程至此完整，**但全部界面只通过编译，未做视觉走查** |
| #112 | language／keywords 接线与语音辅助试读 | **实现完成，界面未走查** | Realtime `transcription.keywords` 真正下发；`transcription.language` 本轮补上生产写入者——语音跟随控制旁的识别语言菜单，持久化并在恢复时按契约清洗（§2 第 22 条）；**语音辅助试读**补上（此前只有手动秒表）：`startSpeechTrial()`／`stopSpeechTrial()` 走既有 coordinator 与 client 构造，证据分开记识别与定位、无识别不产出倍率（§2 第 36 条） |
| #113 | 场景预设、列宽与快捷恢复 | 完成（视觉走查未执行） | `TeleprompterStagePreset`、正文列宽与窗口宽度分离、`TeleprompterStageLayoutPolicy`、“回到朗读位置” |
| #114 | 确定性回放与阶段证据 | 部分完成 | 回放评估器与 runner 已交付；**素材采集与标注工具已补上**（`tools/build_teleprompter_replay_manifest.py`，§2.11）；真实时延基线未执行 |

## 2. 实施中发现并修复的既有缺陷

1. **保真门禁两侧口径不一致（#104 引入）**：来源侧按 source unit 逐个提取受保护值，候选侧在整段文本上提取。数字与单位跨 unit 边界时（如 `50` 与 `元` 分属两个 unit），两侧序列不一致，合法改写被整体拒绝，该窗口静默退化为本地回退。修复为两侧都在整段原文上提取。
2. **跟随权威索引错位（既有）**：恢复阅读位置时按“记录进度时的版本”取索引，却把索引应用到活动版本 `currentSegment`。当前流程在接受新版本时会清空进度，因此这是潜在缺陷而非已观测故障。已改为按活动版本解析，跨版本仅在段文本完全一致时迁移偏移。
3. **改稿后旧候选残留（P-17 回归发现）**：`updateSourceText` 清掉了 `pendingVersion`，却保留了上一轮 AI 候选的 `readingBlocks` 与 `reviewItems`；同文件的 `updateContentSelection` 本来就同时清空两者。结果是旧文本上的风险条目会挂到用户新写的句子上。现在编辑正文与编辑选区行为一致。
4. **设备异常被归因为识别服务（R-04 评估发现）**：麦克风 `engineFailed`／`converterUnavailable` 一律映射为 `serviceNotReady`，界面只说“语音识别服务未就绪”，设备已拔出的事实被吞掉。新增 `BlockReason.inputDeviceUnavailable`：标题说明是麦克风，详情保留原始错误信息并继续提供手动看稿，工作台横幅按“重试语音跟随”处理。
5. **回放报告把“运行到确认的绝对时刻”当成跟随延迟（#114 自查发现）**：`latencies.append(event.atMilliseconds)` 记录的是事件在整段录音中的绝对时间，录音越长、位置越靠后，分位就越大，与 §11.6 定义的“片段结束到正确确认”的延迟无关。现在按每个段落开始被朗读的时刻起算，重复朗读同一段会开启新的窗口。
6. **错误停顿在进入阅读的瞬间就被计数（#114 自查发现）**：没有等待中时限时 `event.atMilliseconds >= (reanchorDeadline ?? 0)` 恒为真，任何一次未确认的 `.read` 标签都会立刻记一次停顿，3 秒阈值形同虚设。现在从该段开始被朗读起算，满阈值后才记一次，之后每个阈值窗口再记一次。
7. **报告缺少失败分母与恢复延迟（#114 对照 §11.6 补齐）**：报告此前只有跟随 P95，没有 P50、没有回稿恢复延迟、没有失败占比，也无法提示“分位只覆盖成功子集”。现在输出 `tracking_latency_p50_ms`／`tracking_latency_p95_ms`、`reanchor_latency_p50_ms`／`reanchor_latency_p95_ms`、`failed_sample_count`、`failure_share`、`failure_share_exceeds_threshold` 和 `unlabelled_event_count`，并在失败占比超过 5%、存在恢复超时、无标注事件、停顿或严重误推进时输出 `caveats` 文字说明。
8. **新测试文件被登记进 App 源码组（Xcode 构建发现）**：`TeleprompterReplayEvaluatorTests.swift` 的 `PBXFileReference` 挂在 `SpeechRailApp` 组下，路径相对解析成不存在的 `macos/SpeechRailApp/SpeechRailApp/TeleprompterReplayEvaluatorTests.swift`，Xcode 单元测试 target 直接构建失败（`Build input file cannot be found`）。SwiftPM 按目录通配编译，所以此前 `swift test` 看不出来。已把该引用移入 `SpeechRailMacControlTests` 组，与其余测试文件一致。**这说明只跑 SwiftPM 不能证明 Xcode 工程注册正确。**
9. **测试闸门不记开启状态，导致整套测试在 Xcode 侧挂死（本轮自查修正了此前第 5 条的归因）**：首轮记录为「App 测试宿主跑完不退出」，并推测需要在 `App.swift` 加终止钩子。该归因不成立：单测 target 是 `bundle.unit-test` 且**没有 `TEST_HOST`／`BUNDLE_LOADER`**，UI 测试又被包装脚本 `-skip-testing:SpeechRailAppUITests` 排除，测试自始至终运行在 `xctest` 进程里，App 从未启动。逐层二分定位到 `TeleprompterSessionLifecycleTests` 的 `explicit voice start uses the current segment and old failures cannot move it`：该用例先 `await drainGate.open()` 放行停止流程，之后才等到 `drainAndClear` 调 `TestGate.wait()`；而 `TestGate` 当时并不记得自己已开启，`open()` 在没有等待者时把信号整段丢弃，随后到达的 `wait()` 永久挂起，于是 `xcodebuild` 再也等不到进程退出。**它只在负载改变时才发作**：单跑该套件通过，全量并行时序翻转后挂死，这也是它此前被误判为宿主问题的原因。修复只动测试辅助件——`TestGate` 增加一次性开启语义（`open()` 之后 `wait()` 立即返回，`waitUntilWaiting()` 同样尊重已开启），生产代码未改：生产路径的 `TeleprompterSession.stopCapture()` 直接 `await client.drainAndClear(...)`，没有等价竞态。新增具名回归 `a gate that was opened before the wait arrived still releases the wait` 锁住该顺序。
10. **时长估计不区分「默认倍率」与「实测倍率」（按 Issue 正文复核发现）**：此前只核对了 Issue 的标题与状态，没有逐条对照正文。#111 步骤 5 要求「复用已有 trial/calibrationFactor……未经有效试读使用默认估计并标明不确定性」，验收要求「手动计时、语音辅助试读的证据来源清晰」——这两条没有实现：`calibrationFactor` 默认 `1.0`，与某次试读恰好测得 `1.00x` 在数据上完全相同，`estimateDuration` 也只按文本原因（数字、网址、非中英文）标注不确定，从未试读的会话因此拿到一个与实测估计**同样确定**的点估计加 0.8–1.25 区间；界面还因为 `calibrationFactor != 1.0` 才显示校准入口，未试读的用户既看不到自己没校准，也没有可点的入口去校准。修复：新增 `TeleprompterCalibrationSource`（`.uncalibrated` / `.manualTrial(durationSeconds:)`），`EstimateResult` 增 `isCalibrated`，`estimateDuration`／`evaluatePreflight` 显式接收来源（默认 `.uncalibrated`，即调用方不举证就按未校准处理）；试读采用时写入 `.manualTrial`，「恢复默认语速」写回 `.uncalibrated`；内容选择页的预计用时在未校准时标注「（未试读校准）」，校准入口改为常驻并显示「未试读校准」。校准倍率本就不落盘（session 级 `@State`），因此不涉及存储迁移。语音辅助试读当时**不存在**（试读 sheet 只有手动秒表），没有为对齐措辞而虚构一条路径——**第十一轮已把这条路径真正补上**，见 §2 第 36 条与 §5 第 7 条。此处保留原文以记录当时的判断。
    - **同轮自查发现第一版只修了一半**：来源虽然接进了 `evaluatePreflight`，但 `PreflightConclusion` 不携带 `isCalibrated`，标记在返回时就被丢弃。结果是工作台最显眼的预检结论（时长 vs 目标）仍把未校准估计当确定值展示，只有内容选择页被修好。补齐：新增 `PreflightConclusion.showsDurationEstimate` 区分「带分钟数的结论」与「无内容／目标无效／无法预估」，只有前者需要标注；`TeleprompterSession.isPaceCalibrated` 供界面判断，未校准时预检文案追加「（未试读校准）」。新增具名回归 `onlyDurationBearingConclusionsAskForACalibrationNote`，并给既有的 `resetting to the default pace is not a measurement` 补上 `isPaceCalibrated` 断言。

11. **回放素材的 intent 契约与工具帮助文本不一致（端到端跑 CLI 发现）**：`teleprompter-replay --help` 写着 `read / improvise / re_read / manual_jump`，解码器只接受 `read / improvise / reRead / manualJump`；照帮助文本写素材必然失败，失败信息还是 Foundation 的通用句子，不说是哪个字段、也不说合法取值。之所以一直没暴露：所有测试都用 Swift 构造 `Intent`（`.manualJump`），没有任何测试让这些字符串经过 JSON 解码——素材是仓库外由人写的，字符串拼写是真正的对外契约，测试却只覆盖了类型内部那一侧。修复：`Intent` 显式钉住 raw value 并新增 `manifestValues`，帮助文本与错误信息从同一列表读；解码失败渲染 coding path 并对 intent 附上可接受取值；补两条回归（JSON 往返钉住拼写、断言 snake_case 被拒）。同时把实测出来的两条素材书写要点写进 `--help`：`expected_segment_index` 标的是**读者已读到的段落**而非系统确认到的段落，挂到系统已追上的事件会让延迟恒为 0 且不报错；第 0 段是回放起点，系统一开始就在 0，因此不产生延迟样本。

12. **提取器看不见的数字让保真门禁从 fail-closed 退化为 fail-open（第三轮对抗探测发现）**：`TeleprompterProtectedContentValidator` 比较的是受保护原子的**序列**（`expected == actual`）。提取器看不见的数字在源与候选两侧都不产生原子，精确序列比较因此得出「没有变化」——数值被改写反而通过了这道本该拦住它的门禁。用临时探针实测确认的静默放行：`1080p` → `4K`、`4K` → `8K`、`1e10` → `2e10`、`0x1F` → `0x2F`，以及 `29.97fps` 只抽出 `29` 而丢掉小数部分。根因是数字模式末尾的 `(?![A-Za-z0-9])` 拒绝任何紧跟 ASCII 字母的数字，而标识符模式要求字母开头，两侧都不匹配。**对本产品尤其要紧**：方案与测试素材本身就是相机设置场景，`1080p` 改 `4K` 在真实稿件上完全可达。修复为数字模式补上进制前缀、指数部分与紧邻 ASCII 单位后缀；首部 lookbehind 保留，`A1`／`GPT4`／`ISO8601`／`x1` 仍不产生数值原子。通用教训：**「比较两侧序列相等」的校验器在任一侧提取为空时必须区分「没有需要保护的东西」与「我没看见」**，前者才是安全的默认。
    - **同轮修复过程中自己引入过一次 fail-open**：单位后缀组漏了 `?` 变成强制匹配，导致所有后面不跟字母的数字（`50 公里`、`第3名`、`-5 度`）都抽不出原子，连「`-5 度` → `5 度`」这种负号丢失都放行。是同一批探针立刻发现的，而当时全量回归是绿的——**P0 门禁的正则改动不能只看测试是否通过，必须用独立探针轰击提取器**。
    - **有意留下的边界**：中文数字不在受保护集合内，`五十` → `五十一` 目前不受硬门禁保护（反向 `五十` → `50` 会被拒绝，因为候选侧多出一个阿拉伯原子）。没有直接把中文数字加进正则：日常中文满是一／两／三（`第一次` → `首次` 是无损改写），朴素比较会大面积误拦。要补必须带可测的误报率，不能靠加字符。已固化为具名回归 `chineseNumeralsRemainOutsideTheHardGateByDesign`，避免这个缺口被静默遗忘。

13. **回放报告无法区分「测得为零」与「检测项从未被触发」（第三轮对抗探测发现）**：报告里每个安全数字都由人工标注推导——`harmful_jump_count` 只在 `improvise` 标注下递增，跟随与恢复延迟只在 `read` 标注带 `expected_segment_index` 时才有样本。于是一份不含任何 `improvise` 标注的素材会输出 `harmful_jump_count: 0` 与 `status: deterministic_replay`，读起来像一次干净验收，实际上误推进检测从未被触发。这正是验收标准第 4 条红线「不以全部停住换取安全」在**测量仪器**层面的缺口：仪器本身不会说「这一项没问」。修复只加 caveat，不改 `teleprompter.eval.v1` schema：缺少 `improvise` 标注时写明「0 表示该检测项未被触发，不表示跟随不会越权推进」；缺少带 `expected_segment_index` 的 `read` 标注时写明「分位为 null 只说明未测量，不表示延迟为零」。
    - **本轮先被这个现象误导过一次，值得原样留下**：把一份「读者确实在朗读」的素材标成 `improvise` 后，报告如实报出 1 次严重误推进。追踪控制器才发现行为是**正确的**——从锚点开始、逐字连续的 final 按方案 §8.9「continuous advance → advance committedPosition to evidence-supported end」本就该跟到文末。#105 的具名回归针对的是**位于脚本别处**的远距短语（`distantUniquePhraseCannotAdvanceThroughPartialOrFinal` 用的是第 100 个单位处的「稳定性」），那一条行为正确。两次教训合起来：**用回放指标下结论前必须先确认标注语义与素材一致**；指标可信度上限由标注决定，仪器必须自己说明这一点。

14. **「写入失败不丢数据」此前没有任何回归覆盖（第三轮审查验收标准 3 时发现）**：#110 的验收写的是「旧稿／损坏文件／写入失败不丢数据」，但已有回归 `sourceRevisionIsImmutableAndInvalidSaveLeavesPreviousBytesUntouched` 只覆盖**写入之前**的校验失败——不可变源版本不匹配时根本走不到写文件。真正的提交路径既无接缝也无覆盖：`atomicWrite` 是 fileprivate，测试无法直接调用；`FileManager.replaceItemAt` 在 Swift 里不可覆写，注入失败同样走不通。**这是测试缺口而非缺陷**：`atomicWrite` 先写临时文件再 `replaceItemAt`，catch 只删临时文件、不碰目标文件。已用只读目录构造同一类失败（磁盘满／权限拒绝正是该验收项指的场景）补上回归，断言抛出 `atomicWriteFailed`、原始字节逐字节不变、原稿仍可读、不残留 `.tmp`；root 绕过目录权限，测试显式跳过而不是假装通过。通用教训：**验收项里点名的失败模式，必须有一条真正走到该路径的回归**；只覆盖前置校验会让「已覆盖」变成一种自我安慰。

15. **「独立有损精简」在产品内没有任何入口（第四轮审查验收标准 1 时发现）**：验收标准 1 要求「有损精简须**单独授权**并展示删减，原稿和已确认版本不被覆盖」。逐条核对三个环节：
    - **单独授权——用户无法发起**：`condenseDraft(mustKeepSourceRanges:)` 在全仓范围内**只有一个调用点**，位于 `TeleprompterSessionLifecycleTests.swift:509`。`TeleprompterView.swift` 里与加工相关的入口只有 `analyzeDraft()`（自然朗读）和 `tightenReadingBlocks()`（让表达更简洁）；`TeleprompterReviewCopy` 连一条精简文案都没有。方案 §4 期望的三个加工选项「保持原文／自然朗读／按时长精简」中，第三个不存在。
    - **标记必讲／可删——无生产者**：`mustKeepSourceRanges` 参数在全仓没有任何调用方传入，`condenseLockedRanges` 因此恒为空，`lockedUnitIDs` 恒为空集。方案 §5.7 定义的「标记必讲／可删内容」这一步在产品中不存在，`condenseRefusesToDeleteLockedContent` 只有测试能到达。
    - **展示删减——审阅项永不出现**：`contentRemoved` 审阅项的唯一来源是 `applyPreparationResult` 中 `block.disposition == .skip` 的分支，而 `finalize` 只在 `input.operation == .condense` 时才把空文本转成 `.skip`。既然 `.condense` 不可达，`.skip`、`contentRemoved` 审阅项与由其触发的复核态在真实 App 中**一次都不会出现**。
    - **未被覆盖的部分是成立的**：`acceptPendingVersion` 走 `versions.append`，`sourceText` 不被改写，原稿与已确认版本确实不会被覆盖。
    - **性质**：这不是计算错误，而是**交付缺口被记成了完成**。会话层与流水线层的实现正确且有回归（`condenseReportsOmittedContentAsSkippedAndReviewable`、`condenseRefusesToDeleteLockedContent`），但单测通过并不等于用户能用到。这与第 13 条同属一类——**当验收项依赖一个从未被触发的路径时，测试可以全绿而验收从未真正成立**。方案 §12.7 的回退条款写「停用新的精简入口不影响已确认版本阅读」，本身已经把「入口」当作本包应当存在的产物。
    - **当时的处置**：补齐需要新增入口、「标记必讲」交互与删除清单展示三处产品设计决定，超出当轮审查范围。此处只把「已完成」的表述纠正为「部分完成」。**后续第五轮已把三处全部交付**（入口 `TeleprompterCondenseDisclosure`、必讲标记、删除清单原文展示），见 §2 第 20、21 条；本段保留原文以记录当时的判断。

16. **「显式语言配置」在产品内无法设置（第四轮同一扫描发现）**：与第 15 条同源。阶段报告原写「Realtime `transcription.language`／`keywords` 真正下发」，实测只有 keywords 成立：
    - **契约层没问题**：`RealtimeContractTypes` 的 transcription payload 确实在 language 非空时写入 `transcription["language"]`，`RealtimeContractTests` 也有断言。共享契约对其他调用方无影响。
    - **keywords 链完整可达**：`TeleprompterSession.currentRealtimeConfiguration` 从当前段起的 8 段聚合 `segment.keywords`，`segment.keywords` 来自 AI 分析产出，生产路径完整。
    - **language 侧没有生产者**：`session.preferredSpeechLanguage` 是一个普通 `public var`，在 `TeleprompterSession.swift:2032` 被读入连接配置，但**全仓没有任何生产写入点**——唯二的赋值在 `TeleprompterSessionLifecycleTests.swift:662` 与 `:712`。`TeleprompterStageSettings` 里没有语言键，`TeleprompterView` 里没有语言设置 UI。`.sanitized` 会把 `nil` 归一为不下发，因此**真实 App 每次连接都用服务端默认语言**。
    - **为什么两个具名回归却是绿的**：`voice start hands the recognizer the script's keywords and the chosen language` 自己先给 `session.preferredSpeechLanguage = "zh"` 再断言 wire。测试构造了产品无法产生的状态。这与第 15 条是同一个教训的两种形态——**测试可以驱动一个产品里不存在的状态**。
    - **本轮未补设置 UI**：需要新增语言选择的持久化、设置界面与合法性校验，属产品设计决定，超出审查范围。

17. **同类问题的系统性排查（方法记录）**：发现第 15 条后，对 `macos/SpeechRailApp/SpeechRailApp/Teleprompter*.swift` 全部 `public func`／`public var` 做了一次「生产调用点」扫描（排除同文件内部调用后，要求至少被一个生产文件引用）。命中 34 项，逐项分类：
    - **真缺口 2 项**：本条与第 15 条。
    - **误报（同文件内部已调用）**：`currentSegment`、`isClosingStage`、`openForManualReading`。
    - **能力在、只是包装函数未被用**：`moveToNext()`／`moveToPrevious()` 无调用方，但舞台的空格／方向键经 `onKeyPress` → `handleReadingKeyPress` → `moveByDisplayLine` 实现，键盘翻行能力完好（#113 的「保留空格/方向键翻行」不受影响）。这两个包装函数属死代码。
    - **测试接缝／协议要求，按设计如此**：`realtimeClientFactory`、`TeleprompterStore.loadBundle`／`updateRunState`、`TeleprompterV2Store.formatVersion`。
    - **Codable 编码器按名反射消费，名字不会被静态检索命中**：`TeleprompterReplayEvaluator` 的 15 个报告字段（JSON 报告确实含这些键）。
    - **仅供测试的公开别名**：`TeleprompterFollowController.hypothesisPosition` 是私有 `candidatePosition` 的别名；#107 的三位置分离在算法内部真实成立，不受此影响。
    - **既无文档声称、也无产品消费**：跟随诊断的 `queueAgeP95Milliseconds`／`matchP95Milliseconds`／`captureToSendP95Milliseconds`。控制器在生产中确实采集这些样本，但没有任何界面读取；方案与本报告都未声称它们对用户可见，因此**不记为缺陷**，只作为未认领范围提示承接团队。

18. **旧稿的句内恢复落点此前没有任何回归覆盖（第四轮审查验收标准 3 时发现并补上）**：验收标准 3 要求「迁移失败保留原数据」。本轮实际只新增了两个持久化字段，且都可选——`TeleprompterV2RunSummary.lastSegmentOffset`（键 `last_segment_offset`）与 `TeleprompterRunState.currentSegmentOffset`。逐条核实后：
    - **确认没有不可逆迁移**：两个字段都是 `Int?` 且带默认值，Swift 合成解码器对可选属性用 `decodeIfPresent`，旧 bundle 缺键即解为 `nil`。`currentSegmentOffset` 实际上根本不落盘——它是 `TeleprompterRunState` 这个内存桥接类型上的 Swift 属性，**因此连同名的 JSON 键都不存在**（此前本报告误写过一个下划线形式的键名，第二十六轮做引用可解析性核查时查出并改正），加载时由 `applyV2Bundle` 从 `lastRun.lastSegmentOffset` 重建。真正跨版本落盘的只有 `last_segment_offset`，§6 的回退声明成立。
    - **已有的旧格式回归只验了一半**：`runSummaryWrittenBeforeIntraSegmentProgressStillLoads` 删掉 `last_segment_offset` 后断言解出 `nil`，但**没有断言读者随后落在哪里**。而 `lastSegmentOffset` 的文档注释明确承诺「older payloads simply omit it … which restores the segment start」——这个承诺当时没有任何测试钉住。
    - **恢复器的 nil 分支此前完全无覆盖**：`TeleprompterReadingProgressRestorer.position` 有三条测试，分别覆盖偏移 4、跨版本改文回落、跨版本同文迁移与越界钳制，**全部带非 nil 偏移**。而 `saved.currentSegmentOffset ?? 0` 这个 `?? 0` 正是每个升级前文档都会走的分支。
    - **补上的回归**：`readingProgressRestoresTheRecordedSegmentStartWhenNoOffsetWasEverSaved` 用第二段（`segment-1`）而不是第一段做记录点，因此它能区分「回到该记录段的开头」与「盲目回退到全文开头」——后者是这个分支最自然的写错方式。
    - **变异验证（这条测试确实有约束力）**：对 `position` 施加两次定向变异。第一次把返回改成恒定 `segmentIndex: 0, utf16Offset: 0`，新用例与既有用例一起变红——说明它不是孤例。第二次**只**在 nil 分支上插入 `guard saved.currentSegmentOffset != nil else { return nil }`，结果**同套件 13 条既有测试全部保持绿色，只有新增这条变红**。这证明既有覆盖确实漏掉了整个 nil 路径，而新增用例精确地锁住了它。生产文件在两次变异后均已还原，`git diff` 为空。

19. **稳定前缀与 2048 scalar 保留窗口的交互：一处判定为「不是缺陷」的潜在边界**（第四轮审查 #106 证据通道时记录）：`TeleprompterFollowController.receiveSnapshot` 先把快照截成 `text.suffix(2048)`（既有代码），再把 `stablePrefixCodepoints` 按保留窗口重新钳制。稳定前缀是**从文本开头**数的，一旦发生截断，保留窗口的开头已经不是那条「已证明稳定」的边界，重钳后该值可能被套到窗口内的另一段文字上——推理上不成立。
    - **两层校验本身是扎实的**：wire 层在 `RealtimeASRClient` 拒绝 `stable_prefix_codepoints < 0` 或 `> text.unicodeScalars.count` 并发 `invalid_hypothesis`；消费层再钳一次才调用 `prefix()`，因此越界值会变成 `nil` 而不是崩溃或越界。这是我最初怀疑的崩溃路径，已排除。
    - **为什么仍不改代码**：一，生产不可达——需要单个 item 超过 2048 scalar，而协商扩展的 item 时长上限为 8000 ms，中文语速下远达不到 2048 字。二，构造不出可观察的 fail-open 差异——实测把 `stablePrefixCodepoints: 100` 配 3000 scalar 文本驱动生产 adapter，位置与完全不传证据一致，说明两个分支都锚定在当前位置前进；差异要在位置断言上体现，就需要一套能同时让「窗口前缀」和「全文」落在不同锚点的脚本，代价与收益不成比例。三，在不可达路径上写一个无法证伪的断言，比不写更糟：它会让人误以为该边界已被覆盖。
    - **留给承接团队**：若将来提高保留窗口、放宽 item 时长上限，或改用其他传输来源，**先回到这条**。届时的正确修法是显式判断是否发生截断（保留长度与原文长度不等即视为截断），截断时直接放弃稳定前缀声明，而不是拿它去解释窗口内的另一段文字。
    - 这条不影响 #106 的结论：稳定前缀的两层校验、越界拒绝与保守回退均有具名回归，本条只是记录一个**尚未被触发**的推理缺口。

20. **删除审阅卡片从不显示被删掉的原文；「按时长精简」也从未接入界面（第五轮据目标验收标准 1 实施时发现并修复）**：上一轮把这两处记为交付缺口。本轮按方案 §5.7「展示删除清单」与 §4「可选加工：保持原文／自然朗读／按时长精简」实际补齐，过程中发现比记录的更严重的一层：
    - **`sourceSnippet` 被写入但从未被渲染**。`TeleprompterSession.applyPreparationResult` 为每条审阅项填了 `sourceSnippet`（`block.rawSourceText`），但全仓只有**测试**读这个字段，任何生产视图都不读它。删除项的 `suggestedText` 又是空的（skip 块正文为空），于是卡片上「建议：…」这行根本不显示。结果是：界面只说一句「这一段将被删除／精简建议不讲这一段，删除后就不会出现在朗读稿里」，**从不显示删的是哪一段**。已有的那条回归 `condenseReportsOmittedContentAsSkippedAndReviewable`（其断言消息正是「删除审阅必须展示被删掉的原文」）只证明了模型携带该字段——又一次「测试验模型、用户看不见」。
    - **修复**：审阅卡片在「有建议显示建议、没建议显示原文」——`item.issue == .contentRemoved || item.suggestedText.isEmpty` 且 `sourceSnippet` 非空时，渲染「原文：…」。规则本身是通用的，不是给删除项开的一个特判。
    - **补上入口**：草稿阶段的加工区新增「按时长精简…」，但**刻意不与保真整理并列为主操作**——它必定先经过 `TeleprompterCondenseDisclosure` 确认，文案明确写出「真的会少讲一些内容」「与整理朗读稿不同：整理只改表达，不会删信息」「删掉的每一段都会单独列出来」。这是「单独授权」的落点；`condenseDraft` 依然没有任何绕过确认的调用路径。
    - **确认文案不复用数据流确认**：保真整理的确认文案承诺「不会删」，让有损操作复用它等于用一句假话为删内容背书，因此另立一段。顺带修正一处会直接显示给用户的细节——初稿里用 `**…**` 强调，但 SwiftUI 的 `Text(String)` 不解析 markdown，星号会原样显示，已改为纯文字。
    - **本轮验证到什么程度**：Xcode Debug 编译 **BUILD SUCCEEDED**、`swift test` 全部通过（本条落地时为 214 项，最终计数见第 21 条）。**没有做界面走查**（未获逐次授权），因此「按钮位置、确认弹层、原文行在实际窗口中的呈现」属于**未验证**，已并入 §5 第 1 条的 U-10 走查范围。
    - **仍未交付**：方案 §5.7 的「标记必讲／可删内容」在本轮之后依然没有界面——草稿阶段只有一个可编辑正文视图，没有可挂标记的来源单元列表，`mustKeepSourceRanges` 仍然只被测试调用。不具备标记能力时，锁定集合为空，精简可删任何段落；安全性目前**完全依赖「删除必进审阅且原文可见」这一层**，而不是锁定。承接团队若要补锁定，需要先在草稿阶段引入来源单元的标记交互。

21. **「标记必讲／可删内容」此前既无界面也无锁定映射的回归（第五轮据方案 §5.7 补齐）**：第 15、20 条把「必讲标记」记为缺口。补齐时发现缺口比记录的更深一层——**不是只有界面没有锁定，而是锁定这条链本身没有任何回归**：
    - **已有锁定回归绕过了 session 层**：`condenseRefusesToDeleteLockedContent` 直接构造 `TeleprompterPreparationInput(lockedUnitIDs:)`，验证的是流水线「锁定单元被删就整轮失败关闭」。而界面实际走的是另一条路——`condenseDraft(mustKeepSourceRanges:)` 里的**重叠映射**（`unit.sourceRange.start < range.end && range.start < unit.sourceRange.end` → `lockedUnitIDs`）。这段映射此前没有任何测试，而它正是「用户标记的到底是哪一段」与「流水线锁住的是哪一段」之间唯一的连接点。
    - **范围必须来自 session，不能由界面重算**：`TeleprompterContentSelectionSheet` 按 `\n\n` 切段时**丢弃了原文偏移**（`Paragraph` 只有 `id` 与 `text`）。若照抄这个切法，界面算出的范围一旦与 `paragraphRanges(in:)` 有任何差异，就会锁错文字而且不报错。因此新增 `TeleprompterSession.mustKeepCandidateRanges()`，由 session 提供与流水线同一份切分，界面只负责显示与勾选。
    - **新增两条回归，且做了两次变异验证**：`condenseFailsClosedWhenAMarkedParagraphWouldBeDeleted`（标记最后一段、模型恰好删它 → 整轮失败关闭、无候选版本、无删减审阅项）与 `condenseStillReviewsDeletionsOutsideTheMarkedParagraphs`（标记第一段 → 其余段落仍进删减审阅且原文可见，标记段不出现）。变异一：把映射改成恒空（锁太空）→ 第一条红 3 处断言；变异二：把过滤改成恒真（锁过度）→ 第二条红 2 处断言。两次分别只命中该测的那条，**说明这两条各自只对自己负责的失败模式有约束力**。生产文件两次均已还原。
    - **一次无效变异值得留下**：第一次把锁改成「精简时全锁」，结果两条测试**全绿**。查下来是变异写错了位置——三元式的 `: []` 分支只在非精简操作下求值，对精简路径毫无影响。**「变异没让测试变红」首先该怀疑变异本身，而不是急着记成覆盖缺口。**
    - **交互落在哪里**：按项目「默认路径只给少量明确动作、进阶操作渐进式披露」的约定，必讲标记收在精简确认 sheet 的 `DisclosureGroup` 里，**默认折叠**——不展开就是两步确认，展开才逐段勾选。默认全部不标记，并在展开区明确写出「未标记任何段落：所有内容都可能被精简列为删减候选」，避免用户以为「没标记＝安全」。
    - **本轮验证到什么程度**：Xcode Debug **BUILD SUCCEEDED**、`swift test` 216 项 / 16 套件、`--test-unit` **TEST SUCCEEDED**。**界面仍未走查**：sheet 的默认高度、Disclosure 展开后的段落列表、滚动与勾选的可访问性都没有实际窗口证据，已并入 §5 第 1 条。

22. **显式识别语言在产品内无法设置（第六轮补齐，见第 16 条）**：第 16 条记录了 `preferredSpeechLanguage` 全仓没有生产写入者，真实连接恒用服务端默认语言。本轮补齐时定了三条约束：
    - **持久化放在视图层，不放进 session**。`preferredSpeechLanguage` 是被测试直接赋值的普通 `public var`；若把 `UserDefaults` 写进它的 setter，测试每次赋值都会留下持久化副作用。因此 session 保持纯内存，写入与持久化都由视图层负责，与既有的 `aiDataFlowAcknowledgementKey` 同一模式。
    - **恢复时必须清洗，不能直读**。存进 UserDefaults 的值可能来自旧版本、手工改写或损坏。`restorePreferredSpeechLanguage()` 复用 `TeleprompterRealtimeConfiguration.sanitized`——越界值退回「自动」，而不是把非法语言带进连接。这样「读取设置」和「下发设置」走同一套契约判定，不会出现两套口径。
    - **进阶项做渐进式披露**。识别语言对多数脚本是「自动」就对了，因此不占主路径，而是收成语音跟随控制旁一个带标签的菜单（标签随当前值变化，如「识别语言：自动」）。标签本身就是状态，用户不必点开就知道现在是自动还是指定。
    - **一条防呆回归**：菜单里列出的每个语言都必须能通过契约清洗。否则会出现「点了没反应、也不报错」的选项——用户以为设置失败或服务有问题。`offeredSpeechLanguagesAreAllContractValid` 遍历选项列表逐个断言；变异验证塞入一个越界项后该测试变红，生产文件已还原。配套的 `storedSpeechLanguageIsSanitisedBeforeUse` 钉住越界、空串与带空白三种存储值。
    - **本轮验证到什么程度**：Xcode Debug **BUILD SUCCEEDED**、`swift test` 218 项 / 16 套件、`--test-unit` **TEST SUCCEEDED**。**界面未走查**：菜单的呈现、标签长度、帮助文本在窄窗下的表现都没有窗口证据，已并入 §5 第 1 条。
    - **诚实边界**：契约只保证 2–24 个字符的合法值会被下发，**不保证所列语言都受当前引擎支持**。服务端不支持时应按既有降级处理，真实识别效果仍属 §3.2 未执行项。

23. **三处复选框没有无障碍名称，台账 U-07 的措辞比实际支持的范围宽（第七轮自审本轮新增界面时发现）**：本轮新增了四处界面但未获授权做 UI 走查，于是改为静态自审。结果发现一个既有缺陷，而且我新增的那处是照抄了它的写法：
    - **缺陷本身**：三处使用 `Toggle(isOn:) { EmptyView() }` 配合 `.toggleStyle(.checkbox)`——审阅卡片的批量勾选、内容选择 sheet 的段落勾选、以及本轮新增的必讲段落勾选。**`EmptyView()` 意味着复选框没有无障碍名称**，VoiceOver 只会念「复选框，未选中」，用户无从判断自己选的是哪一段。旁边的可见文字不构成控件名称。
    - **台账为什么没抓到**：U-07「无障碍与 Reduce Motion」标为通过，引用的 `controls remain visible for focus, menus, VoiceOver, and opt-in always-on` 实际只验证**控制栏在 VoiceOver 开启时不被隐藏**（`voiceOverEnabled` 参与 `controlsVisible` 判定），**完全不涉及控件自身的名称与角色**。引用它来支撑「无障碍通过」是扩大了证据能证明的范围——这与本项目此前几次「测试验模型、用户看不见」是同一类错误，只是这次发生在报告层而不是代码层。
    - **修复**：三处分别补上具体名称——「选中这条待确认事项，用于批量处理」「选择第 N 段，加入本次要讲的内容」「把第 N 段标记为必讲，精简不会删除它」。名称都描述**动作与对象**，而不是复述控件类型。
    - **本轮验证到什么程度**：Xcode Debug **BUILD SUCCEEDED**、`swift test` 218 项 / 16 套件。**无障碍名称的实际朗读效果仍未验证**——`.accessibilityLabel` 是否被正确合成、是否与相邻文字重复播报，都需要一次授权的 VoiceOver 走查，已并入 §5 第 1 条。
    - **给承接团队的一条方法提醒**：本项目已四次出现「证据只覆盖了命题的一部分，却被写成覆盖了全部」。U-07 这一条至今仍是**部分满足**——控件可见性有证据，控件名称此前没有证据、现在只有静态修复没有朗读证据。

24. **F-07「真实重读受控回退」的「受控」二字从未被任何测试触及（第八轮证据强度审计）**：台账把 F-07 标为通过，引用的 `localRepeatCanReturnToPreviousSentence` 位于 `TeleprompterAlignerTests`，**只调用 `TeleprompterAligner.locate`**，证明的是「对齐器找得到上一段」，与跟随控制器要不要真的回退是两件事。真正裁决回退的是 `TeleprompterFollowController.mayConfirm` 的后向门禁（`confidence >= 0.95 && matchedCount >= 6 && tokenDistanceFromAnchor <= 24`）。把该门禁改成无条件 `return true` 后，**218 项测试全绿**。
    - **行为本身是对的，但完全没被钉住**：探针实测——整句重读（`matched=10`、`conf=1.0`、`dist=13`）确实回退；只命中两个 token 的远处短语（`matched=2`）被 `matchedCount >= 6` 挡下，位置与已确认位置均不变。换句话说，**门禁在生产里是有效的，只是没有任何测试证明它有效**。
    - **补两条回归**：`rereadRollsBackOnlyWhenTheBackwardMatchIsStrong` 用同一个控制器连打三次——前进、整句重读（必须回退）、再前进、然后一句两 token 的远处短语（必须留在原位，且 `committedPosition` 不变），把「能回退」和「不许乱回退」钉在同一串事件序列上。`rereadDoesNotRollBackAcrossDistantParagraphs` 用五段脚本从第 5 段回匹配第 1 段（`matched=17`、`conf=1.0`，但 `dist=61` 已超半径），固定距离上限这道子句——**没有它，一次口误就能把观众在提词器上倒退四段**。
    - **两条都经变异验证**：删掉整个后向门禁、只删距离子句，各自变红的正是对应的新用例。

25. **F-11 的真实 epoch 证据藏在一个名字不相干的测试里，同函数另两道闸门零覆盖（同一轮审计）**：`RealtimeEventState.canAcceptExtension` 是一组身份闸门——`latestEpoch` 回退、旧 `generation` 复用、`retiredUntil` 复活、跨 `serverTaskID` 复用。逐个变异后：
    - `latestEpoch` 被 `testRealtimeItemStateValidatesUnicodeSpansAndMergesSameRevisionShards` 杀掉。**该测试的名字里没有任何 epoch 字样**，台账引的却是两个控制器层的陈旧 item 测试——真证据引错了地方。
    - `retiredUntil`、`serverTaskID` 两道闸门**此前零覆盖**：删掉任一，218 项全绿。补 `testRealtimeItemStateRejectsLateHypothesisForARetiredItem`（item 走完生命周期退役后，窗口内的迟到 hypothesis 必须被拒）与 `testRealtimeItemStateRejectsAForeignTaskIDWithinOneConnection`（同一条连接内换 `task_id` 必须被拒，且不得留下任何 item 状态）。两条均经变异验证。
    - 第三道 `existing.generation == generation` **在生产中不可达**：`generation` 只在 `reset(generation:)` 里改，而 `reset` 与 `clear` 都清空 `items`，因此 `existing` 永远与当前 generation 同源。与本报告第 19 条的 `suffix(2048)` 同类——**在不可达路径上补断言是自欺**，只记录不补测试。

26. **F-12 与 F-15 的行为有覆盖，但台账引错测试／计数过期（同一轮审计）**：
    - **F-12**：sequence 缺口、回退、首事件必须为 0、缺口后仍须报回退——四个变异分别被 `testSequenceValidatorReportsGapAndRegression` 与 `testSequenceValidatorRejectsMissingIdentityAndNonzeroInitialSequence` 杀掉，**行为确实被覆盖**。但台账写的是「`RealtimeContractTests`（31 项 XCTest 全通过）」——该套件现有 **35 项**（本轮新增 2 项），且以整个套件充作单条场景的证据本身就过宽，应引具名测试。
    - **F-15**：越界的 `stable_prefix_codepoints` 在 **`RealtimeASRClient` 解码层**就被拒（`invalid_hypothesis`／「稳定前缀超出当前快照范围」），根本到不了跟随控制器。台账引的 `stableHypothesisPrefixLimitsPreviewToProvenText` 测的是控制器的稳定前缀预显机制，与越界无关。**行为有覆盖，引错测试**；正确证据是 `testHypothesisRejectsStablePrefixBeyondCurrentUnicodeScalars`。附带查清：控制器内 `$0 <= item.text.unicodeScalars.count` 那道检查既不可达（wire 已拒）又是空操作（`prefix` 自己会夹），因此控制器的越界变异存活属预期，不补测试。

27. **变异探针本身出错，差点连着给出四个假结论（同一轮的方法教训，比上面三条更值得记住）**：第一次跑 Realtime 闸门变异时，八个变异全部「存活」。**结论是错的**——`testSequenceValidatorReportsGapAndRegression` 直接断言 `.regression`，删掉该分支不可能不红。手工复核发现探针只匹配 swift-testing 的 `✘`，完全漏掉 XCTest 的 `Test Case '…' failed`，于是把编译期就失败或 XCTest 失败一律误判成存活。修正为「退出码 + 两种失败格式」并**加了一道编译预检**（先把变异编译一遍，编译不过直接判为无效变异，不计入存活）后重跑，真实结果是有 killed 有 survived。
    - **这是本项目第二次栽在「变异没让测试变红」上**（第一次见第 18 条）。两次的成因不同但教训同构：**「变异没让测试变红」几乎总是先怀疑变异本身，而不是先怀疑测试**。具体检查顺序是三条：变异是否真的写进了被测文件、变异是否编译通过、被测 target 是否真的包含该文件。第 25 条里 `generation` 闸门之所以判为不可达，也是靠第三条（确认 `reset` 清空 `items`）才站得住。
    - **对交接的提醒**：本轮新增的四条回归**每条都做了变异验证**（删掉对应门禁必须变红），不是只看「测试通过」。承接团队若要扩充证据，建议沿用 `/tmp` 下的三段式探针（写变异 → 编译预检 → 匹配两种失败格式），否则很容易把「探针没报错」当成「行为没被覆盖」。

28. **三处内存有界化在当前接口下不可证伪，只记录不补断言**：变异删掉 `retired`／`eventIDs` 的 128 上限、以及 `items.count > 8` 的最旧 item 淘汰，**220 项测试全部存活**。查因后确认这不是漏测而是**测不了**：
    - 两处上限是私有列表长度，删掉不改变任何可观察行为。
    - 淘汰失效后，迟到事件仍被另外两道守卫挡住——`retired` 名单未含该 id，但 `finalizedSequence` 单调递增，旧 item 的 `sequence` 必然小于它，`receiveCompleted` 里的 `guard item.sequence > finalizedSequence` 会退回。这与第 19 条的 `suffix(2048)`、第 25 条的 `generation` 闸门同属**纵深防御的外层**，内层已经足够。
    - 因此只补了一条**不冒充上限证明**的回归 `longRunsStayCorrectAcrossHundredsOfItems`：连打 300 个 item，断言末条证据仍能推进、且长跑之后重复 event id 仍被抑制。它固定的是「长跑后行为不漂移」，**不是**「列表被截断到 128」——测试名与注释都按后者不可证伪来写，避免下一轮有人以为这里有覆盖。
    - R-07 仍是**部分满足**：本条不改变该结论，真实长时连续运行仍需授权（§5 第 3 条）。

29. **P-08 的三个子项里「否定」从未被测过（第九轮审计 P 段）**：把 `negationMarkers` 整个清空，**223 项测试全绿**。`TeleprompterReviewIssue.negationChanged` 在全仓**只出现在生产代码里，没有任何测试断言它**——而台账 P-08 写的是「条件／否定／确定程度变化」，引用的 `qualifierLossInRewriteBecomesUnresolvedReview` 只断言了 `.conditionRemoved` 与 `.comparisonChanged`，`semanticReviewDetectsSubjectValueAndQualifierChanges` 只断言了条件与确定程度。**四类限定语里，恰恰是唯一会翻转含义方向的那类没有证据**。探针确认生产行为正确（「不得」→「会」等四例都触发）。补 `negationLossBecomesUnresolvedReview`，从 pipeline 端到端断言：数值未变时硬门禁放行、块进入 `.unresolved`、issue 含 `.negationChanged`。

30. **「精简／保真权限分离」在解码层没有守卫（P-16）**：`omit` 必须空文本、`.review` 不得同时声明 `nonspokenContent`——这两条守卫删掉后 223 项全绿。台账 P-16 引的是 `fidelityOperationsStillRejectOmissionsAsUnresolved` 与 `condenseReportsOmittedContentAsSkippedAndReviewable`，两者都验证**操作层**的权限分离（保真操作不许删内容），不经过 `TeleprompterRewriteDecoder` 的 mode 分支。补 `rewriteRejectsOmitWithTextAndReviewClaimingNonspokenContent`。

31. **M／U 段四处缺口（同一轮）**：`TeleprompterReadingProgressRestorer` 在**记录版本已被删掉**时退回段首这一支无覆盖（已有三条只覆盖「同版本」「文本变了」「偏移越界」）；`visibleLineSlots` 的**两行模式在稿尾**不留空无覆盖（已有用例只测了两行模式的**中段**）；`displayLineIndex` 在偏移**超出段尾**时落到该段最后一行无覆盖；`listDocuments` 的排序方向无覆盖，但**台账未声明这一条**，只记录不补断言。补前三条：`readingProgressFallsBackToSegmentStartWhenTheRecordedVersionIsGone`、`displayLineSlotsClampRowsAndEmptyTheTrailingSlot`、`displayLineIndexClampsOffsetsPastTheSegmentEnd`，均经变异验证。
    - **一处必须写清的界限**：`visibleLineSlots` 内部的**上限**夹取（`stageMaximumVisibleLineCount`）**不可观测**——`switch` 对任何 ≥3 的入参都走 `default` 返回 3 槽，删掉上限没有任何可观察差异。因此新回归断言的是**具体槽位数组**（`[9, nil]`、`[3,4,5]`、`[4]`），**不是**「99 的结果等于 3 的结果」这种同义反复的写法；后者在第一次写时就错误地存活了，改正后才杀掉真正的变异。

32. **T-06 的回归靠挂死来发现缺陷，本轮修掉了这个隐患（真缺陷，非证据问题）**：`test_receive_loop_fails_instead_of_growing_an_unbounded_queue` 用**非守护线程**跑 `_receive_loop`。把有界投递改成阻塞投递后，线程永久卡在 `put` 上——断言确实会失败，但**非守护线程让整个 pytest 进程无法退出**。实测：变异后跑满 9 分钟仍未结束，只能中断。改为守护线程并补 `assert not thread.is_alive()` 后，同一变异从「挂死 9 分钟」变成 **0.4 秒内正常失败**，整批 T 段变异 7.6 秒跑完。**这与第 9 条记录的 Xcode 测试闸门挂死是同一类风险**：一个会挂死的测试比一个缺失的测试更难查，因为它卡住的是整条流水线而不是给出红灯。

33. **变异探针第三次栽在「工具没真正跑起来」上（同一轮，最值得记的一条）**：跑 T 段时六个变异**全部报 KILLED**，但整批只用了 0.007 秒。复核发现当前解释器**根本没装 pytest**，每次 `python3 -m pytest` 都以「module not found」非零退出——被我的判据读成「测试失败」。换成主检出的 venv 后又撞上第二层：单文件运行必然触发 `--cov-fail-under=80` 而非零退出，同样会被读成「被杀掉」。两层都修好并加**基线自检**（不改代码时必须 exit 0，否则拒绝解读任何变异结果）后才得到可信结论。

34. **SwiftPM 与 Xcode 编译的是两份不同的文件集，视图层只有 Xcode 一条门禁（第十轮，最容易误判的一条）**：`Package.swift` 的 `sources` 显式列出参与单测目标的文件，`TeleprompterView.swift` 与三个 sheet **都不在其中**。因此 `swift test` 全绿并不代表界面能编译：新增读法标注窗口时 SwiftPM 报 `Build complete`，同一次提交的 Xcode 构建却抓出两个错误（`ForEach` 要求 `TeleprompterSourceRange: Hashable`、一个不存在的 `String(prefix:)` 初始化器）。**「`swift test` 通过」不能用作视图层编译证据**，这类结论只能来自 `scripts/macos_app_build.sh`。
35. **pbxproj 没有文件系统同步组，漏注册是静默失败**：新增 `TeleprompterReadingAliasSheet.swift` 必须显式写入 `PBXFileReference`、`PBXBuildFile`、group children 与 App Sources 四处。漏掉任何一处，`swift test` 依旧全绿（SwiftPM 按目录扫文件），只有 Xcode 会发现 App target 里没有这个类型。本轮显式注册后以 `BUILD SUCCEEDED` 与 `plutil -lint` 证明；这补强了 §5 第 9 条的结论。
36. **语音辅助试读第一版释放路径只关会话自己的 client／source，coordinator 仍持着设备租约（真缺陷，测试先于提交抓到）**：`stopSpeechTrial()` 最初直接调 `stopCapture()`，而 `stopCapture()` 只释放 `client`／`source`，设备租约在 `SessionCoordinator` 上。于是试读做一次，**麦克风就再也开不了下一次**（`coordinator.occupancy` 永不清空）。改为经 `coordinator.stopCapture()` 归还，让 owner 自己释放；回归 `a speech trial releases the device and leaves no session row` 钉住 `occupancy == nil`、`activeSessionID == nil`、连接关闭一次与采集停止一次。
37. **别名 span 自身的位置从未被任何断言覆盖**：原有用例断言的是「整句念完停在哪」，而那个位置来自别名**之后**的词——把别名的 span 改成偏移 0，测试依旧全绿。补 `thePositionOfTheAliasedWordsThemselvesStaysOnTheDisplayedSpan`：让转写正好停在别名上，位置必须落在显示文本那一段的末尾。另有三条同批补齐：跨数值边界的别名整条作废、失效别名不进入 token 流、存盘拒绝重叠别名。
38. **探针改在被测代码不相干的位置，比没有探针更糟（第十一轮方法教训）**：「试读沿用同一套识别配置」那条变异，首版改的是 `RealtimeASRClient` 兜底构造的 `language`／`keywords` 实参，而测试注入的 `realtimeClientFactory` 根本不经过该分支——这条探针与被测路径无关，跑绿也什么都没证明。改写为「试读若自己硬编一份空配置」后才被杀死。与第 33 条同源：**先确认探针真的作用在目标路径上，再解读它的结论。**

39. **试读期间关闭舞台不会释放麦克风（第十二轮自查自己写的代码时发现，真缺陷）**：`TeleprompterVoiceAssistLifecycle.beginStop` 对 `.off` 返回 `nil`，而语音辅助试读刻意不经过 `voiceLifecycle`（它只服务跟读），于是试读期间生命周期停在 `.off`。`closeStage()` → `beginStageClose()` → `requestVoiceStop()` 拿到 `nil`，`disableVoiceAssist()` 也没有兜底任务，**整条关闭链没有发起任何停止**：`source`、`client` 与 coordinator 的设备租约全部留在原处，麦克风再也开不了下一次。修复：`finishStageClose()` 在 `disableVoiceAssist()` 之前显式收尾试读。这条是**先写失败回归再修**的，两条断言（租约归零、采集停止）当场变红。
40. **试读进行中再请求语音跟随会复用试读的 client／source（同一轮，真缺陷）**：`enableVoiceAssist()` 走 `coordinator.requestStart(.teleprompter)`，而占用方本来就是提词器，coordinator 判定为「已经在跑同一个会话」而**什么都不做**；随后 `guard client != nil, source != nil` 却因为试读那套仍然成立而通过，于是新管线的 `startPipeline` 直接覆盖 `self.client`／`self.source`，两套泵同时跑。试读本身不会被这轮自查破坏，但状态已经是错的。修复：`enableVoiceAssist()` 开头显式拒绝并给出 `BlockReason.speechTrialActive`——新增这个 case 而不是复用 `occupiedBy(.teleprompter)`，因为占用麦克风的就是提词器自己的功能，说成别的能力在用会把责任推给一个根本没参与的功能（项目设计规则里「失败归因要说对人」）。本轮同时被第 34 条再次印证：新增 enum case 造成的 `switch` 不穷尽错误，`swift test` 全绿、`scripts/macos_app_build.sh --test-unit` 报 `TEST FAILED`。
    - **教训比第 27 条更通用**：第 27 条讲的是「变异本身写错」，这条讲的是「**测量工具本身没运行**」。两者都会产出看似干净、实则全错的结论。探针必须先自证：基线 exit 0、一次已知应当 KILLED 的变异确实被杀。**任何变异审计的结论，在没有基线自检之前都不该被采信。**
    - **顺带的可复现性问题**：worktree 的 `.venv` 没装 `dev` extra，而项目把 pytest 放在 `[project.optional-dependencies].dev` 而非 `dependency-groups`。阶段报告 §3.1 记的 `pytest tests/…` 在这个 worktree 里**开箱即用是不成立的**，实际依赖主检出的 venv。这条留给承接团队处理（见 §5 第 10 条）。

41. **读法标注把四种失败原因一律说成「正文变了」，磁盘写失败被归因成正文问题（第十三轮自查自己写的代码时发现，真缺陷）**：`confirmReading` 对四种完全不同的原因——`canEdit` 为 false、`document == nil`、段落找不到、存盘失败——一律返回 `.displayTextChanged`，而界面把它映射成「这段正文已经变了，请重新打开窗口再试」。最严重的是**磁盘写失败**：用户被告知正文变了，去重开窗口，白等一场，重开后问题照旧。这违反项目自己「失败归因要说对人」的规则。修复：`TeleprompterAcceptedReadingRejection` 新增 `.notEditable`／`.segmentUnavailable`／`.saveFailed` 三个 case，各配独立用户文案（分别指向「关掉提词窗口后再试」「稿件已经切换」「检查磁盘空间或文件夹权限」）。
    - 顺带修掉同一条函数里的**纵深防御缺口**：`guard document != nil` 原本排在 `versions[versionIndex] = previous` **之后**，该分支不回滚，内存里会留下一条 store 下次拒绝加载的读法——用户以为标好了，下次打开又没了。同文件的 `removeConfirmedReading` 在同一情形下**是**回滚的，两个兄弟函数行为不一致。修复把两个守卫都移到任何改动**之前**，从根上去掉不回滚的分支，而不是靠 catch 兜底。当前 `document == nil` 与 `versions == []` 同时发生、不可达，但兄弟函数已经这么写，代码不该留着「一个回滚一个不回滚」的分叉。
    - 本轮再次被第 34 条印证：新增 enum case 会让别处 `switch` 不穷尽，而三个 case 的用户文案在 `TeleprompterReadingAliasSheet.swift`——**该文件不在 SwiftPM `sources` 里**。改动期间 `swift test` 全绿，唯一的视图层编译证据是 `scripts/macos_app_build.sh`。
    - 变异验证 3 条，全部被两条新回归杀死：存盘失败改回 `.displayTextChanged`（杀）、`.notEditable` 与 `.segmentUnavailable` 合并（杀）、去掉 catch 里的回滚（杀，断言内存中不得残留别名）。第二条最值得记——**把两个语义相邻的错误码合并是最不容易被察觉的退化**，因为两者「反正都写不进去」，只有断言到具体 case 才拦得住。

42. **同一个缺陷在姊妹路径上还在：移除读法把三种原因都说成「没有保存成功」（同轮自查接着发现，真缺陷）**：修完新增路径后重读 `TeleprompterReadingAliasSheet.swift`，发现「移除」按钮走的是 `removeConfirmedReading(...) -> Bool`——`canEdit` 为 false（舞台开着）、这条读法已经不在、存盘失败，三种情况一律弹「没有保存成功，请重试。」**可达性已核实**：就绪页表头的「读法标注」按钮没有 `canEdit` 门控，舞台窗口开着时主窗口照常能打开这个弹窗，于是「舞台还开着」这一路会真实发生，而重试多少次都不会成功。修复：`removeConfirmedReading` 改为返回与 `confirmReading` 同一套 `TeleprompterAcceptedReadingRejection?`，新增 `.noSuchReading` 区分「本来就没有」；弹窗里 `.actionFailed` 随之失去唯一调用方，整条删除而不是留着备用。守卫顺序照新增路径重排（`canEdit`、`document != nil` 都在任何改动之前），去掉原来那条写了回滚、却只在 `document == nil` 时才走的分支。
    - 这一轮顺带暴露一个**测试盲区**：移除路径的存盘失败回滚此前**一条断言都没有**。原实现的回滚其实是对的，但从未被验证过——按本报告自己的纪律（「不再信任自己写的测试，重读代码」），对一条从未被钉住的路径做变异，很容易把「存活」误读成「本来就对」。先补回归再做变异。
    - 变异验证 3 条，全部被杀：移除的 `canEdit` 守卫改回 `.saveFailed`（杀）、`.noSuchReading` 改回 `.saveFailed`（杀）、去掉移除 catch 里的回滚（杀）。
    - **第 34 条在写下它的同一轮里又重演了一次**：改这个弹窗时我先写了 `if rejection == nil { ... } else { message = .init(rejection: rejection) }`，Swift 不会因为 `== nil` 就在 `else` 分支收窄 Optional。`swift test` **全绿**（259 项），因为它不编译这个 sheet；`scripts/macos_app_build.sh` 当场报 `must be unwrapped to a value` 并 BUILD FAILED。**这条记录现在有了一条自证的注脚**：不是「别人踩过」，是「改这块代码时当场踩到」。凡改 `TeleprompterView.swift` 与各 sheet，Xcode 门禁不是可选项。
    - **可复用的一般结论**：修好一条路径的失败归因后，**必须顺着同一个 UI 入口把姊妹路径读完**。这两条缺陷在同一个弹窗里、相隔 60 行，成因完全相同——用粗粒度的返回类型（一个 `Bool`、一个错误码）承载多个原因。凡是把多个原因压成单一返回值的函数，都值得顺着调用方再读一遍。

43. **本轮最重的一条：采用候选版本时存盘失败，会把读者唯一没法重做的工作弄丢，还配了一句安慰话（第十三轮，真缺陷）**：`acceptPendingVersion()` 先把候选版本 append 进 `versions`、把 `pendingVersion` 置 nil、把 `document.activeVersionID` 挪到新版本、重建 `followController`、把 `phase` 推到 `.ready`，**最后**才 `try saveBundle()`。存盘失败时异常抛出去，以上全部改动**一个都没回滚**。三重后果：
    - `pendingVersion == nil` → **AI 审阅结果从界面上消失**，读者已经审过、已经点过采用的那份稿子没了；
    - `canAcceptPendingVersion` 的定义是 `unresolvedReviewItemCount == 0 && pendingVersion != nil`，所以**「采用」按钮变灰，读者连重试都不行**——而重试本该是唯一合理的下一步（腾出磁盘空间后再点一次）；
    - 抛出的错误是 `TeleprompterV2StoreError.atomicWriteFailed`，它的文案是「**稿件保存失败，原版本仍然保留**」。这句话在这条路径上是**假的**：磁盘上保留旧版本没错，但读者刚采用的那份工作既没进磁盘也没留在界面，而这句话正在主动安抚他不要担心。

    修复前先写失败回归，当场四条断言全红（`pendingVersion`、`canAcceptPendingVersion`、`activeVersion` 指向、`phase`），确认可达后才改。修复：把这次改动碰到的每一项（`versions`／`document`／`savedRunState`／`followController`／`phase`／`blocked`／`pendingVersion`）在改动前存下来，写失败整体放回再重抛；位置与跟随状态这些派生字段不逐个猜，而是恢复 `followController` 后调 `syncFollowState()` 重算。改完之后 `.atomicWriteFailed` 那句「原版本仍然保留」**第一次变成真话**。
    - 变异验证 3 条，全部被杀：整个回滚删掉（杀）、不恢复 `pendingVersion`（杀）、不恢复 `phase`（杀）。第三条单独值得记：只写「候选还在、按钮还能按」而不写「仍停在审阅页」的话，回滚漏掉 `phase` 时界面会停在 `.ready` 而审阅内容已经不在——**这类缺陷只有断言到具体状态才看得见**。
    - **这一条不是运气**：第 41、42 条都是「重读自己写的代码」读出来的，本条是把那条线索形式化成一次静态扫描——脚本枚举「先改状态、后面才出现 `try`／`throw`／`guard else`」的函数，命中 12 处，逐个读源码。11 处是假阳性或已有回滚，本条是唯一一条真缺陷，而且是最重的一条。**这个扫描值得固化成 `tools/` 下的脚本**（并入 §5 第 10 条同批建议）：它的产出只有一行函数名和一行失败点，人工复核成本极低。

44. **AI 明明成功了，存盘失败却被说成「AI 没能整理」，而改动还留在内存里（第十三轮，接第 43 条查出的候选 B，真缺陷）**：第 43 条那次静态扫描同时标出了 `annotateActiveVersion()`，我先修了更重的 `acceptPendingVersion()`，把它搁在一边没回头——**这正是本报告自己写过的教训（「不再信任自己写的代码，重读代码」）的反面：一轮里发现的东西要当轮收掉**。它的形态是前一条的加强版：`versions[versionIndex]` 写入新提示、`document.updatedAt` 推进，然后 `try saveBundle()`；存盘失败落进外层 `catch`，回滚没有，消息来自 `aiFailureMessage(for:)`。三重问题：
    - **归因对象错了**：AI 调用在抛出前已经成功返回，提示算得好好的。`aiFailureMessage` 对任何非 `unsupportedStructuredOutput` 的错误统一返回「AI 暂时没能整理这份稿子……你可以重试，或直接按原文分段」。
    - **建议的动作是错的**：「重试」会让读者重跑一次**结果完全相同**的 LLM 调用，再失败一次；真正要做的是腾出磁盘空间。
    - **报告了失败却悄悄生效**：新提示留在 `versions` 里没回滚。下一次任何无关保存——改目标时长、采用候选版本、关闭舞台写进度——都会把它写进磁盘。读者被告知 AI 没成功，提示却在他不知情的时候落地了。这比一条干脆的报错难查得多。

    修复：把 `saveBundle()` 从大 `do` 里单独拎出来自带 `do`/`catch`，失败时回滚 `versions[versionIndex]` 与 `document.updatedAt` 并返回指向保存的文案（「朗读提示已经算好，但没有保存成功，稿件内容未改动。检查磁盘空间或文件夹权限后重试。」）。改完之后外层 `catch` 只可能看到 AI 错误，`aiFailureMessage` 的适用范围也就名副其实了。
    - 变异验证 2 条，全部被杀：删掉回滚（杀）、把文案换回 `aiFailureMessage`（杀）。
    - **这一条附带的元教训比缺陷本身更值钱**：回归第一次跑红时，红的是**回滚**和**文案指向**两条，而我最初写的第一条断言是「文案含『AI』」——它当场通过了，因为旧文案正好含「AI」。**断言写反了：我想表达的是「不要归因给 AI」，写成了「要含 AI」。** 如果当时不看红的是哪几行、只看到「测试通过」就收工，这条缺陷会以「已修复」的名义留在报告里，而断言会在下一次重构里变成相反的意思。**先写回归再改代码的另一个好处在这里显形：它连你的测试写得对不对一起验。**

45. **台账里有一条引用在代码里搜不到（第十三轮，审计交接文档本身）**：交接文档里每个「通过」都点名了具体回归——**这些点名就是证据指针**，接手方按引用去核是这份文档最基本的使用方式。脚本抽出 §4 台账里的 141 个标识，逐个回到 `macos/SpeechRailApp`、`tests`、`tools`、`src` 里查，**140 个命中，1 个查无此条**：`theSpeechTrialAdoptDecisionPinsRecognitionAndDurationSeparately`。实际那条测试的函数名是 `theSpeechTrialAdoptDecisionPinsBothConditionsSeparately`，`@Test` 显示名是 `the adopt decision pins recognition and duration separately`（带空格）。报告引用的是把显示名手工转成 camelCase 的第三种写法，**在代码里不存在任何一种对应形式**。已改为引用函数名。
    - **这次审计本身也犯了一个错，值得一并记**：第一版脚本只比对**函数名**，于是把这条报成缺失，同时把 4 个 `tests/test_resource_governor.py` 里的用例和 `tools/probe_teleprompter_latency.py` 里的类型名 `RealtimeProbeError` 也报成缺失——后者根本不是测试名。补上 `@Test` 显示名与扫描范围后才收敛。**同一份「缺失清单」里既有真问题也有工具的假阳性，说明任何自动化审计的输出都必须逐条查因，不能直接当结论用**——这与第 33 条「探针没跑起来却全报 KILLED」是同一个教训的两种形态：那次是**测量工具完全没运行**，这次是**测量工具口径不全**。
    - 扫描脚本与本轮的静态扫描（第 43 条）都还在 `/tmp`，固化进 `tools/` 仍需授权，见 §5 第 10 条。

46. **同一形态的第五处：「直接使用原稿」存盘失败，状态不回滚且错误被 `try?` 整个吞掉（第十三轮，真缺陷，且在成功目标的主路径上）**：修完第 43、44 条后我回头把 `TeleprompterSession.swift` 里**全部 8 个 `saveBundle()` 调用点逐个过了一遍**——这是对自己那轮修复的完整性检查。结果 `useDeterministicFallback()` 与 `acceptPendingVersion()` 形态逐行相同：append 版本、挪 `activeVersionID`、`pendingVersion = nil`、重建 `followController`、`phase = .ready`、`blocked = nil`，最后 `try saveBundle()`，**无回滚**。它比前两处更糟，因为：
    - 界面上那两个「直接使用原稿」按钮（`TeleprompterView` 两处）用的是 **`try?`**，存盘失败时**错误被整个吞掉**——用户点了没有任何反馈，也没有 `blocked` 说明；
    - 它是 **AI 不可用时的主恢复路径**，也是成功目标第一条「使用户能够直接使用原稿开讲」的落点；
    - 最要命的是 `blocked`：那两个按钮**正是 `blocked` 非空时才渲染的**。`useDeterministicFallback()` 成功时把 `blocked` 清成 nil 是对的，失败时若不放回去，**恢复按钮就从界面上消失**——用户既没有版本、也看不到出路，卡死在中间。

    修复：与 `acceptPendingVersion()` 同样在改动前存快照，`saveBundle()` 成功后置 `didPersist`，`defer` 里只在未落盘时整体回滚并 `syncFollowState()` 重算派生字段。**`invalidateAnalysis()` 刻意不进快照**——取消在途任务、推进 generation 是一次性动作，退回去会让已作废的分析结果重新生效。同时把 `TeleprompterView` 两处 `try?` 改成 `do`/`catch` 并把 `error.localizedDescription` 显示出来：状态回滚后按钮还能再按，但读者仍需要知道**这次为什么没成**，否则「按了没反应」和「按钮坏了」在他眼里没有区别。
    - 回归两条：`aStoreFailureWhileUsingTheRawScriptRollsBack`（钉住 `pendingVersion`／`versions`／`readingBlocks`／`phase` 与磁盘字节）与 `aStoreFailureKeepsTheRecoveryReason`（单独钉住 `blocked`）。**第二条是刻意拆出来的**：回滚里字段最多的就是 `blocked` 的用户价值，若只把它和别的断言混在一条里，变异删掉其中任何一行时很容易看不出是哪条在拦。
    - 变异验证 3 条，全部被杀：存盘前就置 `didPersist` 使回滚永不触发（杀，4 条断言同时红）、不恢复 `blocked`（杀）、不恢复 `readingBlocks`（杀）。
    - **一处明说的覆盖缺口**：回滚里的 `reviewItems` 同样恢复了，但标准 fixture 产不出非空的 `reviewItems`，因此**没有单独断言钉住它**。这里写出来而不是含糊过去——它是纵深防御，缺失时表现为审阅页卡片空白而非数据丢失。
    - **一处刻意不回滚、且必须留下的不对称**：`persistDraft()` 同样是「先改状态再存盘」，存盘失败时它**不回滚**，只把 `blocked` 置成 `.storeUnavailable("稿子暂时没能保存，请稍后重试。")`。这是**有意的、且不能改**：它服务的是 `createDocument` 这类路径——读者刚粘贴的脚本已经在内存里、界面上看得见，回滚等于把刚输入的内容变没，那比不落盘更糟。它的文案也**如实说明了**没有存上，不存在第 43、44 条那种「谎称原版本仍然保留」的问题。**判据是：失败时内存状态是否与用户动作一致、文案是否说实话。** 读法标注、采用候选、朗读标注、直接使用原稿这四条之所以必须回滚，是因为它们的失败文案要么撒谎（第 43、44 条）要么被吞掉（第 46 条），读者会据此以为没生效、而实际已经生效或已经丢失。
    - **可复用的结论**：修一批同类缺陷时，**必须把自己刚改过的文件里同类操作的全体调用点重扫一遍**。第 43 条的静态扫描命中 12 处时，`useDeterministicFallback()` 就在命中列表里（`L446`），我读过它、判定为假阳性就没有回头；实际上它和第 43 条是同一个缺陷。**「读过」不等于「查过」——扫描给出的每一条命中都要有一个明确的结论，哪怕结论是排除。**

47. **拒绝切稿是对的，但拒绝得没有声音：舞台开着时点另一份稿子，界面毫无反应（第十四轮，真缺陷）**：这一轮是照着验收标准逐条对证据，对到判据第 2 条「手动接管、停用或**切稿**后，旧事件不能推进」时发现切稿这一半没有对应用例。查下来**安全属性是成立的**——`load(documentID:)` 有 `guard canEdit`，而 `canEdit` 要求 `source`／`client` 为 nil，语音跟随时必然不成立，所以旧事件确实推不动新稿。问题出在**拒绝的方式**：
    - `guard canEdit else { return }` —— 不抛错、不给消息；
    - 文档行按钮**没有 `disabled` 门控**，看上去完全可点；
    - 那支 `do`／`catch` 在没有异常时执行 `operationMessage = nil`，**把提示区一并清空**。

    于是读者在舞台上开着语音时点另一份稿子：什么都没发生，提示区也空了。在 TA 眼里这和「应用卡了」没有区别。同一文件里还有第二处 `try?`（`reloadDocuments()`），那里更粗——`catch` 会把 `documents` 整个清空，若只是自动打开首份失败，读者看到的是一份空工作台加零说明。
    修复：`TeleprompterTextError` 新增 `sessionBusy`（「现在不能切换稿件：提词窗口还开着，或上一步还没收尾。先关掉提词窗口再试。」），`load` 改为抛出而不是静默返回；`reloadDocuments()` 把「列目录失败」与「自动打开首份失败」拆成两段，后者在列表仍然可用时只报消息、不清空列表。判据第 2 条的安全属性一个字没改——改的只是**让它有声音**。
    - 回归 `switchingDocumentsWhileTheStageIsLiveIsRefusedLoudly`，同时钉住「拒绝必须是干净的」：稿件、版本、阅读位置、舞台相位都不动。
    - 变异验证 2 条，全部被杀：改回 `guard canEdit else { return }`（杀）、抛一个语义不对的错误 `.emptySource`（杀）。第二条证明**类型化断言真的在校验归因**——只断言「抛了某个错」的写法在这里会全绿，而那正是第 44 条吃过亏的地方。
    - **与第 46 条同源**：都是「用户动作失败了，但界面不说」。这一族缺陷在提词器里已经出现三次（`try?` 两处、静默 `return` 一处），**都不是靠读代码发现的，而是靠「用户会怎么做」这个提问发现的**——问「读者点了这个按钮会发生什么」，比逐行读实现更容易撞上它。

48. **「重试保存」这个恢复入口永远恢复不了（第十四轮，真缺陷，本族最隐蔽的一条）**：接着第 47 条的线索把提词器里所有 `try?` 与静默 `return` 扫了一遍，绝大多数是合法的（`Task.sleep` 的取消、临时文件清理、有兜底的解析），但工作台那个按钮有问题：
    ```swift
    case .storeUnavailable:
        Button("重试保存") { try? session.save() }
    ```
    这个按钮出现的**前提就是上次存盘失败了**。读者腾出磁盘空间后按下它，`save()` 确实成功了——但 `blocked` **仍然是 `.storeUnavailable`**：横幅继续写着「稿件保存失败」，按钮也还在。再点多少次结果都一样，读者只能去找旁边的 ✕ 手动关掉。**一个叫「重试保存」的按钮，成功之后仍然宣称保存失败**，这是本族里最伤的一条：应用在断言一件已经不成立的事，而且把唯一的恢复入口也堵死了。
    根因很轻：`persistDraft()` 一直有 `if case .storeUnavailable = blocked { blocked = nil }`（本文件 3245 行），**只有显式 `save()` 漏了这一行**。两个函数做同一件事，一个清了另一个没清。
    修复：`save()` 成功后补上同一行，并把按钮的 `try?` 换成 `do`／`catch`——重试再次失败时读者刚腾出空间、看不到结果就只会以为按钮坏了。
    - 回归 `aSuccessfulExplicitSaveClearsTheStoreFailure`：只读目录下新建稿件进入失败态 → 恢复权限 → `save()` 成功 → 断言 `blocked` 不再是 `.storeUnavailable`。
    - 变异验证 1 条，被杀：删掉 `save()` 里那行清除（杀）。
    - **发现方式值得单独记**：不是读代码读出来的，是**问「读者点了这个按钮，接下来会看到什么」**问出来的。逐行读 `save()` 只会看到三行、一次 `try`、一个 `throw`，完全正常。**判断一个失败路径是否成立，要问界面在成功和失败两条路上分别显示什么，而不是只看函数做了什么。**

49. **存盘失败时「复制稿件内容」点了没有任何反应（第十四轮，本族第四处）**：接着第 48 条把「读者点了会怎样」这个问法用到文档菜单上。「复制稿件内容」的实现是 `if let markdown = session.exportMarkdown() { … }`——`exportMarkdown()` 在任何 store 失败时都返回 nil，于是**既没有复制、也没有提示**。而这恰恰是第 48 条那个状态下的常态：存盘失败时文档只在内存里、不在 store 里，`exportMarkdown()` 与 `exportSourceData()` 双双为 nil。
    对照两条导出路径：导出原稿有 `?? Data(doc.sourceText.utf8)`，导出朗读稿有 `?? doc.sourceText`，**只有复制这条没有兜底**。三个平级动作里两个有、一个没有，读者偏偏撞上没用的那个。
    修复：会话层新增 `copyableDocumentText()`，`exportMarkdown() ?? document.sourceText`，只在根本没有文档时才返回 nil；界面改用它，并在那一支显式给出「还没有可复制的稿件内容。」。读者因此在任何时候都能把稿子拿走——**这恰恰是存盘失败时最该有的能力**。
    - 变异验证 1 条，被杀：去掉兜底、退回 `return exportMarkdown()`（杀）。
    - **这一条没有走「先写失败回归」流程，理由如实记下**：缺陷在视图层，而当时的会话层没有任何对应接口，所以「先红」拿不到——先写的那条断言实际写成了 `exportMarkdown() ?? sourceText == source`，**今天就会通过**，是一个假绿。改成先加接口再补测试，并用变异探针（删掉兜底）证明测试确实有牙齿。**这比假装走了先红流程更诚实**：第 44 条已经吃过「断言写反却以为通过」的亏（§2 第 44 条），这里同一类错误差点再犯一次，是靠「先红拿不到就不硬凑」这个判断拦住的。
    - **本族小结（第 46–49 条共四处）**：两处 `try?`、一处静默 `return`、一处无兜底的 `if let`。**共同点是代码本身全都正常**——每处单独读都挑不出毛病，因为缺陷不在函数里，在「界面在成功和失败两条路上分别显示什么」这个跨越函数与视图的问题上。

50. **把「静默拒绝」这一族横扫到底：删除稿子时，读者在确认框点了「删除」却什么都没发生（第十四轮，真缺陷）**：既然第 47–49 条的同一个问法连中三次，就把会话层里所有 `guard canEdit else { return }` 一次列全——**共七处**，`load` 已修（第 47 条），剩下六处全是静默。
    最刺眼的是 `deleteDocument`：读者点删除、**在确认框里点了「删除」**、然后什么都没发生，界面那支 `do`／`catch` 还会把 `operationMessage` 清成 nil。**破坏性操作上的「确认之后静默」，比干脆没有这个按钮更让人不安**——读者会以为是自己点错了，或者应用崩了。
    修复（只动已经是 `throws` 的两处，零签名变更）：`deleteDocument` 与 `useDeterministicFallback` 的守卫改为抛 `TeleprompterTextError.sessionBusy`。
    - 回归 `deletingWhileTheStageIsLiveIsRefusedLoudly`，并钉住「拒绝必须是干净的」：稿件不动、舞台相位不下滑。
    - 变异验证 1 条，被杀：`deleteDocument` 恢复成两个静默 `return`（杀）。
    - **剩下四处为什么这一轮没改，写明白**：两处编辑器（`updateTitle`／`updateSourceText`）在界面上**已经有** `.disabled(!session.canEdit)`——同文件里的既有做法，读者得到的是灰显而不是静默，那两处守卫只是纵深防御，**不是缺陷**。真正剩下的是 `createDocument` 的两个重载与 `discardPendingVersion`，它们的按钮散在 6 个视图里（顶栏 `PageActionsMenu`、卡片菜单、内联选择器、空状态、模板卡片），**全都没有 `disabled` 门控**，属于同一族。**这一轮没有改，理由是**：改法本身有争议（灰显按钮 vs. 点击后给消息），而判断哪种对只能靠 U-10 界面走查——按 AGENTS.md，那需要用户逐次授权，在没有授权的情况下改 6 处视图等于把一个**未验证的视觉判断**写进代码。**这一条作为已知跟进项交给承接团队，并入 §5 第 1 条的 U-10 走查清单。**
    - **本族最终统计（第 46–50 条共五处）**：两处 `try?`、两处静默 `return`、一处无兜底的 `if let`。共同点依旧是**代码本身全都正常**，缺陷不在函数里，在「界面在成功和失败两条路上分别显示什么」这个跨越函数与视图的问题上。这也是为什么前四条里有一条必须靠变异探针而不是「先红」来证明——有些缺陷根本不在可单测的那一层。

51. **舞台开着时导入文件，界面谎报「已导入」（第十五轮，本族最坏的一条）**：把第 50 条列出的六个静默入口逐个问「读者点了会怎样」，问到 `importFromURL` 时停住了。它的实现是：`try TeleprompterSourceImporter.load(from: url)` → `session.createDocument(title:importedSource:)` → **无条件**设 `operationMessage = "已导入「…」"`。而 `createDocument` 的两个重载都是 `guard canEdit else { return }`。于是舞台开着时导入文件：**什么都没导入，界面却显示「已导入」**。
    这比第 47、50 条的静默更坏：静默至少不骗人，虚假成功消息则让读者**以为稿子已经换好了**，随后在旧稿上继续练习——一段本来该跳过的新稿变成了跟错内容，而且没有任何迹象能让他发现。
    修复（把「导入」整条链改成有声音，零调用点签名变更）：
    - `createDocument(title:importedSource:)` 由静默 `return` 改为 `throws`，拒绝时抛 `TeleprompterTextError.sessionBusy`。两个调用方（`createDocumentValidated`、`importFromURL`）本来就在 `do`／`catch` 里，不需要改结构。
    - `createDocumentValidated` 顶部也加同一道守卫，**顺序在导入之前**：舞台开着时「正在解析内容」是次要事实，读者需要先知道的是现在不能换稿。
    - 视图侧 `importFromURL` 的调用点补 `try`。
    - 回归 `importingWhileTheStageIsLiveFailsLoudly`，并钉住「拒绝必须是干净的」：稿件不变、舞台相位不下滑。
    - **先红如实记录**：本条**拿到了先红**。临时把两个源文件退回 HEAD、只留新测试，`#expect(throws:)` 报 `an error was expected but none was thrown`——正是 `guard canEdit else { return }` 的静默 return；恢复修复版后通过。这与第 49 条不同（那条缺陷在视图层、拿不到先红），本条缺陷同时落在会话层，因此走完了完整流程。
    - 变异验证 1 条，被杀：把 `createDocument(title:importedSource:)` 的守卫改回静默 `return`（杀）。
    - **六个「新建」按钮同时补了 `.disabled(!session.canEdit)`**（顶栏 `PageActionsMenu`、空状态主按钮、模板卡片、卡片菜单、空状态次按钮、拖放提示区）。依据不是审美判断，而是**同文件既有做法**：标题与正文编辑器早已用这个模式，读者得到的是灰显而不是静默。第 50 条把这一族留作「等 U-10 走查再定」，本轮把它按既有约定统一了——灰显与否是视觉判断，**是否与同文件既有约定一致**不是。
    - **刻意没改的一处**：视图在 `case .analyzing, .preparing` 分支显示的「取消整理」按钮**不能**加 `.disabled(!session.canEdit)`。它是「取消正在进行的 AI 整理」，而 `prepareDraft` 只设 `phase = .analyzing`、不动 `isTightening`／`isAnnotating`，所以 `.analyzing` 期间 `canEdit` 为 true、取消本该可用；灰显它会直接破坏取消功能。但由此暴露一个**真缺陷留给 U-10**：`.preparing` 是语音启动瞬态（`canEdit` 为 false），该分支此时也显示「取消整理」，点了静默无效，且标签与场景不符。**本轮只记录不改**——它需要授权走查才能确认正确形态。

52. **一条完全停住的跟随路径，会被回放报告成一场干净结果（第十七轮，真缺陷，且直接违反验收第 4 条）**：验收第 4 条写着「**不以全部停住换取安全**」。`TeleprompterReplayEvaluator` 的 `caveats` 专门处理「0 这个数字有两种完全不同的含义」——注释写得很清楚：
    > Every safety number below is derived from human labels, so a zero has two very different meanings: "the system did not do this" or "the material never asked". Publishing the second as the first is how a frozen follow path gets reported as a clean run.

    原来那几条 caveat 覆盖的是**「素材没问」**（缺 `improvise` 标注、缺 `expected_segment_index` 标注、回稿超时、无标注事件、停顿、误推进）。**「素材问了、系统却一次没动」这一种没有覆盖。** 而且它比缺标注更危险，因为缺标注那几条正好会触发：

    | 报告读数 | 实际情况 |
    |---|---|
    | 0 次严重误推进 | 跟随从没动过 |
    | 0 次错误停顿 | 事件间隔压在 3 秒阈值以内 |
    | 延迟分位 `null` | 一个样本都没有 |
    | **caveat 数 = 0** | 两条「素材没问」都不成立，标注是齐的 |

    也就是说，一条**冻住的跟随路径**可以拿着一份「零误跳、零停顿、无警告」的报告去验收，而这份报告每个数字都是真的——只是它们一起描述的是「什么都没发生」。这正是那句注释警告的事。

    修复（`TeleprompterReplayEvaluator`）：
    - `Metrics` 新增 `advancedEventCount`，统计**实际把阅读位置往前推的事件数**，并写进报告 JSON 的 `advanced_event_count`。这是让「0 次误推进」可读的那个分母。
    - 新增 caveat：推进数为 0 且样本数大于 0 时，明确写出「0 次严重误推进只说明跟随没有动过，不表示跟随可用」。
    - 回归 `aFollowPathThatNeverAdvancesIsNotReportedAsACleanRun`（**先红**：修之前该测试的 caveat 断言直接落空），并钉住前置——两条「素材没问」确实都不触发、误推进确实是 0、延迟分位确实是 `null`，否则这条断言说明不了问题。
    - 同时补了**反向**断言。变异探针有一条「零推进 caveat 无条件触发」**存活**，查因发现：我先前看着 `reportStaysQuietWhenBothDetectorsAreExercised` 通过就说「新 caveat 没误伤正常回放」——**这个结论是错的**。那条测试只断言了「没有某两条 caveat」，**根本没断言 caveat 为空**，多余 caveat 照样能过。已给它补上「正常跟上的回放不得报零推进」和「推进计数不能是 0」。**「该报警时才报」和「不该报警时不报」是两件事，原来只钉了前者。**
    - 变异 4 条全部被杀：删掉零推进 caveat（杀）、不再统计推进事件数（杀）、零推进 caveat 无条件触发（杀）、零推进判断忽略样本数（杀）。
    - 最后一条的查因值得单记：`evaluate` 只挡空稿子、**不挡空事件**，所以「0/0 个事件」真实可达。去掉 `sampleCount > 0` 守卫后空素材会报「跟随一次都没有推进（0/0）」，而**当时没有任何测试能杀掉这个变异**。已把空事件素材写进回归。

53. **「回稿恢复 P95」这个质量门槛没测过的时候，报告不说（第十七轮，第 52 条的同族下一层）**：方案 §11.7 把回稿恢复 P95 与连续跟随 P95 并列为质量门槛。素材全程直读、一次没脱稿时：`reanchor_latency_p50/p95` 是 `null`、`reanchor_timeout_count` 是 0，**而没有任何 caveat 解释这件事**。于是「回稿恢复 P95 = null」和「回稿恢复 P95 = 0ms」在报告里长得一样——前者是没测，后者是极好。验收人引用这个门槛时会以为测过了。
    修复：按**分位本身有没有样本**判断，而不是按标签存在性。
    - 回归 `aRunWithoutAnyDetourSaysTheRecoveryGateWasNeverMeasured`（先红）。
    - 变异 3 条全部被杀：删掉该 caveat（杀）、该 caveat 无条件触发（杀）、**用「有没有 `reRead` 标注」当判据（杀）**。

    **这一条我自己先写错了，被既有回归当场抓住，值得单独记**：第一版按「素材里有没有 `reRead` 标注」判断，而 `reanchorLatencyIsMeasuredFromTheDetour` 的素材**一条 `reRead` 都没有，却量出了 1_100ms 恢复延迟**——因为恢复样本来自 `reanchorStartedAt`，`improvise` 事件在没有推进时也会设它。也就是说标签存在性是个**错误的代理**，真判据是分位有没有样本。
    这条能被抓到，靠的是既有回归里恰好有一份「无 `reRead` 标注但有恢复样本」的素材。**如果那条回归当初用的是纯直读素材，这个错会一路活到验收。** 变异探针里专门放了一条「用 reRead 标签存在性当判据」，确认它会被既有脱稿回归杀掉——探针不只用来证明新测试有牙齿，也用来钉住**实现依据的判据本身**。

### 2.4 验收标准逐条证据审计（第十八轮）

不再问「还有没有缺陷」，改问一个更基础的问题：**验收标准里写的每一句，证据够不够**。逐条过完，结果如下。

| 验收条 | 结论 | 说明 |
|---|---|---|
| 1 稿件可信 | 证据充分 | 数值／单位／正负号／重复内容、主体关系与限定条件、有损精简单独授权与删减展示，各有具名回归（`subjectValueSwapIsRejectedByHardGateAndKeepsSource`、`droppingANumberSignIsRejectedByTheHardGate`、`protectedLiteralExtractorPreservesOccurrencesAndUnicodeBoundaries`、`semanticRiskBecomesReviewItems`、`condenseCreatesDeletionReviewItems` 等） |
| 2 跟随可控 | 证据充分 | `partialMovesProvisionallyAndFinalReplacesIt`、`stableHypothesisPrefixLimitsPreviewToProvenText`、`rereadDoesNotRollBackAcrossDistantParagraphs`、`revisedSnapshotCannotMoveBackWithinTheCurrentSegment`、`eventsAfterManualTakeoverCannotMovePosition` |
| 3 体验与数据安全 | **本轮补齐两处缺口** | 「字号、列宽变化保持位置」此前只钉了两个预设取值 → §2.2 补全值域扫描；「迁移失败保留原数据」此前**零回归** → §2.3 补齐。其余各项（手动阅读兜底、设备异常、关闭释放资源）本就有回归 |
| 4 证据可信 | **台账成立，但真实时延基线仍未执行** | 台账复核：69 项编号唯一、无重复、**每项都有状态且都有证据引用**（65 通过／3 部分／1 未执行）。4 项非通过与 §5 已知缺口一一对应：U-07 无障碍、U-10 窗口走查、R-04 真实拔插、R-07 内存上限。本轮另修掉两处「报告在数字为真时沉默」→ §2 第 52、53 条 |
| 5 交付完整 | 成立 | 回归、契约与文档、回退说明、阶段报告齐全；真实音频／UI／发布三项授权分别独立，未执行项均如实标注 |

**台账复核的可复现口径**（供承接方重跑）：表头在 `## 4. 69 项场景台账` 与 `### 4.1` 之间；每行首格是「编号 + 标题」（如 `P-02 数值被改写`），第二格是状态，第三格是证据。

**这一轮的方法教训值得单记**：用关键词扫测试显示名来估覆盖率，**连续错了三次**——先用中文词（测试名是英文，全 0 命中）、改英文词（漏掉大量用 `@Test func name()` 无显示名的用例）、再改成搜函数名（才发现 `#104`／`106`／`107` 的回归一直都在）。前两次的错误结论都是「这条验收项零覆盖」，而真实情况是覆盖很扎实。**扫描工具的口径必须先验证它能不能找到已知存在的东西，再拿它下「不存在」的结论**；这与第 45 条是同一个错误的两种形态。收尾时改用直接读函数名，一次就看清了。

### 2.5 「五个质量门槛是否都有对应指标」（第十八轮，含一条排除）

第 52、53 条都是「指标在、但沉默」。防的是相反的形态：**指标根本不存在**。把方案 §11.7 的五个门槛逐个对进 `TeleprompterReplayEvaluator.Metrics`：

| §11.7 门槛 | 对应指标 | 结论 |
|---|---|---|
| 无歧义连续跟随 P95 | `trackingLatencyP50/P95` | 有指标、有「无定位标注」告警 |
| 附近回稿恢复 P95 | `reanchorLatencyP50/P95` | 有指标；第十八轮补上「没有样本」告警（第 53 条） |
| 正常朗读错误停滞 < 1% | `stalledEventCount` + 告警带分母 | 满足方案「标明分母」的判定方式 |
| 严重误推进零事件 | `harmfulJumpCount` + `advancedEventCount` | 第十八轮补上零推进告警（第 52 条） |
| **正常手动操作 P95 ≤ 100 ms** | **无** | **排除，不是缺陷** |

最后一行的查法值得记：评估器里确实**没有任何手动操作延迟的测量**（全仓搜 `manualLatency`／`inputLatency` 等命名，零命中）。但这**不构成「静默」**——本报告 §3.2 早就写明「方案 §11.7 的**全部**质量门槛——连续跟随 P95、回稿恢复 P95、**手动操作 P95**、错误停滞比例、严重误推进发生率——当前均为未验证」。而且这个门槛的判定方式是「目标设备，输入到正确画面」，本质是界面响应测量，**本来就不属于确定性回放的范围**，它属于 U-10 走查与真实设备测量。**声明已经在、归属也正确，所以排除。**

顺带记一个**观察，不是缺陷**：用合成素材跑正常跟随时 `tracking_latency_p50_ms` 是 `0`。查下来是素材本身造成的——标注 `read/expected=1` 落在跟随跨入第 1 段的**同一个事件**上，度量窗口开与关在同一瞬间。真实素材里人的「开始读第 1 段」应当早于跟随确认，不会有系统性 0。另外第 0 段不产生延迟样本（跟随初始就在第 0 段，没有「追赶」可测），这是正确行为。**记录下来是为了让承接方看到 0 时知道该先查素材还是先查代码。**

54. **改内容范围会静默清掉读者已经逐条审阅完的工作（第十九轮，真缺陷）**：把「问读者点了这个会怎样」用到前几轮没扫过的三个 sheet 上，第一个就中。
    入口在 `quickToolsGroup` 的「选择范围」按钮，它在 `workbenchInspectorStrip` → `unifiedWorkbench` 里，而 `editor()` 的条件是 `session.document != nil` —— **不看阶段**。也就是说，审阅页（`.review`，读者正在逐条处理 AI 建议）点得到它。
    确认后的动作是 `session.updateContentSelection(...)`，它当时**不抛错**：
    ```swift
    self.contentSelection = selection
    if pendingVersion != nil || !readingBlocks.isEmpty {
        invalidateAnalysis(); pendingVersion = nil; reviewItems = []; readingBlocks = []
    }
    ```
    作废分段本身是对的——按旧范围算出来的分段对新范围无效。问题是它连同**读者已经处理完的审阅**一起清掉，**没有确认、没有消息**，而这份工作是**不可重做**的：要做回来得重新跑一次 AI、再从头审一遍。第 43 条之后，这是链路上最后一份不可重做的工作。
    修复沿用第 43 条那套「拒绝要有声音」的形态，但**不是回滚而是先问一句**——改范围本身是合法操作，读者想要就能改：
    - `TeleprompterTextError` 新增 `reviewDecisionsWouldBeDiscarded`，文案写明后果与「确认要继续吗」；
    - 会话层新增 `hasReviewDecisionsAtRisk`（`pendingVersion != nil && reviewItems.contains(isResolved)`）；`updateContentSelection` 改为 `throws`，有风险时拒绝且**不动任何状态**；
    - 确认路径单独命名为 `applyContentSelectionAfterConfirmation`，读起来就带着「这一步会丢东西」；
    - sheet 捕获该错误弹确认框，其余错误也必须出声（第一版这里我写了 `session.lastVoiceStopFailure = nil`，毫无意义，等于把错误吞回去——同一族缺陷在我自己的新代码里当场出现，已改）。
    三条回归：`changingContentRangeRefusesToDiscardReviewWorkSilently`、`changingContentRangeIsPlainWithoutReviewWork`、`adoptingTheCandidateEndsTheReviewLossRisk`。变异 **7 条全部被杀**，无存活无作废。
    **先红是编译失败**（新 API 尚不存在），不是断言失败——如实记下，与第 49、53 条的先红形态不同。

55. **回放报告不说明「这份素材根本没人看过」（第二十八轮，真缺陷，且是第 52、53 条的同族最上一层）**：素材工具在没人逐条确认标注时会给 `dataset_revision` 加 `-draft` 后缀，人工确认后才去掉。**报告此前只解释「素材没问某个问题」和「系统一次没动」，没有任何一条解释「所有标注都还不是证据」**。于是一份机器草稿只要标注恰好齐全、指标恰好全真，读起来与一次人工确认过的测量完全一样。
    **不是推演，是实测撞出来的**：这一轮补齐了 §3.2 里唯一没有工具覆盖的一环——录音（`ffmpeg -f avfoundation -i ":0" -ar 24000 -ac 1 -c:a pcm_s16le`，产出 pcm_s16le／24 kHz／单声道，正是探针要求的格式），录了 5.4 秒环境声喂给 `tools/build_teleprompter_replay_manifest.py`。结果是**识别器对静音照样吐出 7 个事件，每个都带两字文本**，工具照样把它们全标成 `read`，其中一条还拿到了机器笃定的 `expected_segment_index: 0`。人工确认清单把 6 条标成「对齐不足，读者位置未知」——**安全网在工作**，但它只标存疑项，那条笃定的没进去。
    修复前先写失败回归，当场复现：这份素材跑出来的 `caveats` 是 `[]`。修复按第 52、53 条的既定做法，**只加 caveat、不改 `teleprompter.eval.v1` schema**：`datasetRevision` 以 `-draft` 结尾时，在**最前面**加一条「本次素材是未经人工确认的机器草稿……本报告的数字不能作为质量结论」。放在最前面是刻意的——下面几条解释的都是「这份素材没问什么」，草稿的问题更靠前。
    回归两条，第二条是**反向对照**：`unreviewedDraftDatasetSaysSoEvenWhenEveryOtherCaveatStaysSilent`（前置条件先断言这份 fixture 的其他 caveat 全部沉默，否则草稿声明会被别的缺口顶出来，测试恒真）与 `reviewedDatasetKeepsTheSilenceItEarned`（去掉后缀必须恢复安静，否则这条 caveat 变成常开噪音，真出问题时反被忽略）。变异 **4 条有效全部被杀**（去掉整块、无条件常开、把 `hasSuffix` 写成 `hasPrefix`、用空串判定），另有 1 条作废（替换后编译不过，不计入）。修完用同一份真实素材复跑，4 条 caveat 里草稿声明排在第一条。
    **这一条的边界要说清**：它挡的是「拿机器草稿当验收」，**挡不住拿标注齐全但标错的素材**。第 52、53 条与本条加起来覆盖的是「没问」和「没确认」，不是「标错了」——`reRead` 与 `improvise` 标错仍然会算错分母，那只能靠人对音频。这正是 §11.5 要求人工核验的原因。

56. **对齐器的重投递路径凭空给自己打满分，一段噪声因此拿到阅读位置（第二十九轮，真缺陷，与第 55 条同一场实测的两层）**：第 55 条那轮录 5.4 秒环境声，识别器对静音照样吐出 7 个事件、每个都带两字文本。人工确认清单拦下 6 条，**第 7 条没进去**——它带着机器笃定的 `expected_segment_index: 0`。查下来是 `ScriptAligner.align()` 的重投递分支：

    ```python
    return Alignment(self.index.segment_of(self.high_water), INTENT_READ, 1.0)
    ```

    它只看「这段文字与上一个事件重叠」，**从不把文字拿回稿件里核对**，却直接报 1.0。而识别器在无语音时恰会连续吐同一段幻觉，两条一撞就满足条件。
    **这与工具 docstring 明写的承诺直接矛盾**：「Low confidence yields `read` with no reading position」——低对齐度确实不给位置，但这条路径**绕过对齐度直接发位置**。而阅读位置正是延迟样本的来源：评估器拿它开 `readWindowStart`，没有位置就没有样本，有位置就有。**一段纯噪声因此能向验收人提供一个跟随延迟数字。**
    修法保持最小：重投递路径只负责「不重复推进、不误判成回读」，**不负责给置信度**。改为照样过一遍 `_best_match`，低于阈值就不给位置。既有重投递回归用的文本本来就在稿件里，打分自然仍过阈值，行为不变。
    失败回归先写，当场复现 `Alignment(segment_index=0, intent='read', ratio=1.0)`。变异 **4 条全部被杀**（恢复 1.0、去掉阈值守卫、阈值放到 0、反转守卫）。噪声复验：同类输入 7 条标注**全部不再带** `expected_segment_index`，人工确认清单从 6/7 变成 **7/7**。
    **噪声只能证明「路径存在」，真实语音才能证明「影响多大」**，所以又用 §3.1.1 那份 41 秒素材重跑了整条链。同一份 WAV、同一个服务、同一个 82 事件，修复前后：

    | 指标 | 修复前（已复核的 b2） | 修复后（b3） |
    |---|---|---|
    | 拿到阅读位置的标注 | 71 / 82 | **64 / 82** |
    | 人工确认清单条数 | 20 / 82 | **31 / 82** |
    | **错误停顿次数** | **16** | **12** |
    | 跟随延迟 P50 | 3009 ms | 2995 ms |
    | 跟随延迟 P95 | 11008 ms | 10993 ms |

    逐条比对，7 条差异**全部同向**（原来有位置、现在没有），而且**成对出现**——idx 16/18、42/44/46/48、72——这正是重投递的签名：delta 与 revisioned hypothesis 把同一段文字送来两遍，第一条正常匹配给了位置，第二条走重投递分支又重复一次。
    **停顿数少了四分之一，而延迟分位只动了 14 ms**——说明这一条修掉的正是那些**由虚假位置撑起来的停顿计数**。方案 §11.7 把「正常朗读错误停滞比例」列为质量门槛，而门槛读的正是这个数：**修复前这个门槛被工具自己的缺陷抬高了 25%**。
    顺带一个真实数据上的旁证：b2 是上一轮**人工逐条复核过**的素材，但它的 `dataset_revision` 仍带 `-draft` 后缀（工具只在 `--confirm-reviewed` 时才去掉，手工复核不会改这个字符串）。所以第 55 条那条新 caveat 在 b3 上排在第一条，在 b2 上同样会正确触发——**「复核过」与「被标记为已确认」是两件事，报告信的是后者**。这正是当初把这条 caveat 放在第一位、而不去判断标注内容对错的原因。

57. **回放报告的失败占比用「次数」除以「事件数」——恢复失败拖得越久，评分反而越好（第三十轮，真缺陷，与第 52 条同一层问题的第 3 段）**：方案 §11.6 写的是「若失败样本超过 5%，不能仅对成功子集给一个看似达标的 P95」。实现照做了阈值，却没对齐单位：`failureShare = failedSampleCount / manifest.events.count`，分母是**事件数**，而分子 `failedSampleCount = terminalFailureCount + reanchorTimeoutCount` 里两项都不是事件数——`terminalFailureCount` 逐事件加，`reanchorTimeoutCount` 在循环**结束后只 `+= 1` 一次**。两个后果，都实测复现：

    - **同一次未恢复，拖尾越长占比越低**。探针固定「一次脱稿未回稿」，只改后面拖尾事件的数量：7 个事件时 `failure_share` 是 **14.3%**（超过 5% 门槛），42 个事件时是 **2.3%**（不超门槛）。**方向是反的**：跟随越长时间没回来，这份报告越像一次合格验收。
    - **中途恢复一次，之前真实发生过的超时被整个抹掉**。构造「脱稿 5 秒 → 回稿 → 再脱稿 5 秒 → 再回稿」，报告给出 `reanchor_timeout_count: 0`、`failed_sample_count: 0`——两次各 5 秒的未恢复在报告里不存在。这正是 §11.6「超时算失败，不删除样本」被违反的那一句。

    根因不是阈值取错，是**分子分母不同单位**。修法也不改阈值、不改 `teleprompter.eval.v1` schema：分子改成**按事件计**（终态失败事件，加上未恢复窗口开启后的每一个事件），超时次数改用 latch 逐次结算（窗口关闭时结算一次，跑到素材末尾仍未关闭的也结算）；顺带把「错误停顿门槛」和「回稿窗口 deadline」解耦——两者共用一个变量时，回稿期间的真实停顿会被一个尚未到期的 deadline 挡住。详见 §2.15。

58. **零严重误推进时报告完全沉默，把 41 秒素材读成了一次安全结论（第三十一轮，真缺陷，与第 52 条同一层的第 4 段）**：方案 §11.6 的指标表在「严重误推进」一栏写着「按事件数与运行时长报告」，§11.7 的判定方式一栏写着「同时报总时长，**不声称真实发生率为零**」，紧接着第 1115 行直接给了算法：「『8 小时观察到零严重事件』不能证明真实误跳率为零……零事件的 95% 上界约为 `3 / 总小时数`；8 小时约为 0.375 次／小时」。

    实现的 caveat 是这样的：

    ```swift
    if metrics.harmfulJumpCount > 0 {
        caveats.append("严重误推进 \(metrics.harmfulJumpCount) 次，总时长 \(durationMilliseconds) ms。")
    }
    ```

    **只在 > 0 时说话**。于是 0 次时报告给出一份干净的安全结论，而按方案自己给的算法，那份 41 秒素材能支撑的上界是 **263 次／小时**——**素材越短，证据越弱，报告读起来却越可信**。这与第 52 条（零推进报成干净结果）、第 53 条（恢复门槛未测报成 0ms）是同一族：一项检测没被触发时，报告必须说「没触发」而不是「没问题」。

    修法：`harmfulJumpCount == 0` 且素材时长 > 0 时，按 `3 / 观测小时数` 输出 95% 上界，并写明该数字只提醒样本边界、不作为产品性能宣称。真的观测到事件时不输出——那时候该报的是次数。代价是**报告不再有「完全沉默」这个状态**，两条既有反向对照（第 53、55 条）因此改了断言，见 §2.16。

### 2.6 第十九轮扫了舞台与三个 sheet（含三条排除）

前十八轮的扫描集中在会话层、工作台和评估器，**舞台与三个 sheet 一直是盲区**。这一轮补上，同样逐条记录结论——排除也是结论。

| 命中 | 结论 |
|---|---|
| `TeleprompterStageWindow.windowWillClose` 的 `guard session.beginStageClose() else { return }` | **排除**。`beginStageClose()` 只在两种情况返回 false：已有关闭在进行中（那次会调 `finishStageClose`），或压根没有资源要释放（`!isStageOpen && 状态 == .off && source == nil && client == nil`）。且这是 NSWindowDelegate 回调，窗口无论如何都会关，不会把用户困住 |
| 试读 sheet「采用这次试读」里的 `guard … != nil else { return }` | **排除**。按钮**只在证据可采纳时渲染**（`isAdoptable` 且时长足够），注释写明「否则按钮不出现，而不是按下去再告诉用户」。里面的 guard 是渲染与点击之间状态变化的纵深防御 |
| 试读 sheet「采用此校准」 | **排除**。`applyTrialCalibration` 不抛错且对 k 做钳制，按钮永远可用 |
| 内容选择 sheet「确定本次范围」 | **真缺陷**，见第 54 条 |

被这一轮排除的三条都不是「读错了」，而是**代码里已经写明了为什么这么做**——这与第 50 条那批「注释很自信但其实没兜住」不同。判据是：有没有一条**用户可触发、且失败后界面不说**的路径。

### 2.7 第二十轮：完成度审计（未发现新缺陷，两条经核实的排除）

这一轮换问法：不再找新缺陷，而是问「§2.4 那张验收对照表里，每一行的**证据**是否真的支撑它的**结论**」——凡是只有间接、跨表或过宽证据支撑的，去代码里核实。目的是在交接前把「凭据不足」清零。结果：**没有发现新缺陷**，但把两处此前只被间接覆盖的面用直接证据钉死，并确认报告自身对键盘可达性的描述准确。

| 核实点 | 结论 |
|---|---|
| 读法标注的**回滚保真度**（`confirmReading` 存盘失败路径） | **排除**。`removeConfirmedReading` 用整体还原 `original`，`confirmReading` 却在失败时用辅助函数 `version(at:withSegmentAt:acceptedReadings:)` **重建**版本——两者不对称。核到底：该函数把 `TeleprompterVersion` 的**全部 6 个**存储属性（`id`/`documentID`/`sourceText`/`segments`/`analysisSource`/`createdAt`）逐一转发，无任何字段被初始化器重置，故重建与还原等价、回滚忠实。`saveBundle` 走 `atomicWrite`（先写临时文件再 `replaceItemAt`），抛出即代表未落盘，内存回滚后与磁盘一致。**这一条专门写下来，是为了让接手方不必再怀疑这个不对称** |
| 导出／复制路径的静默失败 | **排除**。`exportDataDocument` 的 `try data.write` 有 `do`/`catch` 并给出「导出失败：」；`exportMarkdown()`、`exportSourceData()` 两条导出与 `copyableDocumentText()`（第 49 条新增的兜底）都保证「存盘失败时仍能把稿子拿走」。与 §2 第 48、49 条的修复一致，无新缺口 |
| 验收第 3 条「常用操作键盘可达」的现状描述是否准确 | **准确，无新增**。实测：舞台有 12 组 `onKeyPress`（含 Space/方向键/PgUp/PgDn/Home/End/Esc/Tab）＋ ⌘`=`/`-`/`0`/`[`/`]` 调字号，**工作台只有 ⌘⏎ 一个**；新建／导入／打开舞台／手动接管／重试保存／采用候选版本**全部无键位**，纯键盘完成依赖系统「键盘导航」开关（默认关闭）。这与 U-07 行「键盘侧零证据」**逐字吻合**，是已知且已正确记录的缺口，不是新缺陷 |

三条都指向同一件事：**本轮没有可提交的产品改动**。第 43 条那条通用教训在这里再次生效——「已覆盖」要有直接证据，不能靠「上一轮说它覆盖了」。而验收第 3 条的键盘子项、验收第 4 条的真实时延基线，仍分别锁在 U-10 走查与 #83 真实音频这两道**逐次授权**后面（见 §3.2），本轮未触碰、也未以任何方式绕过。

### 2.8 第二十一轮：给「手动接管」补上常驻菜单快捷键 `⌘⌥V`

§2.7 把验收第 3 条的键盘子项核实清楚了：**它是一项明文要求，而现状是这些高频操作没有任何键位**。这一轮不再只停在描述上——目标本身就是授权，而补齐它的代价只有一行。

**为什么选常驻菜单命令，而不是给按钮挂 `.keyboardShortcut`**。先否掉了我自己的一个顾虑：曾以为按钮是条件渲染（`switch blocked` 的四个变体、`.review` 才出现的「采用」、`.following` 才出现的「关闭语音跟随」），给条件渲染的按钮挂快捷键会「有时候可达」——但**这在语义上其实是对的**：动作只在对应状态可用，读者不该在非审阅态按到「采用」、在舞台没开时按到「停用语音」。真正该担心的是**键位冲突与系统开关依赖**，而常驻菜单命令恰好两者都躲开：

- **不依赖渲染**：`CommandMenu("提词器")`（`App.swift`）本来就常驻，直接持有 `teleprompter` 与 `teleprompterStage`，不随工作台某个分支出现或消失；
- **不依赖系统开关**：菜单命令由系统这一侧派发，不需要按钮进焦点链，因此**绕开了系统「键盘导航／全键盘访问」默认关闭**这个坑——那正是报告里「键盘可达与不可达只差这一个开关」的根源；
- **处理器已经写好**：`handleVoiceAssistCommand()` 覆盖开启／关闭／`stopFailed` 重试／`pausedByUser` 恢复，`.disabled(!isVisible || isBusy)` 的禁用态也已在。缺的只是键位。

**选 `⌘⌥V`（Voice）的冲突分析**（这是本轮唯一需要判断的地方，因此写下来）：全仓已占用 `⌘1–⌘0`（路由 `AppRoute.shortcutSpec`）、`⇧⌘T/M/D/H`（路由）、`⌘N/E/R`、`⌥⌘I`、`⇧⌘L`、`⇧⌘.`、`⌘⌥←/→`（本菜单行导航）、`⌘Esc`（关提词器），舞台内另有 `⌘=/-/0/[/]`。系统保留的 `⌘C/V/X`（文本编辑）必须让位。`⌘⌥V` 与既有 `⌘⌥←/→` 同族好记，全仓与系统均未占用。

**它关掉的是走查清单里被点名的一条**：§5 第 1 条写着「停用语音／手动接管——**这是「随时手动接管」这条成功目标的入口，不能只能点**」。现在它在纯键盘下可达了。

**证据边界（如实记）**：改动只有一行，`scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED**——这是该改动的唯一编译门禁，因为 SwiftPM 既不编译 `App.swift` 也不编译视图层，而单测 target 无 `TEST_HOST`、同样不编译 App 入口。**没有做任何单测**，因为没有测试断言命令菜单结构，而 `handleVoiceAssistCommand` 背后的会话层行为（`disableVoiceAssist`／`retryStopVoiceAssist`／`enableVoiceAssist`）一行未改、其回归仍在。**真实按键未验证**：`⌘⌥V` 实际按下是否触发、菜单项禁用态与快捷键是否一致，仍属 U-10 走查——这一条只把「不可达」变成「已接线且编译通过」，不宣称走查通过。

### 2.9 第二十二轮：给「采用候选版本」补上 `⌘⏎`（审阅相位主操作）

接着 §2.8 把走查清单里另一条点名的「必须键盘可达」补上：**「采用候选版本」——不可重做的一步**。

**这一条比 ⌘⌥V 难，难在两处，都查清了才动手**：

- **不能做成菜单命令**。`acceptPendingVersion` 那条按钮处理器是 `try session.acceptPendingVersion(); operationMessage = nil; reloadDocuments()`，而 `reloadDocuments()` 会 `documents = try session.listDocuments()` 刷新侧栏（含 `updatedAt`）。`documents` 是**视图本地 `@State`**，菜单命令（`SpeechRailCommands`）够不着它。若菜单命令只调 `acceptPendingVersion()`，侧栏的 `updatedAt` 会停在旧值——给一个不可逆动作造出**第二份、少一步的实现**，正是 `App.swift` 注释里点名要避免的「同一件事两处实现」。**结论：快捷键必须挂在按钮上，复用完整处理器。**
- **键位不是新造，是「各相位主操作」**。`⌘⏎` 已被「整理朗读稿」占用，但它在 `case .draft`；accept 在 `case .review`。两者**互斥**，同一相位只会注册一个 `⌘⏎`：草稿按 `⌘⏎`=整理，审阅按 `⌘⏎`=采用。这是上下文相关主操作的常见形态，不引入新键、不与任何系统键冲突。

**顺带发现一个既存问题（本轮只记录、不重构）**：accept 按钮在代码里有**两份、处理器逐字相同**——`workbenchReviewContent` 内一处（`TeleprompterView` 1879）、`workbenchBottomDock` 的 `case .review` 一处（2255）。审阅相位两者可能同屏。**同屏挂两个 `⌘⏎` 会冲突，因此只给常驻底座那一个挂快捷键**；读者在任一相位按 `⌘⏎` 触发的都是同一个动作，行为无差异。重复本身属可清理项，但拆它要动审阅页布局，超出本轮「补键盘可达」的范围。

**证据边界（如实记）**：`scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED**。**未加单测**——SwiftPM 不编译 `TeleprompterView.swift`，无 `TEST_HOST` 的单测 target 同样不编译视图层，这一行没有任何测试能覆盖；`acceptPendingVersion` 的会话层行为一行未改、其既有回归仍在。**这次多了一个真实风险**：给 accept 标签新增了可见的 `ButtonShortcutHint("⌘⏎")`（沿用「整理朗读稿」的既有模式），**这是一个未经走查的视觉变化**——按钮在窄底座里加上快捷键提示后是否仍不折行、是否与 `.primary` 样式协调，都要 U-10 看一眼。真实按键同样未验证。

### 2.10 第二十三轮：查规格后**决定不再加快捷键**（一次以「不加」为结论的审查）

连着两轮都在加键位，这一轮先去找权威来源——提词器舞台规格（`docs/superpowers/specs/2026-09-24-teleprompter-manual-first-design.md`）对键盘本来就有明确规定。结果是**继续加会违背规格**，因此本轮的结论是「到此为止」。这类「查了之后决定不做」的记录和「查了之后做了」同样重要，否则接手方会以为还能继续往里塞快捷键。

规格的键盘模型是**「核心走菜单快捷键 + 其余走 Tab 聚焦」**，三条硬约束：

- **第 93 行**：菜单栏提供与舞台同源的「上一行／下一行／**语音跟随**／显示设置／关闭」命令，且**不重复实现 Session 状态逻辑**——即语音跟随**本来就该是菜单命令**，不是按钮快捷键。
- **第 101 行**：「本期**不添加额外语音快捷键**，避免占用新的全局或单字母键；键盘用户通过**菜单或 Tab 聚焦按钮**开启。」——其余操作在规格里**本来就该走 Tab**，不是缺快捷键。
- **第 216 行**：`App.swift` 增加「提词器」应用菜单命令，**不把快捷键绑到零尺寸透明按钮**。

**核对结论**：`CommandMenu("提词器")` 已规格齐全——第 93 行点名的五条（上一行 ⌘⌥←、下一行 ⌘⌥→、语音跟随、显示设置、关闭 ⌘Esc）**全部在位**，另有一条「打开提词器」。**没有结构缺口。** 因此「打开提词器／重试保存／复制稿件内容／新建／导入」这些我上两轮想继续加键的，**按规格都该走 Tab 而非新增快捷键**——继续加会违背第 101 行的克制原则。**本轮不加任何快捷键。**

**必须诚实记录的一处张力**：`⌘⌥V`（§2.8）按第 101 行**字面**属于「额外语音快捷键」。加它的理由是：① 它是**菜单命令**快捷键，正是第 93／216 行指定的机制，且非全局热键、非单字母键——正是第 101 行要防的那一类；② 第 101 行的规约写于 2026-09-24，而其后的验收标准第 3 条明文要求「常用操作键盘可达」，且走查清单点名手动接管「不能只能点」。**两者有张力，此处不假装一致**；若接手方或产品认为应严格回到第 101 行、只留 Tab 路径，回退方式是把 §2.8 那一行 `.keyboardShortcut("v", …)` 与其注释删掉，语音跟随仍可经菜单与 Tab 使用，功能不丢。`⌘⏎`（§2.9）则无此问题：它是**可见按钮 + 可见 `ButtonShortcutHint`**，与工作台既有的「整理朗读稿 ⌘⏎」同一模式，不违反第 216 行针对的「零尺寸透明按钮」反模式。

**剩下的真问题不是工程，是产品与设置**：Tab 路径依赖系统「键盘导航／全键盘访问」开关（默认关闭），这正是报告反复记的那一处。把它变成开箱即用，要么改系统默认（越界），要么给每个操作都配快捷键（违背第 101 行）。**这是一个需要产品拍板取舍的点，不是我能单方面决定的**，已并入 §5 第 1 条走查与本节。

### 2.11 第二十六轮：把「人工誊写」换成工具，并修掉模板里一处会**静默失真**的 `kind`

第二十五轮查出的那道人工工序已补上：新增 `tools/build_teleprompter_replay_manifest.py`。它按真实
100 ms 节奏推流、录下整条 Realtime 事件流，拿冻结稿件做单调对齐，产出 `events[]` 与一版 `labels[]`
草稿加人工确认清单；省略 `--script` 则只落原始采集结果。

**为什么新增工具而不改探针**：探针文件头写明它 never writes transcript text, item IDs, event IDs
——那是刻意的隐私设计，而探针结果是要长期留存、会被引用与比较的证据，让它顺手落一份完整转写等于
把转写塞进证据文件。服务端 `/metrics` 同样只有聚合计数。所以解法只能是独立的素材工具。

本轮同时查出**模板一处会静默失真的错误**（第一版模板，不是代码缺陷）：
`speechrail.transcription.hypothesis` 被标成了 `partial`。回放器把 `partial` 映射为
`.partial(itemID:delta:)`——**增量语义，`revision` 与 `stable_prefix_codepoints` 被直接丢弃**；
而线上真实发的是「整句已修订的快照」，对应 `snapshot` → `partialSnapshot(revision:text:evidence:)`。
写错的后果**不是解码失败，而是回放照样跑得出来、却少了一整类推进判定**。已修正文档并写明理由。

三条不许它越界的线：

1. **产物一律出仓库**：输出路径解析后落在检出目录内直接拒绝；stdout／stderr 不打印任何转写文本。
2. **草稿不冒充已确认**：不给 `--confirm-reviewed` 时 `dataset_revision` 被强制加 `-draft` 后缀，
   机器存疑的条目全部列进 review 清单，**只给事件下标，不给文本**。
3. **机器不发明 `improvise`**。这条最要紧：回放器把「`improvise` 且系统发生推进」直接计成
   **严重误推进**（`harmful_jump_count`）。若机器仅因文本对不上就断言脱稿，等于**凭空制造它本该
   测量的那个安全数字**。因此低对齐度只得到「`read` + 位置未知 + 进人工清单」，`improvise` 只能
   由人写。`reRead` 同样收紧到「非重复投递、且明显落在已读位置之后」的片段。

**第二轮：用 41 秒、含回稿重读与脱稿的素材再验一次，抓到三个前一句连续朗读照不出来的坑。**
第一轮的端到端证据只有一句 4 秒的连续朗读。「能不能跟住长朗读」这件事，它根本没测到。改用本机
TTS 按材料 B 合成 41 秒素材（**仅验证工具，不是质量集**）后暴露：

- **累计事件必须按尾部打分。** hypothesis 每次修订都重发整句，读到十几秒时开头早已落在搜索
  窗口之外；仍拿「整句开头」当锚点会让**每个匹配都被拒（ratio 0.00）、游标彻底冻结**——
  报告里位置一路停在第 2 段，而读者已经读到最后一段。改为只对末尾 24 字打分。
- **锚点被幻听前缀打断时要能兜底。** 锚点扫描一无所获时，在游标附近窄带内再做一次无锚点扫描。
- **改锚点位置比不改更糟。** 曾试把锚点挪到片段末尾以贴近「最新内容」，游标彻底不动：
  SequenceMatcher 是把整个 needle 对齐到窗口的，锚点不在开头其余部分就失去约束。已回退。

修正后同一素材：**82 个事件里 71 个拿到位置、最终落在最后一段、位置回退 0 次**（修正前 67 个，
且从 13 秒起冻结）。同时验证了三条护栏在长素材上依然成立：**82 条标注全部是 `read`，没有一个
被断言成 `improvise`**；脱稿句得到的是「位置留空 + 进人工清单」；位置单调不回退。
回放报告写出「错误停顿 16 次，分母为样本 82」——**这正是方案要求的不带分母不报数**。

**两条能力边界（已写进基准文档，接手方必须先读）**：

1. `reRead` 只能抓到**逐字重说**。材料 B 的「等一下，我刚才说的是七点」是**语义回读**——说新词、
   重复旧内容，在文本流上与正常前进无法区分，**必须由人对照音频标注**。
2. 稿件写「四十分钟」而引擎输出「40分钟」时对齐度会掉到阈值以下；工具的处理是**留空并进清单**，
   不是硬凑位置。数字密集的材料 A 要预留更多人工确认量。
   **并且这里试过「中文数字改写」并按实测放弃了**：直觉上该把「四十分钟」归一化成「40分钟」，
   实测**净负**——41 秒素材上能定位的事件从 71 掉到 61（调整「点」的规则后 63），因为引擎会吐出
   「的，五一」这类**数字状噪声**，改写把它变成「51」，原本能匹配的块反而消失；而且随附的三份
   稿件本来就是阿拉伯数字（材料 A 写「50 瓦」「2999 元」「负 20」），改写没有收益可赚。
   **只保留符号折叠**（`负 20` → `-20`）：只紧跟数字触发，风险极低，而材料 A 恰有这类写法。

对齐口径踩到两个坑，都留了回归（`tests/test_teleprompter_replay_manifest.py`）：

- ① 只取**最长**匹配块打分，会让「整句已确认 + 尾部新增」的快照看起来像脱稿——真实采集里
  ratio 掉到 **0.07**。必须**所有匹配块累加**。
- ② 重复投递（hypothesis 与它的 delta 携带同样文字）曾被判成**回读**，一轮跑出 3 个假 `reRead`。
  必须先按**紧邻的上一条**去重；且不能拿整段累计文本去比，否则真回读会被吞掉。

### 2.12 第二十七轮：把缺陷族扫描首次扩到 **Python 服务侧**（结论：未发现新缺陷）

第 41–54 条那一族（先改状态、后面才出现失败而失败不回滚）此前**只在 Swift 侧扫过**——第十三轮的
静态脚本命中的是 `TeleprompterSession.swift` 12 处。而提词器跟随所依赖的事件**源头在 Python**：
hypothesis 的修订号、稳定前缀、utterance 生命周期都由 `application/realtime_openai.py` 生成。
**这一侧此前没有被同一口径审过。** 本轮补上。

**先自证扫描口径**（这一步本身失败过一次，值得记）：第一版扫描器把「回滚了」的样例也报成命中，
因为它只在 `raise` 的表达式里找属性名，而回滚通常是 raise **之前**的一条语句。修正为
「mutation 与其后的第一个退出点之间，是否存在针对同一容器的恢复操作（重新赋值／pop／clear／
remove）」，并植入两个对照样例（一个该报、一个该不报、一个回滚、一个无退出路径），
四种情形全部分类正确后才拿去扫真实代码。**口径没自证就解读「零命中」，等于什么都没说。**

结果：`application/realtime_openai.py` 32 条线索，`compatibility/openai_realtime.py` 0 条。
**逐条读过的部分（跟随路径）全部是良性的**：

| 线索 | 读出来的结论 |
|---|---|
| `_drain_asr_events` 6 条（`_hypothesis_revision`、`_stable_prefix_codepoints` 等先改后发） | 退出点是 `except asyncio.CancelledError: raise`，会话正在终止；且 `_last_hypothesis_text` 在**发送成功之后**才推进。不构成缺陷 |
| delta 分支「`_last_partial_text` 先推进再发 delta，且**忽略返回值**」 | **一度以为是真缺陷**。查 `SendEvent = Callable[..., Awaitable[int \| None]]` 与 transport 实现：返回 `None` **只发生在已断开**（`disconnected = True`）。客户端已经不在，缺一个 delta 无人察觉，**假阳性** |
| `_ensure_diarization`（`_ledger`/`_diarization` 先赋值后 `start()`） | **恰恰是回滚写得对的那一处**：`except BaseException: await self._release_diarization(); raise`。扫描器不认识这种回滚形式 |
| `_commit_audio_once` 4 条 | 「设好新 `_current_item_id` 后正常返回」的正常路径 |
| `_append_audio` 的 `_input_generation` 先自增再 `buffer_too_large` | 客户端违约的硬拒绝，会话随即拆掉；计数与时间戳描述的都是「客户端确实发了东西」，回滚反而会失真 |
| `_finish_alignment` 的 `_metadata_revision` 先自增 | 取消只造成序号跳空，客户端下一次收到的是**完整**单元集，不损坏内容 |
| `_send_diarization_updates` 的 `_speaker_by_unit` 先写 | 它是缓存而非已发布状态，`metadata_revision` 在空 payload 时并未自增，下次成功更新会带上它，无信息丢失 |

**覆盖边界（如实记下）**：32 条里我逐条读过的是**跟随路径**那几组
（`_drain_asr_events`、`_commit_audio_once`、`_append_audio` 的拒绝分支、`_finish_alignment`、
`_ensure_diarization`、`_send_diarization_updates`）。**未逐条读的是 TTS 流式那几组**
（`_on_stream_event`、`_settle_stream_terminal`、`_finalize_tts`）——提词器不走 TTS，
不在本轮范围内。**因此本轮结论是「跟随路径未发现新缺陷」，不是「整个 Python 侧干净」。**

方法上补一条：这一族在 Python 侧的形态与 Swift 不同——Swift 里回滚通常是显式赋值，
Python 里更常见的是「调用一个不点名的清理函数」（`_release_diarization`），
按属性名找回滚的扫描器**必然漏报**。所以扫描器在这里只能当线索来源。

### 2.13 第二十八轮：把缺陷族扫描扩到 **Swift 视图层**（结论：未发现新缺陷）

第 41–54 条那一族此前扫过 Swift 会话层（`TeleprompterSession.swift` 12 处，§2.1）与 Python 跟随路径（§2.12）。**视图层与 sheet 从未被同一口径审过**，而它恰好是证据最弱的一层：第二十一／二十二轮已经写明 `TeleprompterView.swift` 与 `App.swift` 既不被 SwiftPM 也不被无 `TEST_HOST` 的单测 target 编译，那两轮改动只有一条 Debug 构建证据。本轮补上。

**判据先自证，而且失败了三次**（与 §2.12 同一纪律，但这次错得更贵）：

| 版本 | 自证样例 | 失败原因 |
|---|---|---|
| 1 | 6 例 | 「用重新赋值回滚」那一例判成命中：识别器只认 `removeAll`／`remove` 方法式 → 假阳性 |
| 2 | 6 例 | 两例的恢复写在 `do { try … } catch { 恢复; throw }` **同一行**，判据只扫两行之间的区间 → 假阳性 |
| 3 | 8 例 | 「按清空回滚」那一例把恢复写在失败点**之后**（语义上不可达）——这次是**样例**写错；顺势补上「只在失败前恢复过、之后又改一次」的反例 |
| 4 | 11 例 | 通过 |

第 4 版另外修掉一个更严重的漏报源：函数体按花括号深度跟踪且**在声明处起算**。此前一见到含 `}` 的行就判定函数结束，而 `do { … } catch { … }` 单行净深度为 0——等于每个 do／catch 之后的代码全部落到函数外。「单行 do／catch 之后仍有可报语句」与「嵌套闭包里的改动仍归属外层函数」这两例专门盯这一条。

**第 5 版修的是精度不是判据**：`try?` 与 `try!` 不会「让状态悬在半路然后继续」，把它们算作失败点纯属制造发现。去掉之后 `TeleprompterStageView.swift` 14 → **0**、`TeleprompterTrialReadingSheet.swift` 6 → **0**——这两个文件的命中**全部**由 `try?` 造成（例如 `startTimer` 里的 `try? await Task.sleep`，实读该函数根本没有 `throws`）。这一条值得单独记：**扫描器把语言自身的错误处理语法当成了缺陷证据**。

11 例自证全部通过后扫 6 个视图与 sheet 文件，共 23 条候选，**逐条读过，没有第 41–54 条的同族**：

| 文件 | 候选 | 读出来的结论 |
|---|---|---|
| `TeleprompterView.swift` | 19 | 9 条 `operationMessage =` 是错误呈现通道本身，§2.1 已逐条判过 46 处同类赋值、只有第 51 条走错分支；4 条 `savePanel.*` 是文件面板配置，在 `begin` 之前赋值，用户取消不影响稿件；`requestReadingCues` 的 `pendingAIAction` 只被紧邻其后的 alert 确认按钮读到，取消走 SwiftUI 双向绑定，读不到陈旧值。**单独读过的是 `reloadDocuments` 的 `documents = []`**：列表**读**失败时清空视图列表并同时给出 `operationMessage`。这与目标里「迁移失败保留原数据」不是同一件事——那是写路径，这是读路径，且 `session.listDocuments()` 抛错并不改动 store，原稿与已确认版本不受影响。`restorePreferredSpeechLanguage` 写的是持久字段，但来源是 UserDefaults 的清洗值、本身无失败点，属**函数归属误判**（见下方边界） |
| `TeleprompterContentSelectionSheet.swift` | 2 | `applySelection` 的两个分支分别喂给两个 `.alert`：`reviewDecisionsWouldBeDiscarded` 走确认弹层，其余拒绝走「没能改范围」弹层并渲染 `failureMessage`。确认弹层内再失败时 `failureMessage` 仍有弹层呈现且取消可用，不存在静默 |
| `TeleprompterStageWindow.swift` | 2 | `requestLineNavigation` 是「设值 + 换 UUID 触发观察」的成对写法，且该函数**没有任何失败点**——命中同样来自函数归属误判 |
| `TeleprompterStageView.swift` | 0 | 修正 `try?` 精度后归零 |
| `TeleprompterTrialReadingSheet.swift` | 0 | 同上 |
| `TeleprompterReadingAliasSheet.swift` | 0 | 首次扫描即零命中 |

**覆盖边界（如实记下）**：23 条候选全部读过，但**函数归属是启发式的**——深度跟踪不区分 `init`、计算属性与顶层代码，因此会把后续函数的 `try` 归到前一个函数名下（上述两处误判即由此而来）。这意味着**「零命中」比「有命中」更不可信**：扫描器可能因为找不到 `try` 而漏掉整段函数。因此本轮结论是「已逐条读过的 23 条里没有同族缺陷」，**不是「视图层干净」**。视图层真正的证据缺口仍是编译与运行，那属于 U-10，本轮没有改变这一点。

### 2.14 第二十九轮续：目标第 1 条的**向前**那一向此前一条用例都没有（不是缺陷，是证据缺口）

第 41–54 条那一族之外还有一类不同的问题：**实现本来就在，证据一条都没有**。§2.3 记过一次（「迁移失败保留原数据」），本轮又撞上一处，而且正落在成功目标第 1 条上。

「远处短语不得擅自跨句跳转」此前只钉住了**向后**那一向——`rereadRollsBackOnlyWhenTheBackwardMatchIsStrong` 与 `distantFullSentenceCannotDragTheViewportBackwards` 测的都是回退。**向前没有用例**，而 `mayAdvance` 的四道门禁里有两道从未被任何测试碰过：`localAdvanceTokenRadius` 与 `provisionalMinimumMatches` 在整个测试目录里都是零命中。计划 §11.7 把「旧 generation／手动接管：零越权推进」列为门槛，台账 F-04 也只挂了一条距离约 100 个 token 的用例。

补两条：

| 用例 | 补的是什么 |
|---|---|
| `aDistantForwardPhraseCannotDragTheViewportAhead` | 距离 **30** 个 token 的四字短语（刚好在默认半径 24 之外），断言视口与 `committedPosition` 都不动。既有 F-04 用例距离约 100，且只断言 `position`，**没有钉住已确认位置不被改写** |
| `aLoneStrayTokenMatchDoesNotMoveTheViewport` | **单个 token** 在距锚点 10 处（落在局部半径内、近锚窗口外）。置信满分、位置唯一，**只有 token 数这道门禁拦得住**——而这道门禁此前无人验证。这是误听一个杂音的最现实形态 |

**写这两条用例时踩了两个坑，都写进了注释，因为它们会让用例「因为错误的原因通过」**，值得留给接手方：

1. `localAdvanceTokenRadius` 是**绝对** token 数（默认 24）。三段玩具脚本只有 46 个 token，半径几乎覆盖整篇——**测出来的是口径不是性质**。第一版夹具因此直接失败（视口从第 1 段跳到第 3 段），看起来像发现了缺陷，其实是夹具写坏了。
2. 两段用同一句 filler 填充，**重复跨度让匹配变歧义**，锚点根本没建立。此时「视口没动」是因为压根没匹配上，不是因为远处短语被拦。这种通过毫无意义，却会让变异验证**误报存活**（半径放宽到 40 都不翻面）。

因此两条用例都先断言锚点真的建立（`followState == .tracking` 且位置已推进），再断言远处短语没推动它；前者还额外断言 `lastMatchConfidence == 1.0` 与 `lastMatchedCount == 4`——要证明的是「**匹配成功但不许跳**」，不是「没匹配上所以没跳」。

变异 **4 条全部被杀**：去掉半径检查、半径放宽到 100000、半径放宽到 40、`strongMatch` 去掉 `matchedCount` 合取项。前三条两条用例一起验；第四条只有单 token 那条能杀——**对半径外的短语，半径检查支配结果，去掉 `matchedCount` 是结构等价变异**，这一条不计入杀数。`swift test` **279 项 / 16 套件**通过。

### 2.15 第三十轮：核实目标第 4 条点名的「失败分母」（第 57 条）

§2.14 结束时有件挂着的事：**验收标准第 4 条点名的「失败样本」到底怎么算，一直没有核实过**。此前几轮补的是「失败样本、超时、恢复延迟这些字段存在且有 caveat」（第 52、53 条），没人问过**这些字段算得对不对**。本轮去查，查出一条真缺陷。

**怎么查出来的**：先读代码定位到 `TeleprompterReplayEvaluator.swift` 的三行——

```swift
if let deadline = reanchorDeadline, let last = manifest.events.last {
    if last.atMilliseconds >= deadline { metrics.reanchorTimeoutCount += 1 }
}
let failedSampleCount = metrics.terminalFailureCount + metrics.reanchorTimeoutCount
metrics.failureShare = Double(failedSampleCount) / Double(manifest.events.count)
```

循环**结束后**才判断一次、`+= 1` 一次，然后拿它去除**事件总数**。两个问题当场就成立：**分子分母不是同一个单位**，以及**只有最后一个窗口有机会被结算**。再用探针把第一条量化（固定一次未恢复，只改拖尾长度）：

| 拖尾事件数 | 事件总数 | `reanchor_timeout_count` | `failure_share` | 超过 5% 门槛 |
|---|---|---|---|---|
| 0 | 2 | 0 | 0 | 否 |
| 8 | 10 | 0 | 0 | 否 |
| 18 | 20 | 0 | 0 | 否 |
| 38 | 40 | 1 | 2.5% | 否 |

最后一行是**最坏的一种通过**：跟随已经整整 30 秒没回稿，报告给出的失败占比是 2.5%，门槛判定「不超」。**恢复失败拖得越久，评分越好**——这不是阈值取宽了，是计分方向反了。

**修法**（不改阈值、不改 schema，只改「什么算一个失败样本」）：

1. 分子改成**按事件计**：`failedSampleCount` = 终态失败事件数 + 未恢复窗口开启之后的每一个事件。分子分母同为事件，拖尾变长时分子跟着涨，占比只会更高。
2. `reanchor_timeout_count` 改用 latch：窗口一旦越过 deadline 就置位，窗口关闭时结算一次，**跑到素材末尾仍未关闭的也结算**。修复前「跟随彻底没回来」恰好是唯一报 0 次的情形。
3. `stallGateDeadline` 与 `reanchorDeadline` **解耦**。原来「错误停顿」和「回稿窗口」共用一个 deadline：跟随还在脱稿期间发生的真实停顿，会被那个尚未到期的回稿 deadline 整个挡住，§11.7 的错误停滞比例因此被系统性低估。

配套把两条 caveat 改成写明单位：`失败样本占比 X（N/M 个事件）`、`回稿恢复超时 N 次；未恢复窗口内的 N 个事件按失败样本计入`。

**本轮自己踩了一次「拆变量」的老坑，值得单独记**：把停顿门槛从回稿 deadline 上摘下来之后，41 秒真实素材的错误停顿从 **12 掉到 11**。原因是旧代码里「回稿恢复成功」会清空那个**共用**的 deadline，副作用之一是顺手重置了停顿门槛；拆开之后 `stallGateDeadline` 活了下来，**一个在旧停顿之前就打开的读窗口**会被旧门槛挡住。修法是让 `endReanchorWindow()` 一并释放门槛，并补 `aRecoveryReleasesTheStallGateForWindowsOpenedEarlier` 钉住。

**这一条是单测抓不到的**：全绿的 283 项测试当时也没有报错，只有把修复前后两份报告**逐个指标对比**才看得出来（`stalled_event_count` 12 → 11）。前几轮每轮都跑 CLI 端到端（见 §3.1「回放 CLI 契约复核」），本轮头一次觉得「这份素材没有 improvise 标注、失败计数必然是 0」而略过了对比——**恰好是这份素材让失败相关的改动看起来毫无影响，也就最容易把副作用藏进去**。因此本轮把那条纪律写死：**改动评估器时，真实素材的前后逐指标对比不是可选步骤，哪怕预期是「零差异」**。

**变异验证 5 条全部被杀**：去掉逐事件 latch、窗口关闭时不结算次数、分子改回「次数」、停顿门槛复用回稿 deadline、恢复时不再释放停顿门槛。其中**第 4 条首轮存活**——它是本轮新引入的解耦，没有用例覆盖；补 `aStallDuringAnUnrecoveredReanchorWindowStillCounts` 后转杀。这条存活本身是本轮的一个结论：**新写的解耦如果不配用例，下一轮就没人知道它是对的**。

`swift test` **283 项 / 16 套件**通过（新增 4 条）。修复前后 CLI 各跑一次 41 秒真实素材（82 事件），**逐指标对比零差异**——这份素材没有 improvise 标注也没有终态失败，失败计数修复前后都是 0，所以它能证明的是**这次改动没有动到正常路径的数字**，不能证明失败分母在真人素材上落到了某个区间。

**这一条没有验证到什么**：修复前后的数字全部来自**构造素材**，没有在真人朗读素材上重跑过——那需要 #83 的录音与人工标注（§3.2）。所以能确定的是「**同样的未恢复，拖尾越长占比越高**」这条计分规则已经成立；**不能**据此声称真人素材上的失败占比落在某个区间。

### 2.16 第三十一轮：零误推进时报告该说的那句话（第 58 条）

第 57 条修完失败分母，验收第 4 条里还剩一个词没落实：**「同步报告误推进」**。第 52 条补的是「零推进不能报成干净结果」，第 57 条补的是失败分母，都没碰「零误推进」本身。

**怎么查出来的**：把方案 §11.6 指标表、§11.7 质量门槛表和第 1115 行那三段话，逐条对到报告字段上。§11.6「严重误推进」一栏的防止自欺约束是「按事件数与运行时长报告」——报告确实有 `harmful_jump_count` 和 `duration_seconds`，这一半成立。但 §11.7 判定方式一栏写的是「同时报总时长，**不声称真实发生率为零**」，第 1115 行还直接给了算法。而实现的 caveat 是 `if metrics.harmfulJumpCount > 0 { … }`——**只在 > 0 时说话**。0 次时报告什么都不说，`harmful_jump_count: 0` 单独躺在 JSON 里，读者只能理解成「安全」。

**修法**：`harmfulJumpCount == 0` 且素材时长 > 0 时，输出按 `3 / 观测小时数` 算的 95% 上界，并写明它只提醒样本边界、不作为产品性能宣称。真的观测到事件时不输出这条——那时候该报的是次数与总时长，上界是废话。

真实素材上立刻见效（41 秒素材，修复前后各跑一次 CLI）：

| | 修复前 | 修复后 |
|---|---|---|
| `metrics` 全字段 | — | **零差异** |
| caveat 条数 | 4 | 5 |
| 新增的那条 | — | 「零事件不等于零发生率……95% 上界约为 **263 次／小时**」 |

**263 次／小时** 就是这份素材能支撑的全部。§11.7「严重误推进：对抗回归零事件；保留集观察零事件」这条门槛，在只有 41 秒素材时根本不该被引用——此前报告不这么说。

**这一轮动了前几轮自己立的断言，如实记下来**。`reanchorLatencyIsMeasuredFromTheDetour` 与 `reviewedDatasetKeepsTheSilenceItEarned` 原本断言 `caveats.isEmpty`／「除草稿声明外无其他 caveat」，那是第 53、55 条刻意立的**反向对照**（caveat 不能常开成噪音）。新 caveat 破了这条性质。处理方式不是删断言换绿灯，而是把断言收窄到它当初要守的东西：

| 用例 | 原断言 | 改后 | 为什么这么改 |
|---|---|---|---|
| `reanchorLatencyIsMeasuredFromTheDetour` | `caveats.isEmpty` | 不含「回稿／恢复」类 caveat | 它守的是「恢复延迟量到了就别再报警」，不是「报告必须全静」 |
| `reviewedDatasetKeepsTheSilenceItEarned` | 无草稿声明 | 无草稿声明，且**剩下的只有样本上界** | 它守的是第 55 条的反向对照；顺手把「报告不再完全沉默」写进断言，免得下一轮有人以为它还是全静的 |
| `unreviewedDraftDatasetSaysSoEvenWhenEveryOtherCaveatStaysSilent` | 除草稿声明外全静 | 除草稿声明与样本上界外全静 | 同上，隔离性仍保留：再多一条 caveat 它就红 |

**「caveat 不能常开成噪音」这条原则本身没有被推翻**，但它和「零观测必须报样本边界」冲突时**后者赢**——因为前者防的是「真出问题时被忽略」，而这条 caveat 的数字随时长变化、不是固定噪音。可复用的判据：**一条 caveat 如果在所有素材上字面完全相同，它才是噪音；随素材变化的数字不是。**

变异 **5 条全部被杀**：删掉整条 caveat、把上界写成常数 1、假设观测了 8 小时、只对长素材输出、让它在已观测到误推进时也输出。其中一条**首轮作废**：`let hours = 8` 让 `hours` 推成 `Int`，`.rounded()` 编译不过——那是**探针缺陷不是杀**，按第 27、33 条的规矩不计入，改成 `8.0` 后才是有效变异并被杀掉。

`swift test` **285 项 / 16 套件**通过（新增 2 条）。真实素材修复前后 `metrics` 逐字段零差异，只多了一条 caveat。

### 2.1 第十五轮的扫描覆盖与**排除**结论

第 51 条是扫出来的，不是读出来的。为了让接手方知道这一轮**查过什么、排除过什么**（否则下一轮会重复查同一批地方），逐条记录如下。**排除也是结论**——第 46 条的教训正是「命中过、读过、判为假阳性、没回头」，而它和第 43 条是同一个缺陷。

| 扫描维度 | 命中 | 结论 |
|---|---|---|
| 会话层全部 `guard … else { return }` | 5 处公开入口 | 2 处编辑器（`updateTitle`／`updateSourceText`）**排除**：视图已有 `.disabled`，守卫只是纵深防御。3 处（`analyzeDraft`／`condenseDraft`／`discardPendingVersion`）**排除**：前两者的按钮在 `.draft` 分支已带 `!session.canEdit` 门控，后者只出现在 `canEdit` 恒为 true 的 phase。其余为越界／代数／生命周期守卫，非用户可触发的拒绝 |
| 全部 `try saveBundle()` 调用点 | 8 处 | **全部排除**：接受候选与丢弃候选两处有回滚并重新抛出，读法别名增删与朗读标注有 `do`／`catch`，运行态保存写 `lastFailure`，`save()` 是第 48 条已修的那处，`persistDraft()` 是定义处。**没有发现第 43 条的同族** |
| 全部 `operationMessage =` 赋值 | 46 处 | 逐条判「成功／失败是否走对分支」。**只有第 51 条走错**。`tightenReadingBlocks` 与 `annotateActiveVersion` 的 `nil` 返回**排除**：两者对每种拒绝都返回明确文案，不会让视图误报成功 |
| `lastFailure` 是否是只写不读的死状态 | 1 处疑似 | **排除**：`TeleprompterStageView.swift` 三处消费它并弹错误提示 |
| 导出路径 `exportDataDocument` | 1 处 | **排除**：`try data.write` 有 `do`／`catch`，失败给「导出失败：」 |
| 「恢复默认语速」`applyTrialCalibration` | 1 处 | **排除**：`scheduleDraftSave` → `persistDraft` 会设 `blocked = .storeUnavailable`，横幅可见 |

**这一轮没有找到第 52 条**。但按第 50 条的教训，如实写下边界：以上是**这几个维度的实际覆盖范围**，不等于全仓无遗漏——本轮**没有**重扫台账的具名证据引用（那套脚本仍在 `/tmp`，见 §5 第 10 条），也**没有**触及提词器五个文件以外的其他会话类（`AssistantSession`／`MeetingSession`／`CaptionSession` 有各自的 `lastFailure` 与 `storeUnavailable` 机制，未纳入本轮范围）。

### 2.2 第十六轮：补齐验收第 3 条的证据（不是缺陷，是**证据缺口**）

第十五轮扫的是「有没有缺陷」。第十六轮换了个问题：**验收标准里写的每一句，证据够不够**。逐句过第 3 条时发现一处缺口——「字号、列宽变化保持位置」只有 `columnWidthChangesPreserveReadingPosition` 一条回归，而它只钉了 camera 与 podium **两个预设取值**。两个点能过，不等于整条范围都成立：快捷缩放按钮和列宽滑杆给的是连续值域，读者随时可以停在中间任何一格。

补的回归 `fontScaleAndColumnWidthSweepPreservesPositionAndText`：字号扫 0.67–1.52（步长 0.05）× 列宽扫 360–1200（步长 40）＝ **119 组值域**，每组三段混排文本（纯中文／中英混排／含代理对 emoji）各取段首、段中、段尾三个位置，断言位置不丢、不漂。**它一次就通过了**——机制本身是稳的，但此前没有证据能证明它稳。

**写这条回归时犯过一次错，值得记下来**：第一版的「不丢字」断言写的是 `lines.map(\.text).joined() == sources.joined()`。加上结尾换行那段文本后变红，两边字符串在输出里**看起来一模一样**却不相等。没有猜，直接写了一条一次性诊断测试打印码点：源码 11 个 UTF-16 单位、结尾 U+000A；行的区间是 `[0, 11)`——**正确覆盖了换行符**；而行的 `text` 是 10 个单位，**刻意不含换行**。`displayRange` 就是干这个的：区间覆盖源码，显示文本不渲染控制字符。**是断言写错了，不是代码写错。** 改成正确的不变量——**区间并集无缺口无重叠地覆盖全文**，含换行的文本也成立；不含换行的三段仍保留更强的显示文本逐字相等断言。

**变异验证 5 条，全部被杀**：摘掉「落在某一行内」查找（杀）、重排时吞掉一个 UTF-16 单位（杀）、行区间整体左移一位（杀）、行区间不递进（杀）、段尾夹取被摘掉（杀，**由既有那条 `displayLineIndexClampsOffsetsPastTheSegmentEnd` 杀掉**，本扫描只管段内偏移，覆盖边界是真实的）。探针带基线自检。

**一次测量错误，如实记**：查尾行兜底分支是否执行时，我把 `print` 插在了 `if nextUTF16Start < sourceLength` 的**外面**，数到 1584 次命中，差点据此认定「分支在跑、只是杀不死」。把 print 挪进 `if` 内部后是 **0 次**。随后用 12 段候选文本 × 3 档列宽 × 3 档字号共 108 组去构造触发条件，全部行区间连续、没有缺口——**这条兜底分支在本机复现不出触发条件**。它在 `TeleprompterStageLineLayout` 里是纵深防御，代码注释说它防的是「TextKit 省掉尾部空行片段」。因此那条变异**没有被判为等价**，而是记为「触发条件未复现」：分支若真的触发，吞掉尾行会丢正文，这是真实风险，只是本机测不到。**这是本轮唯一没有钉死的点，交给承接团队。**

### 2.3 「迁移失败保留原数据」：实现本来就在，证据一条都没有

第 3 条剩下的唯一缺口。查下来结论和上一句相反——**这次不是缺实现，是缺证据**：机制已经是对的，而且做得挺完整：

- `TeleprompterV2Store.listDocuments()` 对每个解不开的文件返回 `isAvailable: false` 并带上具体 `error`（`corruptBundle`／`unsupportedVersion`／`invalidBundle` 三类可分），**不是跳过**；
- 会话层把它们收进 `unavailableDocuments`，**不混进可用列表**；
- 视图 542 行有明确提示：「有 N 份稿件无法打开，未影响其他稿件。可以删除后重新导入原稿重建。」并逐条列出。

问题是**这三条没有一条有回归钉住**。按第 46 条的教训（「命中过、读过、判为假阳性、没回头」），这里必须钉住的恰恰是最毒的那个假设：**「保留原数据」如果只是「先不报错」，而文件其实被清掉或改写，那就是丢数据。** 而这一条从代码上看完全正常——`listDocuments` 根本没有任何写操作，正是最难靠读代码发现问题的形态。

新增回归 `unreadableBundlesArePreservedAndIsolated`，用三种「这个 build 读不动」的真实形态一起验：更高格式版本（未来 App 写的）、损坏的 JSON、结构不合法。四条断言同时成立才算达标：读不动的稿件不污染可用列表、每份都带失败原因、**三个文件原样留在磁盘上且内容未被改写**、单独打开必须抛错且不换掉读者当前正在用的稿件。

**一次通过**——因为实现本来就是对的。但它同样此前没有证据能证明它对。变异 4 条全部被杀：读不动的稿件从列表里消失（杀）、读不动时顺手删掉原文件（杀）、不带失败原因（杀）、会话层不再记录不可用稿件（杀）。探针同样带基线自检。

**顺带查清并记下的一件事**：仓库里**没有 v1→v2 的文件迁移**。`TeleprompterStore`（v1，214 行）是另一套扁平 bundle 存储，提词器在这条路径上不用它；所谓「迁移」是 `applyV2Bundle` 在内存里把 v2 bundle 投影回旧模型（`legacyVersion`／`legacyBlocks`／`legacySelection`）。而 store 的 `validate` 很严——悬挂的 `sourceRevisionID`、正文与朗读稿不一致、段区间不连续都在**读入时**就拒收，所以 `legacyVersion` 里那两处兜底（`source?.sourceText ?? version.readingText`、长度为 0 的 `sourceRange`）**是纵深防御，生产不可达**。这一点接手方不必再查。

## 3. 验证证据

### 3.1 已执行

| 验证 | 命令 | 结果 |
|---|---|---|
| Swift 单元与回归 | `swift test --package-path macos/SpeechRailApp` | Swift Testing **275 项 / 16 套件** + XCTest **171 项**全部通过（2026-09-29 第十六轮复跑；两轮证据审计新增 8 条，读法别名通道与语音辅助试读再新增 20 条，错误归因与回滚一轮再新增 12 条，导入拒绝一轮再新增 1 条，字号列宽全值域扫描与迁移失败、零推进、恢复门槛与内容范围各再新增 1 条）。**更正**：本节此前写的「XCTest 389 项」无法复现，实测为 171 项；389 应是 Xcode target 侧的另一组计数，两条门禁的 XCTest 集合并不相同，比较时不要混用。**注意**：`swift test` **不编译** `TeleprompterView.swift` 与各 sheet，视图层编译证据只有 Xcode 一条，见 §2 第 34 条 |
| 探针回归 | `pytest tests/test_teleprompter_latency_probe.py` | **12 项通过**（新增时钟回退守卫用例）。**注意**：本 worktree 的 `.venv` 未安装 `dev` extra，须用主检出的 venv 并把本 worktree 的 `src` 置于 `PYTHONPATH` 之前；单文件运行还须加 `--no-cov`，否则 `--cov-fail-under=80` 会让退出码恒为非零。见 §2 第 33 条 |
| 共享准入回归 | `pytest tests/test_resource_governor.py` | 25 项通过（同 key 串行、共享单一 worker 槽位、重叠串行） |
| 回放 runner 端到端 | `swift run teleprompter-replay --manifest <外部 manifest>` | 产出 `teleprompter.eval.v1` 报告（P50／P95、恢复延迟、失败占比与 caveats 齐备）；缺 manifest、缺版本记录、素材字段非法均以退出码 2 拒绝。**CLI 与单测同形核对**：用与 `trackingLatencyIsMeasuredFromTheStartOfTheReadNotTheRun`／`reanchorLatencyIsMeasuredFromTheDetour` 同形的素材跑 CLI，复现了单测断言的数值（跟随延迟 p50=p95=400 ms；恢复延迟 p50=1100 ms），确认 runner 驱动的确实是生产跟随路径，而不是另写一套转写充当验收 |
| Xcode App target 编译 | `scripts/macos_app_build.sh --configuration Debug` | **BUILD SUCCEEDED**（2026-09-29 复跑）；17 条 warning 全部落在既有代码（`RealtimeASRClient` 的 `withStageTimeout` 未用结果、`LLMProvider` 弃用项等），本轮新增文件 0 条 |
| Xcode 单元测试 target | `scripts/macos_app_build.sh --configuration Debug --test-unit` | **TEST SUCCEEDED**（2026-09-29 复跑），XCTest **346 项** 0 failures，进程正常退出，`test-unit: passed`，exit 0。首轮曾因测试闸门竞态挂死并被 1800 s 超时终止，已定位并修复，见 §2 第 9 条 |
| 工程文件一致性 | `plutil -lint project.pbxproj` | OK；新增源码在 SwiftPM 与 Xcode 两个 target 均已登记 |
| 差异卫生 | `git diff --check` | 通过 |
| 回放 CLI 契约复核（第十八轮） | `swift run --package-path macos/SpeechRailApp teleprompter-replay --manifest <仓库外素材>` | 改了 `Metrics` 与报告 JSON 后**重跑 CLI 端到端**（此前只跑了单测）。两份素材放在仓库外 `/tmp`：正常跟随那份输出 `advanced_event_count: 2`；全停那份输出 `advanced_event_count: 0`、`harmful_jump_count: 0`、`stalled_event_count: 0`、`failure_share: 0`，**并带两条告警**（零推进、回稿恢复门槛未测量）。**修复前第二份的 caveat 数为 0**——这就是第 52 条说的「干净结果」，现在它在 CLI 输出里就长成告警的样子 |
| 评估器改动前后逐指标对比（第三十轮） | 同一份 41 秒真实素材（82 事件）分别用 HEAD 版与修复版 `TeleprompterReplayEvaluator` 跑 `teleprompter-replay`，再逐字段 diff 两份 `teleprompter.eval.v1` 报告 | **首轮抓到本轮自己引入的回归**：错误停顿 12 → 11，而 283 项单测全绿。修法与补回归见 §2.15。**复跑后逐指标零差异**——这份素材没有 improvise 标注也没有终态失败，失败计数修复前后都是 0，因此它证明的是「没动到正常路径」，**不是**「失败分母在真人素材上落到了某个区间」 |
| 零误推进 caveat 的真实素材复核（第三十一轮） | 同一份 41 秒真实素材分别用 HEAD 版与修复版跑 `teleprompter-replay`，逐字段 diff | `metrics` **零差异**，caveat 由 4 条增至 5 条，新增那条给出 **95% 上界约 263 次／小时**。这正是该素材能支撑的全部——§11.7「保留集观察零事件」在 41 秒素材上不该被引用，而修复前报告不这么说 |
| 交接文档引用可解析性 | 抽出 §4 台账与 §4.2 对照表里的具名标识，回到代码里逐个查 | **141 个标识全部可解析**（2026-09-29）。首轮查无此条 1 处：#111 引用了 `theSpeechTrialAdoptDecisionPinsRecognitionAndDurationSeparately`，而实际函数名是 `theSpeechTrialAdoptDecisionPinsBothConditionsSeparately`、显示名是带空格的 `the adopt decision pins recognition and duration separately`，报告写的是第三种形式，已改。详见 §2 第 45 条。**复核时（2026-09-29 第十八轮）脚本报 1 条「缺失」，经查是误报，报告无需改动**：`theSpeechTrialAdoptDecisionPinsRecognitionAndDurationSeparately` 现在只出现在 §2 第 45 条与本行**叙述当年那次修正的文字里**，不是活引用；真正被引用的 `theSpeechTrialAdoptDecisionPinsBothConditionsSeparately` 在代码中确实存在。脚本按标识全文匹配，分不清「引用」与「讲这个错名的故事」。**接手方不要为了让脚本归零而去删那段叙述**——那会把一条修正记录删掉。同批复核：台账标识数因本轮新增引用由 141 涨到 191，其余 190 条全部可解析 |
| 回归有效性（变异验证） | 对生产代码施加定向变异，检查是否有测试变红 | 三轮累计。**第 18 条**（前序）：`TeleprompterReadingProgressRestorer` 两次变异，其中只破坏 nil 分支的那次**既有 13 条同套件测试全绿、仅新增用例变红**。**第 24–33 条（本轮）**：有效变异 **79 次**，覆盖台账全部六段——跟随控制器 18、保真门禁与语义检测 12、`RealtimeASRClient` 事件闸门 6、sequence validator 4、存储与舞台 11、回放评估 caveat 7、Python 探针 6、以及若干对照。结果 **47 杀 / 32 存活**；作废 14 次（锚点写错 2、探针缺陷 8、语义等价 2、探针环境错误 6，见第 27、33 条），均不计入。**32 次存活逐个查因**：12 次补回归后转杀掉，20 次判为纵深防御外层、生产不可达或不可观测（§2 第 19、24、25、28、31 条）。新增 12 条回归，其中 **11 条经变异验证**；`longRunsStayCorrectAcrossHundredsOfItems` 经变异验证确认**钉不住内存上限**，只声称它固定长跑后行为不漂移 |。**第十轮（读法别名，22 次变异）与第十一轮（语音辅助试读，8 次变异）**：每轮都带基线自检与一条已知应杀变异，探针本身先证明有效。别名轮首轮 5 条存活，查因后 4 条补回归转杀掉，1 条（`updatePendingSegment` 清空别名）判为**当前不可达**——两处 `pendingVersion` 都从零重建段落，走不到，按纵深防御保留并在注释里写明不可达原因。试读轮首轮 4 条存活，其中 3 条是**测试盲区**（试读不推进阅读位置、采用闸门、沿用同一套识别配置），补断言后杀掉；1 条（把试读事件也喂给 `followAdapter`）定位为**结构性失效**：`TeleprompterFollowController` 每条接收路径都有 `guard mode == .following`，试读从不进入该模式，控制器会 retire 每个 item。**第十二轮（错误归因与回滚，19 次变异）**：新增路径 3 条、移除路径 3 条、采用回滚 3 条、朗读标注回滚 2 条、原稿回退回滚 3 条、切稿拒绝 2 条、重试保存 1 条、复制兜底 1 条、删除拒绝 1 条，全部被新回归杀死，无存活，详见 §2 第 41–44、46–50 条。**第十五轮（导入拒绝，1 次变异）**：把 `createDocument(title:importedSource:)` 的守卫改回静默 `return`（杀），见 §2 第 51 条。**第十六轮（验收第 3 条补证，10 次变异）**：字号列宽扫描 5 条被杀，1 条**未复现触发条件**（`TeleprompterStageLineLayout` 的尾行兜底分支本机进不去；既不是等价变异，也不是测试盲区，见 §2.2），不计入杀数；「迁移失败保留原数据」4 条全杀（读不动的稿件从列表消失／读不动时删掉原文件／不带失败原因／会话层不再记录）。**第十七轮（零推进不得报成干净结果，4 次变异）**：4 条全部被杀，详见 §2 第 52 条。**同轮续（恢复门槛，3 次变异）**：3 条全部被杀，其中一条复现了本轮真实犯的判据错误。**第十九轮（改范围不得静默丢弃审阅，7 次变异）**：7 条全部被杀，无存活无作废，详见 §2 第 54 条。**累计有效变异 123 次、91 杀 / 32 存活；累计新增 37 条回归**（别名 15、试读 5 条中 3 条为补盲区另 2 条为新增场景、错误归因与回滚 6、导入拒绝 1、字号列宽扫描 1、迁移失败 1、零推进 1、恢复门槛 1、内容范围 3） |
| 第三十轮（失败分母，5 次变异） | 对 `TeleprompterReplayEvaluator` 的失败计数与停顿门槛施加 5 条定向变异 | 5 条全部被杀。**「停顿门槛复用回稿 deadline」首轮存活**——它是本轮新引入的解耦、没有用例覆盖，补 `aStallDuringAnUnrecoveredReanchorWindowStillCounts` 后转杀。另 4 条（去掉逐事件 latch、窗口关闭时不结算次数、分子改回「次数」、恢复时不再释放停顿门槛）首轮即杀；其中最后一条杀的是**本轮自己引入的回归**——它让 41 秒真实素材的错误停顿从 12 掉到 11，283 项单测全绿都没发现，是靠修复前后两份报告逐指标对比才看出来的。详见 §2.15 与 §2 第 57 条。**累计有效变异 128 次、96 杀 / 32 存活；累计新增 41 条回归**（本轮 4 条：拖尾稀释、多次未恢复、停顿门槛解耦、恢复释放门槛） |
| 第三十一轮（零误推进样本上界，5 次变异） | 对新增的零观测 caveat 施加 5 条定向变异 | 4 条首轮即杀（删掉整条、把上界写成常数 1、假设观测 8 小时、只对长素材输出）。**1 条作废**：`let hours = 8` 让 `hours` 推成 `Int`，`.rounded()` 编译不过——按第 27、33 条的规矩**探针缺陷不计入杀数**，改成 `8.0` 后成为有效变异并被杀掉。另一条「让它在已观测到误推进时也输出」由反向对照 `aMaterialWithHarmfulJumpsReportsTheCountNotTheSampleBound` 杀掉。详见 §2.16 与 §2 第 58 条。**累计有效变异 133 次、101 杀 / 32 存活；累计新增 43 条回归**（本轮 2 条：样本上界存在、上界随时长收紧） |

**交接前的最终门禁复跑（第二十四轮，2026-09-29）**：上面各行是开发过程中分轮跑的；为了让接手方拿到**一个当前时点、覆盖整条分支的绿证据**（而不是拼凑各轮旧记录），在最终交接状态（**61 个提交**，HEAD `92fad46f`，已含第二十一／二十二轮的两处视图改动）把三条门禁完整重跑一遍：

| 门禁 | 结果 |
|---|---|
| `swift test --package-path macos/SpeechRailApp` | **275 项 / 16 套件通过**（与会话／模型层历史计数一致） |
| `scripts/macos_app_build.sh --configuration Debug` | **BUILD SUCCEEDED** |
| `scripts/macos_app_build.sh --configuration Debug --test-unit` | **TEST SUCCEEDED**，`test-unit: passed`，exit 0 |

**这一轮复跑补上了一个此前没被点明的证据缺口**：第二十一／二十二轮改的是 `App.swift` 与 `TeleprompterView.swift`——**SwiftPM 与无 `TEST_HOST` 的单测 target 都不编译这两个文件**，所以那两处改动（`⌘⌥V`、`⌘⏎`）从来只有 Debug 构建一条编译证据。此刻三条门禁同时绿，等于明确写下：**视图层改动已编译通过，其余各层无回归**。真实按键与新视觉仍待 U-10 走查（见 §3.2），不在此列。

**探针首次在真机线上服务跑通（第二十五轮，2026-09-29）**：此前全部分发证据都注明「真机跑 probe 从未执行」。本轮取得授权后，在 operator contract 的隔离要求下实测：

- **隔离核查**：`lsof` ESTABLISHED 为 0；鉴权 `/metrics` 显示 `governor_active_requests{batch}=0`、`{realtime}=0`、`realtime_active_sessions=0`，无外部 realtime 客户端占用。
- **口径**：active profile `quality/quality`（ASR `asr-1.7b-q8`），warm-up 1 次后连续 5 次，输入为仓库外 4.24 s、24 kHz mono PCM16 普通话素材。`evidence_mode` 5 次全为 `real`，`revision_regressions` 全为 0（对应 §11.5 门禁 T-04 的 revision 单调性在真机流量上成立）。

| 指标 | n | P50 | P95 | min | max |
|---|---|---|---|---|---|
| 首个 partial 用户可见延迟 | 5 | **1022.9 ms** | **1034.6 ms** | 993.0 | 1037.0 |
| 终态 commit（音频结束后） | 5 | **26.0 ms** | **31.5 ms** | 21.8 | 32.8 |
| 上传迟到（每 100 ms 节奏） | 5 | 7.1 ms | 10.0 ms | 6.3 | 10.1 |
| setup | 5 | 24.7 ms | 25.4 ms | 24.4 | 25.4 |

**这些数字证明什么、不证明什么，必须说清**：它们证明探针能真正驱动线上 Realtime ASR 路径，且给出**首个 ASR partial 用户可见延迟**与**终态 commit 延迟**在真机流量上的首个真实量级——正是 #83 一直跟踪的那两个量。**但它不构成 §11.7 的跟随时延基线**：素材是 TTS 合成而非真人朗读（§11.5 禁止用 TTS 生成主质量集），且没有人工核验的阅读位置标注，因此 §11.6 的「正常跟随延迟」与「回稿恢复延迟」分位**仍未测量**。这些数字目前只作为链路与量级参考，不得当作达标结论。

原始制品与结果 JSON 全部落在仓库外 `/tmp`（`tp_run_*.json` 等），探针未向仓库写入任何内容（运行后 `git status` 干净）。素材与结果按 §11.5 只存受控位置，Git 不收音频、结果只含时序与计数、无转写文本。

### 3.1.1 第二十六轮：素材工具的端到端实测（2026-09-29）

- **链路打通**：真实服务、quality 档、仓库外素材，采集 9 个事件（4 hypothesis / 4 delta /
  1 completed）→ 对齐 → 契约合法 manifest → `swift run teleprompter-replay` 解码出
  `teleprompter.eval.v1` 报告（`sample_count: 9`、`advanced_event_count: 4`、
  `unintentional_backjump_count: 0`、`unlabelled_event_count: 0`）。
- **报告自己把「没测」说成「没测」**：两条 caveat 正确触发——「本次素材没有 improvise 标注：
  严重误推进只在该标注下计数，因此 0 表示该检测项未被触发」「本次回放没有量到回稿恢复延迟：
  分位为 null、超时为 0」。**这正是要的性质**：工具不生产安全数字，只保证没测的不显示成达标。
- **修正口径后重跑同一素材**：9 条标签全为 `read`，阅读位置单调 0→1，无假 `reRead`、无假
  `improvise`（修正前是 read 3／improvise 3／reRead 3，6 条存疑）。
- **第二轮（41 秒长素材）**：端到端再跑一次，82 个事件、41 秒；修正后 71 个事件拿到位置、位置回退 0 次、82 条标注全为 `read`；报告写出「错误停顿 16 次，分母为样本 82」。详见 §2.11。
- **门禁**：新增回归 29 项通过（连探针回归共 41 项）；`ruff check` 与 `mypy` 对新工具均无告警。
- **边界**：这批素材是 **TTS 合成音**（音色 audition 素材，源文本见
  `tests/test_voice_design_workflow.py` 的 `CONTROLLED_TEST_TEXT`），按 §11.5 **不得作主质量集**。
  本轮只验证工具与契约链路，**不构成时延基线，也不改变「真实基线未建立」这个结论**。

### 3.2 未执行（需要逐次授权）

- 真实音频 1 倍速回放与真人表达验收（L3／L4）：**未采集任何真人录音**。第二十五轮已获授权并让探针在真机线上服务跑通（见 §3.1 末），但输入是 TTS 合成素材、且无人工核验的阅读位置标注——按 §11.5 它不能充当主质量集。**仍缺**：真人朗读录音 + 人工标注，方能测 §11.6 的正常跟随延迟与回稿恢复延迟分位。
- 任何 UI 自动化、窗口断言、录屏。
- 模型 benchmark、App 安装与发布仍未执行。
- commit 与 Issue 关闭已按 2026-09-28 的用户授权执行：证据完备者已关闭，其余逐条留下复审评论写明精确剩余缺口；**分支仍未 push**，关闭所依据的提交见各 Issue 评论。

因此方案 §11.7 的全部质量门槛——连续跟随 P95、回稿恢复 P95、手动操作 P95、错误停滞比例、严重误推进发生率——**当前均为未验证**，不得以本报告宣称达标。第二十五轮测到的首个 partial 延迟（P95 1034.6 ms）与终态 commit（P95 31.5 ms）是**链路量级参考**，不对应其中任何一条门槛，也不构成达标结论。

### 3.3 契约与文档

- **公共契约无需修改**：`audio.input.transcription.language` 与 `keywords` 早已写入 `contracts/realtime-events.schema.json`（`session.update` 形状）并在 `contracts/realtime-openai.md` 的示例中给出；#112 是客户端向既有契约看齐，而不是新增字段。#106 的稳定性证据同样只走内部 Swift 事件（可选类型化字段，wire 协议未新增事件）。本轮没有改变任何公共端点、事件或错误 envelope。
- **已同步的文档**：`docs/developers/macos-app-teleprompter.md`（版本 0.5.6：场景预设、正文列宽、「回到朗读位置」、Reduce Motion、输入设备失败归因、读法标注的失败归因边界（`TeleprompterAcceptedReadingRejection` 现为 13 种原因，「现在不能改／找不到这一段／没有保存成功／正文变了」是四件不同的事，且**新增与移除走同一套原因**）、模块表与本轮验收记录）、`docs/developers/macos-app-design-system.md`（正文列宽与窗口宽度分离的描述 + §6 验证矩阵新增一行）、`docs/users/mcp-agent-integration.md`（`session.update` 示例补 `keywords`，并说明语言／关键词是可选提示、越界取值应降级为不给提示）、本报告与 SDD ledger。
- **未同步且不需要同步**：`docs/users/` 其余文档不描述舞台列宽与预设入口；根 `README.md` 只保留价值与公共能力，不随本次实现变化更新。

## 4. 69 项场景台账

状态含义：`通过` 有具名回归覆盖；`部分` 机制已覆盖但缺少该场景的完整用例；`未覆盖` 无具名回归；`未执行` 需真实音频／真人／UI 授权。

| 场景 | 状态 | 证据 |
|---|---|---|
| P-01 顺口原文不被加套话 | 通过 | `unchangedRewriteStaysSpeakWithoutReviewIssues` |
| P-02 数值被改写 | 通过 | `subjectValueSwapIsRejectedByHardGateAndKeepsSource`、`rewriteDecoderRejectsChangedAndRepeatedProtectedValues` |
| P-03 中文紧邻数字／年份 | 通过 | `mapDecoderRejectsChangedUnitAndUnicodeNumber`、`protectedLiteralExtractorPreservesOccurrencesAndUnicodeBoundaries` |
| P-04 正负号不混淆 | 通过 | `droppingANumberSignIsRejectedByTheHardGate`（`-3`／`+5`／`−7` 并列；去符号改写被门禁拒绝并逐字回退）、`mapDecoderRejectsChangedUnitAndUnicodeNumber` |
| P-05 百分比与百分点 | 通过 | `mapDecoderRejectsChangedUnitAndUnicodeNumber`、`itnVariantsShareTheSameScriptPosition` |
| P-06 重复出现不被去重掩盖 | 通过 | `protectedLiteralExtractorPreservesOccurrencesAndUnicodeBoundaries` |
| P-07 A／B 价格互换 | 通过 | `subjectValueSwapIsRejectedByHardGateAndKeepsSource`、`semanticReviewDetectsSubjectValueAndQualifierChanges` |
| P-08 条件／否定／确定程度变化 | 通过 | 条件与比较级 `qualifierLossInRewriteBecomesUnresolvedReview`、确定程度与主体-数值 `semanticReviewDetectsSubjectValueAndQualifierChanges`／`semanticReviewMapsRisksIntoExistingReviewIssues`（四项均经变异验证）、**否定 `negationLossBecomesUnresolvedReview`**（本轮补齐）。此前四类限定语里唯独「否定」无任何断言，见 §2 第 29 条 |
| P-09 `0012`／`v1.2.3`／`C++`／URL | 通过 | `identifiersVersionsSymbolsAndURLsBecomeProtectedLiterals`（四类均成为受保护值，且原子偏移能指回原字符） |
| P-10 中文数字／年份读法 | 通过 | `circleZeroYearSharesTheSamePositionAsItsArabicForm`、`itnVariantsShareTheSameScriptPosition`、`toleratesOmissionAndDigitReading` |
| P-11 表格转口语行列归属 | 通过 | `tableRowsKeepTheirOwnPricesAcrossRewrite`（忠实改写保序；跨行调价被门禁拒绝并逐字回退） |
| P-12 不完整 Markdown／代码／公式 | 通过 | `unterminatedCodeAndFormulaSurviveTheFidelityGate`（未闭合代码块与公式不丢内容；改写代码里的数值被拒） |
| P-13 原文注入不当指令 | 通过 | `instructionsInjectedByTheScriptStayInsideTheDataPayload`（注入文本只出现在 JSON 数据里，指令区不含脚本内容，注入文本中的数字同样受保护） |
| P-14 结构错误与重叠被拒 | 通过 | `groupingRejectsNonRangeFieldsAndIncompleteCoverage`、`rejectsOmissionsOverlapAndUnknownFields`、`rewriteRejectsUnknownAndDuplicateBlockIDs` |
| P-15 旧请求结果失效 | 通过 | `cancellationInvalidatesLateMapResponse`、`manualTakeoverInvalidatesOldPipeline` |
| P-16 精简与保真权限分离 | 通过 | 操作层 `fidelityOperationsStillRejectOmissionsAsUnresolved`、`condenseReportsOmittedContentAsSkippedAndReviewable`；解码层 `rewriteRejectsOmitWithTextAndReviewClaimingNonspokenContent`（`omit` 必须空文本、`.review` 不得声明 `nonspoken_content`，本轮补齐并经变异验证），见 §2 第 30 条 |
| P-17 用户编辑后诊断失效 | 通过 | `editingSourceInvalidatesReviewState`、`latePreparationResultAfterEditIsDiscarded`（编辑后候选、审阅条目与块全部失效；旧 generation 的迟到结果不回填） |
| P-18 局部窗口失败不冒充成功 | 通过 | `oneWindowFailureKeepsOtherWindowsAndFallsBackOnlyLocally`、`laterWindowFailureDoesNotReturnPartialScript` |
| F-01 连续朗读不跳读 | 通过 | `bodyAloneMatchesWithProductionDefaults`、`tracksInsideSentenceAndAcrossSegments` |
| F-02 长停顿不抢跑 | 通过 | `detourHoldsAndFollowingSpeechRecovers`、`sustainedDetourEntersFreePlayAndLaterReanchors` |
| F-03 口头禅与插词 | 通过 | `toleratesSubstitutedTailAndShortInput`、`snapshotCompletedSequenceDrivesFollowPosition` |
| F-04 远处唯一短语 | 通过 | `distantUniquePhraseCannotAdvanceThroughPartialOrFinal`（距离约 100，只查视口）＋`aDistantForwardPhraseCannotDragTheViewportAhead`（距离 30，贴住半径边界，连 `committedPosition` 一起钉）＋`aLoneStrayTokenMatchDoesNotMoveTheViewport`（单 token，钉住 `provisionalMinimumMatches` 这道门禁）。三条均为第二十九轮续补，**向前这一向此前一条都没有** |
| F-05 相同开场短语消歧 | 通过 | `unrelatedSpeechAndRepeatedShortPhrasesDoNotMove`、`explicitManualSelectionMakesTheSamePhraseALocalAnchor` |
| F-06 修订不引发整行往返 | 通过 | `partialMovesProvisionallyAndFinalReplacesIt`、`partialCanPreviewForwardWithoutImmediateFinalRollback` |
| F-07 真实重读受控回退 | 通过 | `rereadRollsBackOnlyWhenTheBackwardMatchIsStrong`、`rereadDoesNotRollBackAcrossDistantParagraphs`（均经变异验证；此前引用的 `localRepeatCanReturnToPreviousSentence` 只证明对齐器找得到上一段，删掉 `mayConfirm` 回退门禁它仍全绿，见 §2 第 24 条） |
| F-08 重复快照不重复推进 | 通过 | `snapshotRevisionReplacesTextAndDuplicateEventIsIgnored`、`repeatedWireEventDoesNotAppendTwice` |
| F-09 增量与全文不双计 | 通过 | `snapshotRevisionsReplaceTextAndFollowRevisions`、`partialMovesProvisionallyAndFinalReplacesIt` |
| F-10 旧 revision／eventID | 通过 | `duplicateSnapshotRevisionCannotAppendOrAdvance`、`lateFinalFromOlderItemCannotUndoNewerFinal` |
| F-11 旧 epoch／generation | 通过 | `testRealtimeItemStateValidatesUnicodeSpansAndMergesSameRevisionShards`（`latestEpoch` 回退闸门，变异验证）、`testRealtimeItemStateRejectsLateHypothesisForARetiredItem`（`retiredUntil`，变异验证）、`testRealtimeItemStateRejectsAForeignTaskIDWithinOneConnection`（`serverTaskID`，变异验证）、`pausedAndRetiredItemsCannotOverrideManualPosition`、`eventsAfterManualTakeoverCannotMovePosition`。同函数第三道 `existing.generation` 闸门**生产不可达**（`reset`／`clear` 都清空 `items`），只记录不补断言，见 §2 第 25 条 |
| F-12 sequence 缺口／回退 | 通过 | `testSequenceValidatorReportsGapAndRegression`（缺口、回退、缺口后仍报回退）、`testSequenceValidatorRejectsMissingIdentityAndNonzeroInitialSequence`（首事件必须为 0）、`testSequenceValidatorRejectsDuplicateEventID`、`testClientClosesBeforeDeliveringEventAfterSequenceGap`（四项均经变异验证；此前引整个 `RealtimeContractTests` 套件过宽，且套件已增至 35 项） |
| F-13 未见过 hypothesis 的 final | 通过 | `isolatedFinalMismatchKeepsLastConfirmedPosition` |
| F-14 迟到 final 不覆盖新位置 | 通过 | `lateOldFinalCannotUndoNewerItem` |
| F-15 稳定前缀越界 | 通过 | `testHypothesisRejectsStablePrefixBeyondCurrentUnicodeScalars`（越界在 `RealtimeASRClient` 解码层即被拒为 `invalid_hypothesis`，变异验证）；`stableHypothesisPrefixLimitsPreviewToProvenText` 覆盖的是控制器的稳定前缀预显机制，与越界无关，见 §2 第 26 条 |
| F-16 emoji／代理对不切断 | 通过 | `preservesUTF16SourceRangesAcrossSupplementaryCharactersAndFillers`、`sourceUnitsRoundTripUTF8AndDoNotSplitGrapheme` |
| F-17 自由发挥后恢复 | 通过 | `sustainedDetourEntersFreePlayAndLaterReanchors` |
| F-18 有意跳读 | 通过 | `differentSegmentManualMoveStartsAtParagraphBeginning`、`explicitManualSelectionMakesTheSamePhraseALocalAnchor` |
| F-19 旁人声与静音幻觉 | 通过 | `unrelatedSpeechAndRepeatedShortPhrasesDoNotMove`、`distantUniquePhraseCannotAdvanceThroughPartialOrFinal` |
| F-20 状态区分不误报 | 通过 | `failedAndClosedEventsAreTerminalOutcomes`、`isolatedFinalMismatchKeepsLastConfirmedPosition` |
| F-21 接管后 drain 不夺回 | 通过 | `manual takeover during a delayed connect closes the late client`、`eventsAfterManualTakeoverCannotMovePosition` |
| F-22 行末不越界 | 通过 | `reading position resolves and steps across display lines without wrapping`、`line slots preserve a centered current row at script boundaries` |
| U-01 原稿直接开讲零副作用 | 通过 | `manualOpenHasNoAudioSideEffects` |
| U-02 未确认候选不采用 | 通过 | `manual open never adopts an unconfirmed AI draft` |
| U-03 焦点不被截获 | 通过 | `reading shortcuts require reading focus and never steal control keys` |
| U-04 控制栏显隐几何稳定 | 通过 | `controls remain visible for focus, menus, VoiceOver, and opt-in always-on` |
| U-05 稿首稿尾三行模式 | 通过 | `stage preview shows one, two, or three actual display lines`、`line slots preserve a centered current row at script boundaries`、`two-row mode still leaves the trailing slot empty and row counts stay clamped`（两行模式稿尾留空与行数夹取，本轮补齐并经变异验证）。**内部上限夹取不可观测**，见 §2 第 31 条 |
| U-06 字号列宽变化位置不串 | 通过 | `display-line layout wraps at the requested width and preserves UTF-16 source ranges`、`manual display-line positioning preserves UTF-16 offsets and takes over voice assist`、`an offset past the end of a segment still resolves to that segment's last row`（换字号后偏移落到段尾之外，本轮补齐并经变异验证） |
| U-07 无障碍与 Reduce Motion | 部分 | Reduce Motion 有回归（`reduceMotionRemovesScrollAnimation`：舞台不做位移动画但阅读位置仍更新），焦点策略有回归（`readingShortcutFocusPolicy`）。**无障碍此前只有「控制栏在 VoiceOver 开启时不隐藏」这一条**（`controls remain visible…` 验的是 `controlsVisible`，不涉及控件名称），三处复选框因此长期没有无障碍名称；本轮已补名称（§2 第 23 条），但**朗读效果未验证**。**键盘侧此前是零证据**：方案第 242 行要求「常用操作仍须键盘与无障碍可达 [R01]」。**第二十一轮给「手动接管／语音跟随」补上常驻菜单快捷键 `⌘⌥V`**（§2.8），**第二十二轮给「采用候选版本」补上审阅相位主操作 `⌘⏎`**（§2.9）——两条走查点名的最关键操作现已接线且编译通过、真实按键待 U-10。其余高频操作——新建／导入／打开舞台／重试保存／回到朗读位置——**无键位，但第二十三轮查规格确认它们本就该走 Tab 而非新增快捷键**（舞台规格第 101 行），菜单命令亦已规格齐全（第 93 行）；纯键盘完成这些取决于系统「键盘导航」开关（默认关闭），**该取舍需产品拍板**（§2.10）。其余已并入 §5 第 1 条 U-10 走查清单 |
| U-08 后台更新不抢焦点 | 通过 | `readingShortcutFocusPolicy`（阅读区外焦点、控件焦点、popover 打开时方向键都不被舞台接管）；提词器与 App 均未注册 `NSEvent` 全局／本地监视器，阅读键只作用于舞台窗口 |
| U-09 显示预设持久化 | 通过 | `stage settings clamp and persist their supported ranges`、`stage visibility preferences default off and persist independently` |
| U-10 真实窗口可见性 | 未执行 | 需 UI 自动化逐次授权。**待走查面已增至 7 处**：原四处（精简入口、精简确认 sheet、删除审阅卡片「原文：」行、识别语言菜单）＋读法标注窗口、语音辅助试读的「麦克风／识别／定位」三段链路，以及三处复选框的 VoiceOver 朗读 |
| R-01 权限拒绝与 busy 不阻断手动 | 通过 | `manualOpenHasNoAudioSideEffects`、`readyz diagnostics do not override a valid realtime capability binding` |
| R-02 starting 期关闭 | 通过 | `manual open rejects during close and succeeds after cleanup` |
| R-03 stop 失败可重试 | 通过 | `stop failure remains fail-closed until an explicit stop retry`、`repeated close is idempotent` |
| R-04 设备拔插／蓝牙重连 | 部分 | `inputDeviceLossFailsClosedWithManualFallback`（失败即释放占用、关闭连接、不推进稿件、保留手动；真实拔插与蓝牙重连未执行） |
| R-05 队列风暴有界降级 | 通过 | `eventStormDegradesInsideBoundedTransport`（600 条事件连续灌入后舞台仍在跟随、无错误、位置在稿内）；传输层 `RealtimeEventStream.Limits.default` 本身有界（256 事件／4 MB），探针侧 `test_receive_loop_fails_instead_of_growing_an_unbounded_queue` |
| R-06 共享准入不复制模型 | 通过 | 服务侧具名证据：`test_tts_requests_share_one_admitted_worker_slot`、`test_same_tts_resource_key_remains_serialized`、`test_realtime_slot_remains_available_when_batch_lane_is_saturated`、`test_heavy_overlap_serialization_when_budget_constrained`（2026-09-28 重跑 25 项通过） |
| R-07 长时运行不泄漏 | 部分 | `repeatedStageCyclesReleaseResources`（20 轮开讲→跟随→关舞台，每轮占用归零、连接各关闭一次、采集各停止一次）、`longRunsStayCorrectAcrossHundredsOfItems`（300 个 item 后行为不漂移；**不覆盖内存上限本身**，见 §2 第 28 条）；长时间连续运行未执行 |
| R-08 日志与导出脱敏 | 通过 | `observationsCorrelateCallAndRedactedFailure`、`mapDecoderReportsRangeGapWithoutExposingSourceText`、`reportCarriesOnlyAggregatesAndNoScriptText`，以及本轮补齐的 `unlabelledEventsAndReanchorTimeoutsBothSurfaceAsCaveats`（**未标注事件**与**回稿恢复超时**两条 caveat 此前无覆盖，而它们正是「不把没测到的说成没问题」的关键），见 §2 第 31 条 |
| M-01 旧稿缺字段仍可读 | 通过 | `runSummaryWrittenBeforeIntraSegmentProgressStillLoads` |
| M-02 写入原子性 | 通过 | `sourceRevisionIsImmutableAndInvalidSaveLeavesPreviousBytesUntouched` |
| M-03 损坏保留原文件 | 通过 | `unknownFutureVersionFailsClosedAndCorruptDocumentsDoNotBreakListing` |
| M-04 块位置映射 | 通过 | `readingProgressRestoresTheExactOffsetInsideTheSameVersion`、`readingProgressFallsBackToSegmentStartWhenTheTextChanged`、`readingProgressMigratesOffsetWhenTheSegmentTextIsIdentical`、`readingProgressClampsOffsetsAndIgnoresUnknownSegments`、`readingProgressFallsBackToSegmentStartWhenTheRecordedVersionIsGone`（记录版本已删除这一支，本轮补齐并经变异验证），见 §2 第 31 条 |
| M-05 回退不删稿件 | 通过 | `rollingBackToAnEarlierVersionKeepsEveryScript`（回到旧版本只是切换选中，精简稿与源修订都还在） |
| T-01 recv 返回后才取时戳 | 通过 | `test_receive_loop_stamps_time_after_recv_returns` |
| T-02 ACK 后建立媒体原点 | 通过 | `test_media_origin_is_established_after_session_configuration`、`test_media_origin_refuses_to_start_before_the_configuration_ack`（时钟回退必须硬失败，本轮补齐并经变异验证） |
| T-03 终态绑定 commit event_id | 通过 | `test_commit_terminal_requires_the_matching_event_id`、`test_wait_for_terminal_ignores_other_commit_and_surfaces_errors` |
| T-04 revision 按 utterance 分组 | 通过 | `test_revision_tracker_scopes_regressions_to_one_utterance` |
| T-05 终态缺失与失败 | 通过 | `test_probe_measurements_record_hypothesis_without_losing_first_partial` |
| T-06 慢消费者与队列溢出 | 通过 | `test_receive_loop_fails_instead_of_growing_an_unbounded_queue`、`test_cli_reports_queue_overflow_as_input_error`。**本轮修了该测试自身的挂死隐患**：非守护线程会让有界投递一旦退化成阻塞投递就把整个 pytest 进程卡死，见 §2 第 32 条 |

合计 69 项：通过 65、部分 3、未覆盖 0、未执行 1。

计数说明：2026-09-29 做了两轮证据强度审计。**第一轮（§2 第 24–28 条，范围 F 段）**查出 F-07、F-11、F-12、F-15 四行证据指向有误或过宽；**第二轮（第 29–33 条，覆盖 P／F／M／U／R／T 全部六段）**又查出 P-08、P-16、M-04、U-05、U-06、R-08、T-02 七行存在**具名回归缺失**（不是引错，是根本没有对应断言），以及 T-06 的**测试自身会挂死**这一隐患。**69 行至此全部用变异探针核过一遍**，共补 12 条回归、修 1 处测试缺陷。审计改变的都是「凭什么说通过」，没有一行行的结论从「通过」降级——**唯一仍未通过的是 U-10（需 UI 授权）、R-04 与 R-07（需真机／长时）**，与本轮无关。

### 4.1 Issue 验收项对照

下表把 11 个 Issue 正文里的 61 条验收清单逐条落到证据上。证据列的具名回归都能用 `rg` 在 `macos/SpeechRailApp/SpeechRailMacControlTests/`、`tests/`、`tools/` 中直接搜到（swift-testing 用 `@Test("显示名")`，XCTest 用方法名）；本轮已核过本节全部 81 个证据标识（79 条具名回归 + `TeleprompterCalibrationSource`、`TeleprompterCanonicalizer` 两个类型名，另有 3 个套件通配写法）在源码中字面存在。

状态含义：**满足**＝有具名回归且本机跑过；**边界**＝方案本身就分阶段或需另行授权，不属本轮；**未量化**＝行为已实现并有回归，但缺少可给出的量化数据。

| Issue | 验收项（缩写） | 状态 | 证据／边界 |
|---|---|---|---|
| #104 | `50→150`、`50%→50个百分点`、量级／负号必须阻断或转审阅 | 满足 | `subjectValueSwapIsRejectedByHardGateAndKeepsSource`、`droppingANumberSignIsRejectedByTheHardGate`、`mapDecoderRejectsChangedUnitAndUnicodeNumber`、`hardGateRejectsChangesToNumbersItCouldNotPreviouslySee`（第三轮补：此前 `1080p`／`4K`／`1e10`／`0x1F` 静默通过，见 §2 第 12 条）、`extractorSeesExponentRadixAndUnitSuffixForms` |
| #104 | 中文紧邻数字、全角／Unicode 符号在 macOS 原生生产测试中有结果 | 满足 | `protectedLiteralExtractorPreservesOccurrencesAndUnicodeBoundaries`、`identifiersVersionsSymbolsAndURLsBecomeProtectedLiterals`（跑在 macOS 原生 Swift 测试） |
| #104 | 重复数字删除不被 Set 掩盖；合法等价读法有白名单与测试 | 满足 | `rewriteDecoderRejectsChangedAndRepeatedProtectedValues`、`itnVariantsShareTheSameScriptPosition` |
| #104 | P-02～P-10 进入生产回归；取消、局部回退、用户编辑保护不退化 | 满足 | 台账 P-02～P-10 全通过；`cancellationInvalidatesLateMapResponse`、`oneWindowFailureKeepsOtherWindowsAndFallsBackOnlyLocally` |
| #104 | 报告误报情况；不宣称能自动证明全部事实关系 | 未量化 | 只逐例证明「无害改写不被阻塞」（P-01），**没有汇总误报率**；不得据此推断低误报。已知边界：中文数字互改不受硬门禁保护（`chineseNumeralsRemainOutsideTheHardGateByDesign`），补齐需可测误报率 |
| #105 | 远距短语在 partial 与 completed 两条路径均不得越过未读句 | 满足 | `distantUniquePhraseCannotAdvanceThroughPartialOrFinal` |
| #105 | 手动选中后文后可从新位置继续跟随 | 满足 | `explicitManualSelectionMakesTheSamePhraseALocalAnchor`、`differentSegmentManualMoveStartsAtParagraphBeginning` |
| #105 | 重复标题、相似枚举、跳句、重读、脱稿回近处有正负对照 | 满足 | `unrelatedSpeechAndRepeatedShortPhrasesDoNotMove`、`rereadRollsBackOnlyWhenTheBackwardMatchIsStrong`、`rereadDoesNotRollBackAcrossDistantParagraphs`、`bodyAloneMatchesWithProductionDefaults`。**审计更正**：此前引的 `localRepeatCanReturnToPreviousSentence` 只覆盖对齐器，正负对照的实际裁决在跟随控制器，见 §2 第 24 条 |
| #105 | 不靠「永远不动」规避误跳，同时报告滞后、停滞与人工纠正 | 边界 | 确定性侧由回放评估器输出（`tracking_latency_p50_ms`／`tracking_latency_p95_ms`、`failed_sample_count` 等）；**真实语速下的三者对比需真实音频授权** |
| #105 | F-01～F-07、F-17～F-22 与参数／策略 revision 可追溯 | 满足 | 台账 F-01～F-22 全通过；报告只输出聚合量 |
| #105 | 旧 generation、手动接管后到达的结果无推进权 | 满足 | `testRealtimeItemStateRejectsLateHypothesisForARetiredItem`、`testRealtimeItemStateRejectsAForeignTaskIDWithinOneConnection`、`testRealtimeItemStateValidatesUnicodeSpansAndMergesSameRevisionShards`（`latestEpoch` 回退闸门）、`pausedAndRetiredItemsCannotOverrideManualPosition`、`eventsAfterManualTakeoverCannotMovePosition`。四条 Realtime 侧证据为本轮审计补齐，见 §2 第 25 条 |
| #106 | 有／无稳定信息的同文本事件可区分，invalid span 拒绝或降级 | 满足 | `stableHypothesisPrefixLimitsPreviewToProvenText` |
| #106 | emoji、组合字符、中英混合的 codepoint 与 UTF-16 不错位 | 满足 | `preservesUTF16SourceRangesAcrossSupplementaryCharactersAndFillers`、`sourceUnitsRoundTripUTF8AndDoNotSplitGrapheme` |
| #106 | 同音频重复解码不累计为新增证据；稳定前缀被改写时不推进 | 满足 | `snapshotRevisionReplacesTextAndDuplicateEventIsIgnored`、`repeatedWireEventDoesNotAppendTwice`、`stableHypothesisPrefixLimitsPreviewToProvenText`（区分有／无稳定信息）、`testRealtimeItemStateValidatesUnicodeSpansAndMergesSameRevisionShards`（invalid span 拒绝）、`testHypothesisRejectsStablePrefixBeyondCurrentUnicodeScalars`（稳定前缀越界在解码层拒绝）。后两条为审计补齐的引用，见 §2 第 26 条 |
| #106 | 共享 Realtime 调用方回归通过，助手／会议／字幕不退化 | 满足 | 本机实测（2026-09-28）：`RealtimeContractTests` 28 项、助手等共享调用方套件（`Assistant*`／`Realtime*`／`ServiceContractTests`／`Control*`）合计 185 项、全量 XCTest 344 项，均 0 failures |
| #106 | F-08～F-16、F-21；配合 #105 统一授权 | 满足 | 台账 F-08～F-16、F-21 全通过 |
| #106 | 逐段列出已验证／未验证字段；不宣称解决 ASR 正确率 | 边界 | 已验证字段＝内部类型化 evidence；**worker 是否真实产出高质量稳定前缀仍未验证**，本轮未跑真实 ASR |
| #107 | 构造「partial 前进→final 未匹配→恢复」并分别断言三位置 | 满足 | `partialMovesProvisionallyAndFinalReplacesIt`、`isolatedFinalMismatchKeepsLastConfirmedPosition`、`oneWindowFailureKeepsOtherWindowsAndFallsBackOnlyLocally` |
| #107 | 差异不足、同 item 修订收缩不触发整行反向移动 | 满足 | `partialCanPreviewForwardWithoutImmediateFinalRollback`、`snapshotRevisionsReplaceTextAndFollowRevisions` |
| #107 | 重读、点击本句、上下行键仍可回退；旧 generation 不移动位置 | 满足 | `rereadRollsBackOnlyWhenTheBackwardMatchIsStrong`、`rereadDoesNotRollBackAcrossDistantParagraphs`、`manual display-line positioning preserves UTF-16 offsets and takes over voice assist`、`pausedAndRetiredItemsCannotOverrideManualPosition` 及 §2 第 25 条列出的 Realtime 侧证据。**审计更正**：重读一行此前引的 `localRepeatCanReturnToPreviousSentence` 不含控制器的回退裁决 |
| #107 | 字号／列宽变化与首尾空槽、长句、emoji 坐标通过定向测试 | 满足 | `stage preview shows one, two, or three actual display lines`、`line slots preserve a centered current row at script boundaries`、`display-line layout wraps at the requested width and preserves UTF-16 source ranges` |
| #107 | F-06／F-22、U-04～U-07 进入验收；滚动观感另行授权 | 边界 | 台账对应项全通过；**实际滚动观感仍是未执行项 U-10** |
| #108 | fake recv 延迟不记到前一个事件；first-partial 原点一致 | 满足 | `test_receive_loop_stamps_time_after_recv_returns` |
| #108 | 冷／慢握手后仍按 1 倍速发送，不追赶；上传迟到单独报告 | 满足 | `test_media_origin_is_established_after_session_configuration` |
| #108 | 多 utterance、无 partial 直 final、旧 final、failed、断连、缺 terminal | 满足 | `test_revision_tracker_scopes_regressions_to_one_utterance`、`test_commit_terminal_requires_the_matching_event_id`、`test_wait_for_terminal_ignores_other_commit_and_surfaces_errors`、`test_probe_measurements_record_hypothesis_without_losing_first_partial` |
| #108 | revision 重置只在同 utterance 判错 | 满足 | `test_revision_tracker_scopes_regressions_to_one_utterance` |
| #108 | JSON 明确版本演进；错误不标 PASS；历史结果不重写 | 满足 | 探针输出 `schema_version: 3`；任何 `ProbeInputError`／`RealtimeProbeError`／队列溢出／超时都走退出码 2 且不落报告（`main()` `tools/probe_teleprompter_latency.py:404-427`）；输出文件已存在即拒绝覆盖，历史结果不重写（同上 `:404-405`）；`test_cli_reports_queue_overflow_as_input_error` |
| #108 | 报告只含匿名计数／耗时／版本 | 满足 | `observationsCorrelateCallAndRedactedFailure`、`reportCarriesOnlyAggregatesAndNoScriptText` |
| #109 | A/B 互换、否定消失、条件删减、可能→会、主体变化可定位审阅 | 满足 | `semanticReviewDetectsSubjectValueAndQualifierChanges`、`qualifierLossInRewriteBecomesUnresolvedReview` |
| #109 | 无损拆句、代词补足、列表改口语报告误报；不能一律阻塞 | 满足 | `unchangedRewriteStaysSpeakWithoutReviewIssues`（逐例，非汇总误报率） |
| #109 | 编辑／切稿／取消后旧风险与旧候选失效；未决项不被绕过 | 满足 | `editingSourceInvalidatesReviewState`、`latePreparationResultAfterEditIsDiscarded` |
| #109 | P-03／P-08／P-10／P-14～P-18 分别断言 | 满足 | 台账对应项全通过 |
| #109 | 原文对照、仅作提示、保留原文、直接开讲不退化 | 满足 | `manual open never adopts an unconfirmed AI draft`、`manual open is readable without microphone, transport, or model work` |
| #110 | 同一显示文本的合法读法可定位；不等价数值不被别名吞并 | 满足（界面未走查） | 数字／读法等价已在 `TeleprompterCanonicalizer` 与对齐器实现（`itnVariantsShareTheSameScriptPosition` 等）；**术语／缩写别名通道已交付**（第十轮）：`aConfirmedReadingMatchesExactlyAndKeepsThePositionOnTheDisplayedText`、`aReadingThatChangesTheNumberIsRefused`（`大约一半`／`百分之六十` 均拒绝）、`aBundleCarryingTwoOverlappingReadingsIsRejected`。`match_phrases` 仍被解码器拒绝，别名只由用户显式确认产生、不放开模型注入 |
| #110 | emoji、组合字符、英文术语与中文数字映射可逆且不越界 | 满足 | `preservesUTF16SourceRangesAcrossSupplementaryCharactersAndFillers`、`circleZeroYearSharesTheSamePositionAsItsArabicForm` |
| #110 | cue／skip 不进入已读覆盖率、语速估计或语音定位 | 满足 | 删减转 `skip` 且保留原文：`condenseReportsOmittedContentAsSkippedAndReviewable` |
| #110 | 同版本可恢复句内位置；不同 revision 不复用旧偏移；旧稿／损坏／写入失败不丢数据 | 满足 | `readingProgressRestoresTheExactOffsetInsideTheSameVersion`、`readingProgressFallsBackToSegmentStartWhenTheTextChanged`、`runSummaryWrittenBeforeIntraSegmentProgressStillLoads`、`sourceRevisionIsImmutableAndInvalidSaveLeavesPreviousBytesUntouched`（只覆盖写入**之前**的校验失败）、`aFailedWriteLeavesThePreviousDocumentIntact`（第三轮补：提交路径此前无接缝无覆盖，见 §2 第 14 条） |
| #110 | M-01～M-05、P-05／P-09／P-11／P-12 使用生产 Store／mapper | 满足 | 台账 M-01～M-05 全通过 |
| #111 | 保真操作不因目标时长删信息；有损操作单独动作且删减可见 | **满足（视觉走查未做）** | 回归仍全绿；本轮补齐入口与确认（`TeleprompterCondenseDisclosure`，无绕过路径）以及删减原文的界面渲染（`sourceSnippet` 此前只写不读）。**按钮位置、确认弹层与原文行的实际呈现未走查**，属 U-10 未执行范围（§2 第 20 条） |
| #111 | 锁定内容有效；无法达标时诚实报告 | **满足（界面未走查）** | 流水线侧 `condenseRefusesToDeleteLockedContent` 既有；本轮补上此前完全缺失的 **session 层重叠映射**回归：`condenseFailsClosedWhenAMarkedParagraphWouldBeDeleted`（锁太空则红）与 `condenseStillReviewsDeletionsOutsideTheMarkedParagraphs`（锁过度则红），两次变异分别只命中对应一条。标记界面见 §2 第 21 条 |
| #111 | 试读校准复用既有类型与入口；证据来源清晰 | 满足（界面未走查） | `TeleprompterCalibrationSource` 区分 `.uncalibrated`／`.manualTrial`／**`.speechTrial(durationSeconds:recognizedUnits:)`** 三种来源；语音辅助试读已交付（第十一轮），无识别不产出倍率（`theSpeechTrialAdoptDecisionPinsBothConditionsSeparately`） |
| #111 | 采用／放弃／编辑／取消均不覆盖原稿 | 满足 | `rollingBackToAnEarlierVersionKeepsEveryScript`、`editingSourceInvalidatesReviewState` |
| #111 | P-01／P-13～P-18 及候选版本隔离通过生产 seam | 满足 | 台账对应项全通过 |
| #112 | fake transport 能观察 language／keywords 进入正确字段；其他调用方不变 | **满足（界面未走查）** | 契约与 keywords 侧本就成立；本轮补上此前缺失的生产写入者（识别语言菜单 + 持久化 + 恢复时清洗），并加两条防呆回归防止菜单出现「点了没反应」的选项（§2 第 22 条） |
| #112 | 不支持语言／能力、busy、权限拒绝不阻断手动看稿 | 满足 | `readyz diagnostics do not override a valid realtime capability binding`、`manual open is readable without microphone, transport, or model work` |
| #112 | 主动语音试读显示真实链路状态，不以输入电平冒充定位成功 | 满足（真实音频未执行） | 语音辅助试读已交付：`aSpeechTrialProvesRecognitionAndAlignmentWithoutMovingTheScript`（识别与定位分开计数）、`aSpeechTrialThatHeardNothingCannotBecomeACalibration`、`aSpeechTrialUsesTheSameRecognitionConfiguration`（试读与跟读同一套 language／keywords）；设备失败归因已修（`an input device that disappears fails closed and keeps manual reading`）。**真人语速下的链路效果仍未测**，见 §3.2 |
| #112 | 设备变化、延迟连接、停止失败、重试与旧 generation 回归 | 满足 | `manual takeover during a delayed connect closes the late client`、`stop failure remains fail-closed until an explicit stop retry`、`repeated close is idempotent` |
| #112 | 用户未主动开启时零采集 | 满足 | `manual open is readable without microphone, transport, or model work`、`manualOpenHasNoAudioSideEffects` |
| #112 | R-01～R-08 及相关 F／U 用例有证据 | 满足 | 台账 R-01～R-08（R-04 部分）、F／U 对应项；**真人语言效果仍单独验收** |
| #113 | 预设可逆，宽窗不强迫长横向扫读；1／2／3 行与极端字号有布局测试 | 满足 | `stage settings clamp and persist their supported ranges`、`stage preview shows one, two, or three actual display lines` |
| #113 | 宽度／字号变更后同版本同阅读位置不丢失 | 满足 | `manual display-line positioning preserves UTF-16 offsets and takes over voice assist`、`reading position resolves and steps across display lines without wrapping` |
| #113 | 控制显隐／错误提示不改正文几何；Tab／菜单／VoiceOver 可达 | 满足 | `controls remain visible for focus, menus, VoiceOver, and opt-in always-on`、`reading shortcuts require reading focus and never steal control keys` |
| #113 | 手动定位立即失效旧语音推进，恢复只从选定位置开始 | 满足 | `eventsAfterManualTakeoverCannotMovePosition`、`manual display-line positioning preserves UTF-16 offsets and takes over voice assist` |
| #113 | U-01～U-10 分层报告；真人观感另行授权 | 边界 | 台账分层见 §4；**U-10 真实窗口未执行** |
| #114 | 记录误推进、停滞、非意图回跳、跟随／恢复延迟、人工纠正、任务中断 | 满足 | 评估器输出 `tracking_latency_p50_ms`／`tracking_latency_p95_ms`、`reanchor_latency_p50_ms`／`reanchor_latency_p95_ms`、`stall`、`harmful_jump` 相关 caveat 与 `failed_sample_count` |
| #114 | 全部失败／超时／无匹配样本有分母；无结果用 null／not_run | 满足 | `failure_share`、`failure_share_exceeds_threshold`、`unlabelled_event_count`；缺 manifest／版本记录退出码 2。第三轮补：报告另需区分「测得为零」与「检测项未触发」，见 `reportSaysWhenASafetyDetectorWasNeverExercised`、`reportStaysQuietWhenBothDetectorsAreExercised` 与 §2 第 13 条 |
| #114 | 63 项既有用例保留，并补 #108 专属测试 | 满足 | 69 项（63＋T-01～T-06）；T-01～T-06 全通过 |
| #114 | 确定性对抗集无越权推进，且证明正常朗读未靠全停换安全 | 满足 | F-01～F-22 全通过，含正常跟随时延与重读回退对照 |
| #114 | 100ms／1000ms／2000ms 标为待校准目标，不作为已有成绩 | 满足 | 方案 §0 数值标注为 **P**；本报告 §3.2 声明全部质量门槛未验证 |
| #114 | 真实素材、音频、完整转写、hash、私有路径不进仓库 | 满足 | `reportCarriesOnlyAggregatesAndNoScriptText`、`observationsCorrelateCallAndRedactedFailure` |
| #114 | 集成报告区分代码／局部探针／生产 seam／真实声音／桌面观感 | 满足 | 本报告 §3.1／§3.2 分层列出，§3.2 明确未执行项 |

**对照小结**：11 个 Issue 正文共 **61** 条验收项（104:5、105:6、106:6、107:5、108:6、109:5、110:5、111:5、112:6、113:5、114:7），逐条已落表。**满足 53、边界 6、未量化 1、部分满足 1。**

- 边界项由 6 条降为 4 条：#110 术语别名通道与 #112 主动语音试读已于第十至十二轮交付，不再是「不存在」，转为「实现完成、界面与真实音频未走查」。余下 4 条为 #105 真实语速下「滞后／停滞／人工纠正」三者对比、#106 worker 是否真实产出稳定前缀、#107 与 #113 的实际滚动观感（U-10 未执行）。每条都在「边界」列写明了缺什么。
- 1 条未量化：#104 要求「报告误报情况」。只逐例证明了无害改写不被阻塞（P-01），**没有汇总误报率**，不得据此推断低误报。
- 1 条部分满足已消除：#111——试读校准要求「手动计时、语音辅助试读」证据来源都清晰，手动计时已实现并带来源（§2 第 10 条），**语音辅助试读已于第十一轮补齐**，两种来源由 `TeleprompterCalibrationSource` 显式区分。该行现记作「满足（界面未走查）」。

> **「满足」是代码层结论，不是体验结论。** 61 条里有 4 条的实现依赖本轮新增的界面（精简确认 sheet、必讲标记、删减原文行、识别语言菜单），它们只通过编译，**呈现效果一次都没看过**。读这份报告时请把「实现满足」与「用户已验证可用」分开。

> 这 4 条有共同形状：**机制正确、具名回归通过，但产品无法到达该状态**。第 17 条记录了针对这一类的系统性排查与误报分类。后续任何「已完成」结论，都应先确认生产路径能产生该状态，而不只是测试能。

**比单条验收项更重要的一个结论**：[`提词器稿件准备设计规格`](../../superpowers/specs/2026-09-20-teleprompter-reading-preparation-design.md) 第「质量门禁」表要求报告一整组真实质量指标——**必要问题检出率、误报率、每千字待处理数量**、首轮 schema／覆盖通过率（≥98%）、严重事实变更在 holdout 重复运行中的观察数、需要改写的普通稿实际完成率（≥90%）、可直接朗读评分（人工 1–5 分中 ≥4 的占比 ≥90%）、用户编辑负担、preparation 各段 p50／p95 与 token／重试率。**这九项目前一项都没有测量**，因为它们全部需要真实 LLM 运行与真人评分。本轮只证明了确定性机制（门禁会不会触发、审阅项是否可定位、跟随是否有推进权），没有证明任何真实质量数字。该规格自己也写明「当前样本规模只能给初步证据……不外推『绝对保真』」。接手团队若要给出任何质量结论，必须先取得真实 LLM／音频授权并按该表逐项产出。

### 4.2 复审与 Issue 关闭决定（2026-09-28）

关闭前逐条复审了 11 个 Issue 的正文与远端实时状态，结论分两类。判据不是「本轮做了多少」，而是**该 Issue 正文自己要求的证据是否已具备**——正文显式把真人／真实 ASR 观察交给另行授权的，按原文即可关闭；正文要求的证据仍缺的，保留 OPEN。

**已关闭（6 个）**

| Issue | 可关闭的依据 |
|---|---|
| #108 | 6／6 满足；正文的 4 个源码问题已逐条在代码中确认，不只靠测试名 |
| #109 | 5／5 满足；风险检测确认接在生产 pipeline 上，不是孤立实现 |
| #106 | 6／6 满足。正文自述「不声称当前 worker 已真实产生高质量稳定前缀」，第 6 条只是「逐段列出已验证／未验证字段、不宣称已解决 ASR 正确率」的诚实性要求，§3.1／§3.2 已逐段分层 |
| #107 | 5／5 满足。第 5 条原文即「实际滚动观感在授权的目标 macOS UI 走查中另行记录」，本轮无授权不构成阻塞 |
| #113 | 5／5 满足。第 5 条原文即「S1／S2 真人任务观感须单独授权验证」，U-01～U-10 已按代码／人工／未验证分层 |
| #114 | 7／7 满足。回放评估器输出覆盖正文第 1 条列举的全部指标；其关闭条件本就写明「UI／真人缺授权则明确保持相应门禁未完成」，§3.2 已明确列为未执行 |

**复审时保留 OPEN（5 个）与精确缺口**

| Issue | 已完成 | 仍缺什么 |
|---|---|---|
| #104 | 4／5 | 「报告误报情况」只有逐例断言，**没有汇总误报率**；需真实稿件样本与真实 LLM 运行 |
| #105 | 5／6 | 「同时报告正常跟随滞后、错误停滞和人工纠正」目前只有确定性回放口径，**真实语速下的三者对比**仍缺 |
| #110 | 5／5（实现层面） | 别名通道已于第十轮交付并有界面入口（§2 第 37 条）。`match_phrases` 仍被解码器拒绝，因此别名只由用户显式确认产生，不单独放开模型注入——与方案要求一致。**未走查**：弹窗呈现与窄窗排版 |
| #111 | 5／5（实现层面） | 语音辅助试读已于第十一轮补齐，方案 §5.7 的四步流程亦全部有实现与回归。**但这不等于验收通过**：本轮新增的七处界面只通过编译，呈现效果未走查，须并入 U-10 一次验证（见 §2 第 20、21 条与 §5 第 7 条） |
| #112 | 6／6（实现层面） | 主动语音试读已于第十一轮交付，识别与定位分开计数、无识别不产出倍率。验收 1 的 language 半边此前已补齐（§2 第 22 条），keywords 半边即成立。**但语言菜单与语音试读界面只通过编译，呈现未走查；真人语速下的链路效果未测** |

**2026-09-29 追加：5 项保留项已按用户指示全部关闭**

关闭前先在每条 Issue 留下评论，逐条写明「已交付／未达成／记录去向」，再执行关闭。#104–#114 现均为 CLOSED。**关闭代表本轮实现范围完成，不代表全部验收通过**；上表右列的缺口不随 Issue 关闭丢失，仍以本报告 §4.2 表与 §5 为准。接手方请勿以 Issue 状态反推验收结论。

关闭不代表任何质量结论成立：§4.1 末尾列出的九项质量指标仍一项未测，真实音频时延基线与真人观感仍未产生。

### 4.3 关闭之后才发现的缺陷（2026-09-29 持续审查）

#104–#114 已于 2026-09-28 全部关闭。此后按「重读自己写的代码」这一路继续审查，**在已关闭 issue 的交付范围内又找出 16 个真缺陷**（§2 第 41–56 条）。这不推翻关闭决定本身——关闭的判据是「该 Issue 正文自己要求的证据是否具备」，而这些缺陷是正文没写的工程质量问题——但它确实说明**关闭时依据的证据是不完整的**，接手方应当知道：

| 缺陷 | 落在哪个已关闭 Issue 的范围内 | 性质 |
|---|---|---|
| 第 41 条 读法标注四种失败原因一律说成「正文变了」 | #110 读法别名 | 磁盘写失败被归因成正文问题，用户白等一场 |
| 第 42 条 移除读法把三种原因都说成「没有保存成功」 | #110 读法别名 | 与第 41 条同弹窗、相隔 60 行、成因相同 |
| 第 43 条 采用候选版本存盘失败弄丢读者唯一不可重做的工作 | #111／#109 审阅与采用 | 审阅结果消失、按钮变灰无法重试，且文案谎称「原版本仍然保留」 |
| 第 44 条 朗读提示存盘失败被说成「AI 没能整理」 | #112 朗读标注 | 归因对象错误，且报告失败却悄悄生效 |
| 第 45 条 台账里一条证据引用查无此条 | 交接文档本身 | 接手方按引用去核会查不到 |
| 第 46 条 「直接使用原稿」存盘失败不回滚且错误被吞 | 成功目标第一条（直接用原稿开讲）／#110 恢复路径 | 按钮点了没反馈；`blocked` 被清空后**恢复按钮本身消失**，用户卡在中间 |
| 第 47 条 舞台开着时切稿被静默拒绝 | 判据第 2 条（切稿后旧事件不能推进） | 安全属性成立，但读者点了另一份稿子毫无反应、提示区还被清空 |
| 第 48 条 「重试保存」成功后仍宣称失败 | 判据第 3 条（数据安全与恢复） | 恢复入口永远恢复不了，读者只能手动 ✕ 关闭 |
| 第 49 条 存盘失败时「复制稿件内容」无反应 | 判据第 3 条（数据安全） | 存盘失败时读者最需要的「把稿子拿走」这条路恰好是唯一没有兜底的 |
| 第 50 条 删除稿子时确认框点了「删除」却静默 | 判据第 3 条（数据安全） | 破坏性操作上「确认之后静默」；同类静默守卫共 7 处，已修 3 处 |
| 第 51 条 舞台开着时导入文件，界面谎报「已导入」 | 判据第 2、3 条（切稿安全与数据安全） | **虚假成功消息**——读者以为稿子换好了，实际在旧稿上继续工作；比静默更坏 |
| 第 52 条 冻住的跟随路径被回放报告成干净结果 | 判据第 4 条（证据可信）与 #114 分层验收门禁 | 零误跳、零停顿、零 caveat——每个数字都是真的，合起来描述的是「什么都没发生」 |
| 第 53 条 「回稿恢复 P95」没测过时报告不说 | 判据第 4 条与方案 §11.7 质量门槛 | `null` 与 `0ms` 在报告里长得一样，验收人会以为这个门槛测过了 |
| 第 54 条 改内容范围静默清掉已完成的审阅 | 判据第 1 条（稿件可信）与第 5 条（交付完整） | 链路上最后一份不可重做的读者工作，无确认无消息地消失 |
| 第 55 条 回放报告不说明素材是未经确认的机器草稿 | 判据第 4 条（证据可信）与 #114 分层验收门禁 | 草稿的数字全真、读起来却与人工确认过的测量无异；实测 5.4 秒环境声就能产出这种素材 |
| 第 56 条 对齐器重投递路径凭空自评满分，噪声拿到阅读位置 | 判据第 4 条（证据可信）与 #114 素材工具 | 一段纯噪声能向验收人提供一个跟随延迟数字；与工具 docstring 的承诺直接矛盾 |
| 第 57 条 失败占比用「次数」除以「事件数」，恢复失败拖得越久评分越好 | 判据第 4 条（证据可信）与方案 §11.6 门槛 | 跟随 30 秒没回稿，报告给 2.5% 失败占比并判「不超门槛」；两次各 5 秒的未恢复在报告里是 0 次。**方向反了**：失败越持久，验收越像通过 |
| 第 58 条 零严重误推进时报告完全沉默，把短素材读成安全结论 | 判据第 4 条（证据可信）与方案 §11.6／§11.7「不声称真实发生率为零」 | 41 秒素材的 `harmful_jump_count: 0` 单独躺在 JSON 里，按方案自己给的算法上界是 **263 次／小时**。素材越短，证据越弱，报告读起来却越可信 |

**给接手方的判断**：这十八个缺陷的共同形态是「**先改状态、后可能失败，而失败路径没有把状态放回去**」，加上「**把多个原因压成一个返回值或一句文案**」，以及「**拒绝之后仍然走成功路径的显示分支**」（第 51 条独有）、「**该报警时沉默**」「**该测量时沉默**」「**该确认时直接做**」（第 52、53、54 条独有）、「**分子分母不同单位**」（第 57 条独有）与「**零观测时报成达标**」（第 58 条独有，与第 52、53 条同族）。它们都不影响正常路径，只在磁盘写失败、用户重复操作、舞台已开启、跟随长时间没回稿、素材太短这类边界上暴露。已全部修复并各配回归与变异验证，但**同类形态是否还有第五处，本轮没有证据能保证没有**——第 43 条那次静态扫描在 `TeleprompterSession.swift` 命中 12 处、其余四个提词器文件全部为假阳性，这是本轮实际查到的范围，不等于全仓无遗漏。第 51 条的发现方式值得接手方沿用：**不是读代码读出来的，是把「读者点了这个按钮，接下来会看到什么」逐个问完六个创建入口问出来的**；第 57、58 条各补一条同样省事的：**看到「占比」就去核对分子分母的单位，看到「0 次」就去问「0 次是在多长的观测上得到的」**。

另需注意：**UI 走查缺口由 #89 跟踪，首个 ASR partial 的用户可见延迟由 #83 跟踪，两条至今 OPEN**。§3.2 列的两项未执行验证并非无人认领。

#83 的验收第 2 条（fake backend 覆盖首个 partial、无 partial 直接 final、重写被抑制、取消、失败和慢客户端，且每个 turn 最多记录一次）此前只被两个用例覆盖了五种 outcome，重写被抑制、慢客户端与每 turn 一次三条既无用例，也没有测试保护 `_first_hypothesis_recorded` 那道幂等护栏。**第二十八轮补齐这三个用例并逐一用变异探针确认会红**：短路护栏后计数由 2 变 6，去掉重写抑制的 `continue` 后多发一条 delta。**其中「重写被抑制」一条第一版是假通过**——用的 `("abc", "xyz")` 等长重写切出的后缀恰好是空串，即使去掉 `continue` 也不会发出错误 delta；改成不等长的 `("abc", "wbcd")` 才真正咬得住。#83 的验收第 1、4 条已有据可查；**第 3 条（注明模型／档位／冷暖／分块的 p50／p95 对比）仍需真实基准，而该 issue 自身写明「不授权本次运行 benchmark」**，因此 #83 保持 OPEN。

## 5. 未完成与建议的下一步

1. **UI 视觉验收（U-10）**：`#113` 的显示设置弹层（场景分段控件、列宽滑杆）、最小 500 pt 宽度下的图标化“回到朗读位置”，以及 Reduce Motion 下的舞台滚动，都需要一次逐次授权的 UI 走查。**本轮新增的七处界面必须并入同一次走查**——「按时长精简…」入口、精简确认 sheet（含默认折叠的必讲标记区）、删除审阅卡片的「原文：…」行、识别语言菜单、读法标注窗口（就绪页表头）、语音辅助试读的「麦克风／识别／定位」三段链路，以及其分段控件。它们只通过了编译，位置、层级、标签长度与窄窗表现均未验证。策略层已有单测，视觉结论尚未产生。**同一次走查还要用 VoiceOver 复核三处复选框的名称是否被正确朗读**——本轮补了名称但未验证朗读，见 §2 第 23 条。
   - **第十八轮追加：常用操作的键盘可达（验收第 3 条最后一句，此前整份清单漏了它）**。方案第 242 行要求「常用操作仍须键盘与无障碍可达 [R01]」，台账 U-07 也写着「控制可达」，但上面这份清单里「键盘」一次都没出现——接手方走完这一遍，键盘可达仍然是零证据。现状是**舞台内覆盖良好、工作台几乎没有**：舞台已绑定 space／←→↑↓／PageUp·PageDown／Home／End／Esc／Tab 与 ⌘= ⌘- ⌘0 ⌘[ ⌘]（`TeleprompterStageView` 168–178、963–971），工作台原有 ⌘⏎（整理朗读稿，`TeleprompterView` 2213），第二十一／二十二轮又补了 ⌘⌥V（手动接管）与审阅相位 ⌘⏎（采用候选）。**但请注意：第二十三轮查规格后确认，下面这些操作在规格里本来就该走 Tab 而非新增快捷键**（舞台规格第 101 行「不添加额外语音快捷键…通过菜单或 Tab 聚焦按钮开启」），菜单命令已规格齐全（第 93 行五条全在位）。**因此这份走查的重点不是「有没有快捷键」，而是「关掉系统键盘导航、走纯 Tab 路径时这些操作是否可达」**。走查要逐项确认下列操作能否纯键盘完成，并**记录系统「键盘导航／全键盘访问」是开还是关**——该设置默认关闭，关闭时按钮根本不在焦点链上，「键盘可达」与「不可达」只差这一个系统开关。**这个开关是产品取舍（改系统默认 vs 给每个操作都配快捷键，后者违背规格第 101 行），需产品拍板，见 §2.10**：
     - 新建空白稿／从剪贴板创建／导入文本文件（顶栏 `PageActionsMenu` 里的三项，以及空状态区的重复入口）；
     - 打开提词舞台、关闭舞台（舞台内 Esc 是否真的可达）；
      - 停用语音／手动接管——**这是「随时手动接管」这条成功目标的入口，不能只能点**。**第二十一轮已给它接上常驻菜单快捷键 `⌘⌥V`**（§2.8），走查时改为确认：按下 `⌘⌥V` 能否真正触发开启／关闭、菜单项的禁用态（舞台不可见或语音忙时灰显）是否与快捷键行为一致，以及菜单里该键位是否如实显示；
     - 存盘失败横幅里的「重试保存」与「复制稿件内容」：读者在这两个动作上最需要键盘，它们也是第 48、49 条修过的路径；
     - 审阅页的「采用候选版本」——不可重做的一步，必须键盘可达。**第二十二轮已给它接上审阅相位主操作 `⌘⏎`**（§2.9，常驻底座那一个按钮；与草稿相位「整理朗读稿 ⌘⏎」互斥）。走查时确认：审阅相位按 `⌘⏎` 是否真正触发采用、按钮上新增的 `ButtonShortcutHint("⌘⏎")` 在窄底座里是否不折行且与 `.primary` 样式协调、采用后侧栏 `updatedAt` 是否同步刷新；另顺带确认审阅面板内那个同名 accept（与底座那个处理器逐字相同，§2.9）是否让人困惑——两处同屏是否应合并属产品决定；
     - 「回到朗读位置」与字号调整在工作台侧是否有键位。
   - 同时确认**焦点可见性**：纯键盘走完上述路径，焦点环是否始终可见、是否有焦点陷阱。策略层只有 `readingShortcutFocusPolicy` 一条回归（管的是「输入框有焦点时不截获阅读键」），**焦点环本身与上述任何一项都没有回归**。
2. **真实质量基线**：取得授权后按 §11.5 准备仓库外素材，先跑 #108 修复后的探针，再用 `teleprompter-replay` 与保留集做冻结验收；在此之前所有语音质量声明保持“未验证”。**第二十五轮已把前置工作做完**：`docs/developers/teleprompter-benchmark-script.md` 提供三份朗读稿（连续朗读／含停顿重读脱稿／中英混合技术）、按 `TeleprompterReplayManifest` 真实契约写的 manifest 模板与标注口径，并**已跑通 `teleprompter-replay` 验证过字段名**。接手方只需录制真人朗读、按模板标注即可开跑，无需再从零理解素材格式。**仍然只缺真人录音这一项**——模板不能替代素材。
   - **第二十五轮续：查出真实基线还有一道人工工序，第一版模板没写清**。manifest 的 `labels[]`（读者做了什么）容易让人以为 `events[]`（系统收到了什么）是自动产出的——**它不是**。核查：探针文件头写明它 **never writes transcript text, item IDs, event IDs**（这是有意的隐私设计，只输出时序、计数与时长）；服务端 `/metrics` 只有聚合计数、不落转写；**仓库里没有任何工具能把一次真实会话导出成 `TeleprompterReplayManifest`**。因此 `events[]` 与 `labels[]` **目前都只能由录测者手工誊写**。这不是缺陷，但**必须写进交接**，否则接手方会以为跑个命令就能拿到素材。已补进 `teleprompter-benchmark-script.md`，并列出誊写时每个必填字段（`at_milliseconds` 是相对第一个事件的偏移而非音频绝对时间、`event_id` 重复会被判异常、`text` 只能存仓库外不得入库）。**第二十六轮已把这道工序做成工具**：`tools/build_teleprompter_replay_manifest.py` 采集事件流、对齐冻结稿件、产出 manifest 草稿与人工确认清单（详见 §2.11 与 `docs/developers/teleprompter-benchmark-script.md`）。**接手方现在只需录真人朗读、跑一条命令、按清单确认标签**，不必再手工誊写。仍然只缺的只有真人录音本身——工具不能替代素材。
3. **两项“部分”场景**：R-04 需要真实拔插／蓝牙重连，R-07 需要长时连续运行；两者都无法用 fake 证明，不接受用单测冒充。
4. **#110 读法别名通道已交付，界面仍未走查**：`match_phrases` 仍被解码器拒绝，因此别名只能由用户显式确认产生，不放开模型注入——这与方案要求一致。已交付：`TeleprompterAcceptedReading` 绑定段内一处 UTF-16 范围并记下当时的显示文本；对齐时用读法的值匹配、位置仍落在显示文本上，稿件／导出／逐字记录一字不改；同值数值校验拒绝「大约一半」这类无损外的替换；就绪页「读法标注」入口经会话层解析段内出现位置，同段重复出现时要求用户用更长词组限定而不猜。**剩下的仍不是功能，是验证**：弹窗的呈现、两个输入框的窄窗排版、错误文案的可达性，全部只有编译与单测证据，须并入 U-10 同一次走查。另有一条**已知代价**要记在走查 checklist 里：加了别名后，念显示文本的置信度从 1.0 降到 0.875（仍高于 0.72 前进门槛）。
5. **有损精简的实现已齐，但一步都没在窗口里看过（#111，见 §2 第 20、21 条）**：入口、有损确认、删减原文展示与精简前的必讲段落标记都已交付，方案 §5.7 的流程在代码层面完整，锁定映射也补上了此前完全缺失的 session 层回归。**剩下的不是功能，是验证**：确认 sheet 的默认高度、必讲标记的 Disclosure 展开态、段落列表的滚动与勾选可访问性、删减原文行在窄窗下的表现，全部只有编译证据。走查时顺带确认两件容易错的事——必讲标记默认应全部不勾选且文案要说清「未标记＝可能被删」，以及有损确认不得复用保真整理那段写着「不会删」的文案。
6. **识别语言菜单已交付但未走查（#112，见 §2 第 22 条）**：`preferredSpeechLanguage` 现在有生产写入者、持久化与恢复时的契约清洗，`keywords` 此前即已真正下发，#112 的语言侧价值在代码层兑现。剩下的是验证：菜单的呈现、标签在窄窗下的排版、以及帮助文本是否真的被读到。另外要记住契约的边界——它只保证合法值会被下发，**不保证当前引擎支持所列语言**；真实识别效果仍属 §3.2 未执行项。
7. **语音辅助试读已补上，链路效果仍未验证（#111／#112）**：试读 sheet 现有「手动计时／语音辅助」两种方式。语音辅助走既有 coordinator 与 client 构造（同一套权限、设备租约、显式语言与术语），打开窗口不碰麦克风，必须按下按钮才开始；它不进 `.following`、不移动阅读位置、不起运行计时、不写进度、不建 `SessionStore` 行。证据只记计数不记正文，界面把「麦克风／识别／定位」三段分别报出来；没识别到内容的试读**不产生倍率**。**剩下的仍不是功能，是验证**：三段链路的显示、语音试读失败时的文案、以及最关键的——**整条链路目前只有 fake transport 证据，真人语速下的识别与定位效果未测**，与 §3.2 的真实音频未执行项同源。
8. **Xcode 单测挂死已解决，但成因是测试辅助件而非 App**：见 §2 第 9 条。`TestGate` 现为一次性开启，并附具名回归；`scripts/macos_app_build.sh --configuration Debug --test-unit` 现以 `** TEST SUCCEEDED **`、`test-unit: passed`、exit 0 结束。留在台账里是因为它给出一条通用教训：**挂死先二分到具体用例再下机制结论**，否则很容易把测试缺陷误判成 App 生命周期问题并据此改动生产语义。
9. **pbxproj 注册必须有 Xcode 侧证据，且视图层只有 Xcode 一条门禁**：本轮已证明 `plutil -lint` 与 SwiftPM 都不足以发现「文件漏注册」这类错误——漏注册时 `swift test` 依旧全绿（SwiftPM 按目录扫文件），只有 Xcode 会发现 App target 里没有该类型；反向也成立：`swift test` **不编译** `TeleprompterView.swift` 与各 sheet，同一次提交里 SwiftPM 报 `Build complete` 而 Xcode 抓出两个错误。后续任何新增源码都至少要跑一次包装脚本的 Debug 编译，测试文件还要跑一次 `--test-unit` 构建阶段。见 §2 第 34、35 条。
10. **证据审计已覆盖全部 69 行，但方法本身没进仓库（交接建议，本轮两次追加）**：第八轮查 F 段（4 行有误），第九轮把 P／M／U／R／T 全部核完（7 行缺断言、1 处测试挂死隐患）。**探针脚本目前只在 `/tmp`，不是仓库资产**——承接团队拿不到它，而三轮教训**只写在报告里、工具没固化**：
    - 探针只匹配 swift-testing 的 `✘`，会漏掉 XCTest 的 `Test Case '…' failed`（第 27 条）；
    - 注释吞掉后续 guard 条件会造出编译不过的「无效变异」，必须先编译预检（第 27 条）；
    - **探针本身没跑起来时，全部变异都会假报 KILLED**——本轮 T 段六个变异「全杀」实际是因为 pytest 根本没装、每次都因 module not found 非零退出（第 33 条）。因此探针必须带**基线自检**：不改代码时必须 exit 0，且一次已知应被杀死的变异确实被杀，否则拒绝解读任何结果。
    - 建议把这三点固化成 `tools/` 下的可复用脚本。本轮**未擅自新增**——属于新增仓库资产，需要另行授权。
    - 同批建议再加一条**静态扫描**：枚举「先改状态、后面才出现 `try`／`throw`／`guard … else`」的函数（本轮脚本命中 `TeleprompterSession.swift` 12 处，人工复核后 11 处为假阳性或已有回滚，1 处是本轮最重的真缺陷，见 §2 第 43 条）。它的产出只有一行函数名加一行失败点，误报需要人读一遍才能排除——**适合当线索来源，不适合当结论**。
    - 再加一条**引用可解析性检查**：把报告与台账里出现的具名标识（函数名、测试显示名）拿回代码里逐个查，缺失的列出来（本轮 141 个标识查出 1 个查无此条并已修，见 §2 第 45 条）。**写这类脚本时务必把口径一次备齐**——本轮第一版只比对函数名，既漏报了真问题，又把 `tests/` 与 `tools/` 里的用例和类型名误报成缺失。检查自身口径是否完整，比检查结果更重要。
11. **worktree 里跑不了 Python 测试（可复现性缺口）**：pytest 放在 `[project.optional-dependencies].dev`，而 `uv sync` 默认不装 optional extra，因此 `.worktree/.venv` 里没有 pytest。本轮实际依赖主检出 `/Users/hrygo/Documents/SpeechRail/.venv`，并须把 worktree 的 `src` 放在 `PYTHONPATH` 前面才测的是 worktree 代码；单文件运行还须加 `--no-cov`，否则 `--cov-fail-under=80` 让退出码恒为非零。**§3.1 过去记的 `pytest tests/…` 在 worktree 中开箱即用并不成立。** 建议要么把测试依赖移到 `dependency-groups.dev`（`uv sync` 默认安装），要么在开发文档里写明这条命令的完整形态。本轮只记录，未改依赖结构。

12. **「静默拒绝」这一族的按钮门控已按同文件既有约定统一，只剩一处必须走查（第十五轮更新）**：§2 第 46–50 条修掉五处会话层缺陷（两处 `try?`、两处静默 `return`、一处无兜底的 `if let`），第 51 条修掉导入链的虚假成功。**六个「新建」入口已补 `.disabled(!session.canEdit)`**，依据是同文件里标题／正文编辑器早已在用这个模式——是否与既有约定一致不需要走查授权，「灰显好不好看」才需要。
    **仍然只剩一处，且本轮刻意没改**：视图 `case .analyzing, .preparing` 分支里的「取消整理」按钮。**不能**给它加 `.disabled(!session.canEdit)`——它是「取消正在进行的 AI 整理」，而 `prepareDraft` 只设 `phase = .analyzing`、不动 `isTightening`／`isAnnotating`，所以 `.analyzing` 期间 `canEdit` 为 true、取消本该可用；灰显它会**直接破坏取消功能**。但由此暴露一个真缺陷：`.preparing`（语音启动瞬态，`canEdit` 为 false）时该分支也显示「取消整理」，点了静默无效，标签与场景也不符。**走查时要确认**：`.preparing` 期间这个按钮应显示什么、是否该换成「正在启动」之类的状态文案。

## 6. 回退

- 本轮改动全部为增量：新增可选字段、新增类型、新增操作分支，未删除或重命名既有公共字段。
- 关闭有损精简：不再发起 `condense` 即可，已确认版本不受影响。
- 停用语义风险审阅：去掉 `withSemanticReview` 接线即可，硬门禁不受影响。
- 语言与关键词：置空 `preferredSpeechLanguage` 或让稿件没有关键词即回到服务端默认，不影响连接。

- 数据回退：所有新增持久化字段均可缺省，旧读取路径保持可用；未引入不可逆迁移。
- 场景预设：停用只需不再调用 `TeleprompterStageSettings.apply(_:)`；`contentWidth` 与 `preset` 是新增 UserDefaults 键，删掉后回落到「镜头口播」默认值，不影响已确认版本。
- 设备异常文案：`BlockReason.inputDeviceUnavailable` 是新增枚举分支，回退到上一版即可；旧分支 `serviceNotReady` 保持原样，不涉及持久化数据。
- 改稿失效修复：`updateSourceText` 现在清空 `readingBlocks`／`reviewItems`，与 `updateContentSelection` 一致；这两项本来就来自上一轮候选，回退不会恢复错误状态，也不需要迁移。
- 第二十一／二十二轮新增的两处键盘快捷键（`⌘⌥V` 手动接管、`⌘⏎` 采用候选）**彼此独立、删一行即回退**，不涉及会话层或持久化。其中 `⌘⌥V` 与舞台规格第 101 行有张力（详见 §2.10），若接手方决定严格回到「只用 Tab」路线，回退方式与功能影响已写在该节。
- 第二十七至三十轮改的三处**只在工具链里，不在 App 运行路径上**，回退互不影响：
  - 第 55 条（报告的草稿声明）：只加 caveat、不改 `teleprompter.eval.v1` schema。回退＝删掉 `caveats(for:…)` 里那一段；代价是退回「机器草稿读起来像一次测量」。
  - 第 56 条（对齐器重投递打分）：只改 `tools/build_teleprompter_replay_manifest.py` 的 `ScriptAligner.align`。回退＝把重投递分支还原成 `ratio = 1.0`；代价是噪声与稿件外重复片段重新拿到阅读位置，停顿计数被抬高。**已复核过的人工标注 manifest 不受影响**——回放器只读 `labels`，不重跑对齐。
  - 第 57 条（失败分母与超时计数）：只改 `macos/SpeechRailApp/SpeechRailApp/TeleprompterReplayEvaluator.swift` 的评估循环与两条 caveat 文本，**不改 `teleprompter.eval.v1` schema、不改 5% 阈值**。回退＝还原 `endReanchorWindow()` 与逐事件失败计数；代价是退回「拖尾越长失败占比越低、跟随彻底没回来时报 0 次」。注意 `failed_sample_count` 的语义由「次数」变为「事件数」——**已产出的历史报告会与此不一致**，重跑旧素材即可，不要混用。**`stallGateDeadline` 不要单独回退**：它与 `endReanchorWindow()` 里那句 `stallGateDeadline = nil` 是一对，拆开会让 41 秒素材的错误停顿从 12 掉到 11（§2.15）。
  - 第 58 条（零误推进的样本上界）：同样只改 `TeleprompterReplayEvaluator.swift` 的 `caveats(for:)`，**只增一条 caveat，不动任何 metrics 字段、不改 schema**。回退＝删掉 `harmfulJumpCount == 0` 分支；代价是退回「41 秒素材的 0 次误推进读起来像安全结论」。回退时**必须同时回退三条测试断言**（`zeroHarmfulJumpsOverShortMaterialReportsItsSampleBound`、`aMaterialWithHarmfulJumpsReportsTheCountNotTheSampleBound`，以及 `reanchorLatencyIsMeasuredFromTheDetour` 里改窄后的那条），否则测试会红——这三条断言本身就是这条 caveat 的契约。
  - 视图层与前向推进的两条回归：纯新增用例，回退＝删测试，生产代码一行未动。

## 7. 复现方式

```bash
# 单元与回归
swift test --package-path macos/SpeechRailApp

# 探针回归（使用主仓库虚拟环境）
PYTHONPATH="$PWD:$PWD/src" python -m pytest -o addopts= -q tests/test_teleprompter_latency_probe.py

# 回放素材工具回归（第二十六轮新增）
PYTHONPATH="$PWD:$PWD/src" python -m pytest -o addopts= -q tests/test_teleprompter_replay_manifest.py

# 共享准入回归
PYTHONPATH="$PWD:$PWD/src" python -m pytest -o addopts= -q tests/test_resource_governor.py

# 确定性回放（素材必须在仓库外，且带数据集与版本记录）
swift run --package-path macos/SpeechRailApp teleprompter-replay \
  --manifest /path/outside/repo/replay.json --output /tmp/replay-report.json
```
