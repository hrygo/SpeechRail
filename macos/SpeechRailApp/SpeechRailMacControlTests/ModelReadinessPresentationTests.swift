#if SWIFT_PACKAGE
import SpeechRailAppSupport
#endif
import XCTest

/// 模型页首屏结论的回归。
///
/// 这一句是界面对用户断言「现在是哪一档、模型够不够」的地方。按 REDESIGN-SPEC §4.3，
/// 拿不出证据却读成肯定的话就是界面在骗人，所以除了逐个分支核对措辞，这里还钉住
/// 两条不变量：**语气只在该肯定时肯定**，以及**页面上不出现档位的内部名**。
final class ModelReadinessPresentationTests: XCTestCase {
    private let target = "品质"
    private let remaining = "尚需下载不超过 8.2 GiB"

    private func present(
        _ state: ModelReadinessState,
        running: String? = "轻快"
    ) -> ModelReadinessPresentation {
        ModelReadinessPresenter.presentation(
            state: state,
            target: target,
            running: running,
            remainingDownloadText: remaining
        )
    }

    // MARK: - 逐个分支

    func testCatalogUnreadableDoesNotClaimAnything() {
        let result = present(.catalogUnreadable)
        XCTAssertEqual(result.tone, .neutral)
        XCTAssertTrue(result.title.contains(target))
        XCTAssertTrue(result.message.contains("服务目录暂时不可用"))
    }

    func testNoArtifactsRegisteredPointsAtDiagnostics() {
        let result = present(.noArtifactsRegistered)
        XCTAssertEqual(result.tone, .attention)
        XCTAssertTrue(result.message.contains("诊断"))
    }

    func testPreparingAndApplyingAreDistinct() {
        let preparing = present(.preparing)
        let applying = present(.applying)
        XCTAssertEqual(preparing.tone, .attention)
        XCTAssertEqual(applying.tone, .attention)
        // 准备与切换是两件事，措辞不能互相串台：串台了用户会以为已经在换档。
        XCTAssertTrue(preparing.title.contains("正在准备"))
        XCTAssertTrue(applying.title.contains("正在切换"))
        XCTAssertNotEqual(preparing.title, applying.title)
    }

    func testPendingReportsCountAndRemainingBytes() {
        let result = present(.pending(count: 3))
        XCTAssertEqual(result.tone, .attention)
        XCTAssertTrue(result.title.contains("3"))
        XCTAssertTrue(result.message.contains(remaining))
    }

    func testInUseAndConfiguredIsTheOnlyFullyConfidentReadyState() {
        let result = present(.inUseAndConfigured, running: target)
        XCTAssertEqual(result.tone, .healthy)
        XCTAssertTrue(result.title.contains("服务正在使用"))
        XCTAssertTrue(result.message.contains("配置与运行是同一档"))
    }

    func testConfigurationUnreadStaysHonestAboutWhatIsMissing() {
        let result = present(.inUseConfigurationUnread, running: target)
        XCTAssertEqual(result.tone, .healthy)
        // 模型确实校验过了，所以说就绪没问题；但配置没读到就必须写出来，
        // 不能顺势说成「配置与运行一致」。
        XCTAssertTrue(result.message.contains("还没读到完整的配置档位"))
        XCTAssertFalse(result.message.contains("配置与运行是同一档"))
    }

    func testRuntimeUnreadRefusesToSayWhichTierIsRunning() {
        let result = present(.readyRuntimeUnread, running: nil)
        XCTAssertEqual(result.tone, .attention)
        XCTAssertTrue(result.message.contains("还没读到服务当前运行的档位"))
    }

    func testReadyToSwitchNamesTheRunningTierAndTheConsequence() {
        let result = present(.readyToSwitch, running: "轻快")
        XCTAssertEqual(result.tone, .attention)
        XCTAssertTrue(result.message.contains("轻快"))
        // 应用会重启服务并短暂不可用，这是不用点就知道的后果，必须写在按钮旁边。
        XCTAssertTrue(result.message.contains("重启服务"))
    }

    // MARK: - 不变量

    /// 只有「模型已校验且服务确实在用」这两种状态才允许肯定语气。
    func testOnlyVerifiedInUseStatesUseHealthyTone() {
        let states: [ModelReadinessState] = [
            .catalogUnreadable, .noArtifactsRegistered, .preparing, .applying,
            .pending(count: 2), .inUseAndConfigured, .inUseConfigurationUnread,
            .readyRuntimeUnread, .readyToSwitch
        ]
        for state in states {
            let tone = present(state).tone
            let mayBeHealthy = state == .inUseAndConfigured || state == .inUseConfigurationUnread
            XCTAssertEqual(
                tone == .healthy,
                mayBeHealthy,
                "状态 \(state) 的语气是 \(tone)，与「模型已校验且服务在用」不符"
            )
        }
    }

    /// §4.2：可见文案里不出现档位的内部名。`shortTitle` 翻好了才轮到这句话，
    /// 所以这里按最终字符串断言，而不是信任调用方传进来的名字。
    func testNoTierInternalNameLeaksIntoTheConclusion() {
        let states: [ModelReadinessState] = [
            .catalogUnreadable, .noArtifactsRegistered, .preparing, .applying,
            .pending(count: 1), .inUseAndConfigured, .inUseConfigurationUnread,
            .readyRuntimeUnread, .readyToSwitch
        ]
        let forbidden = ["fast", "quality", "reference", "asr_spec", "tts_spec"]
        for state in states {
            let result = present(state)
            let rendered = result.title + result.message
            for name in forbidden {
                XCTAssertFalse(
                    rendered.contains(name),
                    "状态 \(state) 的结论里漏出了内部名 \(name)：\(rendered)"
                )
            }
        }
    }

    /// 每个分支都要说出目标档位，否则用户在多档之间读不出这句话是关于哪一档的。
    func testEveryStateNamesTheTargetTier() {
        let states: [ModelReadinessState] = [
            .catalogUnreadable, .noArtifactsRegistered, .preparing, .applying,
            .pending(count: 1), .inUseAndConfigured, .inUseConfigurationUnread,
            .readyRuntimeUnread, .readyToSwitch
        ]
        for state in states {
            XCTAssertTrue(
                present(state).title.contains(target),
                "状态 \(state) 的标题没说出目标档位：\(present(state).title)"
            )
        }
    }
}
