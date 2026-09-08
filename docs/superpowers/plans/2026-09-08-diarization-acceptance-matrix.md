---
title: "Speaker Diarization 验收矩阵"
status: in_progress
date: 2026-09-08
source_plan: "2026-09-08-diarization-openai-implementation.md"
---

# Speaker Diarization 验收矩阵

本矩阵把实施方案 T0–T9 的完成标准拆成可独立判定的 AC。`通过`只能由对应的
代码、确定性测试、真实运行或验收报告证明；`待实现`和`待验证`均不等于通过。
原始音频、RTTM、模型和私有配置仍在仓库外。

## 未闭合 AC 的价值与执行优先级

评估基于 SpeechRail 的单机、OpenAI SDK 优先和不保留 fallback 的产品边界。`高`表示直接影响
调用方兼容性、数据正确性、资源上界或发布可信度，优先在仓库内完成；`中`表示不改变核心
调用链，但会降低接入或质量评估风险。`条件`表示缺少受权输入或运行窗口，不能用伪造数据
替代。这里的 ROI 是预期风险降低相对于实现和验证成本的判断，不是未经测量的性能承诺。

| AC | 对 SpeechRail 的价值 | 成本/前置条件 | ROI 与执行决定 |
|---|---|---|---|
| AC-00 | 守住离线、匿名、单进程这一公共安全与资源边界 | 代码审计和确定性测试 | 高：立即核验 |
| AC-03、AC-04 | 让标准 OpenAI SDK 的 multipart 请求可预测，避免调用方学习私有规则 | 低；扩展 SDK/路由测试 | 高：立即完成 |
| AC-06、AC-09、AC-12 | 防止重复归属、无界 PCM/任务积压和慢客户端拖垮服务 | 中；actor 与资源边界测试 | 高：立即完成 |
| AC-13、AC-15 | 防止 IPC 错配、尾部漏标和分包导致的真实分人数据损失 | 中到高；AC-15 还需本机锁定模型 smoke | 高：先完成可注入/确定性部分，再以实际制品核验 |
| AC-19、AC-20 | 完整定义文件 API 的 chunking、失败、静音与断线语义 | 中；HTTP/SSE 集成测试 | 高：立即完成 |
| AC-25、AC-32 | 给 Python/Node 开发者可运行的官方 SDK 接入证据，验证无 opt-in 负担 | 中；需本机 Node 工具链 | 高：在核心语义闭合后完成 |
| AC-26、AC-28 | 证明唯一组合根和依赖方向，避免普通转写付出分人资源或重复载权重 | 中；组合根/静态边界测试 | 高：立即完成 |
| AC-29、AC-30 | 让后续 DER/JER 和文本归属指标不产生误导性“通过” | 中到高；AC-30 需锁定权威评分依赖 | 高：评分器先于质量结论完成 |
| AC-37 | 使升级与回退可审查，避免本机服务升级把用户锁在新制品上 | 低；文档与 release 预检 | 高：核心实现稳定后完成 |
| AC-31、AC-35、AC-36 | 验证真实中文分人质量、ASR 共存和长期稳定性 | 必须有匿名 RTTM/UEM、固定 workload 与两小时本机窗口 | 条件：已写交接，不创建模拟卡或伪造结论 |

