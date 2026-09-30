# SpeechRail AI 提词器：阶段实施报告

> 对应方案：`SpeechRail_AI_Teleprompter_Implementation_Plan_2026-09-28.md` v1.5<br>
> 报告日期：2026-09-28（Asia/Shanghai）；复审与收尾续至 2026-09-30<br>
> 实施分支：`codex/teleprompter-implementation`（worktree `.worktrees/teleprompter-implementation`）<br>
> 基线：`7468efb8c8282b119650fcb8e987a0d74f141e6a`；改动已提交到 `codex/teleprompter-implementation` 并经 PR #115 推送，**未发布**<br>
> 状态：**部分交付**。安全、正确性与体验工作包均有确定性证据（69 项场景：通过 65、部分 3、未执行 1）；真实音频、真人表达与 UI 视觉验收未执行。**功能侧原以为已无已知缺口**：#110 读法别名与 #111／#112 语音辅助试读已于第十至十二轮补齐。但 2026-09-29 继续审查时，在**已关闭 issue 的交付范围内又找出 50 个真缺陷**（§2 第 41–90 条、§4.3）（其中第 83 条是**共享测试闸门**的间歇失败，不属提词器交付范围，但它直接动摇本报告引用的「全量 pytest 全绿」这条证据，因此一并记在这里），均为「先改状态后可能失败而失败不回滚」与「多个原因压成一个返回值或文案」。已全部修复并配回归与变异验证。第二十轮做了完成度审计（逐条核实 §2.4 证据是否支撑其结论），**未发现新缺陷**，新增两处经核实的排除（§2.7）。第二十七／二十八轮把这一族先后扩到 Python 跟随路径（§2.12）与 Swift 视图层与 sheet（§2.13），**两侧结论都是「已逐条读过的范围内未发现新缺陷」，且都写明了覆盖边界**；视图层那侧的函数归属仍是启发式，**零命中不足以证明干净**。**同类形态是否还有第五处，本轮仍没有证据能保证没有**。

## 1. 本轮实际完成的工作包

| Issue | 工作包 | 结果 | 主要改动 |
|---|---|---|---|
| #108 | 探针计时、终态与有界性 | 完成 | `tools/probe_teleprompter_latency.py`、schema 4、14 项回归 |
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

59. **延迟探针的证据文件不带方案 §11.6 要求的语言与设备，而它的形状从来没有任何测试碰过（第三十二轮，真缺陷，根因是「证据文件本身不可测」）**：§11.6 结尾一句是「所有延迟报告 P50／P95、**样本数、语言、设备、模型**与运行条件」。逐条对到 `tools/probe_teleprompter_latency.py` 的输出上：模型有（顶层 `model`），样本数有（每个 `timing_summary` 带 `count`），**语言没有、设备没有**。而语言并不是「探不出来」——它就硬编码在会话配置里：`"transcription": {"model": model, "language": "zh"}`。数字一旦写进 JSON 离开文件，就没有语言标签，跨语言比较无从谈起；设备则连采集都没做。

    同一处还坐着第二个问题：`completed_ms = completed_at - stream_started`，**相对媒体起点**，而整段音频时长是它的结构性下界。41 秒素材配 40 秒的 commit 往返，这个字段是 41.4 秒——读起来仍像「延迟」，实际含义是「音频有多长 + commit 花了多久」。

    **根因不是漏写了两个字段，是 `run_probe` 末尾那个字典字面量没有任何测试碰过**。探针的 12 条旧用例覆盖了时钟、ACK、序号、终态、队列有界性、revision 单调性——**唯独没有一条断言证据文件的形状**。于是「§11.6 要求带的条件缺了两项」不会让任何用例变红。

    修法三步：把结果构造抽成纯函数 `build_evidence`（形状从此可测）；新增 `condition{language, device, model}`，设备标签只用 `platform.system()-platform.machine()`，**不含主机名、用户名或绝对路径**（项目隐私约定）；新增 `completed_after_audio_ms` 把 commit 往返单独拆出来。会话配置也抽成 `session_update_payload`，与 `probe_condition` 共用同一个 `LANGUAGE` 常量——**「探针跑的是 A 语言、报告的是 B 语言」这种分叉不许存在**。证据形状变了，`schema_version` 由 3 升到 4（#108 的验收标准原文就是「JSON 明确版本演进」）。

60. **素材构建器可以把 12 个字变成一个 7 段之外的阅读位置，匹配满分、复核清单里还看不见（本轮目前最重的一条，与第 56 条同族但性质更坏）**：方案 F-04 把「后文唯一短语出现在前文脱稿中 → 不跨远距自动推进」列为 P0，Swift 跟随控制器有 `localAdvanceTokenRadius`（默认 24）挡着这一族。**素材侧没有对应的一道**：`ALIGN_FORWARD_CHARS = 600`，而 `ALIGN_PREFILTER_CHARS` 只有 **2**——锚点只有两个字，一份 128 字的脚本等于全文都在前向窗口内。

    实测（8 段素材，真实工具链）：读者的确认位置还在第 0 段第 17 字符时，识别器只送来第 7 段的一个 12 字片段，`ScriptAligner` 给出 `segment_index = 7`、**`ratio = 1.0`**，并把 `cursor` 从 17 推到 120。走完整 `build_manifest` 后，这条标注是 `{'intent': 'read', 'expected_segment_index': 7}`，而 **`review entries: 0`**——因为 `reason` 只在四种情况里赋值，匹配度够高就不进清单。**质量满分恰好让它对复核的人隐形。**

    后果直接打在验收第 4 条上：`read` + `expected_segment_index` 是回放评估器计算 `tracking_latency` 的唯一依据，也是 §11.7「无歧义连续跟随 P95」这个质量门槛的输入。一个读者从未到达的位置，产出了一条看起来完全正常的跟随延迟样本。

    修法：①对齐器加距离闸门 `ALIGN_MAX_ADVANCE_CHARS = 24`，超出则**不给阅读位置且不移动 cursor**（游标也必须留在原地，否则下一个正常片段会被安到读者没去过的段上）；②`build_manifest` 把「远」与「模糊」分成两条不同的 reason——前者要人去稿件里找「这句话本来出现在哪一段」，后者要人考虑「这是不是一次脱稿」，混成一句「对齐不足」会把人引向错的检查；③复核清单加一列「匹配距离」。**此前清单只给「对齐度」，恰好是看起来最让人放心、也最不相关的那个数。**

    **闸门取值是量出来的，不是拍的**：真实 41 秒素材 82 个事件里 29 次推进，单次最大 **17 字**、中位数 5、p90 11，**没有任何一次超过 24**。修完后用同一份素材重跑 `build_manifest`：**82 条标注零改变，64 → 64 个阅读位置**；再用重建出的素材跑回放，报告**逐字段零差异**。这道闸门挡得住那条 31 字的跳跃，且**不碰真实素材一根手指**。

    误挡的代价是少一个延迟样本（交给人工确认），误放行的代价是把延迟基线建在没人到过的位置上——两者不对称，所以宁可挡。这与工具自己声明的原则一致：「机器可以少报一个阅读位置，绝不能多报一种行为」。

61. **F-19「不仅凭关键词给予大幅推进」在素材侧没有对应的一道闸门（第三十四轮）**：继续用第 60 条那条「把台账对到实现上」的路子，把 Swift 跟随策略的三道门逐个找素材侧的对应物：
62. **回放报告的延迟分位不带样本数，标注了位置却没量到延迟时报告完全沉默（第三十五轮）**：第 59 条查出探针的证据文件不带语言与设备，根因是「证据文件本身不可测」。这一轮把同一根因在回放报告上再查一遍——**分位和它的分母**。方案 §11.6 结尾原文：「所有延迟报告 P50／P95、**样本数**、语言、设备、模型与运行条件」。

    两处都不满足：

    | §11.6 要求 | 修复前回放报告 | 探针报告 |
    |---|---|---|
    | 样本数 | **完全没有**——`metrics` 里没有任何一个计数字段说明分位由几个样本算出 | `timing_summary` 每项带 `count` |
    | 语言／设备／模型 | 带（`condition`） | 修复后带（`condition`，第 59 条） |

    而顶层那个 `sample_count` 是**事件数**，不是延迟样本数。真实素材上这两个数是 **82 与 4**：并排放着，读的人只会把 `tracking_latency_p95_ms = 10993` 当成 82 个样本的结论。**探针侧一直带 `count`，回放侧是另一半**——和第 60、61 条同一个形态：门禁只长在系统的一半上。

    沉默是另一半，而且更危险。已有的「没有量到」caveat 判据是**素材有没有带位置的 read 标注**。于是「标注给了位置、跟随却一次没到」这一种完全落进缝里：标注齐全所以那条不触发，跟随在段内动过所以「一次都没有推进」也不触发。41 秒真实素材上恰恰是 7 个被标注的阅读位置里只有 4 个产出过样本，报告对此一个字都没有。

    **修法两条**：`Metrics` 与 JSON 增 `tracking_latency_sample_count` / `reanchor_latency_sample_count`；caveat 判据从「有没有标注」改成「**标注的位置里有几个真的产出了样本**」，并在为零时单独措辞。

    措辞上花了一轮才改对。最初写的是「从未被跟随到达」——**这是错的**：跟随控制器构造时就在第 0 段，所以任何标注为第 0 段的位置根本开不出「到达」那一刻，它不是没到，是一开始就在。这类位置和真没到达的位置一样都不产出样本、也都不被判为失败。现在写的是「没有产出延迟样本（跟随一开始就在该段上，或一直没到达）」，不替素材猜是哪一种。

    真实素材复核：**其余 `metrics` 逐字段零差异**（没有任何既有数字被改动），新增两个计数字段（4 与 0），新增一条带真实数字的 caveat，其余 caveat 一条不动。

    | Swift 运行时 | 素材侧 | 状态 |
    |---|---|---|
    | `provisionalMinimumConfidence = 0.72` | `ALIGN_MIN_RATIO = 0.72` | 有 |
    | `localAdvanceTokenRadius = 24` | `ALIGN_MAX_ADVANCE_CHARS = 24`（第 60 条补） | 有 |
    | `provisionalMinimumMatches = 2` | —— | **没有** |

    缺口是真的：比例是 `matched / len(needle)`，所以**两字碎片只要出现在稿件里就是 `ratio = 1.0`**。三段 fixture 上直接复现——读者在第 0 段时，识别器送来「先看」两个字，工具把阅读位置推到**第 1 段**。

    **但先量了真实素材，结论是「影响为零」**：41 秒素材 82 个事件里 21 个匹配只有 1–3 字（好几个 `ratio = 1.0`），它们合计推进游标 **0** 个字符；29 次真正的推进里匹配长度取值为 `[5, 9, 15, 16, 18, 19, 20, 21, 22, 23]`，**最小 5 字**。全文 160 字的推进全部来自 4 字以上的匹配。

    所以这条要分开说：**逻辑缺口成立**（有可达路径，有单测复现），**但它没有污染手上这份素材**。按 §2.13 的规矩，这属于「假设—测量—修正」走完一圈后**严重性下调**的一条，不是第 60 条那种已经在真实数据上造成后果的缺陷。修它的理由是**闸门便宜且可证惰性**，不是补救已发生的损失。

    修法：`ALIGN_MIN_ADVANCE_MATCH_CHARS = 4`（按**字符**计；Swift 侧那道按 token，中文 4 字约 2–4 token，取严的一侧）。命中时**位置仍给「读者确实到达的地方」**，只是这几个字不带它往前——事件本身仍是有效朗读证据。复核清单新增「匹配字数」一列，`reason` 也分开：「匹配仅 N 字」要人去找更多音频证据，「对齐不足」要人考虑这是不是脱稿，**混成一句会把人引向错的检查**。

    修完在真实素材上：标注 **0 条改变、64 → 64 个阅读位置**，回放报告**逐字段零差异**；但复核清单从 **31 条涨到 44 条**——13 个此前隐形的事件现在带着「匹配仅 2／3 字」进入人工视野。**位置没动，可见度变了**，这正是第 60 条那条经验的第二次兑现。
63. **没有阅读位置的事件被当成「跟随已恢复」，未匹配数量从不单列（第三十六轮）**：第 62 条补的是分位的样本数，方案 §11.6 同一句里还有一半：「**超时和未匹配数量单列**」。回放报告里两样都没有。

    超时那一半在评估器里是有的（`reanchor_timeout_count`），但**「未匹配」被当成了恢复**。`.read` 分支的 `else`（标注是正常朗读、却没有 `expected_segment_index`）直接调 `endReanchorWindow()`——而那个闭包做的正是结算一次超时并清掉窗口与停顿门槛。

    「没有阅读位置」这件事对「跟随有没有跟上」**不提供任何证据**：它既没说跟上，也没说没跟上。把它读成「跟上了」是把「不知道」记成「好」。

    可复现：读者在 0.5 秒脱稿，之后两个**完全对不上稿**的事件一路走到 6 秒（远超 3 秒超时门槛），报告给出 **0 次超时、0 个失败样本**。一次也没恢复的跟随，被两个「读不懂」的事件抹平了。

    真实素材上这条路径占比不小——按释放点插桩统计，一次回放的窗口释放共 **22 次，其中只有 4 次是跟随真的到达（`read-crossed`），18 次是「对不上稿」（`read-no-position`）**。82 个事件里 18 个（22%）没有阅读位置。

    修法两条：`.read` 的无位置分支不再关闭窗口，只累加 `unmatchedEventCount`；新增 `unmatched_event_count` 与一条说清「既不产生延迟样本、也不计为失败」的 caveat——这类事件**从两个方向同时退出统计**，所以最容易在报告里消失。

    **停顿数从 12 变成 11，这一轮查得最久**：12 → 11 正是第 30 条踩过的同一个数字，所以不能当成回归了事。插桩把 11 次与 12 次停顿的时刻与 gate 全打出来，结论是少掉的那次在 **t=27009ms**，它之所以能计上，只是因为**同一时刻一个对不上稿的事件把停顿门槛提前释放了**——而这条门槛存在的意义正是「一个阈值窗口只记一次停顿」。真实素材上有 6 次停顿落在 t=17020–19033ms 这 2 秒内、gate 全是同一个 15011，同样是这么来的。所以 11 是这条规则**本来就该给出的数**，12 是被「读不懂」事件撑起来的。


64. **稳定前缀越界被当成「没有稳定前缀」，于是拿仍在修订的全文去对齐（F-15，第三十七轮）**：目标里点名的第三项「稳定证据丢失」。这一轮从两侧同一道判据查起。

    | | 稳定前缀越界时怎么办 |
    |---|---|
    | 运行时 `TeleprompterFollowController` | 折成 `nil`，走 else 分支拿**整段仍在修订的文本**对齐 |
    | 素材侧 `build_manifest` | 字段被原样带进 JSON，但对齐时**一个字都不读** |

    运行时那一支方向是反的。方案 §3.6 与 F-15 写得很直接：「稳定前缀范围必须在当前原始文本内；若声称稳定的旧前缀发生变化，记录契约不一致并**暂停自动推进**，不静默夹取成『合法』」（第 694 行），台账 F-15 同样写着「契约异常可见，**暂停推进而非伪造稳定性**」。把越界折成 `nil` 之后落到 else 分支，等于**契约一出问题就改用最宽松的那条路**——比「不推进」更宽松，而异常从外面完全看不出来。

    素材侧那一支则是整道判据都没有：41 个 snapshot 里 **40 个带着 `stable_prefix_codepoints`**，全部被忽略，替代它的是「取尾部 24 字」这个本地启发式。

    **修法**：两侧都只保留「越界即拒绝」。运行时不推进、把不确定性顶满、离开「跟读咬合」，并新增 `stablePrefixContractAnomalies` 让异常**可见**；素材侧不给阅读位置，复核清单给一条独立 reason——**不能写成「对齐不足」**，那是另一种检查（要人考虑这是不是脱稿），这一条要人去看引擎与客户端之间的契约。

    **素材侧只做越界守卫、不按前缀截断，是量完才定下来的**，详见 §2.22。

65. **保真门禁的单位是枚举式的，没列到的单位两侧都不产生原子，于是「换了量级」被读成「什么都没改」（F-01，第三十八轮）**：这道门禁比的是**受保护原子的序列**——两边都看不见的东西不产生原子，序列就相等，相等即「未改动」。第 61 条之前，同一行正则已经因为 `1080p`／`1e10` 补过一次；**单位组是枚举式的，同样的漏法原封不动地留在单位上**：

    | 稿件 | 模型改写后 | 改写前原子 | 改写后原子 | 门禁 |
    |---|---|---|---|---|
    | 额定功率 50 瓦 | 50 千瓦 | `["50"]` | `["50"]` | **放行** |
    | 发射距离 3 米 | 3 厘米 | `["3"]` | `["3"]` | **放行** |
    | 容器容量 2 升 | 2 毫升 | `["2"]` | `["2"]` | **放行** |
    | 载重 5 吨 | 5 千克 | `["5"]` | `["5千克"]` | 拒绝——但**是因为另一侧在枚举里**，不是因为单位被检查了 |

    方案第 397 行把它写成规格：「`50 元`、`50 万元`、`50%`、`50 个百分点` 是不同量；**单位和量级不得脱离数值**」；第 157 行把「完整数值／标识符识别、出现级映射与**语义单位检查**」列为 F-01 的 P0 验收项。这道门禁对 `.speak` 块是**硬拒**（`reject(.protectedLiteral)`），所以漏报不是「宽松一点」，是**换了量级也读不出来，且报告里没有任何一处说它没看**。

    同一行还有反向的一处：`\s*` 把数字与单位之间的空白**吃进原子**，而 `canonicalize` 只裁两端，于是 `50 元` → `50元` 这种纯排版改动被判成「受保护字面量被改」，把无损改写送人工。§11.6 的指标表里就有这一项——「风险误报率：正常无损改写被要求人工处理的比例」。

    **修法两处**：单位组按语料实测扩到 18 类（`米`／`吨`／`瓦`／`厘米`／`毫升`／`条`／`行`／`项`／`字`／`段`／`根`／`张`／`份`／`字符`／`字节` 等），匹配锚在「第一个不是单位的字符」上，因此 `50 瓦的功率` 里的助词 `的` 留在原子外；`canonicalize` 丢弃内部空白（能跨空白匹配的只有数字那一组正则，所以这是精确的，不是全局归一）。

    **扩展清单本身被实测砍掉一半**，过程与量值见 §2.23。

66. **读法别名的数值门禁在量级上是空的：`3万`→`3`、`三万`→`三千` 都能通过（第三十九轮）**：第 65 条查的是**保真门禁**（AI 改写会不会改掉数字），这一条查的是另一道门禁——`TeleprompterAcceptedReading.numericFingerprint`，它决定读者确认的**读法别名**能不能加进来。界面上的承诺是「两边的数字或单位不一致。读法只能改发音，不能改数值」，而这道门禁的实现是「两侧的数字指纹相同即放行」：

    | 显示文本 | 确认读法 | 修复前指纹 | 门禁 | 实际 |
    |---|---|---|---|---|
    | `3万` | `3` | `["3"]` / `["3"]` | **放行** | 30000 变成 3 |
    | `5千` | `5` | `["5"]` / `["5"]` | **放行** | 5000 变成 5 |
    | `2亿` | `2` | `["2"]` / `["2"]` | **放行** | 2 亿变成 2 |
    | `三万` | `三千` | `[]` / `[]` | **放行** | 两侧都没有数字，空指纹相等 |
    | `2万元` | `两万元` | `["2","0元"]` / `["20000元"]` | 拒绝 | **同一个数**，被误拒 |
    | `50` | `五十` | `["50"]` / `[]` | 拒绝 | **同一个数**，被误拒 |
    | `3万` | `三万` | `["3"]` / `[]` | 拒绝 | **同一个数**，被误拒 |

    门禁的强度**恰好等于** canonicalizer 认数字的能力：认不出的量级就是门禁看不见的量级，而两侧都看不见时，两个空指纹是相等的。根因两条，都不在门禁本身：

    1. `.spokenUnit` 要求中文数字后面**必须有单位后缀**才识别，于是裸量级数字（`三万`／`五千`／`五十`）根本不产生数值单元，逐字切成 `["三","万"]`；
    2. arabic 规则从不在阿拉伯数字后认中文量级词，于是 `2万元` 被切成 `2` + `万元`，而 `chineseInteger("万")` 返回 **0**——`2万元` 的规范形式是 `["2","0元"]`，**这是在说稿子里写的是 0 元**。

    修法是两侧都补：新增 `.spokenMagnitude` 规则（不含单位后缀、但含量级字的中文数字串），arabic 规则加 `(?:[万亿千百])?` 并在 `arabicValue` 里折算，同时把「量级前无数字」时的补 1 规则从只对 `十` 扩到全部量级——`百` 本来就是 100 而不是 0，这正是 `万元` 读成 `0元` 的原因。详见 §2.24。

    **这条与第 65 条是同一类形态的两面**：第 65 条是「枚举漏了一项，于是静默通过」，这一条是「枚举之外的整类中文数字根本没进规则，于是静默通过」。两处的可观测性都一样——结果里没有任何一处说它没看见。

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

「远处短语不得擅自跨句跳转」此前只钉住了**向后**那一向——`rereadRollsBackOnlyWhenTheBackwardMatchIsStrong` 与 `rereadDoesNotRollBackAcrossDistantParagraphs` 测的都是回退。**向前没有用例**，而 `mayAdvance` 的四道门禁里有两道从未被任何测试碰过：`localAdvanceTokenRadius` 与 `provisionalMinimumMatches` 在整个测试目录里都是零命中。计划 §11.7 把「旧 generation／手动接管：零越权推进」列为门槛，台账 F-04 也只挂了一条距离约 100 个 token 的用例。

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

### 2.17 第三十二轮：探针的证据文件本身不可测（第 59 条）

前两轮都在评估器（Swift）上。第 52–58 条这七条缺陷里，**有五条的根因是同一个**：不是逻辑写错了，是**「报告／证据文件长什么样」这件事从来没有被断言过**。评估器那边本轮之前有 caveat 反向对照（第 53、55 条）兜着，探针这边一条都没有——所以这一轮换个对象，把同一判据用上去。

**怎么查出来的**：把 §11.6 结尾那句「所有延迟报告 P50／P95、样本数、语言、设备、模型与运行条件」逐项对到 `tools/probe_teleprompter_latency.py` 的输出字典上。模型有，样本数有（`timing_summary` 每个都带 `count`），**语言没有、设备没有**。而语言不是探不出来——它硬编码在第 303 行的会话配置里。

顺着「单位／参照系」这条判据又看到第二个：`completed_ms = completed_at - stream_started` 相对**媒体起点**，整段音频时长是它的结构性下界。41 秒素材 + 40 秒 commit 往返 = 41.4 秒，这个字段读起来像「延迟」，实际是「音频有多长 + commit 花了多久」。

**修法**：`run_probe` 末尾的字典字面量抽成纯函数 `build_evidence`（形状从此可测），新增 `condition{language, device, model}` 与 `completed_after_audio_ms`，会话配置抽成 `session_update_payload` 并与 `probe_condition` 共用 `LANGUAGE`。设备标签只用 `platform.system()-platform.machine()`——**项目隐私约定禁止证据文件带主机名、用户名或绝对路径**，所以这条不是可选项。`schema_version` 3 → 4。

**这一轮顺手量了一件此前没人量的事，如实记下来**：`first_partial_ms` 同样相对媒体起点，所以**素材开头的静音会被算进「首个 partial 延迟」**。听起来像个真缺陷，于是量了那份 41 秒素材：前置静音只有 **80 ms**（20 ms 窗、峰值阈值 200，总长 41040 ms，有声段 31380 ms）。**80 ms 对一个秒级数字可以忽略，这条不构成对已记录数字的推翻**。探针的接收线程在事件到达时打时间戳、主线程在上传结束后才消费队列，所以「首个 partial 到达时已上传了多少音频」无法从现有结构里取出来——要拆开得重建上传进度快照。本轮**不做**：它对现有素材影响可忽略，而重建会引入一个比原问题更容易出错的推导。**如实记下边界，不假装已修**。

变异 **8 条全部被杀**：删掉整个 `condition`、`probe_condition` 报另一种语言、设备标签置空、会话语言与证据语言分叉、commit 往返不做相减、commit 往返恒为 `null`、形状变了不升版本、顶层 `model` 与 `condition.model` 重复。

探针回归 **15 项通过**（新增 3 条）。`ruff check .`、`mypy src` 154 文件全绿。

### 2.18 第三十三轮：素材构建器的远距闸门（第 60 条）

第 59 条在探针上找到「证据文件从不被断言」，这一轮把同一判据再往前推一格：**生成证据的工具本身**。

**怎么找到的**：不是扫代码，是**先把方案 §11 的台账逐条对到实现上**。F-04 那一行写着「后文唯一短语出现在前文脱稿中 → 不跨远距自动推进」，第 2.14 节记着 Swift 侧靠 `localAdvanceTokenRadius`（默认 24）挡住了这一族。于是去问素材侧：等价的一道在哪？答案是**没有**——`ALIGN_FORWARD_CHARS = 600`，而 `ALIGN_PREFILTER_CHARS = 2`。

**量出来的三层**：

| 观察 | 结果 |
|---|---|
| 读者在第 0 段第 17 字符时，识别器送来第 7 段的 12 字片段 | `segment_index = 7`、`ratio = 1.0`、`cursor` 17 → 120 |
| 走完整 `build_manifest` | 标注是 `{'intent': 'read', 'expected_segment_index': 7}` |
| 同一份素材的人工确认清单 | `review entries: 0`——**它根本不进清单** |

第三行是这条缺陷比第 56 条更坏的地方：**匹配质量满分，恰好让 `reason` 不被赋值，于是对复核的人隐形**。而 `read` + `expected_segment_index` 是回放评估器算 `tracking_latency` 的唯一依据，也是 §11.7「无歧义连续跟随 P95」的输入。

**闸门取值先量后定**。真实 41 秒素材 82 个事件、29 次推进，单次最大 **17 字**、中位数 5、p90 11，**零次超过 24**。取 24（与 Swift 侧默认值一致）之后：重建 `build_manifest` → **82 条标注零改变，64 → 64 个阅读位置**；用重建素材跑回放 → **报告逐字段零差异**。**挡得住，且不碰真实素材一根手指**——这是本轮最想留给接手方的一句：闸门半径不能拍脑袋，要拿真材料量分布。

变异 **5 条全部被杀**：删掉闸门、把半径放大到 100000、**拒绝位置但仍移动 cursor**、复核清单去掉距离列、把远距匹配并回「对齐不足」。其中**「拒绝位置但仍移动 cursor」首轮存活**，因为最初那条断言盯的是 `intent`——两种情况下它都是 `read`，变的是 `expected_segment_index`。**变异存活的价值就在这里：它逼我把断言对准了真正会变的那一格。**

素材回归 **33 项通过**（新增 3 条，此前 30）。`ruff check .`、`mypy src` 154 文件全绿。

**这一轮没有验证到什么**：三段 fixture 与那份 41 秒素材都**没有出现真实的远距误匹配事件**（最近的那次是 17 字）。所以能确定的是「**闸门拦得住远超半径的自信匹配，且不改变现有素材**」；**不能**声称真实朗读中远距误匹配的频率已经量化——那需要真人素材（#83）。

### 2.19 第三十四轮：把「另一半有没有对应的一道」做成一张表（第 61 条）
### 2.20 第三十五轮：分位必须带着它的分母走（第 62 条）
### 2.21 第三十六轮：「没有证据」不等于「证据表明没问题」（第 63 条）
### 2.22 第三十七轮：量了三遍才敢说不改（稳定证据，第 64 条）

目标里点名的第三项是「稳定证据丢失」。两侧对同一道判据的处理对不上：

| | 稳定前缀越界时怎么办 |
|---|---|
| 运行时 `TeleprompterFollowController` | 折成 `nil`，走 else 分支拿**整段仍在修订的文本**对齐 |
| 素材侧 `build_manifest` | 字段带进 JSON，但对齐时**一个字都不读** |

运行时那一支方向是反的。§3.6 与 F-15 要求「记录契约不一致并**暂停自动推进**，不静默夹取成『合法』」（第 694 行）、「契约异常可见，**暂停推进而非伪造稳定性**」（第 1008 行）。折成 `nil` 之后落到 else 分支，等于**契约一出问题就改用最宽松的那条路**。

素材侧那一支则是 41 个 snapshot 里 **40 个带着 `stable_prefix_codepoints`**，全部被忽略，替代它的是「取尾部 24 字」这个本地启发式。

#### 量到的东西比预想的多

先量了「素材侧按稳定前缀截断」会怎样——这是补齐这道判据最直接的写法：

| | 数值 |
|---|---|
| 82 条标注里会改变 | **26 条** |
| 带阅读位置的标注 | 64 → 56 |
| 旧标注 `cur[N]` 与新标注 `new[N]` 一致 | 72.0% |
| 旧标注 `cur[N]` 与 **`new[N+1]`** 一致 | **95.9%** |

最后两行是这一轮最有价值的测量：现有标注**系统性领先一个修订**——它在事件 N 就用上了引擎要到 N+1 才确认的文本。这是流式 ASR 的固有性质，不是 bug。

#### 然后把它否掉了

改完跑真实素材，数字炸了：

| | 修复前 | 按前缀截断后 |
|---|---|---|
| `failure_share` | **0** | **48.8%** |
| `reanchor_timeout_count` | 0 | **2** |
| `failed_sample_count` | 0 | 40 |
| 新出现的 intent | — | 3 条 `reRead`（素材侧此前 82 条全是 `read`） |

48.8% 是本分支从未出现过的数字，足够让人先怀疑自己。查下来是**语义错了**，不是实现错了：

- §11.6 指标表写明：「正常跟随延迟 = **人工标注的可识别片段结束** → 正确确认位置反映到 UI 的时间」。**锚点是人说过的话。**
- §6.6 第 799 行的「优先使用后端经过验证的稳定前缀」治的是**跟随器的推进决策**——运行时已经这么做了。

把这条规则套到**标注**上，等于把「读者读到哪」换成「引擎确认到哪」。于是跟随器（本来就按稳定前缀走）相对新标注显得一路落后，回稿窗口连续超时。**报告变得难看，是因为问的问题变了，不是因为跟随变差了。**

所以素材侧只保留越界守卫。收窄之后在真实素材上**完全惰性**：0 条标注改变、报告逐字段零差异——这正是契约守卫该有的样子，它防的是这份素材里没有的违约。

#### 顺带收回一个自己夸大的说法

中途我写过「稳定前缀按截断后的长度校验，会让自己 2048 字的截断伪装成没有稳定前缀」。查下去**这不改变任何匹配结果**：前缀不小于存文本长度时，取前缀与取整段存文本是同一段字符串；小于时两种写法取的也是同一个数。差的是**越界判定**，而越界判定决定要不要推进。代码注释已按实测改写。

长假设那条回归测的就是这一点：2100 个 scalar、整段已稳定的合法假设，**不能**因为「比存下来的 2048 长」被判成越界而停下。写第一版时用异质填充字做夹具，结果对齐器（最多只看尾部 72 个 token）合理地对不上——那测的是对齐器不是这道守卫；改成重复稿件内容，两个前提才同时成立。

#### 变异 11 条，全部被杀

- **2 条探针作废**（按第 27、33 条不计入）：一条是 harness 用了相对 python 路径而 worktree 的 `.venv` 是符号链接，pytest 根本没报结果，我却把「没有 FAILED 行」读成了存活；另一条是变异本身写成了 Python 语法错误。**手动单验 M1 确认它其实是被杀的**——不验这一下，这个假存活会被当成真缺口写进报告。
- 运行时侧 6 条、素材侧 5 条，改完测试后**一次跑 11 条全杀**。

回放素材回归 **36 项**（新增 2 条），`swift test` **293 项 / 16 套件**（新增 2 条），Xcode 两条门禁均 `SUCCEEDED`。

第 62 条补的是 §11.6 那句里的「样本数」。这一轮把同一句的另一半补上——「**超时和未匹配数量单列**」。

「超时」在报告里是有的。缺的是「未匹配」，而且缺的方式比「少一个字段」严重：**未被匹配的事件被当成了恢复**。

```swift
// 修复前：标注说这是正常朗读，却没有阅读位置
} else {
    endReanchorWindow()   // ← 结算一次超时、清窗口、清停顿门槛
}
```

`endReanchorWindow()` 是「跟随追上了」时才该走的路径。而「对不上稿」对「跟随有没有跟上」**不提供任何证据**——它既没说跟上，也没说没跟上。这里把「不知道」读成了「好」。

三段夹具直接复现：读者在 0.5 秒脱稿，之后两个完全对不上稿的事件走到 6 秒（门槛是 3 秒），报告说 **0 次超时、0 个失败样本**。

**真实素材上这条路径的占比要量出来，不能靠推理。**按释放点插桩，把 `endReanchorWindow()` 的四个调用点分别打标签，一次回放的窗口释放长这样：

| 释放原因 | 次数 | 是不是恢复证据 |
|---|---|---|
| `read-crossed`（跟随真的越过了标注位置） | **4** | 是 |
| `read-no-position`（对不上稿） | **18** | **否** |

82 个事件里 18 个（22%）没有阅读位置。修复前，这 18 个各自把一次「未恢复」擦成「已恢复」。

**这一轮最该记的是 12 → 11 这个数字。**改完之后真实素材的 `stalled_event_count` 从 12 变成 11——而 12 → 11 正是第 30 条踩过的同一个数字，那次是丢了恢复时的门槛重置，属于回归。所以这里没有直接接受，而是把两次运行的**每一次停顿的时刻与当时的 gate** 都打出来对比：

```
修复前：… stall#10 t=26015 … stall#11 t=27009 … stall#12 t=35062
修复后：… stall#10 t=26015 …            stall#11 t=35062
```

少掉的停顿在 **t=27009ms**。它之所以能计上，只是因为**同一时刻一个对不上稿的事件把停顿门槛提前释放了**。而这条门槛存在的意义正是「一个阈值窗口只记一次停顿」——它是被设计来防这件事的。

同一份日志里还看得更清楚：t=17020–19033ms 这 2 秒内落了 **6 次停顿，gate 全是同一个 15011**。同一门槛、同量级时刻反复计数，正是这条规则要排除的形态。**所以 11 是这条规则本来就该给出的数，12 是被「读不懂」事件撑起来的。**

修法：`.read` 的无位置分支不再关闭窗口，只累加 `unmatchedEventCount`；新增 `unmatched_event_count` 字段与一条 caveat，caveat 必须说清这类事件**从两个方向同时退出统计**——既不产生延迟样本，也不计为失败。

**真实素材复核**：除 `stalled_event_count` 12 → 11 与新增的 `unmatched_event_count: 18` 外，**其余 metrics 逐字段零差异**；caveat 只增一条、其余一条不动。

**变异 7 条：6 条首轮被杀，1 条存活后补断言再杀**：

- **存活（真覆盖缺口，且是最该抓住的一条）**：把 caveat 的**含义**反过来——写成「这些事件已按失败样本计入」——**没有任何用例变红**。原断言只检查「caveat 存在且带数字」，而这条 caveat 的**全部价值就是那句话**：反过来写，报告会主动误导读报告的人。补法是逐半句钉住「既不产生延迟样本」与「也不计为失败」。

回放回归 **32 项通过**（新增 3 条）。`swift test` **291 项 / 16 套件**通过，Xcode 两条门禁均 `SUCCEEDED`。

第 59 条的根因是「证据文件本身从不被断言」。这一轮把同一个根因换个位置再查一遍：不是证据文件的**形状**，而是**分位与它的样本数**。

先把方案那句要求抄下来对照（§11.6 结尾）：

| §11.6 要求 | 修复前回放报告 | 探针报告 |
|---|---|---|
| 样本数 | **没有** | `timing_summary.count` |
| 语言／设备／模型 | `condition` | 第 59 条补齐 |

**回放报告是缺样本数的那一半。**顶层 `sample_count` 是事件数，两个数在真实素材上差 20 倍：

| | 事件数 | 跟随延迟样本数 |
|---|---|---|
| 41 秒真实素材 | 82 | **4** |

也就是说 `tracking_latency_p95_ms = 10993` 是 **4 个样本**的分位数，而它在 JSON 里的邻居写着 `sample_count: 82`。§11.6 要求随附的样本数不仅没给，还给了一个名字对不上的替身。

**沉默是同一处的第二个面**。已有判据「没有带 `expected_segment_index` 的 read 标注」问的是**素材问没问**。真正没被覆盖的是「素材问了、跟随没答上」：标注里带着位置，所以那条不触发；跟随在段内动过，所以「一次都没有推进」也不触发。真实素材上 7 个标注位置只有 4 个产出样本，报告对此完全沉默。

判据改成「**标注的位置里有几个真的产出了样本**」，并分零与非零两种措辞。写完实测发现第一版措辞是**错的**：

> ~~另有 N 个位置整段回放里从未被跟随到达~~

跟随控制器构造时 `currentIndex: 0`——它**一开始就在第 0 段**。所以标注为第 0 段的位置开不出「到达」那一刻：不是没到，是从头到尾都在。这类位置与真没到达的位置一样，都不产出样本、都不被判为失败。改成「没有产出延迟样本（跟随一开始就在该段上，或一直没到达）」，并**明说不替素材猜是哪一种**。

这个发现顺带解释了为什么「完整覆盖」在默认素材上不可能：任何从第 0 段开始的标注都至少差一个。反向对照的夹具因此刻意从第 1 段标起。

**真实素材复核（修复前 / 修复后各跑一次 `teleprompter-replay` 逐字段 diff）**：既有 `metrics` **逐字段零差异**，无一条既有 caveat 增删；新增两个计数字段与一条 caveat：

> 跟随延迟分位只来自 4 个样本，而素材标注了 7 个阅读位置：另有 3 个标注位置整段回放里没有产出延迟样本（跟随一开始就在该段上，或一直没到达），它们既没有贡献样本、也没有被判为失败。

**变异 9 条：7 条有效首轮被杀，2 条存活后补测试再杀**：

- **存活 A（真覆盖缺口）**：把 `reanchorLatencySampleCount` 的赋值整行删掉无人变红——新用例里回稿样本数恰好是 0，删掉赋值也是 0。补法：在已有的 `reanchorLatencyIsMeasuredFromTheDetour`（本身就量到 1_100ms）上加一条 `== 1`，直接钉住那次赋值。
- **存活 B（真覆盖缺口）**：把 `<` 改成 `<=`，即「样本数刚好等于标注位置数」时也报缺口，**无人变红**——现有夹具没有一个能做到完整覆盖（原因就是上面那条：第 0 段开不出到达）。补法：加 `aFullyCoveredMaterialReportsNoLatencyCoverageGap`，标注刻意从第 1 段起，让样本数与标注位置数相等，并**反向断言 caveat 不出现**。这一条同时钉住「该报警时才报警」。

回放回归 **29 项通过**（新增 3 条）。`swift test` **288 项 / 16 套件**通过，`scripts/macos_app_build.sh` 两条均 `SUCCEEDED`。

