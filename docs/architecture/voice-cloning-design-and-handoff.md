---
title: "SpeechRail 音色克隆（Voice Cloning）架构设计与工程交接方案"
status: active
date: 2026-09-05
---

# SpeechRail 音色克隆（Voice Cloning）架构设计与工程交接方案

## 1. 概述与背景

为配合客户端（Sona「声音工坊 · Voice Studio」）的端到端闭环，SpeechRail 作为独立的本地 ASR/TTS 推理服务，需提供基于参考音频与引导文本的**零样本音色克隆（Zero-Shot Voice Cloning via In-Context Learning）**能力。

客户端已完成：
1. **Sona 前端**：已上线「声音工坊（Voice Studio）」，包含音色资产档案库（Voice Deck）、提词器式大字朗读引导（Teleprompter Script）、麦克风声学校准与动态波形录制、本地回放核验、以及克隆提交与即时测试播放交互（`VoiceStudioModal.tsx`）。
2. **Sona 后端网关**：已在 `http_routes.py` 实现了 `/v1/voices/clone/prompts` 与 `/v1/voices/clone` 的认证代理与降级支持。

本文档明确 SpeechRail 端的落地技术标准、实测事实、接口契约、安全存储规范、三档行为边界与 IPC 改造路径，供 SpeechRail 实施落地与质量验收。

---

## 2. 核心技术原理与多档位行为事实

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

### 2.3 三档体系（Quality / Balanced / Light）能力声明边界

遵循 `AGENTS.md` 核心约束：*“三档只改变权重与量化组合，API、worker 协议保持一致；档位对调用方透明。API 按当前权重声明能力，不伪造不可用功能。”*

| 运行档位 | TTS 变体 (Variant) | 权重规格 | 音色机制 | 克隆支持 (`supports_clone`) |
|---|---|---|---|---|
| **Quality** | `voice_design` | 1.7B-VoiceDesign-8bit | 自然语言 Prompt + ICL 参考音频 | **`True`（原生可用）** |
| **Balanced** | `custom_voice` | 0.6B-CustomVoice-8bit | 9 种固定预设 Speaker ID | **`False`（当前档位不支持）** |
| **Light** | `custom_voice` | 0.6B-CustomVoice-4bit | 9 种固定预设 Speaker ID | **`False`（当前档位不支持）** |

**档位行为规范**：
1. `GET /v1/voices`：每个音色对象中的 `capabilities` 显式声明 `supports_clone: bool`。在 `custom_voice` 变体下，克隆音色的 `available` 字段计算为 `False`。
2. `POST /v1/voices/clone`：在 API 边界前置检查当前 TTS 变体。若非 `voice_design`，稳定返回 `400 voice_cloning_unsupported` Envelope（提示需切换至 `quality` 档位）。
3. `POST /v1/audio/speech` 与 `/v1/realtime`：若客户端尝试在 `custom_voice` 档位下请求克隆音色，`resolve_binding` 抛出明确异常，系统稳定返回 `400 voice_not_available`。

---

## 3. 公共 API 契约与接口规范

所有新增端点纳入 `contracts/openapi.yaml`，遵循统一稳定的错误 Envelope（包含 `request_id`）。

### 3.1 获取精选引导文案：`GET /v1/voices/clone/prompts`

系统提供静态配置的精选文案库（位于 `src/speechrail/assets/clone_prompts.json`）：

- **安全认证**：与 `/v1/voices` 一致，支持可选 `BearerAuth`（本地 loopback 免密直连，非 loopback 校验 API Key）。
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
  - `audio`: 上传录音文件（`UploadFile`，支持 WebM、WAV、MP3、M4A 等，上传大小硬上限 15MB）
  - `ref_text`: 必填字符串，朗读参考文本（1~2000 字符）
  - `name`: 必填字符串，音色显示名称（1~32 字符）
  - `id`: 可选字符串，自定义音色唯一标识。**必须符合正则 `^[a-zA-Z0-9_-]{1,64}$`**，防止路径穿越攻击。
- **服务端处理与防御**：
  1. **档位拦截**：当前 TTS 变体非 `voice_design` 时，立即返回 `400 voice_cloning_unsupported`。
  2. **防穿越白名单**：若提供了 `id`，必须严格通过字符正则校验；未提供时自动生成 `clone_{int(time.time())}_{uuid.uuid4().hex[:6]}`。
  3. **安全转码与 DoS 防御**：
     - 使用 `settings.ffmpeg_path`（或系统 `ffmpeg`）执行转码；
     - 显式设置 `timeout=10`；捕获 `FileNotFoundError` 并在缺失时返回 `500 dependency_missing: ffmpeg is required`；
     - 命令行：`[ffmpeg, "-y", "-i", "pipe:0", "-ac", "1", "-ar", "24000", "-f", "wav", "pipe:1"]`；
     - 限制转码输出 PCM16 字节上限为 `2,160,000` 字节（对应 45.0 秒 24kHz 单声道 16-bit 音频），杜绝解压炸弹。
  4. **时长校验**：解码后时长必须处于 `[2.0s, 45.0s]` 区间；过短返回 `400 audio_too_short`，过长返回 `400 audio_too_long`。
  5. **受控物理落盘**：
     - 写入 `~/.speechrail/voices/{voice_id}.wav`；
     - 校验 `resolved_path.parent == voices_dir`，坚决拦截路径逃逸；
     - 权限设置：目录 `0700`，文件 `0600`。
  6. **元数据持久化**：注册并持久化至 `~/.speechrail/custom_voices.json`。
