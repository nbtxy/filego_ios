import Foundation

/// 把下载到本地的 .md 文件读成字符串。
///
/// 编码是这里的主要难点：网盘里的 md 不保证是 UTF-8，国内常见 GB18030/GBK 编码的中文文档，
/// 直接按 UTF-8 解会得到乱码——这是「渲染效果不对」的第二大成因。
/// `nonisolated`：读文件 + 猜编码是纯计算，调用方就是要把它甩到主线程之外跑
/// （见 MarkdownPreviewController 的 `Task.detached`）——大文件在主线程解码会卡界面。
/// 本 target 开了 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，不写就绑主线程了。
nonisolated enum MarkdownSource {
    /// 超过这个大小就不进 WebView 渲染，降级到 QuickLook 纯文本。
    /// marked + highlight.js 在主线程解析数 MB 文本会明显卡顿。
    static let maximumByteCount = 2 * 1024 * 1024

    enum Failure: Error, LocalizedError {
        case tooLarge(Int)
        case undecodable

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return R.Strings.previewMarkdownTooLarge.localizedString()
            case .undecodable:
                return R.Strings.previewMarkdownUndecodable.localizedString()
            }
        }
    }

    static func load(from url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumByteCount else { throw Failure.tooLarge(data.count) }
        guard let text = decode(data) else { throw Failure.undecodable }
        return normalizeLineEndings(text)
    }

    // MARK: - 解码

    static func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }

        if let (encoding, offset) = byteOrderMark(in: data) {
            let body = data.subdata(in: offset ..< data.count)
            if let text = String(data: body, encoding: encoding) { return text }
        }

        if let text = String(data: data, encoding: .utf8) { return text }

        // 无 BOM 且不是合法 UTF-8：优先按国内最常见的 GB18030 试，
        // 它是 GBK/GB2312 的超集，能覆盖绝大多数简中遗留文档。
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gb18030) { return text }

        for encoding in [String.Encoding.utf16, .shiftJIS, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) { return text }
        }

        // 最后的有损兜底：latin1 对任意字节都成立，至少能看到结构而不是空白页。
        return String(data: data, encoding: .isoLatin1)
    }

    private static func byteOrderMark(in data: Data) -> (String.Encoding, Int)? {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return (.utf8, 3)
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            return (.utf16LittleEndian, 2)
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            return (.utf16BigEndian, 2)
        }
        return nil
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
