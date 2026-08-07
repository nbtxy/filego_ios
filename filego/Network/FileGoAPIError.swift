import Foundation

enum FileGoAPIError: LocalizedError {
    case http(status: Int)
    case business(code: Int, message: String)
    /// 响应体连信封都解不出来。`body` 是原始字节，只用于排查——光一句
    /// 「格式无效」在真出问题时完全无法定位是哪个字段、还是根本不是 JSON。
    case decoding(Error, body: Data)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .http(status):
            return "HTTP \(status)"
        case let .business(code, message):
            return message.isEmpty ? "请求失败（\(code)）" : message
        case .decoding:
            #if DEBUG
            return "服务器响应格式无效\n\(debugDetail)"
            #else
            return "服务器响应格式无效"
            #endif
        case .unauthorized:
            return "登录状态已失效"
        }
    }

    /// 解码失败的排查信息：底层错误 + 响应体前 512 字节。
    /// 只在 DEBUG 里进弹窗，Release 文案保持不变。
    var debugDetail: String {
        guard case let .decoding(error, body) = self else { return "" }
        let snippet = String(decoding: body.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(error)\n响应体：\(snippet.isEmpty ? "<空>" : snippet)"
    }
}