第 60 条是**问出来**的：F-04 那一行写着「不跨远距自动推进」，Swift 侧有 `localAdvanceTokenRadius`，于是问素材侧等价的一道在哪，答案是没有。这一轮把那个动作**做成一张表**——把 Swift 跟随策略的每道门列出来，逐个找素材侧的对应物。

| Swift 运行时 | 素材侧 | 状态 |
|---|---|---|
| `provisionalMinimumConfidence = 0.72` | `ALIGN_MIN_RATIO = 0.72` | 有 |
| `localAdvanceTokenRadius = 24` | `ALIGN_MAX_ADVANCE_CHARS = 24`（第 60 条补） | 有 |
| `provisionalMinimumMatches = 2` | —— | **没有** |

**这张表本身就是可交接的产物**：它把「一个门禁只存在于一半系统」这种最难靠读代码发现的缺口，变成一次可以逐行做完的核对。下次再动任一侧，先重画这张表。

**这一轮最重要的动作是量完之后不夸大**。假设「两字碎片拿满分 → 推进位置」是真缺陷，实测真实素材：

| | 事件数 | 游标推进 |
|---|---|---|
| 匹配 1–3 字 | 21 | **0** |
| 匹配 4 字以上 | 61 | 160（全文 160/160） |

29 次真正的推进里，匹配长度全部落在 `[5, 9, 15, 16, 18, 19, 20, 21, 22, 23]`，**最小 5 字**。也就是说**手上这份素材没有被它污染**。但三段 fixture 上直接复现了可达路径（「先看」两个字把位置从第 0 段推到第 1 段）。两条都成立，所以台账里分开写：**逻辑缺口成立，但在唯一一份真实素材上影响为零**。修它的理由是**闸门便宜且可证惰性**，不是补救已发生的损失。

修完在真实素材上：标注 0 条改变、64 → 64 个位置、回放报告逐字段零差异；**复核清单 31 → 44 条**，13 个此前隐形的事件进入人工视野。位置没动、可见度变了。

**变异 4 条有效全部被杀，1 条无效，1 条存活**：

- **M26 首轮无效**：游标推进的两行被插在 `return` **之后**，不可达——**探针缺陷不是存活**，按第 27、33 条不计入。改插到同一个块内、`return` 之前后杀掉。
- **M28 存活，是真实的覆盖缺口**：给「匹配仅 N 字」分支加上 `segment_index is not None` conjunct（把顺序改成「远」优先于「证据不足」）**没有任何用例变红**。这是**复合情形**——匹配既小又远。现有顺序选「证据不足」优先（更根本），但没有测试钉住这个选择。**如实记为已知边界，不为它编造用例**：构造这样的夹具要先有一段「既 <4 字又 >24 字远」的素材，价值低于它带来的理解负担。

素材回归 **34 项通过**（新增 1 条）。`ruff check .`、`mypy src` 154 文件全绿。

### 2.23 第三十八轮：单位清单扩到一半，又被实测砍掉一半（保真门禁，第 65 条）

第 65 条的修法看起来只是往枚举里加单位。**先量后定**这一步量出来的是另一件事：**中文里能跟在数字后面的字，有一批会组词**。

在 **959 个文件**（md／swift／py／json／yaml／txt，剔除 `.build`／`.git`／`.venv`）上把新旧两条正则并排跑，逐个匹配取**真实的匹配后继字符**（不是按字符串反查，那会取到文件里第一个同名出现的位置）：

| | 数值 |
|---|---|
| 受影响的原子 | **2114** |
| 新绑定的单位后缀 | **26 类** |
| 其中被实测判为误绑 | **7 类** |
| 收窄后保留 | **18 类** |

7 类误绑与它们的真实后继：

| 误绑单位 | 真实后继 | 稿件里的样子 |
|---|---|---|
| 安 | 安装 2、培 2、全 1 | `v1.9.0 安装`、`### 4.2 安全` |
| 克 | 克 2 | `#### 5.7.1 克隆` |
| 处 | 理 6、断 4、是 4、裸 3 | `按 0 处理` |
| 只 | 有 6、读 5、复 2 | `padY 12 只有`、ETag 只读 |
| 升 | 级 3、到 1 | `2.3.2 升级` |
| 页 | 面 10、签 6、头 2 | `§4.2 页面` |
| 支 | — | `v1.3.1 支持` |

也就是说 `v1.9.0 安装` 里的 `0` 会被当成 `0安`，`按 0 处理` 里的 `0` 会被当成 `0处`。**这不是精度损失，是把无损改写误判成受保护字面量被改**，正是 §11.6 那条误报率指标要量的东西。

处置沿用项目对中文数字已经定过的取舍（见 `chineseNumeralsRemainOutsideTheHardGateByDesign` 的注释：**留缺口并记录，不大范围误拦无损改写**）：这 7 个单字全部撤出清单。`牛`／`伏` 属同一类——语料里没有反例**不等于**没有风险，语料无法证明的东西不写进清单，同样撤掉。

收窄后 **18 类**，逐条读过上下文全部是真量词：`82 条标注`、`第 0 段`、`12 / 16 / 18 根`、`40 字符`、`2 字节`、`10 张原图`，以及 `50 瓦的`——助词 `的` 落在原子外。另一头同时量到：2114 个变化原子**全部**满足「新原子严格等于旧原子加一个单位后缀」（`notPrefix = 0`），即这次扩列表**没有改变任何一个数字本身的切分**。

**这一轮在真实素材上完全惰性，必须说清**：`script_b.txt` 里**一个阿拉伯数字都没有**（「七点」「四十分钟」「一个小时」全是中文数字，按既定边界本就在硬门禁外），`manifest_b4.json` 里的数字全是 ID、时间戳与毫秒。所以本条的证据是**语料探针，不是真实素材**——这与第 64 条那种「量到影响为零」不同，那里是素材测得到、结果是零，这里是**素材测不到**。

**变异 4 条全部被杀**：

| 变异 | 触发的断言数 |
|---|---|
| M29 删掉 `canonicalize` 的空白处理 | 3 |
| M30 单位组还原成第 61 条时的枚举 | 3 |
| M31 单位组改成贪婪的 `[\u4e00-\u9fff]{1,3}` | 2 |
| M32 只从清单里去掉「瓦」 | 1 |

M31 就是这一轮**先否掉的那个方向**：改正则确实能一次抓住瓦／米／厘米／升／毫升／吨，但它同时把 `50 瓦的功率` 切成 `50 瓦的功`，于是正常中文里数不尽的助词、地名与连词都会被算进受保护原子。**多抓几个漏报、同时多拦一批无损改写——量过之后选了后者**，与 `extractorStillLeavesDigitsInsideIdentifiersAlone` 是同一条纪律。

素材回归 `swift test` **296 项 / 16 套件通过**（新增 3 条）。

### 2.24 第三十九轮：量级在两道门禁上都是隐形的（读法别名，第 66 条）

第 66 条的修法有三条互相独立的改动，所以**每条都单独量过、单独变异过**。

#### 先量真实素材：完全惰性

`script_b.txt` 的 8 个数值单元（`一天`／`七点`×4／`四十分`／`一个`）**全部走 `spokenUnit`**，没有一个含量级词，因此本轮修复在唯一一份真实素材上逐条零影响。这与第 65 条同样是「素材测不到」，证据只能来自构造用例与 959 个文件的语料探针。

#### 语料探针量到的 114 类读数，逐类核过

在 959 个文件上取出「源串含中文量级字且不含阿拉伯数字」的全部数值读数。**最终误读 0 类**，但过程量出三次真实的过度识别，都被守卫挡掉：

| 误读 | 出现次数 | 触发它的词 | 处置 |
|---|---|---|---|
| `百分 → 100分` | 72 | `百分比`、`百分点`（方案第 397 行恰好点名这个量） | `分(?![之比点号位])` |
| `百分 → 100分` | 29 | `个百分点` | 同上 |
| `百分 → 100分` | 5 | `百分号` | 同上 |
| `百分 → 100分` | 2 | `百分位` | 同上 |
| `零一二三四五六七八九十百千万 → 900000` | 2 | **源码里的正则字符类字面量** | **不修**，见下 |

第一版守卫只写了 `分(?!之)`，量出来还有 29 条——真实语境是「个百分点」。补成 `之|比|点` 后仍有 5 条、2 条，逐次补到 `号|位`。**这个列表是实测出来的，不是构造出来的**；它是穷举式的，将来出现第 6 个「百分X」词还要再加一项，而 `一百分`（100 分）必须继续读得出来。

最后一条**选择不修**：那 2 次出现在 `itn.py` 的正则字符类 `[零一二三四五六七八九十百千万\d]` 字面量里。提词稿与 ASR 输出都不会包含「零一二三四五六七八九十百千万」这样的字符串串，而任何按长度或按字符集的守卫都会误伤合法长数字（`一百二十八`、`一亿二千三万四千五十六`）。**如实记为实测残留**。

语料里剩下的读数绝大多数是**报告自身的轮次数字**（`第五十一轮`→`51`、`第三十七轮`→`37`），它们是这轮修复的**受益者**而不是误报：修复前「第五十一轮」与「第51轮」归一结果不同、永远对不齐，现在两者都得到 `["第","51","轮"]`。

#### 变异 9 条，全部被杀；其中 2 条首轮存活并补了回归

| 变异 | 触发的断言数 |
|---|---|
| M33 删掉 `.spokenMagnitude` 规则 | 13 |
| M34 删掉 arabic 正则的 `(?:[万亿千百])?` | 4 |
| M35 `arabicValue` 不再折算量级 | 9 |
| M36 删掉小量级「补 1」 | 1 |
| M37 删掉大量级「补 1」 | **0 → 存活**，补回归后 3 |
| M38 去掉 `分` 的词汇守卫 | 4 |
| M39 去掉「两个大量级相邻」守卫 | **0 → 存活**，补回归后 2 |
| M39b 只从 `spokenUnit` 一侧去掉该守卫 | 1 |

两条存活都是**真缺口**，不是无效变异：

- **M37**：大量级补 1 只在「整串前面什么都没有」时生效，它唯一的用例就是裸量级——`万元`、`亿元`，以及「融资额以亿元为单位」这种真实稿件句式。修复前它们会读成 `0元`。补的回归 `aBareMagnitudeIsItsOwnPowerAndTwoInARowAreAWord` 把它钉住。
- **M39**：守卫是「万亿」「亿万」「万亿元」不被当成数字的唯一依据。`万亿元` 尤其要紧——没有守卫时它读成 `10000元`，而它是一万亿。补同一条回归里的 `万亿元` 与 `万亿` 两条断言。

`一百分`、`四十分钟`、`十万`、`三百` 各自作为**反向对照**写在回归里：守卫收得太紧就会误伤它们。

#### 查过第三方库，结论是「不集成，但服务端值得单独评估」

接手方大概率会问「这块有没有成熟工具」。**2026-09-29 逐个拉取实测**（不是查资料）：

| 候选 | 版本 / 发布 | 许可 | 实测结论 |
|---|---|---|---|
| `cn2an` | 0.5.24 / 2026-04-22 | MIT，1 个纯 Python 依赖 | Python 3.14.7 装上即用。`三万`→`30000`、`三万零五百`→`30500`、`我买了三万个`→`我买了30000个`、`万亿`／`万一` 正确不动。两处过度转换：`第一`→`第1`、`十分`→`10分` |
| `wetext` | 0.1.8 / 2026-09-09 | Apache-2.0，依赖 `kaldifst`（2.6 MB 原生） | **API 两周内改过**：文档里的 `wetext.processing.inverse_text_normalization` 已不存在；`Normalizer.normalize` 是**反向**的（`2万元`→`两万元`） |
| `chinese-itn-swift` | 0.3.0 / 仓库建于 2026-05-19 | Apache-2.0 | 纯 Swift 3850 行、自带 WeText 官方用例 parity 测试、README 直接提到 Qwen3-ASR。**但全部公开 API 只有 `ChineseITN.normalize(_:) -> String`**，没有任何 span／token 级输出 |

**不集成的理由是接口形状，不是算法质量**：`TeleprompterCanonicalizer.units()` 必须返回**逐单位带 UTF-16 区间**的值，因为 `Script.tokens(forSegmentAt:)` 把每个 token 锚在显示区间上，对齐器返回的 `Position(segmentIndex:utf16Offset:)` 直接驱动舞台滚动。用整串归一再反推位置，恰好会打掉「阅读位置锚在显示文本上」这条产品要求。另外 `chinese-itn-swift` 的默认预设**漏掉「量级+量词」这个最常见形状**（`我买了三万个`、`海拔三千米` 都不转），`--enable-0-to-9` 能补上但同时把 `第一` 变成 `第1`；cn2an 恰好相反。

**服务端 `itn.py` 的结论在第四十轮被推翻了，换库是错的**，见 §2.25：`apply_light_itn` 的问题不是「算法不如 cn2an」，而是**它会把句子改坏**（`百分之`→`0分百`），而 cn2an 在这个代码库里同样会把句子改坏（`一共`→`1共`）并把词内的一转成 1（`统一`→`统1`）。

素材回归 `swift test` **301 项 / 16 套件通过**（新增 5 条）。

### 2.25 第四十轮：服务端 ITN 把量级当数值，改坏的是句子而不是数字（第 67 条）

这一轮的起因是第 66 条留下的那句话——「服务端换 cn2an 是净收益，等产品拍板」。产品要求**统一服务端集成方案**，于是把三个候选在同一组 29 条用例、同一套期望下逐个实测（不是查资料）：

| 候选 | 不符期望 | 失败性质 |
|---|---|---|
| 现状手写 `apply_light_itn` | **14/29** | 3 处**主动破坏文本**：`这是百分百的努力`→`这是0分百的努力`、`我万分感激`→`我0分感激`、`十分之一`→`10分之一` |
| `cn2an` 0.5.24 `transform()` | 7/29 | 1 处破坏（`一共三十人`→`1共30人`）+ 词内误转 |
| `wetext` 0.1.8 ITN | 15/29 | 单位本地化，方向与本项目相反 |

**结论是「不换库」。理由不是风格偏好，三条都量过：**

1. **cn2an 会转词内的一**。`cn2an.cn2an()` 只接受纯数字串，混合文本只能走 `transform()`，而它恒为 smart 模式，**没有「必须带单位后缀」这个保守档**。10118 行含中文数字语料上它改了 6818 行，抽样里混着 `统一`→`统1`、`一个`→`1个`、`一律`→`1律`、`一套`→`1套`、`二进制`→`2进制`、`三档`→`3档`。要挡住这些就得自己维护 `统/一/般/样/起/直/律/套/二/三/六` 的词表——那才是真的重复造轮子。`一共`→`1共` 还是 cn2an 自身的 bug。
2. **wetext 的 ITN 做单位本地化**：`一百二十五元`→`125¥`、`跑了三万米`→`跑了30000m`、`延迟三十毫秒`→`30ms`，`二〇二六年`→`二〇26年`。而服务端 ITN 的产物要回贴原稿做对齐，把「米」换成 `m` 等于单方面改掉匹配条件；它还往受管 wheel 里塞一个 native `kaldifst` FST 依赖。另外它 0.1.8 的 API 两周内改过（`wetext.processing.inverse_text_normalization` 已不存在，`Normalizer.normalize` 是反向的 TN），ITN 入口只剩 `Normalizer(lang="zh", operator="itn")`。
3. **现状那句「必须有单位后缀才转」正是躲词内误转的保守设计**，代价只是少转：语料上只有 70 行是「只有现状会改而 cn2an 不改」。

**真正的缺陷是 3 行代码，不是一个缺失的库。** `_chinese_to_int` 只给 `十` 做了「量级前无数字时补 1」，`百/千/万/亿` 没做，于是量级单独出现时算出 **0**：

```
_chinese_to_int('十') = 10      _chinese_to_int('百') = 0
_chinese_to_int('千') = 0      _chinese_to_int('万') = 0
```

757707 行语料上量到 **165 处**算出 0，压倒性多数是 `[百][分]`（`百分之`／`百分比`／`百分点`／`百分号`／`百分位`，正是 Swift 侧第 66 条已用 `分(?![之比点号位])` 逐个挡掉的同一批），另有 `[万][元]`（`万元`）、`[万亿][元]`（`万亿元`）与 `[零][点]`。同时量到**裸量级取错值**：`数十秒`／`几十秒`／`数十万个`／`数万` 会读成 `10秒`／`10个`／`10元`——那是数值直接错，不是过度转换。

四处改动，全部由语料决定，没有一条是构造出来的：

- **量级补 1 扩到全部量级**，并加 `seen_any` 守卫，使它在一条数字串里只生效一次（否则 `万亿` 会被补两次 1）。与 Swift 侧第 66 条是同一个 bug、同一个修法。
- **`亿` 改为缩放累计值**而不是只缩放当前 section。旧写法让 `万亿` 读成 `100010000`。
- **`分` 加两道守卫**：裸量级在前时不转（`十分满意`／`百分百`／`百分点`），`分之` 前不转（`二分之一`／`四分之三`）。`三分钟` 仍转（`三` 带数字）。
- **删掉单位 `点`**。86 处 `X点` 里 **46 处是普通词**（`这一点`／`短一点`／`有一点`），合法用法（`今天下午三点开会`）与歧义用法（`十点`＝10 点还是十点钟）不值得赌。**删单位只会少转，不会改坏句子**——这是本轮唯一敢做的方向性取舍。
- **数字串前加 `(?<![数几零一二两三四五六七八九十百千万亿])`**。`数`／`几` 不是数字，量级会从它们后面起匹配；把数字也放进后顾断言是为了让被挡下的匹配不能在后面的量级上重新起（`数十万个` 否则会退到 `万个` 读成 `10000个`）。

**语料前后对比（64856 行含中文数字的 md/txt）**：输出改变 115 行，**修掉破坏 59 行，新增破坏 0 行**，其余 56 行逐条看过全是修复方向（`一点`／`百分之`／`零点`／`三分之一` 复原）。

**一处行为损失要如实记下**：`今天下午三点开会` 不再归一成 `3点`。这是删掉 `点` 的代价，方向安全（少转而不是改坏），但确实是能力回退，已写进本节与 §6。

**变异验证 10 条全部被杀**（基线自检通过后才开始）：补 1 只留给十、`亿` 只缩放 section、去掉 `数/几` 后顾、后顾只留 `数/几`、去掉 `分` 的裸量级守卫、去掉 `分(?![之])`、把 `点` 加回、去掉 `seen_any`、量级不再置 `seen_any`、后顾清空。**其中两条首轮存活的都是探针缺陷不是缺口**：`seen_any` 相关的两条最初只替换了第一处 `seen_any = True`（`replace` 漏改或锚点缩进写错），并没有真的测到「量级重复补 1」；改成全量替换后两条都被杀，语料上分别差 109 行。**这一轮还真实暴露过一次自己的编辑事故**：修 `十` 分支的 `seen_any = True` 时替换串缩进写错而静默未生效，随后的变异脚本又因参数错误中途退出，把变异体留在了文件里——是「还原后 rc≠0」这一条自检把它拦下来的，否则会带着一个错的 `_chinese_to_int` 提交。

### 2.26 第四十一轮：语义风险检测器在中文提词稿上**整条静默**（第 68 条）

`TeleprompterSemanticRiskDetector` 承载验收标准第 1 条的「主体关系、否定和条件变化可定位审阅」，接线点在 `withSemanticReview`（3 处调用）。**它在阶段报告里零次被提及，也零条测试覆盖中文主体。**

探针实测（`swift test --filter probeSemanticRisk`）：

```
--- 主体-数值 ---
PROBE ascii:     ["subject_value_changed"]   ← 既有测试用的 ASCII 主体
PROBE cn-甲乙:   []                          ← 中文主体，静默无输出
PROBE cn-单主体: []
PROBE cn-第N批:  []
```

根因是 `nearestSubject` 的两条正则**都要求主体是 ASCII 字母**（`([A-Za-z][A-Za-z0-9+#-]*)\s*的…` 与 `\b([A-Z][A-Za-z0-9+#-]*)\b…`），而 `findings` 又要求两侧 pair 都非空。纯中文主体 ⇒ pair 恒空 ⇒ **对中文提词稿（产品主语言）主体—数值变化完全检测不到**。

**这一轮先量了四种中文主体规则，全部否掉，只留下一种。** 语料为仓库内 2330 个文件：

| 候选规则 | 语料命中 | 否掉的理由 |
|---|---|---|
| `的` 前锚定（取分句首汉字 run 再按 `的` 切） | 350 | 高频命中是量词与代词碎片：`稿`、`我`、`零事件`、`帧`、`行`、`秒`。中文「的」字结构是「修饰语 + 的 + 中心语」，紧贴 `的` 前面拿到的是修饰语碎片，不是主体 |
| 分句首**天干**标签（甲乙丙丁…） | 32 | `未`（不是）与 `子`（子任务）撞掉绝大多数。**把这两个字从表里去掉后归零** |
| 要求文本内存在 ≥2 个平行标签（互换的语义前提） | — | 条件在技术文档里被平凡满足，`稿`／`我`／`零事件`／`与帧`／`差`／`少掉`／`它们`／`新增`／`多出来` **全部存活** |
| 分句末裸汉字 run | 10007 | 被 `第/见/与/约/在/的/为/按/是` 这些单字功能词占满 |
| **序数标签 `第N` + 量词** | **38** | **38 处逐条可读，是唯一通过的** |

**为什么不接受「脏一点但覆盖广」**：`withSemanticReview` 里任何 finding 都会把 block 的 disposition 打成 `.unresolved`，即**误报的代价是拦下一次自动朗读**。在这个代价下窄而准优于宽而脏，这也是第 65／66 条同一条取舍。

**落地范围严格等于语料**：量词表只含实测出现过的 7 个字（轮 30、次 4、批 4、组 1、条 1、版 1、项 1），数字表只含实测出现过的 `一二三四五六七八九十百千`（`两`／`零` 在语料里从未出现在序数里，按第 65 条的规矩不引入未实测面）。

**同一轮还修掉一个由这次改动暴露的既有比较缺陷。** 原比较是两张 pair 列表的全等：`sourcePairs.map(\.identity) != candidatePairs.map(\.identity)`。**少掉一个 pair 会被读成「变了」**——删掉 `第一批采购 50 台，第二批 80 台` 里的逗号，序数就不再位于分句起始，候选侧只剩 1 个 pair 而原文侧有 2 个，于是**纯标点改写被判成主体数值互换**。改为**只比较两侧都出现的主体**。同一处潜伏缺陷在 ASCII 侧同样存在（`方案 A 的成本 50 元，方案 B 的成本 80 元` 删掉逗号同样误报），一并修掉。**是否丢了内容不归这道检查管——那是保真门禁的职责。**

**变异 9 条，7 杀 / 2 条经实测确认为等价变异**（不是断言：把探针输出逐案与基线比对，完全一致才下结论）：删掉序数规则、去掉分句起始后顾断言、量词表去掉「轮」、去掉「批」「组」、数字串上限收到 0、比较退回整张 pair 列表、数字类加回「两」「零」——**7 条全杀**；分句字符集去掉「，」与「把序数规则挪到 ASCII 规则之前」两条**存活但等价**：交集比较之后边界集不再改变判定（两侧对称地丢同一批主体），而两个模式族互斥（一个要拉丁 token，一个要分句首的 `第` + 中文数字），次序今天不承重——已写进代码注释，不是碰巧。

**已知但本轮不修**：否定标记里的单字 `未` 会命中 `未来`（`未来的计划不变` → `将来的计划不变` 误报 `negation_changed`）。这是误报而非漏报，按本轮取舍需先量过再定，列为下一条。

### 2.27 第四十二轮：单字否定标记把「未来」读成否定，一次无害改写拦下一次朗读（第 69 条）

第 68 条的同一个探测器上还有一处**误报**，本轮量过再定。探针实测：

```
PROBE future:        ["negation_changed"]   ← 「未来的计划不变」→「将来的计划不变」
PROBE real-negation: ["negation_changed", "comparison_changed"]
```

`negationMarkers` 里 7 个标记只有 **`未` 是单字**，而它同时是 `未来`／`未必` 的首字。`markerCounts` 用的是字面量 `range(of:)`，没有任何后继字约束。

**语料实测（仓库全文 4495 处「未」）**：

| 形态 | 出现 | 判定 |
|---|---|---|
| `未` + 动词（未验证／未执行／未提交／未授权／未经明确…） | 4086 | **真否定，必须保留** |
| `尚未X` | 247 | **真否定，必须保留** |
| `未来` | 44 | **非否定** |
| `未必` | 3 | **非否定**（是让步语气，且 `certaintyMarkers` 已收 `可能`／`也许`，它属确定性而非否定） |
| `未知` | 362 | **有意保留**——`原因未知`→`原因已知` 是真的语义变化 |

**为什么这条值得修而不能按「影响很小」放过**：文档语料里 `未来` 只占 1%，但**提词稿是口语稿**，「未来 → 将来」是中文改写里最常见的同义替换之一，真实稿件里的命中率远高于此。而 `withSemanticReview` 里任何 finding 都把 block 打成 `.unresolved`——**每一次这样的无害改写都拦下一次自动朗读**。

**修法是一张后继字守卫表，不是把标记换成枚举**。枚举 `未验证`／`未执行`／… 正是第 65 条否掉过的做法（要自己维护一张动词表，且漏一个就漏检）。守卫挂在字面量搜索上：`未` 后面紧跟 `来` 或 `必` 时不计。**选字面量守卫而不是改成正则**是有意的——标记表用 `range(of:)` 匹配，把整张表改成正则会让其他每一个标记的含义都开始依赖正则语法。

**这一轮自己犯了一次 off-by-one，第一次实现完全没生效**。守卫里写成 `text.index(after: range.upperBound)` 再判断，等于**跳过了要检查的那个字**（`upperBound` 本身才是后继字）。表现是探针仍然报 `negation_changed`、8 条新测试全红而代码看起来是对的；靠「探针输出不随预期变化」才定位到。修好后变异 **7 条全杀**，其中 N6 就是把这个 off-by-one 原样改回去——**它被杀死，说明回归真的钉住了这一处**。

### 2.28 第四十三轮：数字与单位之间的空格把 token 切开，脚本里几乎每个数字都对不上（第 70 条）

这一轮是接着第 68、69 条去扫**剩下的同类规则面**（枚举式与单字符式）时撞上的，不在原计划的路线上。探针实测：

```
PROBE 米-空格:   ["3", "米"] vs ["3米"]  不匹配
PROBE 元-空格:   ["50", "元"] vs ["50元"]  不匹配
PROBE 点-空格:   ["10", "点"] vs ["10点"]  不匹配
PROBE 台-空格:   ["5", "台"] vs ["五", "台"]  不匹配
PROBE 米-无空格: ["3米"] vs ["3米"]  匹配
```

**与 `点` 无关，所有单位都中。** 语料实测：仓库文档里「数字 + CJK 单位」共 6788 次，**其中 6650 次（98%）在数字与单位之间有空格**，只有 138 次紧接。

**为什么这比看上去严重**：提词稿常常是从 markdown 文档改写而来的，而那类文档正是 overwhelmingly 带空格的那一种；识别器转写的是口语，**不带空格**。于是**脚本里几乎每一个数字都落在两个不同的 token 流上**，跟随器在那些位置永远匹配不上、不推进——直接打在判据第 2 条上。

**第一层根因**：`.arabic` 规则的单位组前面没有 `\s*`，空格把 token 切开了；而 `.spokenUnit` 处理的是中文数字，两侧因此落到不同的切分上。

**第二层根因才是「治本」那一半**：`.arabic` 与 `.spokenUnit` **各自维护一张单位表，而且已经分叉**——`.arabic` 有 `年` 而 `.spokenUnit` 没有，`.spokenUnit` 有 `台`／`条`／`项`／`字` 而 `.arabic` 没有。于是 `三年` 匹配不到任何东西，`5 台` 与 `五台` 也对不上。**两张表能漂移，本身就是缺陷**；修法不是把某一张补长，是**合成一张、按长度降序、两条规则共用**，`unitAlternation` 由 `unitSuffixes` 直接派生，漂移不再可能。

**成员仍然按第 65 条的规矩量，不按构词感觉选**：

| 判定 | 单位与它在语料里的真实后继 |
|---|---|
| **否掉**（会吞掉下一个词） | `条`→`件`（条件 500）、`字`→`段`（字段 883）、`页`→`面`（页面 807）、`版`→`本`（版本 1072）、`项`→`目`（项目 330）、`周`→`期`（周期 350）、`段`→`落`（段落 131）、`克`→`风/隆`（克服／克隆 620）、`台`→`账/窗`（台账 56）、`根`→`因/据`、`章`→`节`（章节 33）、`张`→`卡/表` |
| **收进来**（后继干净） | `份`、`吨`、`小时`(72)、`毫秒`(30)、`公斤`、`千克`、`毫升`、`厘米`、`毫米`，以及为对称补的 `年` |

**顺序是承重的，不是风格**：`unitSuffixes` 被一处 `first(where: hasSuffix)` 消费，取第一个命中。若 `米` 排在 `厘米` 前面，`五厘米` 会匹配到 `米`、把 `五厘` 留作数字、numeral-run 检查失败，**于是这个 token 干脆不再是数字**——比不匹配更隐蔽。

**这一轮自己写错了一条测试，变异把它抓了出来**。`unitsThatWouldSwallowTheNextWordAreLeftOut` 最初只断言「两侧**不同**」；把 `台` 加回表里两侧仍然不同，测试照绿——但失败方式已经变成**更糟的不对称**（`5 台` 绑定成 `5台`、`五台` 仍是 `五`+`台`）。改成钉死两侧的确切 token 流之后，`台` 加回被杀掉。**「断言不等」不等于「断言了想要的那件事」**，这是本轮最值得带走的一条。

**变异 9 条全杀**（含首轮存活的 `C6` 顺序与 `C7` 加回 `台`，两者都是补强测试后才转杀）。**已知且不再修的缺口**：`五台` 与 `5 台` 仍然对不上，原因是 `台` 属于被否掉的那一类，已写进代码注释与本节，接手方不必重新量一遍。

**另一条该记的**：`swift test` 的套件数从 9 掉到 4 暴露了本轮**误删了 7 条既有测试**——插入新测试时按 `\n}` 定位结构体结尾，命中了更早的位置。靠与 HEAD 比对测试数发现并从 git 取回。**测试文件被削过而门禁仍然全绿，正是这份报告一直在记的那类失效**；此后本轮结束时用 `git diff --numstat` 确认该文件是纯新增才提交。

### 2.29 第四十四轮：全角数字从数值保真闸的旁边绕了过去（第 71 条）

接着第 70 条去扫剩下的同类规则面，探针实测：

```
PROBE 全角数字:   ["延","迟","50毫秒"] vs ["延","迟","5","0","毫","秒"]  不一致
PROBE 全角百分号: ["准","确","率","99"] vs ["准","确","率","99%"]        不一致
PROBE 全角百分之: ["100","分","之","5","0"] vs ["50%"]                 不一致且被改坏
PROBE 标点/引号/省略号/换行/制表                                      全部一致
```

**缺陷不在「宽度」，在「宽度 × 单位」，这一点是量出来的而不是想出来的**。仓库里全角数字共 22 处、文档里 **0 处**，13 行含全角数字的语料里只有 3 行输出改变，且这 3 行全是本轮自己新写的测试与代码行。另外 10 行是 `case "０": return "0"` 这类**单个**全角数字——`appendNormalized` 里的 `fold` 早把它们折成 ASCII，所以单个数字本来就一致。旧代码不一致的恰恰是**多位**数字：`准确率５０％` 被切成 `准,确,率,5,0`，`％` 直接消失。

**最要紧的一条是 `百分之５０`**：全角数字让 `.percentage` 规则匹配不到，规则表里就没有任何规则接住它，**裸量级规则接手把 `百` 读成 100**——「百分之五十」被读成「100 分」。这和第 67 条修掉的量级缺陷是同一类，只是从全角这条缝里又钻进来一次。**同一条缝，先漏检、再改坏句子，两级都在同一处。**

**根因与第 70 条同形**：`TeleprompterProtectedAtom` 的数字正则从一开始就写的是 `[0-9０-９]`、单位组写的是 `%|％`，而 `TeleprompterCanonicalizer` 三条规则都只写 `[0-9]` 和 `%`。**同一层里两处规则对「什么算一个数字」已经不一致**，与第 70 条那两张分叉的单位表是同一种病。修法同样不是把某几处补长，是**把数字字符类收敛成一个 `digitClass` 常量**，三条规则共用——漂移不再可能。取值侧只加一个 `asciiDigit`（全角 U+FF10–FF19 偏移 10 即 ASCII，精确而非查表）。

**宽度归一必须落在值上，不能落在源上**。`Script.tokens(forSegmentAt:)` 把每个 token 锚在显示区间上，对齐器返回的 `Position(segmentIndex:utf16Offset:)` 直接驱动舞台滚动；先折半角再匹配会挪动后面所有字符的 UTF-16 位置。实现里值折半角、**区间仍按源串算**，并用 `延迟５０毫秒。` → `50毫秒@2-6` 钉住。

**语料差分证明对既有文本零影响**：改动前后对仓库 30702 行含数字语料逐行比对输出，**30699 行完全一致，3 行有差异且全部是含全角数字的行**。

**变异 9 条：7 条首轮被杀，2 条存活并查因。**

| 变异 | 首轮 | 查因与处置 |
|---|---|---|
| M1–M6（`.arabic` 只留半角／`asciiDigit` 去掉全角分支／取值不映射宽度／`chineseInteger` 早返回只认 ASCII／`asciiDigits` 不映射宽度／`％` 从交替里删掉） | **KILLED** | — |
| M7 先把整段文本折成半角再匹配（天真修法） | **SURVIVED** | **等价变异**，非测试无效。逐案比对证明：30702 行语料 **0 行差异**，另跑 406 条针对性宽度用例（含 `50/５０/5/５/2026/２０２６/1.5/１.５` × 10 种单位 × 4 种前缀）**0 条差异**。原因是 `fold` 的 width 折叠对数字与 `％` 是 1:1 的 UTF-16 等长替换，偏移量恰好相同。**等价只在这些字符上成立**，一旦折叠对象含会改变长度的字符就不成立——所以实现仍取「值折、源不折」这一条 |
| M8 区间长度改用 canonical 值的 `value.count` | **SURVIVED → 补回归后 KILLED** | **首轮是真缺口**。`50毫秒` 的值恰好也是 4 字形、与源区间等长，所以侥幸通过；但量级词折进数字后值比源串长——`2万元` 的值是 `20000元`（6 字形对 3 个 UTF-16 单位），区间算成 `0-6`，**越过了数字本身锚到后面的文字上**。**314 条既有测试没有一条会红**。补 `canonicalValuesFoldButRangesStayOnTheSourceText` 的量级断言后转杀 |
| M9 `asciiDigit` 顺带接受阿拉伯-印度数字 | **SURVIVED** | **等价变异**。`digitClass` 不含 `٠-٩`，规则根本不匹配，函数不会被问到；406 条用例（含 `٥٠毫秒。`／`准确率 ٩٩％。`／`٥ 万元。`／`۵۰`）**0 条差异** |

**量到并明确记录的边界，不修**：阿拉伯-印度数字（U+0660–0669）与波斯数字（U+06F0–06F9）仍不被识别为数字。`indexedTokens` 用 `CharacterSet.decimalDigits`，它**接受**这些字符，于是它们变成单字数值 token——**与全角修复前一模一样的失败模式**；且 `fold` 的 width 折叠把 `٩` 折成 `9` 却折不了 `۵`(U+06F5)，**同一类字符内部还不自洽**。实测 `٥٠毫秒。` → `٥|٠|毫|秒`，`۵۰` → `۵|۰` 原样。中文口语稿里不会出现这些数字，量级远小于 `五台` 与 `5 台` 那个已记录的缺口，不修。

**顺带否掉的一个方向**：`1，234`（全角逗号当千分位）与 `1,234` 在半角下**同样**对不上，属另一处缺陷。**它不能拿来当全角的回归用例**——那会把两个缺陷混进一条断言，将来其中一个修好时另一个会让它变红。回归里配对的两侧只差宽度。

### 2.30 第四十五轮：口语小数的点前字符类漏了 `两`，`两点五` 被读成「两点钟」（第 72 条）

第 71 条的探针顺手打出了口语小数那一簇的读数，其中两条是**改坏语义**而不是少转：

```
PROBE [两点五]     -> ["2点@0-2", "五@2-3"]   即「两点钟」+「五」
PROBE [三点五]     -> ["3.5@0-3"]
PROBE [三点十四秒] -> ["3点@0-2", "14秒@2-5"]
PROBE [7点40分]    -> ["7.40@0-4", "分@4-5"]  钟点被读成小数
```

**根因是枚举式的**：`.spokenDecimal` 的点前字符类 `[零一二三四五六七八九十百千万]` 漏了 `两`，而 `chineseDigits` 认它、服务端 `_CN_NUM_RE` 也把它列在首位。规则匹配不上，**接手的正是 `.spokenUnit`——而 `点` 在单位表里**，于是小数被读成钟点。这和第 67 条同形：看起来是完备规则，实际是枚举式的，而漏掉的那一个恰好让整条规则失效、把文本交给另一条规则按错的读法处理。

**修法是我自己的判断，不是取自服务端——第四十八轮更正了这里的一处错误归属。**本节原先写「修法取自服务端」，依据是服务端 `_CN_NUM_RE` 里有 `两`；但真正管小数的那条是 `_DECIMAL_RE = ([零一二三四五六七八九十百千万\d]+)点([零一二三四五六七八九\d]+)`，**它的点前类没有 `两`**，实测 `apply_light_itn("两点五")` 原样返回 `两点五`。**所以两侧现在是不一致的方向：Swift 转成 `2.5`（对的），服务端原样不动（它有同一个枚举式遗漏）。**边界仍按语料钉死：点前类补 `两`，点后类**不动**（`_DECIMAL_RE` 点后类同样没有 `两`），`〇` 两边都不加。**接手方不要把这一条当成「照服务端做」**——它比服务端多走了一步，理由是 `两点五` 在中文里就是 2.5，而服务端那一侧要改就得单独开工单。

**语料基线（这是边界，不是完备性证明）**：口语小数（`三点五` 形状）全仓 **13 处**，阿拉伯小数（`3.14`）**15784 处**，比例约 1:1200；点前用 `两` 5 处里 3 处是假阳性（`样本不足两点的序列`、`首尾两点`），点后用 `两` 仅 1 处且是假阳性（`落点两块`），点前／点后用 `〇` **各 0 处**。

**这一轮最该记的是：语料差分 0 行差异，而那不叫「无影响」，叫语料看不见它。** 30702 行含数字文档逐行比对，改前改后完全一致——因为 13 处口语小数里没有 `两点五` 这个形状。**这正是必须写回归而不是靠语料兜底的场合**，报告里把它写成「0 差异」会误导接手方。

**变异 5 条：3 条首轮被杀，2 条首轮存活且都不是等价变异。**

