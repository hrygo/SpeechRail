import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterFollowControllerTests {
    private func script() throws -> [TeleprompterSegment] {
        try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。")
    }

    @Test func splitFinalsAccumulatePosition() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到", segments: segments)
        #expect(controller.position.utf16Offset == 4)
        controller.receiveCompleted(itemID: "b", transcript: "今天的直播", segments: segments)
        #expect(controller.position.utf16Offset == 9)
        controller.receiveCompleted(itemID: "c", transcript: "今天我们介绍相机设置最后演示照片导出", segments: segments)
        #expect(controller.currentIndex == 2)
    }

    @Test func partialIsProvisionalAndFinalReplacesIt() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments)
        #expect(controller.candidatePosition?.segmentIndex == 1)
        #expect(controller.currentIndex == 0)
        controller.receivePartial(itemID: "a", delta: "相机设置", segments: segments)
        #expect(controller.currentIndex == 1)
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到今天的直播", segments: segments)
        #expect(controller.currentIndex == 0)
        controller.receiveCompleted(itemID: "a", transcript: "最后演示照片导出", segments: segments)
        #expect(controller.currentIndex == 0)
    }

    @Test func detourHoldsAndFollowingSpeechRecovers() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到今天的直播", segments: segments)
        let before = controller.position
        controller.receiveCompleted(itemID: "b", transcript: "请稍等我回复一下评论", segments: segments)
        #expect(controller.position == before)
        #expect(controller.uncertainty != nil)
        controller.receiveCompleted(itemID: "c", transcript: "今天我们介绍相机设置", segments: segments)
        #expect(controller.currentIndex == 1)
        #expect(controller.uncertainty == nil)
    }

    @Test func pausedAndRetiredItemsCannotOverrideManualPosition() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "old", delta: "今天我们", segments: segments)
        controller.pause()
        controller.receiveCompleted(itemID: "paused", transcript: "最后演示照片导出", segments: segments)
        #expect(controller.mode == .paused)
        controller.move(to: 1, segmentCount: segments.count)
        controller.resume()
        controller.receiveCompleted(itemID: "old", transcript: "最后演示照片导出", segments: segments)
        controller.receiveCompleted(itemID: "paused", transcript: "最后演示照片导出", segments: segments)
        #expect(controller.currentIndex == 1)
        #expect(controller.position.utf16Offset == 0)
        controller.receiveCompleted(itemID: "new", transcript: "今天我们介绍相机设置", segments: segments)
        #expect(controller.position.utf16Offset > 0)
    }
}
