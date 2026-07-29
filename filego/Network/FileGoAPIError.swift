import Foundation

enum FileGoAPIError: LocalizedError {
    case http(status: Int)
    case business(code: Int, message: String)
    case decoding(Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .http(status):
            return "HTTP \(status)"
        case let .business(code, message):
            return message.isEmpty ? "请求失败（\(code)）" : message
        case .decoding:
            return "服务器响应格式无效"
        case .unauthorized:
            return "登录状态已失效"
        }
    }
}
