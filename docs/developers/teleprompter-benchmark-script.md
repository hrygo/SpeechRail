---
title: "提词器时延基线朗读稿与标注模板"
status: active
version: "0.1.0"
date: 2026-09-29
---

# 提词器时延基线朗读稿与标注模板

> 用途：为验收标准第 4 条的**真实时延基线**（#83 / #114）准备朗读材料与人工标注。
> 依据：方案 §11.5 真实音频数据集、§11.6 指标定义、§11.7 质量门槛。
> **本文件只提供稿件与标注模板，不含任何音频**。音频与原始结果一律落在仓库外受控位置。

## 为什么需要真人朗读

第二十五轮的实测（阶段报告 §3.1 末）已证明探针能驱动线上 Realtime ASR，并给出首个 partial
延迟 P95 1034.6 ms、终态 commit P95 31.5 ms。但那批输入是 **TTS 合成**素材——按 §11.5
「不得使用 TTS 生成主质量集」，它只能作链路量级参考。**跟随时延与回稿恢复分位必须用真人
朗读、且带人工核验的阅读位置标注**才能测。

真人朗读与合成音的关键差别不在音质，而在**节奏**：真人会停顿、改口、重读、重复、犹豫，
这些正是跟随控制器最容易出错的边界，也正是 §11.6 要测的「正常跟随延迟」「错误停滞」
「回稿恢复延迟」赖以成立的条件。

## 朗读材料 A（约 2–3 分钟，普通话口播 + 数字单位）

请按自然语速朗读，**不要刻意放慢或匀速**。标点处自然停顿。

> 大家好，欢迎来到本期节目。今天我们聊一个很多人都会遇到的问题：设备价格。
>
> 先看几组数字。这台设备的标称功率是 50 瓦，配套的电源适配器是 12 伏 2 安培。如果把它
> 换成同系列的高功率版本，功率会变成 150 瓦，适配器则要 20 伏 3 安培。价格方面，标称为
> 2999 元，促销价是 2599 元，老用户还可以叠加 200 元的券。
>
> 这里要提醒一句，2999 和 2599 差的是 400 元，不是 300 元。算清楚这一点，再决定要不要等
> 促销。
>
> 温度的指标也一样。官方标称工作温度是 0 到 35 摄氏度，存储温度是负 20 到 60 摄氏度。
> 实验室环境下测到的峰值是 42 摄氏度，这个数字超过标称上限，所以它只适合放在通风处。
>
> 保修期是 12 个月，延保到 24 个月需要额外付费。易损件不在保修范围内，这一点买之前要问
> 清楚。
>
> 重量是 1.8 公斤，尺寸是 240 乘 180 乘 45 毫米。放进标准机架刚好，占一个 U 位。
>
> 再说一个容易搞混的地方。左声道和右声道的增益要设成一样，默认是负 3 分贝。如果你只想
> 听左边，把右边设成负 60 分贝就够了。
>
> 好，以上就是这期节目的主要信息。我们下期再见。

**覆盖的意图**：连续朗读、数字与单位、精确价格差、负号、技术参数、结尾。

## 朗读材料 B（约 2–3 分钟，含停顿／重读／回稿／脱稿）

这段刻意设计了几处**非匀速**的地方。请按真人习惯处理：

- 括号处是**停顿**（停 1–2 秒再继续）；
- 「等等」处是**回稿重读**（把上一句再说一遍）；
- 「……」处是**脱稿**（念一句与稿件无关的话，然后回到稿件）。

> 今天我们请到了嘉宾。（停）先跟大家打个招呼。
>
> 好的，请问你平时是怎么安排一天的时间的？
>
> 我一般早上七点起床，先喝一杯咖啡。（停）等一下，我刚才说的是七点，没错，七点。
> 然后洗漱、吃早饭，大概七点半出门。
>
> 路上大概四十分钟。……今天风有点大，不过还好。地铁比平时挤一些。
>
> 到公司之后先看一下邮件，然后开始工作。中午会休息一个小时。
>
> 下午主要是开会和写东西。晚饭一般在公司附近解决。
>
> 这样一天就过去了。我觉得节奏还算规律。