- **成功响应 (201 Created)**：
返回**完整且符合 OpenAPI `VoiceProfile` 契约的标准对象**（与 `POST /v1/voices` 完全一致，便于客户端解析）：
```json
{
  "id": "clone_1741234567_abc1",
  "name": "我的专属声音",
  "description": "白日依山尽，黄河入海流...",
  "instruction": "",
  "aliases": [],
  "is_default": false,
  "is_system": false,
  "created_at": 1788583200.0,
  "available": true,
  "variant": "voice_design",
  "capabilities": {
    "supports_speaker": false,
    "supports_instruction": false,
    "supports_clone": true
  },
  "mode": "clone",
  "ref_text": "白日依山尽，黄河入海流...",
  "duration_seconds": 8.4
}
```
*注：绝对文件系统物理路径仅由服务端受控持有，严禁通过 API 响应泄露给调用方。*

### 3.3 音色列表与安全删除

- `GET /v1/voices`：
  - 列表中返回克隆音色，带有 `mode: "clone"`, `ref_text`, `duration_seconds`；
  - `capabilities.supports_clone` 在 `quality` 档位为 `true`，在 `balanced/light` 为 `false`；
  - 克隆音色的 `available` 字段根据当前 TTS 变体是否支持克隆动态计算。
- `DELETE /v1/voices/{voice_id}`：
  - 校验 `voice_id` 正则合法性，阻断路径遍历；
  - 删除内存元数据并写回 `custom_voices.json`；
  - 同步安全删除 `~/.speechrail/voices/{voice_id}.wav`（断言路径在受控目录内后执行 `unlink(missing_ok=True)`）。

---

## 4. 核心模块改造技术方案

### 4.1 领域模型与注册表：`src/speechrail/domain/tts.py`

1. **`VoiceCapabilities` 扩充**：
   ```python
   @dataclass(frozen=True, slots=True)
   class VoiceCapabilities:
       variant: str
       supports_speaker: bool
       supports_instruction: bool
       supports_clone: bool = False
   ```
2. **`VoiceProfile` 属性扩展**：
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
3. **`VoiceRegistry` 增强与跨进程热重载**：
   - 目录与持久化：受控存储目录为 `~/.speechrail/voices/`，创建时赋权 `0700`；
   - **跨进程状态同步（解决 Worker 缓存失效）**：
     - 记录 `self._last_loaded_mtime: float = 0.0`；
     - 在 `get_profile(voice)` 时：若当前在 `self._custom_voices` 中未命中，检查 `custom_voices.json` 的 `st_mtime`；若文件修改时间晚于上次加载时间，立即调用 `_load_custom_voices()` 重新刷新内存缓存，杜绝 Worker 进程找不到新克隆音色；
   - 新增 `create_cloned_profile(...)`：
     - 校验 `voice_id` 匹配 `^[a-zA-Z0-9_-]{1,64}$`；
     - 保证目标路径 `path.resolve().parent == self._voices_dir`；
     - 保存标准化 WAV，赋权 `0600`；更新 `self._custom_voices` 并持久化写回 `custom_voices.json`；
   - 升级 `delete_custom_profile(...)`：删除元数据时安全 `unlink` 对应音频文件。

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

       @property
       def capabilities(self) -> VoiceCapabilities:
           return VoiceCapabilities(
               variant=self.variant,
               supports_speaker=self.speaker is not None,
               supports_instruction=self.instruction is not None,
               supports_clone=self.is_clone,
           )
   ```
2. **`resolve_binding(variant: str, voice: str)` 变体分支**：
   - `variant == "voice_design"`：
     - 若 `profile.mode == "clone"`：返回 `VoiceBinding(variant=variant, voice=preset_voice, speaker=None, instruction=None, is_clone=True, ref_audio_path=profile.audio_path, ref_text=profile.ref_text)`；
     - 否则：返回常规 VoiceDesign 指令绑定；
   - `variant == "custom_voice"`：
     - 若 `profile.mode == "clone"`：抛出 `ValueError(f"voice {voice} requires voice_design variant (quality tier); custom_voice variant does not support voice cloning")`；
     - 否则：查找 `_CUSTOM_VOICE_SPEAKERS`。

### 4.3 主进程 IPC 客户端改造：`src/speechrail/backends/qwen3_tts.py`

在 `Qwen3TtsWorker.synthesize(request: SpeechRequest)` 中：
1. 通过 `resolve_binding(self.variant, request.voice)` 解析音色；
2. 若 `binding.is_clone` 为 `True`，将 `ref_audio` 与 `ref_text` 打包入发往 Worker 的 IPC 帧：
   ```python
   frame_payload = {
       "version": PROTOCOL_VERSION,
       "type": "synthesize",
       "request_id": response_id,
       "text": request.text,
       "voice": request.voice,
       "speed": request.speed,
       "language": request.language,
   }
   if binding.is_clone and binding.ref_audio_path:
       frame_payload["ref_audio"] = binding.ref_audio_path
       frame_payload["ref_text"] = binding.ref_text or ""
   await self._transport.send(frame_payload)
   ```

### 4.4 Worker 进程与 ICL 生成：`src/speechrail/backends/qwen3_tts_worker.py`

1. **协议解包 (`_decode_synthesis_request`)**：
   - 支持解析可选字段 `ref_audio: str | None` 与 `ref_text: str | None`；
   - 严格校验 `ref_audio` 路径必须存在于本地受控文件系统，避免注入。
2. **推理引擎生成分支 (`_generate`)**：
   ```python
   if ref_audio and ref_text and Path(ref_audio).is_file():
       from mlx_audio.tts.models.qwen3_tts.qwen3_tts import load_audio
       audio_array = load_audio(ref_audio, sample_rate=self._sample_rate)
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
3. **首尾平滑**：保留既有的 5ms crossfade 逻辑，确保与前后切片拼接平滑无爆音。
4. **日志隐私脱敏**：Worker 日志严格遵循 `AGENTS.md`，**严禁打印 `ref_audio` 绝对路径（含系统用户名）与完整 `ref_text` 内容**，仅打印脱敏后的音色 ID 与音频采样率/长度。

