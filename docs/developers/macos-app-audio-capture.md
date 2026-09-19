---
title: "SpeechRail macOS App 录音通道与音频采集最佳实践"
status: active
audience: "SpeechRail macOS App 设计与开发人员"
version: "0.2.0"
date: 2026-09-19
---

# SpeechRail macOS App 录音通道与音频采集最佳实践

> 本文是 2026-09-16 的调研 + 本机实测记录，回答两个问题：音色克隆页的麦克风采集现在是怎么做的，
> 以及 macOS 上这件事的当前推荐做法是什么。结论区分「契约/文档声明」「本机实测」和「推断」，
> 外部来源都标了核实日期；本机结论只对本机、当前系统版本成立。

## 1. 当前实现（以代码为准）

| 项 | 现状 | 位置 |
|---|---|---|
| 采集 API | `AVAudioRecorder(url:settings:)`，Linear PCM / 48 kHz / 单声道 / 16-bit，写系统临时目录的 `.wav` | `macos/SpeechRailApp/SpeechRailApp/VoiceRecordingController.swift` |
| 线程 | 录音器整段跑在一条自带 run loop 的私有线程上（`RecorderThread`），主线程只做状态与呈现 | 同上 |
| 电平 | `isMeteringEnabled = true` + 20 Hz 轮询 `averagePower(forChannel: 0)`，dBFS → 0…1 | 同上 |
| 有无信号 | `hasSignal`：本次录音是否越过 `VoiceClone.signalFloorLevel`（≈ -50 dBFS） | 同上 |
| 权限 | `AVCaptureDevice.authorizationStatus(for: .audio)` + `requestAccess`；`NSMicrophoneUsageDescription` 写在三个 build configuration 里 | `VoiceRecordingController.swift` / `project.pbxproj` |
| 采集链处理 | 刻意不启用 AEC / 降噪 / AGC（声音克隆要的是用户本来的音色）；系统级「麦克风模式」未干预 | `VoiceRecordingController.swift` / REDESIGN-SPEC §13.2 |
| 打包 | 本机 Debug/Release：ad hoc 签名、关 Hardened Runtime；`Entitlements/SpeechRailApp.entitlements` 目前是空 `<dict/>`；Distribution 才开 Hardened Runtime | `Config/*.xcconfig` |
| 落盘边界 | 只在「按下录制 → 停止」之间采集；收下后立刻删临时文件，注册成功后连内存里的字节也放掉 | `AppModel.acceptCloneRecording` |

## 2. 2026-09-16 实测：一次「录不到声音」的排障

**现象**：录音时电平表不动、回听没有声音；界面显示「录音中」，计时正常，文件长度与录音时长一致。

**取证顺序与结果**（App 2.6.5 (14)，macOS 26.6.2，本机 MacBook Pro 内置麦克风）：

1. **TCC 是否给了**：`log show --predicate 'process == "SpeechRail"'` + `tccd` 侧
   `AUTHREQ_RESULT: msgID=90727.3, authValue=2` / `ReqResult(Auth Right: Allowed (User Consent))`
   —— 20:31:08 用户在弹出的系统提示里点了允许，菜单栏麦克风指示灯亮。
2. **设备是否真的跑起来**：`coreaudiod` 侧
   `BuiltInMicrophoneDevice ... AudioDeviceStart (err 0)`、`IO Stopped Context 27920 after 713216 frames`
   （713216 / 14.897 s ≈ 47.9 kHz）—— 设备确实启动了 14.9 秒。
3. **拿到的样点是什么**：同一时刻用 `ffmpeg -f avfoundation -i ":0" -t 1.2 -f s16le -` 采集，
   51968 个样点**全部是 0**；`/tmp` 里任何一段 TTS 输出用同一条命令测都是正常电平
   （`max_volume: -5.5 dB`），说明量测方法本身没问题。
