# SpeechRail AI 提词器：阶段实施报告

> 对应方案：`SpeechRail_AI_Teleprompter_Implementation_Plan_2026-09-28.md` v1.5  
> 报告日期：2026-09-28（Asia/Shanghai）；复审与收尾续至 2026-09-29  
> 实施分支：`codex/teleprompter-implementation`（worktree `.worktrees/teleprompter-implementation`）  
> 基线：`7468efb8c8282b119650fcb8e987a0d74f141e6a`；改动已提交到 `codex/teleprompter-implementation`，未推送、未发布  
> 状态：**部分交付**。安全、正确性与体验工作包均有确定性证据（69 项场景：通过 66、部分 2、未执行 1）；真实音频、真人表达与 UI 视觉验收未执行。

## 1. 本轮实际完成的工作包

| Issue | 工作包 | 结果 | 主要改动 |
|---|---|---|---|
| #108 | 探针计时、终态与有界性 | 完成 | `tools/probe_teleprompter_latency.py`、schema 3、11 项回归 |
| #104 | 出现级保真门禁 | 完成 | `TeleprompterProtectedAtom`、完整 canonical 序列比对、rewrite/map/reduce 共用门禁 |
| #105 | partial/final 统一推进权限 | 完成 | 本地推进半径与 reanchor 门槛，partial 与 final 走同一 `mayAdvance` |
| #106 | hypothesis 证据透传 | 完成 | 内部 `RealtimeHypothesisEvidence`，wire 协议未新增事件 |
| #107 | 三位置分离 | 完成 | `committedPosition` / `hypothesisPosition` / `viewportAnchor` |
| #109 | 语义风险审阅 | 完成 | 主体—数值、条件、否定、比较、确定程度五类风险进入生产审阅 |
| #110 | 同版本句内进度与安全恢复 | 完成 | `currentSegmentOffset`、纯函数恢复器、锁定文本偏移丢弃 |
| #111 | 独立有损精简 | 完成 | `condense` 操作、锁定项、删除转 `skip` 与 `contentRemoved` 审阅、语速校准来源与未校准标注 |
| #112 | language／keywords 接线 | 完成 | Realtime `transcription.language`／`keywords` 真正下发 |
| #113 | 场景预设、列宽与快捷恢复 | 完成（视觉走查未执行） | `TeleprompterStagePreset`、正文列宽与窗口宽度分离、`TeleprompterStageLayoutPolicy`、“回到朗读位置” |
| #114 | 确定性回放与阶段证据 | 部分完成 | 回放评估器与 runner 已交付；真实时延基线未执行 |

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
10. **时长估计不区分「默认倍率」与「实测倍率」（按 Issue 正文复核发现）**：此前只核对了 Issue 的标题与状态，没有逐条对照正文。#111 步骤 5 要求「复用已有 trial/calibrationFactor……未经有效试读使用默认估计并标明不确定性」，验收要求「手动计时、语音辅助试读的证据来源清晰」——这两条没有实现：`calibrationFactor` 默认 `1.0`，与某次试读恰好测得 `1.00x` 在数据上完全相同，`estimateDuration` 也只按文本原因（数字、网址、非中英文）标注不确定，从未试读的会话因此拿到一个与实测估计**同样确定**的点估计加 0.8–1.25 区间；界面还因为 `calibrationFactor != 1.0` 才显示校准入口，未试读的用户既看不到自己没校准，也没有可点的入口去校准。修复：新增 `TeleprompterCalibrationSource`（`.uncalibrated` / `.manualTrial(durationSeconds:)`），`EstimateResult` 增 `isCalibrated`，`estimateDuration`／`evaluatePreflight` 显式接收来源（默认 `.uncalibrated`，即调用方不举证就按未校准处理）；试读采用时写入 `.manualTrial`，「恢复默认语速」写回 `.uncalibrated`；内容选择页的预计用时在未校准时标注「（未试读校准）」，校准入口改为常驻并显示「未试读校准」。校准倍率本就不落盘（session 级 `@State`），因此不涉及存储迁移。语音辅助试读目前**不存在**（试读 sheet 只有手动秒表），没有为对齐措辞而虚构一条路径。
    - **同轮自查发现第一版只修了一半**：来源虽然接进了 `evaluatePreflight`，但 `PreflightConclusion` 不携带 `isCalibrated`，标记在返回时就被丢弃。结果是工作台最显眼的预检结论（时长 vs 目标）仍把未校准估计当确定值展示，只有内容选择页被修好。补齐：新增 `PreflightConclusion.showsDurationEstimate` 区分「带分钟数的结论」与「无内容／目标无效／无法预估」，只有前者需要标注；`TeleprompterSession.isPaceCalibrated` 供界面判断，未校准时预检文案追加「（未试读校准）」。新增具名回归 `onlyDurationBearingConclusionsAskForACalibrationNote`，并给既有的 `resetting to the default pace is not a measurement` 补上 `isPaceCalibrated` 断言。

