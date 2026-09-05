# VoiceDesign recipe 搜索与 holdout 验收

> 日期：2026-09-06
> 状态：搜索完成；自动门未全通过；九角色生产配置保持不变

## 结论

本轮完成了 9 个 VoiceDesign 角色的 `instruction × seed` 离线联合搜索：3 个身份 instruction 变体 × 16 个 seed × 6 条 calibration 文本 × 2 次重复，共 `5184` 次生成，`tts_failures=0`。

随后对自动 selector 选出的 9 个候选，用未参与搜索的 3 条 holdout 文本、每条重复 3 次，完成 `81` 条独立验证，`tts_failures=0`，最近中心准确率为 `100%`。但联合 `separation margin p05=-0.2126`，低于预注册目标 `≥0.10`；与同一 holdout 上的当前 recipe 相比，readback CER p95 由 `8.76%` 上升到 `20.97%`。

因此本轮没有把搜索 winner 写回 `SYSTEM_VOICE_PROFILES`，也没有部署新的九角色配方。当前 VoiceDesign 的结论仍是：开放式创造能力可用，但跨文本同一人稳定性未达标；固定角色应优先评估 `CustomVoice`，同时要求开放式创造和稳定身份时再评估 `VoiceDesign → Base clone`。

## 搜索设置

| 项目 | 设置 |
|---|---|
| runtime | SpeechRail source runtime `1.8.0`，`quality`，`tts-1.7b-design-q8` |
| 角色数 | 9 个 canonical roles |
| instruction | 每个角色 3 个只描述身份属性的变体；不复制完整 prompt |
| seed | 16 个候选：`42, 512, 1024, 2048, 4096, 5120, 6144, 7168, 8192, 9216, 10240, 16384, 32768, 65536, 131072, 262144` |
| calibration | 每角色 6 条文本 × 2 次重复 |
| holdout | 每角色 3 条未参与搜索的文本 × 3 次重复 |
| speaker embedding | 项目已有的 `WeSpeaker CNCeleb ResNet34-LM ONNX` 与 80-bin Kaldi fbank 规范 |
| 原始制品 | `<app-home>/benchmarks/20260905-v1.8.0-voice-recipe-search/` 与 `<app-home>/benchmarks/20260906-v1.8.0-voice-recipe-holdout/` |

本轮没有把公开原始音频复制进项目；CNCeleb 只出现在 speaker-embedding 评测模型名称和既有评测规范中。原始 WAV、embedding 和完整 summary 均留在仓库外的私有 benchmark 目录。

## 搜索 selector 结果

`variant` 是临时搜索脚本中的 instruction 变体编号；`seed` 是通过公共 `POST /v1/voices` 写入并由响应确认的确定性 seed。搜索 selector 使用 calibration embedding、readback、角色内稳定性和与其他角色 baseline centroid 的分离度排序；以下不是最终 holdout 结论。

| role | variant | seed | search within p05 | search margin p05 | search centroid acc. | readback CER mean |
|---|---:|---:|---:|---:|---:|---:|
| `serena` | 0 | 8192 | 0.7251 | 0.0375 | 100% | 2.81% |
| `vivian` | 1 | 9216 | 0.7147 | -0.1494 | 100% | 1.30% |
| `uncle_fu` | 0 | 10240 | 0.6365 | -0.0110 | 100% | 2.81% |
| `dylan` | 2 | 6144 | 0.6542 | -0.0853 | 100% | 2.81% |
| `eric` | 0 | 6144 | 0.5436 | -0.1880 | 100% | 2.81% |
| `ryan` | 1 | 10240 | 0.5882 | -0.2316 | 100% | 11.54% |
| `aiden` | 2 | 512 | 0.6293 | -0.2609 | 83.3% | 11.11% |
| `ono_anna` | 0 | 32768 | 0.4194 | -0.4691 | 66.7% | 10.54% |
| `sohee` | 2 | 262144 | 0.3499 | -0.0635 | 100% | 5.91% |

`serena` 的例子说明了为什么不能只看角色内 p05：只看 within-role 时，另一个候选 `variant=1, seed=10240` 达到 `0.8236`；加入九角色分离度后，正式 selector 选择 `variant=0, seed=8192`。最终判断必须以 holdout 为准。

## Holdout 结果

### 联合指标

| 指标 | 当前 recipe | selected recipe | 变化 |
|---|---:|---:|---:|
| within-role cosine p05 | 0.5810 | 0.6037 | +0.0227 |
| within-role cosine median | 0.8184 | 0.7736 | -0.0448 |
| between-role cosine p95 | 0.6598 | 0.6864 | +0.0266（变差） |
| separation margin p05 | -0.1228 | -0.2126 | -0.0897（变差） |
| nearest-centroid accuracy | 100% | 100% | 不变 |
| readback CER mean | 3.20% | 4.30% | +1.10 个百分点 |
| readback CER p95 | 8.76% | 20.97% | +12.20 个百分点（变差） |

预注册目标为 nearest-centroid accuracy `≥98%`、within-role p05 `≥0.60`、separation margin p05 `≥0.10`。selected recipe 只通过前两项，margin 失败；人工 ABX 按决策规则未执行，不能据此声明“同一个人”。

### 逐角色 selected holdout

| role | variant/seed | within p05 | margin p05 | centroid acc. |
|---|---|---:|---:|---:|
| `serena` | `v0/s8192` | 0.7048 | -0.0129 | 100% |
| `vivian` | `v1/s9216` | 0.7756 | -0.0886 | 100% |
| `uncle_fu` | `v0/s10240` | 0.6044 | -0.0889 | 100% |
| `dylan` | `v2/s6144` | 0.6428 | -0.1113 | 100% |
| `eric` | `v0/s6144` | 0.6410 | -0.0600 | 100% |
| `ryan` | `v1/s10240` | 0.6604 | -0.2126 | 100% |
| `aiden` | `v2/s512` | 0.6037 | -0.2257 | 100% |
| `ono_anna` | `v0/s32768` | 0.7914 | -0.0896 | 100% |
| `sohee` | `v2/s262144` | 0.5357 | 0.1730 | 100% |

只有 `sohee` 的 margin 在这组 holdout 上为正且超过 `0.10`，但其 within-role p05 仍低于 `0.60`；不能单独写回。

## 落地与运行态

- 工作区新增的 `seed` API 字段允许创建 custom voice 时显式传递并回显确定性 recipe seed；非法类型或超范围值 fail closed。本轮未发布该工作区 API 变更。
- 九个系统角色的 `instruction`、`seed` 和 `temperature=0.1` 未改动；搜索临时 voice 已清理。
- 临时 source server 已停止，原 managed LaunchAgent 已恢复为单实例运行。
- 恢复后 `/health`、`/readyz`、`/v1/models`、`/v1/voices`、`/metrics` 均核验；真实短 TTS 与 ASR smoke 均为 HTTP 200，TTS 返回 WAV，ASR 返回非空文本。

## 后续决策

当前不继续扩大 seed 网格或做盲目 prompt 微调。若产品要求固定角色的跨文本身份，下一步是用 `balanced/light` 的 CustomVoice；若必须同时保留开放式 VoiceDesign 和持久身份，则立项评估 VoiceDesign 生成锚点、Base checkpoint clone prompt、参考音频管理、切换成本和回退路径。