| 变异 | 首轮 | 查因与处置 |
|---|---|---|
| N1 撤回 `两`（回到修复前）／N4 把 `两` 换成 `〇`／N5 只在点后类放 `两` | **KILLED** | — |
| N2 把 `两` 也放进点后类 | **SURVIVED** | **不是等价变异**：1170 条小数矩阵（13 点前 × 15 点后 × 6 后缀）上改变 **72 条**行为，如 `零点两` 由 `0点`+`两` 变成 `0.2`、`一点两` 变成 `1.2`。语料上没有证据支持任何一边，所以补断言把边界**写死**成「与服务端逐字一致」，并注明依据是「点后用 `两` 唯一一处是假阳性」，N2 转杀 |
| N3 把 `〇` 放进点前类 | **SURVIVED** | 同样**不是等价变异**：矩阵上改变 **72 条**（`〇点五` 由 `〇`+`点`+`五` 变成 `0.5`）。`chineseDigits` 确实认 `〇`、`.year` 也认，所以放它进去在直觉上说得通；但**点前用 `〇` 语料 0 处**，服务端也不认。补断言钉住「与服务端一致」后转杀 |

N2 与 N3 都属于第 70 条那条教训的同一次复发：**「断言不等」不等于「断言了想要的那件事」**。第 72 条的回归最初只钉了 `两点五` 这一个正例，两个反向的成员边界一个都没写，于是两处真实的成员变更都能让它全绿。

**本轮明确分离出去、不混进同一条断言的三处**（与第 71 条同一条纪律：把两个缺陷塞进一条断言，将来只修好一个就会让这条回归因为另一个而变红）：

1. **口语小数不带单位组**：`三点五秒`、`三点一四秒` 都读成 `3.5`+`秒`，而书写侧的 `2.5秒` 是一个整体——`.arabic` 带单位组、`.spokenDecimal` 不带，与第 70 条「两张表分叉」同形。**这是下一条候选。**
2. **`7点40分` → `7.40`**：钟点被 `.arabic` 的小数分支读成小数。`点` 同时是十进制点、钟点和普通词（`这一点`／`短一点`／`第二点`），语料 109 处里压倒性是普通词——服务端 `itn.py` 早已因此**把 `点` 整个排除出单位表**，理由写在代码注释里：「丢掉一个单位只是少转，保留它会改坏句子」。而 Swift 侧把 `点` 留在了表里，于是 `这一点`→`这`+`1点`、`短一点`→`短`+`1点`。**两侧对同一个字符的判断正好相反，这是需要产品判断的取舍，不在缺陷范围内擅自改。**
3. **`〇` 在小数点前不被识别**，理由如上，已钉成断言。

### 2.31 第四十六轮：口语小数不带单位组，同一个数量写成两种数字就对不上（第 73 条）

第 72 条结尾点名的下一条候选。探针上 **12 个单位形状无一例外全部拆开**：

```
PROBE [三点五秒] -> ["3.5@0-3", "秒@3-4"]   vs  [2.5秒] -> ["2.5秒@0-4"]
PROBE [九点九分] -> ["9.9@0-3", "分@3-4"]   vs  [9.9分] -> ["9.9分@0-4"]
PROBE [三点五 元] -> ["3.5@0-3", "元@4-5"]  vs  [2.5 元] -> ["2.5元@0-5"]
```

**根因与第 70 条同形，只是分叉的部位不同**：`.arabic` 的规则带单位组、`.spokenDecimal` 不带。**同一条缺陷家族第三次出现**——第 65 条是「保真门禁的单位是枚举式的」、第 70 条是「两张单位表各自漂移」、这一条是「两条规则带不带单位组都不一样」。三次的共同形状是**同一个概念（数字加单位）在几处各写一遍，没有一处负责说「这就是全部」**。

**修法不是给口语小数单配一张表，是复用第 70 条已经合成的那张 `unitAlternation`**——再配一张就是把这个缺陷原样再造一遍。

**取值时必须先把单位后缀剥掉再找小数点**，因为 `点` 本身就在单位表里：`三点五点` 的末尾 `点` 是单位、靠前的 `点` 才是小数点，顺序反了会读成 `3.40`。同时把 `.arabic` 里那套「空格是排版」的处理一并搬过来，否则 `三点五 元` 的值会带空格。

**语料差分：30702 行含数字文档，改前改后只有 4 行变化，全部是「口语小数+单位」形状**（`三点一四` 的区间多延 1 个单位；两处 `7点40分` 由 `7.40`+`分` 合并成一个 `7.40分`）。

**关于那两处 `7点40分`，必须说清楚**：本条**没有修好那个错读**，错读在改前就存在（`.arabic` 的小数分支本来就把 `7点40` 读成 `7.40`）。本条只是让两个 token 合成一个。**更重要的是它没有制造假放行**：脚本侧 `7点40分` 规范成 `7.40分`，识别器侧的 `7.410分` 规范成 `7.410分`，两者仍然不等。而这个错读本身**已在 #95 认证文档里登记为模型 ASR 的转写偏差**（`synth-zh-number-10`，数字/单位门 54/60 = 90% 未达 95% 口径，文档明写「不是脚本解析缺陷」）——**两条独立路径（模型与 canonicalizer）对同一输入撞上了同一个错模型**，这也是下面那条 `点` 的取舍值得产品拍板的实据。

**变异 5 条：3 条首轮被杀，2 条存活——查因之后发现两处守卫都是冗余的，已删除。**

| 变异 | 首轮 | 查因与处置 |
|---|---|---|
| P1 撤回单位组／P2 给口语小数单配一张更短的表（`元\|个`）／P4 不滤空格 | **KILLED** | P2 被杀正说明**「再配一张表」这条路是走不通的**：第 70 条刚合并的那张表覆盖 12 个形状，任何局部子集都会立刻破 |
| P3 去掉 `body.contains("点")` 守卫 | **SURVIVED** | **等价变异**。2873 条小数矩阵（13 点前 × 13 点后 × 17 单位／后缀）**0 条差异**：紧随其后的 `firstIndex(of: "点")` 在没有 `点` 时同样返回 nil，该守卫被完全覆盖。**已删除**——一条没有任何输入能区分的守卫是噪音，而这份报告一直在记这类失效 |
| P5 去掉 `collapsed.count > unit.count` 守卫 | **SURVIVED** | **等价变异**，矩阵 0 条差异。正则保证至少匹配 `X点Y` 三个字符，单位最长 2 字符，该条件按构造不可达；且 `dropLast` 在越界时返回空串，随后 `firstIndex` 返回 nil，属安全降级。**已删除** |

**删掉两处守卫后重跑语料与矩阵，差异均为 0 行**——这是「等价变异」结论的对照证据，不是推断。

**本轮再次明确分离出去、不混进同一条断言的**：`三点五万元` 的 `万` 仍接不上（`3.5`+`10000元`，与 `五台`／`5 台` 同族的已记录缺口）；`7点40分` 与 `这一点`／`短一点` 那个 `点` 的取舍，仍留给产品判断，见 §2.30 第 2 条。

### 2.32 第四十七轮：保真门禁漏掉了 canonicalizer 认得的五个单位，单位改写全部静默放行（第 74 条）

第 73 条之后把「同一个概念在几处各写一遍」这个家族系统扫一遍：把三处单位枚举逐项 diff。

| 枚举点 | 成员数 | 位置 |
|---|---|---|
| `TeleprompterCanonicalizer.unitSuffixes` | 27 | 跟随侧（切 token、数值指纹） |
| `TeleprompterProtectedAtom` 单位组 | 60 | 保真门禁侧（受保护字面量） |
| 服务端 `itn.py._UNIT_RE` | 16 | 服务端 ITN |

**服务端的 16 项是 canonicalizer 那 27 项的严格子集**（服务端有、canonicalizer 无 = 空集），差出的 11 项是 `份/公斤/千克/厘米/吨/小时/年/毫升/毫秒/毫米/点`。而 **canonicalizer 有 5 项是门禁没有的**：`分/号/岁/楼/点`。

**这 5 项就是漏洞**：canonicalizer 把它们读成数值单位，门禁却不在受保护字面量里，于是**它们之间的每一次互相替换都产生完全相同的原子列表、直接通过硬门禁**。31 个单位两两替换的系统扫描：**静默放行恰好 20 对，全部落在这五个之间；反方向误拦 0 对**。

```
指标是 10分 以内。 → 指标是 10号 以内。   门禁放行，canonical 读法 10分 → 10号
指标是 10岁 以内。 → 指标是 10楼 以内。   门禁放行，canonical 读法 10岁 → 10楼
```

**「10 分」被改成「10 号」，用户听到的是另一个东西，而验收第 1 条写着「数值、单位、正负号及重复内容变化不得静默通过」。**

**根因仍是那句老话**：第 70 条把 canonicalizer 内部的两张单位表合成了一张，**却没有把保真门禁接到那一张上**。合成一张表只解决了自己家门口的分叉，跨组件的那条接缝没人管。

**修法分两层**。表层是把这 5 项补进门禁的单位组；**治本的那一层是一条不变量测试**——`everyUnitTheCanonicalizerReadsIsAlsoAProtectedLiteral` 直接读 `unitSuffixes`（为此把它从 `private` 放宽到模块内可见）并要求每一项都被门禁保护，**下一次新增单位而忘记同步门禁时，它立刻变红**。只补表不写不变量，等于把同一个坑挖好留着。

**变异 5 条：3 条首轮被杀，1 条存活且是真缺口，1 条证明等价。**

| 变异 | 首轮 | 查因与处置 |
|---|---|---|
| R1 撤回五个单位／R2 只去掉 `分`／R3 只去掉 `岁` | **KILLED** | — |
| R7 把 `分` 排到 `分钟` 前面 | **SURVIVED → 补回归后 KILLED** | **真缺口**。探针逐案比对：`10分钟` 的门禁原子由 `10分钟` 变成 `10分`，于是 `10分钟`↔`10分` 两个方向都放行，**而两侧 canonical 读法确实不同**（`10分`+`钟` 对 `10分`）。代码注释里那句「`分钟` 排在前面所以赢」是**承重却无人保护的一句话**，补 `theLongerMinuteUnitWinsOverTheBareFenInTheGate` 后转杀 |
| R8 把 `分钟` 在前缀组内挪到 `小时` 之后 | **SURVIVED** | **等价变异**：门禁全部 40 个单位两两组合共 **3741 条矩阵，逐案比对 0 条差异**。`毫秒/微秒/小时/分钟` 之间互不竞争同一位置 |

**语料差分**：仓库 30702 行含数字文档，门禁的受保护字面量输出**有 58 行变化**——`分` 48 处、`点` 17 处、`号` 1 处，以及 1 处由数字/`.`/`/` 组成的复合原子。绝大多数是正向的（`100分`、`40分`、`13号`、`60点` 确实都含作者写下的数）。**量到一处真实的误保护并保留**：版本号 `2.6.6/2.7.0` 后面跟着「分支」，`分` 被当单位黏上去，`2.7.0分` 成了受保护字面量。代价有界——只在**紧跟文字本身改变**时才会拦（`分支`→`分类`），纯追加文字（`分支`→`分支支持`）两侧原子相同仍放行，空白差异也放行（第 65 条的 `canonicalize` 去空白）。相比漏报「`10 分` 改成 `10 号`」，净收益为正，**不修，但写明**。

### 2.33 第四十八轮：`点` 移出单位表，Swift 侧终于和服务端站到同一侧（第 75 条）

这一条是**产品判断**，不是扫描出来的缺陷，所以先把判断依据和代价一起写在前面。

**依据三条，第一条是量出来的**：

1. **语料**：本仓 109 处 `X点`，压倒性是普通词——`这一点`／`短一点`／`有一点`／`第二点`／`同一点`／`新词一点`。服务端 §2.25 早已在自己的语料上量过同一件事：**86 处里 46 处是普通词**，并写下「删单位只会少转，不会改坏句子——这是本轮唯一敢做的方向性取舍」。
2. **后果不对称**：留着 `点` 会把 `这一点` 读成 `1点`，**凭空造出作者没写下的数并塞进数值指纹**；删掉它只是少转。
3. **留着也换不来时间读法**：`七点半` 得到的是 `7点` + `半`，仍然是数量而不是钟点。删掉损失的是「裸 `三点`／`十点` 被读成 3／10」——**而这个读法本身就不是时间**。

**这不是新决定，是把 Swift 侧拉到服务端已经做过决定的那一侧。** 报告 §2.25 早就把服务端的理由和代价记下来了，两侧对同一个字符判断相反的状态已经挂了很久。

**改完之后两侧实测对齐**（同一批输入，Swift canonicalizer 对 `apply_light_itn`）：

| 输入 | 改前 Swift | 改后 Swift | 服务端 |
|---|---|---|---|
| `这一点` | `这` + `1点` | `这` + `一` + `点` | `这一点`（不动） |
| `第二点` | `第` + `2点` | `第` + `二` + `点` | `第二点` |
| `三点五` | `3.5` | `3.5` | `3.5` |
| `七点半` | `7点` + `半` | `七` + `点` + `半` | `七点半` |
| `两点五` | `2点` + `五` | `2.5` | `两点五`（不动，见 §2.30 更正） |

**两处仍然不一致，都记录不抹平**：`两点五` Swift 转、服务端不转（§2.30 已更正归属）；`十点` Swift 读成 `10` + `点`（`十` 是量级），服务端整词不动。

**`7点40分` 仍被读成小数 `7.40分`——这一条修不了，也不该由这一条修。** 错读来自 `.spokenDecimal` 把 `点` 当十进制点，与单位表无关；**服务端 `apply_light_itn("7点40分")` 同样返回 `7.40分`**，#95 认证里模型 ASR 也独立犯过同一个错（`synth-zh-number-10`）。两侧一致，且是已登记的共享边界。回归里把它钉成**当前的错误读法**并写明理由——否则下一个人会以为「移出 `点`」应该顺带修掉它。

**语料差分（30702 行）**：canonical 输出 **46 行变化**，全部是 `X点` 形状。数值指纹层面：**30656 行完全不变，31 行数字消失**（`3点`／`1点` 不再是数），15 行数字形态变化（`112点` → `112` + `点`，数还在、单位没了）。**按数字多重集严格核验：33 行发生变化的全部是「数字被移除」，没有一行凭空多出一个作者没写的数**——这正是本条要的效果。

**变异 3 条，全部首轮被杀**：S1 把 `点` 放回表里（16 处断言红）、S3 撤回第 72 条的 `两`（4 处红）、S5 让 `unitAlternation` 绕过 `unitSuffixes` 单独保留 `点`（2 处红——**两处列表又分叉的形状，这条测得住**）。

### 2.34 第四十九轮：服务端把 `50万元` 读成 `5010000元`，错两个数量级（第 76 条）

**这一轮起点是一次自我否决，必须先写下来。** 上一轮我拿仓库 30702 行文档喂给 `apply_light_itn`，统计出「改写 1692 行」，样本是 `每 5 秒读一次`→`读1次`、`同一个控件`→`同1个控件`、`四个字段`→`4个字段`，并且说这和当初否掉 cn2an 是同一条理由。**那是假警报，量错了对象。**

`apply_light_itn` 只作用于 **ASR 结果**（`audio.py` 的 `result.text`／`segment.text`、`realtime_openai.py` 的 `event.text`）与 voice_quality 的比对文本，**从不作用于用户文档**。中文口语里「我买了一个苹果」的 `一个`→`1个` 恰恰是 ITN 该做的事。**用源码注释和设计文档当转写稿量 ITN，得到的全是假阳性。**记在这里是因为它与第 69 条那条「文档语料占比低不等于线上影响低」正好互为镜像：**文档语料根本不是转写稿，用它量转写归一同样会得出假阳性。**

**换对输入之后，真正的缺陷自己浮出来了**：

```
50万元   -> 5010000元        10亿元 -> 10100000000元
2万元    -> 210000元          5万美元 -> 510000美元
3万个    -> 310000个          30亿人  -> 30100000000人
```

`_UNIT_RE` 的后行断言是 `(?<![数几零一二两三四五六七八九十百千万亿])`——它挡住「紧跟在中文数字后开始匹配」，**但没挡住 ASCII 数字**。于是 `50万元` 里的 `万元` 单独匹配，`chinese_to_int("万")` 是 10000，`10000元` 直接拼在 `50` 后面。识别器把语音归一成阿拉伯数字时产生的正是这个形状，而 `20万台`／`1000公里` 一直原样保留、说明服务端的本意就是「已经写成数字的不再动」——**后行断言漏了 `0-9` 这一格。**

**这与 Swift 侧第 66 条修过的是同一个 bug**（`2万元` 被切成 `2` + `万元`，`chineseInteger("万")` 返回 0）。Swift 侧那次修的是 canonicalizer 与门禁，**服务端的正则一直没动**。

**影响面比本报告前 35 条都大**：它不在提词器的归一器里，而在**已上线服务路径**上——batch 与 realtime 的转写文本、以及建立在文本上的 `voice_quality` 比对，全部吃这份产物。数字错两个数量级，而 `withSemanticReview` 只把 block 打成 `.unresolved`，并不会因为「数字大了 100 倍」而报警。

**修法是后行断言补 `0-9`**，一个字符类。已写成数字的数不需要转换，这本来就是服务端既有的立场。

**诚实地说清楚暴露面证据有多弱**：本仓语料里触发该形状的只有 **7 行**，而这 7 行**全部是本报告与代码注释里描述这个 bug 的文字本身**（`2万元` 出现在第 66 条那节）。**语料对这条缺陷的暴露面零证据，不能拿它当依据。**论证只能靠结构性理由：识别器归一化后会产生这个形状；服务端自己的设计已经假定它存在（`20万台`／`1000公里` 从未被改写）。**这一条要交给真实转写语料去验，本轮没有。**

**变异 4 条全部被杀**：T1 撤回 `0-9`（新回归红）、T2 把范围写成 `[0-8]`（新回归红——**所以 `9亿元`／`7万吨`／`8千万个` 三条是后补的**，前三条用例都从 1、2、3、5、10、30 起头，漏掉 7 和 9）、T3 去掉 `几`（既有 `数十/几十` 回归红）、T4 去掉 `数`（同）。

### 2.35 第五十轮：单位表差集量完了，结论是**对提词器无效**（无新缺陷，两条排除）

上一轮结尾留了一个开放问题：服务端 `_UNIT_RE` 的 16 项是 `TeleprompterCanonicalizer.unitSuffixes` 27 项的严格子集，差 `份/公斤/千克/厘米/吨/小时/年/毫升/毫秒/毫米` 11 项，服务端对中文数字形式的这些单位完全不动，而 Swift 会读成阿拉伯数字。**当时写着「目前未发现后果，但尚未在真实转写语料上验证」。这一轮把它量完了。**

**排除一：单位表差集对提词器对称无效，不是缺陷。** 理由是两侧都过 Swift 的归一器——`TeleprompterAligner.locate` 对转写走 `TeleprompterCanonicalizer.values(transcript)`，`Script.tokens(forSegmentAt:)` 对脚本走 `TeleprompterCanonicalizer.units(segment.text)`，**是同一张 27 项表**。于是 `三十公斤` 在脚本侧与转写侧都读成 `30公斤`，`3公斤` 两侧都原样，**服务端那 16 项在这条路径上根本不参与判断**。差集只在「服务端产物被直接消费」时才有后果，而提词器不是那种消费者。

**排除二：`voice_quality` 的数字映射表不认量级，是真缺陷但不在本交付范围内。** `normalize_transcript_for_match` 在 `apply_light_itn` 之后还叠了一层 `_TRANSCRIPT_DIGIT_TRANSLATION`，那张表只映射 `零一二三四五六七八九两` **十个数字字符**、不映射 `十百千万亿`。于是裸量级被逐字半成品化：

```
三十      -> 3十        三十公斤 -> 3十公斤      一万 -> 1万
十五      -> 十5        二十小时 -> 2十小时      一亿 -> 1亿
```

后果实测：`transcript_match_score("30公斤", "三十公斤")` = **0.7500**，低于门禁阈值 0.98 → 判 `TRANSCRIPT_MISMATCH`。**两侧形式不一致且数字带量级时才成立**：`30元` vs `三十元` 得 1.0（服务端认得的单位已被 `apply_light_itn` 转掉），`3、6、9` vs `三六九` 也得 1.0（位读法是那张表的设计意图，既有测试 `test_transcript_match_normalizes_itn_punctuation_and_case` 钉住）。所以这张表**确实在干活**，只是遇到量级就断。**这与第 65/67/70/73/76 条同族——同一个概念在几处各写一遍，没有一处负责说「这就是全部」**：归一这件事在 `apply_light_itn`、`_TRANSCRIPT_DIGIT_TRANSLATION`、Swift 的 `chineseInteger` 三处各有一份，其中一份不完整。

**但不计入本报告的缺陷编号。** 判据是「落在已关闭 issue 的交付范围内」：`normalize_transcript_for_match`／`transcript_match_score` 的调用点只有 `routes/voice_designs.py`（751／1098／1417）与 `routes/system.py`（876），**提词器 Swift 侧一次都没调用**，它对带量级的数字有自己的 `chineseInteger` 且处理正确。这条缺陷属于音色设计验证路径，**把它算成第 77 条会让「36 个」这个数字失真**。留给接手方的事实是：这一族还有一处漏网，且它就在 `apply_light_itn` 隔壁——**修第 67／76 条时顺手看一眼那个文件是值得的，但它的修法需要真正的中文数词语法**（`万` 与 `万一`／`一下`、`十` 与 `十足`／`十分` 必须区分），而这类语法正是本报告第 67 条论证过「不能靠枚举硬凑」的东西。**本轮没有动它。**

**本轮零新缺陷，两条排除。** 这也回答了上一轮结尾那个问题：单位表差集不用再查第二遍。

### 2.36 第五十一轮：报告里有两个替换字符，而自检那一栏写着「全绿」（第 77 条）

这一轮的前半段是两条排除（§2.35，零新缺陷）。后半段是自检时撞见的，**而且撞见的方式本身就是缺陷**。

例行查替换字符时，本报告里命中 **2 个 U+FFFD**，在 §2.33 的判断依据第一行——`依据三条，第` 的那个 `第` 字坏成了两个替换字符（写成 `依据三条，<U+FFFD><U+FFFD>一条`）。`git log -S` 定位到引入者是 **`1258eb03`，也就是第 75 条那次提交，本会话自己写的**。那一轮的收尾动作是「跑门禁 → 全绿 → 提交」，而门禁明细里明明白白有一行：

> 文档自检（替换字符／表格列数／标识可解析） | 全绿

**这一行是不成立的。** 仓库里没有任何检查替换字符的工具或测试——`grep -rn "fffd\|FFFD\|替换字符" tools/ tests/` 命中的全是 `replacement` 这个英文词的无关用法。**「文档自检」从来只是一次手动 `grep`，没有落成可重跑的产物**，而它的结论「全绿」被写进了交付证据表，和 pytest／ruff／mypy 并列。这与第 59 条（证据文件本身从不被断言）、第 60 条（生成证据的工具没有对应那道闸门）同族，也与 §5 第 10 条记的那个「探针只在 `/tmp`、接手方拿不到」是同一个根：**证据可以是一次性的，但报告把它写成了可复现的门禁。** 更糟的是这次连一次性都没做对——第 75 条提交时那一行的三个字符里就有两个是坏的。

**顺带量出两处既有结构缺口，同一个根**（都不是本轮造成，但它们进一步说明「文档自检」那一栏不可能真的跑过）：**其一**，§4.3 那张表在基线里只有第 41–67 条，**第 68／69／70 条从未进过这张表**（它们各自写在 §2 的分节里），表里没有、而正文声称「37 个真缺陷」——**数表的人会数出 34**；**其二**，第 71–76 条的表格行在基线里被追加到了 `## 6. 回退` 那一节里，**§4.3 的表实际停在第 67 条**。本轮把 71–77 七行搬回 §4.3（顺带把本轮新增的 77 行也放对），**但 68–70 的缺口只记录不补**——补它要从 §2 各节里重新组织三行，属于编辑工作而不是修缺陷，**留给接手方**，按 §5 第 10 条的同一判断不擅自扩大。另记：第 71 条那一行本身有 5 个竖线（3 列表格该是 4 个），**在基线里就是这样**，同样只记录不修。

**修法三件。** 其一，把 `第` 修回来——本报告现在替换字符为 0。
其二，**新增 `scripts/check_teleprompter_report.py`，把这一栏变成真的门禁**：
它检查替换字符、表格未转义竖线、页首计数与自身区间是否自洽，并且
**每个检查器先拿自己的坏夹具证明自己不是空转**——任一检查器对自己的夹具不报，
就 exit 2 且**拒绝解读报告**。
**这正是本条形态的正面写法**：一个永远返回「ok」的检查器比没有检查器更坏，
所以「检查器自己会不会失败」必须和「报告有没有问题」一起被断言。
其三，证据表那一栏指向它，并写明覆盖边界。

**边界必须一起写出来，否则下一个接手方会以为它管得更多。**
**表格完整性现在归它管了，但那是后来的事**：写这个工具时 §4.3 缺第 68／69／70 条，
**而我当时的记法是错的**——写成「它们在 §2 各节里」，实际是 **69／70 两行错位在 `### 3.1 已执行`**，
**第 68 条则全仓一个表格行都没有**。已补齐（68 新写一行，69／70 搬回来），
**门禁也加上了「§4.3 的行数必须等于页首声称的数」这一条**，
**下次再少一行就会红**。教训与本条同源：**「我知道这里有个缺口」不等于「我知道缺口长什么样」**，
写下来之前应当先量。**它也不管标识可解析性**——§5 第 10 条记着第一版既漏报又误报，
**口径没备齐之前宁可不做**。新增仓库资产仅此一个脚本加一个测试文件。

**门禁不是一次写对的，这一点也得记下来**：第一次跑就 exit 2 了，因为「计数漂移」那个夹具
我写成了 `36 个 / 41–76 条`——**那两者其实自洽**（76-41+1=36），夹具根本没造出漂移，
于是检查器被自己的自检判为空转。**这就是自检的价值：它抓到的是我自己的错，不是报告的错。**
改成 `37 个 / 41–76 条` 后转绿。随后它立刻又抓出一处真实破损：
§2.30 那张变异表里 `元|个` 的竖线未转义，**在 GitHub 上会把一行渲染成两行**
——与本节记的两处结构缺口同源，同样只有真跑起来才看得见。原替换如下：把 `第` 修回来（本节落地时已修，本报告现在替换字符为 0）；**并把「文档自检」这一栏从证据表里撤下来**，直到它真的成为一条可重跑的门禁。理由是 §5 第 10 条已经写了同一个结论——三轮教训只写在报告里、工具没固化，接手方因此拿不到。**本轮仍未擅自新增 `tools/` 资产**（属新增仓库资产，需另行授权，与 §5 第 10 条的判断一致），但**先不再声称这一项通过了**：一个查不到出处的「全绿」比没有这一行更坏。

**「非空即通过」这个自检本身也太弱，本轮把它改了**：新加的表格完整性检查器，
自检时**第一次就通过了**——但它通过的理由是错的。那条夹具
`"### 4.3\n\n| 第 41 条 x | a | b |\n\n## 5.\n"` 里**根本没有页首那句声称**，
于是检查器走的是「找不到 claim」这条分支，照样返回非空；
自检只问「有没有触发」，于是**一个从未测到缺行的检查器被证明是活的**。
这与上面那个 `36 个 / 41–76 条` 的夹具是**同一个病**：自检证明的是「函数返回了东西」，
不是「它因为该有的理由返回了东西」。改法两条：每条夹具**自带它必须产出的消息**，
答非所问即视为空转；再给每个检查器配一条**干净夹具**，对正常文档必须无发现——
**永远触发的检查器和从不触发的检查器一样没用**，而后者至少还会被自检抓住。
两条一起上之后，`tests/test_teleprompter_report_check.py` 里也补了对应的两条回归
（答非所问、永远触发），确保这个失效模式本身也被钉住。

**改完当场用报告的基线版本验它不是空转**：把 `1f55e4a2` 那份报告（§4.3 缺 68／69／70）
喂进去，得到的正是 `4.3 table is missing conditions [68, 69, 70]`——**与本节记的那次破损逐条对上**；
当前报告则无输出。随后 5 条定向变异全部被杀，且每条都报出正确的死因：
整段返回空（空转）、整段返回同一条消息（永远触发）、整段返回另一条消息（答非所问）、
撤掉重复行检查、只数行数不看区间。**其中「撤掉重复行检查」这条是靠夹具抓到的，
不是靠读代码看出来的**——那一刻检查器还会在真实报告上给出 exit 0。

### 2.37 第五十二轮：注释里点名的回归从来不存在，而报告跟着引用了它（第 78 条）

**这一条是第 45 条的复发，但深了一层。** 第 45 条是台账里一条引用查无此条，
而这条是**代码注释里点名的回归从来不存在**，报告第 714 行又照抄了一遍。

`TeleprompterFollowControllerTests.swift` 里那条讲「向前越位」的注释写着：
既有回归钉住了远处短语不得向后拖（`rereadRollsBackOnlyWhenTheBackwardMatchIsStrong`）
与整句复述不得倒退（`distantFullSentenceCannotDragTheViewportBackwards`）。
**第二个名字在本文件里只出现在这条注释中，全仓 0 个 `@Test func` 与之同名。**

**先量清楚它属于哪一种，这决定严重性**：`git log --all -S'func distantFullSentenceCannotDragTheViewportBackwards'`
**返回空**——它不是被改过名的旧测试，而是**从来没有被定义过**。
真实的向后回归是 `rereadDoesNotRollBackAcrossDistantParagraphs`，
它的断言原文正是「远处整句复述不得把已确认位置拖回前面的段落」，与注释想说的完全对得上。
**所以覆盖没有丢，丢的是指针。** 按 §2.14 那一节的记法，
这条属于「证据缺位」而不是「能力缺失」——**但后果一样坏**：
接手方按注释或按报告去核，会发现「整句复述不得倒退」这条回归不存在，
于是合理地推断这一向没有覆盖，**而它其实有**。
一个让人以为缺了、其实不缺的东西，比一个明摆着缺的东西更难查。

**顺带记下这一轮量到的口径教训，这是第 77 条那句「口径没备齐之前宁可不做」的直接印证**：
我先写的判据是「注释里每个反引号 camelCase 名字都必须是本文件的 `@Test func`」，
**第一次跑就误报 4 条**——`eventIDs`、`localAdvanceTokenRadius`、
`provisionalMinimumMatches`、`retired` 是被测代码里的字段，不是测试引用。
**这与报告 §5 第 10 条记的「第一版只比对函数名，既漏报又误报」是同一次复发。**
收紧后的判据是：名字必须解析到**本文件的 `@Test func`**
**或被测源码里声明的标识符**——四个误报全部消失，只剩那一个真正悬空的。
**结论与报告一致：写这类检查器，口径本身就是交付物，比第一条结果更值钱。**

**修法**：注释与报告都指向真实的那条测试；
新增 `tests/test_teleprompter_swift_evidence_refs.py` 4 条回归，
其中一条按上面的收紧判据守住这个文件里每一个反引号名字都能解析，
另外两条把具体实例与「两个方向都有回归」钉住，**免得有人改名后注释又悄悄指空**。
### 2.38 第五十三轮：把第 78 条那一族扫完全部 Swift 测试文件（**零新缺陷**）

第 78 条是在**一个**文件里查出来的。既然这一族是「注释点名一条自己也不存在的回归」，
那只查一个文件就没有意义——**同一句话可能落在另外 13 个提词器测试文件里的任何一处**。
这一轮把同一判据扫到全部 **37 个** Swift 测试文件（`SpeechRailMacControlTests` 36 个 + `SpeechRailAppUITests`）。

**结论是零新缺陷**：唯一的真悬空就是第 78 条那一处，已修。
剩下的全部是**判据自身的误报**，逐类量过：

- **9 个是 Apple SDK 与 XCTest 的符号**（`AVAudioEngine`／`AsyncThrowingStream`／
  `URLProtocol`／`isHittable`／`hasSuffix`／`addTeardownBlock` 等）——它们不在本仓任何文件里，按定义解析不到；
- **22 个是 snake_case 的 manifest JSON 键**（`sample_count`／`dataset_revision`／`pitch_band` 等）
  ——那是 `teleprompter.replay.v1` 的线上字段，本来就不该在 Swift 源码里找；
- **1 个是外部工具**（`xcodebuild`）。

**这一轮真正的收获不是「没找到」，而是判据被逼着改了三版，每一版都是被自己的误报打回来的**：

1. **第一版只认「本文件的 `@Test func`」**——误报 4 条控制器字段；
2. **第二版加上「被测源码里的标识符」**——4 条消失，却又把
   `gateAcceptsWhitespaceOnlyChangesAroundAUnit` 报成悬空，**而它确实存在**，
   只是在**另一个测试文件**里（`TeleprompterPreparationPromptsTests.swift`）——
   测试文件当然可以引用兄弟文件的回归，这一版把范围收得太窄；
3. **第三版再放宽到「整个测试 target 的 `@Test func`」**，并补上 snake_case 排除；
   同时发现我前两版**都漏了类型声明关键字**（`struct`／`class`／`enum`／`actor`），
   于是 `TeleprompterCanonicalizer`、`TeleprompterV2Store`、`AssistantSession` 全被误报——
   而且**只扫了 `SpeechRailApp/` 一个模块**，漏了 `SpeechRailControlKit/`，`SafeVoiceEntry` 因此也误报。

**这三次改动的方向和 §5 第 10 条记的那次完全一致：每一次都是先误报、再放宽。**
报告在那里写下的结论在这里得到了第二次印证——**口径本身就是交付物，比第一条结果更值钱**；
而**判据最终只敢覆盖提词器那 14 个测试文件**，其余 25 个明确不覆盖，
**因为要覆盖它们就得放进一张宽到足以藏住真问题的白名单。** 边界写进测试的 docstring，不留给记忆。

**留下的守卫**：`tests/test_teleprompter_swift_evidence_refs.py` 从守 1 个文件扩到守 14 个，
白名单只收 2 个名字（`hasSuffix`、`xcodebuild`）并注明理由；
另有一条断言专门盯住**范围本身**（`len(SCOPED) >= 14`），
**免得以后新增提词器测试文件时这条守卫悄悄只覆盖老的那批**——这正是第 45 条与第 78 条反复示范的那一课。
### 2.39 第五十五轮：把 Swift 侧变异探针落成仓库资产，并用它找出 3 个新缺陷（第 79–81 条）

§5 第 10 条记了三轮变异教训，探针却一直只在 `/tmp`。本轮把它落成
`scripts/swift_mutation_probe.py`（探针本体）、`scripts/teleprompter_swift_mutations.json`（变异集）
与 `tests/test_swift_mutation_probe.py`（探针自身的回归）。
**这不是「把结论搬进仓库」，而是把方法搬进仓库**——结论会过期，方法不会。

**那三条教训各做成了一条规则，并逐条用变异证明它会咬人**（自检夹具 + 3 条定向变异，全被杀）：

- **只认一种框架的失败标记**：swift-testing 报 `✘ Test … failed`，XCTest 报
  `Test Case '…' failed`。`classify` 两种都数，夹具专门钉住「只有 XCTest 失败」这一种。
  探针的通过条数同样两种都数——**一个只跑一种框架的过滤器会因此显形，而不是变成假存活**。
- **编译不过的变异不算杀死**：注释吞掉后面的 guard 是本项目真实踩过的坑。每条变异先
  `swift build --build-tests`，编译失败记 INVALID，**永不计入杀数**。
- **探针没跑起来会把全部变异假报成杀死**（第 33 条：pytest 压根没装，每次 module not found 非零退出，
  六个变异「全杀」）：基线必须绿**且必须真的跑到测试**，spec 里另有一条 `sanity` 变异必须被杀，
  任何一条不成立就 exit 2 拒绝解读全部结果。
- **本轮加的第四条**：存活必须能声明查因结论（`expect` + `rationale`），**声明与实测不符即 exit 1**——
  否则「已查因」这句话会在覆盖变好之后悄悄过期。

**探针从不用 `git checkout` 还原**：按内存里的原始字节写回，再比对 `git status` 前后是否一致，
不一致就报「有并行改动」而不是默默回退。项目规则禁止用 `git checkout --` 清除改动，探针同样不能。

**过滤范围本身就是结论的一部分，这是本轮最该记的一条**：M3（预算比 0.95 放到 1.0）在只跑
`TeleprompterTimingPolicyTests`（7 项）时**存活**，换全量 712 项后**被杀 3 条**。
照窄过滤记录，就会把一条真覆盖写成缺口——而缺口比覆盖更容易被当真。
因此 spec 默认 `filter: ""`（全量），并把这条写进 M3 的查因栏。
**一个存活的变异，在查清它为什么存活之前，什么都不证明。**

**5 条变异的结果**：M0（sanity）被杀，M2／M3／M4／M5 被杀，M1 存活但**语义等价**——
唯一的读取点是下一行的 `prefix(n)`，而 `n` 大于集合长度时 `prefix` 返回整个集合，两侧拿到同一段字符串；
该字段也不出仓、不落盘、不进评测证据。按第 27／33 条的规矩作废，不计入存活。

**探针本身也带门禁**：`tests/test_swift_mutation_probe.py` 6 项，含「每条锚点在源码里仍恰好命中一次」
——重构让锚点变歧义时，失败会发生在改代码的那一刻，而不是谁第一次跑探针时。

### 2.40 第五十五轮逐条：第 79–81 条

**第 79 条　报告自己把 XCTest 计数从 389「更正」成 171，而 389 恰恰是可复现的那一个。**
报告 §3.1 写着「**更正**：本节此前写的『XCTest 389 项』无法复现，实测为 171 项」。
本轮全量实测：`Executed 389 tests, with 0 failures` 稳定复现，171 复现不出来。
swift-testing 是 `Test run with 322 tests in 16 suites`（本轮补 2 条后 324），
324 + 389 = 713，与探针数到的通过条数逐条对上。**一条「更正」把正确的数字改成了错的**——
与第 77 条同族：**一个复现不出来的更正，比没有更正更坏**，它让下一个接手方连"该信哪个"都要重新判断一遍。
根因与第 77 条完全一致：**凭印象改数字，没有当场复跑**。**已改回 389，并同时记下 171 从何而来都无法确认。**

**第 80 条　试读建议时长有两个事实源，其中一个是死的。**
`suggestedTrialDurationSeconds = 60` 自 `6b752f5b`（timing core）引入后**全仓无人读取**——
`rg suggestedTrial` 只命中声明本身；而 sheet 里显示的「建议 60–90 秒」是**另一处硬编码字面量**。
变异 M5 把它改成 30，**全量 712 项无人变红**：两者从来没有连在一起。
方案 `2026-09-20-ai-teleprompter-final-spec.md:575` 写的是 60–90 秒，**区间来自方案，实现只留了下界**。
**修法（治本）**：常量换成 `suggestedTrialDurationRange: ClosedRange<TimeInterval> = 60...90`，
文案由 `trialGuidanceText` 生成、sheet 引用它，两者此后不可能再漂移；补一条回归钉住文案。
用户看到的文字不变（仍是「建议 60–90 秒」），变的只是它不再被复制了两份。