**覆盖的意图**：自然停顿、回稿重读、脱稿后回归、对话语速、非匀速。

## 朗读材料 C（约 1–2 分钟，中英混合技术讲解）

术语保持英文原样朗读，不要翻译成中文。

> 今天讲一下怎么在你的项目里集成实时语音。
>
> 首先，你需要一条 WebSocket 连接。端点是 wss://127.0.0.1:8201/v1/realtime，
> 协议版本是 OpenAI Realtime 的当前版本。
>
> 握手的时候，model 参数填 speechrail-asr。采样率固定 16 kHz，单声道，PCM 16-bit。
> 记住这四个数字：16000、1、16、PCM，少一个都不行。
>
> 连接建立之后，server 会先发一个 session.updated。你要等这个事件到了，再开始推音频。
> 如果不等，服务端会拒绝这一路流。
>
> 推音频的时候按 100 毫秒的节奏发。记住是实时发送，不要攒着一次性发完——那样测出来的
> 延迟是假的。
>
> 收到 hypothesis 事件的时候，把它渲染到界面上。收到 commit 事件的时候，才认为这一轮
> 识别结束。
>
> 最后一点，close 的时候记得发 drain 和 clear，不然麦克风的占用不会释放，下次就打不开了。
>
> 好，这就是全部要点。谢谢大家。

**覆盖的意图**：中英混合、协议术语、URL 与端口朗读、连续数字、结尾。

## 标注模板：manifest 的真实契约

**先看这个，否则一定会写错。** `teleprompter-replay` 的 manifest 契约是
`TeleprompterReplayManifest`（`macos/SpeechRailApp/SpeechRailApp/TeleprompterReplayEvaluator.swift`），
`schema_version` 必须是 `teleprompter.replay.v1`。它由**三段数组**组成——不是「每个标注一行」：

- `segments`：冻结的稿件分段，每段一个 `id` 与 `text`；
- `events`：按接收顺序排列的 Realtime 事件（`kind` 为 `partial`／`snapshot`／`completed`／`failed`），
  `at_milliseconds` 是**相对第一个事件的虚拟时钟偏移**，回放从不真的 sleep；
- `labels`：**每个事件一条**，`event_index` 指向 `events` 里的下标。

`labels` 的 `intent` 只有四个合法取值，且**大小写是契约的一部分**：

| `intent` | 含义 |
|---|---|
| `read` | 正常朗读，系统应跟随 |
| `improvise` | 脱稿／停顿。**保持不推进是对的，擅自跳过是错的** |
| `reRead` | 真正回读前面某句。注意是 camelCase，**不是 `re_read`** |
| `manualJump` | 有意跳读。**不是 `manual_jump`** |

> **我自己踩过的坑**：第一版这份模板把 intent 写成了 `re_read`／`manual_jump` 的 snake_case。
> 解码器只认 `read`／`improvise`／`reRead`／`manualJump`，照 snake_case 写必然解码失败——
> 这与阶段报告 §2 第 11 条记录的「帮助文本与解码器不一致」是同一类坑。接线前请以
> `Intent.manifestValues` 为准，不要凭直觉拼字符串。

一份最小可用的 manifest（值均为占位，需按真实录制填写）：

```json
{
  "schema_version": "teleprompter.replay.v1",
  "dataset_revision": "A_v1",
  "baseline_commit": "<基线 commit>",
  "candidate_commit": "<候选 commit>",
  "policy_revision": "<推进策略版本>",
  "language_lane": "zh",
  "device_class": "macbook-builtin-mic",
  "segments": [
    { "id": "s0", "text": "大家好，欢迎来到本期节目。" },
    { "id": "s1", "text": "先看几组数字。这台设备的标称功率是 50 瓦。" },
    { "id": "s2", "text": "价格方面，标称为 2999 元，促销价是 2599 元。" }
  ],
  "events": [
    { "at_milliseconds": 0,    "kind": "partial",   "item_id": "i0", "event_id": "e0", "revision": 1, "text": "大家" },
    { "at_milliseconds": 320,  "kind": "completed", "item_id": "i0", "event_id": "e1", "revision": 1, "text": "大家好，欢迎来到本期节目。" },
    { "at_milliseconds": 900,  "kind": "partial",   "item_id": "i1", "event_id": "e2", "revision": 1, "text": "先看几组" }
  ],
  "labels": [
    { "event_index": 0, "intent": "read", "expected_segment_index": 0 },
    { "event_index": 1, "intent": "read", "expected_segment_index": 0 },
    { "event_index": 2, "intent": "read", "expected_segment_index": 1 }
  ]
}
```

