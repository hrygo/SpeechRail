---
title: "音色创建与使用端到端缺陷修复：Luna 实施方案"
status: draft
version: "1.0"
date: 2026-09-28
baseline: "main@0f171401"
evidence: "当前源码与契约核查；未执行运行态复现或测试"
---

# 1. 问题结论

本方案接续 2026-09-28 的音色创建与使用审计，范围贯穿 App、HTTP、服务编排、验证证据存储、音色注册、worker 与正式合成。目标是修复七项已定位的逻辑缺陷，不以“能出声音”代替端到端正确性。

| ID | 级别 | 缺陷 | 可观察后果 |
|---|---|---|---|
| F1 | P1 | App 正式配音没有发送严格验证策略 | 未验收或验收失败的克隆音色仍能制作作品 |
| F2 | P1 | 设计发布与克隆复验写出的验证范围不符合生产查询 | 验收通过但严格合成仍拒绝 |
| F3 | P1 | 严格验证在冷 worker 加载前要求当前运行身份 | 复验驱逐或空闲驱逐后，严格请求无法自己恢复 |
| F4 | P1 | 明确拒绝注册后 App 没有解除注册上下文 | 用户被要求重录，但重录、删除录音均被阻止 |
| F5 | P1 | App 遇到持久化 pending 只查询、不执行恢复 POST | 注册部分提交后可能永远显示处理中 |
| F6 | P1 | async 注册/预检同步执行 ffmpeg | 单 ASGI worker 的事件循环被阻塞，输出收集也缺乏前置上限 |
| F7 | P2 | 设计候选 failed 终态仍展示复验重试 | 每次重试都被当前状态机拒绝 |

方案补查确认一个实现前置缺口 C1：`ServiceAPIClient.runVoiceQuality` 调用 namespaced 端点，却返回 `VoiceQualityReportSnapshotV2`；该类型要求顶层 `status`，服务实际返回 `legacy_report/evidence/validation_persisted`。目前不能把这个现有方法直接接到按钮上，必须先修正响应类型。

**证据边界：**上述为代码路径与契约交叉核查，不是目标机故障实测。没有本次任务对应的 Issue/PR URL，不推断历史 PR 状态。图谱符号和覆盖率工具在审计时未成功暴露，结论以直接读取的源码为依据；不得称图谱覆盖完整。本轮只交付方案，不自动实施、运行测试、加载模型、操作服务、提交或发布。

# 2. 当前实现与根因

下列路径均相对仓库根目录。行号会变化，实施时按符号定位。

## 2.1 F1：生产消费没有继承质量门禁

