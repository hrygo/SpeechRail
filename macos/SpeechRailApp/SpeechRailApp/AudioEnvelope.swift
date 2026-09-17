import AVFoundation

/// 波形条的数据来源：把一段真实音频压成「一排条的高度」。
///
/// 2026-09-16 用户反馈「播放音波效果是假的」：在此之前，三处 `WaveformBars` 画的都是
/// 稿上的**固定高度数组**（`SpeechRailDesignTokens.Waveform.*`），播放时只叠一层整块
/// 透明度呼吸——它知道「在播」，但既不知道「在响什么」，也不知道「播到哪了」。
/// 这里补上第一条真实通道（幅度包络），第二条（播放进度）在
/// `AudioPlaybackController.progress`（REDESIGN-SPEC §11.6 第五十七轮）。
///
/// 两个刻意的选择：
/// - 取**峰值**而不是 RMS。波形图的通行读法就是逐窗峰值；RMS 会把语音的停顿拉成
///   一片几乎等高的绒面，「看得出这句话的结构」正是这张图存在的理由。
/// - 整段按最大值**归一化**。不同音色、不同设备录进来的音频响度差很多，归一化后
///   都填满同一个盒子，剩下的差异就只有形状——也就是这段音频本身。
///
/// 全部是 `nonisolated` 纯函数：解码一段 12s 的 WAV 是本机毫秒级的工作，但它是
/// **I/O 与解码**，调用方负责把它放到主线程之外（见 `AppModel.cacheEnvelope`）。
enum AudioEnvelope {
    /// 解码内存里的音频数据，按等宽窗口取峰值，返回 `buckets` 个 0…1 的值。
    ///
    /// `AVAudioFile` 只认文件 URL（`AVAudioPlayer` 才有 `Data` 初始化器），所以这一支
    /// 先把数据落到**系统临时目录**、读完立刻删掉：TTS 试听的音频是内存里的数据，
    /// 应用不落盘保存它（作品的音频本来就有自己的文件，走 `levels(forAudioFileAt:)`）。
    nonisolated static func levels(forAudioData data: Data, buckets: Int) -> [CGFloat]? {
        guard buckets > 0 else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "speechrail-envelope-\(UUID().uuidString).wav",
                isDirectory: false
            )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return levels(forAudioFileAt: url, buckets: buckets)
    }

    /// 解码磁盘上的音频文件，按等宽窗口取峰值，返回 `buckets` 个 0…1 的值。
    nonisolated static func levels(forAudioFileAt url: URL, buckets: Int) -> [CGFloat]? {
        guard buckets > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let totalFrames = file.length
        let channelCount = max(1, Int(format.channelCount))
        guard totalFrames > 0 else { return nil }

        // 分块读：一段几分钟的音频也不会被一次性读进内存。
        let chunkFrames: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { return nil }

        var peaks = [Float](repeating: 0, count: buckets)
        var frameIndex: AVAudioFramePosition = 0
        while frameIndex < totalFrames {
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                return nil
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channelData = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var magnitude: Float = 0
                for channel in 0..<channelCount where channelData[channel][frame].isFinite {
                    magnitude = max(magnitude, abs(channelData[channel][frame]))
                }
                // 窗口边界按**整段**位置算，不按块算：否则块边界会多切出一条。
                let bucket = min(
                    buckets - 1,
                    Int((frameIndex + AVAudioFramePosition(frame))
                        * AVAudioFramePosition(buckets) / totalFrames)
                )
                if magnitude > peaks[bucket] { peaks[bucket] = magnitude }
            }
            frameIndex += AVAudioFramePosition(frames)
        }

        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks.map { _ in 0 } }
        return peaks.map { CGFloat($0 / maximum) }
    }

    /// 把一份包络重采样成 `count` 根条（每根取所属区间里的最大值）。
    ///
    /// 缓存只有一份（`Waveform.envelopeBuckets`），而三种排布分别是 12 / 16 / 18 根，
    /// 视图因此按自己的条数重采样，模型不必知道任何 `Pattern`。
    nonisolated static func resample(_ levels: [CGFloat], to count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }
        guard levels.count != count else { return levels }
        return (0..<count).map { index in
            let start = index * levels.count / count
            let end = max(start + 1, (index + 1) * levels.count / count)
            return levels[start..<min(end, levels.count)].max() ?? 0
        }
    }
}
