---
title: "Speaker Diarization 质量验收交接"
status: pending_external_input
date: 2026-09-08
---

# Speaker Diarization 质量验收交接

CoreML FP16 运行时、OpenAI 文件接口、Realtime opt-in 与确定性回归已完成；以下验收无法由
fake backend、D1 runtime smoke 或代码审查替代。需要由项目方安排一次受权的本机验证。

## 需要提供的最小输入

- 一份**可在本机短期处理**的匿名评测 manifest，包含每条音频的本机路径、RTTM、UEM 和唯一
  sample id。每项必须有 `reference_rttm`、`hypothesis_rttm` 和 `uem` 相对条目；工具拒绝缺少
  UEM 的 manifest。要评正文时，成对提供 `reference_text_json`、`hypothesis_text_json` sidecar：
  其 JSON 是 `{text, speaker, status?}` 数组；reference 的 `speaker` 必填，hypothesis 的
  `unknown`/`null` 不会映射为真值 speaker。音频、RTTM、UEM 和 sidecar 不进入仓库、日志或提交。
- eval 与 tune 必须是不同 sample id。eval 至少覆盖清晰双人、远场、重叠、短插话、相似音色、
  长静音和无语音；每条标明语言与参考说话人数。
- 一份固定中文 ASR 正文完整性样本，以及确认过的人工听感结论。当前没有任何 DER/JER 结论可
  以 D1 的 90 秒 smoke 代替。
- 一个可连续占用本机两小时的窗口，用于晚加入、8 秒边界、长静音、重叠、慢客户端、cancel/finish
  和物理内存增长检查。
- 一段**人工确认尾部仍在讲话**的匿名 PCM/WAV fixture，结尾至少覆盖模型一个前端窗口；同时保留
  尾部讲话的起止样本范围。用同一文件做规则和不规则分包，确认最终活动帧覆盖该范围且 finish 后
  worker 已退出。这是 AC-15/19 的模型尾帧真值，不可由静音或合成 fake port 替代。

## 执行与交付

1. 先在隔离目录保存输入的路径、来源许可、SHA-256 与 manifest；不要复制原始音频到仓库。
2. 在隔离的 dev 环境使用锁定的 `pyannote.metrics==4.1` 运行
   `tools/evaluate_diarization_e2e.py`。它以显式 UEM、指定 collar、计 overlap 的 DER/JER 为主结果，
   并要求内置 DER 与参考评分一致；不一致即停止报告并保留失败样本 id。若有文本 sidecar，报告同时
   输出 cpCER：每位 speaker 的整场文本汇总后作一次全局映射，插入、删除、替换和 unknown 均计分；
   不提供 reference 文本时它为 `null`，不得写成 0。报告还应含正文完整性、条件归属指标与 unknown 统计。
3. 在相同 CoreML bundle、worker、ASR profile 和固定请求分包下，记录 RTF P50/P95、词尾到 final
   延迟、ASR 共存 P95、pid/退出状态及 physical footprint。
4. 两小时 soak 输出按 5 分钟采样的 footprint、错误、degraded、finish/cancel 事件计数；判定稳定
   增长不超过 10%。

## 回传格式

回传一份脱敏 Markdown 报告和 manifest 的非敏感摘要即可。报告须给出：运行版本与 bundle hash、每
个场景样本数、指标、失败样本 id、人工判断、日志中是否出现原文/音频，以及是否满足发布阈值。

本交接不要求上传音频、RTTM、UEM、API key 或绝对模型路径；收到结论后，项目可将 AC-15、AC-19、
AC-31、AC-35、AC-36 从“待验证”改为通过，或据失败样本修正实现。