4. **是不是被静音了**：读 `kAudioDevicePropertyMute` = `unmuted`、`kAudioDevicePropertyVolumeScalar`
   = 0.69、`kAudioDevicePropertyDataSource` = `imic`（内置麦克风）、`kAudioDevicePropertyNominalSampleRate`
   = 48000。

**结论（本机实测）**：权限已给、设备在跑、数据全 0 —— 这台机器的麦克风输入在**系统层面**就没有声音，
不是音色克隆页的代码问题。`AVAudioRecorder` 写出的是一段时长达标、内容为数字静音的 wav，
所以「播放也没声音」和「电平表不动」是同一个原因的两种表现。

**可复用的排障顺序（先系统、再应用）**：

1. 系统设置 ▸ 声音 ▸ 输入：确认选中的设备、输入音量、下方输入电平表在有声时是否起跳；
2. 语音备忘录录一段并回听（换一个完全独立的 App）；
3. 仍无声 → 重启 `coreaudiod`（需要管理员）或重启系统；外接一支 USB/耳机麦克风对比，
   能区分「内置麦克风硬件」与「整机采集链路」；
4. 以上都正常、只有本 App 无声，再回到本文第 1 节的五项逐个查（权限、entitlement、格式、线程、电平）。

## 3. 最佳实践（来源标注在 §5，核实日期 2026-09-16）

### 3.1 选哪条采集 API

- **只需要「录成文件」**：`AVAudioRecorder` 仍然是最省事的一条（macOS 10.7+，Apple 文档仍在维护）。
  新代码优先用 `init(url:format:)`（macOS 10.12+）：格式来自 `AVAudioFormat` 对象，
  比 `settings` 字符串键字典少一层拼写风险。注意 `AVAudioRecorder` 内部是 AudioQueue：
  `record()` 是同步的 CoreAudio 调用，**可能长时间阻塞**（本机首次冷启动实测最坏 36 秒），
  所以它必须离开主线程（本仓库的 `RecorderThread` 就是为此存在）。
- **需要实时样点**（本地 VAD、边录边传 ASR、自己算电平）：用 `AVAudioEngine` 的输入节点 tap，
  或 `AVAudioSinkNode`（macOS 10.15+）。SinkNode **不做格式转换**，连接时要用输入节点的输出格式
  （即硬件采样率）——这正好也是采集侧最省事的选择。
- **只有在需要极底层控制时**才直接写 AudioQueue / AudioUnit。

### 3.2 格式与音质

- **采样率跟随硬件**（本机内置麦克风 48 kHz）。不要在采集侧先重采样：服务端会把参考音频统一
  转码成 24 kHz 单声道，应用多做一次只会白丢一次质量。
- **位深**：16-bit PCM 的理论动态范围约 96 dB，对人声参考音频足够（服务端质量门看的是 SNR 与削波，
  不是位深）。要更多余量再用 24-bit / float32，但文件会大一倍。
- **声道**：单声道。这是参考音频的形态，也避免左右通道间的相位差。
- **电平目标**：峰值落在 -12…-6 dBFS 之间最稳；离麦 15–20 cm、避免正对键盘与风扇口。
  低于 -40 dBFS 基本等于「没说话」，贴着 0 dBFS 会削波——这两种正是服务端质量门会拒的情况。
- **不要 AGC / AEC / 降噪**（声音克隆场景）：它们会改掉用户的音色，属于「替用户改声音」。
  需要留意的是**系统级**的「麦克风模式」（语音突显 / 宽谱 / 标准）由用户在 Control Center 里选，
  它会在 App 之外处理音频（`AVCaptureDevice.MicrophoneMode`，macOS 12+）；录参考音频时应提示用户
  用「标准」。

### 3.3 电平与可视化

- `isMeteringEnabled = true` 之后，读 `averagePower(forChannel:)` / `peakPower(forChannel:)`
  **必须先调 `updateMeters()`**（Apple 文档口径），并且在录音真正跑起来之前两者会一直贴着地板。
