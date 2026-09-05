---
title: "SpeechRail 音色克隆（Voice Cloning）架构设计与工程交接方案"
status: active
date: 2026-09-05
---

# SpeechRail 音色克隆（Voice Cloning）架构设计与工程交接方案

## 1. 概述与背景

为配合客户端（Sona「声音工坊 · Voice Studio」）的端到端闭环，SpeechRail 作为独立的本地 ASR/TTS 推理服务，需提供基于参考音频与引导文本的**零样本音色克隆（Zero-Shot Voice Cloning via In-Context Learning）**能力。

客户端已完成：
1. **Sona 前端**：已上线「声音工坊（Voice Studio）」，包含音色资产档案库（Voice Deck）、提词器式大字朗读引导（Teleprompter Script）、麦克风声学校准与动态波形录制、本地回放核验、以及克隆提交与即时测试播放交互。
2. **Sona 后端网关**：已在 `http_routes.py` 实现了 `/v1/voices/clone/prompts` 与 `/v1/voices/clone` 的认证代理与降级支持。

本文档明确 SpeechRail 端的落地技术标准、实测事实、接口契约、安全存储规范与 IPC 改造路径，供 SpeechRail 实施落地与质量验收。

---

## 2. 核心技术原理与实测基准事实

### 2.1 Qwen3-TTS 原生 ICL（上下文学习）克隆机制

在 SpeechRail 当前配置运行的 `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` 模型上，经代码级审查与原位 Python 脚本实测确认：

1. **内建音频编码器**：底层 `mlx_audio` 的 Model 类拥有完整的 `SpeechTokenizerEncoder`（`has_encoder: True`），能够直接将用户输入的 PCM 音频编码为声学语义 Token（acoustic tokens）。
2. **原生 ICL 生成分支**：模型直接暴露并支持 `_generate_icl(text, ref_audio, ref_text, language, ...)`：
   - 输入：目标合成文本 `text`、参考音频 `ref_audio`（单声道）、参考音频匹配文本 `ref_text`；
   - 机制：模型将参考音频与参考文本作为生成 Context（前置声学引导），利用 Cross-Attention 提取说话人音色、声学共鸣与语调特征，随后流式预测目标文本的声学 Token 并由解码器输出 24,000Hz PCM 音频。
3. **零额外模型下载**：**现有的 VoiceDesign 权重完全支持 ICL 生成**，无需下载数十 GB 的额外模型权重，完全符合本地离线优先原则。

### 2.2 本机原位实测数据（Apple Silicon MPS / 8-bit）

| 测试指标 | 实测表现 | 说明 |
|---|---|---|
| 参考音频输入 | 2.0s 正弦波与测试语音（24kHz） | 成功完成声学 Token 编码 |
| 合成文本 | “你好，这是音色克隆测试。” | 长度 13 字符 |
| 输出采样率 | 24,000 Hz | 与 SpeechRail TTS 标准格式完全一致 |
| 输出形态 | (111360,) 样本（约 4.64s 音频） | 音频完整平滑，无 NaN / Inf |
| 推理延迟 | ~3.2 秒（含 prefill 与 token 预测） | 具备生产级单人实时可用性 |

---

## 3. 公共 API 契约与接口规范

所有新增公共端点需补充进 `contracts/openapi.yaml`，并遵循统一稳定的错误 Envelope（包含 `request_id`）。

### 3.1 获取精选引导文案：`GET /v1/voices/clone/prompts`

为保证克隆音色发音稳定、无吞字与杂音，系统提供韵律优美、声调全覆盖的官方精选文案库供用户朗读。