| AC | 来源 | 判定与证据 | 当前状态 |
|---|---|---|---|
| AC-00 | 全局 | Python 3.12、单一服务/ASGI worker、请求路径不下载或联网、匿名且 session-scoped | 待验证 |
| AC-01 | T0 | 普通 JSON/text/verbose/timestamps/error/Realtime 回归；分人未配置仍能普通转写 | 通过（全量回归） |
| AC-02 | T0 | `diarized_json` 的 `task`、string `id`、segment `type`、A–D 标签、正文精确拼接、无 confidence | 通过（SDK 回归） |
| AC-03 | T0/T5 | OpenAI SDK 对 scalar 及 object/bracketed `chunking_strategy` 的真实 multipart 编码兼容 | 通过（官方 Python SDK 经 ASGI 覆盖 scalar `auto` 与 object `{"type":"auto"}`；锁定 Node SDK 覆盖 object `{"type":"server_vad"}`→`chunking_strategy[type]`；服务端同样覆盖直接 bracket form） |
| AC-04 | T0/T5 | 冲突 chunking、known speaker、缺模型、空正文、>30 秒未 chunk 的请求在模型前拒绝 | 通过（multipart 冲突、两种 known speaker、缺模型、空音频和 >30 秒均在 activity engine 前拒绝） |
| AC-05 | T1 | interval union 不重复计数；overlap 不是概率分布 | 通过（领域反例） |
| AC-06 | T1 | epoch/step 幂等、稳定帧不可改、水位满足 `stable <= processed <= accepted` | 通过（领域反例覆盖 duplicate step 幂等/冲突、stale epoch、稳定帧 replace、stable/processed 回退与 final attribution 的真实 stable watermark） |
| AC-07 | T1 | A–D 会话内稳定分配、unknown/final/degraded 规则和 24→16k 分包不变性 | 通过（领域 A–D/unknown/final/degraded 反例；Realtime 24→16k 单帧与拆帧输入字节相同） |
| AC-08 | T2 | 固定正文对齐；无二次 ASR；canonical 映射、非法对齐结果均显式失败 | 通过（私有 `align_text` IPC、Qwen3 `ForcedAligner`、canonical 校验及 batch/Realtime 投影均已接通；Realtime 回归证明错误 ASR segment 不参与固定正文对齐） |
| AC-09 | T2 | 普通转写不初始化 aligner；alignment 队列、PCM 生命周期有界 | 通过（普通 Realtime 的 aligner 调用为零；opt-in PCM 限为 30 秒并释放；独立 admission 固定为 3，第四项立即拒绝） |
| AC-10 | T3 | transport 无关的单一 `DiarizationSession` actor，活动、正文、对齐与旧 epoch 乱序均正确 | 通过（文件与 Realtime 均通过同一 actor；固定正文对齐、旧 epoch/step 反例和 Realtime 投影回归通过） |
| AC-11 | T3 | finish/cancel 的原子顺序、30 秒 deadline、同 ID 幂等、空输入和降级闭环 | 通过（actor 与 Realtime 回归） |
| AC-12 | T3 | 5 秒活动 backlog、30 秒/4096 unit ledger、3 个 alignment item、慢客户端合并边界 | 通过（活动 append 以 5 秒为硬期限，超时终止 activity 并稳定发出 `diarization_backlog_exceeded` 降级；canonical ASR 时轴继续；30 秒/4096 ledger、3 个 alignment admission 和慢客户端按 unit 合并均已覆盖） |
| AC-13 | T4 | 私有长度前缀 IPC、二进制 PCM、消息上限、协议/epoch/offset 校验，无网络监听 | 通过（长度、二进制、上限、版本与 epoch/operation 错配注入，以及真实 Swift worker 对无效 bundle 的私有错误回包/子进程回收均已覆盖） |
| AC-14 | T4 | 单一锁定 CoreML FP16 制品、固定 FluidAudio commit/revision/preset、`.all`、直接 `.mlmodelc` 加载 | 通过（哈希、静态 shape 与 worker preflight） |
| AC-15 | T4 | worker 只维护有界前端/模型状态；任意分包相同、尾部 flush 覆盖真实输入且不超界 | 部分实现（D1 90 秒输入的规则/不规则分包得到相同 1,123 个活动 frame；finish watermark 均为真实 1,440,000 sample 并回收 worker；仍缺人工已知尾部活动 fixture） |
| AC-16 | T4 | 精确 PID cancel→terminate→kill，确认退出后才释放资源 | 通过（两次超时故障注入验证精确顺序；监督器在最终 `wait()` 后才释放 worker 引用） |
| AC-17 | T4 | 无 NeMo worker、provider auto、精度切换或请求路径 fallback | 通过（旧 production 路径已删除并检索审计） |
| AC-18 | T5 | 文件 API 的模型选择、`json`/`text`/`diarized_json`、标准 DTO 和 SSE 使用同一 segment DTO | 通过（官方 Python SDK SSE/multipart 回归） |
| AC-19 | T5 | `auto/server_vad` 的 chunking、原始时轴、>30 秒规则、大文件、尾帧、非英文 | 部分实现（`auto` 的 >30 秒拒绝/显式放行和 `server_vad` 的流式 PCM 原样传递、尾块、非中文 language 均有集成反例；真实大文件与锁定模型尾帧质量仍待受权验证） |
| AC-20 | T5 | unresolved: JSON 失败，SSE error 后结束；静音空文本成功；连接断开释放资源 | 部分实现（合法静音返回空 `text`/`segments` 且不启动 activity/alignment；所有分人工作在 SSE 开始前完成，失败即稳定 JSON envelope，不存在已发 delta 后的后台 error；文件连接断开回收仍待 ASGI 取消注入） |
| AC-21 | T6 | 普通 Realtime 原样；未 opt-in 不出现 `speechrail.*` 或 session 分人字段 | 通过（Realtime 回归） |
| AC-22 | T6 | 唯一 `session.speechrail.diarization.enabled`；旧字段拒绝、late opt-in 拒绝、同配置幂等、缺模型不破坏普通 session | 通过（Realtime 回归） |
| AC-23 | T6 | completed 正文不可改写，归属更新字段不泄露模型 slot/embedding，code-point 边界正确 | 通过（extension schema/语义回归与中文、emoji、标点 code-point 反例；DTO 不含 model slot 或 embedding） |
| AC-24 | T6 | 单一 finish/done，final snapshots 在 done 前，异常只发一次状态且 unknown 为 null | 通过（actor fake-port Realtime 回归） |
| AC-25 | T6/T9 | Python/TypeScript 官方 SDK WebSocket 示例与薄扩展类型通过 | 部分实现（README 与 Node SDK wire contract 证明文件分人的原生 multipart 调用；官方 SDK WebSocket 对 `session.speechrail.*` opt-in 的实连仍待） |
| AC-26 | T7 | 组合根是唯一生产链路；普通请求不获取分人/对齐 lease，懒启动且争用稳定 busy/degraded | 通过（组合根只在 opt-in 时建立分人 actor；第二个 Realtime opt-in 稳定返回 `backend_busy`，首会话继续可用） |
| AC-27 | T7 | 删除 legacy session、NeMo/CAM++、centroid/group linkage、hint/双开关、旧 serializer 和旧配置；旧请求失败 | 通过（旧 production 路径、snapshot/candidate timeline、DTO、verbose serializer 与 OpenAPI schema 均已删除；旧字段、旧 request shape 和旧配置入口显式失败） |
| AC-28 | T7 | domain/application 不依赖 FastAPI/CoreML/NeMo/具体 adapter；模型缺失/idle-evict 竞争不复制权重 | 通过（AST 边界测试；CoreML child 为单 session、finish/cancel 精确回收，跨 transport admission 禁止第二份模型状态） |
| AC-29 | T8 | 评分器对缺 RTTM、空参考+预测、插入、文本全异等反例正确失败/计分 | 通过（缺 RTTM/UEM、空参考预测、文本替换/插入和 unknown 均有反例；manifest 强制 UEM） |
| AC-30 | T8 | pyannote.metrics DER/JER 交叉验证；UEM/collar/overlap、Hungarian 映射、CER/条件归属/cpCER/unknown 定义正确 | 部分实现（锁定 `pyannote.metrics==4.1`，UEM 的 DER/JER 参考交叉与 collar/overlap/Hungarian/CER/unknown 反例通过；cpCER 以成对外部文本 sidecar 作整场最优映射并计插删改/unknown；条件归属指标与真实语料交叉仍待） |
| AC-31 | T8 | 受权 eval manifest：tune/eval 隔离、清晰/远场/overlap/插话/相似音色/静音返回覆盖 | 需要受权真值输入 |
| AC-32 | T9 | Python 与 Node 官方 SDK 的 HTTP/WS/multipart/SSE/opt-in 集成；锁定依赖和 lockfile | 部分实现（Python 官方 SDK 已覆盖 HTTP/SSE；`tests/openai-sdk-node/package-lock.json` 锁定 `openai==7.10.0`，验证 Node 原生 multipart 的 `diarized_json` 与 object `server_vad` 编码；Node HTTP 实连、SSE 和 WebSocket opt-in 仍待） |
| AC-33 | T9 | 完整 deterministic gate（pytest、ruff、mypy、OpenAPI lint、diff check）通过 | 通过（2026-09-08） |
| AC-34 | T9 | native executable 被 wheel/release 定位；版本/IPC 不匹配 preflight 失败；Swift tests/build 通过 | 通过（Hatch 编译 macOS 平台 wheel；隔离安装确认 package 内 executable 可执行；IPC protocol mismatch 注入在 preflight 前失败；Swift release build 与 codec self-test 通过） |
| AC-35 | T9 | 固定中文 eval：DER/JER/正文完整性、RTF P95、词尾→final、ASR 共存 P95、footprint | 需要受权真值输入与运行窗口 |
| AC-36 | T9 | 两小时 soak：晚加入、长静音、overlap、8 秒边界、慢端、取消/finish；footprint 稳定增长 ≤10% | 需要运行窗口 |
| AC-37 | T9 | ADR、迁移说明、release checklist 和上一 release 回退步骤可评审 | 通过（ADR-0012、runtime deployment 与 managed runbook 一致：wheel 内 worker、CoreML/aligner preflight、`/v1/models` alias 验证和失败恢复上一 `runtime/current`；installer 仅识别当前 `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH`） |

