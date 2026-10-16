/// Maps the SDK's cumulative frame cursor onto its bounded retained array.
public struct RetainedFrameCursor: Sendable {
    public enum CursorError: Error { case invalidRange, activityGap }
    public let absoluteStart: Int
    public let localRange: Range<Int>

    public init(totalFrames: Int, retainedFrames: Int, emittedFrames: Int) throws {
        guard totalFrames >= 0, retainedFrames >= 0, retainedFrames <= totalFrames,
              emittedFrames >= 0, emittedFrames <= totalFrames else {
            throw CursorError.invalidRange
        }
        let base = totalFrames - retainedFrames
        guard emittedFrames >= base else { throw CursorError.activityGap }
        absoluteStart = emittedFrames
        localRange = (emittedFrames - base)..<retainedFrames
    }
}