- 20 Hz 的轮询节奏足够（本仓库取 `Waveform.progressInterval`），更快只是在敲录音器。
- 「电平一直贴底」是一个**可解释状态**（设备被静音、选错设备、系统层面没给数据），
  不要让界面把它表现成动画故障：4 秒内没有越过门限就直接写结论（本次同轮已落地）。

### 3.4 权限与打包（macOS 特有的坑）

- TCC：Info.plist 必须有 `NSMicrophoneUsageDescription`，请求用
  `AVCaptureDevice.requestAccess(for: .audio)`（macOS 10.14+）。denied 时给的是「去系统设置」的路。
- 沙盒：需要 `com.apple.security.device.audio-input`（Apple entitlements 文档：先开 Hardened Runtime，
  再在 Resource Access 里勾 Audio Input）。**本仓库待补**：该文件现在是空 dict，
  Distribution 会开 Hardened Runtime，届时内置麦克风采集需要这个 entitlement。
- **ad hoc 签名 + 每次重建会重新弹权限**：TCC 记录按 static code 匹配，
  `tccd` 会记 `Failed to match existing code requirement for subject ... and service kTCCServiceMicrophone`
  并重新提示。用稳定签名（Developer ID）发布后这个现象消失；排障时不要把「又弹了一次」当成故障。
- 非沙盒、非 hardened runtime 的本机 Debug 构建现在不需要 entitlement 就能录，所以**不能**用
  「Debug 能录」证明发布路径也能录。

### 3.5 设备与运行期

- 采集用的设备是**系统默认输入**；界面上的设备名只用来解释「声音从哪来」，
  要和实际采集保持一致（本仓库用 `AVCaptureDevice.default(for: .audio)?.localizedName` 显示）。
- 用户在录音中途换了默认输入设备（插耳机、切蓝牙）时，`AVAudioRecorder` 会继续写同一个文件，
  但**整段录音可能来自两支不同的麦克风**：要么监听默认输入设备变化并提示重录
  （CoreAudio 的 `kAudioHardwarePropertyDefaultInputDevice` 属性监听），要么在录音开始时把设备钉住。
- 采集结束要**等文件封口**再读：`stop()` 只把「停」发出去，立刻读会读到一段还没写完的音频
  （本仓库 `finish()` 的职责）。

### 3.6 线程与实时性

- 涉及 AudioQueue 的创建/启动不要放主线程（见 §3.1 的阻塞实测）。
- 实时回调里不做 I/O、不加锁、不分配大对象；写文件交给 `AVAudioFile` 或录音器自己。

## 3.7 会话级采集（2026-09-18 补，实时字幕落地时实装）

音色克隆是「录一段文件」，会话（语音助手 / 会议助手 / 实时字幕）是「连续出 PCM、立刻送走、随即丢掉」。
两者共用权限口径与电平曲线，但**采集件不是一个**：文件那一条是 `AVAudioRecorder`（AudioQueue），
会话这一条是 `AVAudioEngine` 的输入 tap + `AVAudioConverter`。

