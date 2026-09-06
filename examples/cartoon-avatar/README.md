# 卡通数字人示例

这是一个独立的本地浏览器示例：选择一个原创卡通角色和 SpeechRail 当前可用的 TTS 音色，输入文字后由角色完成播报。示例进程只做代理和静态资源服务，不加载模型，也不会替换、重启或停止 SpeechRail。

## 前置条件

- Python `>=3.12,<3.13` 和 `uv`。
- 已运行并且存在可用 TTS 音色的 SpeechRail，默认地址为 `http://127.0.0.1:8201/v1`。
- 支持 Web Audio API 的浏览器。
- Node.js 22+ 只用于运行示例的 JavaScript 测试，示例运行本身不依赖 Node，也不下载前端资源。

## 启动

以下命令从仓库根目录执行。首次同步依赖可能联网；启动后的示例只访问本机 SpeechRail。

```bash
uv sync --extra dev
uv run python examples/cartoon-avatar/server.py
```

浏览器打开 <http://127.0.0.1:8202>。需要更换示例端口时：

```bash
uv run python examples/cartoon-avatar/server.py --port 8203
```

示例只绑定 `127.0.0.1`，并拒绝与上游解析端口相同的端口。默认上游由 `SPEECHRAIL_BASE_URL` 覆盖；它必须仍是 `/v1` 下的 HTTP loopback 地址。如果既有 SpeechRail 部署启用了鉴权，在启动示例进程前以现有安全方式提供 `SPEECHRAIL_API_KEY`；不要把真实 key 写进命令历史、文件或浏览器。

## 使用和接口

- 页面启动时只请求 `GET /api/voices`，不会发声或请求麦克风。只有上游返回 `available=true` 的音色会进入选择框；角色预设会优先绑定自己的期望 voice ID。
- 页面向 `POST /api/speech` 发送 `{ "input": "…", "voice": "…" }`；代理固定转发模型 `speechrail/qwen3-tts` 和 `response_format: "wav"`。
- 页面提供 3 个原创内联 SVG 角色预设：角色会同步改变配色、发型、服装和装饰，并显示当前绑定的期望 voice ID。绑定音色不可用时会明确提示，必须手动选择替代音色，不会静默换声。
- 人物预置 `idle`、`welcome`、`thinking`、`speaking`、`smile`、`emphasis` 和 `settle` 动作：进入页面欢迎、切换角色微笑、生成等待时思考，播放时随音量轻微重心/倾身，音量峰值触发短促强调，结束后自然回落。
- 输入限制为 1–600 个 Unicode 码点，音色 ID 限制为 1–200 个字符。代理拒绝额外字段、非 JSON、超过 8 KiB 的请求体和不匹配的本地 `Host`/`Origin`。
- 每次提交会保留一份完整文本回显，并显示 WAV 的已播放时间/总时长进度；没有逐字对齐数据，不做逐字高亮。
- 浏览器等待完整 WAV 下载后再解码播放，因此首音延迟包含整段生成与下载时间；音频只驻留内存，代理端上限为 32 MiB。
- 人物动作根据播放节点的时域幅值和播放器状态驱动，是轻量的表现增强，不提供音素级口型对齐或逐字时间戳。视频封面的 `static/assets/autobiography-character.png` 仍仅供其他视频示例使用。
- “停止”会立即停止本页音频、取消浏览器请求并忽略迟到结果；它不能证明或强制取消 SpeechRail 已经开始的后端推理。后端仍忙时，下一次请求可能得到 `example_busy`。

## 错误恢复

- 音色目录加载失败、SpeechRail 不可达或没有可用音色：确认 SpeechRail 的 health/ready 状态后点击“刷新音色”。
- `401`：检查示例进程继承的 `SPEECHRAIL_API_KEY`，不要将 key 放入页面请求。
- `503`、`backend_busy` 或超时：等待上游空闲/就绪后重试；示例不会无限自动重试。
- 音频解码失败或浏览器暂停音频：再次点击“开始播报”。浏览器必须在用户点击处理器中解锁 `AudioContext`。
- 页面刷新或从后台恢复后不会自动重放旧请求；需要再次点击播报。

退出时只在示例进程前台按 `Ctrl+C`，不会停止 SpeechRail。

## 检查

```bash
uv run --extra dev pytest examples/cartoon-avatar/tests/test_server.py --no-cov
node --test examples/cartoon-avatar/tests/app.test.mjs examples/cartoon-avatar/tests/player.test.mjs examples/cartoon-avatar/tests/avatar.test.mjs examples/cartoon-avatar/tests/layout.test.mjs
uv run --extra dev ruff check examples/cartoon-avatar/server.py examples/cartoon-avatar/tests
uv run --extra dev mypy examples/cartoon-avatar/server.py
```

仓库完整门禁仍需从根目录执行，见 `docs/developers/testing-acceptance.md`。真实 TTS smoke 需要本机已有可用 runtime；测试不会下载模型、保存音频或把完整音色目录写入报告。