**第 81 条　校准倍率区间外的取值没有任何回归。**
M4 把下界 `minimumCalibrationFactor` 从 0.5 放到 0.0，**全量 712 项无人变红**：
`estimateDuration` 里那句 `min(max(calibrationFactor, minimumCalibrationFactor), maximumCalibrationFactor)`
从来没有被喂过区间外的值。倍率来自试读实测，异常值必须夹住。
**补的回归钉的是夹取后算出的秒数**（220 汉字自然档 ⇒ 基准 60 秒 ⇒ 下界 30 秒、上界 120 秒），
**不是「夹取后等于边界值」**——后者在边界本身被改动时两边一起动，永远成立。
本轮同时记录一处**同形的自指写法但不算缺陷**：`TeleprompterV2Store` 校验持久化 bundle 时用
`timing.budgetSeconds - timing.targetSeconds * TeleprompterTimingPolicy.budgetRatio`，
而 `budgetSeconds` 正是同一个常量算出来的，**该守卫只有在上一个版本写下的 bundle 上才可能触发**，
本轮没有找到喂这种 bundle 的用例。**不列缺陷**——防御性校验持久化数据本身是合理的，
只是**从未被执行过**，按证据纪律记为未验证而非记为缺陷。
（`budgetRatio` 本身是有真覆盖的：`TeleprompterPreparationDomainTests` 用硬编码的 `1_140` 钉住它，
所以 M3 死得正当。）


### 2.41 第五十六轮：探针铺到验收标准最看重的两条上，又找出 1 个缺陷和 3 处零覆盖（第 82–83 条）

上一轮探针只跑了两个文件、一个常量族。本轮按**验收标准本身**选题：第 1 条（稿件可信）
与第 2 条（跟随可控），因为「远距误跳」「稳定证据丢失」「数值保真」都在这两条里。
变异集从 5 条扩到 **12 条**，全部声明预期结果，探针 exit 0。

**先说方法上值得留下的一条**：12 条里 5 条首轮存活，**每一条都要先查因再下结论**——
一个存活的变异，在查清它为什么存活之前什么都不证明。查因的结果分成三类，
**没有一类是"补个断言"就完事的**：

- **真缺陷（第 82 条）**：`两`。
- **真缺口，但缺陷在测试之外**：M7／M8／M10 三条存活的查因都是「从未被喂过那个值」，
  不是实现错了。已各补一条回归，探针复跑三条全杀。
- **有条件等价，按规矩作废**：M11。

### 2.42 第五十六轮逐条：第 82–83 条

**第 82 条　两张中文数字表已经分叉，对齐器那张少了「两」。**
`TeleprompterAligner` 有一份自己的 `digits` 表，`TeleprompterCanonicalizer` 有一份
`chineseDigits`。**后者有 `"两": "2"`，前者没有**——第 70 条「两条数字规则各维护一张单位表
且已分叉」在**数字表**上原样重演，而当年修的只有单位表。
关键一步是**证明它可达**：裸中文数字在归一化里只有「数字 + 已登记单位」才转写，
所以 `两难`、`这里是两`、`第三季度` 里的数字**原样活到对齐器**（实测：
`两难` → `["两","难"]`，`第三季度` → `["第","三","季","度"]`），
那张表正是它们与阿拉伯数字唯一的等价来源。实测 `这里是2难` 对上 `这里是两难` 原来只有
**置信 0.8**（五个 token 错一个），补上「两」后才是 1.0。
**修法按第 70 条的结论来**：不是把「两」补进第二张表，而是**删掉第二张表**，
`equivalent` 改用 `TeleprompterCanonicalizer.chineseDigits`——**两张表在结构上不可能再分叉**。
补三条回归：裸中文数字对上阿拉伯数字、裸「两」对上 2、**反向的「七」不得与「8」等价**
（少了反向那条，把「七」映成 8 仍会显得无害）。变异 M9（把「七」映成 8）与
M12（拿掉「两」）现在分别被杀 7 条与 18 条。

**第 83 条　共享 realtime 契约测试里有一处 teardown 竞态，让「全量 pytest 全绿」这条证据不可靠。**
本轮跑全量时 `test_openai_append_commit_produces_transcription_completed` 失败一次
（`assert len(factory.released) == 1` 实得 0），**单独复跑 5 次全过**，下一次全量又全绿——
1/2 的间歇率，与行为变更无关。原因是会话释放在应用侧任务里完成，
而断言紧跟在 `with` 退出之后，**偶发早于释放完成**。
**这个文件里早就有一个带 deadline 的等待写法**（只在一处用着），其余四处是立即断言。
已把那四处统一到同一个 `_wait_for_releases` 助手上。**修复后连跑 5 次全量 2728 项 0 失败**，
但**必须说清楚：1/2 的间歇率本来就无法用 5 次全绿证伪**，这里只做到了「诊断与修法一致、
不再复现」，不宣称已证明根因唯一。


### 2.43 第五十七轮：按目标自己的优先级选题，四个新变异全被杀（**零新缺陷**）

前两轮探针选题的依据是「验收标准第 1、2 条」。本轮换依据：**目标句里点名的四个优先项**
——「数值保真、远距误跳、稳定证据丢失、**评测探针失真**」。前三项上一轮已覆盖，
**「评测探针失真」这一项的变异覆盖此前是零**：`TeleprompterReplayEvaluator` 的两个阈值常量
和读法别名的数值门禁，从没有人在可复跑的探针下动过它们。

新增 4 条（变异集 12 → 16），全部声明预期，探针 exit 0、16 条声明与实测一致：

| 变异 | 处置 | 被杀条数 |
| --- | --- | --- |
| M13 停滞阈值 3 秒放宽到 30 秒 | KILLED | 24 |
| M14 失败分母阈值 0.05 放宽到 0.5 | KILLED | 6 |
| M15 数值指纹只留长度不留数值 | KILLED | 14 |
| M16 别名接受比当前更新的规则版本 | KILLED | 3 |

**M15 值得单独说一句**：它把 `numericFingerprint` 的 `.map(\.value)` 换成 `.map { _ in "" }`，
于是 `50 瓦` 与 `500 千瓦` 的指纹都是同长度的空串列表、判成一致——**读法别名通道上的
数值门禁就此彻底失效**，而这正是第 1 条「数值变化不得静默通过」在别名路径上的落点。
它此前**从未被变异验证过**：`numericValuesDiffer` 有 4 处用例，但那些用例只证明
「这个拒绝分支会触发」，不证明**「把整个指纹掏空也还会触发」**。本轮补上这条之后才敢说
这一道门是被守住的，而不是碰巧有人写过用例。

**「零新缺陷」这三个字要按它本来的意思读**：它说的是**这 4 条选定变异全部被杀**，
不是「这一片没有缺陷」。覆盖边界必须一起写出来，否则下一个接手方会把它当成
「评测器与别名门禁已全面验证」——而本轮只动了 2 个文件里的 4 个点。
**远距误跳与稳定证据丢失**这两项上一轮各只跑了个位数的变异，同样不足以支持任何
「已全面验证」的说法。真正支持那句话的，是把这两个文件的常量与门槛逐个过一遍，
本轮没做，也不假装做过。


### 2.44 第五十八轮：把 `TeleprompterFollowPolicy` 的六个阈值与三道守卫逐个变异（**零新缺陷，三处真缺口**）

前四轮 Swift 侧探针的选题都落在 `TeleprompterReplayEvaluator`（评测器）与读法别名门禁上，
而**真正决定提词器跟随行为的 `TeleprompterFollowPolicy` 本身，此前从未被变异过**。
本轮改按目标句点名的优先项选题：验收第 1 条的「远距误跳」、验收第 2 条的「切稿后旧事件不能推进」，
以及「稳定证据丢失」——把该结构体六个阈值常量与三道守卫逐个过一遍。

新增 12 条（变异集 16 → 28），全部声明预期，探针 exit 0、28 条声明与实测一致：

| 变异 | 处置 | 被杀条数 | 查因结论 |
| --- | --- | --- | --- |
| M17 局部推进半径 24 放大到 240 | KILLED | 9 | 远距误跳闸门被守住 |
| M18 暂定推进置信度 0.72 降到 0.3 | SURVIVED | 0 | **真缺口，本轮未修**（见下） |
| M19 暂定推进命中数 2 降到 1 | KILLED | 4 | 暂定推进的命中数下限被守住 |
| M20 重定位命中数 4 降到 1 | SURVIVED | 0 | **真缺口，本轮未修**（见下） |
| M21 连续未命中 2 次进入自由发挥降到 1 次 | KILLED | 5 | 自由发挥的进入时机被守住 |
| M22 歧义判定余量 0.12 归零 | SURVIVED | 0 | **真缺口，本轮未修**（见下） |
| M23 去掉局部推进半径的 320 上限夹取 | SURVIVED | 0 | **生产不可达的纵深防御**（见下） |
| M24 重复事件由「拒绝」改为「放行」 | KILLED | 6 | 一次重发不得二次推进 |
| M25 切稿后不重置对齐状态（比较方向翻转） | KILLED | 3 | **验收第 2 条的直接落点** |
| M26 列宽扫描不再校验逐段长度表是否齐全 | INVALID | — | 去掉这道守卫会让整个测试进程 trap 中断（见下） |
| M27 时钟回退守卫只留队列年龄、丢掉匹配年龄 | KILLED | 4 | **「稳定证据丢失」的直接落点** |
| M28 暂定推进命中数不再兜底下界 1 | SURVIVED | 0 | **生产不可达的纵深防御**（见下） |

**M25 与 M27 是本轮唯二落到验收标准上的两条，各自补了一条回归**：
`anEventFromThePreviousScriptCannotAdvanceAfterTheScriptChanges` 与
`aRolledBackMatchClockIsNotRecordedAsALatencySample`。两条都写在
`TeleprompterFollowControllerTests`，此前**没有任何用例钉住这两道守卫**——
也就是说这两条验收项目前只有「代码里写着」这一层证据，没有「改错了会红」这一层。

**M26 值得单列，因为它暴露的是探针的分类规则不够用**：去掉
`segmentUTF16Lengths.count >= segmentCount` 这道守卫之后，失败形态**不是某条断言变红**，
而是 Swift 越界 trap 让整个测试进程在几百项处**直接崩掉**。探针拒绝把这种崩溃记成
「被杀」是对的——那会虚增杀数。因此本轮给探针加了 `unexplained_invalid()`：
**事先声明过的 INVALID 不再让整轮失败，没声明的仍然 exit 1**。回归
`tests/test_swift_mutation_probe.py` 同步补 2 条把它钉住。

**三条如实标为「真缺口，本轮未修」，它们不是缺陷，是证据缺口**：

- **M18**（`provisionalMinimumConfidence` 0.72 → 0.3 无人变红）：与上一轮 M8 同族。
  既有用例里没有落在 (0.3, 0.72) 区间的**暂定推进**材料，要补得先造一份这样的素材。
- **M20**（`relocalizationMinimumMatches` 4 → 1 无人变红）：重定位只在**自由发挥态**可达，
  而既有用例进不去那个状态，因此这个阈值改动后无人能观察。
- **M22**（`reanchorMargin` 0.12 → 0.0 无人变红）：现有素材里**没有真正歧义的两条候选**，
  余量归零与归零之外不可区分。

这三条**不能编造夹具去凑绿**——第 43 条与第 61 条都是这么栽的。
按第 79 条与 b84706dc 的教训，**「造不出触发条件」要如实写成缺口，不能写成「已验证」**。
三条已登记为 §5 第 13 条的交接事项。

> **第六十一轮更新**：M20 与 M22 已各自补回归并确认能杀（各 4 条变红），
> M18 改判**等价变异**——它的可达性被代码路径穷举掉，不是素材不够。
> 三条的现状与代价见 §2.47 与 §5 第 13 条。

**M23 与 M28 判为生产不可达的纵深防御**，判据是实测而非推理：
全仓**没有任何生产代码带参构造** `TeleprompterFollowPolicy`，永远走 `init` 的字面量默认值，
因此把默认值改成 0 或去掉 `max(1, …)` 之类的夹取，在产品路径上不可观测。
它们仍留在变异集里并带声明，作为「若将来开放带参构造，这些夹取必须还在」的守门。

**本轮零新缺陷，这句话要按它本来的意思读**：说的是**这 12 条选定变异没有暴露出实现与声明不符**，
**不等于**「跟随控制器已全面验证」。边界写清楚：本轮只动了 `TeleprompterFollowPolicy`
 一个结构体的六个阈值与三道守卫，**没有触及**匹配算法本身、素材侧对齐器、
以及前四轮已覆盖的评测器与别名通道。§2.43 记的「远距误跳与稳定证据丢失各只跑了个位数变异」
在本轮补齐到 9 条与 4 条被杀，但**离「全面」仍然很远**。


### 2.45 第五十九轮：把 Swift 侧的**保护字面量闸门与分组区间守卫**纳入变异（找出 4 处零覆盖，并修了探针自己两处）

前四轮 Swift 侧探针打的都是 `TeleprompterReplayEvaluator`（评测器）与读法别名门禁。
本轮先量了变异集的文件分布，发现一个此前没人提过的缺口：
**`TeleprompterPreparationPrompts.swift`——也就是 AI 整理／有损精简／读法标注的输出校验层——在 Swift 侧一条变异都没有**，
而它承载的正是验收第 1 条「数值、单位、正负号及重复内容变化不得静默通过」在 App 端的落点。
（Python 侧同一族门禁此前被变异过，见 §3.1 的第十轮与第十二轮；**两侧是各自独立的实现，覆盖不能互相代替**。）

新增 11 条（变异集 28 → 39）：

| 变异 | 首轮 | 处置 | 被杀条数 | 查因结论 |
| --- | --- | --- | --- | --- |
| M29 候选稿把含保护字面量的整段删空时不再报差异 | KILLED | KILLED | 5 | 验收第 1 条：整段删除必须报出 |
| M30 保护字面量按集合比较，重复次数被折叠 | KILLED | KILLED | 5 | 验收第 1 条明写「重复内容」；既有 `droppedOccurrence` 用例（`50 50` → `50`）钉住 |
| M31 Unicode 负号不再归一 | KILLED | KILLED | 2 | 验收第 1 条点名「正负号」 |
| M32 数字与单位之间的空格不再丢弃 | KILLED | KILLED | 7 | 纯排版改写不得被误判成数值变化 |
| M33 去掉重叠抑制 | INVALID | KILLED | 7 | **首轮的 INVALID 是我自己的变异写错了**（`{ false }` 无法推断单参闭包），不是产品发现；改成 `< 0` 写法后被杀 |
| M34 原子值不再剥离句尾标点 | **SURVIVED** | KILLED | 4 | 零覆盖，已补回归 |
| M35 分组区间只查重叠、不查缺口 | **SURVIVED** | KILLED | 2 | 零覆盖，已补回归，**这条最要紧**（见下） |
| M36 分组区间不再校验上界 | **SURVIVED** | KILLED | 3 | 零覆盖，已补回归 |
| M37 单组分片数上限形同虚设 | **SURVIVED** | KILLED | 2 | 零覆盖，已补回归 |
| M38 接受一个不认识的 grouping schema 版本 | INVALID | INVALID | — | 崩溃类 INVALID，见下 |
| M39 源分片 id 的连续性不再校验 | SURVIVED | SURVIVED | 0 | 生产不可达的纵深防御，但**它的读数一开始是假的**，见下 |

**M35 是本轮最实的一条**。既有测试里确实有 `.rangeGap` 用例，但它用的是
`groups: [{0,1},{2,3}]`——末尾总覆盖兜底（`next == targets.count`）会把这条接住，
**循环内那道守卫从未被走到**。而 `groups: [{0,1},{2,4}]` 这种「后面补齐总数」的缺口，
去掉 `== next` 之后会被**静默接受**：总数对得上，unit 1 却不在任何一组里，
被跳过的段落会原样保留却仍被算进改写结果。已补
`aGapThatALaterGroupCompensatesForIsRejectedWithItsOwnBlockIndex`，
它断言的不只是诊断码，还要求 `fieldPath == "groups[1].start_unit"`——
即证明**是循环内那道守卫报的**，而不是末尾兜底。

**M34 的回归我先写错了，值得记**：第一版拿「50 瓦。」写用例，结果在变异下依然全绿。
查下去才发现**数字 pattern 的结尾 lookahead 使它从不越过标点**，剥离对数字本就是空操作；
真正会吞掉标点的是 URL pattern（`[^\s]+`）。改用 URL 后变异被杀 4 条。
**这条正是「回归没钉住东西」的典型形态**：用例存在、断言存在、但它证明的不是你以为的那件事。

**M38 让探针自己的分类理由露了馅**。它确实该判 INVALID（测试进程在 490／722 项处
`Fatal error: Index out of range` 中断），但首轮记的理由是「does not compile」——
崩溃报告行里 `error: Process '...' exited with unexpected signal code 5` 被
`_COMPILE_ERROR` 正则命中了。**结论对、理由错**，而理由恰恰是读者判断
「被删掉的那道守卫到底有没有被走到」的依据。已给 `classify()` 加 `_TEST_CRASH`
并排在编译规则之前，配 2 条夹具 + 2 条回归：崩溃必须报成崩溃，
而失败信息里恰好含 `error: ` 的**真击杀不许降级**（否则真击杀被静默丢掉）。

**M39 逼出了本轮最不好写的一条**：全量探针 5 次里 3 次报 KILLED，隔离跑 6/6 全绿、
干净树 5/5 全绿、8 倍 CPU 负载下全量 6/6 全绿。逐条抓失败用例名之后，凶手是
**`observationRecorderPersistsEventsAndAggregatesLowCardinalityMetrics`**——
它报的断言是 `eventText.split(separator: "\n").count == 4` 实测 **5 或 8**、
`metricLines.count == 1` 实测 **2**：一个全新 UUID 临时目录里的文件多出若干行，每次行数还不同。
它与提词器分组、源分片、本变异毫无关系，所以 M39 是存活。
**机制未确定**（只在紧跟会崩溃的 M38 之后出现），已登记为 §5 第 14 条的开放缺陷。

**由此得到一条对全部既往探针结果都成立的校准**：一个无关测试的间歇失败会把**存活读成击杀**，
这与第 33 条「探针没跑起来导致全部假报 KILLED」是镜像情形，而后者当年只修了「探针没跑起来」这一半。
可用的判据是：**失败数 ≥5 的击杀不能由单个 flaky 测试解释；失败数 1–4 的击杀需要复跑确认。**

**本轮还试了一条守则、按纪律撤掉了**：M39 曾报出「725 通过 + 3 失败」而基线只有 726，
看起来是自相矛盾的读数，于是加了 `impossible_tally()`，要求 `passed + failed` 不得超过基线。
**它第一条真实输入就判错了**——sanity 变异给出 725+6=731，基线 726，超出 5，而那是**合法的击杀**。
回头核对历史，sanity 一直是「721 通过 + 6 失败 / 基线 722」，同样超出 5：
这个偏移是计数口径本身带来的，**求和根本不是测试数的上界**。按「因正确理由通过」的纪律撤掉该规则，
改为在 `classify()` 的文档串里写明这一实测性质。**一条第一次就误判的规则比没有规则更糟。**

**覆盖边界照旧写清楚**：本轮只动了 `TeleprompterPreparationPrompts.swift` 的
保护字面量提取／比较与分组区间校验，**没有触及**素材侧对齐器、跟随控制器、
评测器与别名通道（那几处见 §2.43、§2.44）。「验收第 1 条已全面验证」这句话**仍然不成立**。


### 2.46 第六十轮：把第五十九轮那条**间歇失败**查到底，结论是**探针在给自己造假击杀**

上一轮把 `observationRecorderPersistsEventsAndAggregatesLowCardinalityMetrics` 记成开放缺陷（§5 第 14 条），
只写清了「它会让存活读成击杀」。本轮**只做这一件事**：查清它为什么会失败，以及失败是怎么变成假击杀的。

**先量「是不是它」，再量「什么时候发生」**。逐条抓失败用例名之后，事实很干净：

| 场景 | 结果 |
|---|---|
| 隔离跑该测试 20 次 | 0 失败 |
| 干净树全量 5 次 | 0 失败 |
| 8 倍 CPU 负载下全量 6 次 | 0 失败 |
| **紧跟在一条崩溃变异之后跑干净树** | **失败 1 次，4 条用例红** |
| 再往后的干净树连跑 2 次 | 0 失败 |

第四行是关键：**干净树、没有任何变异施加**，照样失败。所以它与 M39 无关——
第五十九轮那些「KILLED」从一开始就是假的。受害的只有那一条测试，
且**污染只持续一次运行**，第二次就自愈。

**机制在最后查清了，而且它推翻了前两轮对这条的定性**。旁路监听抓不到现场——
断言失败后 `defer` 立刻删目录，而带稳定判定的轮询要 90ms，窗口太短。
改用**临时诊断**（在断言前把文件内容落到固定路径，用完立即还原、`git status` 已核对干净），
dump 出来的内容里混着**两种不同 JSON 形状**：一部分带 `schemaVersion` 与 `component`、键序是当前实现，
另一部分两者都没有、键序也是旧的。**结论是崩溃打断了构建，下一次 `swift test` 链出的是新旧混合产物**，
旧对象里那个 `TeleprompterAIObservationRecorder` 写出的记录与当前结构不一致，于是多出整行。

这一条同时解释了当初所有想不通的地方：**全新的 `UUID()` 目录里也会有整行多余**（是同进程的陈旧对象写的，不是别的进程）、
**每次行数不同**（取决于哪些对象陈旧）、**隔离跑与干净构建永远通过**（产物一致）、**第二次运行自愈**（重编即一致）。
**所以它既不是产品缺陷，也不是那条测试的缺陷——测试本身是对的，§5 第 14 条据此作废。**
真正要记住的只有一条：**崩溃型失败之后先重跑一次再解读结果**，而这正是 `recover_after_crash()` 做的事。
**教训比结论更值钱**：前两轮之所以查不出来，是因为一直在问「谁往这个文件里多写了行」，
而正确的问题是「**这个文件是谁编译出来的**」。**产物一致性属于证据链的一部分，测试写得对不等于跑的是对的代码。**

**本轮真正的交付是修探针，而不是修那条测试**。探针此前只在开头校验一次基线，
于是把「崩溃跑之后那一次污染运行」当成了正常结果——这与第 33 条
「探针没跑起来，全部变异假报 KILLED」是同一类缺陷的另一半：**环境坏了 verdicts 照样照出**。
现已加上 `recover_after_crash()`：任何崩溃判决之后，必须先恢复到干净运行才允许继续解读——
第一次就干净则直接继续；脏则重跑一次，绿则放行并把残留写进记录；**连续两次脏则拒绝解读后续任何变异**（exit 2）。

**修完之后的端到端证据**（配对只跑 M38、M39 两条）：

```
[1/2] M38 ... INVALID: test process crashed after 26 failing (428 passed, 26 failed)
      -- the run right after the crash was KILLED (3 failing); re-running it gave a clean run
[2/2] M39 ... SURVIVED: all green (726 passed, 0 failed)
```

M39 随即给出它真实的读数。全量 39 条重跑 **exit 0**，29 杀 / 8 存活 / 2 INVALID，
运行中确实触发过一次崩溃后的恢复（`one-run residue`）。

**这一轮同时验证了第五十九轮的一个判断**：那一轮我在证据不足时选择声明 SURVIVED
并把矛盾原样记下来，而不是把 3/5 的 KILLED 写进声明。本轮证明那是唯一正确的读法。
**声明写「查因结论」而不是写「上一次跑到了什么」，这条纪律第一次直接救了结论。**

**顺带一条流程教训**：第五十九轮的提交把 CI 的 Ruff 门禁弄红了——
`recover_after_crash` 的三条回归里显式传了 `Path(".")`，触发 `PTH201`，
而我那轮最后跑的是 `swift test` 与文档门禁，**ruff 是在加这批测试之前跑的**。
本地 `ruff check .` 通过不等于提交时通过：**门禁要在最后一步跑**，
这与第 79 条「数字要么当场复跑，要么别动」是同一条纪律的两种形态。


### 2.47 第六十一轮：把 §5 第 13 条那三个阈值逐个查到底——**两个补回归，一个是等价变异**

上一轮把 `TeleprompterFollowPolicy` 六个阈值里的三个记成「真缺口，本轮未修」（M18／M20／M22），并写明「不能编造夹具去凑绿」。本轮把三条逐个查到底，结论是**两条真缺口、一条等价变异**，§5 第 13 条因此可以结掉。

**M20（`relocalizationMinimumMatches` 4 → 1）真缺口，已补。** 先查可达性，而不是先写测试：该阈值在 `mayAdvance()` 的**最后一行**才被读到，前提是「自由发挥态 + 远处匹配（`tokenDistance > 24`）+ 非 unique + 过了暂定门槛」。`lookAheadTokens` 默认 320、`lookBehindTokens` 80，所以远处匹配**找得到**——可达性没问题。问题在既有素材：两条自由发挥用例的重锚短语在脚本里**唯一**，于 `mayAdvance` 前两行（`isUniqueNearAnchor` / `isUniqueExactContinuation`）就短路了；`distantUniquePhraseCannotAdvanceThroughPartialOrFinal` 只匹配 1 个 token，在 `provisionalMinimumMatches` 就被拦下。**三条都没走到那一行**，所以阈值改错无人能观察。

新增 `freePlayReanchorsOnADistantPhraseOnlyWithEnoughEvidence`：素材 `甲×100。稳定性良好。乙×100。`，先用两条无关 transcript 逼进 `.freePlaying`，再用同一句话的**短版与长版**把阈值夹在中间——「稳定性」（3 token）**不推进**，「稳定性良好」（5 token）**推进**。后半句是关键：它证明前一条断言是关于**证据量**的，而不是关于「这个短语根本够不着」。降到 1 后 **4 条变红**。

**M22（`reanchorMargin` 0.12 → 0）真缺口，已补。** 该阈值只喂给对齐器的 `advanceMargin`，用在两处：歧义闸门（`best.confidence - competitor.confidence < advanceMargin` 则返回 `position: nil`）与 `uniqueNearAnchor` 的判定。要观察它，素材必须是**真正歧义的两条候选**。新增 `aPhraseWrittenTwiceIsNotAnUnambiguousAdvance`：同一句话在稿里出现两次，两次打分**完全相同**（cost 0、confidence 1.0），差值 `0 < 0.12` 于是走歧义分支、锚点不动。余量正是「不许凭一句重复的话把读者拽走」的唯一依据；归零后 `0 < 0` 不成立，tie-break 挑近的那次并推进。**4 条变红。** 这条用例同样带一个正向对照（一个只出现一次的短语确实会推进），否则「锚点不动」也可能只是控制器已经死了。

**M18（`provisionalMinimumConfidence` 0.72 → 0.3）不是缺口，是等价变异。** 这一条**不能靠补夹具解决**，因为补不出来——先把可达性穷举掉：

- `mayAdvance()` 里该阈值只以 `match.confidence >= policy.provisionalMinimumConfidence` 被读；
- 能走到这一行的 match，`position` 必然非 nil；而 `position` 非 nil 的 `Match` **只有一个来源**——`TeleprompterAligner.locate` 末尾那条 return；
- 那条 return 之前，`TeleprompterAligner.swift:217` 已经先做了 `guard let best = candidates.first, best.confidence >= configuration.minimumConfidence`；
- `Configuration.minimumConfidence` **全仓只有声明处与那一处读取，没有任何调用方传过别的值**（控制器传的是 `.init(advanceMargin: policy.reanchorMargin)`，另一处直接 `TeleprompterAligner()`），于是它恒为 0.72，与本阈值**相等**。

所以凡是能走到这个比较的 match，置信度必然 ≥ 0.72，把阈值放宽到 0.3 **不改变任何一次判定**。另一条提前返回（歧义分支）`position` 为 nil，`mayAdvance` 第一行就挡掉了。**这是代码路径穷举，不是样本不足**——按第 46 条的纪律，穷举结论要给出边界，而这里唯一会翻案的条件是「有人把 `Configuration.minimumConfidence` 调低」，那时本阈值会重新变成活阈值且依然零覆盖。

**代价要说清，不能只写「等价」就完**：这层判断目前是**死的**，而且它让弱匹配无法作为 `uncertainty` 暴露——对齐器在 0.72 以下直接返回 `none`（confidence 0），所以 `uncertainty` 只可能是 0 或 ≥ 0.72，界面上「大致对但不确定」这个中间态**从来没出现过**。要让阈值变成活的，得改对齐器的产出策略（让它把弱候选也吐出来，再由策略决定推不推进），那是产品行为变更，**本轮明确不做**，只在这里登记。

**本轮新增 2 条回归、3 条变异声明改写（M20／M22 改判 KILLED，M18 改判等价并附穷举理由），`swift test` 基线 726 → 728。**


### 2.48 第六十二轮：把变异覆盖扩到**分段器**——所有阅读位置的锚点来源，此前 0 条变异

前 61 轮的 39 条 Swift 变异集中在 7 个文件。`TeleprompterSegmenter.swift` 不在其中，尽管它比其中任何一个都靠上游：`Position(segmentIndex:utf16Offset:)` 全部由它产出的段与 UTF-16 区间推导，而跟随、手动接管、回放评估、导出都以它为锚。它 211 行、4 条专测，**此前一条变异都没有**。

**本轮结论：13 条变异，12 条被杀、1 条判为等价变异；找出第 84 条真缺陷。**

**第 84 条（新）：任何略超软上限的句子，都会在句末留下一个只含「。」的段。** 实测（源文为重复汉字加句号，只改长度）：

| 句子长度 | 61 | 62 | 63 | 70 | 121 | 200 | 500 |
|---|---|---|---|---|---|---|---|
| 分段 | 60 + **1** | 61 + **1** | 62 + **1** | 69 + **1** | 120 + **1** | 199 + **1** | 499 + **1** |

那个 `1` 永远是句号。机制：`boundedRanges` 先把 `end` 定在软上限 60，随后那道「不要切断英文单词」的循环在中文上不生效（见下），于是第一段正好停在句号前一个字符，句号成为余下的尾段。**后果是每个超长句子末尾都多出一个几乎空白的舞台行**，而且这个段在对齐器眼里永远匹配不上（canonicalizer 对「。」产出 0 个 token）。

**既有那条回归正好踩在这个缺陷上，却没看见它。** `testLongLatinIdentifierIsNotSplitAtTheSoftTarget` 的素材是 61 字——刚好越过软上限，**它产出的正是 [60, 1] 这组被孤立的段**，而断言只写了「标识符没被切断」。这是第 78 条（「注释里点名的回归从来不存在」）的同一次复发，形态更隐蔽：回归存在、名字正确、也真的绿了，**只是它断言的那件事与它脚下的缺陷无关**。本轮把素材换成真正跨过上限的 73 字版本，N4（去掉词内保护）随即被杀。

修法是尾段若不含文字数字就并回上一段；合并后段长会略微超过软上限，而那个上限的注释本来就写明「可能超出」。两条新变异守着修复本身的边界：N13 去掉合并（回到修复前）、N14 去掉「不含文字数字」这个前提（让合并吞掉有内容的尾段）。

**一次把声明写对、却把断言写错的复发（N10）**，值得单独记。我把「尾部空白不再裁掉」声明为 KILLED，首轮存活。查因不是素材不够，**是断言的方向错了**：我最初断言「段文本不含尾随空白」，而句级 `trimmedRange` 早就保证了这一条，断言恒真。真正的可观察后果在 `pauseHint`——段落末尾的空格会把段落真实末尾推后，`sectionEnds` 因此对不上，末句拿不到「长停顿」而被降级成「句间停顿」。**是空格而不是写作内容决定了读者看到什么标签。** 改断言为「加不加尾部空格，段文本与停顿提示都不变」后转杀。这与第 43 条「断言不等不等于断言了想要的那件事」是同一次复发，这次漏掉的是「**这个字段到底被谁读**」。

**一条机制与注释不符的，本轮按产品判断保留不修，只登记。** `isWordCharacter` 的判据是 `CharacterSet.letters`，**它包含汉字**，于是「不要切断英文单词或标识符」那个循环对中文同样生效——**60 字软上限对中文根本不生效**：500 字的中文句子被切成 1 段（499 字）加 1 段（句号）。这是实测结论，不是推断。方案 §5 对分段只承诺「不在数字＋单位、URL、代码标识符中间切断」，60 字是代码内部的软上限、注释明确写了「可能超出」，**改中文分段策略会改动每一篇长稿的段数、每一个阅读位置与回放素材的标注，属于产品行为变更，不在本轮授权内**。因此登记为 §5 第 15 条，附实测数据，交产品拍板。

**一条等价变异（N5）**：小数点守卫（`isDigit(previous) && isDigit(next)`）的结论被下一道完全覆盖——`isDigit` 的判据是 `decimalDigits`，`isWordCharacter` 的判据是 letters OR decimalDigits OR `_` OR `#`，前者恒蕴含后者。删掉它 733 项全绿。保留原样是为了让「小数不切开」的意图留在代码里。

**一处流程教训**：这次给探针挑 sanity 变异时，我先选了「撤掉 `boundedRanges` 的长度守卫」，探针**当场报它存活并拒绝解读全部结果**。查下来它确实是等价变异——那段 guard 只是短路优化，chunk 循环对不超过上限的 range 结果完全相同。**这是探针的基线自检第二次救下结论**（第一次是第 33 条「探针没跑起来全部假报 KILLED」）。

**本轮变异集 39 → 52 条，全量 exit 0：43 杀 / 7 存活 / 2 INVALID，基线 733。** `swift test` 由 728 增至 733（XCTest 389 → 394，Swift Testing 339 不变）。

### 2.49 第六十三轮：把变异覆盖扩到**AI 标注解码器**——找出第 85 条，以及本轮最要紧的一处零覆盖

继上一轮的分段器之后，本轮查两个同样 0 覆盖的文件。**先说好结论：一个是干净的负结果，一个产出了新缺陷。**

**`TeleprompterStageInteractionPolicy`（82 行，判据第 3 条键盘可达性的落点）：5 条变异全部被杀，零新缺陷、零缺口。** 这个文件是本分支里少见的「读起来覆盖、实测也覆盖」的例子：每个可见性原因各有一条断言、两个清除路径各有一条。最值得一提的是 P4——`voiceOverEnabled` 一旦摘掉，VoiceOver 用户**没有任何办法**把控件叫出来（他们没有指针悬停），而这条是判据第 3 条明写的无障碍子项。**把它测过一遍与没读过一遍，结论完全不同**，所以这 5 条也进了仓库 spec 锁住。

**`TeleprompterAnalysis`（212 行，AI 朗读提示的解码器）：13 条变异，10 条首轮被杀、3 条崩溃，4 条存活全部是真缺口。**

**第 85 条（新）：含长于 180 字单元的稿件，AI 朗读提示必然失败，而失败被报成「AI 失败」。** 这条是上一轮那个发现的下游后果——**两轮前量出来的「60 字软上限对中文不生效」，在这里变成了一个用户可见的失败**：

| 句子长度 | 120 | 180 | 181 | 300 | 500 |
|---|---|---|---|---|---|
| 解码 | 成功 | 成功 | **失败** | **失败** | **失败** |

解码器对每组标注校验 `text.count <= 180`，而 `text` 是从**模型拿到的单元**原样拼出来的。分段器在中文上不切长句（见 §2.48），于是 500 字的中文稿就是一个 499 字的单元，模型无论返回什么都超限——**这条路径对这样的稿件是不可满足的**。更糟的是错误类型：`analyze()` 抛出后 `TeleprompterSession` 走 `catch` 返回 `aiFailureMessage`，于是**模型返回完全合法的结果，界面却说 AI 失败了**，而读者无论重试多少次都不会成功。

修法：**这道上限是为了阻止模型把多个单元合并成一段，单个本来就超长的单元没有「合并」这回事**。因此只在该组恰好覆盖一个单元时豁免，并同步改提示词把这条规则告诉模型。合并本身仍受约束（新增一条反向用例：两个 120 字段落合成一组照样被拒）。

**本轮最要紧的一处零覆盖（A6），值得单列。** 解码器有一道 `annotation.match_phrases.isEmpty`——模型**不得**注入读法别名。为什么这条重要：`TeleprompterSession.swift:1562` 把 `annotation.matchPhrases` 直接写进已确认版本，而这些短语正是对齐器匹配时用的东西；方案 §5.6 写明读法别名只能由读者登记（「屏幕上写 A，我实际念 B」）、模型不得注入。**唯一执行这条产品规则的守卫，此前没有任何一条测试观察它。** 把它改成允许模型注入，736 项测试全绿。这不是「证据缺口」四个字能盖过去的东西——**它是一条产品边界当时只存在于代码里**。

另外三条零覆盖同源，值得记下它们是怎么被漏掉的：

- **A3（分组必须首尾相接）**：既有那条「漏单元」夹具把 `end_unit` 改成 3，**被越界检查先挡下了**，所以相接性本身从未被测到。`(0,1)` 后接 `(2,4)` 能同时满足上界与末尾覆盖，中间那个单元静默拿不到关键词与停顿提示。
- **A11（关键词须按出现顺序）**：推进 `lowerBound` 是这道检查成为「顺序检查」而不是「成员检查」的唯一原因，摘掉后模型可以返回任意顺序。
- **A1（顶层封闭对象）**：封闭对象在**单元层**有测试，在**顶层一条都没有**。

三条都补了回归，A11 那条还带一个顺序正确的正向对照——否则「被拒绝」可能只是因为别的理由。

**3 条崩溃型（INVALID）**：A4（分组不再要求非空）、A5（越界检查放宽一格）、A13（窗口切片与步长不一致）去掉守卫后都不是「某条断言变红」，而是 `units[...]` 越界 **Swift trap 让测试进程直接中断**（0 失败）。与 M26／M38 同族，如实记为 INVALID，不计入存活。

**本轮变异集 52 → 70 条，全量 exit 0：58 杀 / 7 存活 / 5 INVALID，基线 740**（Swift Testing 346/16 套件 + XCTest 394）。7 条存活全部是等价变异或生产不可达的纵深防御，逐条理由在 spec 的 `rationale` 里。

**跨午夜**：本轮收尾在 2026-09-30，文档编制日期仍为 2026-09-28，按此前惯例只在此注明续期，不把午夜后的改动记到前一天。

### 2.50 第六十四轮：把变异覆盖扩到**语音跟随生命周期状态机**——15 条变异 11 条存活，这是本分支覆盖最差的一个文件

前两轮分别补上分段器与 AI 标注解码器之后，本轮挑的是判据第 2 条「旧事件不能推进」与判据第 3 条真正落地的那个文件：`TeleprompterVoiceAssistLifecycle.swift`（148 行）。它此前**只有 4 条测试、0 条变异覆盖**。

