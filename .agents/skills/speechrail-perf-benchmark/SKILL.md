---
name: speechrail-perf-benchmark
description: >-
  SpeechRail 性能与质量基准 SOP。用于按 SemVer 选择单档或三档范围，测量 ASR/TTS/Realtime
  延迟、RTF、吞吐和 Apple Silicon 物理内存，验证三档质量与音色稳定性，并用统一模板生成
  版本纵向变化和档位横向对比报告；仅在用户明确要求时才把可信摘要同步到 README。
---

# SpeechRail 性能与质量基准 SOP

目标是生成可复现、可比较、不会夸大证据的发布基准。所有推理通过公共 API，原始 JSON、音频和日志放在仓库外；Git 只保存脱敏汇总报告。

停服、强杀、切档和恢复边界统一遵守 [本机 operator contract](../speechrail-local-deploy/references/operator-contract.md)；本 SOP 只定义测量口径、证据和报告。

## 1. 三档事实

三档使用同一服务架构、worker 协议、调度和共享 vendor runtime，只改变权重与量化：

| profile | ASR | TTS | 音色行为 |
|---|---|---|---|
| `quality` | Qwen3-ASR 1.7B q8 | Qwen3-TTS 1.7B VoiceDesign q8 | 九个固定 VoiceDesign 配方；支持自然语言自定义音色 |
| `balanced` | Qwen3-ASR 1.7B q8 | Qwen3-TTS 0.6B CustomVoice q8 | 九个角色映射同名固定 speaker；不执行 VoiceDesign instruction |
| `light` | Qwen3-ASR 0.6B q8 | Qwen3-TTS 0.6B CustomVoice q8 | 与 balanced 同一 TTS，ASR 更小；8GB Apple Silicon 目标 |

profile 对 API 调用方透明。报告必须记录 `/v1/models` 与 `/v1/voices` 的实际声明，不根据计划或目录名推断运行模型。

## 2. 版本决定范围

| 发布类型 | 必测范围 | 切换规则 |
|---|---|---|
| PATCH | 当前部署 profile | 不为基准切档；与上一可比版本做纵向比较 |
| MINOR | `quality`、`balanced`、`light` | active → 其余档 → active，逐档停服切换 |
| MAJOR | 三档完整套件 | 另加迁移、兼容客户端和回退验证 |

如果改动直接影响未被上述范围覆盖的 profile、模型、共同 runtime 或 benchmark 工具，应扩大到三档。纯文档改动不制造新的性能结论。

## 3. 测量约束

1. 使用已安装 wheel、锁定 snapshot 和无下载运行态；`/health`、`/readyz`、`/v1/models`、`/v1/voices` 均通过后再测。
2. 记录 commit、版本、profile、artifact、variant、quantization、macOS、实际芯片（不能用 `arm`/`arm64` 等通用架构名替代）、物理内存、Python、MLX 与 benchmark schema。
3. 每项先预热至少 1 次；基础发布基准测 5 次，报告 p50、p95、min/max 和样本数。cold 只统计从确认未加载或已重置状态发出的首次推理；此前已执行过推理（含前置 smoke）时标记为 warm 或 `cold_unavailable`，不混入 warm 分位数。
4. RTF 使用 `ffprobe` 实测音频时长：`latency / actual_audio_seconds`。不得使用文件名中的 3s/10s/30s/60s 标签代替。
5. Apple Silicon 内存使用 `footprint -p <pid> -f bytes` 的 `phys_footprint`。不要用 RSS 代替，也不要相加发生在不同时刻的进程峰值。
6. 总峰值必须来自每个完整采样 tick 内各目标 PID+start-time 的总和；任一 tick 缺样、PID 重用、sampler 线程异常或停止超时都标记 N/A 并关闭 gate。
   worker 为懒加载时，采样器必须在预热后重新发现受管进程；预热前固定 PID 集合而漏掉新 worker 的结果无效。
