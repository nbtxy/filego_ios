import Alamofire // Moya.Method / JSONEncoding 都是 Alamofire 类型的别名，必须显式导入
import Foundation
import Moya

/// 鉴权相关接口。实现 `FileGoTarget` 即自动获得统一 baseURL 与 Header。
enum AuthAPI {
    case apple(identityToken: String, fullName: String?)
    case refresh(refreshToken: String)
    case logout(refreshToken: String)
}

nonisolated extension AuthAPI: FileGoTarget {
    var path: String {
        switch self {
        case .apple: return "/auth/apple"
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
    case updateDisplayName(String)
    /// 注销账号。服务端会硬删该用户的全部数据，不可恢复。
    case delete
}

nonisolated extension AccountAPI: FileGoTarget {
    var path: String { "/me" }

    var method: Moya.Method {
        switch self {
        case .me: return .get
        case .updateDisplayName: return .patch
        case .delete: return .delete
        }
    }

    var task: Task {
        switch self {
        case .me, .delete:
            return .requestPlain
        case let .updateDisplayName(displayName):
            return .requestParameters(
                parameters: ["displayName": displayName],
                encoding: JSONEncoding.default
            )
        }
    }
}