**首轮结果：15 条变异，10 条存活。** 这个比例本身是本轮最重要的结论——**一个专门负责「迟到回调不许搬动状态」的纯状态机，此前没有任何一条变异测试**，而它恰好是全仓最容易被异步时序打穿的形状。存活不等于缺陷，但 2/3 的存活率说明这里读过的每一行都缺少钉子。

**第 86 条（新）：空的停止失败原因被记成停止成功。** `markStopped` 写的是 `if let failureReason, !failureReason.isEmpty`——一个空串的失败原因会走到「停止成功」分支，于是状态落到 `pendingStopDestination ?? .off`，**读者看到「已停止／麦克风已释放」，而设备可能根本没释放**。同一族的坑在隔壁：`.stopFailed` 的文案是固定字符串，真实原因从不显示，所以这里也没有「至少用户能看到原因」来兜底。修法是按可选本身判断（`if let failureReason`），并把「fail-closed 优先于信息完整」的理由写进注释——**这条注释是承重的，它说明为什么空串不能被当成成功**。本轮 7 条回归里有两条（`emptyStopFailureReasonIsNotRecordedAsSuccess`、`deviceErrorDuringStopKeepsTheStopInFlight`）就是钉这一处的。

**补完 7 条回归后复跑：11 杀 / 4 存活，基线 747。** 剩下 4 条逐个查因，结果**全部是等价变异**——但它们的等价性不是一眼可见的，理由都写在 spec 的 `rationale` 里：

| 变异 | 存活原因 |
|---|---|
| V7 `invalidateAfterFailure` 不再换代 | `generation` 唯一不带状态检查的消费者是 `TeleprompterSession.startPipeline` 的 4 处守卫，它们只在 `.starting` 窗口内运行；该窗口内 `startPump` 尚未执行，而 `enterManual`（`invalidateAfterFailure` 的唯一调用点）只能由 pump 的 `upload`／`handle` 触发，故不可达 |
| V8 `resetToOff` 不再换代 | 唯一调用点 `finishStageClose` 的前置 `requestVoiceStop` 在 `.starting` 下必经 `beginStop` 换代；状态本就是 `.off` 时无在途管线可复活 |
| V14 `beginStart` 不再清空待定目的地 | 两个读点分别被 `state == .stopping`（进入该态的唯一路径 `beginStop` 必先写入）与 `.stopFailed` 守卫，而从 `.stopFailed` 起 `canStart` 为 false，`beginStart` 不可达 |
| V16 停止成功后不再清空待定目的地 | 残留值不可被读到：唯一无状态守卫的写入口 `beginStop` 总覆写，其余四个转换点都清空 |

V7／V8 这两条要特别说明：**它们能被论证成等价，靠的是跨文件可达性，而不是本文件自身的结构**——`TeleprompterSession.swift` 有 2500 行，而「`.starting` 窗口内不存在 pump」这个前提没有自动化护栏。哪天有人在 `beginStart` 之后、`startPump` 之前插一个 `enterManual` 调用，这两条会同时静默存活。**这是本轮留下的最大一处结构性缺口，已按纪律登记，不靠「等价」二字把它消掉。**

**本轮变异集 70 → 85 条：69 杀 / 11 存活 / 5 INVALID，基线 747**（Swift Testing 353/16 套件 + XCTest 394）。**本节此前写的「全量 exit 0」是错的，已在第六十五轮更正**——见该节末的「探针给不出 exit 0 时，我凭什么说它 exit 0」。

### 2.51 第六十五轮：把变异覆盖扩到**持久化层**——17 条变异 12 条存活，这一层此前**一条守卫都没被测过**

前四轮挑的都是「算法」文件（跟随策略、分段器、AI 标注、语音跟随状态机）。本轮换一类：**`TeleprompterV2Store`（1031 行），应用真正在用的落盘层**——`save`／`load`／`listDocuments`／`delete`／`duplicate`／`exportReading`／`exportSource` 全部走它（`TeleprompterSession.swift:299–443`、`2656`）。它此前 **12 条测试、0 条变异覆盖**。

**首轮结果：17 条变异，12 条存活。** 与第 64 轮的状态机同形态，但结论更硬：这里不是「算法错了」，而是 **`validate` 本身二十多道守卫没有任何一条被观察过**。逐条摘掉，747 项测试全绿。

这些守卫平时挡住的是**被改坏或被截断的磁盘文件**——也就是读者已经遇到的那种稿件。所以本轮补的 11 条回归全部是「构造出来就必须被拒」，逐条对应一个读者能看见的后果：

| 守卫 | 摘掉之后的后果 |
|---|---|
| 段 `ordinal` 与下标一致 | 界面序号与真正的阅读顺序分叉，而稿件看上去完全正常 |
| 段关键词上限 5 | 一段十几个词全进识别偏置，跟随更容易被带偏 |
| 已确认朗读段禁止 `matchPhrases` | **一份旁本别名参与跟随，且不出现在读者确认过的清单里** |
| 朗读正文 == blocks 的 speak 内容 | 审阅通过的东西和上台念的东西不是同一个 |
| `readingHash` == sha256(正文) | 「这一版念的是什么」这条凭据证明不了任何东西 |
| 段列表非空 | 打开后什么都没有 |
| 段 id 唯一 | 读者在第一段登记的读法落到第二段头上 |
| 块引用单元去重且升序 | 按单元归位时拿到互相矛盾的位置集合 |
| 选区是来源单元的子集 | 稿子能打开，念到那里就断了 |

**其中一条要单列：已确认朗读段禁止 `matchPhrases`。** 这是方案 §5.6「读法别名只能由读者登记、模型不得注入」在**持久化层**的执行点，而第 63 轮的 A6 是它在**解码器侧**的执行点——**同一条产品边界，两个执行点，此前两侧都没有任何测试观察**。第 63 轮当时写下「这条产品边界只存在于代码里」，本轮把另一半也钉上了。

**两条存活的查因结果构成本轮最有意思的部分**，都是「看起来承重、实际承重的是别处」：

- **D14（目标时长必须 > 0）等价变异**：`TeleprompterTimingPlanner.validateTargetMinutes` 只接受 1…N 分钟，**0 在更早的规划器范围检查处就已被拒**。守卫与它冗余。
- **D15（时长区间上下界有序）生产不可达**：`ClosedRange` 不允许下界大于上界——进程内构造会 trap，**实测 `ClosedRange(uncheckedBounds:)` 在本工具链下同样 trap**（这条是写测试时真崩了一次才发现的），Codable 解码也会先崩。这道守卫永不触发。
- **D11／D17（`documentID` 的路径守卫）等价变异**：`documentID` 全部来自 `UUID().uuidString`（`createDocument`／`duplicate`）或磁盘文件名（`listDocuments`），**从不来自用户输入**；而 `".."` 拼上扩展名是 `"...json"`，在 `appendingPathComponent` 下不构成目录穿越。承重的是「ID 不来自用户输入」这个前提，不是这两行代码。

**D7 是本轮唯一一条「首轮存活、补对夹具后才转杀」的**，值得记下来：最初那条回归只把段列表清空，而**空段列表会被区间连续性的 reduce 顺带挡住**（reduce 得 0，而正文非空）——所以那条断言根本区分不出守卫在不在。真正只有 `!segments.isEmpty` 能拦的是「正文也为空、块也为空」的全空版本。**这是第 84 条与 A3 的同一次复发：断言存在、名字正确、也真的绿了，只是它断言的那件事与被保护的分支无关。**

**本轮变异集 85 → 102 条，全量 exit 0：82 杀 / 15 存活 / 5 INVALID，基线 757**（Swift Testing 363/16 套件 + XCTest 394）。15 条存活全部是等价变异或生产不可达，逐条理由在 spec 的 `rationale` 里。**真缺陷数不变，仍是第 41–86 条**——本轮找到的是覆盖缺口，不是实现错误。

**下一轮候选**（仍 0 变异覆盖）：`TeleprompterStageSettings`（793 行，场景预设）、`TeleprompterPreparationPipeline`（2074 行，素材构建）。

**本轮最大的收获不是那 11 条回归，而是探针替我抓到的一次自己的假读数。** 全量 102 条跑完报 `exit 1`：V7／V8／V14／V16 四条**声明 KILLED、实测 SURVIVED**——而这四条我在第六十四轮已亲手查清是等价变异、并在 `rationale` 里写清了理由，**却没把 `expect` 字段一并改成 `SURVIVED`**。根因是第六十四轮那条命令是 `swift_mutation_probe.py … | tail -30`，`$?` 取的是 `tail` 的退出码；`tail` 永远成功，于是我据此写下「exit 0」。**探针那一刻正在报 exit 1，而我的证据链只到 `tail`。**

这与第 60 轮（探针给自己造假击杀）、第 79 条（凭印象改数字）是同一条纪律的第三次复发，**而这一次错的人是我自己**。写进报告是因为接手方一定会碰到同一件事：**任何用管道取尾的命令都会把退出码替换成最后一个管道的退出码**，而流水线的绿灯恰恰挂在这个码上。三条可直接照做的规矩：

1. **探针不许接管道。** 要看输出就重定向到文件再单独读，退出码从探针本身取。
2. **`expect` 与 `rationale` 必须同时改。** 查清一条存活是等价变异时只改 `rationale` 而不改 `expect`，探针会一直把它报成不一致——**这道报错本身是好的**，它是唯一能发现「文档与 spec 说法不同步」的东西。
3. **报告里凡是引用退出码的行，都必须能指到一条没接管道的命令。** 指不到的按「未验证」处理。

修正后 102 条为 **82 杀 / 15 存活 / 5 INVALID**，与本节及 §3.1 引用的数字一致。

### 2.52 第六十六轮：把变异覆盖扩到**舞台设置与显示行排版**——存活全部落在边界上，而三次「夹具不够咬得住」

前两轮补的是状态机与持久化层，都是「此前零覆盖」。本轮换了个起点：`TeleprompterStageSettings`（793 行）此前**已有 33 条测试**，看上去是最不需要操心的一批。**首轮 23 条变异，12 条存活。**

**结论不是「它覆盖不足」，而是「它覆盖的是典型值」。** 12 条存活里绝大多数是边界：非有限输入、偏移**恰好等于**末行末尾、刚开口的第一段、以及「差一点点就不该报」的那几道死区。33 条用例把每道夹取、每个槽位边界、每种配速状态都测了，**但没有一条测「刚好踩线」**。这与第 64／65 轮的形态不同，值得单独记：那两个文件是**没测**，这个文件是**没测到边**。

本轮补 9 条回归。**其中三条在第一版夹具上没咬住，是本轮最该留下的部分**：

- **E1（退化排版宽度）**：第一版只断言「排出来的行仍拼得回原文」。可排版器在 NaN 宽度下同样能把整段塞进一行——**那三条断言在有守卫和无守卫时都成立**。改成「退化宽度必须与按 1 排版的结果逐条相同」才咬住。顺带把一条事实写进注释：**Swift 的 `max(1, .nan)` 返回的是 nan 而不是 1**（`max` 实现为 `y < x ? x : y`，而 `nan < 1` 为假），所以这道守卫不是冗余判断。
- **E2（退化字号）**：第一版只试 `.nan`，而 AppKit 对 NaN 字号与 1 号字体给出同样的排版结果，同样区分不出来。补 `.infinity`（超大字号会把整段挤成一行）后转杀。**宽度侧与字号侧是两道独立的守卫，症状完全不同**——这也是为什么它们必须各有一条用例。
- **E15（校准建议的 0.02 死区）**：第一版把 `currentCalibrationFactor` 设成刚测出来的倍率，差值为 0。而 **`abs(0) > 0.02` 与 `abs(0) > 0` 同为 false**——这样的夹具改不掉死区。改成落在死区内的 0.01 后转杀。

**本轮第四次撞上同一族问题，而这一次它藏在一个名字极正确的既有用例里。** 既有那条 `stage summary computes speech review metrics and calibration` 里写着「Accidental start (under 30s) -> canCalibrate is false」，断言 `shortSummary.canCalibrate == false`，**它是真的绿的**——但它只把 `currentSegmentIndex` 设成 0，读到的只有第 1 段共 29 个单元，于是 `totalUnits >= 50` 先一步挡住了它，**30 秒那道门根本没被走到**。新补的 `calibrationStaysUnavailableBeforeThirtySeconds` 用「读得够多（3 段 ≥50 单元）但只读了 20 秒」的素材才真正咬住，并带一条过 30 秒的正向对照——**没有这条对照，上面的断言仍可能因为别的原因通过**。

这是第 84 条、A3、D7、E16 的同一次复发，四次形态完全一致：**断言存在、名字正确、也真的绿了，只是它断言的那件事与被保护的分支无关。** 到这一轮我不再把它当意外——**凡是「被摘掉后仍通过」的守卫，都必须先问一句「它是被哪条别的守卫挡住的」，再决定要不要补用例。**

2 条存活的处置：

- **E4 生产不可达**：`TeleprompterStageDisplayLine` 的 init 是 `fileprivate`，全仓只有 `TeleprompterStageLineLayout.layout` 的两处构造它，而每个段的首行恒从 0 开始——`lines[firstIndex].utf16Start > 0` 不可能成立，「早于首行则回落到首行」永不触发。
- **E21 等价变异**：`apply(_:)` 是同步的 `@MainActor` 方法，预设期间 `markCustomized` 会把 `presetStorage` 写成 `.custom`，但方法末尾的 `self.preset = preset` 紧接着覆盖它并重写 defaults，**中间没有任何观察者能看见那个瞬态**（无 await、无 reentrant 观察点）。

1 条崩溃型 INVALID：**E5** 去掉上界夹取后 `lines[currentIndex + boundedDelta]` 越界，Swift trap 让测试进程在 662 项处中断。与 A4／A5／M26 同族。

**E23 顺带量出一处真缺口的下界**：`scriptPointSize` 夹在 28…60，而 `38 × 0.67 = 25.46`——**读者把字号拉到最小时，下界夹取是承重的**，否则拿到 25.46pt；上界那半边（`38 × 1.52 = 57.76 < 60`）属冗余。补的用例钉的是「停在设计下限」这个结果，不是「等于边界值」——后者在边界被改动时两边一起动、永远成立（第 81 条的教训）。

**本轮变异集 102 → 125 条，全量 exit 0：102 杀 / 17 存活 / 6 INVALID，基线 766**（Swift Testing 372/16 套件 + XCTest 394）。**真缺陷数不变，仍是第 41–86 条**。

**下一轮候选**（仍 0 变异覆盖）：`TeleprompterPreparationPipeline`（2074 行，素材构建）。

### 2.53 第六十七轮：把变异覆盖扩到**素材构建管线**——零击杀，以及一条让真检出变成「什么都没证明」的测试缺陷

本轮目标 `TeleprompterPreparationPipeline`（2074 行）：**87 条测试、0 条变异覆盖**，是本分支体量最大也最要紧的一块——它是 AI 改稿从提示词走到读者稿子的那条路（分组 → 改写 → 接缝归并，含重试、窗口切分、本地兜底与可观测性）。

**首轮 18 条变异：零击杀。** 15 条存活、3 条 INVALID。这个比例本身说明：**这条路径的测试只覆盖「模型规规矩矩」的情况，从不模拟「模型不规矩」。**

## 本轮最重要的发现不在提词器里，在测试里

那 3 条 INVALID 不是「探针缺陷」，是**真检出被崩溃吃掉了**。

`F11`（429 不再算瞬时失败→可重试）在首轮报的是 INVALID，理由写着「test process crashed after 3 failing」。手动应用该变异跑 `swift test`，真相是：

```
✘ transientRetryWaitsForRetryAfterBeforeTheNextStageRequest
  recorded an issue at TeleprompterPreparationPipelineTests.swift:517
  Expectation failed: values.count >= 3
Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range
```

**三条真实失败已经产生了，然后测试自己越界 trap，把整个测试进程带崩。** 探针的既定纪律是「崩溃后不得解读结果」，于是这次检出被记成 INVALID——**一个已经被逮住的真回归，变成了「什么都没证明」**。`F13` 同理（8 条真实失败被 `rewritePrompts[1]` 的越界吃掉）。

根因是一个很小、很常见的写法错误：

```swift
#expect(values.count >= 3)          // 非致命：失败后继续往下走
#expect(values[1].timeIntervalSince(values[0]) >= 0.04)   // 于是这里越界 trap
```

修法是一行：把计数断言换成**致命**的 `try #require`。修完复跑，**`F11` 干净转杀（6 条失败）、`F13` 干净转杀（12 条失败）**。

我按模式全量扫了提词器测试目录（66 处 count 断言、10 个文件），**又找到并修掉 1 处同型**（`TeleprompterStageSettingsTests` 里 `#expect(lines.count > 1)` 后接 `lines[0]`／`lines[1]`／`lines.last!`）。修完全量复扫为 0。

**这一条比本轮任何覆盖缺口都重要**：它意味着在此之前，只要某条回归恰好踩中这两个用例中的一处，整轮变异证据就作废——而我们**此前没有任何机制发现这一点**，因为探针只会说「INVALID」，不会说「INVALID 是因为测试自己崩了」。第 60 轮修的是探针把崩溃读成击杀，本轮修的是**崩溃本身不该发生**。

## 修完之后，一条**早已被接受的旧结论**自己变了

全量探针第一次跑完是 **exit 1**：只有一条不符——**M38 声明 `INVALID`，实测 `KILLED`（72 failing）**。

按已登记的校准（「失败数 ≥5 的击杀不能由单个 flaky 测试解释」），72 条远超阈值，且**隔离复跑 3 次读数 72／73／73，确定性复现，不是间歇**。于是去查它为什么变了，答案就是本轮那处测试修复：

M38 把 grouping 的 `schemaVersion` 守卫改成 v2，于是分组提示词带 v2，`rewriteFailureRetriesOnlyRewriteWithTheOriginalGrouping` 里按 schemaVersion 过滤出来的 `rewritePrompts` 变成 0 条。**改之前那句正是非致命的 `#expect(rewritePrompts.count == 2)`**——断言红了却不停止，下一行 `rewritePrompts[0]` 越界 trap 把进程带崩。M38 因此长期被记成 INVALID，而它其实**和 F11、F13 是同一个病**：崩溃吃掉了真检出。

这条比 F11／F13 更有分量，原因是**它不是本轮新加的变异，而是一条在第 57 轮就已经写下结论、并且当时还被当成「分类规则被修好了」的证据**（「崩溃行里的 `error: Process ... signal code 5` 被编译错误正则命中，据此给 `classify()` 加了崩溃规则」）。那段记录本身没错——它确实被读成了 `does not compile` 而不是 `INVALID`。但**结论从此就一直是「这条变异只能靠崩溃暴露」**，而真实情况是：它一直能干净地暴露，只要测试不要在断言之后越界。

由此得到一条与本轮开头那条互补的纪律：

> **崩溃一旦消失，原本被它掩盖的读数会自己变干净。** 因此「INVALID」不是一条可以长期沿用的结论——它是「当时观测被崩溃污染了」的记录。每修掉一处崩溃，都必须回头重测此前所有因此记成 INVALID 的变异。

本轮因此把 M38 由 `INVALID` 升级为 `KILLED` 并重写了它的 `rationale`。**这不是把读数改成好看的，而是把「当时观测不到」换成「现在观测得到」。**

## 变异验证的 CI 形态：**按需触发，不进常规门禁**

探针此前只能在本机跑，接手方拿到的是一个脚本和一份 spec，却没有任何「怎么跑、要跑多久、退出码怎么读」的入口。本轮补上 `.github/workflows/teleprompter-mutation.yml`，但**它只有 `workflow_dispatch`，刻意不挂 push／pull_request**：

- **耗时**：143 条在本机约 45 分钟，CI runner 更慢，因此 job 超时给到 120 分钟；
- **工作区不干净**：探针按设计会真实改写 Swift 源码再还原，运行期间工作区一直是脏的；
- **并发语义**：`cancel-in-progress: false`。挂上常规触发会让每一次提交都等它，也会让两次长跑互相取消。

常规门禁仍然只有 `ci.yml`；这条 workflow 是它的**补充，不是替代**。同时 `docs/developers/testing-acceptance.md` 补了退出码语义表（0 可引用 / 1 不可引用 / 2 拒绝解读）与「不要接管道」的跑法——`ci.yml` 里那步同样不接管道，退出码直接从探针收下来。

## 16 条存活：一条按形态判等价，其余全是真缺口

- **F15（重试等待不再要求延迟为正）等价变异**：`Task.sleep(for: .seconds(0))` 本身就是空操作，去掉判断不改变可观测行为。
- **其余 15 条是真缺口**，其中后果最重的几条：
  - **F7**：去掉「这类错误才允许本地兜底」的判定后，**配置类错误（`notConfigured` 等）也会静默降级成「按原文朗读」**——读者以为 AI 不可用，却拿到一份看起来完全正常的稿子。这与判据 1「稿件可信」直接相关：降级本身没有告诉读者发生了。
  - **F5**：模型可以跳过中间单元而不被发现，**与第 63 轮 A3 同一族**，只是那一族在解码器侧、这一族在管线侧。
  - **F8／F1／F2**：本地兜底不校验段数、选区缺单元不报错、窗口返回空结果被记成成功——三者都会**静默交付一份缺段的稿子**。
  - **F12**：429 的重试用例有，**5xx 的没有**。服务端 5xx 不再触发重试，读者白等一次完整往返。
  - **F18**：输出被截断是确定性失败，重试只会再截断一次。

**这 15 条本轮只定位、未补回归**，逐条写进了 spec 的 `rationale`，并登记为 §5 第 16 条。理由不是「不重要」，而是**它们每一条都需要先造出一种「模型不规矩」的素材**（跳过分组、凭空造块、空结果、缺单元、5xx 注入……），这是一轮独立的素材工作，混在本轮里做会两头不靠。**报告与探针此刻都如实记着它们是缺口，没有把它们写成「已覆盖」。**

**本轮变异集 125 → 143 条：105 杀 / 33 存活 / 5 INVALID，基线 766**（Swift Testing 372/16 套件 + XCTest 394，本轮未新增回归，只修了两处会崩的断言）。首轮声明的 104／33／6 里，M38 由 INVALID 升为 KILLED，故净变为 105／33／5。**真缺陷数不变，仍是第 41–86 条**——但本轮产出的是**一处真实缺陷（测试侧）**、**一处已登记的方法论更正**，以及**一条被崩溃掩盖了整整十轮的旧读数**。

**提词器侧剩余 0 变异覆盖的文件已清空**：`TeleprompterV2Store`、`TeleprompterStageSettings`、`TeleprompterPreparationPipeline` 均已覆盖。**该文件已在第六十八轮查清：F 组 18 条中 6 杀 / 12 存活，存活的 12 条全部判定为生产不可达、冗余防御或等价变异，没有真缺口（见 §2.54）。**

### 2.54 第六十八轮：把「15 条真缺口」逐条查清——**结论是它们都不是真缺口**

上一轮把 F 组 16 条存活里的 15 条登记成「真缺口，本轮只定位未补」，并按后果排了序（配置类错误静默降级、跳过中间单元、静默交付缺段稿）。**本轮逐条查完之后，这个判断被推翻了。**

做法很直接：为每条造一种具体的「模型不规矩」素材，写成回归，再用探针看它到底杀不杀得掉。

## 4 条转杀，12 条不是缺口

| 变异 | 新增回归 | 结果 |
|---|---|---|
| F7 配置类错误不再要求可本地恢复 | `configurationFailureIsNotSilentlyDowngradedToReadingTheSource` | **KILLED（3 条失败）** |
| F12 瞬时失败不再认 5xx | `serverErrorGetsOneBoundedRetryJustLikeRateLimit` | **KILLED（4 条失败）** |
| F9 可本地恢复的错误种类被收窄 | `transportFailureFallsBackLocallyInsteadOfFailingTheWholeDraft` | **KILLED（2 条失败）** |
| F3 接缝合并不再要求两侧都是 speak | `seamNextToAnOmittedBlockIsNotSentToTheReduceStage` | **KILLED（5 条失败）** |

**F7 是这一轮里后果最重的一条**：去掉那道判定后，`notConfigured` 这类「重试也没用」的错误也会被本地兜底接住，降级成一份看起来完全正常的稿子——读者以为 AI 不可用，却拿到成品，而降级本身没有告诉任何人发生过。这与判据 1「稿件可信」直接冲突，现在被回归钉住了。

其余 11 条存活逐个查因，**没有一条是真缺陷**：

- **生产不可达（5 条）**：F1／F8／F14／F16／F17。共同原因是它们都建立在一个上游已经强制成立的不变式上，而**五条各不相同**：
  - F1／F8 依赖 `validate(_:)` 的 `selectedIDs.allSatisfy({ unitsByID[$0] != nil })`，加上 `makeWindows` 对每个入选 ID 直接 `unitsByID[id]!` 强制解包——每个窗口单元 ID 按构造必然查得到，`compactMap` 永远不会丢东西。
  - F14 的 `split` 只在 `sourceUnitIDs.count > 1` 时被调用，而 `count ≥ 2` 时 `midpoint = count / 2` 恒满足 `0 < midpoint < count`。
  - F16 的 `elapsedMilliseconds` 只有两个产地，两个都以 `max(0, …)` 收尾（`LLMProvider.swift:1219` 与管线自己的 `elapsedMilliseconds(since:)`）。
  - F17 的 `budgetUnits` 构造时就是 `max(1, rawText.utf8.count)`，持久化层读取时另有一道 `> 0` 校验。
- **冗余的纵深防御（5 条）**：F2／F5／F6，以及 F18（见下）。**上一轮把 F2／F5／F6 写成「会静默交付缺段稿」，是过重的判断。**
- **等价变异（2 条）**：F15（形态判定，沿用上轮）、F4（见下）。

## 「被摘掉后仍通过」的守卫：这一族第五次出现

F5／F6 的变异去掉后，整套测试**照样全绿**。按第 84 条以来就写进报告的那条规矩——「凡是『被摘掉后仍通过』的守卫，都必须先问『它是被哪条别的守卫挡住的』」——去查，结果是：

| 变异 | 真正拦住它的是 | 位置 |
|---|---|---|
| F5 跳过分组中间单元 | 分组解码器 `guard group.startUnit == next`，跳段以 `.rangeGap` 被拒 | `TeleprompterPreparationPrompts.swift:1451` |
| F6 凭空造改写块 | 改写解码器 `IDs.count == allowed.count` 与 `guard let group = allowed[block.blockID]` | 同文件 :1545 / :1550 |
| F2 窗口结果为空 | `rewrite` 提示词构造器的 `guard !groups.isEmpty` | 同文件 :782 |
| F18 截断失败不再重试 | `canRetryStage`——`.outputTruncated` 既不是结构化失败也不是 429/5xx，**本来就不可重试** | `TeleprompterPreparationPipeline.swift:1226` |

**F5 那一行值得单独说**：它和第 63 轮的 A3 是**同一条约束的两个副本**——A3 在解码器侧，F5 在管线侧，而解码器先跑。上一轮把 F5 说成「与 A3 同一族」，其实比「同族」更强：**它就是 A3 的重复守卫**。

由此得到本轮的一条记账规矩：

> **同一道约束在两层各写一遍时，上层那道要按「冗余」记账，不能按独立防线记账。** 否则报告会把一份纵深防御记成两处风险，接手方会以为有两件事需要修。

这是「断言与被保护的分支无关」那一族的第五次出现（前四次：第 84 条、A3、D7、E16）。**每一次的形态都一样：被测代码是对的，多出来的那道是冗余的。**

## 一个假存活差点让我改错结论

前两条夹具我按「守卫会抛错」来写，断言 `prepare` 抛异常。结果在变异下**依然全绿**。第一反应是「变异没应用」——按纪律这确实是要先排除的可能。

查下来是另一回事：**这些守卫抛出的错会被本地兜底接住**，所以可观察的差别根本不在「抛不抛错」，而在**交付的稿子是否少了一段**。把断言改成「稿子内容必须与原文逐字相同、且 fallbackBlockCount 等于单元数」之后，F5／F6 才被正确地区分出来。

这条记在这里是因为它同时暴露了两件事：一是**兜底机制会把「结构失败」和「内容缺失」两种表现合成同一种结局**，观察点选错就会得到假存活；二是**假存活必须先排除「变异没应用」，再去找原因**——顺序反了会改错地方。

## F4 与 F10：如实记作未覆盖，而不是硬凑用例

- **F4（恢复预算不受窗口数约束）判等价变异**，限于默认 policy：`maxRecoveryRequests` 默认 3，原式 `min(3, max(2, min(windows.count, 3)))` 与变异式在所有可达窗口数下都相同——windows ≤ 2 时原式给 2，而**每个窗口最多消耗一次恢复请求**，所以 2 与 3 都不构成约束；windows ≥ 3 时两式恒等。只有「调用方传入 `maxRecoveryRequests > 3` 且窗口数 ≥ 4」才分叉，生产走默认 policy。
- **F10（重试延迟不夹到 60 秒）一半等价、一半不可经济观测**。下界 `max(retryAfter, 0)` 是等价的：唯一消费者 `waitBeforeRetryIfNeeded` 已经要求 `delay > 0`。上界是真的防御，但**只能在真的等超过 60 秒时才可观测**，而 `retryAfterDelay` 是 `fileprivate`——实测编译期就报 `inaccessible due to fileprivate protection level`。**本轮试过写成行为断言，跑出来要么让整套测试多花 60 秒、要么断言不到边界，如实记作未覆盖。**

## 本轮结论

**变异集仍是 143 条，净变为 109 杀 / 29 存活 / 5 INVALID，基线 774**（Swift Testing 380 + XCTest 394，本轮新增 8 条回归）。真缺陷数不变，仍是第 41–86 条。

**§5 第 16 条的 15 条「真缺口」至此结掉：4 条补回归转杀，11 条判定为生产不可达、冗余防御或等价变异，没有一条是真缺陷。** 提词器侧素材构建管线这一块，现在**没有已知的、由测试证据支持的缺陷**。

剩下的 29 条存活中，属于「真缺口（已定位未补）」的只有第 63 轮之前的少数几条；F 组已不再有真缺口。

### 2.55 第六十九轮：把 INVALID 分成两类——剩下 5 条全部是「崩溃在产品里」

第六十七轮立了一条纪律：**崩溃一旦消失，原本被它掩盖的读数会自己变干净**；据此 §5 第 17 条要求剩下 5 条 INVALID（M26／A4／A5／A13／E5）逐条回炉，查清是真会崩溃到无法解读，还是又一次被测试自己的写法吃掉了真检出。

**结论：5 条全部是前者，没有一条是后者。** 5 条的 `expect` 维持 `INVALID`，但每一条都补上了「崩在哪个用例、trap 在哪一行产品代码、测试断言的恰恰是什么」。

## 做法

串行复跑（`swift test --no-parallel`）。这一步是必需的：并行执行时崩溃点前的输出被其他用例的 `✔ Test … passed` 交错打散，**从日志里根本看不出是谁崩的**；串行之后，崩溃行的上一条 `◇ Test … started` 就是肇事用例。

| 变异 | 肇事用例 | trap 位置 |
|---|---|---|
| M26 | `manualMoveWithAStaleLengthTableIsANoOpRatherThanACrash` | `TeleprompterFollowController.manualMove` 内部越界读 `segmentUTF16Lengths` |
| A4 | `rejectsOmissionsOverlapAndUnknownFields` | `TeleprompterAnalysisDecoder` 内部 |
| A5 | 同上 | 同上（`end_unit` 上界放宽一格后放行越界标注） |
| A13 | `aScriptWithAnOverlongUnitStillAnnotatesEndToEnd` | `TeleprompterAnalysisDecoder.decode` 内部 |
| E5 | `reading position resolves and steps across display lines without wrapping` | `TeleprompterStagePresentation.positionByMovingLine` 内部 |

## 关键观察：这 5 条的测试断言的恰恰是**安全行为**

这是本轮最值得记下来的一点。逐条看过去会发现一件整齐得可疑的事：

- M26 的用例名里就写着 **`...RatherThanACrash`**，断言是「长度表不齐全时必须原地不动，而不是越界崩溃」；
- A4／A5 喂的素材是「`end_unit` 越界必须被拒」，断言是 `throws`；
- A13 的用例名断言「超长单元也要端到端标注成功」；
- E5 断言的是 `positionByMovingLine(by: 1, from: lastPosition, lines: lines) == nil`——**越过末行返回 nil，而不是崩溃**。

也就是说：**这些用例本来就在钉「不许崩」的行为，变异把守卫摘掉后产品真的崩了，于是测试跟着一起崩。** 测试没有毛病，被测代码的缺陷才是被它逮住的那个东西——而守卫正是这个缺陷的修复。

## 于是 INVALID 分成两类

| 类型 | 特征 | 能不能靠改测试挽回 | 本分支实例 |
|---|---|---|---|
| **一型：崩溃在测试里** | 测试用了非致命断言之后继续按下标取值，断言失败不停止 → 越界 trap | **能**：把计数断言改成致命的 `#require` 就干净转杀 | M38、F11、F13（第六十七轮） |
| **二型：崩溃在产品里** | 变异让产品代码自己越界，测试随之崩 | **不能**：这不是测试的缺陷，守卫就是修复 | M26、A4、A5、A13、E5（本轮 5 条） |

第六十七轮之前，这两类在报告里都写作「INVALID：去掉守卫后 Swift 越界 trap 让整个测试进程中断」，**读起来像是同一回事，处理方式却完全相反**。分开记账之后，「要不要回炉」这个问题就有了确定答案：只有一型值得回炉，二型回炉是白费功夫。

**E5 还额外排除了一种可能**：第六十七轮刚把该用例里的计数断言改成了致命的 `#require`，所以它不可能再是「测试自己越界」——崩溃点确实落在产品函数里。

## 本轮没有代码改动

变异集仍是 143 条、109 杀 / 29 存活 / 5 INVALID，基线 774，**数字未变**。本轮的全部产出是这 5 条 `rationale` 的重写与本节结论：**§5 第 17 条至此结掉**，5 条 INVALID 全部确认是二型，继续记 INVALID 是正确读数，不需要（也不应该）试图把它们变成 KILLED。

顺带记一条工具事实：**崩溃定位必须串行**。并行执行下 `✔ Test … passed` 与崩溃行交错，从日志里无法归因——本轮第一次并行跑就没能定位到肇事用例，改 `--no-parallel` 后一次就定位全了。

### 2.56 第七十轮：把变异覆盖扩到**提词会话**——15 条变异 8 条存活，三个是真缺陷

本轮目标 `TeleprompterSession.swift`（3348 行）：**0 条变异覆盖**。它是舞台侧的总调度——`beginStart`／`beginStop`／`stageCloseToken`／跟读状态与段落的全部交互都在这里，前七轮补覆盖的文件（状态机、持久化、设置、素材、分段器）都要经过它。**它此前一条守卫都没被直接观察过。**

新增 S 组 15 条变异，**7 杀 / 8 存活**；补 4 条行为回归后 3 条存活转杀，**第 87–89 条**由此产生。

**第 87 条（新）：按下暂停后，「手动浏览中」要等排空跑完才出现。** `requestVoiceStop` 里的 `followController.enterManual()` + `syncFollowState()` 是**同步交付给界面的**——读者按下暂停那一刻，状态条就必须已经切到手动。去掉同步交付后，排空与关台（最多 8 秒）期间 `followState`／`followStatusText` 一直停在「跟读咬合」，而麦克风其实已经在关。回归用 `drainGate` 把排空卡住，**在停止仍在飞行时**断言这两个值，所以杀掉的是同步语义而不是收尾后的最终状态。

**第 88 条（新）：关台令牌可以被第二次请求换掉，舞台从此再也打不开。** `stageCloseToken` 是一次性的：窗口关闭委托与菜单里的「关闭」可能都到一次。第二次 `beginStageClose()` 若换掉令牌，第一次的 `finishStageClose()` 就会在 `stageCloseToken == token` 处提前返回，`stageCloseToken` 永不清空、`isClosingStage` 恒为真。回归直接断言第二次 `beginStageClose()` 必须返回 false。

**第 89 条（新）：「结束当前会话」不会把跟读收回手动。** 该路径走 `coordinator.stopCapture` → `stopper` → `stopCapture()`，**不经过 `requestVoiceStop`**，所以把跟读收回手动是 `stopCapture()` 自己的职责。少了那一步，采集已释放而 `followState`／`followStatusText` 仍停在「跟读咬合」，并且 `saveProgress()` 落盘的 `mode` 也是 `.following`——**重开时会按跟读态恢复**，这是三条里唯一会跨会话留痕的。回归走 coordinator 这条真实路径断言两个交付值。

剩下 5 条存活逐条查因，**没有一条是真缺陷**：

| 变异 | 判定 | 依据 |
|---|---|---|
| S2 | **真缺口**（非等价） | `phase == .manual` 且 `state == .starting` 的组合在生产里存在——`beginCapture()` 的 catch 在 state 仍 `.starting` 时就写 `phase = .manual`。去掉 `.starting` 排除会漏停麦克风。测试无法确定性控制该窗口，与阶段报告 V7／V8 同一族 |
| S3 | **生产不可达**（静态推断） | else 分支需 `phase != .manual` 且 state 非 starting/following；各条写 `phase` 的路径都紧接写 `.manual`，`finishStageClose` 写 `.ready` 时舞台已关。**但若可达后果不小**：`.stopFailed` 时 `beginStop` 会成功，滚动手势将静默重试停止并清空 `blocked` |
| S5／S6 | **冗余防御** | 要 token 失效须在 `.stopping` 期间换 generation，四个换 generation 的入口逐个回查均不可能 |
| S7／S8 | **等价变异** | 被 `TeleprompterFollowController.manualMove` 内层的 `min(max(0,index), segmentCount-1)` 遮挡（双层夹取） |
| S11 | **冗余防御** | 被 `beginStart()` 的 `canStart` 与 S12 的试读检查先后遮挡 |
| S13 | **等价变异** | 被 `beginStop` 对 `.stopping` 返回 nil 遮挡；`pendingStopDestination` 非空的状态只有 `.stopping`／`.stopFailed` |

**S2 的登记方式与其他五条不同，值得单独记住**：它既不是等价变异，也不是生产不可达，而是「**缺陷成立、但测试钉不住**」。这类存活不能靠补夹具消掉——要消掉它得能在 `beginCapture()` 与其 catch 之间确定性插入一次观察点，那要改的是产品结构而不是测试。**遇到这种存活，正确动作是把它留在存活里并写明后果，而不是硬凑一条测试假装它已被覆盖。**


### 2.57 第七十一轮：把变异覆盖扩到**素材导入域**——20 条变异，以及两套时长估算的分歧

本轮目标 `TeleprompterPreparationDomain.swift`（608 行）：**0 条变异覆盖**。它是「导入 → 分片 → 时长估算 → 时间预算」那条链路的纯逻辑实现——字节上限、扩展名、BOM、NUL、参考时长上限、UTF-8 字节前缀表、段落与语义切点、时长区间、时间预算分配全在这里。准备域此前只有 15 条用例。

R 组 20 条变异，首轮 **7 杀 / 12 存活**；补 10 条回归后 **18 杀 / 1 存活**（R9），**第 90 条**由此产生；再补 R21 钉住第 90 条的修复本身，定案 **19 杀 / 1 存活 / 0 INVALID**。

