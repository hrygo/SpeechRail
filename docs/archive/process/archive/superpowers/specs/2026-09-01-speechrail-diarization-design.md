# SpeechRail 公共说话人分离设计

## 目标

在不改变 SpeechRail 公共 ASR/TTS 定位的前提下，恢复并提升原
`sona` 的多人会议能力：实时显示匿名说话人、在收尾后稳定归并标签，
并由会议应用完成人员身份和持久化。

## 边界

SpeechRail 拥有 PCM 输入验证、VAD/diarization 推理、会话内 label、重叠标识、
短期有界缓冲、分段结果和最终 remap。它不拥有会议、姓名、声纹库、数据库、UI、
LLM、播放或跨会话身份。

`sona` 拥有 `speaker_id → display_name` 的会议映射、人工更正、事务性
remap、纪要与展示。它不得再运行 Sortformer、CAM++ 或任何 ASR fallback。

## 公共契约

transcription session 的 `session.update.session.diarization` 是可选对象：

```json
{"enabled": true, "speaker_count_hint": 4, "finalize": true}
```

`speaker_count_hint` 仅是 1–8 的软上限，不保证发现的说话人数量。未启用时事件维持
既有形状；启用却无 profile 时服务发稳定错误 `diarization_not_available`。

`transcription.completed.segments[]` 增加可选字段：

```json
{
  "speaker": "spk_01",
  "speakers": [{"id": "spk_01", "confidence": 0.91}],
  "speaker_revision": 1
}
```

`speaker` 是仅含一个主说话人的兼容字段；有重叠时 `speakers` 可以有多个成员。
所有 ID 只在一个 SpeechRail session 内稳定。`transcription.diarization.completed`
在 commit 后至 `session.completed` 前一次性发出，其中 `mapping` 以旧 ID 到 canonical
ID 表示确定性归并；没有变更时 `mapping` 为空。

## 领域设计

`DiarizationEngine` 是不依赖 FastAPI、WebSocket 或厂商 SDK 的 async port。它接收
经验证的 PCM、会话配置和 segment 边界，输出 `DiarizationAssignment`。`DiarizationSession`
只保留固定大小 ring buffer、累计时间轴与 session local state；超限立即返回稳定错误。
`DiarizationEngine.finalize()` 返回 immutable remap。具体模型 adapter 是 infrastructure：
流式 Sortformer 用于在线标签；embedding + 聚类用于收尾校正。模型 adapter 的输出在
进入领域前必须验证 speaker ID、时间范围、置信度和数量限制。

## `sona` 映射

SpeechRail adapter 解析 `speaker` / `speakers`，为会议生成
`epoch:<source_epoch>:speaker:<id>`。不含 speaker 的非-diarization 会话沿用单一
`speaker:0`，但会议启动时必须请求 diarization；未获支持就显式报告
`SPEECHRAIL_DIARIZATION_UNAVAILABLE`，不得静默生成单说话人会议。

会议持续复用既有 `DiarizationSmoother` 作为纯文本/时序展示规则，删除
`MeetingVoiceprintManager`、CAM++ 配置和整场 PCM 缓冲。收到 SpeechRail finalize
mapping 后，会议 repository 在一个事务中应用 remap，保留人工 display name。

## 验收

- 单元：输入/输出 schema、label 验证、ring-buffer 上限、overlap、映射归并。
- WebSocket：启用/未启用/未就绪状态，completed event 和 finalize event 的有序性。
- 客户端：多 speaker segment 映射、overlap 的主 speaker 选择、无 profile 的 fail-closed。
- 回归：SpeechRail 全量测试、Ruff、mypy、OpenAPI lint；sona 全量测试、Ruff、
  mypy、前端测试与构建；以真实本地 ASR worker 完成原有语音助手、字幕、会议 smoke。

真实 diarization model 上线门槛另行用已授权评测集衡量在线延迟、DER/JER、label
稳定性和会议人工更正率；在此之前 profile 不在默认运行配置中启用。
