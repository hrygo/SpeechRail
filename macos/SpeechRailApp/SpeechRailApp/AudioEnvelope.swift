import AVFoundation

/// 分块扫描持久化音频；取消在每块读取及计算后检查。没有临时落盘路径。
@concurrent
public func scanWaveformEnvelope(fileURL url: URL, buckets: Int) async throws -> [Double] {
    try AppPerformanceMetrics.shared.measure(.waveformScan, count: buckets) {
        try Task.checkCancellation()
        guard (1...32_768).contains(buckets) else { throw WaveformLoadError.invalidRequest }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        let channelCount = max(1, Int(format.channelCount))
        guard totalFrames > 0 else { throw WaveformLoadError.invalidAudio }

        // 分块读：一段几分钟的音频也不会被一次性读进内存。
        let chunkFrames: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { throw WaveformLoadError.invalidAudio }

        var peaks = [Float](repeating: 0, count: buckets)
        var frameIndex: AVAudioFramePosition = 0
        while frameIndex < totalFrames {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channelData = buffer.floatChannelData else { throw WaveformLoadError.invalidAudio }
            for frame in 0..<frames {
                var magnitude: Float = 0
                for channel in 0..<channelCount where channelData[channel][frame].isFinite {
                    magnitude = max(magnitude, abs(channelData[channel][frame]))
                }
                // 窗口边界按**整段**位置算，不按块算：否则块边界会多切出一条。
                let bucket = min(
                    buckets - 1,
                    Int(Double(frameIndex + AVAudioFramePosition(frame)) * Double(buckets) / Double(totalFrames))
                )
                if magnitude > peaks[bucket] { peaks[bucket] = magnitude }
            }
            frameIndex += AVAudioFramePosition(frames)
        }

        try Task.checkCancellation()
        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks.map { _ in 0 } }
        return peaks.map { Double($0 / maximum) }
    }
}

enum AudioEnvelope {
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