11. **回放素材的 intent 契约与工具帮助文本不一致（端到端跑 CLI 发现）**：`teleprompter-replay --help` 写着 `read / improvise / re_read / manual_jump`，解码器只接受 `read / improvise / reRead / manualJump`；照帮助文本写素材必然失败，失败信息还是 Foundation 的通用句子，不说是哪个字段、也不说合法取值。之所以一直没暴露：所有测试都用 Swift 构造 `Intent`（`.manualJump`），没有任何测试让这些字符串经过 JSON 解码——素材是仓库外由人写的，字符串拼写是真正的对外契约，测试却只覆盖了类型内部那一侧。修复：`Intent` 显式钉住 raw value 并新增 `manifestValues`，帮助文本与错误信息从同一列表读；解码失败渲染 coding path 并对 intent 附上可接受取值；补两条回归（JSON 往返钉住拼写、断言 snake_case 被拒）。同时把实测出来的两条素材书写要点写进 `--help`：`expected_segment_index` 标的是**读者已读到的段落**而非系统确认到的段落，挂到系统已追上的事件会让延迟恒为 0 且不报错；第 0 段是回放起点，系统一开始就在 0，因此不产生延迟样本。

12. **提取器看不见的数字让保真门禁从 fail-closed 退化为 fail-open（第三轮对抗探测发现）**：`TeleprompterProtectedContentValidator` 比较的是受保护原子的**序列**（`expected == actual`）。提取器看不见的数字在源与候选两侧都不产生原子，精确序列比较因此得出「没有变化」——数值被改写反而通过了这道本该拦住它的门禁。用临时探针实测确认的静默放行：`1080p` → `4K`、`4K` → `8K`、`1e10` → `2e10`、`0x1F` → `0x2F`，以及 `29.97fps` 只抽出 `29` 而丢掉小数部分。根因是数字模式末尾的 `(?![A-Za-z0-9])` 拒绝任何紧跟 ASCII 字母的数字，而标识符模式要求字母开头，两侧都不匹配。**对本产品尤其要紧**：方案与测试素材本身就是相机设置场景，`1080p` 改 `4K` 在真实稿件上完全可达。修复为数字模式补上进制前缀、指数部分与紧邻 ASCII 单位后缀；首部 lookbehind 保留，`A1`／`GPT4`／`ISO8601`／`x1` 仍不产生数值原子。通用教训：**「比较两侧序列相等」的校验器在任一侧提取为空时必须区分「没有需要保护的东西」与「我没看见」**，前者才是安全的默认。
    - **同轮修复过程中自己引入过一次 fail-open**：单位后缀组漏了 `?` 变成强制匹配，导致所有后面不跟字母的数字（`50 公里`、`第3名`、`-5 度`）都抽不出原子，连「`-5 度` → `5 度`」这种负号丢失都放行。是同一批探针立刻发现的，而当时全量回归是绿的——**P0 门禁的正则改动不能只看测试是否通过，必须用独立探针轰击提取器**。
    - **有意留下的边界**：中文数字不在受保护集合内，`五十` → `五十一` 目前不受硬门禁保护（反向 `五十` → `50` 会被拒绝，因为候选侧多出一个阿拉伯原子）。没有直接把中文数字加进正则：日常中文满是一／两／三（`第一次` → `首次` 是无损改写），朴素比较会大面积误拦。要补必须带可测的误报率，不能靠加字符。已固化为具名回归 `chineseNumeralsRemainOutsideTheHardGateByDesign`，避免这个缺口被静默遗忘。

## 3. 验证证据

### 3.1 已执行

| 验证 | 命令 | 结果 |
|---|---|---|
| Swift 单元与回归 | `swift test --package-path macos/SpeechRailApp` | 210 项 / 16 套件全部通过 |
| 探针回归 | `pytest tests/test_teleprompter_latency_probe.py` | 11 项通过 |
| 共享准入回归 | `pytest tests/test_resource_governor.py` | 25 项通过（同 key 串行、共享单一 worker 槽位、重叠串行） |
| 回放 runner 端到端 | `swift run teleprompter-replay --manifest <外部 manifest>` | 产出 `teleprompter.eval.v1` 报告（P50／P95、恢复延迟、失败占比与 caveats 齐备）；缺 manifest、缺版本记录、素材字段非法均以退出码 2 拒绝。**CLI 与单测同形核对**：用与 `trackingLatencyIsMeasuredFromTheStartOfTheReadNotTheRun`／`reanchorLatencyIsMeasuredFromTheDetour` 同形的素材跑 CLI，复现了单测断言的数值（跟随延迟 p50=p95=400 ms；恢复延迟 p50=1100 ms），确认 runner 驱动的确实是生产跟随路径，而不是另写一套转写充当验收 |
| Xcode App target 编译 | `scripts/macos_app_build.sh --configuration Debug` | **BUILD SUCCEEDED**；17 条 warning 全部落在既有代码（`RealtimeASRClient` 的 `withStageTimeout` 未用结果、`LLMProvider` 弃用项等），本轮新增文件 0 条 |
| Xcode 单元测试 target | `scripts/macos_app_build.sh --configuration Debug --test-unit` | **TEST SUCCEEDED**（XCTest 344 项、Swift Testing 210 项 / 16 套件，均 0 failures），进程正常退出，`test-unit: passed`，exit 0。首轮曾因测试闸门竞态挂死并被 1800 s 超时终止，已定位并修复，见 §2 第 9 条 |
| 工程文件一致性 | `plutil -lint project.pbxproj` | OK；新增源码在 SwiftPM 与 Xcode 两个 target 均已登记 |
| 差异卫生 | `git diff --check` | 通过 |

