---
title: "音色验证应用用例与执行所有权"
status: active
audience: "核心开发者、架构评审者"
version: "3.8.1"
date: 2026-10-07
---

# 音色验证应用用例与执行所有权

候选验证和固定探针质量运行分别由 `application/candidate_validation.py` 与
`application/voice_quality_run.py` 编排。HTTP adapter 保留鉴权、输入 schema、
request ID、错误 envelope 和响应投影，不再依赖另一 route 的私有业务函数。
两用例共享 `voice_validation_execution.py` 中的有界合成、重采样、ASR 与评分组件，
复用现有领域评分和 validation binding，不合并不同的验证策略。

## 阶段、资源与提交

| 阶段 | Owner | 资源与输入 | 失败结果 / 提交点 |
|---|---|---|---|
| 候选状态与新文本检查 | `validate_candidate` | 候选快照、当前 capability、新文本 | 状态、文本、capability 不合法在计算前拒绝；标记更新锁内复查 revision |
| 候选音频生成 | `execute_candidate_validation` | TTS reservation；每请求 pin 候选 voice revision；PCM 最多 30 秒 | 空输出、坏 PCM、超限、backend 异常拒绝；产生身份在 reservation 内采集 |
| 固定探针音频生成 | `run_voice_quality` + `synthesize_probes` | 整次运行持有 registry profile lease；TTS reservation；每条 pin voice revision | 合成失败按 probe 评分；关闭失败立即隔离 lane 并停止后续 probe |
| TTS 驱逐 | 执行组件，调用者持 TTS reservation | 与合成相同 resource key；同一绝对 deadline | 失败隔离 lane；质量用例不再进入 ASR 或保存成功报告 |
| ASR 可懂度 | `transcribe_pcm` / `evaluate_probe_intelligibility` | batch ASR reservation + AdmissionQueue；PCM 从 24 kHz 转 16 kHz | 候选缺证据为 warn；固定探针缺证据为 unevaluated；超时或资源拒绝由 adapter 映射 |
| 候选证据提交 | `validate_candidate` | 本次音频摘要、执行身份、voice revision、policy/recipe | 提交前查 deadline；`update_with_validation_audio` 锁内 CAS；失败不返回保存成功 |
| 固定探针证据提交 | `run_voice_quality` | profile lease 持续到提交；本次 producing identity | 提交前查 deadline；registry 锁内 expected revision / revoked 检查；保存失败返回 `validation_persisted=false` |
| 人工听审 | `apply_human_review` | 当前 revision 的真实 machine pass 与 validation ID | 锁内复查，不给旧结果补新审核；机器结果不填写 identity/naturalness 人工字段 |

## 取消与清理

共享执行阶段持有一个本次调用的 task。调用方取消只向它发起一次取消；若阶段已因自身
deadline 进入取消，则不追加取消。随后通过已有 `join_cleanup` 等待其结束，重复取消
不得打断回收，也不得使外层 reservation/profile lease 提前退出。子任务的异常由 owner
取回，再向正常调用方传播，避免取消 shield 的已处理异常进入 event-loop 日志。

TTS 流继续使用 `iter_validated_audio` 的 source-close owner；关闭失败调用 governor
的 `quarantine_tts_lane`，隔离范围遵循现有 lane 策略。固定 probe 不继续复用未确认回收
的 backend。`backend_reclamation_failed` 为 503 且不可自动重试；隔离持续到 runtime
重新建立。隔离并不表示物理资源已经释放。

task 不脱离调用方存活；不引入全局后台 task 集合、额外 worker 或无预算并发。若 backend
永久拒绝结束，调用方仍保留资源所有权并等待，deadline 不承诺强杀进程或确定的响应上界。
真实 worker 的回收时限属于 worker owner 的责任，不由应用层伪造完成。

## 证据身份与可用性

生成音频对应的 runtime revision 在产生它的 TTS reservation 内读取，后续驱逐 A→B
不把 A 音频绑定到 B；读取失败保持 unknown。构造 binding 时不再次传入 live synthesizer，
因此不会在提交阶段补填另一 worker 的身份。

计算成功、保存成功、机器通过、人工通过分别是不同事实。unknown 身份不能使候选 machine
pass；保存失败不能发布 production-ready。固定探针验证的是输出，始终不代填人工 identity
审核；数字精确匹配仍服从既有领域规则。

## 验证与回退

fake 端口回归覆盖身份切换、unknown、提交 CAS、保存失败、重复取消及 timeout/cancel
交错；HTTP 回归单独检查错误与响应。定向测试与 CI 不能代表真实模型质量、性能或长稳验收。
本变更不迁移持久化格式；普通 revert 恢复入口接线，不删除候选或音色资产。
Epic 分组与实施账本见 [#238 loop 计划 r2](../implementation/2026-10-07-issue-238-solid-loop-plan-r2.md)。#245 已由用户确认实施完成，临时避让限制已撤销；实际其他 worktree 的未提交改动仍须保留。
API 消费方处理见 [音色验证失败与证据保存](../users/voice-validation-failures.md)。
