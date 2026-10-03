# 服务端 Issue #138–#145：Luna 逐项修复与交付整合计划

日期：2026-10-03

交付对象：后续获得实施授权的 Luna

仓库：`/Users/hrygo/Documents/SpeechRail`

分析基线：`main`，`fe95b7836c69e32613ada0fe067a6a6f996973ad`，编写时工作区干净。

本文件是实施方案。当前回合只新增此文件，没有实施修复、运行本计划中的测试、提交代码、更新 Issue、部署或改变服务状态。下文标为“拟新增”的字段、函数和测试不是现有实现。

授权约束：后续“按计划修复”可覆盖业务修改及必要的定向验证；本项目 AGENTS.md 明确规定，未明确要求时不自动 commit、push 或创建发布物，因此本计划的逻辑提交点只作为分组建议。提交、推送、关闭 Issue、合并、安装发布与运行态操作分别按后续明确授权执行。完整测试套件、真实模型/音频验收、性能测试和 UI 自动化不纳入默认执行范围。

## 1. 问题结论

本次交付围绕已提交的八个缺陷，不扩大到 App、LLM 编排或完整 OpenAI API 支持。

| Issue | 优先级 | 已确认现象 | 推荐修复方向 |
|---|---|---|---|
| [#138](https://github.com/hrygo/SpeechRail/issues/138) | P1 | VoiceDesign 的数字错误能通过机器校验、人工评审并发布 | 数字独立硬门槛；版本化局部校验策略；阻止旧证据继续准入 |
| [#139](https://github.com/hrygo/SpeechRail/issues/139) | P1 | 两个异步校验均返回 200，但后完成者覆盖先完成者的 validation | 仓库锁内增量合并；保留评审与资产；限定身份冲突及容量行为 |
| [#140](https://github.com/hrygo/SpeechRail/issues/140) | P1 | durable ASR 的 timestamps 仍交给 vendor，未调用独立 aligner | 识别文本后对冻结文本做独立对齐；任务失败时不写成功制品 |
| [#141](https://github.com/hrygo/SpeechRail/issues/141) | P1 | durable TTS 接受非法 AudioChunk 并生成成功制品 | 复用公共音频流校验器与有界计数；异常及取消关闭迭代器 |
| [#142](https://github.com/hrygo/SpeechRail/issues/142) | P1 | 对齐器遗漏否定词、数字等口语内容仍被补进有效时间片 | 在扩展标点间隙前验证全部口语内容已覆盖 |
| [#143](https://github.com/hrygo/SpeechRail/issues/143) | P2 | REST aligner 超时成为无 request ID 的 500；confirm 超时误报 422 | 明确绝对期限、资源准入、超时与数据错误分类 |
| [#144](https://github.com/hrygo/SpeechRail/issues/144) | P2 | 文档/契约声明 400，代码/测试返回 422；ASR 502 未声明 | 执行明确的 400 语义，补齐 502；以行为测试约束错误契约 |
| [#145](https://github.com/hrygo/SpeechRail/issues/145) | P2 | diarized SSE delta 缺少 segment_id，无法关联 segment 事件 | 从同一分段载荷取 ID；增加服务端与官方 SDK 的关联断言 |

既有审查证据为代码读取和 fake backend 的隔离复现，不是生产模型质量或长时稳定性验收：

- #138：把合成测试句中的 `500` 改成 `900`，相似度仍为 `0.9655172413793104`，数字比较为 false，却 machine pass，人工双 pass 后发布返回 201。
- #139：使用 `asyncio.Event` 控制同一 ASGI loop 中两个真实异步校验的完成顺序；两次 200、两个返回 ID，最终只保留一个，另一 ID 的评审返回 404。
- #140：fake ASR 捕获 `include_timestamps=True`；独立 aligner 调用数为零，成功制品的 segments 为空。真实 vendor 失败属于依据代码的推断，本轮没有实测。
- #141：fake 返回 `response_id="one"`、`chunk_index=4`、一字节 PCM，任务仍成功并输出一字节文件。
- #142：`Do not pay 500 dollars` 仅返回 `Do / pay / dollars`，当前校验成功并生成 `Do / not pay / 500 dollars`。
- #143–#145：隔离请求确认上述错误分类、状态码与事件字段差异。

## 2. 当前实现与根因

以下路径均相对仓库根目录；定位以符号为准，实施前核对当前 HEAD，避免依赖变化后的旧行号。

| Issue | 当前定位 | 因果链与测试入口 |
|---|---|---|
| #138 | `src/speechrail/http/routes/voice_designs.py::_candidate_validation`、`_validation_id`、`publish_candidate`；`src/speechrail/application/voice_design.py::VoiceDesignValidation`、`VoiceDesignCandidate.passing_validation` | 相似度阈值独自决定 intelligibility；机器判定未调用既有 `voice_quality.transcript_numbers_match`。人工评审只能检查旧 machine_status；发布写入 `probe_set="voice_design_base_v1"`。现有 ID 不包含转写结果及局部校验策略。测试从 `tests/test_voice_design_workflow.py` 扩展。 |
| #139 | `voice_designs.py::validate_candidate`；`voice_design.py::VoiceDesignRepository.update_with_validation_audio` | 请求在 await 前取得 candidate 快照，await 后从快照构造整个 validations；仓库虽然持锁，却整体替换为调用方传入的 updated_candidate。锁只能保证写入互斥，不能阻止丢失更新。 |
| #140 | `src/speechrail/runtime/local_file_processor.py::LocalFileJobProcessor._transcribe`；`src/speechrail/application/services.py` 的 processor 注入 | request 直接转发 timestamps；仅 diarize 分支用 aligner。REST 已改为文本识别后独立对齐，job 没有同步。`job_runner.py::run_once` 已在外层提供 governor 与任务期限。 |
| #141 | `local_file_processor.py::LocalFileJobProcessor._synthesize` | 直接拼接 `synthesizer.synthesize` 的 chunk.audio，绕过 `src/speechrail/application/tts_delivery.py::iter_validated_audio` 对 response ID、索引、PCM 字节完整性的校验。 |
| #142 | `src/speechrail/application/alignment.py::validate_alignment`、`_SpokenProjection`、`_with_leading_gaps` | token 可以在 cursor 后跳跃查找；未验证跳过部分是否含口语字符，随后把所有 gaps/tail 附到时间片，制造对齐成功。 |
| #143 | `alignment.py::FixedTextAligner.align`；`src/speechrail/http/routes/audio.py` 的 ASR 对齐阶段；`voice_designs.py::confirm_candidate` | FixedTextAligner 不分类 TimeoutError；REST 对齐在现有推理期限之外，仅捕获 TranscriptAlignmentError。confirm 的 OSError 捕获也捕获其子类 TimeoutError。 |
| #144 | `audio.py` 中 ASR stream、known-speaker、TTS stream_format 拒绝分支；`contracts/openapi.yaml`；`docs/users/api-contract.md` | 实现/测试维持 422，与明确的 400 承诺漂移。现有契约检查脚本不检查每个运行时错误状态，不能单独证明错误语义一致。 |
| #145 | `audio.py::diarized_events`；`tests/test_diarization_sdk.py`；`tests/openai-sdk-node/diarization.test.mjs` | delta 只带 type/delta，尽管后续 segment 载荷已有稳定 id。SDK 测试未断言关联字段；Node 现有文件主要验证 multipart 编码，不能证明服务端 SSE 行为。 |

额外查证：

- `tests/test_alignment_spoken_projection.py::test_spoken_match_covers_the_punctuation_it_swallowed` 只提供 `今 / 345 / 我`，却期望覆盖整句；`test_spoken_match_swallows_trailing_and_leading_punctuation` 未提供 `please` 却期望成功。这些 fixture 必须改成完整 token 覆盖，保留原有标点投影回归目的。
- 既有 `voice_quality.transcript_numbers_match` 已处理数字口语归一化，不能新增另一套数字正则口径。
- `VoiceValidationRepository` 已允许 probe_set，但证据 identity/get 不按它区分。`voice_validation_gate.py` 的正常证据读取和冷 worker 的 recorded-runtime 重建都可能读到旧 VoiceDesign 证据。
- 图谱 generation 为 `2026-10-01T23:35:51Z`。覆盖检查提示部分路径 metadata_changed/not_tracked；本方案相应结论使用当前源文件直接读取，不以图谱完整性为证明，没有重建索引。

> 🧠 **From Hindsight memory (Conventions and patterns)** — 历史约定强调行为回归先行、fake doubles 遵守真实边界、数字准确性与原始相似度分别判断，以及失败时不能制造时间片。本方案将这些约定与当前代码核对后使用；历史验收记录不作为本轮测试通过证据。

## 3. 目标行为

1. VoiceDesign 输出读错、漏读或多读数字时 machine_status 必须 reject，保留原始相似度用于解释；人工评审不得提升它，发布不得接受它，严格 TTS 不得接受旧漏洞生成的 output-pass。
2. 同一 candidate revision 的两个成功校验结果均持久化，其 ID、WAV 与评审状态可查询。并发中的终态/修订变化返回明确冲突，不回滚终态、不宣称成功后丢失记录。
3. job ASR 永远以 `include_timestamps=False` 解码文本；timestamps=true 通过本地独立 aligner 得到真实 segments，无法对齐时任务失败。普通文本请求不调用 aligner。
4. job TTS 的 PCM 必须满足统一交付校验，任何非法 chunk 或不完整输出均不能成为成功 artifact。
5. 对齐允许归一化后的标点差异，禁止遗漏实际发音内容；返回文本仍是冻结文本的原始 code-point 切片。
6. REST 的推理和后处理共享一份明确的绝对期限；超时为 503/backend_timeout/retryable=true，资源满为 429/backend_busy，配置缺失与 vendor 非法输出保留各自稳定错误。
7. 明确不支持的选项为契约约定的 400；一般输入 schema 校验继续 422。对齐/分人无效结果的 502、超时 503 和 request ID 在实现、契约、文档、行为测试中一致。
8. diarized delta 的 segment_id 必须指向本次响应里对应的 segment.id，并保持原事件顺序及最终 text。

声明边界保持为 SpeechRail 的 ASR/TTS 子集；本轮不承诺 TTS SSE、LLM responses/tool calls、已知声纹身份或完整 OpenAI 模型能力。

## 4. 推荐解决方案

按单一执行分支串行完成，推荐顺序：

```text
#142 → #143 → #140 → #141 → #139 → #138 → #145 → #144 → 交付整合
```

依赖理由：#142 是真实时间片的基础；#143 提供对齐异常/期限规则；#140 复用二者。#139 先修持久化，再由 #138 增加校验证据字段。#145 修事件；#144 最后统一错误契约，但每个前序修复仍须同时更新其直接影响的契约和文档，不能留到最后才使测试恢复。

不建议并行写 `audio.py`、`voice_designs.py`、`local_file_processor.py`、`openapi.yaml`。这八项的共同文件较多，串行实施比拆分后解决冲突更容易保持可评审状态。

关键决策：

- **#139 采用锁内增量合并，保留合法并发。** 单 candidate single-flight 虽可规避本次丢失更新，却改变当前允许的并发行为，仍不能解决其他调用方整体替换的问题。把读最新状态、检查 revision/state、合并一条 validation、校验容量、写资产/记录集中到仓库事务。
- **#138 对局部策略做版本化。** 拟新增 `validation_policy_revision`，旧记录缺省为 legacy；新结果使用 `voice_design_text_fidelity_v2`，发布证据使用 `voice_design_base_v2`。共享 quality policy、模型 recipe 和已有 clone 证据不做全局失效。生产证据读取排除已知受影响的 `voice_design_base_v1`，保留完整历史数据。
- **#143 不吞超时为“非法数据”。** 保留 TimeoutError 到有 request ID 的 HTTP 边界；task runner 的任务超时仍由外层映射为 job_timeout。不要重新起算阶段期限，也不要用全局 500 handler 掩盖分类问题。
- **#144 修实现以履行现有 400 契约。** 不简单把文档改为 422 来迎合漂移；一般 schema 错误维持 422。用表驱动请求验证错误状态及 OpenAPI 声明，避免扫描源码数字的脆弱检查。

## 5. 详细实施步骤

### 单元 A：#142，拒绝不完整口语覆盖

修改 `alignment.py::validate_alignment`，在 literal/projected 匹配成功且扩展 gaps 前：

1. 为首 token 前、相邻 token 间、末 token 后的未匹配原始区间增加检查（拟新增 helper）。区间只可包含 vendor 不发音的分隔/标点；含 `_is_spoken_char` 的遗漏内容返回既有 `text_mismatch`。
2. projected 路径内部允许 `3:45→345`、`p.m.→pm`、`forty-two→fortytwo`，同时证明它覆盖对应口语字符，没有跳过另一词。literal/projected 路径执行相同完整性不变量。
3. 保留中文单字 token、apostrophe、单调时间与 sample span 检查。组合字符沿用现有 tokenization 语义，增加重音字符测试，不凭 Unicode 类别随意删除音素或改写文本。
4. 调整上述两个缺失 token 的旧 fixture 为完整 token 序列；增加独立失败用例，不能仅把“成功”断言改成失败后丢弃标点测试。

完成条件：缺否定词/数字/首词/尾词均失败；全覆盖的真实 vendor tokenization 仍通过，单位切片无损拼回 frozen text。逻辑提交建议：`fix: reject incomplete spoken alignment coverage`。

### 单元 B：#143，统一期限与异常分类

修改 `audio.py` 的 ASR 推理、timestamp alignment、diarization 后处理边界，`voice_designs.py::confirm_candidate`；按需补充 `alignment.py` 与 shared admission 的注入。

1. 先增加两个原始回归：aligner 抛 TimeoutError；confirm 的 ASR 抛 TimeoutError。断言 503、backend_timeout、retryable=true、JSON envelope 及 X-Request-ID。
2. 在当前推理准入开始前创建一次 `expires_at = loop.time() + resolved.request_timeout_seconds`。这段流程中已有解码、排队、ASR、对齐及分人共享该期限；上传接收及既有上传解码限制按原契约处理，不声称覆盖客户端上传耗时。
3. 使用 absolute timeout 或剩余预算包围后处理；governor/admission 的 deadline 参数按其当前“时长”语义传 remaining，不把绝对时间直接传进去。所有捕获点保持 TimeoutError 分类，不能再给 alignment 完整的新时长。
4. REST 使用 `services.alignment_admission` 限制 alignment owner。资源满返回 429/backend_busy；没有 aligner 返回既有 503/timestamp_alignment_unavailable/retryable=false；对齐返回 failure 仍为 502/timestamp_alignment_unavailable。分人复用同一 deadline，但不因本次修复制造嵌套的同一 admission。
5. `confirm_candidate` 的 TimeoutError 捕获必须位于 OSError 前，使用既有 503/backend_timeout，真正的 reference/audio 数据无效仍走原 422。
6. `CancelledError` 继续传播。验证取消、timeout 和 capacity-full 后资源计数归零；worker 已有 transport reset/期限保持有效，不引入重试或二次 ASR。

完成条件：所有上述错误可稳定分类，慢 ASR 后留给 aligner 的预算实际减少，无资源槽泄漏。逻辑提交建议：`fix: classify speech workflow timeouts consistently`。

### 单元 C：#140，job timestamps 复用独立对齐

修改 `local_file_processor.py::_transcribe`、constructor 和 `services.py` 中 processor 构造；按需引用 `alignment.py::align_transcript_timeline` 与 shared AlignmentAdmission。

1. 增加 timestamps=true 的 fake 任务回归：记录 ASR 请求，并返回完整的 frozen text；fake aligner 返回确定时间片。
2. 时间戳需求在开始解码/ASR 前检查 aligner 可用；缺失时以 `timestamp_alignment_unavailable` 失败，避免做无用推理。ASR request 固定 `include_timestamps=False`。
3. 识别完成后按 REST 同样的规范冻结规范化文本，再申请 alignment admission，使用 `align_transcript_timeline(..., granularities=frozenset({"segment"}))`。当前 job 制品没有 words，不能顺手新增 word 字段或新的 job 参数。
4. timestamps=false/diarize=false 不调用 aligner；diarize=true 复用现有分人对齐链，不为 timestamps=true 再做一轮重复对齐。补 `timestamps×diarize` 四组合测试。
5. 对齐失败映射为 JobProcessingError 的稳定 code；admission 满映射 backend_busy。外层 runner 的 deadline/governor 继续拥有任务生命周期，processor 不嵌套同一 governor，也不重置期限。
6. 完整成功后才序列化并写 transcript artifact。失败、超时、取消均不得写成功路径或留下可被 runner 当作成功的文件。

完成条件：ASR 从未收到原生 timestamps，独立 aligner 正好执行所需次数；JSON 的 text、language、duration_ms、segments 结构保持兼容。逻辑提交建议：`fix: align durable transcription timestamps locally`。

### 单元 D：#141，job TTS 使用统一交付校验

修改 `local_file_processor.py::_synthesize`，复用 `tts_delivery.py::iter_validated_audio`，保留现有严格音色准入。

1. 把直接拼接 vendor chunk 替换为经统一校验器的输出。先读取该 helper 当前签名及现有 REST 调用方式，不能另写一套索引/PCM 校验。
2. 验证首 chunk index=0、递增顺序、单一 response ID、PCM 偶数字节。空流、非法流、合法前缀后异常均失败，不写 artifact。
3. 保留 `_MAX_ARTIFACT_BYTES` 有界累计；超过上限仍为 job_input_too_large。非法交付映射既有 job_processor_failed，保留 TtsBackendError 当前输入错误/strict-validation 分类。
4. 确保 validator、processor 和 runner 的取消链关闭底层 iterator；超时归 runner 的 job_timeout，不吞掉取消。
5. 测试合法多 chunk 输出逐字节准确，strict voice gate 依旧在任何 synthesize 前执行。

完成条件：原一字节反例失败且无成功 artifact；容量保护、异常/取消清理和严格准入不回退。逻辑提交建议：`fix: validate durable speech audio before delivery`。

### 单元 E：#139，锁内合并校验记录与资产

修改 `voice_design.py::VoiceDesignRepository.update_with_validation_audio`、`voice_designs.py::validate_candidate`。

1. 用 asyncio.Event 控制两个自然异步校验的完成顺序；同步点放在 `_transcribe_pcm` 返回并释放 ASR lane 之后，避免持有串行 lane 等待第二个请求而造成测试死锁。不在同步人工评审读写之间人为插入 await，不把这种人工时序当作新缺陷。
2. 移除仓库对 caller-built updated_candidate 的依赖。调用方传 candidate_id、expected_revision、一条 validation、WAV 及大小约束；仓库在现有 file lock 内读取最新 candidate，再合并。
3. 允许新校验写入 `confirmed / validating / publishable` 且 revision 相同的 candidate。开始机器校验、人工听审写入和机器结果提交共用 `require_validation_writable`，在各自仓库事务内核验最新状态。若此前变成 `published / cancelled / failed` 或 revision 变化，返回现有 409 冲突，禁止恢复终态。这时并发请求可能一成功一冲突，不能声称两个都成功。
4. 同 ID 的机器事实一致时幂等保留已存记录，尤其保留 identity/naturalness 人工评审及 created_at；机器事实冲突返回 `409 voice_design_revision_conflict`，已存 WAV 身份冲突返回 `409 validation_audio_unavailable`，不覆盖。机器事实比较排除 updated_at 等时间字段与人工评审字段；candidate.updated_at 保留当前与新记录的较大值，防止旧结果重试导致更新时间倒退。
5. 新 ID 达到现有 max32 时禁止静默驱逐已返回的记录。拟新增 `409 voice_design_validation_limit_reached`；route 可提前检查，仓库仍须锁内检查，错误进入契约/用户文档。
6. candidate state 从合并后的完整列表推导：若已有当前有效完整 pass，则保持 publishable；否则本次 machine reject 为 failed，其他为 validating。开始新校验也复用 `review_state_for`，使后续 backend timeout 或容量拒绝不会将已审核候选降回 validating。state 推导集中为共享小函数供持久化与人工评审复用；#138 再加强“当前有效”条件。
7. 原有同一锁内的资产校验、写文件、保存记录及新文件回滚保持。只有本事务新建且保存失败的资产可清理；已有 WAV 和其他 validation 不删除。
8. 人工评审更新改为基于 repository.update 回调的 current 重新核验机器证据并查找目标 ID 后替换一项。此为防止调用方将来重复整体覆盖的边界整理，不能声称已复现同步 review 的自然并发缺陷；竞争写入测试在仓库事务前注入状态变化，明确属于事务边界验证。

完成条件：两次成功响应对应的 ID 重启后均存在，音频可取并通过 hash，评审不丢失；冲突/容量失败不产生孤儿资产。逻辑提交建议：`fix: merge voice design validations atomically`。

### 单元 F：#138，数字门槛及旧证据失效

修改 `voice_designs.py::_candidate_validation`、`_validation_id`、human_review 分支及发布；`voice_design.py` 的校验模型/通过选择/安全投影；`voice_validation_gate.py` 的证据读取；相关契约和文档。

1. 复用 `vq.transcript_numbers_match(test_text, transcript)`。转写缺失仍为 unavailable/warn；转写存在时，数字比较 false 无条件 machine reject，拟新增 failure code `transcript_numbers_mismatch`。原始 transcript_match 继续保存，不能伪造为零。没有数字的句子若转写平白加入数字，也应拒绝。
   验收补充：`confirm_candidate` 同样要求数字完全一致，拒绝时沿用 `400 transcript_mismatch` 且不写候选；等价口语数字仍通过。Base 低相似度优先保留 `transcript_mismatch`，数字错误只有在相似度足够时才成为主要失败原因，原始相似度保持可观察。
2. 拟新增 `VoiceDesignValidation.validation_policy_revision: str`，缺省 legacy 值供旧私有记录加载；新结果显式为 `voice_design_text_fidelity_v2`。拟新增 `transcript_numbers_match: bool | None`，旧/未获得转写为 None；不要存完整测试句或转写到公共结果。
3. `_validation_id` 加入局部策略 revision 和 transcript_text_sha256，避免旧数字漏洞结果或相同 WAV/不同 ASR 观察共享身份。新结果天然产生新 ID；旧记录/音频保留。
4. `passing_validation` 与人工评审前置条件要求当前策略、machine pass、数字比较 true 及既有 revision/runtime/capability 约束。旧 validation 保持可查看，但不能经人工评审变成当前可发布依据；返回既有 `voice_design_machine_validation_required` 并提示重新机器校验。
5. 发布只从符合上述条件的记录写 `probe_set="voice_design_base_v2"` 的输出证据；不改 voice revision、不重写参考音频、不改全局 POLICY_VERSION 或 Base generation recipe。
6. 在 `voice_validation_gate.py::load_validation_evidence` 和 `_binding_from_recorded_runtime` 共享同一个“生产可用证据”筛选规则：已知 `voice_design_base_v1` 无法提供 output-pass。正常与 cold-worker 路径一致，防止 discovery unready 而 strict job/REST ready，或反向漂移。
7. `VoiceValidationRepository.get/put` 的全局 identity 暂不扩展 probe_set。当前它们对同 binding 只保留最新一条，新 v2/full quality-run 可正常替代旧结果；有明确需求后再独立设计多策略历史保留，不在本次扩大持久化结构。
8. 添加旧 candidate record、旧已发布 voice evidence 两类 fixture：能读取历史，不触碰资产；旧 candidate 在非终态且可机器校验时重验；已 published 的 voice 通过既有完整 quality-run 获得新有效输出证据，不解封终态 candidate。人工 clone/完整 quality-run 的证据维持原来准入。

完成条件：数字反例不 machine pass、不可人工提升、不可发布；旧 v1 不 production_ready、不通过 strict REST/job；v2 或既有有效完整质量证据通过，冷 worker 的 recorded-runtime 行为仍符合 #129 回归。逻辑提交建议：`fix: require exact numbers for voice design output validation`。

### 单元 G：#145，SSE 分段关联

修改 `audio.py::diarized_events`、OpenAPI SSE 事件定义/示例、用户 API 文档及 Python/Node SDK 测试。

1. delta 添加 `segment_id=segment["id"]`，来源与紧随其后的 segment 事件一致；不得再创建另一个计数器或从 speaker label 推导。
2. 多段 SSE 断言每条 delta 均有非空 ID、仅关联本响应的一段，delta 内容与对应段文本一致；ID 跨 delta/segment 一致且分段之间不混淆。
3. 保留 delta→segment→最终 done 的顺序。done 文本仍来自 canonical transcript，不从带 speaker 标签的内容拼接；普通非 diarized 请求不强加这一字段。
4. Python 官方 SDK 用 fake ASGI 服务验证真实服务事件；Node fake-fetch 用本次服务端事件形状验证 SDK 解码，不把手写 Node fixture 单独算作服务端证明。

完成条件：至少两段/两位匿名 speaker 的事件关联通过服务端与 SDK 测试；文档示例字段一致。逻辑提交建议：`fix: associate diarized transcript deltas with segments`。

### 单元 H：#144，契约与错误行为收口

修改 `audio.py` 三类 unsupported 分支，`contracts/openapi.yaml`、`docs/users/api-contract.md` 及相关 SDK/HTTP 回归。

1. ASR stream_unsupported、known-speaker unsupported_parameter、TTS stream_format_unsupported 显式返回 400。空参数、类型/范围错误等 schema failures 保持 422，不能批量替换所有 422。
2. 在 `/v1/audio/transcriptions` responses 增加真实可达的 502，声明稳定 ErrorResponse/request ID；核对 timestamp、diarization、formatting failure、backend_timeout 及新增 validation-limit 错误的状态和 retryable。
3. 更新旧测试中这三个场景的状态断言及官方 SDK 异常类型：unsupported 为 BadRequestError；真正 422 为 UnprocessableEntityError，其他字段继续检查 envelope。
4. 拟新增 `tests/test_audio_error_contract.py`，表驱动场景同时检查 response status、error.code、retryable、X-Request-ID，以及该操作的 OpenAPI responses 包含状态。通过 HTTP 请求验证，不从源码文本推断。
5. `check_openapi_contract.py`、`check_user_doc_contract.py` 保留现有职责，用行为测试补齐它们不能证明的错误语义；无需做通用文档解析器重构。
6. 正式文档有正文变更时才更新 version/date。不修改 archive 或无关 README；若确需修改根 README，按项目规定同步双语。

完成条件：八个修复的直接 API 变化都有契约/文档/测试依据，400/422/429/502/503 分类一致；不能只凭静态契约检查退出码验收。逻辑提交建议：`fix: align audio errors with the public contract`。

### 单元 I：交付整合

逐项通过后再做跨入口 fake workflow：

- 对齐：REST 与 job 针对同一合成 PCM、同一冻结文本使用同一 fake aligner；正例时间片一致，漏词均失败，timeout 均走对应边界的稳定错误。
- 交付：相同非法 TTS chunk 在 REST/job 都被拒绝；job 无制品，REST 保持既有流开始前/后的错误语义，不声称已发送的响应还能改 HTTP 状态。
- 创作：create→confirm→validate→human_review→publish→strict REST/job；数字反例在 validate 阶段阻断，完整正例完成。并发 validate 的两个成功 ID 均可检索/取音频/评审。
- 准入：旧 v1 candidate/已发布 voice evidence 不准入；重新校验的新证据与完整 quality-run 证据恢复准入；冷 worker 与已加载 worker 的发现/strict gate 一致。
- SDK：diarized SSE 关联和 unsupported 400、alignment 502、timeout 503 同时符合公开子集契约。

整合测试可放入拟新增 `tests/test_server_workflow_integration.py`，共享既有 fake builders；若复用 fixture 必须跨测试文件导入私有实现，应提取最小共享 fixture，而不是复制整套测试应用。测试只固定边界和结果，不镜像实现细节。

## 6. 关键实现说明

### 校验状态与人工评审

拟定有效性谓词：

```text
current_machine_pass(validation, candidate):
  same candidate revision
  AND validation_policy_revision == voice_design_text_fidelity_v2
  AND machine_status == pass
  AND transcript_numbers_match == true
  AND current runtime/capability binding satisfies existing checks

complete_pass:
  current_machine_pass AND status == pass
  AND identity_status == pass AND naturalness_status == pass
```

实现中的 revision/capability/runtime 检查分布需保持各边界的既有职责；不能仅检查字符串 marker 就允许发布。人工双 pass 是必要条件，不替代机器文本准确性。

“旧证据失效”指不用于准入，不是删除、不改变历史 machine_status，也不自动改写用户数据。公共投影需清楚说明待重新校验；新增公开字段进入 OpenAPI 对应 schema。

### 原子合并顺序

```text
lock → load latest → check revision/state
     → compare duplicate identity OR check max32
     → merge one validation and preserve review
     → compute state from latest complete list
     → validate/write WAV → save candidate → return stored candidate
```

资产写入/保存失败沿用当前原子写与回滚。别用 `model_copy(update=...)` 绕过 max_length 后就假定数据合法；构造提交记录时显式验证模型不变量。返回必须是实际存储的 merged candidate。

### 对齐完整性

只允许把没有口语字符的 gap/tail 归到邻近 token。字母、数字、否定词不属于标点。不要用“gap 长度≤N”或“总体相似度≥阈值”放行缺词；不要强制空格切词而拒绝中文单字 token。

### 期限与资源

REST 为本次推理链建立一次绝对期限；job 使用 runner 既有期限。独立 alignment admission 与 ASR governor 是不同边界，不能重复获取同一个 governor/lane。超时/取消既要返回正确分类，也要释放 admission 和迭代器。禁止失败后自动调用另一个 ASR 或下载 vendor aligner。

## 7. 测试方案

以下是待执行计划；测试名为拟新增建议，现有文件名已经核对。所有新音频用合成 PCM/WAV，临时资产在 test tmp_path，不用真实转写、参考音频或模型。

| 单元 | 文件 | 最少新增/强化场景 |
|---|---|---|
| A / #142 | `tests/test_alignment_spoken_projection.py`；`tests/test_diarization_alignment.py` | `test_missing_spoken_gap_fails_closed`、missing leading/trailing/digit/negation；完整中英文 vendor tokenization；标点投影；Unicode offsets；word/segment granularity |
| B / #143 | `tests/test_transcription_api.py`；`tests/test_voice_design_workflow.py`；`tests/test_alignment_admission.py`；`tests/test_alignment_worker.py` | aligner/confirm TimeoutError；延迟 ASR 消耗后续预算；容量满；取消释放；worker timeout transport reset 原回归保留 |
| C / #140 | `tests/test_local_file_processor.py`；`tests/test_job_diarization.py`；`tests/test_job_runner.py` | timestamps/diarize 四组合；ASR false；aligner 缺失提前失败；text_mismatch/timeout/capacity；无成功 artifact |
| D / #141 | `tests/test_local_file_processor.py`；`tests/test_job_runner.py` | odd bytes、首索引4、索引缺口/回退、response ID变化、空流、部分后异常、取消、超容量、合法多chunk |
| E / #139 | `tests/test_voice_design_concurrency.py`（复用 workflow 文件的既有 fake helpers） | 双异步校验两种完成顺序；持久化重读；双音频 hash；已评审记录保留；同 ID 幂等/冲突；32/33 边界；save失败回滚；终态冲突 |
| F / #138 | `tests/test_voice_design_workflow.py`；`tests/test_voice_quality_gates.py`；`tests/test_voice_validation.py`；`tests/test_voice_quality_evidence.py` | 500→900；数字漏读/新增/顺序/日期/小数；口语数字等价；无转写；旧 candidate加载；旧 v1 strict REST/job与 discovery拒绝；v2/完整quality-run通过；冷runtime不回退 |
| G / #145 | `tests/test_openai_diarized_batch.py`；`tests/test_diarization_sdk.py`；`tests/openai-sdk-node/diarization.test.mjs` | 两段delta.segment_id对应segment.id；内容一致；最终text；Python SDK解码；Node SDK解码 |
| H / #144 | `tests/test_transcription_api.py`；`tests/test_openai_multipart.py`；上述SDK测试；拟新增 `tests/test_audio_error_contract.py` | 三类unsupported=400；schema=422；alignment/diarization=502；timeout=503；错误header与契约responses |
| I / 整合 | 拟新增 `tests/test_server_workflow_integration.py` | 正/反两类设计发布闭环；并发校验查询评审；ASR任务artifact；TTS坏流；各入口准入口径一致 |

#139 的并发测试必须断言两个请求都成功时两个 ID 均存在；状态已变终态的测试则允许明确 409，不把冲突算作数据丢失。每个成功结果的资产都要验证，而不只检查列表长度。

避免毫秒级 sleep 的 flaky 测试。并发同步使用 Events；期限测试给合理余量并检查剩余预算或受控 timeout，别要求严格墙钟误差。

## 8. 验收标准

### 已有证据与待验证边界

2026-10-03 的审查已证明八个当前缺陷及上述源文件根因；本计划尚未验证修复。没有执行全量 gate、真实模型、性能/质量、长时运行、App UI 或发布验收。执行者必须把后续实际测试输出与审查证据分开。

### 定向命令

执行位置：`/Users/hrygo/Documents/SpeechRail`。先确认 Python 满足项目 `>=3.14,<3.15`，现有锁定开发依赖可用；缺失时报告，不为验证自动下载模型或升级依赖。下列为可移植原生命令，不复制本机 RTK wrapper。

每个单元先运行其回归文件，失败时局部修复；完成整合后跑一次相关文件合集，避免每项重复运行完整集合：

```bash
# A、B：按本次涉及文件选择运行
uv run --extra dev pytest -q tests/test_alignment_spoken_projection.py tests/test_diarization_alignment.py tests/test_transcription_api.py tests/test_alignment_admission.py tests/test_alignment_worker.py

# C、D
uv run --extra dev pytest -q tests/test_local_file_processor.py tests/test_job_diarization.py tests/test_job_runner.py

# E、F
uv run --extra dev pytest -q tests/test_voice_design_workflow.py tests/test_voice_quality_gates.py tests/test_voice_validation.py tests/test_voice_quality_evidence.py

# G、H；新增文件创建后执行
uv run --extra dev pytest -q tests/test_openai_diarized_batch.py tests/test_diarization_sdk.py tests/test_openai_multipart.py tests/test_audio_error_contract.py

# I；新增文件创建后执行
uv run --extra dev pytest -q tests/test_server_workflow_integration.py

# Node：已有锁定依赖可用时执行，不自动安装或升级 SDK
npm --prefix tests/openai-sdk-node test

# 静态契约检查只作为补充证据
uv run python scripts/check_openapi_contract.py
uv run python scripts/check_user_doc_contract.py

# 对改动的实际 Python 文件做定向 Ruff/Mypy，最后检查 diff
git diff --check
git status --short --branch
```

Ruff 的命令模板为 `uv run --extra dev ruff check <changed-python-files>`；Mypy 为 `uv run --extra dev mypy <changed-source-files>`，占位符必须替换成实际文件。新增行为测试、既有 SDK 测试或相关文档检查若需要额外依赖，记录缺失项，不把 skipped 当作通过。

### 行为验收 Checklist

- [ ] #142：缺否定词/数字不生成时间片；完整真实 tokenization 与 frozen-text 拼回通过。
- [ ] #143：两个原始超时反例均稳定 503/JSON/request ID；后处理不重置期限，取消及满槽不泄漏。
- [ ] #140：timestamps job 使用独立 aligner；四组合行为明确；失败不返回成功 artifact。
- [ ] #141：非法 TTS 流失败且无 artifact；合法 bytes 完全一致；iterator 在取消/异常后关闭。
- [ ] #139：两次成功校验记录/资产/人工评审均保留；容量、重复身份、保存回滚和终态冲突通过。
- [ ] #138：数字反例不可人工提升/发布；旧 v1 不准入；v2与完整quality-run准入，clone与冷worker不回退。
- [ ] #145：delta/segment 关联由实际服务端测试与官方 SDK 解码共同证明。
- [ ] #144：状态码矩阵与 OpenAPI/user docs 一致；原 schema422 保持；新增错误均有公开说明。
- [ ] 整合：八项结果有对应 regression，跨 REST/job/discovery 的闭环测试通过。
- [ ] 交付：diff 只包含授权修复、测试和直接相关契约/文档；无秘密、真实音频、转写、模型绝对路径。

Issue 达到单项标准后记为“修复已验证”；全体完成且整合通过后才能宣称本次交付完成。不因一次 readyz 或测试退出码推断真实音色质量。

## 9. 风险与注意事项

- **持久化：** #138 新字段需允许旧私有记录读取，不能因为 extra=forbid/required 导致整库不可用。#139 的上限需显式校验，禁止静默驱逐或绕过 Pydantic。不迁移/清除用户资产。
- **旧证据：** v1 被排除后，一部分已发布 generated voice 的 production_ready 会转为 false，严格合成要求重新取得有效质量证据；普通 allow_unverified 保持原有显式语义。交付必须说明这一变化，不能宣称数据损坏或自动批量跑模型恢复。
- **校验身份：** 新策略/转写 hash 改变新 validation ID；旧 ID 可查看，但不能作为当前策略的发布依据。同 ID 的既有人工评审不得被重复机器请求重置。
- **状态机：** reject/取消/发布期间的迟到校验返回冲突。不要允许仓库“方便重试”而把终态重新设为 validating；已发布 voice 的恢复走 quality-run。
- **性能：** timestamps job 增加必要的 aligner 工作，整体延迟受现有期限约束；本计划未测真实性能，不给吞吐/RTF 承诺。#142 更严格会暴露 vendor 不完整输出，这是明确失败而不是退化占位时间。
- **兼容：** 400 替代漂移的422会改变 SDK 异常类型；同步修测试和文档，遵循项目当前 API 策略，不保留兼容 alias。新数字失败码/容量错误/校验字段需同时进入契约。
- **公开标准：** #145 的依据是 OpenAI speech-to-text 官方指南中 diarized delta 的 segment_id 语义，审查核验日期为2026-10-03。若执行跨越较长时间或官方 SDK升级，重新核验官方资料，不能靠本计划锁死完整 API 能力。
- **范围：** 不顺手重构 `_write_artifact`、全局错误中间件、所有 endpoint、App UI、模型 worker 或 release pipeline。发现独立缺陷先记录为新增问题，纳入后续明确授权。
- **回退：** 本轮只新增计划文件。后续代码回退按单元反向还原且保留用户/并行改动；禁止 reset --hard。新 v2 数据需保持可读取策略，不能用旧二进制直接读未知字段后宣称安全回退。恢复有缺陷的 v1 准入不是可接受的默认回退，优先停用受影响严格路径/回退相关代码并保留证据，运行态动作另获授权。

## 10. Luna 执行清单

- [ ] 读取本计划和当前适用 AGENTS.md，核对八个 Issue 的状态/最新评论、HEAD、工作区与实施授权。若已有修复合入，按现状缩减，不重复实现。
- [ ] 记录本次执行基线；单一执行分支串行修改共享文件。已有分支/用户改动先核实，不自动清理或覆盖。
- [ ] 按单元 A → B → C → D → E → F → G → H 逐项补行为回归、实施、定向验证并检查 diff。每一单元均记录 Issue、实际文件、结果及遗留项。
- [ ] 每个逻辑单元保持自洽可评审；只在后续明确授权提交后，按建议边界形成 commit 并核对 staged diff、`git diff --staged --check`、敏感内容。未获授权时报告“未提交”，不填虚构 hash。
- [ ] 完成单元 I 的跨入口 fake workflow；跑一次受影响测试合集和契约补充检查。失败只重跑受影响部分，完整 gate/真实验收另获明确授权。
- [ ] 汇总 issue→文件→回归测试→实际结果→commit（或未提交）矩阵，并说明新增策略/字段、400异常类型、旧证据重新校验路径及回退边界。
- [ ] 汇总实测日期、测试数量/失败/skipped、SDK版本、未执行检查、剩余风险；日志与报告不附真实音频、完整prompt/转写或秘密。
- [ ] 仅在明确获得对应授权后，更新 Issue、创建 PR、推送或关闭 Issue。PR 说明先写实际缺陷与修复后的行为；附行为验证，不把本计划中的待执行项写成已通过。

建议交付记录表（实施时填写实际结果）：

| Issue | 实际修复/文件 | 回归与实际结果 | 契约/文档同步 | Commit / 未提交 | 可关闭条件 |
|---|---|---|---|---|---|
| #142 | 待填写 | 待执行 | 待填写 | 待填写 | A完成 |
| #143 | 待填写 | 待执行 | 待填写 | 待填写 | B完成 |
| #140 | 待填写 | 待执行 | 待填写 | 待填写 | C完成 |
| #141 | 待填写 | 待执行 | 待填写 | 待填写 | D完成 |
| #139 | 待填写 | 待执行 | 待填写 | 待填写 | E完成 |
| #138 | 待填写 | 待执行 | 待填写 | 待填写 | F完成 |
| #145 | 待填写 | 待执行 | 待填写 | 待填写 | G完成 |
| #144 | 待填写 | 待执行 | 待填写 | 待填写 | H完成 |
| 整合 | 待填写 | 待执行 | 全部核对 | 待填写 | I完成，八项无未解释失败 |