7. batch ASR 与 streaming ASR 分开测量，不制造二者同时工作的场景。TTS 负载也单独给出，组合峰值只反映产品真实允许的组合。
8. 同轮比较使用同一 fixture 字节、文本、请求参数、运行环境和静默背景负载。任何变化都标记为“不可直接比较”。
9. API key 由共享 resolver 读取：显式 `SPEECHRAIL_API_KEY` 优先，其次是 `SPEECHRAIL_APP_HOME`（默认 managed app home）下的 `config/.env`；不得 `source` 配置，不出现在命令、报告或日志中。
10. 基准开始、每次切档前和最终恢复后都要隔离外部 realtime 客户端：用 `lsof -nP -iTCP:<port>` 排除 `ESTABLISHED` 连接，并用已配置鉴权读取 `/metrics` 确认 `realtime_active_sessions=0`、batch/realtime active requests 均为 0。Sona、浏览器标签页或其它客户端不会随服务 stop 自动断开；发现活动客户端时暂停采集并报告阻塞，等待客户端自行断开，只有用户明确授权才按精确 PID 关闭指定客户端。顺序 ASR 仍返回 `429 backend_busy` 时停止采集并记录根因，不循环重试或复用旧数据。

## 4. 基础发布套件（每个 profile）

### A. 身份与就绪

- `/health` 与 `/readyz` 状态和版本；
- `/v1/models` 的 active profile、ASR/TTS artifact、variant、quantization；
- `/v1/voices` 九个 canonical role 的 availability 与 capabilities；
- 公共 ASR/TTS smoke、HTTP 状态、request ID、非空输出。

身份检查（`/health`、`/readyz`、`/v1/models`、`/v1/voices`）只读、不触发推理，不影响 cold；但 ASR/TTS smoke 会触发推理，若在 cold 测量前执行过任何推理，该档 cold 标记为 `cold_unavailable`，不把预热后的首次请求当 cold。

### B. Batch ASR

- 独立、非 SpeechRail TTS 自生成的中英文短样本；
- 约 3s、10s、30s、60s 的固定音频；
- cold 1 次，warm N=5；记录 latency、RTF、CER/WER；
- 可选 4 workers × 8 requests 吞吐，记录成功率、wall time、req/s、p95；
- 单独采样 host + batch ASR 的稳定与负载同时物理占用。

### C. TTS

- 固定短句与长句，canonical voice 固定为 `serena`；
- cold 1 次，warm N=5；记录 latency、实际输出时长、RTF、首音频时间（可用时）；
- 用独立 ASR 回读只作为可懂度代理，不替代听感质量；
- 单独采样 host + TTS 的稳定与负载同时物理占用。

### D. Realtime（完整套件或改动相关时）

- 16 kHz mono PCM16，连续 3 个 session；
- setup、首 delta、commit、TTFA、terminal event、成功率；
- 单独启动 streaming 模式并采样 host + streaming ASR；结束后恢复原模式。

开始任何一档的基础套件前，先记录外部连接快照：listener、established client PID、`realtime_active_sessions`、两类 governor active requests 和 streaming worker state。只有客户端连接清零后，`/health`、`/readyz` 和短 ASR smoke 都通过，才允许开始该档数据采集。

工具入口：

```bash
uv run python examples/perf/bench_profiles.py \
  --base-url http://127.0.0.1:8201 \
  --app-home "${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}" \
  --manifest <repo-external-manifest.json> \
  --profile <quality|balanced|light> \
  --phase warm \
  --output <repo-external-result.json>
```

正式 benchmark 只接受外部 manifest 和外部 fixture；`prepare_fixtures.py` 仅用于开发调试，不得作为发布基准入口。`bench_profiles.py` 的 release gate 只有在硬件、模型身份、独立质量证据、成功公共推理和完整资源采样均为真实证据时才可打开；fixture 标签必须是安全的 opaque id/language tag。

benchmark 启动后会先访问一个只读受保护路由探测鉴权；若返回 `401`，在任何 ASR/TTS 推理前停止并修正 `--app-home` 或环境变量，不把无鉴权请求写入结果。keyless loopback 服务返回非 `401` 时继续执行。

## 5. 质量与音色稳定性套件

