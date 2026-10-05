---
status: active
date: 2026-10-05
version: 1.0.0
---

# 流式 TTS 结束边界与异常尾音

用户反馈整段回答结束时偶发“打嗝样”声音。本次修复保留正常语音，以 codec EOS
决定生成结束；PCM 淡出仍只处理最后采样到静音的波形边界。

## 调研依据与适用范围

- [Qwen 官方生成实现](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/core/models/modeling_qwen3_tts.py)
  用首个 codec EOS 计算有效长度，排除 EOS 及其后的 codes。
- [当前固定版本的 MLX 实现](https://github.com/Blaizzy/mlx-audio/blob/4ab7e6f7dedd69a136cfaa318c5dc8aed5119446/mlx_audio/tts/models/qwen3_tts/qwen3_tts.py)
  在 EOS 时退出生成循环，不把终止标记送入语音解码器。本地审阅了这一固定 revision，
  不把最新上游当作安装态。
- [Apple 播放回调契约](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype)
  区分 consumed、rendered 和 playedBack。核查当前助手路径后，未发现 codec EOS 后
  多余音频由播放回调生成的证据，本次不扩大为播放器重构。
- [上游 MLX 采样冻结问题报告](https://github.com/huggingface/speech-to-speech/issues/646)
  指向 `mlx==0.32.0` 的跨线程采样问题。当前 runtime lock 已固定 `mlx==0.32.2`，
  该报告不足以归因本问题，不据此升级依赖或改变模型/音色。

以上外部资料核验日期为 2026-10-05；问题报告中的实测只属于其作者的环境。

## 已复现的本地缺陷

`IncrementalSessionDriver._advance` 收到 `FrameOutcome(terminal=True)` 后仅设置标记，
同一次调用仍可继续走剩余 frame budget。真实模型在 EOS 时返回空 PCM，因此下一帧
可能继续采样并输出结束后的音频，或使本应成功的结束变成异常。
此前 fake backend 在每个 terminal 都返回 PCM，循环顶端随即返回音频，未覆盖真实的空 PCM EOS。
5ms 淡出能消除末样本突变，但不能消除已产生的额外音频。

## 实施与验证边界

驱动收到首个 terminal 后立即退出当前循环；terminal 自带的合法 PCM 仍只交付一次。
模型 backend 在 codec EOS 后直接结束，不再运行 code predictor、建立后续 codec embedding
或调用 vocoder；重复调用终态不会再次推进模型。

回归覆盖 1/2/16/64 frame budget、空 PCM EOS、带 PCM terminal、EOS 后噪音/异常、
重复 step，以及真实 driver/adapter/Host 链路的样本总量、连续 offset 和唯一完成。
受控 engine wheel、provenance 和 runtime lock 一起更新，其余依赖版本保持不变。

这些确定性测试证明 EOS 后音频不会进入输出，不能证明用户听到的全部异常只有此一个原因。
真实模型输出及设备听感仍需实际验收；不得用静音检测或固定裁剪删掉正常尾字来替代诊断。
