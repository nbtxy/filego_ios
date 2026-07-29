import Alamofire // Moya.Method / JSONEncoding 都是 Alamofire 类型的别名，必须显式导入
import Foundation
import Moya

/// 鉴权相关接口。实现 `FileGoTarget` 即自动获得统一 baseURL 与 Header。
enum AuthAPI {
    case apple(identityToken: String, fullName: String?)
    /// 开发期免 Apple 账号登录，服务端 ALLOW_DEV_LOGIN 为 true 时可用
    case dev(handle: String)
    case refresh(refreshToken: String)
    case logout(refreshToken: String)
}

extension AuthAPI: FileGoTarget {
    var path: String {
        switch self {
        case .apple: return "/auth/apple"
        case .dev: return "/auth/dev"
        case .refresh: return "/auth/refresh"
        case .logout: return "/auth/logout"
        }
    }

    var method: Moya.Method { .post }

    var task: Task {
        switch self {
        case let .apple(identityToken, fullName):
            var body: [String: Any] = ["identityToken": identityToken]
            if let fullName, !fullName.isEmpty {
                body["fullName"] = fullName
            }
            return .requestParameters(parameters: body, encoding: JSONEncoding.default)
        case let .dev(handle):
            return .requestParameters(
                parameters: ["handle": handle],
                encoding: JSONEncoding.default
            )
        case let .refresh(refreshToken):
            return .requestParameters(
                parameters: ["refreshToken": refreshToken],
                encoding: JSONEncoding.default
            )
        case let .logout(refreshToken):
            return .requestParameters(
                parameters: ["refreshToken": refreshToken],
                encoding: JSONEncoding.default
            )
        }
    }
}

/// 账号信息接口。
enum AccountAPI {
    case me
}

extension AccountAPI: FileGoTarget {
    var path: String { "/me" }
    var method: Moya.Method { .get }
    var task: Task { .requestPlain }
}
