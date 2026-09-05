# Contributing to SpeechRail 🎙️

感谢你关注并有意愿为 **SpeechRail** 做出贡献！  
SpeechRail 是一个面向本机应用的独立、高性能、隐私优先、OpenAI 契约兼容的语音识别 (ASR) 与合成 (TTS) 运行时服务。

为了保证项目的工程质量、稳定性与优雅的协作体验，请在提交代码或 Issue 前仔细阅读本指南。

---

## 🧭 核心设计原则

在提出新功能或提交改动前，请参考以下设计原则：

1. **本地优先与绝对隐私 (Local-First & Offline)**：
   - 绝不引入向外部云端的静默请求或数据外呼；
   - 模型权重严格使用本地外部快照，运行期间严禁自动联网下载模型；
   - 用户音频与转写文本仅在内存中按需流转，不持久化保存源音频。
2. **OpenAI 协议兼容 (API Conformance)**：
   - 对外公开的 REST API 与 Realtime WebSocket 协议必须 100% 保持与 OpenAI 官方契约一致；
   - 不向外部公开协议中注入私有专有字段，保持对标准 OpenAI SDK（Python, Node.js 等）及生态应用（QwenPaw、Sona）的无缝兼容。
3. **单机单人与低开销 (Zero Bloat & High Efficiency)**：
   - 优先通过进程隔离、显存池治理、零拷贝 IPC 与轻量状态机解决单机并发保护；
   - 避免为单人本机场景引入过度设计的分布式组件或复杂的平台化基础设施。

---

## 🛠️ 本地开发环境准备

SpeechRail 采用现代 Python 工具链 **`uv`** 进行依赖管理，支持 **Python `>=3.12,<3.13`**。

### 1. 安装基础工具
确保本机已安装：
* macOS (推荐 Apple Silicon M 系列芯片)
* `git`
* `ffmpeg` (`brew install ffmpeg`)
* `uv` (`curl -LsSf https://astral.sh/uv/install.sh | sh` 或 `brew install uv`)

### 2. 克隆仓库与依赖同步
```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail

# 同步安装开发与测试环境依赖
uv sync --extra dev
```

### 3. 配置本地开发环境
复制配置模板：
```bash
cp configs/speechrail.example.env .env
chmod 600 .env
```
> ⚠️ **安全注意**：`.env` 中可能包含你的本地路径，已被 `.gitignore` 忽略。请切勿将包含私有路径或凭据的 `.env` 提交到公开分支。

---

## 🧪 自动化测试与质量门禁

SpeechRail 对代码质量、类型安全与测试覆盖率有严格的自动化门禁要求。提交 PR 前请确保以下命令全部通过：

### 1. 运行全量单元与契约测试
```bash
uv run --extra dev pytest -q --no-cov
```

### 2. 测试覆盖率检查 (门禁要求 >= 80.0%)
```bash
uv run --extra dev pytest --cov=src
```

### 3. 代码规范与 Lint 检查
```bash
uv run --extra dev ruff check src tests
```

### 4. 严格静态类型检查
```bash
uv run --extra dev mypy src
```

---

## 📝 提交信息规范 (Git Commit Guidelines)

我们遵循 [Conventional Commits](https://www.conventionalcommits.org/) 规范，请使用清晰、结构化的提交信息：

```text
<type>(<scope>): <subject>

<body>
```

* **`feat`**: 新增功能（如新模型别名支持、新协议事件适配）
* **`fix`**: 修复缺陷（如类型错误、进程通信异常、边界条件错误）
* **`perf`**: 性能优化（如内存降低、IPC 吞吐提升、解码延迟降低）
* **`docs`**: 文档编写与更新
* **`refactor`**: 代码重构（不改变功能与外部契约）
* **`test`**: 补充或修复自动化测试
* **`chore`**: 工具链、构建系统或元数据调整

**示例**：
```bash
git commit -m "perf(audio): add fast-path decoding for 16kHz mono WAV"
```

---

## 🚀 Pull Request (PR) 提交流程

1. **Fork** 本仓库并创建特性分支：
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. 编写代码，并为新功能或 Bugfix **补充单元测试**；
3. 执行全量测试与 Lint：`pytest`, `ruff check`, `mypy src`；
4. 提交修改并推送到你的 Fork 仓库；
5. 创建 Pull Request，根据 PR 模板填写修改背景、影响范围与测试验证证据；
6. 维护者将对 PR 进行 Review，并在 CI 通过后合并。

感谢你为开源语音生态做出的贡献！🎉