**首轮我错了三条。** R6／R11／R17 我按 SURVIVED 声明，实测分别是 20／30／59 条失败。共同原因是我**先验地认定「有另一条分支会遮挡」而没有核对夹具**：

- R6 把分片窗口的 `<=` 改成 `<`，我以为「每段少一个字节」不违反任何断言。实际它改的是**每一个分段结果**，下游所有钉住 `rawText`、`sourceRange`、段数与阅读位置的用例一起变红。
- R11 把语义边界的回扫方向反过来，我以为段落循环会先短路。实际现有夹具里大量文本**没有段落边界**，段落循环全部落空，语义回扫的方向就是唯一决策来源。
- R17 把预算余数从末段改到首段，我以为两条预算用例只断言「合计等于 `budgetSeconds`」。实际下游有 59 条用例断言**逐段预算值**。

**这三条是本分支第 84 条／A3／D7／E16 那一族「断言与被保护的分支无关」的镜像**：那次是断言没咬住被摘掉的守卫，这次是我以为断言没咬住、实际咬得很紧。**两种误判都源于没数清断言覆盖面，而不是源于守卫本身。** 已按纪律把这三条的 `expect` 改成实测值并重写 `rationale`。

**12 条存活逐条查因：9 条真缺口、1 条等价变异、2 条我的假设本身错了。** 9 条真缺口已各补回归转杀：

| 变异 | 守卫 | 不补回归会怎样 |
|---|---|---|
| R1／R5 | 字节上限、参考时长上限 | 报错点从「导入」后移到分片／预算阶段，容量限制名存实亡 |
| R2 | `.markdown` 扩展名别名 | 文案说支持 Markdown，行为只认 `.md` |
| R7 | `continuation` 续写标记 | 标点之后起段也被当成句子中间被截断 |
| R8 | `maxSourceUnits` 边界 | `<=` 变 `<`，恰好等于上限的合法稿件被误拒 |
| R13 | 时长区间下界系数 0.8 | 区间被无声收窄 20%，界面仍显示区间 |
| R14 | 校准系数下界夹取 0.5 | 语速极慢时估算小到与「念不完」同量级 |
| R18 | 权重下限 0.001 | 全部估算为 0 时报「无法建立时间预算」，真实原因是没估出时长 |
| R19 | 冒号作为 URL 标记 | `mailto:`／`tel:` 被判成「可精确估算」 |

**R9 是等价变异，且查清了它「是什么」而不是留着猜**：`isParagraphBoundary` 的窗口从 4 格缩到 3 格后，`"\r\n\r\n"` 那条 4 字符规则确实再也匹配不上，**但它本来就没有生效的机会**——同一个正向循环里 2 字符的 `"\n\r"` 在 CRLFCRLF 的**前一个位置**就已经命中并 `return`，4 字符那条永远排在后面。补了 CRLF 回归后它仍存活。**按纵深防御记账，不按独立防线记。**

**R10 我自己否掉了。** 我原本写了一条「去掉点号保护的 `next` 一侧」，并打算把它记成真缺口。写 rationale 时发现**「3.14」的 `next` 仍是词字符，那条变异根本没触及这道守卫要防的事**——它削弱的只是「`1.` + 空白」这种编号列表边界，而实测该形态下变异体切得**更多**而不是更少。**把它单列出来等于自欺。** 已作废并换成 R20（摘掉整道守卫），由小数回归钉住。

**第 90 条（新）：两套时长估算对同一段文本给出相反的确定性结论，其中一侧是 fail-open。** 提词器里有**两套并行的时长估算实现**——`TeleprompterDurationEstimator`（会话、素材管线、分段预算，18 处调用）与 `TeleprompterTimingPolicy.estimateDuration`（舞台设置、内容选择、试读，5 处调用）。两者的分档、区间系数（0.8／1.25）、校准夹取（0.5…2.0）**完全一致**，只有 URL 判定不同：本文件按「ASCII 标点里出现 `:` 或 `/`」，`TeleprompterTimingPolicy` 按正则 `(?:https?://|www\.)`。实测三分之二的样本上两者结论相反：

| 文本 | DurationEstimator | TimingPolicy |
|---|---|---|
| `详见 /usr/local 目录。` | 不确定 | **确定** |
| `发到 mailto:someone` | 不确定 | **确定** |
| `看 www.example.com` | **确定** | 不确定 |

**第三行是危险的那一侧**：`www.example.com` 既没有 `:` 也没有 `/`，两条 URL 规则都没命中，于是会话侧给出了一**可信点估计**，而同一时刻设置侧对同一段文字说「不确定」。这属第 63 条「把『没有证据』读成『证据表明没问题』」那一族：**含网址的稿件拿到了一个假装量出来的时长**，而按网址逐字符念恰恰是最不可预测的一类文本。

**修法只补 fail-open 那一侧**：给 `TeleprompterDurationEstimator.metrics` 补上 scheme／`www.` 形式，令它成为 `TeleprompterTimingPolicy` 的**超集**。**没有**把「ASCII `:` 或 `/`」这条规则反向搬进 `TeleprompterTimingPolicy`——那会让舞台设置、内容选择与试读三处对同一段文本从「不确定」变成「确定」，是**产品行为变更而非缺陷修复**，本轮不擅自做，并在代码注释里写明这处不对称是故意的、待产品拍板。回归 `wwwURLsAreTreatedAsUncertainOnBothSides` 钉住的是底线那条：**会话侧不比设置侧更宽松**。

**留下的记账规矩**：同一个概念在两处各写一遍时，**先查两处会不会给出相反的结论，再决定补哪一侧**。本轮两侧都「自洽」、都全绿，是下游 59 条断言也没能发现的——因为没有任何一条断言跨这两个入口对比过。


### 2.58 第七十二轮：把变异覆盖扩到**稿件持久化层**——19 条全杀，**零新缺陷**

本轮目标 `TeleprompterStore.swift`（214 行、28 处逻辑、仅 5 条用例）：稿件的落盘、原子覆盖、路径解析与 bundle 校验都在这里，而它是**唯一一个承载用户数据持久化的提词器文件**。

T 组 19 条。首轮 **2 杀 / 16 存活 / 1 INVALID**；补 10 条回归后 **19 条全杀**（每条恰好 1 条用例转杀），**本轮没有找到任何新缺陷**。

**首轮我又错了两条，方向与第七十一轮相反。** T5 我判 SURVIVED，实测 KILLED——我以为「读一份不存在的稿子」零观察，实际 `testDeleteAndDuplicateDocument` 在删除之后紧接着 `loadBundle` 并断言 `.notFound`。**而同一道约束在删除侧的副本（T8）确实零观察**：两条长得几乎一样，只有一条被测到。**这说明「同一道约束在两个入口各写一遍」时，一条被覆盖不代表另一条被覆盖**，必须逐条查。T15 首轮记成 INVALID，则是我替换时把 `guard` 关键字一起吃掉导致编译失败——**属锚点写错，不是产品缺陷**，已改正后重跑。

**16 条存活逐条查因，全部是真缺口**，已各补回归：

| 类别 | 变异 | 不补回归的后果 |
|---|---|---|
| **安全** | T17／T18／T19（`documentID` 里的 `/`、`.`、`..`） | **路径穿越防护零观察**：`documentID` 可让读取与删除都落到 documents 目录之外的任意路径 |
| **数据丢失** | T6（原子覆盖分支） | 已被既有测试守住——这条是本组唯一首轮就杀掉的产品分支 |
| 归因 | T5／T8 | 「找不到这份稿子」被压成「这份稿子已损坏」，与第 41 条同族 |
| 正确性 | T9 | **导出拿到的是第一版而不是正在读的那一版**——AI 改过稿后导出旧稿 |
| 正确性 | T4／T10／T13／T14／T15／T16 | 排序反向、段落分隔丢失、版本可跨稿、当前版本悬空、零段落版本、序号错乱 |
| 容量与输入 | T1／T2／T3／T7／T11／T12 | 见 spec 的 `rationale` |

**T15 值得单独记**：此前「一个版本但零段落」从未被构造过——`TeleprompterDraftStoreTests` 存的是**零个版本**，`for` 循环直接落空。而零段落版本正是**第 85 条**（长单元稿件的 AI 标注必然失败）的下游形态。

**本轮的方法论收获是一条记账纪律**：**「这个文件已有 N 条测试」和「这个文件的关键守卫被测过」是两件事。** 214 行配 5 条用例，看上去不算少，但路径穿越防护、原子覆盖分支、bundle 六道校验里有五道从未被观察——**其中一道是安全控制**。这与第六十六轮「舞台设置是没测到边」、第六十七轮「素材构建只测模型规规矩矩的情况」是同一族，但这次落在持久化层，代价最高。

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
| Swift 单元与回归 | `swift test --package-path macos/SpeechRailApp` | Swift Testing **372 项 / 16 套件** + XCTest **394 项**全部通过（2026-09-29 第六十二轮晚、跨午夜至 2026-09-30 第六十四轮复跑，合计 766 与探针基线自洽；第六十六轮为舞台设置与显示行排版新增 9 条回归（首轮 23 条变异 12 条存活，补完转杀 20 条），第六十五轮为持久化层的存盘守卫新增 11 条回归（首轮 17 条变异 12 条存活，补完转杀 13 条），第六十四轮为语音跟随生命周期状态机新增 7 条回归（首轮 15 条变异 10 条存活，补完转杀 11 条），第六十三轮为 AI 标注解码器新增 7 条回归，第六十二轮为分段器新增 5 条回归并把一条既有回归的素材换成真正跨过软上限的版本，第六十一轮为跟随策略的 `relocalizationMinimumMatches` 与 `reanchorMargin` 两个阈值各新增 1 条回归，第五十八轮为跟随策略两道守卫新增 3 条，第五十九轮为分组区间与保护字面量新增 4 条；两轮证据审计新增 8 条，读法别名通道与语音辅助试读再新增 20 条，错误归因与回滚一轮再新增 12 条，导入拒绝一轮再新增 1 条，字号列宽全值域扫描与迁移失败、零推进、恢复门槛与内容范围各再新增 1 条）。**第二次更正（第 79 条）**：本节此前写的「**更正**：XCTest 389 项无法复现，实测为 171 项」**本身是错的**——第五十五轮全量实测 `Executed 389 tests, with 0 failures` 稳定复现，171 复现不出来，而 324 + 389 = 713 与变异探针数到的通过条数逐条对上。上一条更正把正确的数字改成了错的，**与第 77 条同族：凭印象改数字、没有当场复跑**。两次更正的教训合并成一句：**数字要么当场复跑，要么别动**。**注意**：`swift test` **不编译** `TeleprompterView.swift` 与各 sheet，视图层编译证据只有 Xcode 一条，见 §2 第 34 条 |
| 探针回归 | `pytest tests/test_teleprompter_latency_probe.py` | **15 项通过**（新增时钟回退守卫用例）。**注意**：本 worktree 的 `.venv` 未安装 `dev` extra，须用主检出的 venv 并把本 worktree 的 `src` 置于 `PYTHONPATH` 之前；单文件运行还须加 `--no-cov`，否则 `--cov-fail-under=80` 会让退出码恒为非零。见 §2 第 33 条 |
| 共享准入回归 | `pytest tests/test_resource_governor.py` | 25 项通过（同 key 串行、共享单一 worker 槽位、重叠串行） |
| 回放 runner 端到端 | `swift run teleprompter-replay --manifest <外部 manifest>` | 产出 `teleprompter.eval.v1` 报告（P50／P95、恢复延迟、失败占比与 caveats 齐备）；缺 manifest、缺版本记录、素材字段非法均以退出码 2 拒绝。**CLI 与单测同形核对**：用与 `trackingLatencyIsMeasuredFromTheStartOfTheReadNotTheRun`／`reanchorLatencyIsMeasuredFromTheDetour` 同形的素材跑 CLI，复现了单测断言的数值（跟随延迟 p50=p95=400 ms；恢复延迟 p50=1100 ms），确认 runner 驱动的确实是生产跟随路径，而不是另写一套转写充当验收 |
| Xcode App target 编译 | `scripts/macos_app_build.sh --configuration Debug` | **BUILD SUCCEEDED**（2026-09-29 复跑）；17 条 warning 全部落在既有代码（`RealtimeASRClient` 的 `withStageTimeout` 未用结果、`LLMProvider` 弃用项等），本轮新增文件 0 条 |
| Xcode 单元测试 target | `scripts/macos_app_build.sh --configuration Debug --test-unit` | **TEST SUCCEEDED**（2026-09-29 复跑），XCTest **346 项** 0 failures，进程正常退出，`test-unit: passed`，exit 0。首轮曾因测试闸门竞态挂死并被 1800 s 超时终止，已定位并修复，见 §2 第 9 条 |
| 工程文件一致性 | `plutil -lint project.pbxproj` | OK；新增源码在 SwiftPM 与 Xcode 两个 target 均已登记 |
| 差异卫生 | `git diff --check` | 通过 |
| 回放 CLI 契约复核（第十八轮） | `swift run --package-path macos/SpeechRailApp teleprompter-replay --manifest <仓库外素材>` | 改了 `Metrics` 与报告 JSON 后**重跑 CLI 端到端**（此前只跑了单测）。两份素材放在仓库外 `/tmp`：正常跟随那份输出 `advanced_event_count: 2`；全停那份输出 `advanced_event_count: 0`、`harmful_jump_count: 0`、`stalled_event_count: 0`、`failure_share: 0`，**并带两条告警**（零推进、回稿恢复门槛未测量）。**修复前第二份的 caveat 数为 0**——这就是第 52 条说的「干净结果」，现在它在 CLI 输出里就长成告警的样子 |
| 评估器改动前后逐指标对比（第三十轮） | 同一份 41 秒真实素材（82 事件）分别用 HEAD 版与修复版 `TeleprompterReplayEvaluator` 跑 `teleprompter-replay`，再逐字段 diff 两份 `teleprompter.eval.v1` 报告 | **首轮抓到本轮自己引入的回归**：错误停顿 12 → 11，而 283 项单测全绿。修法与补回归见 §2.15。**复跑后逐指标零差异**——这份素材没有 improvise 标注也没有终态失败，失败计数修复前后都是 0，因此它证明的是「没动到正常路径」，**不是**「失败分母在真人素材上落到了某个区间」 |
| 零误推进 caveat 的真实素材复核（第三十一轮） | 同一份 41 秒真实素材分别用 HEAD 版与修复版跑 `teleprompter-replay`，逐字段 diff | `metrics` **零差异**，caveat 由 4 条增至 5 条，新增那条给出 **95% 上界约 263 次／小时**。这正是该素材能支撑的全部——§11.7「保留集观察零事件」在 41 秒素材上不该被引用，而修复前报告不这么说 |
| 素材侧远距闸门的真实素材复核（第三十三轮） | 用同一份 41 秒素材分别以修复前后的 `build_manifest` 重建标注，再各跑一次 `teleprompter-replay` 并逐字段 diff | **闸门取值先量后定**：82 事件 29 次推进，单次最大 17 字、中位数 5、p90 11，零次超过 24。取 24 后 **82 条标注零改变、64 → 64 个阅读位置**，回放报告**逐字段零差异**。挡得住那条 31 字跳跃, 且不碰真实素材 |
| 关键词闸门的真实素材复核（第三十四轮） | 同一份 41 秒素材以修复前后的 `build_manifest` 各重建一次标注，再各跑一次 `teleprompter-replay` | **先量后定**：82 事件里 21 个匹配只有 1-3 字，它们推进 **0/160** 字；29 次真正的推进里匹配最小 **5 字**。取 4 字闸门后 **标注 0 条改变、64 → 64 个位置、报告逐字段零差异**，而**复核清单 31 → 44 条**——13 个此前隐形的事件进入人工视野。位置没动，可见度变了 |
| 延迟样本数的真实素材复核（第三十五轮） | 同一份 41 秒素材以修复前后的评估器各跑一次 `teleprompter-replay`，逐字段 diff | **先量后定**：修复前探针实测 `latencies=4 / events=82`，即 P95 只由 4 个样本算出却与 `sample_count: 82` 并排。修复后既有 `metrics` **逐字段零差异**、既有 caveat 一条不动，只新增 `tracking_latency_sample_count=4`、`reanchor_latency_sample_count=0` 与一条带真实数字的覆盖面 caveat |
| 未匹配事件的真实素材复核（第三十六轮） | 同一份 41 秒素材以修复前后的评估器各跑一次 `teleprompter-replay`，逐字段 diff；并按窗口释放点插桩统计释放原因 | **释放点分布**：22 次释放中 `read-crossed` **4** 次、`read-no-position` **18** 次，即 82 个事件里 18 个（22%）没有阅读位置。修复后除 `stalled_event_count` **12 → 11** 与新增 `unmatched_event_count: 18` 外，其余 metrics **逐字段零差异**，caveat 只增一条 |
| 稳定前缀的真实素材复核（第三十七轮） | 同一份 41 秒素材分别按「按前缀截断」与「只保留越界守卫」两种改法重建标注并各跑一次 `teleprompter-replay` | **按前缀截断那一版否掉**：82 条标注改 26 条、带位置 64 → 56、`failure_share` **0 → 48.8%**、多出 2 次回稿超时与 3 条 `reRead`；原因是 §11.6 的延迟锚点是「人工标注的可识别片段结束」（人说过的话），而 §6.6 的稳定前缀规则治的是跟随器的推进决策。**收窄后的越界守卫**：0 条标注改变、报告逐字段零差异——契约守卫本就该对不含违约的素材完全惰性 |
| 交接文档引用可解析性 | 抽出 §4 台账与 §4.2 对照表里的具名标识，回到代码里逐个查 | **141 个标识全部可解析**（2026-09-29）。首轮查无此条 1 处：#111 引用了 `theSpeechTrialAdoptDecisionPinsRecognitionAndDurationSeparately`，而实际函数名是 `theSpeechTrialAdoptDecisionPinsBothConditionsSeparately`、显示名是带空格的 `the adopt decision pins recognition and duration separately`，报告写的是第三种形式，已改。详见 §2 第 45 条。**复核时（2026-09-29 第十八轮）脚本报 1 条「缺失」，经查是误报，报告无需改动**：`theSpeechTrialAdoptDecisionPinsRecognitionAndDurationSeparately` 现在只出现在 §2 第 45 条与本行**叙述当年那次修正的文字里**，不是活引用；真正被引用的 `theSpeechTrialAdoptDecisionPinsBothConditionsSeparately` 在代码中确实存在。脚本按标识全文匹配，分不清「引用」与「讲这个错名的故事」。**接手方不要为了让脚本归零而去删那段叙述**——那会把一条修正记录删掉。同批复核：台账标识数因本轮新增引用由 141 涨到 191，其余 190 条全部可解析 |
| 回归有效性（变异验证） | 对生产代码施加定向变异，检查是否有测试变红 | 三轮累计。**第 18 条**（前序）：`TeleprompterReadingProgressRestorer` 两次变异，其中只破坏 nil 分支的那次**既有 13 条同套件测试全绿、仅新增用例变红**。**第 24–33 条（本轮）**：有效变异 **79 次**，覆盖台账全部六段——跟随控制器 18、保真门禁与语义检测 12、`RealtimeASRClient` 事件闸门 6、sequence validator 4、存储与舞台 11、回放评估 caveat 7、Python 探针 6、以及若干对照。结果 **47 杀 / 32 存活**；作废 14 次（锚点写错 2、探针缺陷 8、语义等价 2、探针环境错误 6，见第 27、33 条），均不计入。**32 次存活逐个查因**：12 次补回归后转杀掉，20 次判为纵深防御外层、生产不可达或不可观测（§2 第 19、24、25、28、31 条）。新增 12 条回归，其中 **11 条经变异验证**；`longRunsStayCorrectAcrossHundredsOfItems` 经变异验证确认**钉不住内存上限**，只声称它固定长跑后行为不漂移 \|。**第十轮（读法别名，22 次变异）与第十一轮（语音辅助试读，8 次变异）**：每轮都带基线自检与一条已知应杀变异，探针本身先证明有效。别名轮首轮 5 条存活，查因后 4 条补回归转杀掉，1 条（`updatePendingSegment` 清空别名）判为**当前不可达**——两处 `pendingVersion` 都从零重建段落，走不到，按纵深防御保留并在注释里写明不可达原因。试读轮首轮 4 条存活，其中 3 条是**测试盲区**（试读不推进阅读位置、采用闸门、沿用同一套识别配置），补断言后杀掉；1 条（把试读事件也喂给 `followAdapter`）定位为**结构性失效**：`TeleprompterFollowController` 每条接收路径都有 `guard mode == .following`，试读从不进入该模式，控制器会 retire 每个 item。**第十二轮（错误归因与回滚，19 次变异）**：新增路径 3 条、移除路径 3 条、采用回滚 3 条、朗读标注回滚 2 条、原稿回退回滚 3 条、切稿拒绝 2 条、重试保存 1 条、复制兜底 1 条、删除拒绝 1 条，全部被新回归杀死，无存活，详见 §2 第 41–44、46–50 条。**第十五轮（导入拒绝，1 次变异）**：把 `createDocument(title:importedSource:)` 的守卫改回静默 `return`（杀），见 §2 第 51 条。**第十六轮（验收第 3 条补证，10 次变异）**：字号列宽扫描 5 条被杀，1 条**未复现触发条件**（`TeleprompterStageLineLayout` 的尾行兜底分支本机进不去；既不是等价变异，也不是测试盲区，见 §2.2），不计入杀数；「迁移失败保留原数据」4 条全杀（读不动的稿件从列表消失／读不动时删掉原文件／不带失败原因／会话层不再记录）。**第十七轮（零推进不得报成干净结果，4 次变异）**：4 条全部被杀，详见 §2 第 52 条。**同轮续（恢复门槛，3 次变异）**：3 条全部被杀，其中一条复现了本轮真实犯的判据错误。**第十九轮（改范围不得静默丢弃审阅，7 次变异）**：7 条全部被杀，无存活无作废，详见 §2 第 54 条。**累计有效变异 123 次、91 杀 / 32 存活；累计新增 37 条回归**（别名 15、试读 5 条中 3 条为补盲区另 2 条为新增场景、错误归因与回滚 6、导入拒绝 1、字号列宽扫描 1、迁移失败 1、零推进 1、恢复门槛 1、内容范围 3） |
| 第三十轮（失败分母，5 次变异） | 对 `TeleprompterReplayEvaluator` 的失败计数与停顿门槛施加 5 条定向变异 | 5 条全部被杀。**「停顿门槛复用回稿 deadline」首轮存活**——它是本轮新引入的解耦、没有用例覆盖，补 `aStallDuringAnUnrecoveredReanchorWindowStillCounts` 后转杀。另 4 条（去掉逐事件 latch、窗口关闭时不结算次数、分子改回「次数」、恢复时不再释放停顿门槛）首轮即杀；其中最后一条杀的是**本轮自己引入的回归**——它让 41 秒真实素材的错误停顿从 12 掉到 11，283 项单测全绿都没发现，是靠修复前后两份报告逐指标对比才看出来的。详见 §2.15 与 §2 第 57 条。**累计有效变异 128 次、96 杀 / 32 存活；累计新增 41 条回归**（本轮 4 条：拖尾稀释、多次未恢复、停顿门槛解耦、恢复释放门槛） |
| 第三十一轮（零误推进样本上界，5 次变异） | 对新增的零观测 caveat 施加 5 条定向变异 | 4 条首轮即杀（删掉整条、把上界写成常数 1、假设观测 8 小时、只对长素材输出）。**1 条作废**：`let hours = 8` 让 `hours` 推成 `Int`，`.rounded()` 编译不过——按第 27、33 条的规矩**探针缺陷不计入杀数**，改成 `8.0` 后成为有效变异并被杀掉。另一条「让它在已观测到误推进时也输出」由反向对照 `aMaterialWithHarmfulJumpsReportsTheCountNotTheSampleBound` 杀掉。详见 §2.16 与 §2 第 58 条。**累计有效变异 133 次、101 杀 / 32 存活；累计新增 43 条回归**（本轮 2 条：样本上界存在、上界随时长收紧） |
| 第三十二轮（探针证据文件，8 次变异） | 对 `tools/probe_teleprompter_latency.py` 的 `build_evidence`／`probe_condition`／`session_update_payload` 施加 8 条定向变异 | 8 条全部被杀：删掉整个 `condition`、`probe_condition` 报另一种语言、设备标签置空、会话语言与证据语言分叉、commit 往返不做相减、commit 往返恒为 `null`、形状变了不升版本、顶层 `model` 与 `condition.model` 重复。详见 §2.17 与 §2 第 59 条。**累计有效变异 141 次、109 杀 / 32 存活；累计新增 46 条回归**（本轮 3 条：§11.6 条件齐备、commit 往返与音频时长分离、会话与证据语言同源） |
| 第三十三轮（素材远距闸门，5 次变异） | 对 `ScriptAligner.align` 的距离闸门与复核清单的距离列施加 5 条定向变异 | 4 条首轮即杀（删掉闸门、半径放大到 100000、复核清单去掉距离列、把远距匹配并回「对齐不足」）。**「拒绝位置但仍移动 cursor」首轮存活**——最初那条断言盯的是 `intent`, 而两种情况下它都是 `read`, 变的是 `expected_segment_index`；断言改盯真正会变的那一格后转杀。详见 §2.18 与 §2 第 60 条。**累计有效变异 146 次、114 杀 / 32 存活；累计新增 49 条回归**（本轮 3 条：远距不给位置、近距仍给位置、清单显示匹配距离） |
| 第三十四轮（素材关键词闸门，6 次变异） | 对 `ALIGN_MIN_ADVANCE_MATCH_CHARS` 闸门与清单的匹配字数列施加 6 条变异 | **4 条有效全部被杀**（删掉闸门、闸门置 0、关键词匹配仍推游标、清单去掉匹配字数列）。**1 条无效**：游标推进两行被插在 `return` 之后不可达——探针缺陷不是存活，按第 27、33 条不计入，改插到同一块内后杀掉。**1 条存活（M28）是真实覆盖缺口**：给「匹配仅 N 字」分支加上 `segment_index is not None` conjunct（把 reason 顺序改成「远」优先于「证据不足」）无人变红，属「匹配既小又远」的复合情形，已在 §2.19 记为已知边界，不为它编造夹具。详见 §2 第 61 条。**累计有效变异 151 次、118 杀 / 33 存活；累计新增 50 条回归**（本轮 1 条） |
| 第三十五轮（延迟样本数，9 次变异） | 对两个样本数字段、JSON 键、覆盖面判据与措辞分支施加 9 条定向变异 | **7 条有效首轮被杀**（样本数改回事件数、回稿样本数不赋值、JSON 各删一个键、判据改 `<=`、删掉整条 caveat、零样本分支改成非零分支）。**2 条存活是真覆盖缺口，已补测试再杀**：删掉回稿样本数赋值时新夹具里它恰好是 0；判据改 `<=` 时没有任何夹具能做到完整覆盖——跟随控制器从第 0 段起步，标注为第 0 段的位置开不出「到达」，所以默认素材**不可能**全覆盖。补 `reanchorLatencySampleCount == 1` 与反向用例 `aFullyCoveredMaterialReportsNoLatencyCoverageGap`（标注从第 1 段起）后 9 条全杀。详见 §2.20 与 §2 第 62 条。**累计有效变异 160 次、127 杀 / 33 存活；累计新增 53 条回归**（本轮 3 条） |
| 第三十六轮（未匹配不算恢复，7 次变异） | 对无位置分支的窗口关闭、`unmatchedEventCount` 的累加与 JSON 键、以及 caveat 的触发条件与措辞施加 7 条定向变异 | **7 条有效全部被杀**（无位置分支改回关闭窗口、计数不自增、JSON 删键、删掉整条 caveat、caveat 只说「存在未匹配」不说数字、判据改 `>= 0`）。**1 条首轮存活是最该抓住的一条**：把 caveat 的**含义**反过来写成「这些事件已按失败样本计入」，无人变红——原断言只查「caveat 存在且带数字」，而这条 caveat 的全部价值就是那句话，反过来写等于报告主动误导。补逐半句断言（既不产生延迟样本／也不计为失败）后转杀。详见 §2.21 与 §2 第 63 条。**累计有效变异 167 次、134 杀 / 33 存活；累计新增 56 条回归**（本轮 3 条） |
| 第三十七轮（稳定前缀契约，11 次变异） | 对运行时与素材侧两处越界判定、异常可见性与 reason 措辞，以及「按前缀截断」这一被否方案施加 11 条定向变异 | **11 条有效全部被杀**（越界折回 nil 走全文、删掉 guard、不计异常、不离开跟读咬合、按存文本长度校验、放行负数前缀、素材侧删守卫、越界改夹取、reason 并入「对齐不足」、清单不带原始数值、重新引入前缀截断）。**2 条探针作废不计入**：一条 harness 用相对 python 路径而 worktree 的 `.venv` 是符号链接，pytest 未报结果却被读成存活；一条变异本身是 Python 语法错误——**手动单验确认该条其实被杀**，不验就会把假存活写进报告。详见 §2.22 与 §2 第 64 条。**累计有效变异 178 次、145 杀 / 33 存活；累计新增 60 条回归**（本轮 4 条） |

**交接前的最终门禁复跑（第二十四轮，2026-09-29）**：上面各行是开发过程中分轮跑的；为了让接手方拿到**一个当前时点、覆盖整条分支的绿证据**（而不是拼凑各轮旧记录），在最终交接状态（**61 个提交**，HEAD `92fad46f`，已含第二十一／二十二轮的两处视图改动）把三条门禁完整重跑一遍：

| 门禁 | 结果 |
|---|---|
| `swift test --package-path macos/SpeechRailApp` | **275 项 / 16 套件通过**（与会话／模型层历史计数一致） |
| `scripts/macos_app_build.sh --configuration Debug` | **BUILD SUCCEEDED** |
| `scripts/macos_app_build.sh --configuration Debug --test-unit` | **TEST SUCCEEDED**，`test-unit: passed`，exit 0 |

**这一轮复跑补上了一个此前没被点明的证据缺口**：第二十一／二十二轮改的是 `App.swift` 与 `TeleprompterView.swift`——**SwiftPM 与无 `TEST_HOST` 的单测 target 都不编译这两个文件**，所以那两处改动（`⌘⌥V`、`⌘⏎`）从来只有 Debug 构建一条编译证据。此刻三条门禁同时绿，等于明确写下：**视图层改动已编译通过，其余各层无回归**。真实按键与新视觉仍待 U-10 走查（见 §3.2），不在此列。

**交接前的最终门禁复跑（第三十五轮，2026-09-29）**：第二十四轮那次复跑记录的是 **61 个提交**时的状态，与现在的分支相差 50 多个提交，**不能拿它当今天的绿证据**。本轮在第 62 条改动之上把整套门禁重跑一遍，给接手方一个当前时点的记录：

| 门禁 | 结果 |
|---|---|
| `swift test --package-path macos/SpeechRailApp` | Swift Testing **322 项 / 16 套件通过** + XCTest 全部通过（2026-09-29，第四十八轮复跑；第四十轮新增 5 条读法别名相关，第 68 条新增 6 条、第 69 条 2 条、第 70 条 5 条、第 71 条 2 条、第 72 条 1 条、第 73 条 1 条、第 74 条 3 条、第 75 条 1 条）。**计数说明**：各轮的临时探针 `ZZScratchProbeTests.swift` 均已在提交前删除，**交付态下直接跑 `swift test` 就是 322/16**；若工作区里重新出现该未跟踪探针，会多出 1 项 1 套件（323/17），交接方不应把它算进交付 |
| `swift test --filter TeleprompterReplayEvaluatorTests` | **32 项通过**（第三十五轮新增 3 条、第三十六轮再新增 3 条） |
| `scripts/macos_app_build.sh --configuration Debug` | **BUILD SUCCEEDED** |
| `scripts/macos_app_build.sh --configuration Debug --test-unit` | **TEST SUCCEEDED**，`test-unit: passed`，exit 0 |
| `pytest`（探针／素材／operator 文档／user 文档） | **57 项通过**（15 + 36 + 6） |
| `pytest`（**全量**，`PYTHONPATH=<worktree>/src`） | **2735 项通过**，0 失败 0 跳过（第六十轮，2026-09-29 复跑；第六十一轮同日再复跑一次，数字不变——本轮只动了 Swift 侧，Python 侧一条未改；本轮为探针的崩溃恢复补 3 条 Python 回归。**顺带修掉一处 CI 红灯**：上一轮新增的测试显式传 `Path(".")` 触发 `PTH201`，而那轮最后跑的是 swift 与文档门禁、ruff 是在加测试之前跑的——门禁要在最后一步跑。)**修复第 83 条的 teardown 竞态后连跑 5 次全量，均 0 失败**）。**必须显式设 `PYTHONPATH`**，否则测的是主检出的源码（见本节下方更正） |
| `ruff check .` | 全绿 |
| `mypy src` | 154 个源文件无问题 |
| 文档自检（替换字符／表格列数／表格完整性／标识可解析） | **通过**（exit 0，`scripts/check_teleprompter_report.py`）。四项：替换字符、表格未转义竖线、页首计数与自身区间是否自洽、**§4.3 表是否一行对一条**。每个检查器先对自己的坏夹具证明**因正确理由**触发（夹具自带期望消息，空转或答非所问都 exit 2 拒绝解读报告），另配干净夹具证明它不会对正常文档乱报。回归 `tests/test_teleprompter_report_check.py` 15 项。**标识可解析性不在其中**，理由见 §2.36 |
| `python scripts/swift_mutation_probe.py scripts/teleprompter_swift_mutations.json` | **exit 0**（2026-09-30，第七十二轮，变异集 197 条）。基线 799 项全绿且确实跑到测试；`sanity` 变异被杀后才开始解读；**197 条中 154 条被杀、38 条存活、5 条 INVALID**（第七十一轮时为 178／135／38／5，基线 789）。**第七十二轮新增 19 条（`TeleprompterStore`，214 行／28 处逻辑／仅 5 条用例）：首轮 2 杀 / 16 存活 / 1 INVALID**（INVALID 是锚点写错而非产品缺陷），补 10 条回归后 **19 条全杀**，**本轮零新缺陷**。详见 §2.58。**第七十一轮新增 20 条（`TeleprompterPreparationDomain`，608 行，此前 0 条变异覆盖）：首轮 7 杀 / 12 存活**，补 10 条回归后 18 杀 / 1 存活 / 1 条新增的 R21 转杀，**R9 定案为等价变异**；过程中**第 90 条的修复改动使 R19 锚点失效，探针以 `anchor appears 0 times` 中止整轮**——修好锚点后重跑才拿到读数，这正是探针拒绝在半途失效的 spec 上给出数字的机制。详见 §2.57。**第七十轮新增 15 条（`TeleprompterSession`，3348 行，此前 0 条变异覆盖）：7 杀 / 8 存活**，补 4 条回归后 S4／S14／S15 转杀（第 87–89 条），余 5 条判为等价变异（S7／S8／S13）、冗余防御（S5／S6／S11）或生产不可达（S3）；**S2 是真缺口但测试钉不住，留在存活并写明后果**（详见 §2.56）。以下是第六十八轮及更早的记录：**143 条中 109 条被杀、29 条存活、5 条 INVALID**且确实跑到测试；`sanity` 变异被杀后才开始解读；**143 条中 109 条被杀、29 条存活、5 条 INVALID**，每条都带 `expect` 与 `rationale`，声明与实测不符即 exit 1。存活 7 条逐个查因：M1 语义等价、M11 有条件等价（2 条作废），M18 **等价变异**（代码路径穷举，见 §2.47），M23／M28 两条生产不可达的纵深防御，M39 一条生产不可达的纵深防御（**它的击杀读数是假的，凶手已定位**，见 §2.45），N5 **等价变异**（判据集合的包含关系，见 §2.48）。**第六十七轮新增 18 条（`TeleprompterPreparationPipeline`，素材构建管线）：首轮零击杀**，15 条存活 + 3 条 INVALID（修完测试缺陷后 F9 存活、F11／F13 转杀，定案 2 杀 / 16 存活）。但**本轮真正的产出是修掉一处让真检出失效的测试缺陷**：两处 `#expect(count…)` 之后按该计数取下标，断言失败后不停止、直接越界 trap 把测试进程带崩，探针按既定纪律记成 INVALID——**三条已经产生的真实失败就这样变成「什么都没证明」**。改成致命的 `try #require` 之后，`F11`／`F13` 分别以 6 条与 12 条干净失败转杀；全量复扫（66 处 count 断言、10 个文件）又修掉 1 处同型。**同一处修复还把一条旧读数翻了过来**：M38（去掉 grouping schemaVersion 守卫）此前长期记成 INVALID，隔离复跑 3 次稳定 72／73／73 failing，**确定性干净击杀**，已升为 KILLED 并重写 `rationale`（见 §2.53）。第六十七轮曾把其中 15 条登记为真缺口，**第六十八轮逐条查清后该判断被推翻**：补 8 条回归，F7／F12／F9／F3 转杀；其余 11 条判为生产不可达（F1／F8／F14／F16／F17）、冗余纵深防御（F2／F5／F6，解码器侧已拦住）、等价变异（F15、F4）或被 `canRetryStage` 遮挡（F18）。**F5 与第 63 轮 A3 是同一条约束的两个副本**，解码器先跑（见 §2.54）。**第六十六轮新增 23 条（`TeleprompterStageSettings`，含显示行排版）**：20 条被杀；**首轮 12 条存活，且全部落在边界上**——非有限输入、偏移恰好等于末行末尾、刚开口的第一段、以及「差一点点就不该报」的死区。这个文件此前已有 33 条测试，**不是没测，是没测到边**。本轮有三条夹具第一版没咬住（退化宽度与退化字号只钉「拼得回原文」、死区取 0 而非 0.01），并且**既有那条「under 30s -> canCalibrate 为 false」名副其实的用例，是因为只读了第 1 段（29 个单元）而被 `totalUnits >= 50` 先挡住，根本没走到 30 秒那道门**——这是「断言与被保护的分支无关」这一族在四轮里的第四次（第 84 条、A3、D7、E16）。E4 判**生产不可达**（显示行 init 是 `fileprivate`，且每段首行恒从 0 开始），E21 判**等价变异**（`apply` 同步，瞬态 `.custom` 无观察者），E5 为崩溃型 INVALID。**第六十五轮新增 17 条（持久化层 `TeleprompterV2Store`）**：13 条首轮或补夹具后被杀；**首轮 17 条里 12 条存活——`validate` 二十多道守卫此前一条都没有被观察过**，而它平时挡的是被改坏的磁盘文件。补 11 条回归后 4 条存活逐个查因：D14 **等价变异**（0 在 `validateTargetMinutes` 的 1…N 范围检查处已先被拒）、D15 **生产不可达**（`ClosedRange` 构造与解码都会先 trap，**实测 `uncheckedBounds` 同样 trap**）、D11／D17 **等价变异**（`documentID` 全部来自 `UUID()` 或磁盘文件名，从不来自用户输入）。**本轮无新缺陷，真缺陷数仍是第 41–86 条**。**第六十四轮新增 15 条（语音跟随生命周期状态机）**：11 条首轮即杀；**首轮 15 条里 10 条存活，是本分支覆盖最差的文件**（此前 0 条变异覆盖、仅 4 条测试），补 7 条回归后 4 条存活逐个查因，**全部判为等价变异**——但 V7／V8 的等价性依赖跨文件可达性论证（`TeleprompterSession.startPipeline` 只在 `.starting` 窗口内跑，而该窗口内不存在 pump），**没有自动化护栏，已按纪律登记为结构性缺口**（第 86 条由 V5 钉住）。**第六十三轮新增 18 条（舞台交互 5 条、AI 标注解码器 13 条）：舞台交互 5 条全杀，解码器 13 条中 10 条被杀、3 条为崩溃型 INVALID**（第 85 条由 A8 钉住；「模型不得注入读法别名」这条产品边界此前零覆盖，由 A6 补上）。**第六十一轮把 M20／M22 两条真缺口补回归后转杀**，§5 第 13 条随之结掉；**第六十二轮新增 13 条分段器变异，其中 12 条首轮即杀**（第 84 条由 N13 钉住）。本轮探针的自检还当场拦下一条**我自己写的等价 sanity 变异**并拒绝解读全部结果（见 §2.48 末）。**INVALID 现存 5 条（M26、A4、A5、A13、E5）**：均为去掉守卫后 Swift 越界 trap 直接中断整个测试进程，而非某条断言变红，如实单列不计入击杀。**第六十九轮逐条回炉后确认：这 5 条的 trap 全部在产品代码里，属于「崩溃在产品里」那一类，测试断言的恰恰是不许崩的行为**（详见 §2.55）；与 M38／F11／F13 那种「崩溃在测试里、可通过把计数断言改成致命 `#require` 挽回」的是两回事。**M38 曾是其中之一，已于第六十七轮升为 KILLED**——它去掉 grouping schemaVersion 守卫后同样崩溃中断，且**首轮把崩溃记成了「编译不过」**（崩溃报告行里的 `error: Process ... signal code 5` 被编译错误正则命中）。据此给 `classify()` 加了崩溃规则并排在编译规则之前，配 2 条夹具 + 2 条回归：崩溃必须报成崩溃，而失败信息里恰好含 `error: ` 的**真击杀不许降级**，否则真击杀被静默丢掉。第五十七轮新增的 4 条全部被杀（零新缺陷，§2.43）；第五十八轮 12 条中 6 条被杀（零新缺陷、3 条真缺口，§2.44）；第五十九轮 11 条中 9 条被杀（4 处零覆盖已补回归，§2.45）。探针自身的分类规则由 10 条夹具钉住，崩溃恢复另有 3 条回归钉住「脏一次必须重跑、脏两次必须拒绝解读」。**它从不用 `git checkout` 还原**：按内存原始字节写回并比对 `git status` 前后一致|
| `git diff --check` | 通过 |