- `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
  - `synthesizeAndSave` 只检查 `voice.available` 和 clone 的 1.0x 速度，随后调用 `createSpeechRender`。
  - `speechRequestOptions(for:)` 从 capability facade 取得请求参数。
- `macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift`
  - `SpeechRailCapabilityRevisionSelector.creatorRequestOptions` 只填写 expected voice/model revision。
  - `SafeVoiceEntry` 当前没有接收服务已返回的 production readiness 字段。
- `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`
  - `createSpeechRender` 透传 `options.validationPolicy`；调用方未提供时仍为 nil。
- `src/speechrail/http/routes/audio.py`
  - speech handler 将缺失 header 解释为 `allow_unverified`。
- `contracts/openapi.yaml`
  - `SpeechRail-Validation-Policy` 将 `allow_unverified` 定位于 audition/diagnosis。

深层原因是把“可路由”与“已通过输出验收”混为同一可用性。保留公共 HTTP 默认值和试听能力；修正 App 正式制作策略及可完成的验收路径。

## 2.2 F2：验证事实的生产者与消费者词义不一致

- `src/speechrail/http/routes/voice_designs.py::publish_candidate`
  - 写 `capability_key=<tier>.render`，同时写 `validated_for=[<tier>.render]`。
- `src/speechrail/http/routes/system.py::run_voice_quality`
  - 写 `validated_for=["output"]`，但 binding 与存储记录均未写 `capability_key`。
- `src/speechrail/application/capability_snapshot.py::_validation_state`
  - production readiness 要求 reference pass、synthesis pass、`"output" in validated_for`、绑定有效。
- `src/speechrail/domain/voice_validation.py::VoiceValidationRepository.get`
  - 指定 capability key 后必须精确匹配。
- `src/speechrail/http/routes/audio.py`
  - 严格合成使用当前 `<tier>.render` 查证据。
- `src/speechrail/http/routes/capabilities.py::respond`、`system.py::_voice_entry`
  - 部分 discovery 查询没有传 capability key，需要一起收敛，防止列表结论与执行结论不同。

根因是将“验证了什么”和“在哪个档位/模式验证”放进了同一个集合，另一路又完全省略作用域。

## 2.3 F3：验收与实际使用之间缺少运行身份绑定

- `system.py::_evict_quality_tts_if_supported` 以及设计复验在 ASR 阶段前主动释放 TTS。
- `backends/qwen3_tts.py::Qwen3TtsCapabilityRouter.evict_warm_capability` 关闭各 worker。
- `Qwen3TtsWorker.runtime_revision` 只在 ready 时返回身份；`synthesize` 在内部锁中按需 `_start_locked`。
- `audio.py` 的严格检查发生在 governor reservation 和上述启动之前。
- `runtime/local_file_processor.py::LocalFileJobProcessor._synthesize` 存在同样的前置检查。
- `runtime/job_runner.py` 已在 `governor.run` 中调用 processor，不能再套一次相同资源 reservation。

根因不是 evidence 应当被宽松接受，而是严格检查顺序无法获得其必需的事实。必须在资源准入后准备实际 worker，核对运行身份，再允许合成；不能通过记住旧 revision 或先生成一段试听音频绕过。

## 2.4 F4/F5：确定失败、未知结果与遗留 pending 没有分开

- `AppModel.registerCloneVoice` 在第一次提交前保存 `CloneRegistrationContext`，非不确定错误分支只更新文案。
- `discardCloneRecording`、`acceptCloneRecording` 阻止在 context 存在时替换录音。
- `clone_voice` 在参考质量拒绝时直接返回 400，尚未开始幂等注册。
- `clone_voice` 在 registry 已提交、journal.complete 失败时保留 pending；同 payload 的再次 POST 可以核对已有 profile 并补完 journal。
- `clone_idempotency_status` / `DurableIdempotencyJournal.lookup` 只读取状态，不恢复。
- App 在 lookup 返回 pending 时直接结束，因此根本触达不了恢复 POST。
- `clone_voice` 将 `publication_started=True` 置于调用 registry 前，之后的 abort 条件无法区分提交前确定拒绝与实际提交结果不明。

保留稳定注册 ID、payload fingerprint、create-only、原录音和未知结果保护；改变恢复动作与确定失败出口。不以删除 journal、换 key 或覆盖目标 ID 解决未知状态。

## 2.5 F6：同步进程生命周期进入 HTTP 事件循环

- `system.py::_transcode_clone_audio` 调用 `domain/tts.py::transcode_and_validate_clone_audio`。
- 后者同步 `subprocess.run(capture_output=True, timeout=10)`，在完整得到 stdout 后才检查时长/大小。
- clone 与 clone/validate 都从 async route 直接调用该函数。
- `http/routes/audio.py` 已有 `_run_ffmpeg_subprocess`、`_read_ffmpeg_stdout` 和 `_cleanup_ffmpeg_process`，可复用其有界 I/O 与取消回收机制，避免再实现一套子进程协议。

## 2.6 F7：终态与操作可达性相互矛盾

- 设计机器验证 reject 时，服务将 candidate.state 置为 failed。
- `AppModel.validateVoiceDesignCandidate` 为失败设置 `.validate` 重试步骤。
- `performVoiceDesignPublicationTask(.resumeValidation)` 不接受 failed。
- 服务 `validate_candidate` 也拒绝 failed。

保留 failed 为终态；此次不重新开放失败候选，不修改其已有证据。把终态动作改为明确的“重新生成候选”。

## 2.7 C1：质量检查响应模型未对齐

- `ServiceAPIClient.runVoiceQuality` 请求 `/v1/speechrail/voices/{id}/quality-runs`。
- `system.py::run_voice_quality` 的 namespaced 分支返回 envelope。
- `ServiceContractTypes.swift::VoiceQualityReportSnapshotV2` 解析的是里面的报告，不能承担 envelope。
- `contracts/openapi.yaml` 已定义 envelope，因此以既有契约修正客户端，不能让服务为错误 DTO 添加另一种顶层 status。

# 3. 目标行为

1. 系统音色保持当前制作路径；克隆音色（含设计发布的 clone）正式制作必须携带 `require_output_pass`。
2. 普通音色试听和预览使用 `allow_unverified`，页面明确区分“可试听”和“已检查配音效果”。参考预检不能被显示为输出验收通过。
3. 设计的机器验收与人工听审完成后，其发布证据可以支持同档位严格 render；普通 clone 通过输出复验后也可支持同档位严格 render。
4. 验收证据只适用于精确的 voice revision、model artifact/catalog/runtime、policy/recipe/preprocess 和 capability key。其他档位、streaming、变更后的模型均不能借用。
5. 冷 worker 上，同一严格请求能完成加载、验收证据核对和合成；不需要用户先执行宽松试听。缺失或过期证据仍拒绝，且拒绝前不产生音频。
6. 确定未注册的拒绝结果允许用户修改资料或重录；结果未知时保留原操作身份；遗留 pending 能通过用户重试恢复原操作，不制造第二个音色。
7. 转码期间健康请求与其他协程可以继续运行；超限、超时和取消均回收确切子进程并关闭 I/O。
8. 终态 failed 候选只提供重新生成/关闭等有效动作；网络故障留下的 validating 仍能恢复。
9. 已保存作品仍按其原音频回放、导出，不追溯撤销，不重新验收或删除用户历史数据。

# 4. 推荐解决方案

## 4.1 证据使用现有双字段，不另建兼容层

统一为：

```text
validated_for = ["output"]             # 验收维度
capability_key = "<active-tier>.render" # 唯一适用的执行规格
```

人工 identity/naturalness 仍按设计候选现有字段记录，不能由机器替填。普通录音 clone 的 output pass 不应被宣传为身份/自然度人工通过。

不选“消费者同时接受 output 或任意 .render 字符串”：这会延续歧义，并掩盖证据生产错误。旧证据保留但不自动提升为可用；用户可显式重新检查，生成新证据。不变更声学 revision、不重写参考音频。

## 4.2 严格准入采用准备身份、验证、执行身份钉住三步

在现有 TTS admission/application 边界增加受控的准备能力，启动目标 voice 所属的唯一 worker，不合成探针，不启动无关 lane。返回实际握手 runtime revision。随后调用同一验证函数，最后在真正发送合成请求前再次核对 runtime revision。

不选“discovery 预热”或“缓存上次 runtime revision”：discovery 必须只读，进程已关闭也不能被当作当前已观察。

HTTP 和 durable speech job 共用验证语义；job 已由 JobRunner 做 governor 准入，不能嵌套 reserve。Realtime wire 不新增策略字段，render 证据也不能声称覆盖 streaming。

## 4.3 pending 使用现有幂等 POST 恢复，不新增轮询后台任务

用户点击重试时先查询；completed 读取原 voice；pending 允许用原 ID、原 key、原冻结 payload 再次 POST。服务保留 create-only 与 fingerprint 校验，使恢复最多产生一个声学资产。未知状态、查询失败、已删除结果不可通过换 key 绕开。

不把 GET 改成有副作用的恢复接口，不添加永远轮询的自动任务，不根据“等了多久”判断注册没有发生。

## 4.4 转码提取既有有界执行器

将 audio.py 内成熟的 ffmpeg 执行辅助能力移至拟新增 `src/speechrail/application/ffmpeg.py`，由普通音频路径和 clone 转码共同调用。保留已有 decode/encode 的格式策略；clone 自己负责输入大小、45 秒时长与参考规范化策略。

仅 `asyncio.to_thread(subprocess.run)` 不能满足取消、输出内存上限和进程回收要求，因此不作为完成方案。

# 5. 详细实施步骤

## S0：确认基线并先补回归反例

位置：仓库根目录。

- 核对 `git status --short --branch`、`git rev-parse --short HEAD`；若不再是本方案基线，比较相关符号差异后更新方案执行记录。
- 先按第 7 节编写最小 fake 回归，特别是发布→冷却→严格合成、400 后重录、pending 原操作恢复。
- 现有测试通过不是反例不存在的证明；不要修改 fixture 使 fake 永远 warm 或自动补齐实际服务没写的证据字段。
- 本方案不授权执行测试；用户后续授权实施时按项目规则进行必要定向验证，不自动升级为完整 gate、UI 测试或真实模型验收。

完成条件：每项修改有明确失败断言；不依赖用户私有配置、真实录音或模型。

## S1：统一生产证据和 discovery

文件/符号：

- `application/voice_validation_gate.py::build_validation_binding/validation_state_for_voice`
- `domain/voice_validation.py::VoiceValidationRepository`
- `application/capability_snapshot.py::_validation_state`
- `http/routes/voice_designs.py::validate_candidate/publish_candidate`
- `http/routes/system.py::run_voice_quality/_voice_entry`
- `http/routes/capabilities.py::respond`

修改：

1. 在现有验证领域模块集中声明 output 验收维度；capability key 继续用 `domain/tts_routing.py::tts_capability_key`，不在各层手拼新表。
2. 设计发布证据写 `validated_for=["output"]`，保留机器实测得到的 capability key 及人工审听状态。
3. 普通质量运行在开始时捕获当前 TTS spec、clone artifact 与 voice revision，生成 binding 时传 render capability key，落盘时完整保留；质量运行期间不根据后来重新查询的档位改写原证据身份。
4. candidate validate 的显式 `body.capability_key` 必须等于实际执行的 active render key；不一致返回拟新增 `422 voice_design_capability_mismatch`，在启动模型前拒绝。当前代码只校验字符串格式，不能允许给一份实际 quality 输出标记成 reference。
5. discovery、rich voice 与严格请求均使用当前 render key 读取；不得使用无 scope 查询来宣称 production_ready。
6. 保留冷态 discovery 的 fail-closed：没有当前 runtime identity 时显示需要在使用时确认，GET 不加载 worker。
7. 旧格式记录不删除、不就地升级、不假定跨档位有效。更新正式文档说明重新检查路径。

完成条件：正常设计发布和普通 clone 复验都能写出消费者所需证据；其他档位、旧记录、无 output 维度均不能通过严格 gate。

## S2：修复冷启动准入，保持执行期间身份一致

文件/符号：

- `domain/ports.py::SpeechRequest` 及拟新增内部准备协议
- `application/tts_admission.py`
- `application/voice_validation_gate.py`
- `backends/qwen3_tts.py::Qwen3TtsWorker/Qwen3TtsCapabilityRouter`
- `http/routes/audio.py` 的 speech handler、`audio_stream` 和格式响应错误映射
- `runtime/local_file_processor.py::_synthesize`
- `runtime/job_runner.py` 仅验证既有 reservation 包含准备步骤，不新增第二层资源获取

具体设计：

1. 拟新增内部 `prepare_voice(voice, expected_voice_revision) -> str` 能力：返回真实、有效的 runtime revision；router 按 voice profile 选 lane；worker 在现有 `_incremental_slot`/`_lock` 顺序下启动。不调用 router.start 去启动全部 TTS。
2. 扩展内部 `SpeechRequest`，拟新增 `expected_runtime_revision: str | None`。这是进程内执行钉住字段，不加到 OpenAI JSON 或公共参数，不改 worker wire。
3. 新增共享 application helper（拟名 `prepare_validated_speech`）：
   - 接收已经过边界校验的 request、registry、artifact、capability key、synthesizer。
   - 非 clone/非 strict 保持现有路径。
   - 获取当前合法 profile，校验撤销和 expected voice revision；准备 worker；读取绑定并检查独立证据。
   - 通过后返回填写 voice revision 和 runtime revision 的不可变 request。
   - 不自行 reserve；由 HTTP 或 JobRunner 的现有 reservation 包住。
4. worker 在 `_start_locked` 之后、transport.send 之前比较 expected runtime revision。相同模型身份的重新加载可继续；身份改变、缺失都拒绝，不把 catalog revision冒充运行身份。拟使用独立内部错误，公共稳定码 `voice_validation_runtime_changed`。
5. HTTP 把原来 reservation 外的 runtime 验证迁入 `audio_stream` 的 reservation 内、读取第一块输出前；保留不需模型的参数/权限/voice 校验在前。
6. PCM 与各容器格式都要在发出 HTTP 200 前映射 gate 异常；沿用当前首块预读/完整容器处理，不把 409 降级成 502 或截断音频。gate 失败同时将 receipt/timing 置为失败，不留下 pending。
7. 一个请求的 queue、prepare、validate、synthesize 共享 deadline；取消必须传播至启动流程并释放 slot、lease。不能为准备过程重置超时。
8. job 路径调用同一 helper，将 gate 错误转为 `JobProcessingError`；保留 JobRunner 原有总 deadline。给 request 钉住 voice revision，避免验收后 alias 指向另一版再合成。
9. 注入 backend 无准备能力且没有可信 runtime identity 时必须拒绝 strict；更新测试 fake 显式实现准备/身份变化，禁止生产静默 fallback。

完成条件：冷态严格请求可成功；身份切换时在任何音频输出之前拒绝；失败后后续请求仍能取得资源。REST/job 结果一致。

## S3：App 补齐质量检查类型、状态与正式制作策略

文件：

- `SpeechRailControlKit/ServiceContractTypes.swift`
- `SpeechRailApp/CreatorServiceClient.swift`
- `SpeechRailApp/ServiceAPIClient.swift`
- `SpeechRailApp/AppModel.swift`
- `SpeechRailApp/CreatorSurfaceViews.swift`：`VoiceLibraryView`、`DubbingDeskView`
- `SpeechRailApp/VoiceCloneView.swift`

具体修改：

1. C1：拟新增 `VoiceQualityRunResponse`，字段映射 `legacy_report`、`evidence`、`validation_persisted`。复用报告 DTO 和已有通用 JSON/证据类型；必要的新证据类型只覆盖契约中的实际字段。`runVoiceQuality` 的 protocol、真实 client、fake 和返回值一起更新。
2. `SafeVoiceEntry` 接收现有 `production_ready`、`production_ready_reason`、`validation_state`；新增 typed presentation 仅解释这些事实，不再用 `available` 推断验收通过。缺失/未知字段不能默认 true。
3. `AppModel` 拟新增 `checkVoiceOutput` 动作和按 voice ID + revision + 请求 generation 绑定的检查状态，调用已有 namespaced quality-runs，默认复用 `VoiceQualityRunRequest()` 的 3 次配置，不自动减少验证量。
4. 音色库 clone 的详情区增加“检查配音效果”，注册成功状态增加“前往音色库检查”；不自动在注册成功时启动真实重计算。检查中阻止重复提交；切换选择、删除、改版后的迟到结果不能污染新选择。
5. 只有 `legacy_report.status == pass && validation_persisted == true` 才显示“本次检查通过”。`validation_persisted == false` 显示“检查已完成，但结果未保存，请重试”；HTTP 200 本身不是通过。
6. 检查成功刷新 capability 和 rich list。刷新后 runtime unknown 不能把刚结束的检查改为失败，也不能显示“当前生产已确认”；显示“检查已通过，生成时确认当前声音环境”。
7. 配音台始终为正式生成请求设置 `require_output_pass`；在 `createSpeechRender` 边界也保证该值，避免另一个调用点省略。`createSpeech` 的试听路径显式允许未验收。复制 options 时保留全部原字段。
8. 冷态 discovery 的 production_ready=false 不得永久禁用“生成语音”，否则会在 App 再造 F3。可路由音色允许发起严格请求由服务最终判定；被 409 拒绝时给出“先检查配音效果”的有效入口。
9. strict 返回缺少/过期证据时不自动降级重试，不自动追加一次质量运行，也不保存失败音频。
10. 保留现有 pendingDubbing 和用户显式保存：检查结果变化不删除已保存作品，不将历史作品纳入重新验收。

默认文案映射：

| 状态 | 提示/动作 |
|---|---|
| 仅参考注册完成 | “音色已保存，可以试听；正式配音前请检查效果” / “检查配音效果” |
| 正在运行 | “正在检查配音效果…” / 禁止重复点击 |
| 本次 pass 且已落盘 | “本次检查通过” / 可以发起严格生成 |
| warn/reject | “效果检查未通过” / 展示具体可理解原因 |
| 模型身份未知 | “生成时确认当前声音环境” / 允许服务受控准备 |
| 证据过期或缺失 | “需要重新检查配音效果” / 检查入口 |
| 未落盘 | “检查结果未保存，请重试” |

UI 使用设计系统的既有按钮、状态组件和 token；动作需键盘与无障碍可达。内部 capability/runtime 字段仅放技术详情。

## S4：解除确定失败锁定，并恢复遗留 pending

文件/符号：

- `AppModel.registerCloneVoice/lookupCloneRegistration/discardCloneRecording`
- `VoiceCloneView` 的注册、重录、表单可编辑状态
- `system.py::clone_voice/clone_idempotency_status`
- `domain/idempotency.py` 与 `domain/tts.py::create_cloned_profile`：优先保留现有持久化与 create-only 语义

App：

1. pending 只在用户显式重试时用冻结 context 再 POST；保留原 audio/name/ref_text/voiceID/key。自动查询不无限触发 POST。
2. 在确定发生于提交前的错误码白名单（`invalid_name`、`invalid_ref_text`、`invalid_audio`、`audio_too_short`、`audio_too_long`、`voice_quality_reject`）上清除 context，保留录音供用户回听，允许编辑和重录。
3. 清除 context 时同时刷新下一次逻辑操作的 key；若服务已保证这些码发生在 journal.begin 前，也可明确创建新 key。原 key 不再用于不同 payload。
4. 不按所有 400/409 一概释放：`voice_creation_failed`、冲突、invalid response、断连、取消、5xx 等可能有提交结果，继续保留身份，通过 lookup/replay 对账。新补充的确定失败码必须有服务端无副作用测试。
5. 未知结果期间表单显示冻结值并说明“正在确认上次注册结果”，提供“重试注册”；不要要求用户凭记忆恢复原文。离开再进入页面不得清空用于恢复的真实朗读文本而只保留默认提词稿。
6. completed 但原 voice 已删除/不可读时保持明确错误，不新建替代；重启恢复持久化草稿不在本次范围，不能承诺跨 App 重启保存内存 context。

服务：

1. name/ref_text/ID/保留 ID 等确定输入验证移到 journal.begin 前；依据契约校验长度，避免在创建中途才发现格式问题。
2. 维持同 key 不同 fingerprint=409；pending 重放时已有匹配 profile 则补记 completed；没有 profile 则在 create-only 下继续创建；已有不匹配 profile 则冲突，不覆盖。
3. 删除错误的 `publication_started` 常真式 abort 判断。明确提交阶段：prepared → commit attempted → committed。只有有证据证明没有副作用时才 abort；registry/journal I/O 不确定时保留 pending。
4. 并发同 key POST 仍通过 registry 原子 create-only 和 winner reconciliation 收敛；不同 key 同目标 ID 不允许覆盖。无需更改 GET 状态集合，也无需自动超时清理 pending。
5. 新异步转码会增加请求交错机会，必须覆盖两个重放请求同时进入创建的情况。

完成条件：400 质量拒绝后可以重录；registry 成功/journal 失败后重试恢复同一个 ID；并发重放只有一份有效资产，不无限 pending。

## S5：异步、有界、可取消地处理参考音频

文件：

- 拟新增 `src/speechrail/application/ffmpeg.py`
- `http/routes/audio.py` 的 ffmpeg 辅助函数与调用
- `http/routes/system.py::_transcode_clone_audio/clone_voice/validate_voice_clone`
- `domain/tts.py::transcode_and_validate_clone_audio`

实施要求：

1. 提取已有异步进程执行器，保留固定 argv、stderr 不回传原始文本、并发写 stdin/读 stdout、输出上限以及 terminate/kill/wait 清理行为。不得通过 shell 拼命令。
2. clone 路径 await 新执行器，输入上限 15 MiB；输出按当前 45 秒、24 kHz、单声道 PCM16 与必要 WAV 头余量做有界读取。超过上限立即终止，不能靠 `-t 45` 静默截断后接受。
3. 保留最短 2 秒、最大 45 秒，以及 signal quality/canonicalization 的现有判据。WAV 管道声明长度 sentinel 的处理需要保留测试。
4. 将可复用的 WAV 检查提取为纯函数；不要让 `domain/tts.py` 反向导入 application。同步函数若仍有明确非 HTTP 调用者，暂保留且复用纯校验；只有证实无调用才在同一范围删除，不保留无用 alias。
5. 单次转码使用当前 10 秒上限；如调用方已有更短剩余 deadline，取其最小值。取消时 reader/writer/process 都必须回收。
6. 信号分析的同步 CPU 工作移到可界定的线程任务，输入在此前已 bounded；取消不写 registry/journal。禁止将完整音频放日志。
7. 不引入新的模型资源 lane。转码并发若需限制，使用该组件自己的有界容量，不把本地音频解码伪装成一次模型推理。

完成条件：等待转码时独立协程仍前进；最大输出只多读一个探测字节；取消/超时/坏数据不留子进程。

## S6：终态动作与恢复动作一致

文件：`AppModel.swift` 的 publication retry/reconciliation、`CreatorSurfaceViews.swift::VoiceCandidateSaveSheet`；服务候选终态规则保持不变。

- failed：清除 `.validate` 重试动作，展示原因；提供“重新生成候选”。
- 重新生成使用现有候选 slot 的生成方法，但先结束当前 publication context；不复用 failed 的 candidate ID、target voice ID 或 idempotency key。
- 用户显式关闭/重新生成后才释放本地 publication context；保留服务端失败候选及证据，不隐式删除。
- validating 的断连/502：仍查询原 candidate 并恢复同一步。
- published：进入已保存对账，不重新生成。
- cancelled 或未知状态：分别显示终止或保守错误，不提供必然失败的验证重试。
- 调整 sheet dismissal，确保“重新生成”不会被自动 cancel 回调误伤新一轮 context。

完成条件：每个显示的按钮至少有一条成功可达的状态迁移；failed 不再进入 resumeValidation。

## S7：同步契约与正式文档

修改范围：

- `contracts/openapi.yaml`：说明两个验证字段含义、严格准入的冷启动顺序、拟新增稳定错误、pending 重放恢复语义；保留 quality-runs envelope。
- `docs/architecture/generated-voice-registration.md`：发布后同档位严格 render、旧证据需重新检查。
- `docs/architecture/voice-clone-quality-gates-and-contract.md`：仅修改与本次实现相关内容，不把 under_review 文档整体提升为已验收。
- `docs/users/api-contract.md`：试听/正式制作、验收与恢复流程。
- `docs/developers/macos-app-design-system.md`：新增质量检查状态与动作约定。

正文实质变动才更新 date/version。根 README 不在本次范围。MCP 保持已有工具调用与默认策略；若修改共享错误或模型导致其契约受影响，只补必要测试/说明，不增加新工具。

# 6. 关键实现说明

## 6.1 严格准入伪代码（拟新增 helper 的语义）

```python
# 调用方已取得 governor；本 helper 不再 reserve。
async def prepare_validated_speech(request, context):
    if request.validation_policy != "require_output_pass":
        return request
    with context.registry.lease_profile(
        request.voice, expected_revision=request.expected_voice_revision
    ) as profile:
        if profile.mode != "clone":
            return request
        runtime_revision = await context.prepare_voice(profile.id, profile.revision)
        binding = build_binding(
            profile, context.artifact, runtime_revision, context.capability_key
        )
        evidence = load_exact_evidence(binding)
        require_current_output_pass(profile, binding, evidence)
        return request.model_copy(update={
            "expected_voice_revision": profile.revision,
            "expected_runtime_revision": runtime_revision,
        })
