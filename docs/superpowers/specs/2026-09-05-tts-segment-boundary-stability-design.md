# SpeechRail TTS 合成片段边界稳定性修复设计

## 背景与已确认事实

2026-09-05 对真实 SpeechRail TTS 输出进行了 REST 与 Realtime 冒烟：长文本与八组短文本均未发现
PCM16 削顶，首尾样本通常接近零；Realtime 源块中位间隔约 25 ms、最大约 44 ms，超过 200 ms
的间隔为 0。因此 SpeechRail 不是 Sona 连续爆音的主根因，连续爆音主要由消费端 CoreAudio
播放过载造成。

SpeechRail 自身仍存在一个独立的边界缺陷：

- `src/speechrail/domain/tts.py` 已定义 `apply_crossfade()`；
- `MlxVoiceDesignEngine._to_pcm()` 只对最终块做尾部静音裁剪和 5 ms fade-out；
- `MlxVoiceDesignEngine._generate()` 没有对首个非空 PCM 块做 fade-in；
- Realtime 按句拆分并为每句调用 worker，因此独立合成片段可能从静音直接跳到非零首样本。

该缺陷更可能表现为句首 click，而不是持续噼啪或长播报失速，但属于 SpeechRail 服务内部应修复的
PCM 逻辑边界。

设计收口期间并行完成了自定义音色/voice registry 改动，并已由提交 `d4a7c9f` 独立收口；其中
`qwen3_tts_worker.py` 新增 seed 与 temperature 选择。边界修复应基于该提交之后的 HEAD 实施，
保留这些逻辑，不得回退或改写其职责。

## 目标

1. 每次 `MlxVoiceDesignEngine.synthesize()` 的首个非空 PCM 块应用一次 5 ms fade-in。
2. 保留最终块现有的尾部静音裁剪与 5 ms fade-out。
3. 空块不得消耗“首块”状态，中间流式块不得逐块 fade。
4. REST、Realtime、OpenAI compatibility 的公共事件、chunk index、PCM16 24 kHz 格式保持不变。
5. 以 SpeechRail 1.6.9 patch release 独立构建、部署和回退。

## 非目标

- 不修改 Qwen3-TTS 模型、voice instruction、seed、temperature 或采样策略。
- 不改变句间 80 ms pause，也不把 crossfade 扩展为跨句重叠混音。
- 不负责 Sona、Pipecat、PyAudio 或 CoreAudio 播放调度。
- 不持久化 TTS 文本或 PCM，不输出 API key。
- 不把 `/readyz=200` 当作真实音频质量验收。

## 采用方案

在 `MlxVoiceDesignEngine._generate()` 内维护单次合成调用作用域的 `first_chunk` 布尔状态：

```text
model.generate() result
        │
        ▼
_to_pcm(result)
  ├─ 空 bytes：跳过，不改变 first_chunk
  ├─ 首个非空块：apply_crossfade(fade_in=True, fade_out=False)
  ├─ 中间块：原样输出
  └─ 最终块：_to_pcm() 继续负责 fade-out
```

首块处理放在 `_to_pcm()` 之后，原因是 `_to_pcm()` 已完成 float→PCM16 转换，并且
`apply_crossfade()` 的输入契约就是 PCM16 bytes。首块状态属于一次 `_generate()` 调用，不进入
engine 实例状态，因此并发请求之间不会串扰。

若单次合成只有一个非空最终块，处理顺序为：`_to_pcm()` 先做 fade-out，随后 `_generate()` 再做
fade-in，最终得到首尾都平滑的单块音频。

## 公共接口与兼容性

不增加配置字段，不修改 HTTP/WS schema，不改变：

- `AudioChunk` 数据结构；
- PCM16 little-endian、mono、24,000 Hz；
- Realtime `response.audio.delta` / `response.audio.done` 顺序；
- chunk index 和完成事件；
- voice registry 与 voice alias 规则。

REST 与 Realtime 都通过 `Qwen3TtsWorker` 使用同一 engine，因此修复在 worker 内接线即可覆盖两条
入口，无需在应用层重复处理。

## 错误处理与观测

- `apply_crossfade()` 对不足 5 ms 的短块沿用现有有界 ramp 行为。
- 空块继续被 worker 丢弃，不产生空 `AudioChunk`。
- crossfade 不新增日志；避免记录文本、PCM 或请求隐私数据。
- 任何转换异常沿用现有 worker 错误传播，不静默返回未处理音频。

## 自动化验收

- 两个 2,400-sample 常量块：首块首样本接近 0，首块中后段保持原幅值。
- 最终块开头与中段保持原幅值，末样本接近 0。
- 首个 model result 为空时，后续首个非空块仍执行 fade-in。
- 单块最终结果同时具有 fade-in 和 fade-out。
- 现有 TTS worker、streaming splitter、REST 与 Realtime 测试全部通过。
- 版本一致性、ruff、mypy、OpenAPI lint 和 wheel 检查全部通过。

## 真实 PCM 验收

部署 SpeechRail 1.6.9 后，至少合成一组短句和一组多句文本：

- HTTP/WS 成功且 PCM 非空、字节数为偶数；
- 每个独立合成片段首样本绝对值小于 100；
- 最终样本绝对值小于 100；
- 无绝对值达到 32760 的样本；
- 无可闻句首 click，事件顺序和 chunk index 连续。

临时 PCM 只写入临时目录，统计完成后立即删除。

## 发布与回退

该修复作为向后兼容 bugfix 发布为 `1.6.9`。构建 wheel 后使用现有 macOS 版本化安装器切换
`runtime/current`，安装前记录上一 release 的绝对路径。

回退时先 disable 当前 LaunchAgent，把 `runtime/current` 恢复到记录的 release，使用上一 release
自带的 `speechrail service install` 重新渲染服务定义，再 enable 并验证 `/health`、`/readyz`、
`/v1/models`、`/v1/voices`。不得删除 releases、外部模型或私有配置。

## 与 Sona 的边界

SpeechRail 只保证生成 PCM 的逻辑片段首尾平滑。Sona 的设备原生采样率、PyAudio 缓冲和
CoreAudio overload 修复由 Sona 仓库自己的设计与实施计划负责。两侧可独立测试和回退，联合验收
时再同时检查源 PCM、Sona 队列与 CoreAudio 日志。