## 当前证据（2026-09-08）

- `uv run --extra dev pytest --no-cov -x`：1270 passed（2 条既有第三方/Pydantic warning）；包含 Realtime 直接 fixed-text alignment、24→16k 分包不变量、慢客户端归属快照合并、单会话 admission、epoch/operation 回包错配和 worker 定向终止故障注入。
- `uv run --extra dev pytest --no-cov tests/test_realtime_openai.py tests/test_diarization_extensions.py tests/test_openai_diarized_batch.py tests/test_diarization_sdk.py tests/test_diarization_session.py tests/test_diarization_attribution.py tests/test_diarization_worker.py`：120 passed；文件与 Realtime 共同使用 actor/port 的回归。
- `uv run --extra dev ruff check src tests`、`uv run --extra dev mypy src`、`npx @redocly/cli lint contracts/openapi.yaml`、`git diff --check`：全部通过；`swift build --package-path native/diarization` 与 `swift run --package-path native/diarization SpeechRailDiarizationProtocolSelfTest`：通过。
- `uv run --extra dev pytest --no-cov tests/test_diarization_sdk.py tests/test_formatters.py tests/test_openai_diarized_batch.py`：15 passed；官方 `openai==2.54.0` 已锁入 dev extra，覆盖 SDK multipart object、known-speaker reject 与 SSE iterator。
- `uv run --extra dev pytest --no-cov tests/test_diarization_attribution.py tests/test_diarization_session.py`：9 passed；覆盖领域证据、watermark 和 actor finish/degraded。
- `uv run --extra dev pytest --no-cov tests/test_diarization_alignment.py tests/test_openai_diarized_batch.py tests/test_qwen3_worker.py tests/test_qwen3_streaming.py tests/test_realtime_openai.py tests/test_diarization_extensions.py`：170 passed；验证私有 `align_text` IPC、固定正文映射、批量分人接线，以及对齐不会回调 `Session.transcribe`。
- `uv run --extra dev pytest --no-cov tests/test_diarization_metrics.py`：12 passed；缺 RTTM/UEM 与空参考预测显式失败，文本替换/插入和 unknown 不再被计为零错误，UEM 下的 DER/JER 与 `pyannote.metrics==4.1` 交叉一致。
- `uv run --extra dev pytest --no-cov tests/test_diarization_metrics.py tests/test_openai_diarized_batch.py tests/test_diarization_sdk.py`：32 passed；cpCER 的全场 mapping、插删改/unknown 计分与 paired text sidecar 加载、聚合报告均已覆盖。
- `uv run --extra dev pytest --no-cov tests/test_openai_diarized_batch.py`：14 passed；`server_vad` 在流式容器解码中保留完整 PCM（含不规则尾块）并把 `ja` 原样传入 ASR，活动 actor 收到相同样本序列。
- `npm ci --prefix tests/openai-sdk-node --ignore-scripts --no-audit --no-fund && npm test --prefix tests/openai-sdk-node`：1 passed；锁定的官方 `openai==7.10.0` 把 `chunking_strategy: {type: "server_vad"}` 编码为 OpenAI multipart 的 `chunking_strategy[type]`，不需要 SpeechRail SDK。
- `uv run --extra dev pytest --no-cov tests/test_diarization_session.py tests/test_diarization_extensions.py tests/test_realtime_openai.py`：106 passed；受阻 activity append 超过 configured deadline 会取消 activity、保留 canonical audio sample 计数并以单一 degraded 状态结束。
- `uv run --extra dev pytest --no-cov tests/test_diarization_attribution.py`：7 passed；验证 session-scoped epoch、step 幂等/冲突、monotonic watermark 与 stable activity frame 不可重写。
- `uv run --extra dev pytest --no-cov tests/test_installer.py`：22 passed；managed installer 仅以当前 CoreML profile 键识别 diarization 安装，仍保留原子切换失败恢复旧 release 的回归。
- `uv run --extra dev pytest --no-cov tests/test_openai_diarized_batch.py tests/test_diarization_sdk.py`：19 passed；`stream=true` 的分人失败仍为 SSE 开始前的 `502` JSON envelope，成功事件序列保持标准 SSE DTO。
- D1 固定 CoreML bundle 的哈希清单已写入 `coreml.py`；本机现存 bundle 通过该清单和 Swift worker preflight。
- 使用 `<D1_RUN_DIR>` 的固定 90 秒 PCM，当前 Swift worker 对规则/不规则分包都输出相同的 1,123 个活动 frame；两个 finish watermark 都是 1,440,000 samples，且子进程已退出。该 smoke 不包含 RTTM，不能代替 AC-31/35/36。
- `swift build --configuration release --package-path native/diarization`、`swift run --package-path native/diarization SpeechRailDiarizationProtocolSelfTest` 与 `uv build --wheel`：通过；生成的 macOS wheel 含 `speechrail/_native/SpeechRailDiarizationWorker`。

## 执行规则

1. 先关闭不依赖真实标注音频的 AC-00–30、32–34、37。
2. AC-31、35、36 需要用户提供或授权的匿名 RTTM/UEM、固定 workload 与维护窗口；在此之前不能将能力标为质量验收通过。
3. 每次状态变化都在本表增加可复现命令、产物路径或报告链接；禁止只改复选框。