```

以上 `build_binding/load_exact_evidence/require_current_output_pass` 是语义占位名，实现复用现有 binding/repository/state 函数，不机械新增三层包装。lease 的内部 registry 锁不能跨 await 持有；现有 lease 仅短时锁住快照和引用计数，保持这一语义。

准备后和实际发送间仍可能发生 idle close/reload，必须由 worker 的 `expected_runtime_revision` 再检查关闭 TOCTOU 缺口。不要只在 HTTP 做一次检查。

## 6.2 不将 cold 等同于未验收

服务 discovery 保持当前运行事实：没有 ready worker 就不声称当前 identity 已观察。App 同时保留“上次检查结果”和“当前生产准入”两个概念：

- 本次检查报告是一次历史观测，必须绑定 voice revision 与 run ID。
- production_ready 是当前绑定事实。
- 当前 identity 未知可触发严格准备，不能据此自动放行或永久禁用。
- 显式请求返回 409 后，由用户选择重新检查；绝不自动切换 `allow_unverified`。

## 6.3 注册恢复表

| 服务/传输结果 | App 上下文 | 后续动作 |
|---|---|---|
| 明确提交前 400 白名单 | 释放冻结 context，保留可回听音频 | 编辑/重录，下一次逻辑操作使用新 key |
| 201，或 lookup completed 且读取到预期 ID | 完成并释放 | 刷新列表，进入输出检查 |
| pending | 保留全部冻结 payload | 用户重试：同 key 同 payload POST 恢复 |
| 已发 POST 后超时/取消/断连/5xx | 保留 | 查询并按同一身份恢复 |
| 幂等冲突/目标冲突/未知状态 | 保留且展示明确冲突 | 不换 ID，不覆盖，不宣称仍在后台处理 |
| completed 但结果已删除 | 不重建 | 明确提示原结果不可用 |

禁止使用通用 `catch { reset() }`，也禁止所有 `catch` 都永远冻结录音。

## 6.4 质量维度与人工审听

仍保留 reference pass 的生产前提；reference warn 不因 output pass 自动转 pass。本次不调整信噪比、ASR 相似度或自然度阈值。普通 clone 的机器输出检查不会产生人工身份结论；设计音色依旧要求真实用户完成参考/复验音频听审后再发布。

# 7. 测试方案

所有下列新增测试名均为拟新增。测试以 fake worker/transport、合成音频和临时存储运行；本方案阶段全部未执行。

| 测试文件 | 必须新增/更新的断言 |
|---|---|
| `tests/test_voice_design_workflow.py` | 完整 create→confirm→machine→human→publish→冷 worker→strict render；发布记录含 output 和实际 render key；显式错档位在生成前拒绝；机器不能代替人工 |
| `tests/test_voice_quality_routes.py` | clone quality pass 落盘→strict success；warn/reject/未落盘不通过；实际 runtime/key 写入；registry 成功而 journal.complete 注入失败，再 POST 恢复 |
| `tests/test_voice_validation.py` | 全部 binding 维度匹配；旧无 key、错 key、无 output、旧 policy/runtime 不可通过；保存新证据不修改声学 revision |
| `tests/test_voice_safe_listing.py` | rich/safe/capability 的同档位 scope 一致；cold discovery 不加载模型、不假称 ready |
| `tests/test_speech_api.py` | cold strict 成功；无证据 409 且 synth 次数为 0；准备后身份变化拒绝；PCM/WAV 错误 envelope；默认 audition 仍允许；deadline/取消释放资源 |
| `tests/test_local_file_processor.py` | 与 HTTP 相同的 cold/pass/reject/身份变化结果；voice revision 钉住；失败不写 artifact |
| `tests/test_qwen3_tts_worker.py` | prepare 只加载目标 worker、不产生音频；实际发送前身份比较；退出重载相同身份可用；准备取消后可重试 |
| `tests/test_tts_voice_clone.py` | 异步 clone 转码正常/过短/过长/无效；纯 WAV 检查保持原边界；录音 clone 仍使用 Base |
| `tests/test_durable_idempotency.py` | pending/completed 重放、payload 冲突和并发 winner；GET 不写状态；没有成功证据不 abort |
| 拟新增 `tests/test_ffmpeg_async.py` | fake process 驱动 stdin/stdout 并发；max+1 上限、BrokenPipe、超时、取消、terminate→kill→wait；未泄露 stderr |
| `tests/test_openapi_contract.py` | 错误码、质量 envelope 和参数默认符合公开契约 |
| `SpeechRailMacControlTests/ServiceContractTests.swift` | 真实 envelope fixture 可解码；缺顶层 status 仍正常；persisted=false；render 总带 strict、preview 带 allow；复制 options 无字段丢失 |
| `SpeechRailMacControlTests/AppModelTests.swift` | 400 后能 discard/re-record；pending 重试使用同 ID/key/bytes；unknown 不释放；quality fail 不宣称可配音；迟到响应隔离；cold 仍发 strict；failed 候选不出现 validate 重试；validating 恢复仍可用 |

后端测试不能用永久 warm 的 fake 掩盖 F3：fake 必须能在 evict 后返回 runtime=None，prepare 后恢复身份，并可注入新的 runtime。验证 HTTP 最终失败必须同时断言没有音频、没有成功 receipt/timing，而不只检查状态码。

前后端一致性采用相同真实 envelope 的脱敏 fixture，至少覆盖新注册 clone、已验收、cold、证据过期、未落盘五类。不要只按 Swift DTO 手写假响应。

UI 点击测试和真实模型 E2E 暂不执行。若后续当次得到明确授权，人工/自动流程覆盖：录音拒绝后重录、设计失败重新生成、检查后直接正式生成、切页时迟到结果、冷态首次制作。真机音质与时延另按专项规则验收，不属于 fake 测试结论。

# 8. 验收标准

## 8.1 执行命令

以下为后续实施验证命令，**本轮未执行**。工作目录为仓库根目录；使用已安装的项目依赖，不为验证擅自下载模型、切换服务或升级工具链。

```bash
git status --short --branch
git rev-parse --short HEAD