### 3.2 未执行（需要逐次授权）

- 真实音频 1 倍速回放与真人表达验收（L3／L4）：本轮无授权，未采集任何录音。
- 任何 UI 自动化、窗口断言、录屏。
- 模型 benchmark、App 安装与发布仍未执行。
- commit 与 Issue 关闭已按 2026-09-28 的用户授权执行：证据完备者已关闭，其余逐条留下复审评论写明精确剩余缺口；**分支仍未 push**，关闭所依据的提交见各 Issue 评论。

因此方案 §11.7 的全部质量门槛——连续跟随 P95、回稿恢复 P95、手动操作 P95、错误停滞比例、严重误推进发生率——**当前均为未验证**，不得以本报告宣称达标。

### 3.3 契约与文档

- **公共契约无需修改**：`audio.input.transcription.language` 与 `keywords` 早已写入 `contracts/realtime-events.schema.json`（`session.update` 形状）并在 `contracts/realtime-openai.md` 的示例中给出；#112 是客户端向既有契约看齐，而不是新增字段。#106 的稳定性证据同样只走内部 Swift 事件（可选类型化字段，wire 协议未新增事件）。本轮没有改变任何公共端点、事件或错误 envelope。
- **已同步的文档**：`docs/developers/macos-app-teleprompter.md`（版本 0.5.1：场景预设、正文列宽、「回到朗读位置」、Reduce Motion、输入设备失败归因、模块表与本轮验收记录）、`docs/developers/macos-app-design-system.md`（正文列宽与窗口宽度分离的描述 + §6 验证矩阵新增一行）、`docs/users/mcp-agent-integration.md`（`session.update` 示例补 `keywords`，并说明语言／关键词是可选提示、越界取值应降级为不给提示）、本报告与 SDD ledger。
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
| P-08 条件／否定／确定程度变化 | 通过 | `qualifierLossInRewriteBecomesUnresolvedReview`、`semanticReviewMapsRisksIntoExistingReviewIssues` |
| P-09 `0012`／`v1.2.3`／`C++`／URL | 通过 | `identifiersVersionsSymbolsAndURLsBecomeProtectedLiterals`（四类均成为受保护值，且原子偏移能指回原字符） |
| P-10 中文数字／年份读法 | 通过 | `circleZeroYearSharesTheSamePositionAsItsArabicForm`、`itnVariantsShareTheSameScriptPosition`、`toleratesOmissionAndDigitReading` |
| P-11 表格转口语行列归属 | 通过 | `tableRowsKeepTheirOwnPricesAcrossRewrite`（忠实改写保序；跨行调价被门禁拒绝并逐字回退） |
| P-12 不完整 Markdown／代码／公式 | 通过 | `unterminatedCodeAndFormulaSurviveTheFidelityGate`（未闭合代码块与公式不丢内容；改写代码里的数值被拒） |
| P-13 原文注入不当指令 | 通过 | `instructionsInjectedByTheScriptStayInsideTheDataPayload`（注入文本只出现在 JSON 数据里，指令区不含脚本内容，注入文本中的数字同样受保护） |
| P-14 结构错误与重叠被拒 | 通过 | `groupingRejectsNonRangeFieldsAndIncompleteCoverage`、`rejectsOmissionsOverlapAndUnknownFields`、`rewriteRejectsUnknownAndDuplicateBlockIDs` |
| P-15 旧请求结果失效 | 通过 | `cancellationInvalidatesLateMapResponse`、`manualTakeoverInvalidatesOldPipeline` |
| P-16 精简与保真权限分离 | 通过 | `fidelityOperationsStillRejectOmissionsAsUnresolved`、`condenseReportsOmittedContentAsSkippedAndReviewable` |
| P-17 用户编辑后诊断失效 | 通过 | `editingSourceInvalidatesReviewState`、`latePreparationResultAfterEditIsDiscarded`（编辑后候选、审阅条目与块全部失效；旧 generation 的迟到结果不回填） |
| P-18 局部窗口失败不冒充成功 | 通过 | `oneWindowFailureKeepsOtherWindowsAndFallsBackOnlyLocally`、`laterWindowFailureDoesNotReturnPartialScript` |
| F-01 连续朗读不跳读 | 通过 | `bodyAloneMatchesWithProductionDefaults`、`tracksInsideSentenceAndAcrossSegments` |
| F-02 长停顿不抢跑 | 通过 | `detourHoldsAndFollowingSpeechRecovers`、`sustainedDetourEntersFreePlayAndLaterReanchors` |
| F-03 口头禅与插词 | 通过 | `toleratesSubstitutedTailAndShortInput`、`snapshotCompletedSequenceDrivesFollowPosition` |
| F-04 远处唯一短语 | 通过 | `distantUniquePhraseCannotAdvanceThroughPartialOrFinal` |
| F-05 相同开场短语消歧 | 通过 | `unrelatedSpeechAndRepeatedShortPhrasesDoNotMove`、`explicitManualSelectionMakesTheSamePhraseALocalAnchor` |
| F-06 修订不引发整行往返 | 通过 | `partialMovesProvisionallyAndFinalReplacesIt`、`partialCanPreviewForwardWithoutImmediateFinalRollback` |
| F-07 真实重读受控回退 | 通过 | `localRepeatCanReturnToPreviousSentence` |
| F-08 重复快照不重复推进 | 通过 | `snapshotRevisionReplacesTextAndDuplicateEventIsIgnored`、`repeatedWireEventDoesNotAppendTwice` |
| F-09 增量与全文不双计 | 通过 | `snapshotRevisionsReplaceTextAndFollowRevisions`、`partialMovesProvisionallyAndFinalReplacesIt` |
| F-10 旧 revision／eventID | 通过 | `duplicateSnapshotRevisionCannotAppendOrAdvance`、`lateFinalFromOlderItemCannotUndoNewerFinal` |
| F-11 旧 epoch／generation | 通过 | `pausedAndRetiredItemsCannotOverrideManualPosition`、`eventsAfterManualTakeoverCannotMovePosition` |
| F-12 sequence 缺口／回退 | 通过 | `RealtimeContractTests`（31 项 XCTest 全通过，含 sequence validator 用例） |
| F-13 未见过 hypothesis 的 final | 通过 | `isolatedFinalMismatchKeepsLastConfirmedPosition` |
| F-14 迟到 final 不覆盖新位置 | 通过 | `lateOldFinalCannotUndoNewerItem` |
| F-15 稳定前缀越界 | 通过 | `stableHypothesisPrefixLimitsPreviewToProvenText` |
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
| U-05 稿首稿尾三行模式 | 通过 | `stage preview shows one, two, or three actual display lines`、`line slots preserve a centered current row at script boundaries` |
| U-06 字号列宽变化位置不串 | 通过 | `display-line layout wraps at the requested width and preserves UTF-16 source ranges`、`manual display-line positioning preserves UTF-16 offsets and takes over voice assist` |
| U-07 无障碍与 Reduce Motion | 通过 | `controls remain visible for focus, menus, VoiceOver, and opt-in always-on`、`readingShortcutFocusPolicy`、`reduceMotionRemovesScrollAnimation`（Reduce Motion 下舞台不做位移动画，阅读位置仍更新） |
| U-08 后台更新不抢焦点 | 通过 | `readingShortcutFocusPolicy`（阅读区外焦点、控件焦点、popover 打开时方向键都不被舞台接管）；提词器与 App 均未注册 `NSEvent` 全局／本地监视器，阅读键只作用于舞台窗口 |
| U-09 显示预设持久化 | 通过 | `stage settings clamp and persist their supported ranges`、`stage visibility preferences default off and persist independently` |
| U-10 真实窗口可见性 | 未执行 | 需 UI 自动化逐次授权 |
| R-01 权限拒绝与 busy 不阻断手动 | 通过 | `manualOpenHasNoAudioSideEffects`、`readyz diagnostics do not override a valid realtime capability binding` |
| R-02 starting 期关闭 | 通过 | `manual open rejects during close and succeeds after cleanup` |
| R-03 stop 失败可重试 | 通过 | `stop failure remains fail-closed until an explicit stop retry`、`repeated close is idempotent` |
| R-04 设备拔插／蓝牙重连 | 部分 | `inputDeviceLossFailsClosedWithManualFallback`（失败即释放占用、关闭连接、不推进稿件、保留手动；真实拔插与蓝牙重连未执行） |
| R-05 队列风暴有界降级 | 通过 | `eventStormDegradesInsideBoundedTransport`（600 条事件连续灌入后舞台仍在跟随、无错误、位置在稿内）；传输层 `RealtimeEventStream.Limits.default` 本身有界（256 事件／4 MB），探针侧 `test_receive_loop_fails_instead_of_growing_an_unbounded_queue` |
| R-06 共享准入不复制模型 | 通过 | 服务侧具名证据：`test_tts_requests_share_one_admitted_worker_slot`、`test_same_tts_resource_key_remains_serialized`、`test_realtime_slot_remains_available_when_batch_lane_is_saturated`、`test_heavy_overlap_serialization_when_budget_constrained`（2026-09-28 重跑 25 项通过） |
| R-07 长时运行不泄漏 | 部分 | `repeatedStageCyclesReleaseResources`（20 轮开讲→跟随→关舞台，每轮占用归零、连接各关闭一次、采集各停止一次）；长时间连续运行未执行 |
| R-08 日志与导出脱敏 | 通过 | `observationsCorrelateCallAndRedactedFailure`、`mapDecoderReportsRangeGapWithoutExposingSourceText`、`reportCarriesOnlyAggregatesAndNoScriptText` |
| M-01 旧稿缺字段仍可读 | 通过 | `runSummaryWrittenBeforeIntraSegmentProgressStillLoads` |
| M-02 写入原子性 | 通过 | `sourceRevisionIsImmutableAndInvalidSaveLeavesPreviousBytesUntouched` |
| M-03 损坏保留原文件 | 通过 | `unknownFutureVersionFailsClosedAndCorruptDocumentsDoNotBreakListing` |
| M-04 块位置映射 | 通过 | `readingProgressRestoresTheExactOffsetInsideTheSameVersion`、`readingProgressFallsBackToSegmentStartWhenTheTextChanged`、`readingProgressMigratesOffsetWhenTheSegmentTextIsIdentical` |
| M-05 回退不删稿件 | 通过 | `rollingBackToAnEarlierVersionKeepsEveryScript`（回到旧版本只是切换选中，精简稿与源修订都还在） |
| T-01 recv 返回后才取时戳 | 通过 | `test_receive_loop_stamps_time_after_recv_returns` |
| T-02 ACK 后建立媒体原点 | 通过 | `test_media_origin_is_established_after_session_configuration` |
| T-03 终态绑定 commit event_id | 通过 | `test_commit_terminal_requires_the_matching_event_id`、`test_wait_for_terminal_ignores_other_commit_and_surfaces_errors` |
| T-04 revision 按 utterance 分组 | 通过 | `test_revision_tracker_scopes_regressions_to_one_utterance` |
| T-05 终态缺失与失败 | 通过 | `test_probe_measurements_record_hypothesis_without_losing_first_partial` |
| T-06 慢消费者与队列溢出 | 通过 | `test_receive_loop_fails_instead_of_growing_an_unbounded_queue`、`test_cli_reports_queue_overflow_as_input_error` |

