import AppKit
import CoreGraphics
import Foundation

/// 目标窗口几何跟踪器。
///
/// 针对用户选定的目标 App 窗口（`CaptionTargetApp`），以 ~15Hz 频率轮询窗口的屏幕位置。
/// 当目标窗口移动、缩放、最小化或关闭时，实时将最新几何（AppKit 屏幕坐标系）通知给上层。
///
/// **严格隐私与权限约束**：
/// 仅通过 `CGWindowListCopyWindowInfo` 查询目标窗口的边界（`kCGWindowBounds`），
/// **严禁**读取 `kCGWindowName`，杜绝任何触发 TCC 录屏权限弹窗的隐患。
@MainActor
public final class TargetWindowTracker {
    public struct TargetWindowGeometry: Equatable, Sendable {
        public let windowID: CGWindowID
        public let pid: pid_t
        public let frame: CGRect // AppKit 屏幕坐标系（以主屏幕左下角为原点）
        public let isVisible: Bool

        public init(windowID: CGWindowID, pid: pid_t, frame: CGRect, isVisible: Bool) {
            self.windowID = windowID
            self.pid = pid
            self.frame = frame
            self.isVisible = isVisible
        }
    }

    private var target: CaptionTargetApp?
    private var timer: DispatchSourceTimer?
    private var lastGeometry: TargetWindowGeometry?

    /// 当目标窗口位置、大小或可见性改变时的回调。若窗口关闭或不可见，返回 `nil`。
    public var onGeometryChanged: ((TargetWindowGeometry?) -> Void)?

    public init() {}

    deinit {
        timer?.cancel()
    }

    /// 开始跟踪指定的目标应用窗口。
    public func startTracking(target: CaptionTargetApp) {
        self.target = target
        stopTrackingTimer()

        // 立即执行一次探测
        pollTargetWindow()

        // 启动 15Hz 定时器（约 66ms 间隔）
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(66), repeating: .milliseconds(66), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.pollTargetWindow()
        }
        timer.resume()
        self.timer = timer
    }

    /// 停止跟踪。
    public func stopTracking() {
        stopTrackingTimer()
        target = nil
        lastGeometry = nil
    }

    private func stopTrackingTimer() {
        timer?.cancel()
        timer = nil
    }

    private func pollTargetWindow() {
        guard let target else {
            if lastGeometry != nil {
                lastGeometry = nil
                onGeometryChanged?(nil)
            }
            return
        }

        let geometry = queryWindowGeometry(target: target)
        if geometry != lastGeometry {
            lastGeometry = geometry
            onGeometryChanged?(geometry)
        }
    }

    /// 查询窗口几何信息并将 Quartz 坐标转换为 AppKit 屏幕坐标。
    ///
    /// 优先匹配选定的 `windowID`；若目标窗口因切换全屏/画中画或从底部快捷栏按应用级选中而无直接 `windowID` 命中，
    /// 自动回退至同一 `bundleID` 在屏面积最大的可见窗口（layer 0...3）。
    private func queryWindowGeometry(target: CaptionTargetApp) -> TargetWindowGeometry? {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

        if let windowID = target.windowID {
            let options: CGWindowListOption = [.optionIncludingWindow]
            if let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
               let dict = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
               let geometry = Self.extractGeometry(from: dict, expectedPID: target.pid, primaryScreenHeight: primaryScreenHeight) {
                return geometry
            }
        }

        // 回退：按 bundleID（或 pid）在当前屏幕可见窗口中选取面积最大的主窗口
        var matchingPIDs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID)
                .map(\.processIdentifier)
        )
        if let pid = target.pid {
            matchingPIDs.insert(pid)
        }
        guard !matchingPIDs.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        var bestGeometry: TargetWindowGeometry?
        var bestArea: CGFloat = 0
        for dict in list {
            guard let layer = dict[kCGWindowLayer as String] as? Int, (0...3).contains(layer),
                  let alpha = dict[kCGWindowAlpha as String] as? Double, alpha > 0.5,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t, matchingPIDs.contains(ownerPID),
                  let geometry = Self.extractGeometry(
                      from: dict,
                      expectedPID: ownerPID,
                      minimumWidth: 120,
                      minimumHeight: 100,
                      primaryScreenHeight: primaryScreenHeight
                  )
            else { continue }

            let area = geometry.frame.width * geometry.frame.height
            if area > bestArea {
                bestArea = area
                bestGeometry = geometry
            }
        }
        return bestGeometry
    }

    private static func extractGeometry(
        from dict: [String: Any],
        expectedPID: pid_t?,
        minimumWidth: CGFloat = 50,
        minimumHeight: CGFloat = 50,
        primaryScreenHeight: CGFloat
    ) -> TargetWindowGeometry? {
        guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
              let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }

        if let expectedPID, ownerPID != expectedPID {
            return nil
        }

        guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
              let quartzRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              quartzRect.width >= minimumWidth, quartzRect.height >= minimumHeight
        else { return nil }

        let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? true
        guard isOnScreen else { return nil }

        let appKitY = primaryScreenHeight - (quartzRect.origin.y + quartzRect.height)
        let appKitRect = CGRect(
            x: quartzRect.origin.x,
            y: appKitY,
            width: quartzRect.width,
            height: quartzRect.height
        )

        return TargetWindowGeometry(
            windowID: windowID,
            pid: ownerPID,
            frame: appKitRect,
            isVisible: true
        )
    }
}
