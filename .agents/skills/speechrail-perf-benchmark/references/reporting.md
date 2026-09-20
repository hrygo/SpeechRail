# SpeechRail 基准报告与 README 同步

仅在需要生成或修订性能归档、比较结果或 README 时读取。原始 JSON、音频、embedding 和日志
始终留在仓库外；Git 只保存脱敏摘要。

先确定交付位置：临时测量按用户指定位置交付，未指定时在仓库外保存结果并给出摘要；只有用户请求
正式归档时才写入性能归档和索引。README 同步单独按下文判断，不由是否修改 README 反推归档范围。

## 比较口径

按实际测量与可比基线选择视图，不为填满模板补跑未授权基准：

- **纵向版本变化**：当前版本与上一份同机器、同 profile、同 fixture、同 benchmark schema 的版本比较。
- **横向档位对比**：同一版本、同一机器、同一 fixture 下 `quality`/`balanced`/`light` 比较。

变化公式：`delta = current - baseline`，`delta_pct = delta / baseline × 100%`。延迟、RTF、CER/WER、
内存下降为改善；吞吐、成功率和相似度上升为改善。表中同时显示绝对值与百分比，并用
`改善`/`持平`/`回归`/`不可比`表示方向。基线为 0 或口径不同则百分比为 N/A。

“持平”必须使用预先固定的噪声带或统计区间；单轮波动不得直接归因。实测为 0 才写 0，缺失值写 N/A。

## 归档报告模板

正式归档时保存为 `docs/archive/performance/YYYY-MM-DD-v<version>-performance-benchmark.md`，并更新索引。
临时报告可复用下列相关字段，不因此写入仓库或补跑未请求的测量：

```markdown
# SpeechRail vX.Y.Z 性能与质量基准

> 状态：通过 / 有条件通过 / 未通过
> 范围：实际 profile、场景、指标及已授权切换
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
| 重计算重叠状态 | auto (ON) | auto (ON) | 是/否 |

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
| VoiceDesign 自定义音色 | 实测 / 未验证 | 实测 / 未验证 | 实测 / 未验证 | API 按能力声明 |

单档报告只保留实测档列，并注明三档横向对比不适用；未测量的能力不预填支持结论。

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
|---|---|---:|---:|---:|---:|

### 质量与音色稳定性

| profile / voice | same-text hash | within-role p05 / median | nearest-other max | margin | restart Δ | ABX |
|---|---|---:|---:|---:|---:|---|

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

记录可移植命令、fixture digest、参数和报告生成方式；不写凭据与私人路径。Realtime 证据命令使用
`examples/perf/bench_realtime_json.py`，并注明 `--warmup`/`--no-warmup` 口径与 `sampling_complete`。
```

## README 同步

只有用户明确要求修改 README 时，才同步“真实性能基准实测”区；未请求同步时保留 README，
报告与索引是否更新由前述交付范围决定。

同步规则：

1. 报告是唯一数据来源。README 的版本、报告链接、硬件、物理内存、样本数、RTF 和质量结论逐项来自报告，
   不从原始日志重新计算，也不复制计划值。
2. PATCH 只更新当前部署档的可信数据；其他档位只能保留已验证的旧来源并明确标注，不能写成 patch 实测。
3. MINOR/MAJOR 的横向表必须来自同一轮、同一硬件和同一 benchmark schema，不能拼接不可比结果。
4. gate 为 `unset`/`fail` 或可比性不足时，不把指标提升为 README 承诺；缺失值不得写成 `0`。
5. README 只保留用户需要的简表、测试机器、测量口径、报告链接和必要限制；完整分位数、fixture digest、
   进程采样和 gate 留在归档报告。
6. 更新后核对 README 数值与报告一致、相对链接可解析，且顶部 Release badge 仍存在。

获授权同步时至少包含：实测硬件、正式报告相对链接、PATCH 当前档或 MINOR/MAJOR 三档关键指标、N/cold/warm
口径、不能直接比较的限制，以及每个保留值的来源版本。

```bash
git diff -- README.md docs/archive/performance/
rg -n 'github/v/release/hrygo/SpeechRail|性能基准|performance-benchmark' README.md
git diff --check
```

如果没有可信指标可写入 README，只更新报告链接或“本版本未验证”状态，并在报告和交接中说明原因。