| 项 | 会话级采集的口径 | 位置 |
|---|---|---|
| API | `AVAudioEngine.inputNode.installTap`（硬件格式）+ `AVAudioConverter` → 16 kHz / 单声道 / PCM16 | `MicrophoneCapture.swift` |
| 出口格式 | **永远 16 kHz 单声道 PCM16**。契约规定 `/v1/realtime` 首个 PCM 之后不得改格式，把归一放在来源这一侧，客户端就不可能违反它 | 同上 |
| 块大小 | 100 ms（3,200 字节）。端到端延迟里可忽略，事件数比 20 ms 一块少一个量级 | 同上 |
| 实时约束 | 回调里只做一次转换 + 一次拷贝进**预分配环形缓冲**（容量 1 秒 = 32,000 字节）；取数据由一条 100 ms 的 drain 任务负责（与上面的块大小同一个数）。回调里不做 I/O、不分配、不等锁以外的任何东西 | 同上 |
| 溢出 | 写满时丢最旧的字节——丢的音频就是真的没录上，不做"回源补全"，也不假装它还在。**没有溢出计数器**：今天没有消费者，写一个没人读的数比不写更容易被误当成"已经有监控了" | 同上 |
| 电平 | 与音色克隆**同一条曲线**（`AudioLevel.normalized`，-60 dBFS 为底），三页读数一致 | `MicrophoneCapture.swift` / `VoiceRecordingController.swift` |
| 设备生命周期 | **按功能启用、功能离开释放**：`start()` 建引擎、`stop()` 拆 tap 并 `engine.stop()`；空闲时没有引擎、没有 tap | `MicrophoneCapture.swift` |
| 阻塞调用 | `engine.start()` 跑在采集队列上（本机实测过 `AVAudioRecorder.record()` 最坏阻塞 36 秒，同类调用一律不回主线程） | 同上 |
| PCM 落盘 | **没有写文件的路径**。内存里只有 1 秒的环形缓冲，出口直接进 WebSocket | 同上 |

**授权弹窗文案**也要跟着改：`NSMicrophoneUsageDescription` 已从「音色克隆需要读取麦克风」
改成同时覆盖克隆与会话（`project.pbxproj` 三个 build configuration 各一份）。

### 3.7.1 本机音频（进程 tap）与多来源合流（2026-09-18 补，会议助手落地时实装）

会议助手要录的不只是屋里的人，还有**这台 Mac 正在播的声音**（腾讯会议、QQ 音乐…）。
这一路与麦克风是两套机制，所以它的口径单独写在这里：

| 项 | 本机音频的口径 | 位置 |
|---|---|---|
| API | macOS 的**按进程 tap**：`CATapDescription.bundleIDs` → `AudioHardwareCreateProcessTap` → 私有 aggregate device（tap 作为它的输入流）→ `AudioDeviceCreateIOProcID` | `CoreAudioTapCapture.swift` |
| 不改变听感 | `muteBehavior` 保持默认 `CATapUnmuted`：抓取不该让本机静音 | 同上 |
| 来源重开 | `isProcessRestoreEnabled = true`（SDK 语义：来源 App 重启后按 bundle id 自动接回）。**本机没有真机验证过它的行为**，所以实现里只把它当作"尽力而为" | 同上 |
| 载体 | **App 内 XPC service**（`Resources/XPCServices/com.speechrail.desktop.capture-helper.xpc` + `SpeechRailCaptureHelper` target）。由 launchd 在 App 连接时启动、App 停采集后空闲退出，同时把 tap 的崩溃面与 App 隔开 | `SpeechRailCaptureHelper/` |
| 出口格式 | 与麦克风**同一个出口**：16 kHz / 单声道 / PCM16。tap 的原始格式（通常是 48 kHz 的 Float32）在 helper 里用 `AVAudioConverter` 归一 | `CoreAudioTapCapture.swift` |
| 实时约束 | IOProc 回调里只做"交错 + 写预分配环形缓冲"（2 的幂容量、原子读写下标），转换与电平都在 drain 线程；回调里没有锁、没有分配 | 同上 |
| 合流 | 勾了多个来源时走 `StreamMixer`：每 40 ms 从每一路的抖动缓冲取 640 帧，**缺的补静音并计一次缺口**，而不是把两路硬拼成一条听起来连续的流 | `AudioSourceCoordinator.swift` |
| 为什么选了本机音频就总走混音器 | 即使只有它一路：来源 App 退出之后要**换上新的那一路**，而直通的那条流没有换人的位置。「来源 App 退出」是四类中断里唯一会自动接回的一类 | 同上 |
| 设备生命周期 | 与麦克风同一条规则：会话提交时拿、会话离开时释放。XPC 连接一作废，helper 的 `invalidationHandler` 立刻停采集并拆设备 | `CaptureHelperClient.swift` |
| PCM 落盘 | 与麦克风一致：**没有写文件的路径**。PCM 只在内存里过一道 40 ms 的管道 | 全链 |