合计 69 项：通过 66、部分 2、未覆盖 0、未执行 1。

### 4.1 Issue 验收项对照

下表把 11 个 Issue 正文里的 61 条验收清单逐条落到证据上。证据列的具名回归都能用 `rg` 在 `macos/SpeechRailApp/SpeechRailMacControlTests/`、`tests/`、`tools/` 中直接搜到（swift-testing 用 `@Test("显示名")`，XCTest 用方法名）；本轮已核过本节全部 78 个证据标识（76 条具名回归 + `TeleprompterCalibrationSource`、`TeleprompterCanonicalizer` 两个类型名，另有 3 个套件通配写法）在源码中字面存在。

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
| #105 | 重复标题、相似枚举、跳句、重读、脱稿回近处有正负对照 | 满足 | `unrelatedSpeechAndRepeatedShortPhrasesDoNotMove`、`localRepeatCanReturnToPreviousSentence`、`bodyAloneMatchesWithProductionDefaults` |
| #105 | 不靠「永远不动」规避误跳，同时报告滞后、停滞与人工纠正 | 边界 | 确定性侧由回放评估器输出（`tracking_latency_p50_ms`／`tracking_latency_p95_ms`、`failed_sample_count` 等）；**真实语速下的三者对比需真实音频授权** |
| #105 | F-01～F-07、F-17～F-22 与参数／策略 revision 可追溯 | 满足 | 台账 F-01～F-22 全通过；报告只输出聚合量 |
| #105 | 旧 generation、手动接管后到达的结果无推进权 | 满足 | `pausedAndRetiredItemsCannotOverrideManualPosition`、`eventsAfterManualTakeoverCannotMovePosition` |
| #106 | 有／无稳定信息的同文本事件可区分，invalid span 拒绝或降级 | 满足 | `stableHypothesisPrefixLimitsPreviewToProvenText` |
| #106 | emoji、组合字符、中英混合的 codepoint 与 UTF-16 不错位 | 满足 | `preservesUTF16SourceRangesAcrossSupplementaryCharactersAndFillers`、`sourceUnitsRoundTripUTF8AndDoNotSplitGrapheme` |
| #106 | 同音频重复解码不累计为新增证据；稳定前缀被改写时不推进 | 满足 | `snapshotRevisionReplacesTextAndDuplicateEventIsIgnored`、`repeatedWireEventDoesNotAppendTwice`、`stableHypothesisPrefixLimitsPreviewToProvenText` |
| #106 | 共享 Realtime 调用方回归通过，助手／会议／字幕不退化 | 满足 | 本机实测（2026-09-28）：`RealtimeContractTests` 28 项、助手等共享调用方套件（`Assistant*`／`Realtime*`／`ServiceContractTests`／`Control*`）合计 185 项、全量 XCTest 344 项，均 0 failures |
| #106 | F-08～F-16、F-21；配合 #105 统一授权 | 满足 | 台账 F-08～F-16、F-21 全通过 |
| #106 | 逐段列出已验证／未验证字段；不宣称解决 ASR 正确率 | 边界 | 已验证字段＝内部类型化 evidence；**worker 是否真实产出高质量稳定前缀仍未验证**，本轮未跑真实 ASR |
| #107 | 构造「partial 前进→final 未匹配→恢复」并分别断言三位置 | 满足 | `partialMovesProvisionallyAndFinalReplacesIt`、`isolatedFinalMismatchKeepsLastConfirmedPosition`、`oneWindowFailureKeepsOtherWindowsAndFallsBackOnlyLocally` |
| #107 | 差异不足、同 item 修订收缩不触发整行反向移动 | 满足 | `partialCanPreviewForwardWithoutImmediateFinalRollback`、`snapshotRevisionsReplaceTextAndFollowRevisions` |
| #107 | 重读、点击本句、上下行键仍可回退；旧 generation 不移动位置 | 满足 | `localRepeatCanReturnToPreviousSentence`、`manual display-line positioning preserves UTF-16 offsets and takes over voice assist`、`pausedAndRetiredItemsCannotOverrideManualPosition` |
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
| #110 | 同一显示文本的合法读法可定位；不等价数值不被别名吞并 | 边界 | 数字／读法等价已在 `TeleprompterCanonicalizer` 与对齐器实现（`itnVariantsShareTheSameScriptPosition` 等）；**术语／缩写别名通道按方案要求仍关闭**（见 §5 第 4 条） |
| #110 | emoji、组合字符、英文术语与中文数字映射可逆且不越界 | 满足 | `preservesUTF16SourceRangesAcrossSupplementaryCharactersAndFillers`、`circleZeroYearSharesTheSamePositionAsItsArabicForm` |
| #110 | cue／skip 不进入已读覆盖率、语速估计或语音定位 | 满足 | 删减转 `skip` 且保留原文：`condenseReportsOmittedContentAsSkippedAndReviewable` |
| #110 | 同版本可恢复句内位置；不同 revision 不复用旧偏移；旧稿／损坏／写入失败不丢数据 | 满足 | `readingProgressRestoresTheExactOffsetInsideTheSameVersion`、`readingProgressFallsBackToSegmentStartWhenTheTextChanged`、`runSummaryWrittenBeforeIntraSegmentProgressStillLoads`、`sourceRevisionIsImmutableAndInvalidSaveLeavesPreviousBytesUntouched` |
| #110 | M-01～M-05、P-05／P-09／P-11／P-12 使用生产 Store／mapper | 满足 | 台账 M-01～M-05 全通过 |
| #111 | 保真操作不因目标时长删信息；有损操作单独动作且删减可见 | 满足 | `fidelityOperationsStillRejectOmissionsAsUnresolved`、`condenseReportsOmittedContentAsSkippedAndReviewable` |
| #111 | 锁定内容有效；无法达标时诚实报告 | 满足 | 删除锁定单元整轮失败关闭（Task 8 记录）；时长估计来源见 §2 第 10 条 |
| #111 | 试读校准复用既有类型与入口；证据来源清晰 | 满足（部分） | 新增 `TeleprompterCalibrationSource`；**语音辅助试读不存在**，只有手动秒表 |
| #111 | 采用／放弃／编辑／取消均不覆盖原稿 | 满足 | `rollingBackToAnEarlierVersionKeepsEveryScript`、`editingSourceInvalidatesReviewState` |
| #111 | P-01／P-13～P-18 及候选版本隔离通过生产 seam | 满足 | 台账对应项全通过 |
| #112 | fake transport 能观察 language／keywords 进入正确字段；其他调用方不变 | 满足 | `voice start hands the recognizer the script's keywords and the chosen language`、`an out-of-contract language degrades to the server default` |
| #112 | 不支持语言／能力、busy、权限拒绝不阻断手动看稿 | 满足 | `readyz diagnostics do not override a valid realtime capability binding`、`manual open is readable without microphone, transport, or model work` |
| #112 | 主动语音试读显示真实链路状态，不以输入电平冒充定位成功 | 边界 | 设备失败归因已修（`an input device that disappears fails closed and keeps manual reading`）；**语音辅助试读本身不存在**，见 §5 第 4 条 |
| #112 | 设备变化、延迟连接、停止失败、重试与旧 generation 回归 | 满足 | `manual takeover during a delayed connect closes the late client`、`stop failure remains fail-closed until an explicit stop retry`、`repeated close is idempotent` |
| #112 | 用户未主动开启时零采集 | 满足 | `manual open is readable without microphone, transport, or model work`、`manualOpenHasNoAudioSideEffects` |
| #112 | R-01～R-08 及相关 F／U 用例有证据 | 满足 | 台账 R-01～R-08（R-04 部分）、F／U 对应项；**真人语言效果仍单独验收** |
| #113 | 预设可逆，宽窗不强迫长横向扫读；1／2／3 行与极端字号有布局测试 | 满足 | `stage settings clamp and persist their supported ranges`、`stage preview shows one, two, or three actual display lines` |
| #113 | 宽度／字号变更后同版本同阅读位置不丢失 | 满足 | `manual display-line positioning preserves UTF-16 offsets and takes over voice assist`、`reading position resolves and steps across display lines without wrapping` |
| #113 | 控制显隐／错误提示不改正文几何；Tab／菜单／VoiceOver 可达 | 满足 | `controls remain visible for focus, menus, VoiceOver, and opt-in always-on`、`reading shortcuts require reading focus and never steal control keys` |
| #113 | 手动定位立即失效旧语音推进，恢复只从选定位置开始 | 满足 | `eventsAfterManualTakeoverCannotMovePosition`、`manual display-line positioning preserves UTF-16 offsets and takes over voice assist` |
| #113 | U-01～U-10 分层报告；真人观感另行授权 | 边界 | 台账分层见 §4；**U-10 真实窗口未执行** |
| #114 | 记录误推进、停滞、非意图回跳、跟随／恢复延迟、人工纠正、任务中断 | 满足 | 评估器输出 `tracking_latency_p50_ms`／`tracking_latency_p95_ms`、`reanchor_latency_p50_ms`／`reanchor_latency_p95_ms`、`stall`、`harmful_jump` 相关 caveat 与 `failed_sample_count` |
| #114 | 全部失败／超时／无匹配样本有分母；无结果用 null／not_run | 满足 | `failure_share`、`failure_share_exceeds_threshold`、`unlabelled_event_count`；缺 manifest／版本记录退出码 2 |
| #114 | 63 项既有用例保留，并补 #108 专属测试 | 满足 | 69 项（63＋T-01～T-06）；T-01～T-06 全通过 |
| #114 | 确定性对抗集无越权推进，且证明正常朗读未靠全停换安全 | 满足 | F-01～F-22 全通过，含正常跟随时延与重读回退对照 |
| #114 | 100ms／1000ms／2000ms 标为待校准目标，不作为已有成绩 | 满足 | 方案 §0 数值标注为 **P**；本报告 §3.2 声明全部质量门槛未验证 |
| #114 | 真实素材、音频、完整转写、hash、私有路径不进仓库 | 满足 | `reportCarriesOnlyAggregatesAndNoScriptText`、`observationsCorrelateCallAndRedactedFailure` |
| #114 | 集成报告区分代码／局部探针／生产 seam／真实声音／桌面观感 | 满足 | 本报告 §3.1／§3.2 分层列出，§3.2 明确未执行项 |

