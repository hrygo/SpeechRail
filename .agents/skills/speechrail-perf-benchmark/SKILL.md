---
name: speechrail-perf-benchmark
description: >-
  SpeechRail 性能与质量基准 SOP。用于按 SemVer 选择单档或三档范围，测量 ASR/TTS/Realtime
  延迟、RTF、吞吐和 Apple Silicon 物理内存，验证三档质量与音色稳定性，并用统一模板生成
  版本纵向变化和档位横向对比报告。
---

# SpeechRail 性能与质量基准 SOP

目标是生成可复现、可比较、不会夸大证据的发布基准。所有推理通过公共 API，原始 JSON、音频和日志放在仓库外；Git 只保存脱敏汇总报告。

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
2. 记录 commit、版本、profile、artifact、variant、quantization、macOS、芯片、物理内存、Python、MLX 与 benchmark schema。
3. 每项先预热至少 1 次；基础发布基准测 5 次，报告 p50、p95、min/max 和样本数。首次请求单列为 cold，不混入 warm 分位数。
4. RTF 使用 `ffprobe` 实测音频时长：`latency / actual_audio_seconds`。不得使用文件名中的 3s/10s/30s/60s 标签代替。
5. Apple Silicon 内存使用 `footprint -p <pid> -f bytes` 的 `phys_footprint`。不要用 RSS 代替，也不要相加发生在不同时刻的进程峰值。
6. 总峰值必须来自同一采样 tick 内各目标 PID+start-time 的总和；缺样、PID 重用或 sampler 失败时标记 N/A 并关闭 gate。
7. batch ASR 与 streaming ASR 分开测量，不制造二者同时工作的场景。TTS 负载也单独给出，组合峰值只反映产品真实允许的组合。
8. 同轮比较使用同一 fixture 字节、文本、请求参数、运行环境和静默背景负载。任何变化都标记为“不可直接比较”。
9. API key 只从环境读取，不出现在命令、报告或日志中。

## 4. 基础发布套件（每个 profile）

### A. 身份与就绪

- `/health` 与 `/readyz` 状态和版本；
- `/v1/models` 的 active profile、ASR/TTS artifact、variant、quantization；
- `/v1/voices` 九个 canonical role 的 availability 与 capabilities；
- 公共 ASR/TTS smoke、HTTP 状态、request ID、非空输出。

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

工具入口：

```bash
python3 .agents/skills/speechrail-perf-benchmark/scripts/prepare_fixtures.py
python3 .agents/skills/speechrail-perf-benchmark/scripts/run_all_benchmarks.py \
  --host http://127.0.0.1:8201
python3 examples/perf/bench_profiles.py \
  --base-url http://127.0.0.1:8201 \
  --manifest <repo-external-manifest.json> \
  --profile <quality|balanced|light> \
  --phase warm \
  --output <repo-external-result.json>
```

`bench_profiles.py` 的 release gate 只有在硬件、模型身份、独立质量证据、成功公共推理和完整资源采样均为真实证据时才可打开。

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

MINOR/MAJOR：

1. 记录初始 active profile 和 generation。
2. 每次 `speechrail profile apply <profile> --yes` 后等待服务真正 ready。
3. 核对模型/音色身份并执行该档完整基础套件。
4. 不在同一时间运行多个 benchmark。
5. 结束时恢复初始 profile，复查公共 ASR/TTS smoke。

切换或 smoke 失败时停止后续数据采集，记录失败，并使用 `speechrail profile rollback --yes`。失败档不得用旧数据补齐。

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

## 9. 归档与完成条件

1. 原始 JSON、音频、embedding 和日志保存到仓库外 `<app-home>/benchmarks/<run-id>/`，权限最小化。
2. Git 报告只保留脱敏指标、digest、可比性和 gate；更新 `docs/archive/performance/README.md`。
3. README 只在可信基线变化时更新一张简表，并明确硬件与验收边界。
4. 最终 active profile 与开始一致；服务、模型、音色和公共 smoke 再次通过。
5. 缺少真实质量、完整物理采样或目标设备证据时，对应 gate 必须为 `unset`/`fail`，不得写“通过”。
