# 三档统一运行时本机可行性基准

状态：本机三档已实测；M1 Air 8GB、12GB 设备与完整质量集发布门仍未完成。

## 结论

2026-09-05 在同一台 Apple M5 Max / 128GB / macOS 26.6.2 主机上，按
`quality → balanced → light → quality` 串行完成受管模型准备、停服切换、公共
ASR/TTS smoke、准确率代理、热态延迟和物理内存采样。三档使用同一 FastAPI、同一共享
vendor runtime、一个物理 ASR worker 和一个 TTS worker，仅权重与量化组合不同。

三档公共 API 均成功。`light` 的三进程最大同时物理占用为 **4484.2 MB**；该结果证明
当前权重组合在本机明显低于 8GB，但不能替代 8GB 设备上的系统内存压力和 Metal 行为验收。
结束时已恢复 `quality`，active selection 为 generation 4。

## 固定组合

| profile | ASR | TTS |
|---|---|---|
| `quality` | Qwen3-ASR 1.7B q8 | Qwen3-TTS 1.7B VoiceDesign q8 |
| `balanced` | Qwen3-ASR 1.7B q8 | Qwen3-TTS 0.6B CustomVoice q8 |
| `light` | Qwen3-ASR 0.6B q8 | Qwen3-TTS 0.6B CustomVoice q8 |

四个实际使用的 q8 snapshot 均按 catalog 的不可变 ModelScope revision、文件大小和
SHA-256 验证后发布。0.6B TTS q4 仍是候选，本轮没有下载或用于正式档位。

## 测量方法

- 公共入口：`POST /v1/audio/transcriptions`、`POST /v1/audio/speech`、
  `/health`、`/readyz`、`/v1/models`、`/v1/voices`。
- ASR 代理语料：macOS `say` 生成的独立中英文语音，各 1 条；中文 28 个归一化字符，
  英文 13 个归一化词。它不是 SpeechRail TTS 自生成输入。
- TTS 可懂度代理：每档生成同一中文句子，再通过当前公共 ASR 回读计算 CER。
- 热态 RTF：`examples/perf/bench_profiles.py`，同一两条 ASR 和一条 TTS fixture。
- 资源：`examples/perf/sample_resources.py`，分别对 batch ASR 和 TTS 预热后运行 3 次，
  使用 macOS `footprint`，只接受完整的同一采样轮总和。
- 原始 JSON、日志和试听 WAV 位于仓库外
  `<user-app-home>/benchmarks/20260905-184852/`，未提交音频、转写或凭据。

## 结果

| profile | 中文 CER | 英文 WER | ASR 热态 RTF（中/英） | TTS 热态 RTF | 最大常驻 | 最大压测峰值 |
|---|---:|---:|---:|---:|---:|---:|
| `quality` | 0% | 0% | 0.0346 / 0.0353 | 0.2676 | 6624.8 MB | 7000.3 MB |
| `balanced` | 0% | 0% | 0.0332 / 0.0330 | 0.2303 | 5561.3 MB | 5877.4 MB |
| `light` | 0% | 7.69% | 0.0249 / 0.0240 | 0.2272 | 4168.0 MB | 4484.2 MB |

每档 TTS→ASR 回读 CER 均为 0。所有 REST 请求返回 200 且包含 request ID；每次档位
切换后的公共 ASR/TTS smoke 均通过。资源采样的 `gate_complete=true`，没有 RSS fallback、
缺样或 PID 重用。

`quality` 的第一条中文 ASR 请求为 1.027 秒，第二次为 0.169 秒，体现首次加载成本；
后续档位在切换 smoke 中已加载 worker，因此本轮没有形成可比较的逐档纯冷启动数据。

## 实施中发现并修复的问题

真实安装和切换暴露了以下 fake 测试未覆盖的缺陷，均已加入回归：

1. `uv venv` 的标准外部解释器链接被误判为 release 逃逸（`c3fb306`）。
2. runtime 强制使用 macOS 13 解析目标，无法匹配 MLX 0.32.2 wheel（`97dc91e`）。
3. `uv pip sync` 错误使用 `-r` 参数（`30af091`）。
4. 受管 selection 没有覆盖共享 Python/ffmpeg，且源码 profile CLI 用错 diarization
   preflight Python；`launchctl bootout` 后立即 `bootstrap` 还存在 exit-5 竞态
   （`5e29b72`、`4f30605`、`5b081b3`）。
5. 公共健康状态固定报告 1.7B，voice 目录不区分 VoiceDesign/CustomVoice。`339fdb2`
   改为从同一次启动 selection 发布实际档位、artifact、variant、量化和 voice capabilities。

修复后完整测试为 983 passed，覆盖率 83.09%；Ruff、Mypy、OpenAPI lint、LaunchAgent
plist lint 和 `git diff --check` 均通过。

## 尚未完成的发布证据

- M1 Air 8GB 与 12GB Apple Silicon 的实际峰值、内存压力和系统响应。
- 240 段独立真人 ASR 集、60 条 TTS 人工审听、四个公共 voice 的盲听质量门。
- 每档可比较的 cold、长时间 soak、streaming ASR 和客户端矩阵。
- 干净用户目录首次双击安装、签名/公证和断网恢复。

因此本报告放行本机三档开发与受管切换，不把 `light` 标记为已通过 M1 Air 8GB 发布门。