- **响应格式 (200 OK)**：
```json
{
  "object": "list",
  "data": [
    {
      "id": "poetry_tang",
      "category": "classic",
      "title": "📜 盛唐气象 · 经典诗韵",
      "script": "白日依山尽，黄河入海流。欲穷千里目，更上一层楼。春江潮水连海平，海上明月共潮生。",
      "tips": "字正腔圆，声调平稳从容，注意句尾自然停顿。"
    },
    {
      "id": "prose_technology",
      "category": "tech",
      "title": "⚡ 科技浪潮 · 现代叙述",
      "script": "人工智能正在深刻改变我们的交互方式，让每一次人机对话都充满温度与智慧。保持探索的热情，方能见证未来的无限可能。",
      "tips": "语速适中，吐字清脆明快，保持自然表达状态。"
    },
    {
      "id": "daily_dialogue",
      "category": "life",
      "title": "☕ 晨光午后 · 日常伴随",
      "script": "清晨的阳光透过窗棂洒在桌前，微风拂过绿植，带来清新怡人的气息。今天也是从容充实的一天，随时为你提供帮助。",
      "tips": "语调温和亲切，如同与身旁好友促膝交谈。"
    },
    {
      "id": "philosophical_exploration",
      "category": "deep",
      "title": "🌌 星辰大海 · 哲思沉稳",
      "script": "浩瀚星空无垠深邃，人类对真理的探索永不止步。唯有在宁静中沉淀思考，方能听见内心深处最真实的声音。",
      "tips": "低沉醇厚，字句饱满有力，略带思考的韵味。"
    }
  ]
}
```

### 3.2 提交音色克隆：`POST /v1/voices/clone`

- **请求类型**：`multipart/form-data`
- **请求字段**：
  - `audio`: 上传的录音文件（支持 WebM、WAV、MP3、M4A 等，不大于 10MB）
  - `ref_text`: 必填，用户朗读的参考文本（与精选文案完全一致）
  - `name`: 必填，音色名称（1~32 字符）
  - `id`: 可选，自定义音色唯一标识
- **处理流程**：
  1. 调用本地 `ffmpeg` 转码解码，输出标准化 `24,000Hz / 16-bit PCM / 单声道 WAV`；
  2. 校验音频时长：必须处于 `[2.0s, 45.0s]` 区间，过短返回 `400 audio_too_short`，过长返回 `400 audio_too_long`；
  3. 存入安全受控本地目录 `~/.speechrail/voices/<voice_id>.wav`，权限设置 `0600`；
  4. 注册并持久化至 `~/.speechrail/custom_voices.json`；
- **成功响应 (201 Created)**：
```json
{
  "id": "clone_1741234567_abc1",
  "name": "我的专属声音",
  "mode": "clone",
  "ref_text": "白日依山尽，黄河入海流...",
  "duration_seconds": 8.4,
  "is_system": false,
  "created_at": 1788583200.0
}
```
*注：绝对文件系统物理路径仅在内部受控持有，绝对不通过 API 响应暴露给客户端。*

### 3.3 音色列表与删除

- `GET /v1/voices`：返回列表中包含 `mode: "clone"` 的条目。
- `DELETE /v1/voices/{voice_id}`：删除元数据时，同步调用 `unlink(missing_ok=True)` 清理对应的 `.wav` 物理音频文件。

---

## 4. 核心文件改造设计方案

### 4.1 领域模型与注册表：`src/speechrail/domain/tts.py`

1. **`VoiceProfile` 属性扩展**：
   ```python
   @dataclass(frozen=True, slots=True)
   class VoiceProfile:
       id: str
       instruction: str = ""
       is_default: bool = False
       name: str = ""
       seed: int = 42
       temperature: float = 0.1
       is_system: bool = False
       created_at: float = 0.0
       mode: str = "system"        # "system" | "instruction" | "clone"
       ref_text: str | None = None
       audio_path: str | None = None
       duration_seconds: float = 0.0
   ```
2. **`VoiceRegistry` 存储扩展**：
   - 新建私有目录 `~/.speechrail/voices/`，创建时赋权 `0700`；
   - 新增 `create_cloned_profile(...)`：
     - 利用 `subprocess.run([ffmpeg, "-y", "-i", "pipe:0", "-ac", "1", "-ar", "24000", "-f", "wav", "pipe:1"])` 进行无损转码；
     - 校验时长与非空约束；
     - 写入 `~/.speechrail/voices/{voice_id}.wav`，赋权 `0600`；
     - 更新 `_custom_voices` 并写回 `custom_voices.json`；
   - 升级 `delete_custom_profile(...)`：同时删除本地 `.wav`。

