# SpeechRail 自传视频：事实版社交媒体文案

> 这份文案只使用当前仓库代码、API 契约和本示例流水线能够支持的内容。
> “90 秒”是脚本设定的时间线，不是对所有重新生成结果的永久承诺；重新运行或更换环境后，应重新核对成片。
>
> - `01_generate_voiceover.py` 向本机 `http://127.0.0.1:8201/v1/audio/speech` 请求 14 段正式旁白和 6 段音色展示音频。
> - `02_generate_bgm.py` 生成 90 秒 BGM；`03_process_audio_and_mix.py` 负责变速、时间轴、SRT、ducking 和母带混音。
> - `04_analyze_waveform.py` 提取 64-band 频谱；`05_render_video.py` 按 30 fps、1920×1080 的参数渲染视频。
> - SpeechRail 对外提供的是 OpenAI-compatible subset，不是逐字段的完整 OpenAI API 克隆。音色是否可用以当前服务的 `GET /v1/voices` 为准。

---

## 1. Bilibili（B 站）投稿文案

### 候选标题

- **选项 A**：SpeechRail 自传视频示例：从本机 TTS 到 90 秒成片
- **选项 B**：用本机语音服务制作一条视频：SpeechRail 流水线实录
- **选项 C**：SpeechRail 示例：旁白、混音、频谱和视频渲染如何串起来

### 简介正文

```markdown
这是 SpeechRail 的一个视频制作示例。

流水线先通过本机 SpeechRail 的 `POST /v1/audio/speech` 生成旁白，再依次完成：
- 14 段正式旁白和 6 段音色展示音频；
- 90 秒 BGM 合成；
- 旁白变速、时间轴编排、SRT 字幕和 ducking 混音；
- 64-band 频谱提取；
- 30 fps、1920×1080 视频渲染。

SpeechRail 默认绑定 `127.0.0.1:8201`。它提供 OpenAI-compatible 的 ASR/TTS 接口子集，
具体支持的路径、参数和格式以仓库契约为准；这不等同于逐字段复制完整的 OpenAI API。

当前仓库注册了 9 个 canonical voice IDs：
`serena`、`vivian`、`uncle_fu`、`dylan`、`eric`、`ryan`、`aiden`、`ono_anna`、`sohee`。
实际可用性仍应以运行中的 `GET /v1/voices` 返回值为准。

本示例的 TTS HTTP 请求目标是本机 loopback 地址；如果把服务暴露到非 loopback 地址，
需要配置 `SPEECHRAIL_API_KEY` 并使用 Bearer 鉴权。

项目地址：https://github.com/hrygo/SpeechRail
```

### 评论区置顶文案

```markdown
📌 运行前请先确认：SpeechRail 已启动并监听默认地址，TTS 所需 voice 在 `/v1/voices` 中为 `available=true`，
同时已安装 `uv` 和 `ffmpeg`。

Q1：示例怎么运行？
A：在 SpeechRail 仓库根目录执行：
cd examples/autobiography-video
make all

Q2：是否支持任意 Mac 和任意配置？
A：项目面向 macOS Apple Silicon；实际可用性取决于当前 macOS、内存、模型文件、运行档位和依赖，
请以本机 `/health`、`/readyz` 和 `/v1/voices` 的结果为准。

Q3：是不是所有请求都免密？
A：默认 loopback 配置可以不设置 API key；非 loopback 暴露必须配置 `SPEECHRAIL_API_KEY` 并鉴权。

Q4：是不是完整兼容 OpenAI？
A：不是逐字段完整克隆，而是有明确边界的 OpenAI-compatible ASR/TTS 子集；请按契约接入。
```

---

## 2. 微信视频号文案

> **#AI #开源 #macOS #语音技术**  \
> SpeechRail 自传视频示例：把本机 TTS 接入一条完整的视频流水线。
>
> 这个示例从本机 `POST /v1/audio/speech` 生成旁白，随后完成 90 秒 BGM、时间轴、字幕、ducking、频谱分析和视频渲染。
> 服务默认使用 `127.0.0.1:8201`；API 是有边界的 OpenAI-compatible ASR/TTS 子集，具体能力以当前契约和运行状态为准。
>
> 示例代码注册并展示 9 个 canonical voice IDs，但实际可用音色请以 `/v1/voices` 返回结果为准。
> 本示例的 TTS 请求指向本机 loopback；非 loopback 部署需要 `SPEECHRAIL_API_KEY`。
>
> 开源地址：github.com/hrygo/SpeechRail

---

## 3. 小红书文案

### 封面标题建议

- **主标题**：用本机 TTS 做一条 90 秒视频
- **副标题**：SpeechRail · 旁白 · 混音 · 频谱 · 渲染

### 笔记正文

```text
这是 SpeechRail 的一个本地语音视频示例。🎙️💻

示例流水线分成几步：
1️⃣ 通过本机 `127.0.0.1:8201/v1/audio/speech` 生成 14 段正式旁白和 6 段音色展示；
2️⃣ 生成 90 秒 BGM，编排旁白时间轴并导出 SRT；
3️⃣ 对旁白和 BGM 做 ducking 混音，再提取 64-band 频谱；
4️⃣ 按 30 fps、1920×1080 参数渲染视频。

SpeechRail 对外是有边界的 OpenAI-compatible ASR/TTS 服务，不是逐字段完整复制 OpenAI API。
项目当前注册 9 个 canonical voice IDs，实际可用性以 `/v1/voices` 为准。

默认服务绑定本机 loopback；如果改为非 loopback 暴露，需要配置 `SPEECHRAIL_API_KEY`。
运行方法和前置依赖见仓库内 `examples/autobiography-video/README.md`。

项目地址：github.com/hrygo/SpeechRail

#开源软件 #macOS #本地AI #语音合成 #视频制作 #开发者工具
```

---

## 4. 抖音 / 快手短视频文案

### 前 3 秒 Hook

- **画面**：终端窗口、本机服务地址和音频波形依次出现。
- **声音**：`这是 SpeechRail 的本地 TTS 视频示例：从一段 API 请求，到一条 90 秒时间线。`

### 视频配文

> 从本机 `POST /v1/audio/speech` 生成旁白，经过 BGM、时间轴、SRT、ducking、64-band 频谱和视频渲染，
> 完成一条 90 秒示例流水线。SpeechRail 默认绑定 `127.0.0.1:8201`，对外提供有边界的 OpenAI-compatible ASR/TTS 子集。  \
> #程序员 #AI工具 #macOS #开源软件 #语音合成

---

## 事实边界与发布前核验

| 要发布的内容 | 当前依据 | 发布前动作 |
| --- | --- | --- |
| 旁白、音色展示和视频处理步骤 | `01`–`05` 脚本 | 重新运行后确认实际产物和时间线 |
| 视频时长、分辨率、帧率 | `DURATION=90.0`、`FPS=30`、`WIDTH=1920`、`HEIGHT=1080` | 用 `ffprobe` 检查最终文件 |
| TTS endpoint、输入限制和格式 | `contracts/openapi.yaml` | 以当前契约和实际服务响应为准 |
| voice ID 和可用性 | `src/speechrail/domain/tts.py`、`GET /v1/voices` | 不要把未返回 `available=true` 的音色写成可用 |
| 默认地址和鉴权边界 | `src/speechrail/config/__init__.py`、运行配置 | 非 loopback 部署时确认 `SPEECHRAIL_API_KEY` |

发布前还应删除没有单独证据支持的受众判断、范围扩大表述、绝对承诺和主观质量结论。
