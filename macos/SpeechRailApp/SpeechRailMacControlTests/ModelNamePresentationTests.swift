#if SWIFT_PACKAGE
import SpeechRailAppSupport
#endif
import SpeechRailControlKit
import XCTest

/// 模型展示名与精度的回归（REDESIGN-SPEC §7.7 第七十五轮）。
///
/// 模型组合页把「这一档到底用哪个模型」放到卡片和轴面板的正中央，于是
/// `model_id` → 展示名这条转换成了用户直接读到的文字：它一旦把仓库前缀留在屏幕上，
/// 就会读成 `mlx-community/Qwen3-ASR-1.7B-8bit` 这样的机器名；把本机绝对路径带上，
/// 还直接违反 §7.7「绝对模型路径不得上屏」。精度同理——位数读不出来时必须说
/// 「未读取」，不能编一个。
final class ModelNamePresentationTests: XCTestCase {
    // MARK: - 展示名

    func testStripsRepositoryPrefixAndPackagingSuffix() {
        XCTAssertEqual(
            ModelNamePresentation.displayName(modelID: "mlx-community/Qwen3-ASR-1.7B-8bit"),
            "Qwen3-ASR-1.7B"
        )
        XCTAssertEqual(
            ModelNamePresentation.displayName(modelID: "mlx-community/Qwen3-ASR-1.7B-bf16"),
            "Qwen3-ASR-1.7B"
        )
    }

    /// 变体名（`-Base`）是模型身份的一部分，不能连同打包后缀一起削掉。
    func testKeepsVariantNameInTheMiddle() {
        XCTAssertEqual(
            ModelNamePresentation.displayName(modelID: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"),
            "Qwen3-TTS-12Hz-1.7B-Base"
        )
    }

    /// 本机路径只取最后一段：§7.7 明确禁止绝对模型路径端上屏。
    func testLocalPathNeverReachesTheUI() {
        let name = ModelNamePresentation.displayName(
            modelID: "/Users/someone/Library/Caches/speechrail/Qwen3-ASR-0.6B-8bit"
        )
        XCTAssertEqual(name, "Qwen3-ASR-0.6B")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.lowercased().contains("users"))
    }

    /// 去掉后缀后不能什么都不剩：整体就是后缀时保留原名。
    func testKeepsNameWhenStrippingWouldEmptyIt() {
        XCTAssertEqual(ModelNamePresentation.displayName(modelID: "-8bit"), "-8bit")
        XCTAssertEqual(ModelNamePresentation.displayName(modelID: "8bit"), "8bit")
    }

    func testEmptyIdentifierStaysEmpty() {
        XCTAssertEqual(ModelNamePresentation.displayName(modelID: "   "), "")
    }

    /// 目录本机实测的四个 ASR/对齐制品都要落到可读的名字上。
    func testCatalogIdentifiersResolveToReadableNames() {
        let identifiers = [
            "mlx-community/Qwen3-ASR-0.6B-8bit",
            "mlx-community/Qwen3-ASR-1.7B-8bit",
            "mlx-community/Qwen3-ASR-1.7B-bf16",
            "mlx-community/Qwen3-ForcedAligner-0.6B-bf16",
        ]
        XCTAssertEqual(
            identifiers.map(ModelNamePresentation.displayName(modelID:)),
            [
                "Qwen3-ASR-0.6B",
                "Qwen3-ASR-1.7B",
                "Qwen3-ASR-1.7B",
                "Qwen3-ForcedAligner-0.6B",
            ]
        )
    }

    // MARK: - 精度

    func testQuantizedPrecisionComesFromBits() {
        let quantization = ModelQuantizationSnapshot(
            bits: 8,
            groupSize: 64,
            format: "mlx"
        )
        XCTAssertTrue(ModelNamePresentation.isQuantized(quantization))
        XCTAssertEqual(ModelNamePresentation.precisionText(quantization), "8-bit")
        XCTAssertEqual(ModelNamePresentation.precisionAccessibilityText(quantization), "精度 8 位")
    }

    /// 未量化制品用权重数值格式换算位数：`bf16` 与 `fp16` 都是 16 位。
    func testUnquantizedPrecisionComesFromDType() {
        let bf16 = ModelQuantizationSnapshot(format: "none", dtype: "bf16")
        XCTAssertFalse(ModelNamePresentation.isQuantized(bf16))
        XCTAssertEqual(ModelNamePresentation.precisionText(bf16), "16-bit")

        let fp32 = ModelQuantizationSnapshot(format: "none", dtype: "fp32")
        XCTAssertEqual(ModelNamePresentation.precisionText(fp32), "32-bit")
    }

    /// 位数读不出来时如实写「未读取」，不按格式名猜。
    func testUnknownPrecisionIsNotGuessed() {
        let unknown = ModelQuantizationSnapshot(format: "none")
        XCTAssertNil(ModelNamePresentation.bitWidth(unknown))
        XCTAssertEqual(ModelNamePresentation.precisionText(unknown), "未读取")
        XCTAssertEqual(ModelNamePresentation.precisionAccessibilityText(unknown), "精度未读取")
    }
}
