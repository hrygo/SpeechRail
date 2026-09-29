import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TempProbe3 {
    @Test func measureConfidenceLadder() throws {
        let seg = try TeleprompterSegmenter.segment(sourceText: "这里是七成")
        for t in ["这里是8成", "这里是八成", "这里八成", "八成"] {
            let m = TeleprompterAligner().locate(transcript: t, segments: seg,
                                                 anchor: .init(segmentIndex: 0, utf16Offset: 0))
            print("LADDER [\(t)] -> conf=\(m.confidence) m=\(m.matchedCount) pos=\(m.position != nil)")
        }
    }

    @Test func measureShortTranscripts() throws {
        let seg = try TeleprompterSegmenter.segment(
            sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。"
        )
        for t in ["相机", "设置", "相机设置", "导", "照片导出"] {
            let m = TeleprompterAligner().locate(transcript: t, segments: seg,
                                                 anchor: .init(segmentIndex: 0, utf16Offset: 0))
            print("SHORT [\(t)] -> conf=\(m.confidence) m=\(m.matchedCount) pos=\(String(describing: m.position))")
        }
    }
}
