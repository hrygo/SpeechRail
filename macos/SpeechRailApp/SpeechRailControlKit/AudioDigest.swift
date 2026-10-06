import CryptoKit
import Foundation

/// #189：WAV `data` chunk 字节摘要。
///
/// 服务端 `pcm_sha256` 是传输前 PCM16 字节流的 SHA-256（`render_receipts.py`
/// `accept_pcm` 逐块 `update`，`complete` 时 `hexdigest`），与 WAV 容器无关。
/// 客户端 `audioData` 是 WAV 全文件：必须解析 `data` chunk 只取 PCM 字节算哈希，
/// 哈希整个文件会与服务端口径不一致。
/// 纯函数、可单元测试；调用方在非 MainActor 执行边界调用，避免同步占用主线程。
public enum AudioDigest {
    public enum Failure: Error, Equatable {
        case notRIFF
        case truncatedHeader
        case chunkOverrunsFile(declared: Int, available: Int)
        case dataChunkNotFound
    }

    /// 解析 WAV 并返回 `data` chunk 的 PCM 字节区间。只读、不拷贝。
    /// - 要求 12 字节 RIFF 头 + 逐 chunk 扫描（`id` + `size` + 内容，奇数补齐）。
    /// - `data` chunk 出現多次时取第一块（服务端是单段 PCM 流，无多 data 语义）。
    public static func pcmRange(in wav: Data) throws -> Range<Int> {
        guard wav.count >= 12 else { throw Failure.truncatedHeader }
        let riff = wav[wav.startIndex ..< wav.startIndex.advanced(by: 4)]
        guard riff.elementsEqual("RIFF".utf8) else { throw Failure.notRIFF }
        // RIFF size + WAVE 四字节之后是 chunk 序列。
        var cursor = wav.startIndex.advanced(by: 12)
        let end = wav.endIndex
        while cursor < end {
            guard let chunkEnd = wav.index(cursor, offsetBy: 8, limitedBy: end) else {
                throw Failure.truncatedHeader
            }
            let id = wav[cursor ..< wav.index(cursor, offsetBy: 4)]
            let size = Int(
                wav[wav.index(cursor, offsetBy: 4)]
            ) | (Int(wav[wav.index(cursor, offsetBy: 5)]) << 8)
                | (Int(wav[wav.index(cursor, offsetBy: 6)]) << 16)
                | (Int(wav[wav.index(cursor, offsetBy: 7)]) << 24)
            let bodyStart = chunkEnd
            guard let bodyEnd = wav.index(bodyStart, offsetBy: size, limitedBy: end) else {
                throw Failure.chunkOverrunsFile(declared: size, available: end - bodyStart)
            }
            if id.elementsEqual("data".utf8) {
                return bodyStart ..< bodyEnd
            }
            // chunk 内容按偶数对齐：奇数 size 后有一字节 pad。
            var next = bodyEnd
            if size % 2 == 1 {
                guard next < end else { throw Failure.truncatedHeader }
                next = wav.index(after: next)
            }
            cursor = next
        }
        throw Failure.dataChunkNotFound
    }

    /// WAV `data` chunk 字节的 SHA-256 hex（小写）。失败时抛 `Failure`。
    public static func sha256HexOfPCM(in wav: Data) throws -> String {
        let range = try pcmRange(in: wav)
        var hasher = SHA256()
        wav[range].withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