### 4.5 系统路由与序列化：`src/speechrail/http/routes/system.py`

1. **`_voice_entry` 扩充**：
   - 提取并透传 `profile.mode`、`profile.ref_text`、`profile.duration_seconds`；
   - capabilities 包含 `supports_clone`；
   - 若 `profile.mode == "clone"` 且当前变体不是 `voice_design`，标记 `available = False`。
2. **`GET /v1/voices/clone/prompts`**：
   - 从 `src/speechrail/assets/clone_prompts.json` 读取并返回精选文案列表。
3. **`POST /v1/voices/clone`**：
   - 校验当前 TTS 变体是否为 `voice_design`，若否返回 `400 voice_cloning_unsupported`；
   - 校验 `UploadFile`、`ref_text`、`name`、`id`；
   - 执行带 `timeout=10` 的 ffmpeg 转码，限制最大解压 PCM 大小；
   - 校验时长 `[2.0s, 45.0s]`；
   - 调用 `registry.create_cloned_profile(...)` 并返回标准 201 `_voice_entry`。

### 4.6 契约规范更新：`contracts/openapi.yaml`

1. 增加 `/v1/voices/clone/prompts` 与 `/v1/voices/clone` 端点描述；
2. 扩充 `VoiceProfile` 模式：增加 `mode`, `ref_text`, `duration_seconds`；
3. 扩充 `VoiceCapabilities` 模式：增加 `supports_clone`；
4. 新增 `ClonePromptList` 与 `VoiceCloneRequest` 模式定义。

---

## 5. 质量验收门禁（Gate Verification）

实施必须严格使用 **Fake Backend 与 Mock 转码** 进行自动化测试，严禁在测试中联网或下载权重：

```bash
# 1. 契约规范检查
npx @redocly/cli lint contracts/openapi.yaml

# 2. 针对性自动化测试套件
rtk uv run --extra dev pytest tests/test_tts_voice_clone.py -q --no-cov
rtk uv run --extra dev pytest tests/test_tts_voices_api.py -q --no-cov
rtk uv run --extra dev pytest tests/test_qwen3_tts_voice_design.py -q --no-cov
rtk uv run --extra dev pytest tests/test_speech_api.py -q --no-cov

# 3. 全量测试与静态检查
rtk uv run --extra dev pytest
rtk uv run --extra dev ruff check src/ tests/
rtk uv run --extra dev mypy src/
git diff --check
```

---

## 6. 回退方案与风险边界

1. **版本与数据回退**：
   - 用户在 Sona 声音工坊或通过 `DELETE /v1/voices/{voice_id}` 可物理清除录音文件与配置元数据；
   - 删除后自动回退至预设音色（如 `serena`），系统无残留。
2. **隐私隔离**：
   - 物理音频保存在 `~/.speechrail/voices/`，权限严格控制为 `0600`，绝对路径不通过 API 对外暴露；
   - 日志与测试 fixture 严禁包含敏感参考音频、绝对路径与用户真实文本。
3. **档位切换透明性**：
   - 用户若将 SpeechRail 切换为 `balanced` 或 `light` 档位，克隆音色自动置灰（`available=False`），并在调用时稳定返回 `voice_not_available`，切回 `quality` 档位后立即可恢复使用。