**对照小结**：11 个 Issue 正文共 **61** 条验收项（104:5、105:6、106:6、107:5、108:6、109:5、110:5、111:5、112:6、113:5、114:7），逐条已落表。**满足 53、边界 6、未量化 1、部分满足 1。**

- 6 条边界：#105 真实语速下「滞后／停滞／人工纠正」三者对比、#106 worker 是否真实产出稳定前缀、#107 与 #113 的实际滚动观感（U-10 未执行）、#110 术语别名通道（按方案要求保持关闭）、#112 主动语音试读（当前不存在）。每条都在「边界」列写明了缺什么。
- 1 条未量化：#104 要求「报告误报情况」。只逐例证明了无害改写不被阻塞（P-01），**没有汇总误报率**，不得据此推断低误报。
- 1 条部分满足：#111 要求试读校准的「手动计时、语音辅助试读」证据来源都清晰。手动计时已实现并带来源（§2 第 10 条），**语音辅助试读不存在**，未为对齐措辞虚构。

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

**保留 OPEN（5 个）与精确缺口**

| Issue | 已完成 | 仍缺什么 |
|---|---|---|
| #104 | 4／5 | 「报告误报情况」只有逐例断言，**没有汇总误报率**；需真实稿件样本与真实 LLM 运行 |
| #105 | 5／6 | 「同时报告正常跟随滞后、错误停滞和人工纠正」目前只有确定性回放口径，**真实语速下的三者对比**仍缺 |
| #110 | 4／5 | 别名通道是 Issue 标题范围内的能力，`match_phrases` 仍被解码器拒绝；按方案要求须随审阅 UI 交付，不单独放开模型注入 |
| #111 | 4／5 | 试读校准的**语音辅助试读不存在**，只有手动秒表；该项要求两类证据来源都清晰 |
| #112 | 4／6 | **主动语音试读本身不存在**，无从显示真实链路状态；相关两项随之待办 |