### 标注口径（对应 §11.6）

- `expected_segment_index` 指**读者已读到的段落**，不是系统确认到的段落。把它挂到系统已追上的
  事件上，会让延迟恒为 0 且**不报错**——这是最容易把测量做废的一个错误。
- 时间标签必须**人工核验**；强制对齐可辅助，但按 §11.5 不能作为唯一真值，
  **也不能把待测 ASR 的输出当标准答案**。
- **第 0 段是回放起点**，系统初始就在第 0 段，因此不产生延迟样本。这是正确行为，
  不要把它记成「缺样本」。
- 素材里若**完全没有** `improvise` 标注，报告会提示「误推进检测从未被触发」；
  若没有任何带 `expected_segment_index` 的 `read` 标注，报告会提示分位未测量。
  这两条 caveat 是有意设计的，别为了让报告好看而删掉标注。

## 本模板已通过真实解码器验证（2026-09-29）

上面那份 manifest 示例**不是照契约想象出来的，是跑过 `teleprompter-replay` 的**：

- 按模板填写 → 成功产出 `teleprompter.eval.v1` 报告，`sample_count: 3`、
  `advanced_event_count: 3`，并正确触发两条 caveat（无 `improvise` 标注、无回稿恢复样本）；
- 故意把 `read` 改成 `re_read` → 如预期被拒，错误信息直接列出合法取值：
  `字段 labels.Index 0.intent：Cannot initialize Intent from invalid String value re_read（接受的取值：read / improvise / reRead / manualJump）`。

**接手方若只改素材、不改字段名，可以直接复用这份模板**；若要动结构，先用上面的
「snake_case 应当被拒」做一次自检，确认自己接的还是同一个解码器。

## 录音与重采样要求

探针要求输入为 **24 kHz mono PCM16**（realtime 唯一 wire rate）。本机麦克风为 48 kHz，
录音后需重采样；重采样要在仓库外进行，且保留原始录音以便核验。

## 验收时怎么跑

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
CURRENT_PYTHON="$APP_HOME/runtime/current/.venv/bin/python"

# 1) 探针：首个 partial 与终态延迟（材料需为 24 kHz mono PCM16）
"$CURRENT_PYTHON" tools/probe_teleprompter_latency.py <外部素材>.wav \
  --profile quality --output <外部结果>-probe.json --app-home "$APP_HOME"

# 2) 确定性回放：跟随／回稿延迟、失败分母、caveats
swift run --package-path macos/SpeechRailApp teleprompter-replay \
  --manifest <外部素材>-manifest.json --output <外部结果>-report.json
```

manifest 的 `id` 与 `language` 只能用安全标签，**不得写入原始路径、文本、音频或 token**。

## 怎么算通过

对照 §11.7（这些是**待建立基线的工程目标**，不是实测承诺）：

| 门槛 | 目标 | 本材料能测的 |
|---|---|---|
| 无歧义连续跟随 | P95 ≤ 1000 ms | 材料 A、C（连续朗读） |
| 附近回稿恢复 | P95 ≤ 2000 ms | 材料 B（回稿段） |
| 正常朗读错误停滞 | 超 3 秒事件 < 1% | 材料 A、B |
| 严重误推进 | 对抗回归零事件 | 材料 B（脱稿段） |
| 正常手动操作 | P95 ≤ 100 ms | **本材料不测**——属界面响应，U-10 走查 |

失败样本超过 5% 时，不能只对成功子集给一个看似达标的 P95。报告必须同时写明误推进、
停滞、恢复延迟与失败分母，**不以全部停住换取安全**。
