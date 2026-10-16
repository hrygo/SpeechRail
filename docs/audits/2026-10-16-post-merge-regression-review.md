# 合并后音频与转录链路回归审查

核验日期：2026-10-16。源码基线：`111185ea`（3.11.0），工作分支：
`codex/post-merge-regression-audit`。本文记录该基线及随后未提交修复的确定性证据，
不代表已安装版本或真实模型质量认证。

## 比较范围与结论

比较合并前功能分支 `1340630c` / `b007d828`、主线 `49abd8a4`、合并后的
`443c96d1` / `2932cdbc`，并核对 `111185ea`。

| 链路 | 结论与处理 |
| --- | --- |
| 音频生命周期 | 新的有界通道、XPC 连接身份、启动与清理 watchdog、异步停止和实际退出等待仍保留。但原启动等待器的预取消检查未接入生产 `XPCReplyLatch`；已恢复发送请求前的取消检查，并使回归直接测试生产等待器。 |
| 会议收尾与保存 | `preservingRecord`、窗口尾部保留、上传排空、SQLite 保存屏障和迟到辅助结果仍组合在生产链路中。新增音源中断与窗口封存、动态 S5 归属、保存失败重试的交叉回归，未发现这些行为被冲突解决覆盖。 |
| 字幕跟随与保存显示 | `CaptionBandWindow.swift` 从 `b007d828` 到 `2932cdbc` 再到基线 blob 相同；`TranscriptFollowState.swift` 在上述基线中也相同。末行跟随、主动回看、返回最新、静音状态稳定和有界展示的回归仍通过。标准转写回退路径存在保存确认前正文消失的既有缺口，现将当前记录已接纳但未保存的正式命令纳入浮层投影，按固定行 ID 去重。 |
| 动态分人 | matcher 的身份交换、短应答保留未知、重复音频不累积、离席返回、32 个身份工程边界仍通过。发现认证人数低于 32 时仍可能创建额外身份的既有缺口；现按认证人数限制新身份，超出时保持未知并返回 `speaker_capacity`，已知身份仍正常匹配。 |

字幕保存可见性问题和 native 认证人数问题在 rebase 前已经存在，不能归因为冲突覆盖。
启动预取消检查则是原启动实现与合并后生产等待器之间的行为差异。

## 修复与回归

### 音频生命周期

- 将实际生产使用的 `XPCReplyLatch` 移到已有共享源文件 `CaptureHelperProtocol.swift`，
  App 与测试使用同一实现，保留启动和停止原有的超时错误语义。
- 请求发送前检查任务是否已取消；取消时收束 deadline 任务。
- 移除已经没有生产调用的 `CaptureStartContinuation` / `CaptureStartTimeout`，
  将其测试替换为生产 latch 的预取消、在途取消、超时、迟到回复和首个回复胜出测试。
  XPC ownership、watchdog 和诊断的已有测试继续保留。

### 会议收尾保存

`MeetingWindowMergeRegressionTests` 使用生产 `MeetingSession`，只替换设备和网络边界：

- 分别模拟来源丢失和丢样；已上传的音频只提交一次，尾部窗口保存后再结束连接。
- 动态第五位说话人的归属写入同一条尾句；中断后原记录和占用仍保留，可继续恢复。
- SQLite 拒绝写入时保留恢复文字；连续重试只保存一次，重试不能伪造协议收尾成功。

异常源关闭会清空未确认安全的源队列；测试明确先确认 transport 已接纳输入，
再验证服务端尾部排空，不将被源侧拒绝的 PCM 计作已上传数据。

### 字幕投影

- 保存挂起和失败时，已经识别定稿的正文仍在字幕带；它不混入数据库镜像。
- 保存确认前后使用同一个行 ID，保存回调与队列移除交错时也只展示一次。
- 覆盖多条待保存正式文字与下一条实时预览共存、记录隔离、容量拒绝时正文保留。
- 没有修改滚动状态机、字体、布局 Token 或静音状态文案。

### 动态分人

- 认证上限设为五人时，第六个新身份不再产生 `S6`，返回未知及明确容量原因。
- 已达到认证人数时，已知身份仍可匹配；保留原有 32 人工程边界断言。
- App 新回归验证同一归属重复到达只写库一次、行索引裁剪保留已存身份，
  且重连后复用服务端编号不会继承上一连接的匿名身份。

## 验证证据

| 检查 | 结果 |
| --- | --- |
| 修复前字幕保存回归 | 保存确认前、保存失败后的正文可见性两处断言失败；修复后通过。 |
| 修复前生产 XPC latch 回归 | 预取消仍发送请求的断言失败，其余取消／超时／迟到回复测试通过；修复后通过。 |
| 修复前 native 认证容量回归 | 第六人未保持未知的断言失败；修复后通过。 |
| 会议收尾变异检查 | 临时关闭音源中断后的 drain，新组合测试产生五处失败；源码已恢复，最终测试通过。 |
| Swift 定向回归 | XCTest 191 项、Swift Testing 81 项（14 suites）通过；包含音频通道、四场景输入中断、四小时有界投影、会议／字幕生命周期、保存、分人与跟随。参数化 case 数与 test 数不混用。 |
| Python 定向回归 | 9 个文件、101 项通过；覆盖回溯窗口、辅助归属、分人资源隔离、时间线与公开契约。 |
| Native 协议 self-test | 通过，包含上述新增认证人数反例及原 matcher 场景。 |
| SwiftPM / Xcode 测试登记一致性 | `macos-test-target-coverage: OK`。新增用例均放入已有登记文件。 |
| App / helper Debug 构建 | `macos_app_build.sh --configuration Debug` 通过，结果为 `BUILD SUCCEEDED`；包装脚本退出后清理临时 App，未安装。 |

主要复现命令：

```sh
swift test --package-path macos/SpeechRailApp --enable-swift-testing \
  --filter 'MeetingSessionLifecycleTests|MeetingWindowMergeRegressionTests|CaptionSessionLifecycleTests|CaptionBandContentTests|XPCReplyLatchTests|CaptureHelperOwnershipTests|CaptureStartDeadlineTests|AudioSampleRingTests|AudioCaptureDrainTests|AudioChunkStreamTests|AudioInputTerminationTests|CaptureDeliveryWindowTests|CaptureAudioRelayTests|Transcript|MeetingSpeakerCapacityTests|SpeakerLabelingPersistenceTests'

uv run --no-sync pytest --no-cov \
  tests/test_realtime_auxiliary_attribution.py tests/test_realtime_revision_window.py \
  tests/test_asr_window_coordinator.py tests/test_meeting_diarization_session.py \
  tests/test_meeting_diarization_resources.py tests/test_diarization_session.py \
  tests/test_diarization_attribution.py tests/test_meeting_diarization_contract.py \
  tests/test_diarization_metrics.py

swift run --package-path native/diarization SpeechRailDiarizationProtocolSelfTest
python3 scripts/check_macos_test_target_coverage.py
bash scripts/macos_app_build.sh --configuration Debug
git diff --check
```

## 证据边界与回退

本轮未安装 App 或服务，未改变用户数据、selection、模型或运行配置，未推送或发布。
没有执行 UI 自动化、真实硬件采集、真实模型准确率／分人质量、延迟或 CPU 基准；
确定性检查不提升既有质量认证结论。特别是工程容量、匿名编号稳定和模型能准确区分多少人，
是三个不同的结论。

本轮不改变公开 wire 协议或数据库格式。回退可在评审时仅撤销本分支的三个修复及配套测试，
保留合并基线和用户数据；尚未执行提交或运行态替换。