本轮**没有新增 Xcode warning**，也没有新增未登记的源码文件——第 65 条只改了一个既有 Swift 文件、它的测试与本报告；第 66 条同样只改既有的 `TeleprompterNormalizer.swift` 与两个测试文件、本报告，**没有新增任何依赖**。| 第 68 条 语义风险检测器的主体识别只认 ASCII，中文提词稿上整条静默；且「少一个 pair」被读成「变了」 | 判据第 1 条「主体关系、否定和条件变化**可定位审阅**」与 #109 | `nearestSubject` 两条正则都要求 ASCII 主体，中文主体 ⇒ pair 恒空 ⇒ `subjectValueChanged` **在产品主语言上从不触发**，而这条检查此前在报告里零次被提及、零条中文测试。比较方式又把两张 pair 列表做全等，于是删掉一个逗号让序数失去分句起始锚点时，**纯标点改写被判成主体数值互换**。四种更宽的中文主体规则全部被语料否掉（`的` 前锚定 350 处大半是量词碎片「稿/我/帧」，天干标签被 `未`「不是」与 `子`「子任务」撞掉，去掉后归零，要求平行标签则 `稿/我/与帧` 全部存活），**只保留语料支持的序数标签（2330 文件 38 处，逐条可读）**——误报会把 block 打成 `.unresolved` 拦下一次自动朗读，窄而准优于宽而脏 |


**第四十轮更正一条此前写错的既有状态**：本节原来记着「在**本分支**上跑全量 `pytest` 有 2 条失败（`test_serve_uses_one_shot_startup_claim`、`test_model_status_marks_missing_artifacts_without_exposing_paths`），原因是本分支的 Python 侧落后于 main」。**这个归因是错的。**真实原因是 **venv 的解释路径**：主检出的 `.venv` 里 `speechrail` 解析到**主检出的 `src/`**，不设 `PYTHONPATH` 时 pytest 测的一直是**主检出的源码**，不是本 worktree 的；那两条失败来自主检出当时未提交的并行改动。**把本 worktree 的 `src` 放在 `PYTHONPATH` 之前后，全量 `pytest` 2700 项全绿**（0 失败 0 跳过 0 错误，2026-09-29 第四十轮实测），那两条也单独复跑通过。

**接手方请把这条当成复跑方法记下来**：本 worktree 的 `.venv` 未安装 `dev` extra，必须用主检出的 venv **并显式设置** `PYTHONPATH=<worktree>/src`（§3.1 表里那条「探针回归」的注意事项同源，只是当时只写在了单文件运行上）。不设它得到的任何 Python 结论都指向错误的源码树——**本轮之前至少一条「既有失败」是这样来的**。分支与 main 的 Python 侧确实仍有差异（`git diff main..HEAD -- src/` 为 7 个文件、29 增 328 删，集中在 `model_store.py`／`preflight.py`），合并前仍需 rebase 再复跑，但那与上述两条失败无关。

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
- Issue 关闭已按 2026-09-28 的用户授权执行：#104–#114 现均为 CLOSED（关闭前逐条留下复审评论写明精确剩余缺口，见 §4.2）。**关闭不代表验收通过**——评论里写明的缺口不随关闭丢失。分支已推送，PR #115 开放中。

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
| #108 | JSON 明确版本演进；错误不标 PASS；历史结果不重写 | 满足 | 探针输出 `schema_version: 4`（第三十二轮因证据形状变化升版：新增 `condition` 与 `completed_after_audio_ms`，顶层 `model` 移入 `condition`）；任何 `ProbeInputError`／`RealtimeProbeError`／队列溢出／超时都走退出码 2 且不落报告（`main()` `tools/probe_teleprompter_latency.py:404-427`）；输出文件已存在即拒绝覆盖，历史结果不重写（同上 `:404-405`）；`test_cli_reports_queue_overflow_as_input_error` |
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

#104–#114 已于 2026-09-28 全部关闭。此后按「重读自己写的代码」这一路继续审查，**在已关闭 issue 的交付范围内又找出 50 个真缺陷**（§2 第 41–90 条）。这不推翻关闭决定本身——关闭的判据是「该 Issue 正文自己要求的证据是否具备」，而这些缺陷是正文没写的工程质量问题——但它确实说明**关闭时依据的证据是不完整的**，接手方应当知道：

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
| 第 59 条 延迟探针的证据文件不带 §11.6 要求的语言与设备，形状从无测试 | 判据第 4 条（证据可信）与 §11.6 指标定义／#108「JSON 明确版本演进」 | 语言硬编码在会话配置里却不进输出，设备根本没采集；`completed_ms` 把整段音频时长算进「延迟」。根因是探针 12 条旧用例没有一条断言证据文件形状 |
| 第 60 条 素材构建器无远距闸门，12 个字换到 7 段外的阅读位置且复核看不见 | 判据第 4 条（证据可信）与方案 F-04（P0）／§11.7 跟随 P95 门槛 | 匹配 `ratio = 1.0` 恰好让 `reason` 不被赋值，标注不进人工清单；`expected_segment_index` 是回放延迟的唯一依据。Swift 侧有 `localAdvanceTokenRadius` 挡着，素材侧没有对应的一道 |
| 第 61 条 F-19「不仅凭关键词推进」在素材侧没有对应闸门 | 判据第 4 条（证据可信）与方案 F-19 | 两字碎片只要出现在稿件里就是 `ratio = 1.0`，可复现地把位置推到下一段。**但真实素材上影响为零**（1–3 字匹配推进 0/160 字，推进事件最小匹配 5 字）——本条按「逻辑成立、实测惰性」记，不与第 60 条同量级 |
| 第 62 条 回放报告的延迟分位不带样本数，且「标注给了位置却没量到」时报告沉默 | 判据第 4 条（证据可信）与方案 §11.6「所有延迟报告 P50／P95、**样本数**、语言、设备、模型与运行条件」 | `metrics` 里没有任何字段说明分位由几个样本算出，而顶层 `sample_count` 是**事件数**——真实素材上 82 对 4，并排放着等于替身顶着真名。探针侧一直带 `count`，回放侧是另一半。沉默面：caveat 判据问「素材问没问」，不问「问了答没答上」，7 个标注位置只产出 4 个样本时报告一字不提 |
| 第 63 条 没有阅读位置的事件被当成「跟随已恢复」，且未匹配数量从不单列 | 判据第 4 条（证据可信）与方案 §11.6「超时和**未匹配**数量单列」、§11.6 指标表「回稿恢复延迟＝到**恢复可靠跟随**」 | `.read` 分支无 `expected_segment_index` 时直接 `endReanchorWindow()`——把「不知道」读成「好」。三段夹具复现：脱稿后两个对不上稿的事件走过 6 秒，报告 **0 次超时、0 个失败样本**。真实素材插桩：22 次窗口释放里 **只有 4 次是真恢复，18 次是对不上稿**。停顿数 12 → 11 是修正不是回归（少掉的那次只因同刻一个无位置事件提前释放了停顿门槛，而门槛正是为防这个） |
| 第 64 条 稳定前缀越界被当成「没有稳定前缀」，于是拿仍在修订的全文去对齐 | 判据第 4 条（证据可信）、目标第 3 项「稳定证据丢失」与方案 §3.6／F-15「第 694 行：记录契约不一致并暂停自动推进，不静默夹取成合法」 | 运行时把越界折成 `nil` 后走 else 分支拿**全文**对齐——契约一出问题就改用最宽松那条路，且异常从外面完全看不见。素材侧 41 个 snapshot 里 40 个带 `stable_prefix_codepoints` 却被完全忽略，改用尾部 24 字的本地启发式 |
| 第 65 条 保真门禁的单位是枚举式的，没列到的单位两侧都不产生原子，「换了量级」被读成「什么都没改」；同一行又把纯排版的空白差异算成受保护字面量被改 | 判据第 4 条（证据可信）与方案第 157 行 F-01「语义单位检查」、第 397 行「**单位和量级不得脱离数值**」、§11.6 误报率指标 | `50 瓦`→`50 千瓦`、`3 米`→`3 厘米`、`2 升`→`2 毫升` 两侧原子都是 `["50"]`／`["3"]`／`["2"]`，序列相等即放行，而这道门禁对 `.speak` 块是**硬拒**。反向一处：`\s*` 把空白吃进原子，`50 元`→`50元` 被判成改动，无损改写被送人工。清单本身被语料实测砍掉一半（安／克／处／只／升／页／支 会组词）。**真实素材上测不到**（`script_b.txt` 无阿拉伯数字），证据来自 959 文件语料探针 |
| 第 66 条 读法别名的数值门禁在量级上是空的：`3万`→`3`、`三万`→`三千` 都能通过 | #110 读法别名的验收项「读法只能改发音，不能改数值」 | 门禁比的是两侧数字指纹，强度恰好等于 canonicalizer 认数字的能力：`.spokenUnit` 要求中文数字后**必须有单位后缀**，于是 `三万`／`五十` 根本不产生数值单元；arabic 侧从不认中文量级词，`2万元` 被切成 `2`+`万元` 而 `chineseInteger("万")` 返回 **0**，规范形式是 `["2","0元"]`。假放行 4 类、假拒绝 3 类（同一个数被拒），**真实素材上完全惰性**（8 个数值单元全走 `spokenUnit`，无一个含量级词） |
| 第 67 条 服务端 ITN 把量级当数值，改坏的是句子而不是数字 | 判据第 1 条（稿件可信）与判据第 4 条（证据可信） | `_chinese_to_int` 只给 `十` 做了「量级前无数字时补 1」，`百/千/万/亿` 没有，于是量级单独出现时算出 **0**：757707 行语料上 **165 处**，压倒性多数是 `百分之`／`百分比`／`百分点`／`百分号`／`百分位` 被读成 `0分`，另有 `万元`→`0元`、`万亿元`→`0元`、`零点`→`0点`。**同时量到裸量级取错值**：`数十秒`／`几十秒`／`数十万个` 读成 `10秒`／`10个`。这条路径的产物同时喂给 batch、realtime 与 `voice_quality` 的文本比对，而 `withSemanticReview` 里任何 finding 都会把 block 打成 `.unresolved`，所以被改坏的句子既进不了自动朗读，也进不了提词器对齐。**这一轮同时否掉了「换 cn2an」这个方向**：它把词内的 `一` 也转（`统一`→`统1`、`一共三十人`→`1共30人`），wetext 的 ITN 做单位本地化（`米`→`m`）与本项目回贴原稿对齐的目标相反 |
| 第 68 条 语义风险检测器在中文提词稿上整条静默 | 判据第 1 条「主体关系、否定和条件变化可定位审阅」 | `nearestSubject` 两条正则**都要求主体是 ASCII 字母**，而 `findings` 要求两侧 pair 都非空，于是**纯中文主体 ⇒ pair 恒空 ⇒ `subjectValueChanged` 一次也不会触发**——承载这条验收的检测器在产品主语言上整条失灵，且**零条中文测试、报告里零次提及**，看上去是已交付的能力。探针实测：ASCII 主体报 `subject_value_changed`，`cn-甲乙`／`cn-单主体`／`cn-第N批` 三种中文主体全部 `[]`。四种更宽的中文规则全部量过并否掉（`的` 前锚定 350 处命中多是量词碎片、分句末裸汉字 run 10007 处被功能词占满、平行标签要求被平凡满足、天干标签被 `未`／`子` 撞掉），**只保留序数 `第N`+量词这一种（38 处逐条可读）**，量词表与数字表严格等于语料实测集合。**同一轮还修掉一个由它暴露的既有比较缺陷**：两张 pair 列表全等会把「少掉一个 pair」读成「变了」，删一个逗号就判成主体数值互换，改为只比较两侧都出现的主体 |
| 第 69 条 否定标记里的单字 `未` 把「未来」读成否定，一次无害改写拦下一次朗读 | 判据第 1 条与判据第 3 条「安全审阅 AI 修改」（安全不能以误报率换） | `未来的计划不变` → `将来的计划不变` 判成 `negation_changed`，block 被打成 `.unresolved`。**文档语料里只占 1%（44/4495），但提词稿是口语稿，「未来→将来」是中文改写里最常见的同义替换之一，真实命中率更高**，而每次误报的代价是拦下一次自动朗读。7 个否定标记里只有 `未` 是单字，语料另量出 4086 处 `未+动词` 与 247 处 `尚未X` 都是真否定——**改成枚举正是第 65 条否掉过的做法**，改用后继字守卫（`来`／`必`），`未知`（362）有意保留 |
| 第 70 条 数字与单位之间的空格把 token 切开；两条数字规则各维护一张已分叉的单位表 | 判据第 2 条「远处短语不得擅自跨句跳转」的同一处——**该位置根本匹配不上** | 语料里「数字+CJK 单位」**98%（6650/6788）带空格**，而识别器转写不带。提词稿多从 markdown 改写而来，正是带空格的那一类，于是**脚本里几乎每个数字都落在不同 token 流上**，跟随在那些位置永不推进。`.arabic` 规则缺 `\s*` 只是表层；**根因是两条规则各维护一张单位表且已分叉**（`.arabic` 有 `年`、`.spokenUnit` 有 `台/条/项/字`），`三年` 因此匹配不到任何东西。合成一张表后仍按第 65 条的规矩量成员：`条→件`（条件 500）、`字→段`（字段 883）、`页→面`（页面 807）、`版→本`（版本 1072）等 12 类被否掉，`台` 与 `5 台` 的缺口**明确记录为已量过、不修** |
| 第 75 条 `点` 移出单位表，与服务端对齐（**产品判断，非扫描所得**） | 判据第 1 条与判据第 4 条「证据可信」 | 本仓 109 处 `X点` 压倒性是普通词（`这一点`／`短一点`／`第二点`），服务端 §2.25 早已在自己的语料上量过同一件事（86 处里 46 处是普通词）并写下「删单位只会少转，不会改坏句子」。留着 `点` 会把 `这一点` 读成 `1点`——**凭空造出作者没写下的数并塞进数值指纹**；删掉只是少转。且留着也换不来时间读法：`七点半` 得到的是 `7点`+`半`，仍是数量不是钟点。**代价已写明**：裸钟点 `三点`／`十点` 不再是数字。改后 Swift 与服务端在 `这一点`／`第二点`／`三点五`／`七点半` 上一致。**`7点40分` 仍被读成 `7.40分`，且这一条修不了也不该由它修**——错读来自 `.spokenDecimal` 的十进制点，服务端同样返回 `7.40分`，#95 认证里模型 ASR 也独立犯过同一个错 |
| 第 76 条 服务端 ITN 把中文量级粘在它前面的阿拉伯数字上，`50万元` 读成 `5010000元`（**与 Swift 侧第 66 条同一个 bug，服务端正则一直没动**） | 判据第 1 条「稿件可信」与判据第 4 条「证据可信」 | `_UNIT_RE` 后行断言 `(?<![数几零一二两三四五六七八九十百千万亿])` 挡住「紧跟中文数字起匹配」，**却漏了 ASCII 数字**。`50万元` 里 `万元` 单独匹配，`chinese_to_int("万")=10000` 直接拼在 `50` 后 → `5010000元`，错两个数量级；`10亿元`／`5万美元`／`30亿人`／`3万个`／`2万元` 同形。识别器把语音归一成阿拉伯数字时产生的正是这个形状，而 `20万台`／`1000公里` 从未被改写、说明服务端本意就是「已写成数字的不再动」——后行断言漏了 `0-9` 这一格。**影响面比前 35 条都大**：不在提词器归一器里，而在**已上线服务路径**上——batch／realtime 转写与 `voice_quality` 比对全吃这份产物，且 `withSemanticReview` 只把 block 打成 `.unresolved`，不会因「数字大了 100 倍」报警。修法＝后行断言补 `0-9`（一个字符类）。**暴露面证据如实写明**：本仓语料触发该形状仅 7 行，且全部是本报告与注释里描述此 bug 的文字本身，**语料零证据**，论证靠结构性理由。**这一轮同时更正一次自我误判**：上一轮拿 30702 行文档喂 `apply_light_itn` 统计「改写 1692 行」是**假警报**——该函数只作用于 ASR 结果与 `voice_quality` 比对、从不作用于用户文档，而中文口语「买了一个苹果」的 `一个`→`1个` 正是 ITN 该做的事，**拿文档当转写稿量 ITN 得到的全是假阳性**。变异 4 条全杀（撤回 `0-9`、`[0-8]` 窄化、去 `几`、去 `数`），其中 `[0-8]` 存活促发后补 `9亿元`／`7万吨`／`8千万个` 三条 |
| 第 77 条 报告证据表里的「文档自检 全绿」没有对应实现，而报告里真的有两个坏字符 | 交付完整（报告与回退说明）与判据第 4 条「证据可信」 | 证据表里 `文档自检（替换字符／表格列数／标识可解析） \| 全绿` 与 `pytest`／`ruff`／`mypy` 并列，**但仓库内没有任何检查替换字符的工具或测试**（`grep -rn "fffd\|FFFD\|替换字符" tools/ tests/` 只命中英文词 `replacement` 的无关用法）——这一栏从来只是一次手动 `grep`，却被写成了可复现的门禁。**而它自己就没做对**：`1258eb03`（第 75 条，本会话自己写的）在 §2.33 留下一处 `第` 坏成两个 U+FFFD，那一轮照样「跑门禁 → 全绿 → 提交」。**一个查不到出处的「全绿」比没有这一行更坏**，已撤下该行 |
| 第 78 条 注释里点名的回归从来不存在，报告照抄了同一个名字 | 判据第 4 条「证据可信」与目标第 1 条「远处短语不得擅自跨句跳转」 | `TeleprompterFollowControllerTests.swift` 讲「向前越位」的注释写「既有回归钉住了……与整句复述不得倒退（`distantFullSentenceCannotDragTheViewportBackwards`）」，**该名字在全仓 0 个 `@Test func` 与之同名**，`git log --all -S'func …'` **返回空**——**不是被改名的旧测试，是从未定义过**。真实回归是 `rereadDoesNotRollBackAcrossDistantParagraphs`，其断言原文「远处整句复述不得把已确认位置拖回前面的段落」与注释意图完全一致。**覆盖没丢，丢的是指针**；报告第 714 行照抄了同一名字。**后果是让人以为缺了、其实不缺**。修法：两处改指真实测试 + `tests/test_teleprompter_swift_evidence_refs.py` 4 条回归 |
| 第 79 条 报告自己把 XCTest 计数从 389「更正」成 171，而 389 恰恰是可复现的那一个 | 判据第 4 条「证据可信」与交付完整 | §3.1 写着「**更正**：此前写的『XCTest 389 项』无法复现，实测为 171 项」。本轮全量实测 `Executed 389 tests, with 0 failures` **稳定复现**，171 复现不出来；swift-testing 为 `Test run with 322 tests in 16 suites`（本轮补 2 条后 324），324 + 389 = 713 与探针数到的通过条数逐条对上。**一条「更正」把正确的数字改成了错的**，与第 77 条同族——复现不出来的更正比没有更正更坏，它让接手方连「该信哪个」都要重新判断。根因同为**凭印象改数字、没有当场复跑**。已改回 389 |
| 第 80 条 试读建议时长有两个事实源，其中一个是死的 | 判据第 3 条与交付完整（证据与实现不得各说各话） | `suggestedTrialDurationSeconds = 60` 自 `6b752f5b` 引入后**全仓无人读取**（`rg suggestedTrial` 只命中声明本身），而 sheet 显示的「建议 60–90 秒」是**另一处硬编码字面量**；变异 M5 把它改成 30 时**全量 712 项无人变红**，证明两者从未连在一起。方案 `2026-09-20-ai-teleprompter-final-spec.md:575` 写的是 60–90 秒，**区间来自方案，实现只留了下界**。已修为 `suggestedTrialDurationRange: ClosedRange = 60...90`，文案由 `trialGuidanceText` 生成、sheet 引用它，并补回归钉住；用户看到的文字不变 |
| 第 81 条 校准倍率区间外的取值没有任何回归 | 目标第 1 条「稿件可信」与判据第 4 条（同一处夹取要么被钉住要么等于没写） | M4 把下界 `minimumCalibrationFactor` 从 0.5 放到 0.0，**全量 712 项无人变红**：`estimateDuration` 里 `min(max(calibrationFactor, minimumCalibrationFactor), maximumCalibrationFactor)` 从未被喂过区间外的值，而倍率来自试读实测。补的回归**钉夹取后算出的秒数**（220 汉字自然档 ⇒ 基准 60 秒 ⇒ 30／120），**不是「等于边界值」**——后者在边界被改动时两边一起动、永远成立 |
| 第 82 条 两张中文数字表已经分叉，对齐器那张少了「两」；裸中文数字恰好是唯一用到它的场景 | 目标第 1 条「稿件可信」与判据第 4 条（同一份事实只能有一张表） | `TeleprompterAligner.digits` 与 `TeleprompterCanonicalizer.chineseDigits` 各一份，**后者有 `"两": "2"`、前者没有**——第 70 条在数字表上原样重演，当年只修了单位表。**可达性已实测**：归一化只转写「数字 + 已登记单位」，所以 `两难`／`这里是两`／`第三季度` 里的数字原样活到对齐器（`两难` → `["两","难"]`），那张表是它们与阿拉伯数字唯一的等价来源；`这里是2难` 对上 `这里是两难` 原来只有**置信 0.8**。**修法是删掉第二张表而不是补一个字**——`equivalent` 改用 `chineseDigits`，两张表在结构上不可能再分叉。补三条回归（含反向的「七」不得等价于「8」），变异 M9／M12 分别被杀 7 条与 18 条 |
| 第 83 条 共享 realtime 契约测试的 teardown 竞态，让「全量 pytest 全绿」这条证据不可靠 | 判据第 4 条「证据可信」与交付完整（**证据本身不得间歇失效**） | **不属于提词器交付范围**，但它动摇的是本报告引用的那条全绿证据，因此一并记在这里。本轮跑全量时 `test_openai_append_commit_produces_transcription_completed` 失败一次（`assert len(factory.released) == 1` 实得 0），**单独复跑 5 次全过**、下次全量又全绿，1/2 的间歇率与行为变更无关。释放在应用侧任务里完成，断言紧跟 `with` 退出，偶发早于释放完成；**同一文件里早已有一处带 deadline 的等待写法**，其余四处仍是立即断言。已统一到 `_wait_for_releases` 助手。**修复后连跑 5 次全量 2728 项 0 失败**，但 1/2 的间歇率无法用 5 次全绿证伪——**只做到「诊断与修法一致、不再复现」，不宣称已证明根因唯一** |
| 第 71 条 全角数字与全角百分号从数值保真闸旁边绕过去，`百分之５０` 被读成「100 分」 | 判据第 1 条「数值、单位、正负号及重复内容变化不得静默通过」与判据第 3 条「位置保持」 | `.percentage`／`.spokenDecimal`／`.arabic` 三条规则的数字类只写 `[0-9]`、百分号只写 `%`，而同一层的 `TeleprompterProtectedAtom` 早就写的是 `[0-9０-９]` 与 `%\|％`——**两处规则对「什么算一个数字」已经不一致**。后果不是排版难看：`５０` 匹配不上就被切成 `5`/`0` 两个单字，**数值指纹里一个数都没有**，保真闸再也看不见它；`％` 匹配不上时没有规则接住，裸量级规则接手把 `百` 读成 100，**50% 变成「100 分」**——第 67 条那类量级缺陷从全角这条缝里又钻进来一次。语料 22 处全角数字、文档 0 处、13 行含全角语料仅 3 行输出改变（全角折半角对数字是 1:1 等长替换，**旧代码不一致的恰恰是多位数字，单个数字本来就被 `fold` 折过**）。变异 M8 另暴露一处真缺口：区间长度若改用 canonical 值的 `value.count`，`2万元`→`20000元` 的区间会越过数字本身锚到后面的文字上，**314 条既有测试无一会红** |
| 第 73 条 口语小数不带单位组，同一个数量写成两种数字就对不上 | 判据第 1 条与判据第 2 条「跟随可控」 | `.arabic` 的规则带单位组、`.spokenDecimal` 不带，于是 `三点五秒` 规范成 `3.5`+`秒`、而 `2.5秒` 是一个 token——**同一个数量写成阿拉伯数字还是中文口语数字，得到的 token 流不同**。探针上 12 个单位形状无一例外全部拆开。**这是同一缺陷家族的第三次出现**（第 65 条单位枚举、第 70 条两张表漂移、第 73 条规则带不带单位组），共同形状是同一个概念在几处各写一遍、没有一处负责说「这就是全部」。修法是复用第 70 条已合成的 `unitAlternation` 而非新配一张表。语料差分 30702 行只有 4 行变化。**本条没有修好 `7点40分` 的错读**（改前就存在），只是把两个 token 并成一个，且未制造假放行（`7.40分` 与 `7.410分` 仍不等） |
| 第 74 条 保真门禁漏掉 canonicalizer 认得的五个单位，单位改写全部静默放行 | 判据第 1 条「数值、单位、正负号及重复内容变化不得静默通过」 | `TeleprompterCanonicalizer.unitSuffixes` 27 项、`TeleprompterProtectedAtom` 单位组 60 项、服务端 `_UNIT_RE` 16 项；**服务端的 16 项是 canonicalizer 的严格子集**，而 **canonicalizer 有 5 项（`分/号/岁/楼/点`）是门禁没有的**。这 5 项之间的每一次互相替换都产生完全相同的原子列表、直接通过硬门禁——`10 分` 改成 `10 号` 用户听到的是另一个东西。31 个单位两两替换实测：**静默放行恰好 20 对全部落在这五个之间，反方向误拦 0 对**。**根因是第 70 条把 canonicalizer 内部两张表合成一张时，没有把门禁接到那一张上**。修法除补表外还加了不变量测试直接读那张表（为此把它从 `private` 放宽到模块内可见），下一次只改一边会立刻变红。变异 R7（把 `分` 排到 `分钟` 前）首轮存活且是真缺口——代码注释里「`分钟` 排在前面所以赢」是承重却无人保护的一句话 |
| 第 72 条 口语小数的点前字符类漏了 `两`，`两点五` 被读成「两点钟」 | 判据第 1 条「数值、单位、正负号及重复内容变化不得静默通过」 | `.spokenDecimal` 的点前类 `[零一二三四五六七八九十百千万]` 漏了 `两`，而 `chineseDigits` 认它、服务端 `_CN_NUM_RE` 把它列在首位。规则匹配不上就由 `.spokenUnit` 接手——**而 `点` 在单位表里**——于是小数被读成钟点：`两点五` → `2点`+`五`、`三点十四秒` → `3点`+`14秒`。与第 67 条同形：完备规则外观下的枚举式遗漏，且漏掉的那一个让整条规则失效、把文本交给另一条规则按错的读法处理。语料基线：口语小数 13 处 vs 阿拉伯小数 15784 处（约 1:1200）。**语料差分 0 行差异，而那不叫无影响、叫语料看不见它**——13 处口语小数里没有 `两点五` 这个形状。变异 N2／N3 首轮存活且**都不是等价变异**（1170 条小数矩阵上各改变 72 条行为），补断言把成员边界钉成「与服务端逐字一致」后转杀 |

| 第 84 条 分段器把略超软上限的句子在句末留下一个只含「。」的段 | 判据第 2 条「跟随可控」与判据第 3 条（阅读位置与显示单元） | 软上限 60 一旦被越过，`boundedRanges` 的第一段正好停在句号前一个字符，句号成为独立尾段——**每个超长句子末尾都多出一个几乎空白的舞台行**，而这个段在对齐器眼里永远匹配不上（canonicalizer 对「。」产出 0 个 token）。实测 61／62／63／70／121／200／500 字的中文句子无一例外。**既有那条 `testLongLatinIdentifierIsNotSplitAtTheSoftTarget` 的素材恰好是 61 字，它产出了这个缺陷却只断言标识符没被切断**——第 78 条的同一次复发，这次是回归存在、名字正确、也真的绿了，只是它断言的那件事与脚下的缺陷无关。修法：尾段若不含文字数字就并回上一段 |

| 第 85 条 含长于 180 字单元的稿件，AI 朗读提示必然失败且被报成「AI 失败」 | 判据第 1 条与判据第 4 条（失败要指向真实原因） | 解码器对每组标注校验 `text.count <= 180`，而 `text` 由**模型拿到的单元**原样拼出。分段器的 60 字软上限对中文不生效（第 84 条与 §2.48），500 字中文稿因此是一个 499 字单元，模型无论返回什么都超限——**这条路径对该稿件不可满足**。`analyze()` 抛出后 session 走 `catch` 返回 `aiFailureMessage`，于是**模型返回完全合法的结果，界面却报 AI 失败，读者重试多少次都不会成功**。实测边界正好在 180（120／180 成功，181／300／500 失败）。修法：这道上限是为阻止模型**合并**多个单元，单个本来就超长的单元不构成合并，故仅在恰好覆盖一个单元时豁免，并同步改提示词；合并仍受约束（两个 120 字段落合成一组照样被拒） |