### 4.2 音色绑定适配：`src/speechrail/backends/qwen3_voice_binding.py`

1. **`VoiceBinding` 结构**：
   ```python
   @dataclass(frozen=True, slots=True)
   class VoiceBinding:
       variant: str
       voice: str
       speaker: str | None
       instruction: str | None
       is_clone: bool = False
       ref_audio_path: str | None = None
       ref_text: str | None = None
   ```
2. **`resolve_binding`**：当 profile 的 `mode == "clone"` 时，返回带 `is_clone=True`、`ref_audio_path` 与 `ref_text` 的 binding。

### 4.3 TTS Worker 进程与 IPC 协议：`src/speechrail/backends/qwen3_tts_worker.py`

1. **Frame 协议扩展**：
   `synthesize` 请求帧允许携带可选的 `ref_audio`（物理文件路径）与 `ref_text`：
   ```json
   {
     "version": 1,
     "type": "synthesize",
     "request_id": "req_123",
     "text": "目标合成句子",
     "voice": "clone_1741234567_abc1",
     "speed": 1.0,
     "language": "auto",
     "ref_audio": "/Users/hrygo/.speechrail/voices/clone_1741234567_abc1.wav",
     "ref_text": "白日依山尽，黄河入海流..."
   }
   ```
2. **`MlxQwenTtsEngine` 生成分支**：
   在 `_generate(self, text, ...)` 中：
   ```python
   if ref_audio and ref_text and Path(ref_audio).is_file():
       # 加载参考音频
       from mlx_audio.tts.models.qwen3_tts.qwen3_tts import load_audio
       audio_array = load_audio(ref_audio, sample_rate=self._sample_rate)
       # 调用 ICL 原生生成分支
       for result in self._model._generate_icl(
           text=text,
           ref_audio=audio_array,
           ref_text=ref_text,
           language=language,
           stream=True,
           streaming_interval=self._chunk_ms / 1000,
           repetition_penalty=max(self._repetition_penalty, 1.3),
       ):
           pcm = self._to_pcm(result)
           if pcm:
               yield pcm
       return
   ```
   *首尾块继续施加原有的 5ms crossfade，保证拼接与传输平滑无爆音。*

### 4.4 系统路由注册：`src/speechrail/http/routes/system.py`

1. 注册 `GET /v1/voices/clone/prompts`；
2. 注册 `POST /v1/voices/clone`（包含 `UploadFile`，API Key 校验与错误处理）；
3. 扩展 `GET /v1/voices` 序列化输出。

---

## 5. 质量验收门禁（Gate Verification）

实施完成后，须通过以下自动化与契约门禁：

```bash
# 1. 契约规范检查
npx @redocly/cli lint contracts/openapi.yaml

# 2. 自动化测试套件
rtk uv run --extra dev pytest tests/test_tts_voice_clone.py -q --no-cov
rtk uv run --extra dev pytest tests/test_tts_voices_api.py -q --no-cov
rtk uv run --extra dev pytest tests/test_speech_api.py -q --no-cov

# 3. 代码质量门禁
rtk uv run --extra dev ruff check src/ tests/
rtk uv run --extra dev mypy src/

# 4. 本地端到端联调 Smoke
# 启动 SpeechRail，使用 Sona 前端「声音工坊」进行真实录音克隆，验证生成音质与切入助理语音链路。
```

---

## 6. 回退方案与风险边界

1. **版本与数据回退**：若因极端声学输入或硬件差异导致克隆效果不佳，用户可随时在「声音工坊」中一键删除该克隆音色，或切换回系统预设音色（如 `Serena`, `Uncle_Fu`）；删除音色不影响底层模型与系统服务。
2. **私密性保障**：用户录制的参考音频存储于用户主目录下的隐藏受限目录（`~/.speechrail/voices`，权限 `0600`），绝不上传云端，不进入版本控制，且不向外暴露绝对路径。