**授权**：`NSAudioCaptureUsageDescription` 在两处给到——App 的
`SpeechRailApp/Info.plist`（补进生成式 Info.plist 的那份偏量文件）与 helper 自己的
`Resources/XPCServices/…/Contents/Info.plist`（tap 是在那个进程里建的）。
按「按功能启用」的口径，这个权限**只在用户第一次选「本机音频」来源时**才会触发——
只用字幕或只用麦克风的用户永远看不到它。

> **踩过的坑（2026-09-18 实测）**：这个键**没有** `INFOPLIST_KEY_` 映射。写成
> `INFOPLIST_KEY_NSAudioCaptureUsageDescription` 会被 Xcode **静默丢弃**：`plutil -p` 查产物时
> 它不在，而同一批写法里的 `NSMicrophoneUsageDescription` 在（那条在映射表里）。
> 判据只有一条——**构建之后查产物里的键**，不要看 build settings 里写没写。
> App target 仍是 `GENERATE_INFOPLIST_FILE = YES`，`INFOPLIST_FILE` 指定的是**偏量**文件，
> 生成器产出的键照常合并进来（同一次实测：`CFBundleName` / `LSApplicationCategoryType` /
> `CFBundleShortVersionString` 都还在）。

**helper 的签名**：嵌入脚本用 `codesign --force --sign …` 重签这个 `.xpc`，**没有**带
`--options runtime`，也没有 entitements 文件——所以它在 Distribution 构建里不是 hardened runtime，
而 tap 的 TCC 归属（算 App 还是算 XPC service）本机没验证过。两件事都算在 §6 那条 tap 真机验证里。

**现状分层（2026-09-19）**：以上 `MicrophoneCapture` 仍服务字幕与会议，设备变化时保持原有
「采集流结束 → 中断」口径；语音助手不再直接使用它，而是使用下方的 `AudioEngineSession`。
因此助手已经有自己的引擎重建路径，但会议/字幕仍未实现 `device_switch` 行。

### 3.7.2 语音助手的共享播放/采集与系统 AEC（2026-09-19 实装）

`AssistantSession` 的默认 `audioSourceFactory` 现在返回 `AudioEngineSession`：采集与 TTS 播放共用
同一台 `AVAudioEngine`。这条链路只在助手会话期间建立，结束时拆 tap、停止 engine 并释放播放节点；
音色克隆仍然保持未经 AEC/AGC/降噪处理的独立录音链路。

| 模式 | 原生配置 | 上行口径 |
|---|---|---|
| 一问一答（外放） | 同一 engine 播放与采集；不强制 voice processing | 播放开始时清空旧输入，播放期间由会话门闩不上行，播放结束再清空残留 |
| 实时对讲（耳机） | engine 启动前同时对 `inputNode` / `outputNode` 调用 `setVoiceProcessingEnabled(true)` | 全程上行；系统 voice processing 获得同 engine 的 far-end 播放参考，服务端 `speech_started` 负责取消 TTS |

输入 tap 仍归一为 16 kHz / 单声道 / PCM16；TTS 以 24 kHz / 单声道 PCM16 进入同一 engine 的
`AVAudioPlayerNode`。插话或用户点停止只停播放器并使旧缓冲失效，不拆输入引擎，所以下一块 TTS
可以继续播放。`AVAudioEngineConfigurationChangeNotification` 触发后会重建 input tap、converter
和 player；新路由不支持 duplex 时回调为可读失败，而不是静默发送未经处理的帧。

**尚未完成的验收**：本机 Debug 构建已通过，但系统 AEC 的真实 ERLE、双讲不收敛、外放距离与不同
耳机/麦克风组合仍需在实际设备上测量。没有这组声学数据，不把「已调用 voice processing」写成
「外放也一定不回采」。

## 4. 与 SpeechRail 的差距（按性价比排序的建议）