性能快不代表质量可接受。MINOR/MAJOR 三档必须同时报告质量；PATCH 若影响推理、分句、采样、量化、音色或模型 runtime，也必须执行本节。

### ASR 质量

- 使用版本固定、人工核对的独立真人中英文语料；禁止用当前 SpeechRail TTS 生成 ASR 主质量集。
- 分别报告总体与语言/时长分组的 CER/WER、样本数和失败数。
- 同时报告 p50/p95，不能只给均值。

### TTS 可懂度与自然度

- 九个角色覆盖中英文、短长句、数字和标点；记录生成失败率与独立 ASR 回读 CER/WER。
- 人工 MOS/偏好测试报告样本数、评分尺度、盲听方式和置信区间；没有人工听测时写“未验证”。

### 同一角色跨轮稳定性

每个角色至少覆盖 3 类文本 × 3 次生成，并包含一次服务重启后的重复：

1. **同文本确定性**：固定 input、voice、speed、response format，比较 PCM hash；hash 相同可证明该输入字节级复现，不能证明跨文本身份一致。
2. **跨文本身份相似度**：使用固定 speaker-embedding 模型，报告同角色 cosine 的 p05/median、不同角色最近邻上界和 separation margin。
3. **跨重启一致性**：重启前后采用同一配方与 fixture，单列相似度变化。
4. **ABX 盲听**：听者判断 A/B 是否同一人，并用 X 检查角色混淆；报告人数、样本数和通过率。

`quality` 还需记录 canonical instruction 版本、role seed、temperature 和其他采样参数；`balanced/light` 记录 vendor speaker 名。VoiceDesign 与 CustomVoice 的跨档同名角色只要求角色意图一致，除非 embedding 与盲听都通过，不声明为同一声纹。

建议门值必须在首个可信数据集上冻结后再作为 release gate；门值未冻结前，只报告数值与相对变化，不临时选择有利阈值。

## 6. 档位切换与恢复

切档是停服事务，不是普通热重启。`launchctl bootout` 返回不代表旧 ASGI 父进程或 vendor worker 已退出；每次切档必须使用本机部署 skill 的生命周期 controller：先 bootout，最多等待 2 秒获取同一个 per-port singleton lock；仍占用时重新核对当前 lock owner、命令行和 executable，只对仍然匹配的精确 PID/进程组发送 `SIGKILL`，再最多等待 10 秒确认 lock 释放。lock 未释放、PID 不安全、身份不一致或无法确认旧服务身份时立即停止基准，不启动候选。详见 [speechrail-local-deploy 生命周期 SOP](../speechrail-local-deploy/references/lifecycle.md)。

所有 `service` 和 `profile` 操作都显式传入 `--app-home`；带 `--app-home` 的 CLI 会自动使用 `runtime/current/.venv/bin/python`，因此不再从源码 checkout 手工拼接 managed preflight 或启动命令。

MINOR/MAJOR：

1. 记录初始 active profile 和 generation。
2. 每次 `speechrail profile apply <profile> --yes` 前后都重做外部连接快照；发现 established realtime client 或 active session 时暂停并报告阻塞，等待客户端自行断开或用户明确授权关闭，不能把 `backend_busy` 当作候选模型失败。
3. 每次 `speechrail profile apply <profile> --yes` 后等待服务真正 ready，并先核对 `/health.profile` 是否等于目标档位。
4. 核对 `/v1/models`、`/v1/voices` 的模型/音色身份并执行该档完整基础套件。
5. 不在同一时间运行多个 benchmark；启动真空可持续数分钟时不要连续 restart。
6. 结束时恢复初始 profile，复查公共 ASR/TTS smoke、外部 session 清零和单 listener。

切换或 smoke 失败时停止后续数据采集，记录失败档、operation 状态、PID、stderr 尾部和错误码。先读取 operation 状态与回滚结果：事务已自动回滚且已恢复时不得再次回滚；仅在确认未恢复且回退目标明确时执行一次 `speechrail profile rollback --yes`。回滚也失败时保持 `not_ready`，不要循环重启或用旧数据补齐。

## 7. 比较与变化表达

