# SpeechRail 自传视频：面向开发者与创作者的社媒文案

> 目标受众：想把本机语音能力接进创作流程的开发者、独立创作者和本地 AI 爱好者。
>
> 核心信息：SpeechRail 不只生成一段声音；这个示例把本机 TTS 接入旁白、BGM、字幕、混音、频谱分析和视频渲染，展示从 API 请求到成片的一条完整流水线。
>
> 事实边界：以下文案只使用当前仓库代码、API 契约和本示例流水线能够支持的内容。“90 秒”是脚本设定的时间线，不是对所有重新生成结果的永久承诺；重新运行或更换环境后，应重新核对成片。

## 发布时可使用的事实

- `01_generate_voiceover.py` 向本机 `http://127.0.0.1:8201/v1/audio/speech` 请求 14 段正式旁白和 6 段音色展示音频。
- `02_generate_bgm.py` 生成 90 秒 BGM；`03_process_audio_and_mix.py` 负责变速、时间轴、SRT、ducking 和母带混音。
- `04_analyze_waveform.py` 提取 64-band 频谱；`05_render_video.py` 按 30 fps、1920×1080 的参数渲染视频。
- SpeechRail 对外提供的是 OpenAI-compatible subset，不是逐字段的完整 OpenAI API 克隆。音色是否可用，以当前服务的 `GET /v1/voices` 为准。

---

## 1. Bilibili（B 站）投稿文案

### 推荐标题

**一条 90 秒视频是怎么做出来的？SpeechRail 本机 TTS 流水线实录**

### 备选标题

- **把本机 TTS 接进视频制作：SpeechRail 从旁白到成片**
- **从一次 API 请求到一条视频：SpeechRail 旁白、混音与渲染示例**

### 简介正文

```markdown
如果你也想把本机语音能力真正接进创作流程，这个示例可以从头看到一条视频是怎样被组装出来的。

它不是只展示一段合成音，而是从本机 SpeechRail 的 `POST /v1/audio/speech` 开始，继续完成：
- 14 段正式旁白和 6 段音色展示音频；
- BGM 生成、旁白变速和时间轴编排；
- SRT 字幕、ducking 混音和母带处理；
- 64-band 频谱提取；
- 30 fps、1920×1080 视频渲染。

你可以把它当作一个可阅读、可运行的本地语音视频工作流示例：
先看 API 如何生成声音，再看音频怎样进入字幕、混音、可视化和最终视频。

SpeechRail 默认绑定 `127.0.0.1:8201`，提供有边界的 OpenAI-compatible ASR/TTS 接口子集。
它不是逐字段复制完整的 OpenAI API，具体支持的路径、参数和格式请以仓库契约为准。

项目当前注册了 9 个 canonical voice IDs：
`serena`、`vivian`、`uncle_fu`、`dylan`、`eric`、`ryan`、`aiden`、`ono_anna`、`sohee`。
实际可用音色仍请以运行中的 `GET /v1/voices` 返回值为准。

想复现这条流水线？运行方式和前置依赖见：
`examples/autobiography-video/README.md`

项目地址：https://github.com/hrygo/SpeechRail
```

### 评论区置顶文案

```markdown
📌 想运行示例，先确认这 3 件事：

1. SpeechRail 已启动并监听默认地址；
2. TTS 所需 voice 在 `/v1/voices` 中返回 `available=true`；
3. 本机已安装 `uv` 和 `ffmpeg`。

运行：

cd examples/autobiography-video
make all

常见问题：

Q：这个示例适合谁？
A：适合想了解本机 TTS 如何进入真实音视频工作流的开发者、创作者和本地 AI 爱好者。

Q：是否支持任意 Mac 和任意配置？
A：项目面向 macOS Apple Silicon；实际可用性取决于 macOS、内存、模型文件、运行档位和依赖。
请以本机 `/health`、`/readyz` 和 `/v1/voices` 的结果为准。

Q：默认需要 API key 吗？
A：默认 loopback 配置可以不设置 API key；如果暴露到非 loopback 地址，必须配置 `SPEECHRAIL_API_KEY` 并使用 Bearer 鉴权。

Q：是不是完整兼容 OpenAI？
A：不是逐字段完整克隆，而是有明确边界的 OpenAI-compatible ASR/TTS 子集；请按仓库契约接入。

Q：为什么文案里列出的音色不一定都能用？
A：仓库注册的 voice ID 和当前运行环境的可用性是两件事，最终以 `GET /v1/voices` 返回的 `available` 状态为准。
```

---

## 2. 微信视频号文案