uv run --extra dev pytest \
  tests/test_voice_design_workflow.py \
  tests/test_voice_quality_routes.py \
  tests/test_voice_validation.py \
  tests/test_voice_safe_listing.py \
  tests/test_speech_api.py \
  tests/test_local_file_processor.py \
  tests/test_qwen3_tts_worker.py \
  tests/test_tts_voice_clone.py \
  tests/test_durable_idempotency.py \
  tests/test_openapi_contract.py \
  -q --no-cov

# 下列文件在 S5 新建后才运行。
uv run --extra dev pytest tests/test_ffmpeg_async.py -q --no-cov

swift test --package-path macos/SpeechRailApp --filter AppModelTests
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests

git diff --check
```

Swift package 已编译真实 AppModel/client，但明确排除了 `CreatorSurfaceViews.swift`，因此以上单测不能证明新页面编译通过。后续获得构建授权后，读取 release skill 并使用：

```bash
scripts/macos_app_build.sh --configuration Debug
```

不裸跑 xcodebuild，不安装 `.app`，不运行 `scripts/macos_app_test.sh`。后者涉及 UI 自动化，必须有当前用户逐次明确授权。完整 pytest、完整 gate、真实模型质量/性能验收均不作为自动附加动作。

按实际变更文件执行项目既有 Ruff/Mypy 检查；不要为了“全绿”修复无关基线问题。若新文件进 Xcode target，核对项目当前引用方式，仅做必要 project 配置并按项目技能处理。

## 8.2 可执行验收清单

- [ ] F1：App 正式配音实际请求含 strict header；拒绝时无 pendingDubbing 音频，试听策略不变。
- [ ] F2：两种来源音色均能用自身正确证据通过严格 render；错 scope 或旧记录拒绝。
- [ ] F3：验收驱逐后不先试听也可严格合成；身份变化拒绝且没有音频输出；job 同样成立。
- [ ] F4：服务确定拒绝后立即可修改/重录，未知结果仍保留上下文。
- [ ] F5：完成日志写入失败后，一次用户重试可恢复原 ID；同 key 并发不重复资产。
- [ ] F6：fake 转码等待时事件循环中的独立任务前进；超限/取消的进程全部被回收。
- [ ] F7：failed 只出现有效终态动作；validating 可恢复；旧 sheet 回调不取消新 context。
- [ ] C1：质量 envelope 可解码；persisted=false 不显示验收已保存或已可配音。
- [ ] 安全：日志与 fixture 不含真实音频、prompt、转写、key 或私有模型路径。
- [ ] 现有作品回放/导出、系统音色、普通试听、显式保存行为保持。
- [ ] 正式文档和契约与最终代码一致；报告列出已执行命令、结果、未执行项和基线差异。

# 9. 风险与注意事项

- **授权边界：**当前用户只要求方案；本文件不是实施、测试、真实听审、构建、安装、运行态变更或发布授权。
- **改动次序：**先让服务正确消费证据，再启用 App strict。单独先改 App 会把正常制作全部挡住。
- **旧验证数据：**保留原记录和参考资产；不以补字符串自动提升旧证据。无 scope/错误维度旧证据需用户显式复验。已有发布候选可通过已发布 voice 的 quality-runs 重建 output 证据，无需删除或重新注册音色。
- **旧 reference warn：**维持现有严格判据，需用户录制合格参考；本次不通过降阈值消除阻塞。
- **公共行为：**保留 OpenAI speech JSON 和默认 audition 策略；变化集中在 App 正式制作、SpeechRail gate/error 和幂等恢复说明，不增加历史 alias。
- **冷启动：**增加可见等待，但必须共享总 deadline，不增加第二模型进程；不要承诺性能提升，实际时延未测。
- **TOCTOU：**准备后模型可变，执行前必须再核对；metadata rename 不应生成声学 revision，声学变更必须使旧证据失效。
- **异步重构：**同步 clone 转码改为 await 后原来被事件循环隐式串行化的注册会交错；create-only 并发回归不可省略。
- **故障恢复：**不能把尚未确认的提交解释为失败并丢弃唯一 key；不能清理真实 journal 来让测试通过。
- **UI：**新增输出检查必须有普通用户可见入口；不可只在开发者详情放必经动作。未知状态 fail-closed 不等于只显示禁用按钮。
- **测试限制：**fake 证明协议和状态机，不证明声纹相似、自然度、真实音频设备或长时稳定性。
- **不处理：**模型下载/切档、质量阈值调优、Realtime 产品策略新增、跨重启 App 注册草稿持久化、全局 AppModel/tts.py 重构、历史数据清理、README 改版。
- **回退：**本次不改 voice/作品持久化格式；按逻辑补丁回退代码即可保留资产。新完整证据记录可以保留，旧代码对额外合法 key 的行为以 repository 测试核对。若未来已部署，运行态回滚另按 release/local-deploy 流程，不通过删数据回退；禁止把撤掉 strict 当作修复质量闭环。

# 10. Luna 执行清单

1. [ ] **基线与反例**：核对 main/worktree 差异，定位上述符号；在第 7 节已有测试文件补反例。完成条件：每个 F 编号对应至少一个具体断言，未覆盖项显式列出。
2. [ ] **证据闭环**：完成 S1 的 producer、repository gate 和 discovery scope 收敛。完成条件：设计与录音 clone 的 pass 记录均能被正确 scope 消费，错 scope fail-closed。
3. [ ] **受控冷启动**：完成 S2 的目标 worker prepare、内部 runtime pin、HTTP/job 顺序与异常映射。完成条件：冷启动成功、身份漂移无音频、deadline/取消释放资源。
4. [ ] **注册恢复**：完成 S4 的确定失败释放、pending 同身份重放、服务提交阶段区分。完成条件：400 可重录；部分提交可恢复；并发无重复音色。
5. [ ] **有界转码**：完成 S5 的执行器提取与 clone await 接入。完成条件：事件循环前进、输出受限、子进程可回收；普通 audio 路径无回归。
6. [ ] **App 契约**：完成 C1 envelope 和 SafeVoiceEntry readiness 字段，更新 protocol/fake/client。完成条件：真实响应 fixture 解码成功，未落盘结果不提升状态。
7. [ ] **用户验收与制作**：完成 S3 的检查入口、状态文案、严格制作与冷态可达性。完成条件：未验收音色有下一步；正式请求不降级；试听不受无关限制。
8. [ ] **终态出口**：完成 S6 failed 重新生成及 sheet 生命周期隔离。完成条件：终态无无效重试，进行中恢复保持同一 candidate。
9. [ ] **文档与契约**：完成 S7，保留原状态级别，更新有实质变化文档的日期。完成条件：字段、错误、恢复步骤与实际代码一致。
10. [ ] **定向验证与交付**：按已获授权执行第 8 节必要验证，检查实际断言与 diff，不自动提交/推送。完成条件：报告逐项 F1–F7/C1 状态、证据、未验证事项、并行改动与回退方法；不得宣称真机端到端验收完成。