报告同时包含两种视图：

- **纵向版本变化**：当前版本与上一份同机器、同 profile、同 fixture、同 benchmark schema 的版本比较。
- **横向档位对比**：同一版本、同一机器、同一 fixture 下 `quality/balanced/light` 比较。

变化公式：`delta = current - baseline`，`delta_pct = delta / baseline × 100%`。延迟、RTF、CER/WER、内存下降为改善；吞吐、成功率和相似度上升为改善。表中同时显示绝对值与百分比，例如 `0.24 (-0.03, -11.1%)`，并用 `改善 / 持平 / 回归 / 不可比` 表示方向。基线为 0 或口径不同则百分比为 N/A。

“持平”必须使用预先固定的噪声带或统计区间；单轮波动不得直接归因。报告中的 0 只表示实测为 0，缺失值必须写 N/A。

## 8. 报告模板

保存为 `docs/archive/performance/YYYY-MM-DD-v<version>-performance-benchmark.md`：

```markdown
# SpeechRail vX.Y.Z 性能与质量基准

> 状态：通过 / 有条件通过 / 未通过
> 范围：PATCH 当前档 / MINOR 三档 / MAJOR 三档+迁移
> 基线：vA.B.C（可比 / 部分可比 / 不可比）

## 一眼结论

| 结论 | 结果 | 证据 |
|---|---|---|
| 发布档位 | quality / balanced / light | active profile + artifact identity |
| 最大同时物理占用 | ... MB | 同一 tick `phys_footprint` |
| ASR / TTS 关键 RTF | ... / ... | warm N=... |
| 质量与音色稳定性 | 通过 / 未验证 | CER/WER、embedding、ABX |
| 相对上一版本 | 改善 / 持平 / 回归 / 不可比 | 见纵向表 |

## 测量身份与可比性

| 项目 | 当前值 | 基线值 | 是否一致 |
|---|---|---|---|
| 硬件 / macOS | ... | ... | 是/否 |
| profile / artifact / quantization | ... | ... | 是/否 |
| fixture digest / benchmark schema | ... | ... | 是/否 |
| warmup / N / 背景负载 | ... | ... | 是/否 |

说明任何不可比较项；原始制品只记录仓库外相对位置与 digest，不记录私人绝对路径。

## 纵向：版本变化

| profile | 指标 | 基线版本 | 当前版本 | Δ | Δ% | 判断 |
|---|---|---:|---:|---:|---:|---|
| quality | ASR warm p50 RTF ↓ | ... | ... | ... | ... | ... |
| quality | TTS warm p50 RTF ↓ | ... | ... | ... | ... | ... |
| quality | 同时物理峰值 ↓ | ... | ... | ... | ... | ... |
| quality | speaker similarity p05 ↑ | ... | ... | ... | ... | ... |

## 横向：三档对比

| 指标 | quality | balanced | light | 最优 / 代价 |
|---|---:|---:|---:|---|
| ASR CER / WER ↓ | ... | ... | ... | ... |
| ASR warm p50 / p95 RTF ↓ | ... | ... | ... | ... |
| TTS warm p50 / p95 RTF ↓ | ... | ... | ... | ... |
| 稳定 / 峰值 phys_footprint ↓ | ... | ... | ... | ... |
| speaker similarity p05 ↑ | ... | ... | ... | ... |
| ABX 同一人通过率 ↑ | ... | ... | ... | ... |
| VoiceDesign 自定义音色 | 支持 | 不支持 | 不支持 | API 按能力声明 |

PATCH 报告只保留当前档列，并注明三档横向对比不适用。

## 分项结果

### Batch ASR

| fixture | actual s | cold s | warm p50 / p95 s | RTF p50 / p95 | CER/WER | success |
|---|---:|---:|---:|---:|---:|---:|

### TTS

| text set | voice | cold s | warm p50 / p95 s | output s | RTF | success |
|---|---|---:|---:|---:|---:|---:|

### Realtime（若执行）

| sessions | setup p50 | commit p50 / p95 | TTFA p50 / p95 | terminal success |
|---:|---:|---:|---:|---:|

### 资源

| 场景 | 进程集合 | stable MB | simultaneous peak MB | samples | complete |
|---|---|---:|---:|---:|---|

### 质量与音色稳定性

| profile / voice | same-text hash | within-role p05 / median | nearest-other max | margin | restart Δ | ABX |
|---|---|---:|---:|---:|---:|---:|

## Gate

| Gate | 结果 | 证据 / 原因 |
|---|---|---|
| 服务与模型身份 | pass/fail | ... |
| 性能回归 | pass/fail/unset | ... |
| 资源上限 | pass/fail | ... |
| ASR 质量 | pass/fail/unset | ... |
| TTS 自然度与稳定性 | pass/fail/unset | ... |
| profile 恢复 | pass/fail | ... |

## 限制与未验证

- ...

## 复现

记录可移植命令、fixture digest、参数和报告生成方式；不写凭据与私人路径。
```