关闭不代表任何质量结论成立：§4.1 末尾列出的九项质量指标仍一项未测，真实音频时延基线与真人观感仍未产生。

## 5. 未完成与建议的下一步

1. **UI 视觉验收（U-10）**：`#113` 的显示设置弹层（场景分段控件、列宽滑杆）、最小 500 pt 宽度下的图标化“回到朗读位置”，以及 Reduce Motion 下的舞台滚动，都需要一次逐次授权的 UI 走查。策略层已有单测，视觉结论尚未产生。
2. **真实质量基线**：取得授权后按 §11.5 准备仓库外素材，先跑 #108 修复后的探针，再用 `teleprompter-replay` 与保留集做冻结验收；在此之前所有语音质量声明保持“未验证”。
3. **两项“部分”场景**：R-04 需要真实拔插／蓝牙重连，R-07 需要长时连续运行；两者都无法用 fake 证明，不接受用单测冒充。
4. **#110 术语别名通道**：`match_phrases` 仍被解码器拒绝。按方案要求别名必须由用户确认并绑定来源范围，该能力依赖审阅界面，应与下一轮审阅 UI 一起交付，不要单独放开模型注入。
5. **Xcode 单测挂死已解决，但成因是测试辅助件而非 App**：见 §2 第 9 条。`TestGate` 现为一次性开启，并附具名回归；`scripts/macos_app_build.sh --configuration Debug --test-unit` 现以 `** TEST SUCCEEDED **`、`test-unit: passed`、exit 0 结束。留在台账里是因为它给出一条通用教训：**挂死先二分到具体用例再下机制结论**，否则很容易把测试缺陷误判成 App 生命周期问题并据此改动生产语义。
6. **pbxproj 注册必须有 Xcode 侧证据**：本轮已证明 `plutil -lint` 与 SwiftPM 都不足以发现“文件挂错组”这类错误；后续任何新增源码都至少要跑一次包装脚本的 Debug 编译，测试文件还要跑一次 `--test-unit` 构建阶段。

