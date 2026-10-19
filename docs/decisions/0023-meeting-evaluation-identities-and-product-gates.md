---
title: "ADR-0023：会议评测身份与产品评分门"
status: accepted
date: 2026-10-18
---

# ADR-0023：会议评测身份与产品评分门

## 决策

会议转录与分人的实验使用[评分策略](../../examples/perf/meeting-evaluation-policy.json)和独立 candidate/manifest/runtime-policy 摘要。候选包含实际 worker、adapter、模型文件、SDK、完整 preset、解码与后处理、归属算法和 scorer；后处理开关或任何有效参数变化均产生新摘要。v2 开发收据分别绑定开发与留出 manifest，不能由 schema 1 收据解锁。留出在推理前原子消费，换候选不能重用同一个 manifest；旧报告保留原值，只作历史诊断。

产品门与标准指标分别报告：

- `legacy_nonoverlap` 复算原 90%/95%/95%/80% 门，明确非重叠参考分母。空分母不通过。
- `product_all_regions` 进行整场一次最优身份匹配，排除 unknown 身份；重叠按 speaker-seconds 计数，短插话保留。recall≥90%、precision≥95%，逐场前四位逐人 recall≥95%，其余发言≥2 秒者逐人≥80%。额外 known 标签和静音中的假警报进入预测分母。unknown 不贡献正确项。
- 标准 DER/JER 使用 `pyannote.metrics==4.1`，主口径 collar=0、含 overlap；另列 collar=0.25、含 overlap 的研究对照，以及旧 skip-overlap 口径。
- 标准 cp/tcp/greedy DI-cp 使用 `meeteval==0.4.3`；中文 char-token 指标单独命名。全部假设文字（包括 unknown stream）进入官方 assignment，不添加自定义 unknown 惩罚。unknown 文本比例与产品身份门独立报告。
- 旧 probe 的参考时间重归属命名为 `temporal_oracle_*`，属于诊断，不解释为正式 DI-cp，也不把 cp−oracle 差值视为纯分人误差的因果估计。

全区间 pooled 与会议等权 macro 都必须过门，逐人失败不能被均值抵消。以来源会议组为统计单位，组内重复先平均，固定 seed=1717、10,000 次 paired bootstrap、双侧 percentile 95% 区间。认证要求总体比例下界过门；单个会议或缺人数层不形成认证。1–4 人对同 PCM/scorer 的 C0，DER/cpCER 点差与配对区间上界都须≤0。择优时区间跨零不视为等价，只有预先规定的 1pp DER 非劣界满足后才允许优先低延迟。

评分输入分为连续说话活动区间和带标签文字区间：前者用于 speaker-time、旧门及 DER/JER，后者用于 cp/tcp/greedy DI-cp 与 unknown 文字比例。活动区间不得携带文字，不以 ASR 段边界替代活动预测；文字参考与假设须成对提供，未观察时均显式为 `null`，空假设则代表已观察到的全量删除。评分输出使用 schema 3，旧 schema 2 输出不能汇入新汇总；candidate 的 scorer 源码摘要随实现变化。

汇总中的总体 recall/precision 按人数层检查 pooled 与 macro，不附加单场总体门；逐场逐人门及旧门仍独立必过。`decision` 区分 `pass`、`point_failed`、`insufficient_evidence` 和 `not_observed`：点值失败不可通过扩样复活，证据不足才可按固定检查点共同扩样；缺场或缺层须先补齐完整观察。非退化判定同样区分点值退化与区间证据不足。`quality_gate=fail` 仍覆盖全部未通过状态，任何评分输出都不单独签发认证。

## 条件与影响

本决策固定新实验的评分语义，不更改已部署能力人数、不启用候选、不改变 ASR 文本、不降低 #370 门槛。评分通过仍须独立完成来源锁、生产制品冻结、实际双路运行、一次性留出和安装态证据，才可签发对应范围的生产能力。

15 秒稳定标签 P95 和 5 秒 finish P95 仍为获批目标；现有 meeting revision window 的静态等待不能保证满足，真实联合评测前必须解决 A0 时钟前置。不得看完候选输出后调整阈值或放宽预算。

Python 3.14 本地独立开发环境已完成两个锁定 scorer 的安装/导入及人工小样本 cp/tcp/greedy DI-cp 运行。scorer 仅加入 `dev` extra，不进入服务请求路径依赖。具体测试记录见[实施记录](../implementation/2026-10-18-meeting-diarization-handoff-audit.md)。

## 回退

按逻辑提交反向修改评测工具、dev lock 与文档即可；没有数据迁移或运行态修改。恢复旧工具也不使历史收据具备新的认证效力。

依据：[调研设计](../superpowers/specs/2026-10-18-meeting-asr-diarization-research-design.md)、[MeetEval 官方 cp 实现](https://github.com/fgnt/meeteval/blob/v0.4.3/meeteval/wer/wer/cp.py)、[官方 greedy DI-cp 实现](https://github.com/fgnt/meeteval/blob/v0.4.3/meeteval/wer/wer/di_cp.py)，于 2026-10-18 核验。