| 第 86 条 空的停止失败原因被记成停止成功 | 判据第 2 条「跟随可控」与判据第 3 条（状态要与设备事实一致） | `markStopped` 的 `if let failureReason, !failureReason.isEmpty` 让空串失败原因走「停止成功」分支，状态落到 `pendingStopDestination ?? .off`——**读者看到麦克风已释放，而设备可能根本没有**。`.stopFailed` 的文案是固定字符串、真实原因从不显示，因此也没有信息层面的兜底。修法改按可选本身判断并把 fail-closed 的理由写进注释（注释是承重的）。本轮 7 条新回归钉住这一处及其邻接时序（迟到回调、重复停止、设备报错期间停止在途） |
| 第 87 条 按下暂停后「手动浏览中」要等排空跑完才出现 | 判据第 2 条「跟随可控」 | `requestVoiceStop` 里的 `enterManual()` + `syncFollowState()` 是同步交付给界面的，读者按下暂停那一刻状态条就必须已切到手动。去掉后，排空与关台（最多 8 秒）期间 `followState`／`followStatusText` 一直停在「跟读咬合」，而麦克风其实已经在关。回归用 `drainGate` 卡住排空，**在停止仍在飞行时**断言，钉的是同步语义而不是收尾后的最终状态 |
| 第 88 条 关台令牌可被第二次请求换掉，舞台从此再也打不开 | 判据第 2 条「跟随可控」（舞台生命周期） | `stageCloseToken` 是一次性的：窗口关闭委托与菜单里的「关闭」可能都到一次。第二次 `beginStageClose()` 若换掉令牌，第一次的 `finishStageClose()` 就在 `stageCloseToken == token` 处提前返回，`stageCloseToken` 永不清空、`isClosingStage` 恒为真。回归直接断言第二次 `beginStageClose()` 必须返回 false |
| 第 89 条 「结束当前会话」不会把跟读收回手动 | 判据第 2 条「跟随可控」与判据第 3 条（状态要与设备事实一致） | 该路径走 `coordinator.stopCapture` → `stopper` → `stopCapture()`，**不经过 `requestVoiceStop`**，把跟读收回手动是 `stopCapture()` 自己的职责。少了那一步，采集已释放而状态仍停在「跟读咬合」，且 `saveProgress()` 落盘的 `mode` 也是 `.following`——**重开时按跟读态恢复**，是本轮三条里唯一跨会话留痕的。回归走 coordinator 这条真实路径断言 |
| 第 90 条 两套时长估算对同一段文本给出相反的确定性结论 | 判据第 4 条「证据可信」，与第 63 条同族 | `TeleprompterDurationEstimator`（会话／素材管线，18 处调用）与 `TeleprompterTimingPolicy.estimateDuration`（舞台设置／内容选择／试读，5 处调用）是两套并行实现，档位、区间系数与校准夹取完全一致，**只有 URL 判定不同**：前者按「ASCII 标点里出现 `:` 或 `/`」，后者按正则（`https?://` 前缀或 `www\` 前缀）。于是 `www.example.com`（既无 `:` 也无 `/`）在会话侧拿到**可信点估计**，同一时刻设置侧说「不确定」——**含网址的稿件拿到了一个假装量出来的时长**，而按网址逐字符念恰是最不可预测的一类文本。修法只补 fail-open 那一侧：令前者成为后者的超集；反向搬运会让三处 sheet 对同一段文本从「不确定」变「确定」，属产品行为变更，已在注释里写明不对称是故意的、待产品拍板 |

**给接手方的判断**：这五十个缺陷的共同形态是「**先改状态、后可能失败，而失败路径没有把状态放回去**」，加上「**把多个原因压成一个返回值或一句文案**」，以及「**拒绝之后仍然走成功路径的显示分支**」（第 51 条独有）、「**该报警时沉默**」「**该测量时沉默**」「**该确认时直接做**」（第 52、53、54 条独有）、「**分子分母不同单位**」（第 57 条独有）、「**零观测时报成达标**」（第 58 条独有，与第 52、53 条同族）、「**证据文件本身从不被断言**」（第 59 条独有）、「**生成证据的工具没有对应那道闸门**」（第 60 条独有）与「**匹配质量与推进量脱钩**」（第 61 条独有：两字碎片拿到 `ratio=1.0` 便足以推动游标，与第 60 条的「远距」是同一处判断的两个独立闸门）与「**分位与它的分母走散**」（第 62 条独有：分位由 4 个样本算出，却与写着 82 的 `sample_count` 并排——**替身顶着真名**，且「没量到」的判据问的是素材问没问、不问问了答没答上，与第 58 条的「零观测时报成达标」同族）与「**把『没有证据』读成『证据表明没问题』**」（第 63 条独有：标注说这是正常朗读却没有阅读位置，这类事件对「跟随有没有跟上」不提供任何证据，却被当作恢复结算掉——真实素材上 22 次窗口释放里只有 4 次是真恢复，18 次是「读不懂」）、「**契约出问题时改用最宽松那条路**」（第 64 条独有：稳定前缀越界被折成「没有稳定前缀」，于是拿仍在修订的全文去对齐——比「暂停推进」更宽松，方向正好反了）与「**该拦的没拦，不该拦的拦了**」（第 65 条独有：保真门禁的单位组是枚举式的，没列到的单位两侧都不产生原子，于是 `50 瓦`→`50 千瓦` 读起来等于没改；同一行的 `\s*` 又把 `50 元`→`50元` 这种纯排版改动算成受保护字面量被改——**同一道门禁上漏报与误报同时存在**，而 §11.6 只规定了误报率指标，没有规定单位覆盖率）与「**门禁的强度等于它认得出的东西，两边都认不出就等于没有门禁**」（第 66 条独有：读法别名的数值门禁比的是两侧数字指纹，而 `.spokenUnit` 只在中文数字后有单位后缀时才识别，于是 `三万`／`五十` 根本不产生数值单元——`3万`→`3`、`5千`→`5`、`三万`→`三千` 全部放行，两个空指纹是相等的；与第 65 条同族，但落在另一道门禁上，且这一道连误报率指标都没有）。与「**同一件事在两个地方各信一次，两边都以为对方做了**」（第 70 条独有：保真门禁在第 65 条就承认 `50 元`≡`50元`，对齐器却仍按字面把空格切开——**枚举与切分规则散落多处时，没有一处负责说「这就是全部」**，于是每处都正确、合起来不成立；与第 65 条同族，但那一处是枚举漏项，这一处是**两份枚举各自漂移**）与「**为「不误报」把「报得全」让掉，代价记在没人看的地方**」（第 69 条独有：安全审阅一旦误报，拦下的是**每一次朗读**而不是某一次错误——而文档语料只占 1% 的命中在口语稿里是常见改写，**语料占比低不等于线上影响低**；与第 68 条同族，一个漏一个误，都在同一个探测器上）与「**检测器在产品主语言上整条静默，而报告里零次提到它**」（第 68 条独有：语义风险检测器承载验收第 1 条的「主体关系变化可定位审阅」，而它的主体识别只认 ASCII 字母，于是中文提词稿上 `subjectValueChanged` **一次也不会触发**——既没有中文测试，报告里也没有一次提及，**它看上去是已交付的能力**；同一处还把「pair 少了一个」读成「数值变了」，纯标点改写因此被拦下送去人工——**证据缺位与判定过宽叠在同一个函数里**）与「**把一处在服务端早已做过、Swift 侧一直没做的判断当成新发现**」（第 75 条独有：`点` 该不该是单位，服务端第 67 条就基于自己的语料决定过并把理由与代价写进了报告，Swift 侧却一直没有跟上——**同一个仓里两套数字规则对同一个字符判断相反，而这份矛盾在文档里躺了二十多轮没人对账**；本条同时更正了第 72 条一处把 `_CN_NUM_RE` 当成 `_DECIMAL_RE` 的错误溯源）与「**守卫只挡住输入的一种形态，同一个形状的另一种来源直接通过**」（第 76 条独有：`_UNIT_RE` 后行断言枚举了「中文数字」却漏了「已经写成阿拉伯数字」，而识别器把语音归一后产生的恰恰是后者——`50万元` 里 `万元` 单独匹配、`chinese_to_int("万")=10000` 拼在 `50` 之后 → `5010000元`，错两个数量级；**被守卫挡住的那一格恰好是真实输入里少见的，漏掉的那一格恰是常态**，且这条与 Swift 侧第 66 条是同一个 bug——**两侧各修过一次，另一侧一直没动**）与「**把一次手动检查的结果写成了可复现的门禁**」（第 77 条独有：证据表里那一栏与 `pytest`／`ruff`／`mypy` 并列，**而实现它的是一次手动 `grep`、不在仓库里**——与 §5 第 10 条「探针只在 `/tmp`、接手方拿不到」同根，而这一次连一次性都没做对：**引入坏字符的那次提交，恰恰是在「全绿」之后做的**；证据可以是一次性的，但**把它写成门禁就等于让下一轮以为它一直在跑**）与「**点名了一条自己也不存在的回归**」（第 78 条独有：注释把一条**从未定义过**的名字当成既有回归写下来，报告再抄一遍——**覆盖是有的，指针是空的**，于是接手方按引用去核会推断这一向没测，而它其实测了；与第 45 条同族但深一层，那一条错在交接文档，这一条错在**代码注释**，因而更难被发现：测试照常全绿，注释照常权威，只有真去核对的人才会撞上）与「**合成了一张表，就以为接缝也接好了**」（第 74 条独有：第 70 条把 canonicalizer 内部两张单位表合成一张，保真门禁那张 60 项的表却没跟着接上，于是 5 个单位在两侧各有一份答案、互相替换全部静默放行——**统一了一张表不等于统一了所有读它的人**）与「**同一个概念在几处各写一遍，没有一处负责说「这就是全部」**」（第 73 条独有，且是这条家族的第三次出现：第 65 条是保真门禁的单位枚举、第 70 条是两张单位表各自漂移、第 73 条是两条规则带不带单位组都不一样——三次都正确，合起来不成立）与「**把两份清单对齐之后，就以为清单本身对了**」（第 72 条独有：补上 `两` 之后口语小数对了，但**点前点后的成员边界一条测试都没写**，于是「把 `两` 也放进点后类」和「把 `〇` 放进点前类」两个真实的成员变更都能让整套件全绿——与第 70 条「断言不等不等于断言了想要的那件事」是同一次复发，只是这次漏的是**否定侧**）与「**同一件事在两个地方各信一次，两边都以为对方做了**」（第 71 条独有，且是第 70 条那条的直接续集：ProtectedAtom 已经承认全角是数字，canonicalizer 不认，于是**改写保护把 `５０毫秒` 当成一个原子，改写校验却把它切成五个字符**——同一个「什么算一个数字」有两份答案）与「**把「修数字」写成了「改数字」**」（第 67 条独有：量级补 1 只覆盖 `十` 这一个字符，看起来是完备规则，实际是枚举式的——和第 65 条的单位枚举同一种病，只是这次枚举的是**量级本身**，缺的那几个（`百/千/万/亿`）单独出现时算出 0，于是量级越大错得越彻底：`百分之`→`0分百`、`数万`→`10元`；而下游 `withSemanticReview` 把任何 finding 都升级成 `.unresolved`，被改坏的句子既进不了自动朗读也进不了对齐——**数值门禁本身成了漏检来源**）与「**该同步交付的状态被做成了收尾时才交付**」（第 87 条独有：把「进入手动」放在停止流程的收尾里而不是按下暂停的那一刻，于是最需要反馈的那几秒里界面仍在说「跟读咬合」——**与前面各族都不同，这一族的错不在失败路径，而在成功路径的时机**；第 88 条是它的同族但更硬：一次性令牌被第二次请求换掉，**失败的不是某次状态同步，而是这个令牌此后再也不会被清空**）与「**同一条职责在一个入口做了、在另一个入口没做**」（第 89 条独有：`requestVoiceStop` 会把跟读收回手动，`coordinator.stopCapture` 这条路不会——**两条路都叫「停止」，只有一条记得同步状态**，而落盘的 `mode` 走的正是没做的那条）。**这一轮还量出并否掉了一个看起来很对的方向**：把素材侧标注也按稳定前缀截断，数字上说得通（现有标注确实系统性领先一个修订），但 §11.6 的延迟锚点是「人说过的话」而不是「引擎确认到哪」，照做会让 `failure_share` 从 0 跳到 48.8%——**报告变难看是因为问题被换掉了，不是因为跟随变差了**。它们都不影响正常路径，只在磁盘写失败、用户重复操作、舞台已开启、跟随长时间没回稿、素材太短、识别器听错远处某段、或素材里存在大量一两个字碎片这类边界上暴露。已全部修复并各配回归与变异验证，但**同类形态是否还有第五处，本轮没有证据能保证没有**——第 43 条那次静态扫描在 `TeleprompterSession.swift` 命中 12 处、其余四个提词器文件全部为假阳性，这是本轮实际查到的范围，不等于全仓无遗漏。

**四条发现方式留给接手方，按成本从低到高排**：

1. 第 51 条：**把「读者点了这个按钮，接下来会看到什么」逐个问完**六个创建入口问出来的。
2. 第 57 条：看到「占比」就去核对**分子分母的单位**是不是同一个。
3. 第 58 条：看到「0 次」就去问「**0 次是在多长的观测上得到的**」。
4. 第 59、60 条：**把方案台账逐条对到实现上**。F-04 那一行写着「不跨远距自动推进」，第 2.14 节记着 Swift 侧靠 `localAdvanceTokenRadius` 挡住了——于是去问素材侧等价的一道在哪，答案是没有。**一个门禁在一半系统里存在、另一半不存在，是最难靠读代码发现的一类缺口**：两边的代码都没错。

另需注意：**UI 走查缺口由 #89 跟踪，首个 ASR partial 的用户可见延迟由 #83 跟踪，两条至今 OPEN**。§3.2 列的两项未执行验证并非无人认领。

#83 的验收第 2 条（fake backend 覆盖首个 partial、无 partial 直接 final、重写被抑制、取消、失败和慢客户端，且每个 turn 最多记录一次）此前只被两个用例覆盖了五种 outcome，重写被抑制、慢客户端与每 turn 一次三条既无用例，也没有测试保护 `_first_hypothesis_recorded` 那道幂等护栏。**第二十八轮补齐这三个用例并逐一用变异探针确认会红**：短路护栏后计数由 2 变 6，去掉重写抑制的 `continue` 后多发一条 delta。**其中「重写被抑制」一条第一版是假通过**——用的 `("abc", "xyz")` 等长重写切出的后缀恰好是空串，即使去掉 `continue` 也不会发出错误 delta；改成不等长的 `("abc", "wbcd")` 才真正咬得住。#83 的验收第 1、4 条已有据可查；**第 3 条（注明模型／档位／冷暖／分块的 p50／p95 对比）仍需真实基准，而该 issue 自身写明「不授权本次运行 benchmark」**，因此 #83 保持 OPEN。

## 5. 未完成与建议的下一步

16. **素材构建管线的「15 条真缺口」已结案（第六十八轮逐条查清，推翻了上一轮的判断）**：第六十七轮把 F 组 16 条存活里的 15 条登记为真缺口。**逐条查完之后，其中 4 条补回归转杀（F7 配置类错误静默降级、F12 5xx 不重试、F9 传输层错误不兜底、F3 非朗读块被送去合并接缝），其余 11 条没有一条是真缺陷**：5 条生产不可达（F1／F8 依赖 `validate` 的选区可解析不变式、F14 的 `split` 只在 count > 1 时调用、F16 两个耗时产地都以 `max(0, …)` 收尾、F17 的 `budgetUnits` 构造即 `max(1, …)`）、5 条冗余纵深防御（F2／F5／F6 被解码器侧与提示词构造器先一步拦住，**F5 与第 63 轮 A3 是同一条约束的两个副本**）、2 条等价变异（F15 形态判定、F4 限于默认 policy）。**留下的不是缺陷，而是一条记账规矩**：同一道约束在两层各写一遍时，上层那道要按「冗余」记账，否则报告会把一份纵深防御记成两处风险。唯一如实记作未覆盖的是 **F10 的上界**（`min(retryAfter, 60)`）：它只能在真的等超过 60 秒时才可观测，而 `retryAfterDelay` 是 `fileprivate`、测试无法直接调用（实测编译期即报 inaccessible）——**本轮试过写成行为断言，跑出来要么让整套测试多花 60 秒、要么断言不到边界，因此不硬凑用例。**逐条 rationale 见 `scripts/teleprompter_swift_mutations.json` 的 F 组，论证过程见 §2.54。

17. **剩下 5 条 INVALID 已于第六十九轮逐条回炉，结论是全部继续记 INVALID**：第六十七轮证明「崩溃一旦消失，原本被它掩盖的读数会自己变干净」，据此要求这 5 条（M26／A4／A5／A13／E5）查清是「真会崩溃到无法解读」还是「又一次被测试自己的写法吃掉了真检出」。**结论：5 条全部是前者。** 串行复跑（`swift test --no-parallel`）逐条定位到肇事用例与 trap 位置，**trap 全部落在产品代码里**，而且这 5 条用例断言的恰恰是安全行为（M26 的用例名就写着 `...RatherThanACrash`、E5 断言「越过末行返回 nil 而不是崩溃」）。**据此把 INVALID 分成两类**：一型崩溃在测试里（可改断言挽回，M38／F11／F13），二型崩溃在产品里（守卫就是修复，回炉是白费功夫，本轮 5 条）。**分类之后，「要不要回炉」才有确定答案。** 本轮无代码改动：变异集仍 143 条，109 杀 / 29 存活 / 5 INVALID，基线 774，详见 §2.55。

12. **「静默拒绝」这一族的按钮门控已按同文件既有约定统一，只剩一处必须走查（第十五轮更新）**：§2 第 46–50 条修掉五处会话层缺陷（两处 `try?`、两处静默 `return`、一处无兜底的 `if let`），第 51 条修掉导入链的虚假成功。**六个「新建」入口已补 `.disabled(!session.canEdit)`**，依据是同文件里标题／正文编辑器早已在用这个模式——是否与既有约定一致不需要走查授权，「灰显好不好看」才需要。
    **仍然只剩一处，且本轮刻意没改**：视图 `case .analyzing, .preparing` 分支里的「取消整理」按钮。**不能**给它加 `.disabled(!session.canEdit)`——它是「取消正在进行的 AI 整理」，而 `prepareDraft` 只设 `phase = .analyzing`、不动 `isTightening`／`isAnnotating`，所以 `.analyzing` 期间 `canEdit` 为 true、取消本该可用；灰显它会**直接破坏取消功能**。但由此暴露一个真缺陷：`.preparing`（语音启动瞬态，`canEdit` 为 false）时该分支也显示「取消整理」，点了静默无效，标签与场景也不符。**走查时要确认**：`.preparing` 期间这个按钮应显示什么、是否该换成「正在启动」之类的状态文案。

13. **~~跟随策略有三个阈值至今没有能观察到它们的用例~~ ——第六十一轮结掉（§2.47）**：第五十八轮登记的三条证据缺口，两条是真缺口并已补回归，一条是等价变异。
    - `relocalizationMinimumMatches`（4）：**已覆盖**。新增 `freePlayReanchorsOnADistantPhraseOnlyWithEnoughEvidence`，短版不推进、长版推进，降到 1 后 4 条变红。
    - `reanchorMargin`（0.12）：**已覆盖**。新增 `aPhraseWrittenTwiceIsNotAnUnambiguousAdvance`，同一句话出现两次、分数相同即判歧义不推进，归零后 4 条变红。
    - `provisionalMinimumConfidence`（0.72）：**判为等价变异，不需要夹具**——凡能走到该比较的 match 置信度必然 ≥ 0.72（对齐器在 `TeleprompterAligner.swift:217` 先卡了一道，且没有任何调用方改过那个值），放宽阈值不改变任何一次判定。**但它留下一件产品侧的事**：`uncertainty` 因此只可能是 0 或 ≥ 0.72，「大致对但不确定」的中间态在界面上从未出现过。要让这个阈值变成活的，得改对齐器的产出策略，属产品行为变更，本轮未做。

14. **~~有一条可观测性测试会间歇失败~~ ——第六十轮已查清，这条作废，机制是崩溃留下的陈旧构建产物**：
    第 59 轮登记的现象是真的：`observationRecorderPersistsEventsAndAggregatesLowCardinalityMetrics`
    断言临时目录里两个文件的确切行数，实测会多出若干行（`…count == 4` 实测 5、6 或 8；`metricLines.count == 1` 实测 2），
    **且只在紧跟一条崩溃变异之后出现，第二次运行即自愈**。
    **第六十轮把那个文件的内容 dump 出来，机制确定了**：里面混着**两种不同 JSON 形状**——
    一部分带 `schemaVersion` 与 `component`、键序是当前实现；另一部分两者都没有、键序也是旧的。
    也就是说，**崩溃打断了构建，下一次 `swift test` 链出的是新旧混合产物**，旧对象里那个
    `TeleprompterAIObservationRecorder` 写出的记录与当前结构不一致，于是多出整行。
    这一条同时解释了当初所有想不通的地方：**全新的 `UUID()` 目录里也会有整行多余**（是同进程的陈旧对象写的，不是别的进程）、
    **每次行数不同**（取决于哪些对象陈旧）、**隔离跑与干净构建永远通过**（产物一致）。
    **所以它既不是产品缺陷，也不是那条测试的缺陷，测试本身是对的。**
    **对使用者的意义只有一条**：任何崩溃型失败之后，**先重跑一次再解读结果**——
    `scripts/swift_mutation_probe.py` 已内置该闸门（`recover_after_crash()`），
    手工用 `swift test` 时同样适用。**不需要修产品，也不需要改那条测试。**

15. **60 字软上限对中文根本不生效——已决定按常理切分，本 PR 不实施，转 issue**：实测 **500 字的中文句子被切成 1 段（499 字）+ 1 段（句号）**，60／61／121 字同理。根因在 `TeleprompterSegmenter.boundedRanges` 的那道「Never split a long **Latin** word or identifier」循环：它用的 `isWordCharacter` 判据是 `CharacterSet.letters`，**而 `letters` 包含汉字**，于是这道为拉丁文设计的保护在中文上照样生效，循环一路把切点推到句末。注释承诺的是「不切断英文单词」，实际把后面的中文也并了进来。**产品决定（2026-09-30）**：中文按常理切分即可，不追求一次做完美。**实施建议（留给接手方，本 PR 不做）**：把该循环改用**只认拉丁字母与数字**的判据（`_`／`#` 保留），而不是全局改 `isWordCharacter`——后者同时被「点两侧都是词字符就不切」与「英文缩写前缀」两处共用，改动面更大且会放宽小数／版本号的保护。**影响面**：改完之后每一篇长稿的段数与每个阅读位置都会变，回放素材标注与既有分段夹具需同步重做；**这同时是第 85 条（长于 180 字单元的稿件 AI 标注必然失败）的根因**，分段修好后该条的触发面自然消失，但第 85 条本身的解码器豁免修复仍应保留。已开 follow-up issue 跟踪。

18. **`TeleprompterSession.swift` 的覆盖已补上，但留下一条「钉不住」的存活（第七十轮）**：本轮 15 条变异 7 杀 / 8 存活，补 4 条回归后 **3 条存活转杀（第 87–89 条）**，其余 5 条逐条查因为等价变异、冗余防御或生产不可达。**唯一需要接手方知道的是 S2**：它是**真缺口而非等价变异**——`phase == .manual` 且 `state == .starting` 的组合在生产里确实存在（`beginCapture()` 的 catch 在 state 仍 `.starting` 时就写 `phase = .manual`），去掉 `.starting` 排除会漏停麦克风；但测试无法确定性控制这个窗口，要消掉它得改产品结构而不是改测试。**因此它被留在存活里并写明后果，没有硬凑一条测试假装已覆盖。** 其余存活的逐条理由在 spec 的 `rationale`，论证见 §2.56。变异集 143 → **158 条**（116 杀 / 37 存活 / 5 INVALID），基线 774 → **778**（Swift Testing 384 + XCTest 394）。

19. **两套时长估算的不对称——产品决定：保持现状，本 PR 不再改**：第 90 条已修掉危险的那一侧（会话侧不再比设置侧更宽松）。剩下的一半是：含 ASCII 冒号或斜杠的普通稿件（如「步骤 1: 打开设置」）在会话侧判「不确定」、在舞台设置／内容选择／试读三处判「确定」。**产品决定（2026-09-30）**：不重要，不需要一次做完美，先保持现状、待真实测试后再定。**当前状态是安全的**：会话侧偏保守（宁可说「不确定」），三处 sheet 偏乐观，**没有任何一侧会给出错误的精确值**。代码注释里已写明这处不对称是故意的、以及两种收窄方向各自的后果，接手方要改时不必重新推导。

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
  - 第 59 条（探针证据文件）：只改 `tools/probe_teleprompter_latency.py` 与 `tests/test_teleprompter_latency_probe.py`。**这是本分支唯一改动探针输出 schema 的一条**：`schema_version` 3 → 4，`condition` 为新增字段，顶层 `model` 移除。已产出的历史结果文件**仍是合法的 schema 3**，回退代码后仍可读；但**不要把 schema 3 的文件当 schema 4 解析**。回退＝还原 `run_probe` 的字典字面量；代价是退回「证据文件不带语言与设备、`completed_ms` 含整段音频时长」，且三条新回归会红。`LANGUAGE` 与 `session_update_payload` 可以保留——它们不改变输出形状，只是把字面量收成单一来源。
  - 第 60 条（素材远距闸门）：只改 `tools/build_teleprompter_replay_manifest.py` 与 `tests/test_teleprompter_replay_manifest.py`，**不改 `teleprompter.replay.v1` schema**（`labels` 结构不变，只是远距时不再给 `expected_segment_index`；复核清单加一列，不影响 manifest）。回退＝把 `ALIGN_MAX_ADVANCE_CHARS` 调大或删掉闸门；代价是退回「12 个字换到 7 段外、匹配满分、复核看不见」。**已按真实素材量过分布**（最大 17 字），所以回退不会改变现有素材的标注，但会重新打开 F-04 这一族。已产出的历史 manifest **不受影响**——它们已经写好了 labels，回放器只读 `labels`，不重跑对齐。
  - 第 61 条（素材关键词闸门）：同样只改 `tools/build_teleprompter_replay_manifest.py`，**不改 `teleprompter.replay.v1` schema**（`labels` 结构不变；复核清单加一列，不影响 manifest）。回退＝把 `ALIGN_MIN_ADVANCE_MATCH_CHARS` 调成 0；代价是退回「两字碎片拿满分即可推进位置」。**已在真实素材上量过**（1-3 字匹配推进 0 字），所以回退不改变现有素材的标注。`matched_chars` 字段与「匹配字数」列建议保留——它们不改变行为，只让复核的人看得到证据量。
  - 第 62 条（延迟样本数）：只改 `TeleprompterReplayEvaluator.swift` 的 `Metrics`、`jsonObject` 与 `caveats(for:)`，**报告 `teleprompter.eval.v1` 的字段是新增而非改义**，`metrics` 里每个既有字段含义不变，但**已产出的历史报告不含这两个计数字段**，回退代码后重跑即可，旧报告仍可读。回退＝删掉两个样本数字段与覆盖面 caveat；代价是退回「P95 由 4 个样本算出，却与 `sample_count: 82` 并排」，以及「标注给了位置、跟随一次没到」时报告完全沉默。**回退时必须同时回退三条测试**（`everyLatencyPercentileTravelsWithItsSampleCount`、`aLabelledPositionTheFollowerNeverReachedIsNotReportedAsSilence`、`aFullyCoveredMaterialReportsNoLatencyCoverageGap`），并把 `reanchorLatencyIsMeasuredFromTheDetour` 里新增的那条样本数断言与 `reviewedDatasetKeepsTheSilenceItEarned`／`unreviewedDraftDatasetSaysSoEvenWhenEveryOtherCaveatStaysSilent` 的「剩下只剩上界」放宽回去——这四条断言本身就是这两条 caveat 的契约。
  - 第 63 条（未匹配不算恢复）：只改 `TeleprompterReplayEvaluator.swift` 的 `.read` 无位置分支、`Metrics`、`jsonObject` 与 `caveats(for:)`，**报告 `teleprompter.eval.v1` 仍是新增字段**（`unmatched_event_count`），既有 metrics 字段里只有 `stalled_event_count` 的**取值**会变（真实素材 12 → 11），含义不变。回退＝把 `.read` 的 `else` 分支改回 `endReanchorWindow()` 并删掉计数与 caveat；代价是退回「一次也没恢复的跟随被两个对不上稿的事件抹平，超时与失败样本双双报 0」，以及「82 个事件里 18 个无位置事件从报告里完全消失」。**注意**：回退会让 `stalled_event_count` 在真实素材上从 11 回到 12——那 12 里有一次是被无位置事件提前释放门槛撑起来的，所以**不要把 12 当成正确值再把 11 当成回归**。回退时必须同时回退三条测试（`anUnmatchedEventIsNotEvidenceThatTheFollowerRecovered`、`eventsWithoutAReadingPositionAreCountedSeparately`、`aFullyPositionedMaterialReportsNoUnmatchedEvents`），它们是这条修复的契约。
  - 第 64 条（稳定前缀契约守卫）：改 `TeleprompterFollowController.swift`（越界即暂停并计数）、`tools/build_teleprompter_replay_manifest.py`（越界即拒绝并给独立 reason 与清单字段）与两侧测试。**不改任何 wire 或 manifest schema**——`stable_prefix_codepoints` 本来就在 manifest 里，复核清单加的那一列是给人看的，不影响 manifest。回退＝撤掉两处 guard；代价是退回「契约一出问题就拿仍在修订的全文去对齐，且异常不可见」。**在真实素材上这份守卫完全惰性**（0 条标注改变、报告逐字段零差异），所以回退不改变现有素材的任何数字——但会重新打开 F-15。回退时必须同时回退四条测试（`anOutOfRangeStablePrefixPausesInsteadOfAligningUnrevisedText`、`aLongHypothesisWhoseStablePrefixExceedsTheStoredBoundIsNotAnAnomaly`、`test_a_stable_prefix_out_of_range_is_a_contract_anomaly_not_a_weak_match`、`test_a_stable_prefix_within_range_does_not_change_the_labels`）。**最后一条是反向对照**：它钉住「别把按前缀截断加回来」——那一版量过并否掉，理由见 §2.22。
  - 第 65 条（保真门禁的单位与空白）：只改 `TeleprompterPreparationPrompts.swift` 的数字正则单位组与 `canonicalize`，**不改任何 schema、不改门禁位置、不改 `.speak` 的硬拒语义**。回退＝还原这两处；代价是退回「`50 瓦`→`50 千瓦` 读起来等于没改」与「`50 元`→`50元` 被当成受保护字面量被改、送人工」。**真实素材不受影响**（`script_b.txt` 里没有阿拉伯数字），所以回退不改变现有任何素材的数字。回退时必须同时回退三条测试（`extractorSeesCjkUnitsThatWereNotEnumerated`、`unitBindingStopsBeforeAParticle`、`gateAcceptsWhitespaceOnlyChangesAroundAUnit`）。**若接手方要继续扩单位清单，先照 §2.23 量一遍匹配后继字符**，并守住两条已定的边界：助词／连词不得进入原子、中文数字仍在门禁外。
  - 第 66 条（读法别名的量级门禁）：只改 `TeleprompterNormalizer.swift` 的两条规则与 `chineseInteger`／`arabicValue`，**不改任何 schema、不改别名存储、不改 `currentRuleRevision`**。回退＝还原这四处；代价是退回「`3万`→`3`、`三万`→`三千` 都能加进别名」与「`2万元`→`两万元`、`50`→`五十` 这些同一个数被误拒」。**已复核过的人工标注别名不受影响**——回退只是让门禁回到旧判据，已存的别名不会因此失效。回退时必须同时回退五条测试（`recognisesMagnitudeCarriedByTheNumeralItself`、`arabicMagnitudeWordsFoldIntoTheNumber`、`aliasGateSeesMagnitudeOnBothSides`、`wordsThatOwnTheFractionCharacterAreNotReadAsQuantities`、`aBareMagnitudeIsItsOwnPowerAndTwoInARowAreAWord`）。**收紧那两处守卫时要一并回退**：`分(?![之比点号位])` 少一个字就会把 `百分比`／`百分点`／`百分号`／`百分位` 读成 100 分，「两个大量级相邻」的守卫失效会把 `万亿元` 读成 `10000元`（它是一万亿）。§2.24 记了这两处各自的实测出现次数。
  - 第 67 条（服务端 ITN 的量级）：只改 `src/speechrail/domain/itn.py` 的 `_chinese_to_int`、`_UNIT_RE` 与 `_convert_with_unit`，**不改任何契约、schema、配置或依赖**（`git diff --stat` 为 1 个源文件 + 1 个测试文件 + 本报告，**没有新增任何第三方依赖**——这一轮正是靠「不换库」才做到零依赖面变化）。回退＝还原这三处；代价是退回「`这是百分百的努力`→`这是0分百的努力`、`我万分感激`→`我0分感激`、`十分之一`→`10分之一`、`数十秒`→`10秒`」。**行为差异要知道两处**：删掉单位 `点` 之后 `今天下午三点开会` 不再归一为 `3点`（少转，方向安全）；`万元`／`万亿元` 现在会正确归一为 `10000元`／`1000000000000元`，回退后重新读成 `0元`。回退时必须同时回退 8 条测试（`test_itn_does_not_corrupt_magnitude_words`、`test_itn_converts_bare_magnitude_with_a_real_unit`、`test_itn_scales_the_accumulated_total_at_yi`、`test_itn_leaves_quantity_words_alone`、`test_itn_leaves_fractions_alone`、`test_itn_does_not_read_an_approximate_magnitude_as_a_value`、`test_itn_still_converts_minutes_and_bare_ten_with_a_measure_word`，以及 `test_itn_scales_the_accumulated_total_at_yi` 里新增的 `十万亿` 断言），它们是这条修复的契约。**若接手方要扩单位表，先照 §2.25 量一遍**：`点` 是被语料否掉的，`分` 只在带数字时成立，两条边界都不要放宽。
  - 第 68 条（中文主体的语义风险检测）：只改 `TeleprompterPreparationPrompts.swift` 的 `nearestSubject` 模式表、`SubjectValuePair` 与 `findings` 的比较段，加该文件的测试，**不改任何 schema、不改 `withSemanticReview` 接线、不改 review issue 枚举、不新增依赖**。回退＝删掉模式表里的 `Self.chineseOrdinalSubject` 并把比较段还原成两张 pair 列表的全等；代价是退回「中文提词稿上主体—数值变化一次也不报」与「删一个逗号就判成互换」。**注意两处是同一个 commit 但可分开回退**：只回退模式表会得到「中文序数能报，但纯标点改写仍误报」；只回退比较段则回到本条之前的行为。回退时必须同时回退 6 条测试（`semanticReviewSeesChineseOrdinalSubjects`、`semanticReviewSeesEveryOrdinalQuantifierTheCorpusProduces`、`semanticReviewOnlyReadsAnOrdinalThatStartsItsClause`、`semanticReviewIgnoresASubjectThatOnlyOneSideFinds`、`semanticReviewKeepsTheOrdinalNumeralSetToWhatTheCorpusHas`、`semanticReviewStillMissesGeneralChineseNounPhraseSubjects`），它们是这条修复的契约。**若接手方要扩中文主体范围，先照 §2.26 的表重跑一遍语料**，`的` 前锚定与天干标签都有现成的反例数字；量词表与数字表都严格等于实测集合，`两`／`零` 是被实测挡掉的，不是漏写。
  - 第 69 条（否定标记的后继字守卫）：只改 `TeleprompterPreparationPrompts.swift` 的 `markerForbiddenFollowers` 常量与 `markerCounts` 里的跳过分支，加该文件的测试，**不改任何 schema、不改标记表本身、不改 `withSemanticReview` 接线**。回退＝删掉那张两字的守卫表；代价是退回「`未来`→`将来` 判成否定变化，拦下一次自动朗读」。`未知` 有意不在表内——`原因未知`→`原因已知` 是真的语义变化。回退时必须同时回退 2 条测试（`semanticReviewDoesNotReadANonNegationWordAsNegation`、`semanticReviewStillSeesTheRealNegations`，后者含 `未` 位于文末的边界断言），它们是这条修复的契约。**守卫挂在字面量搜索上而不是改成正则是有意的**：标记表用 `range(of:)` 匹配，整张表改成正则会让其他每个标记的含义都开始依赖正则语法；接手方若要加标记，先照 §2.27 的表量一遍后继字。
  - 第 70 条（单位表合并与空格归一）：只改 `TeleprompterNormalizer.swift` 的 `unitSuffixes`（改为长度降序的单一来源）、新增 `unitAlternation`、两条规则改为共用它，并给 `.arabic` 的单位组加 `\s*` 与在 `.arabic` 取值时滤掉空白，加该文件的测试，**不改任何 schema、不改对齐器的推进逻辑、不改 `TeleprompterCanonicalizer` 的对外接口**。回退＝还原两张表与两条正则；代价是退回「脚本里带空格的数字全部对不上」与「`三年` 匹配不到任何东西」。**注意表里同时收进了 `年/份/吨/小时/毫秒/公斤/千克/毫升/厘米/毫米`**，回退会让这些也一并退回不一致。`台/条/项/字/页/版/根/周/段/克/章/张` **有意不在表内**，理由与语料数字见 §2.28，接手方不要因为「看起来常用」就加回去——`条` 会把 `条件` 读成 `5条件`。回退时必须同时回退 5 条测试（`aSpaceBetweenDigitsAndAUnitIsLayoutNotContent`、`bothNumeralRulesReadTheSameUnitList`、`unitsThatWouldSwallowTheNextWordAreLeftOut`、`aUnitOnItsOwnIsStillSeparateFromTheNumber`、`aLongerUnitWinsOverTheCharacterItEndsWith`）。**`unitSuffixes` 的顺序是承重的**：它被一处 `first(where: hasSuffix)` 消费，`米` 排到 `厘米` 前面会让 `五厘米` 干脆不再是数字。
  - 第 71 条（全角数字与全角百分号）：只改 `TeleprompterNormalizer.swift`——三条数字规则改用新的 `digitClass` 常量（`[0-9０-９]`），`.arabic` 的单位组加上 `％`，新增私有 `asciiDigit(_:)` 并在 `arabicValue`／`chineseInteger`／`asciiDigits` 三处取值路径上使用；加该文件的 2 条测试，**不改任何 schema、不改对齐器的推进逻辑、不改 `TeleprompterCanonicalizer` 的对外接口、不碰 `TeleprompterProtectedAtom`（它本来就对）**。回退＝把 `digitClass` 换回 `[0-9]`、删掉 `％` 与 `asciiDigit`；代价是退回「全角数字静默逃过数值闸」与「`百分之５０` 被读成 100 分」。**注意 `arabicValue` 的区间仍必须取 `match.range.length` 而非 canonical 值的 `value.count`**——`2万元` 的值是 `20000元`，两者不等长，混用会让区间越过数字锚到后面的文字上（§2.29 变异 M8）。回退时必须同时回退 2 条测试（`fullWidthDigitsAndPercentSignAreTheSameNumber`、`canonicalValuesFoldButRangesStayOnTheSourceText`）。**阿拉伯-印度／波斯数字仍不识别为数字，这是量过后明确记录的不修项**，回退不影响该边界。
  - 第 72 条（口语小数的点前类补 `两`）：只改 `TeleprompterNormalizer.swift` 一处字符类（`.spokenDecimal` 的点前类加 `两`），加该文件的 1 条测试，**不改任何 schema、不改对齐器、不改单位表、不改 `TeleprompterProtectedAtom`**。回退＝把那一个 `两` 删掉；代价是退回「`两点五` 被读成两点钟」。**注意点后类与 `〇` 是有意不加的**：那不是遗漏，是与服务端 `_DECIMAL_RE` 逐字对齐的选择，语料上点后用 `两` 唯一一处是假阳性（`落点两块`）、点前点后用 `〇` 各 0 处（§2.30）。回退时必须同时回退 1 条测试（`spokenDecimalsAcceptTwoTheSameWayTheRestOfTheNumeralRulesDo`）——那条测试里的两条反向断言（`〇点五` 不转、`三点两` 不转）是**唯一**钉住成员边界的东西，删掉它会让下一次成员变更悄无声息地通过。
  - 第 73 条（口语小数带单位组）：改 `TeleprompterNormalizer.swift` 两处——`.spokenDecimal` 的正则加 `\s*(?:unitAlternation)?`，以及 `canonicalValue` 的 `.spokenDecimal` 分支改为先滤空白、再剥单位后缀、最后按原样拼回；加该文件的 1 条测试，**不改任何 schema、不改对齐器、不改单位表本身（复用第 70 条合成的那一张）、不改 `TeleprompterProtectedAtom`**。回退＝把正则的单位组与 `canonicalValue` 的剥壳一起还原；代价是退回「同一个数量写成两种数字就匹配不上」。**注意 `点` 也在那张共享表里**，所以本条会让 `7点40分` 由 `7.40`+`分` 合并成单个 `7.40分`——那是既有错读（§2.30 第 2 条、#95 认证的 `synth-zh-number-10`），**不是本条引入的，也没有被本条修好**；脚本侧 `7.40分` 与识别器侧 `7.410分` 仍不相等，未制造假放行。若将来决定把 `点` 移出单位表，本条应当仍然成立（`三点五秒` 与 `3.5秒` 都不依赖 `点`），回退前请一并复跑。回退时必须同时回退 1 条测试（`spokenDecimalsCarryTheSameUnitSuffixesArabicOnesDo`）。
  - 第 74 条（保真门禁补齐五个单位 + 不变量测试）：改 `TeleprompterPreparationPrompts.swift` 的 `TeleprompterProtectedAtom` 数字正则单位组，加入 `分|点|号|楼|岁`（放在 `度` 之后、`条` 之前，**`分钟` 仍在前面因此仍优先**），并把 `TeleprompterNormalizer.swift` 的 `unitSuffixes` 从 `private` 放宽到模块内可见（仅供不变量测试读取，无对外接口变化）；加 3 条测试，**不改任何 schema、不改对齐器、不改解码器**。回退＝把五个单位从正则里删掉、把 `unitSuffixes` 改回 `private` 并删掉引用它的那条测试；代价是退回「`10 分` 改成 `10 号`、`10 岁` 改成 `10 楼` 等 20 对单位改写静默通过」。**注意交替顺序是承重的**：`分` 必须排在 `分钟` 之后，否则 `10分钟` 的受保护原子退化成 `10分`，`10分钟`↔`10分` 两个方向随即放行而两侧 canonical 读法不同（§2.32 变异 R7）。**回退时不要只回退正则而留下不变量测试**——它会立刻变红，那正是它存在的意义；若确实要缩小 `unitSuffixes`，必须同一条提交里同步门禁，否则不变量测试是红的。已量到并保留的一处误保护：版本号 `2.6.6/2.7.0` 后接「分支」时 `2.7.0分` 成为受保护字面量，代价有界（只在紧跟文字本身改变时拦），不修。
  - 第 75 条（`点` 移出单位表）：只改 `TeleprompterNormalizer.swift` 的 `unitSuffixes` 删掉一个成员（并补了一段说明为什么删），加该文件的 1 条测试，**不改任何 schema、不改对齐器、不改保真门禁、不改服务端**。回退＝把 `点` 放回 `unitSuffixes`；代价是退回「`这一点`→`1点`／`短一点`→`1点`／`7点40分`→`7.40分`」。**注意保真门禁那一侧仍保留 `点`**（第 74 条加的），那是更宽的方向、安全，不需要跟着回退。
  - 第 76 条（服务端 ITN 的 ASCII 量级守卫）：只改 `src/speechrail/domain/itn.py` 的 `_UNIT_RE` 后行断言（补 `0-9`）与该文件 1 条新回归，**不改任何契约、schema、配置或依赖**（仍为 0 新增第三方依赖）。回退＝把 `0-9` 从后行断言里去掉；代价是退回「`50万元`→`5010000元`、`10亿元`→`10100000000元`、`5万美元`→`510000美元`、`30亿人`→`30100000000人`、`3万个`→`310000个`、`2万元`→`210000元`」——数字错两个数量级，且这条在**已上线服务路径**（batch／realtime 转写、`voice_quality` 比对）上，`withSemanticReview` 不会因「数字大了 100 倍」报警。回退时必须同时回退 1 条测试（`test_itn_does_not_glue_an_ascii_magnitude_onto_the_digits_before_it`），它含 `9亿元`／`7万吨`／`8千万个` 三条**后补**用例（`[0-8]` 窄化变异存活后才加的，前三条用例都从 1/2/3/5/10/30 起头、漏掉 7 与 9）。**已写成阿拉伯数字的数一律原样保留**（`20万台`／`1000公里`／`3小时`／`8吨`），这是修复后仍需守住的行为。
  - 第 77 条（报告自检证据与坏字符）：**只改本报告**——把 §2.33 那个坏掉的 `第` 修回、撤下证据表里不成立的「文档自检 全绿」一行、并新增 §2.35／§2.36 两节。**不改任何源码、测试、契约或配置**，因此没有运行时回退。回退＝把那一行填回「全绿」；**不建议这么做**——它没有实现，重新写上等于把一个查不到出处的结论再次交给接手方。坏字符若要恢复，代价是 §2.33 第一条依据里出现 `依据三条，??一条`。**真正的修法是把这条门禁落成 `tools/` 下的可重跑脚本，属新增仓库资产，需另行授权（与 §5 第 10 条同一判断）**；在它落地之前，这一栏应当保持空缺而不是写「全绿」。
  - **本条同时更正了报告第 72 条的一处错误归属**：那一节原写「修法取自服务端」，依据的却是服务端 `_CN_NUM_RE`；真正管小数的 `_DECIMAL_RE` 点前类**没有** `两`，实测 `apply_light_itn("两点五")` 原样返回。所以 `两点五` 是 **Swift 单方面比服务端多走了一步**（Swift 转 `2.5`，对；服务端不转，漏），**接手方不要把它当成「照服务端做」**。要补服务端那一侧须单独开工单并补 `tests/test_itn.py`。
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