> **#开源 #本地AI #macOS #语音技术**  \
> 想看本机 TTS 怎么进入一条真正的视频制作流程？SpeechRail 先生成旁白，再把声音接到 BGM、时间轴、SRT 字幕、ducking 混音、64-band 频谱和视频渲染，串起一条从 API 到成片的示例流水线。
>
> 服务默认使用 `127.0.0.1:8201`，对外提供有边界的 OpenAI-compatible ASR/TTS 接口子集；具体支持范围以当前契约和运行状态为准。
>
> 仓库当前注册 9 个 canonical voice IDs，但实际可用音色请以运行中的 `/v1/voices` 返回结果为准。示例运行方式和前置依赖见仓库内 `examples/autobiography-video/README.md`。
>
> 开源地址：<https://github.com/hrygo/SpeechRail>

---

## 3. 小红书文案

### 封面标题建议

- **主标题**：把一句旁白做成一条视频
- **副标题**：本机 TTS → 字幕 / 混音 → 频谱 → 成片

### 笔记正文

```text
本机语音服务，除了“合成一句话”，还能怎么进入创作流程？🎙️💻

这次用 SpeechRail 做了一个自传视频示例：
从本机 TTS 生成旁白开始，一路接上 BGM、字幕、混音、频谱和视频渲染。

整条流水线大致是：
1️⃣ 通过本机 `127.0.0.1:8201/v1/audio/speech` 生成 14 段正式旁白和 6 段音色展示；
2️⃣ 生成 BGM，编排旁白时间轴并导出 SRT 字幕；
3️⃣ 对旁白和 BGM 做 ducking 混音，再提取 64-band 频谱；
4️⃣ 按 30 fps、1920×1080 参数渲染视频。

重点不是“某个声音有多神奇”，而是把本机语音能力放进一条可观察、可拆解的视频工作流：
API 生成的声音，最后真的会变成字幕、波形和画面的一部分。

SpeechRail 提供的是有边界的 OpenAI-compatible ASR/TTS 服务子集，不是逐字段完整复制 OpenAI API。
项目当前注册 9 个 canonical voice IDs，实际可用性请以运行中的 `/v1/voices` 为准。

想复现的话，运行方法和前置依赖见：
`examples/autobiography-video/README.md`

项目地址：github.com/hrygo/SpeechRail

#开源软件 #macOS #本地AI #语音合成 #视频制作 #开发者工具
```

---

## 4. 抖音 / 快手短视频文案

### 前 3 秒 Hook

- **画面**：终端窗口、本机服务地址和音频波形快速切换。
- **口播**：`一条 90 秒视频，能不能从一次本机 TTS 请求开始做出来？`

### 视频配文

> 从本机 `POST /v1/audio/speech` 生成旁白，接着完成 BGM、时间轴、SRT 字幕、ducking 混音、64-band 频谱和视频渲染，把一次 API 请求串成一条 90 秒示例流水线。SpeechRail 默认绑定 `127.0.0.1:8201`，对外提供有边界的 OpenAI-compatible ASR/TTS 接口子集；具体能力以当前契约和运行状态为准。  \
> 想复现这条流程，运行方式见仓库内 `examples/autobiography-video/README.md`。  \
> #程序员 #AI工具 #macOS #开源软件 #语音合成

---

## 发布前核验与表达边界

| 要发布的内容 | 当前依据 | 发布前动作 |
| --- | --- | --- |
| 旁白、音色展示和视频处理步骤 | `01`–`05` 脚本 | 重新运行后确认实际产物和时间线 |
| 视频时长、分辨率、帧率 | `DURATION=90.0`、`FPS=30`、`WIDTH=1920`、`HEIGHT=1080` | 用 `ffprobe` 检查最终文件 |
| TTS endpoint、输入限制和格式 | `contracts/openapi.yaml` | 以当前契约和实际服务响应为准 |
| voice ID 和可用性 | `src/speechrail/domain/tts.py`、`GET /v1/voices` | 不要把未返回 `available=true` 的音色写成可用 |
| 默认地址和鉴权边界 | `src/speechrail/config/__init__.py`、运行配置 | 非 loopback 部署时确认 `SPEECHRAIL_API_KEY` |

发布前不要把示例写成以下未经证实的承诺：

- “支持任意 Mac”或“任何配置都能运行”；
- “完整兼容 OpenAI”或“所有 OpenAI 参数都可用”；
- “所有音色随时可用”；
- “固定每次都生成 90 秒成片”；
- “零延迟”“专业级音质”等没有单独测量依据的结论。

这份文案的重点是让受众先看懂价值，再决定是否阅读代码；具体能力、可用性和最终产物，始终以当前契约、运行状态和发布前实测为准。