1. **补 entitlement**（Distribution）：`com.apple.security.device.audio-input`
   （2026-09-18 已加进 `Entitlements/SpeechRailApp.entitlements`；发布路径的真机验收仍未做）。
2. **发布路径也要在真机上验收一次录音**，不能只用本机 Debug 构建的结论替代。
3. **采集侧不做 AGC/AEC 的原则**已经是现状，值得在 ADR 里固化，避免以后被「更干净」说服。
4. **默认输入设备变化**：录音中提示重录（§3.5）。
5. **需要实时能力时再迁移**：本地 VAD / 边录边传 → `AVAudioEngine` + `AVAudioSinkNode`，
   保留 48 kHz 硬件格式。
6. `AVAudioRecorder(url:format:)` 替代 settings 字典，给格式一个类型化的来源。

## 5. 来源（核实日期 2026-09-16）

| 来源 | 用途 |
|---|---|
| [AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)（macOS 10.7+） | 录音器现状、可用性 |
| [AVAudioRecorder.init(url:settings:)](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/init(url:settings:)-5whyq) / [init(url:format:)](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/init(url:format:)-7herw)（macOS 10.12+） | 格式的两种声明方式 |
| [isMeteringEnabled](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/ismeteringenabled) / [updateMeters()](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/updatemeters()) / [averagePower(forChannel:)](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/averagepower(forchannel:)) | 电平读数的先后顺序 |
| [AVAudioSinkNode](https://developer.apple.com/documentation/avfaudio/avaudiosinknode)（macOS 10.15+） | 实时样点通道；"The format should match the hardware input sample rate" |
| [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)（macOS 10.10+） | 节点图与实时渲染约束 |
| [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession) | **平台列表里没有 macOS**：macOS App 不能像 iOS 那样声明 audio session 类别，等价控制走 HAL / 录音器自身 |
| [AVCaptureDevice.MicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/microphonemode) / [.voiceIsolation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/microphonemode/voiceisolation)（macOS 12+） | 系统「麦克风模式」会处理输入音频 |
| [AVCaptureDevice.requestAccess(for:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:))（macOS 10.14+） | 权限请求 |
| [App Sandbox：Audio Input](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input) | 沙盒/Hardened Runtime 的 entitlements 要求 |
| [在 Mac 上控制对麦克风的访问](https://support.apple.com/zh-cn/guide/mac-help/mchla1b1e1fe/mac) | 用户侧权限一览与录制指示灯 |
| [在 Mac 上更改声音输入设置](https://support.apple.com/zh-cn/guide/mac-help/mchlp2567/26/mac/26) | 输入设备与输入音量 |
| [在 Mac 上使用麦克风模式](https://support.apple.com/zh-cn/guide/mac-help/mchle82b42f0/26/mac/26) | 语音突显 / 宽谱 / 标准 |

## 6. 未验证与待办

- 本文第 2 节的结论只覆盖本机、当前系统版本；**系统侧麦克风恢复之前，任何「录音质量」结论都不成立**，
  恢复后需要按 `.agents/skills/speechrail-perf-benchmark/SKILL.md` 的制品口径重新实测一次。
- 建议里的 1、4、5、6 项尚未实施。
- 未做：多设备切换实测、蓝牙耳机采集实测、长时间（>5 分钟）录音的稳定性实测。
- 未做：**进程 tap 的真机验证**（`TECHNICAL-DESIGN` §12 第 1、2 条）——授权弹窗的实际触发点、
  `bundleIDs` 是否真按 App 生效、`processRestoreEnabled` 的真实行为，三件都只有 SDK 标注语义。
  会议助手的整个本机音频来源都建立在这三件事上，所以它现在是**这一版里最需要真机跑一次的地方**。
- 未做：**tap 的 TCC 归属**（算 App 还是算 XPC service）与 helper 在 Distribution 下的签名形态
  （嵌入脚本重签时没带 `--options runtime`、没有 entitlements）。Debug 路走通不等于发布路走通。