## 9. README 同步（仅用户明确要求）

只有用户明确要求修改 README 时，才在同一个逻辑变更中同步相应 README 的“真实性能基准实测”区。用户没有明确要求时，不得因生成报告、发布、基准结果、接口或其他文档变化而修改任何 README（含语言版本）；此时只更新正式报告和性能归档索引。

获授权同步时遵守以下规则：

1. 报告是唯一数据来源。README 中的版本、报告链接、硬件、物理内存、样本数、RTF 和质量结论必须逐项来自报告，不根据原始日志重新计算，也不复制计划值。
2. PATCH 只测当前部署档时，只更新该档的可信数据和最新报告链接；其他档位只可保留上一份三档报告的已验证数据，并明确标注其来源版本。不得把未重测档位表述为本 patch 实测。
3. MINOR/MAJOR 完成三档测量后，更新整张横向表和报告链接；三个档位必须来自同一轮、同一硬件和同一 benchmark schema，不能拼接不可比结果。
4. 对应 gate 为 `unset`/`fail` 或可比性不足时，不把该指标提升为 README 的性能承诺；保留上一份可信值并标注旧来源，或写“本版本未验证”。缺失值不得写成 `0`。
5. README 只保留用户需要的简表、测试机器与内存、测量口径、报告链接和必要限制；完整分位数、fixture digest、进程采样和 gate 留在归档报告。
6. 更新后逐项核对 README 数值与报告一致、相对链接可解析，并确认顶部 Release badge 仍存在；不得在整理 README 时删除或改坏该 badge。

获授权更新 README 时至少包含：

- 标题中的实测硬件；
- 指向本次正式报告的相对链接；
- PATCH 当前档或 MINOR/MAJOR 三档的关键 ASR/TTS RTF 与同时物理峰值；
- `N`、cold/warm 口径和不能直接比较的限制；
- 数据来自不同版本时，每个保留值的来源版本。

仅在本次 README 位于用户明确授权范围内时执行：

```bash
git diff -- README.md docs/archive/performance/
rg -n 'github/v/release/hrygo/SpeechRail|性能基准|performance-benchmark' README.md
git diff --check
```

如果用户明确要求同步但本次没有可信指标可写入 README，更新报告链接或“本版本未验证”状态，并在报告和交接中说明原因。用户没有要求同步时，README 保持不变，不得以此为由跳过报告或归档索引。

## 10. 归档与完成条件

1. 原始 JSON、音频、embedding 和日志保存到仓库外 `<app-home>/benchmarks/<run-id>/`，权限最小化。
2. Git 报告只保留脱敏指标、digest、可比性和 gate；更新 `docs/archive/performance/README.md`。
3. 性能归档索引已更新；只有用户明确要求 README 同步时，才核对 README 的报告链接、实测硬件、版本来源和关键指标可追溯且一致。
4. 只有本次修改 README 时，才确认顶部 GitHub Release badge 仍存在且链接、图片 URL 正确。
5. 最终 active profile 与开始一致；服务、模型、音色和公共 smoke 再次通过。
6. 缺少真实质量、完整物理采样或目标设备证据时，对应 gate 必须为 `unset`/`fail`，不得写“通过”。