## 6. 回退

- 本轮改动全部为增量：新增可选字段、新增类型、新增操作分支，未删除或重命名既有公共字段。
- 关闭有损精简：不再发起 `condense` 即可，已确认版本不受影响。
- 停用语义风险审阅：去掉 `withSemanticReview` 接线即可，硬门禁不受影响。
- 语言与关键词：置空 `preferredSpeechLanguage` 或让稿件没有关键词即回到服务端默认，不影响连接。

- 数据回退：所有新增持久化字段均可缺省，旧读取路径保持可用；未引入不可逆迁移。
- 场景预设：停用只需不再调用 `TeleprompterStageSettings.apply(_:)`；`contentWidth` 与 `preset` 是新增 UserDefaults 键，删掉后回落到「镜头口播」默认值，不影响已确认版本。
- 设备异常文案：`BlockReason.inputDeviceUnavailable` 是新增枚举分支，回退到上一版即可；旧分支 `serviceNotReady` 保持原样，不涉及持久化数据。
- 改稿失效修复：`updateSourceText` 现在清空 `readingBlocks`／`reviewItems`，与 `updateContentSelection` 一致；这两项本来就来自上一轮候选，回退不会恢复错误状态，也不需要迁移。

## 7. 复现方式

```bash
# 单元与回归
swift test --package-path macos/SpeechRailApp

# 探针回归（使用主仓库虚拟环境）
PYTHONPATH="$PWD:$PWD/src" python -m pytest -o addopts= -q tests/test_teleprompter_latency_probe.py

# 共享准入回归
PYTHONPATH="$PWD:$PWD/src" python -m pytest -o addopts= -q tests/test_resource_governor.py

# 确定性回放（素材必须在仓库外，且带数据集与版本记录）
swift run --package-path macos/SpeechRailApp teleprompter-replay \
  --manifest /path/outside/repo/replay.json --output /tmp/replay-report.json
```
