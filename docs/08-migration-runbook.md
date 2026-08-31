---
title: "SpeechRail 迁移 Runbook"
status: active
date: 2026-08-31
---

# SpeechRail 迁移 Runbook

本 Runbook 目标是把 Qwen3-ASR 从 `voice-realtime` 的综合进程中独立出来，同时保持
QwenPaw、Hermes 和 `voice-realtime` 可回退。每一阶段都可以单独验收。

## Phase 0：冻结基线

记录当前事实：

```text
voice-realtime 1.4.0
旧 WLK：127.0.0.1:8001
QwenPaw：127.0.0.1:8001/v1
Hermes：当前 STT endpoint/model 配置
```

执行：

```bash
cd /Users/hrygo/Documents/voice-realtime
uv run pytest tests/asr tests/test_subtitle_proxy.py -q --no-cov
git status --short --branch
```

保存 `/health`、`/v1/models`、短音频 REST、WS partial/EOF 的结果。不得在这一步修改
旧仓库配置。

## Phase 1：SpeechRail 旁路启动

使用 `8201`，避免与旧 WLK 冲突：

```bash
cd /Users/hrygo/Documents/SpeechRail
uv sync --extra dev
uv run speechrail
```

先确认：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
```

模型未 ready 时，`/readyz=503` 是正确状态；不能通过修改客户端绕过 preflight。

## Phase 2：QwenPaw/Hermes REST 切换

### QwenPaw

将 base URL 临时改为 `http://127.0.0.1:8201/v1`，模型改为 canonical ID，完整重启
QwenPaw，完成录音 smoke。失败时只把 URL 改回 `8001/v1`。

### Hermes

将 `STT_OPENAI_BASE_URL` 改为 `http://127.0.0.1:8201/v1`，
`STT_OPENAI_MODEL` 改为 canonical ID，重启 Hermes 进程，验证一条语音消息。聊天模型
使用的 `OPENAI_BASE_URL` 不变。

## Phase 3：voice-realtime legacy 切换

先确认 SpeechRail 的 `/asr` parity：

- 首帧 `config`。
- `language` 和 `mode=full` 解释一致。
- `lines`/`buffer_transcription` 结构一致。
- 空 PCM → `ready_to_stop`。
- token 失败不会泄露 traceback。

然后执行切换窗口：

1. 停止 `voice-realtime` `vr-subtitles` 和 `run-all.sh` 里托管的 WLK 子进程。
2. 关闭旧 WLK 的 `8001` 监听。
3. 用 SpeechRail 配置监听 `8001`。
4. 保持 `voice-realtime` 的 host/port 配置不变，重新启动 UI。
5. 运行字幕、会议开始/结束、SRT、数据库 confirmed 文本和重连测试。

如果任一项失败，执行回滚，不在窗口内修改会议代码。

## Phase 4：现代 Realtime adapter

在独立的 `voice-realtime` feature 分支中：

1. 增加外部 SpeechRail URL 配置。
2. 增加 `/v1/realtime` adapter，把 delta/completed 转成现有领域事件。
3. 保留 legacy `/asr` 作为回退。
4. 修改 `run-all.sh`，默认不再拉起 WLK 子进程。
5. 完成 `assistant → meeting → idle → assistant` 闭环测试。

这一步完成后，`voice-realtime` 不再拥有 Qwen3/WLK server 进程，只拥有客户端会话、
AudioHub、会议、Sortformer 和应用逻辑。

## Phase 5：退役重复实现

达到以下条件才删除或冻结旧代码：

- 三客户端连续 smoke 通过。
- 至少一个完整会议闭环通过。
- 旧端口回滚演练通过。
- SpeechRail 具备模型/runtime/snapshot 可追溯记录。
- WLK compatibility 与现代 Realtime 都有契约测试。
- 所有 benchmark 结果已经迁移到独立 evidence 目录。

退役只删除重复 ASR server/worker 入口，不删除会议、UI、TTS、AudioHub、Sortformer 或
数据库代码。

## 回滚

```text
停止 SpeechRail
  → 恢复旧 WLK :8001
  → voice-realtime 保持原 host/port
  → QwenPaw base_url 恢复 8001/v1
  → Hermes STT_OPENAI_BASE_URL 恢复旧值
```

回滚后保留 SpeechRail 日志/运行清单供分析，但不保留音频。若旧 WLK 无法启动，先恢复
旧项目原始 branch/环境，不进行破坏性 git reset；具体操作必须由用户授权。
