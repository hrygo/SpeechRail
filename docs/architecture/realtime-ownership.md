---
title: Realtime 会话状态与资源所有权
status: active
version: "1.0.0"
date: 2026-10-09
---

# Realtime 会话状态与资源所有权

`OpenAIRealtimeSession` 组合三个用例 owner，负责协议配置、事件派发和组合关闭。
WebSocket route 负责传输、队列和 JSON；公开事件由
[Realtime ASR/TTS 协议契约](../../contracts/realtime-openai.md)定义。

| Owner | 独占状态 | 依赖与交付边界 |
| --- | --- | --- |
| `RealtimeAsrOwner` | 输入采样时钟、重采样器、VAD/admission、冻结 item、reader、commit barrier/final、ASR lane 与 reservation | ASR factory、Governor、metrics；辅助接口只允许接收 PCM、冻结文本、清理和读取能力状态 |
| `RealtimeTtsOwner` | 连接级 request ledger、在途任务集合、当前 utterance | 音色目录、incremental service、execution ports、catalog、readiness 与发送端口 |
| `TtsUtterance` | 单次 request/response/plan、ready、task、controller、window、receipt、pending append、PCM 计量、wire terminal lock | 每条异步路径捕获对应 context；领域终态与模型回收仍由 `StreamController` 拥有 |
| `RealtimeAuxiliaryOwner` | alignment task、diarization actor/ledger、epoch、归属单位、speaker revision、finalization | aligner、diarization engine/admission、metrics；输入接口只提供不可变身份快照与 final drain |

子 owner 接收显式窄端口及协议配置读取函数。它们不持有 `AppServices` 或根 session
的任意写接口。根在候选配置、VAD 构造与 diarization 资源准备成功后发布配置；
失败时保留原配置与选项。

## 输入与辅助结果

每个 `_AsrItem` 保持自己的 reader、采样区间、commit 身份和 canonical final。
后续输入可以推进到新 item，旧 final 仍按冻结身份交付。`FrozenTranscript` 把已确认文本、
revision、采样区间、PCM pin 和 connection generation 交给辅助 owner；辅助结果补充
alignment/attribution，不修改 canonical final。

辅助 owner 通过 `AsrFinalSource` 读取 `AsrIdentity`。clear/close 改变 connection generation，
迟到结果必须通过任务、epoch 与 generation 检查。仅推进到下一输入 item 不使原 item
的 alignment 失效。diarization finish 依次等待 ASR finals、alignment 与 actor drain。

## 输出与关闭

TTS request ledger 有界且不驱逐，连接内重复 request ID 稳定拒绝。admission 尚未完成时，
append/finish 等待所属 utterance 的 ready；取消唤醒该 context 的等待者。旧 task 的 finally、
append ACK 和 terminal 只能操作创建时捕获的 context，不能清空或唤醒下一请求。

`StreamController` 确认模型回收后交付唯一领域终态。wire terminal 使用每次 utterance 的锁
与计量。退休但仍在发送终态的 task 保留在连接级任务集合，关闭时同样被等待。模型回收失败时，
controller/context 保持未确认，Governor lane 隔离与 pending receipt 保留，错误向关闭方传播。

根关闭创建一个受保护的清理 task。重复调用或重复取消等待者不会抛弃该 task。
关闭先撤销 ASR generation，再取消辅助任务、关闭 TTS、关闭 ASR 与辅助资源。
单个 owner 失败仍执行其余 owner 的关闭，所有失败以 `ExceptionGroup` 返回。

## 验证范围

独立 owner 测试使用窄 fake；组合回归使用 fake backend。覆盖 admission 前取消、
旧 context 收尾、冻结 final/采样区间、辅助 epoch、重复取消、清理失败与资源隔离。
这些测试不证明真实模型质量、长时稳定性或设备/UI 行为。
