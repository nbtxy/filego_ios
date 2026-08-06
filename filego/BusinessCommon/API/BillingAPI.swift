import Alamofire // Moya.Method / JSONEncoding 都是 Alamofire 类型的别名，必须显式导入
import Foundation
import Moya

/// Pro 订阅接口。实现 `FileGoTarget` 即自动获得统一 baseURL 与 Header。
enum BillingAPI {
    /// 只读当前档位，不打 Apple。
    case status
    /// 上报购买 / 恢复购买。服务端拿这两个交易号回查 App Store Server API，
    /// 客户端送来的值只是线索，不构成权益依据。
    case verify(transactionId: String, originalTransactionId: String)
}

extension BillingAPI: FileGoTarget {
    var path: String {
        switch self {
        case .status: return "/billing/status"
        case .verify: return "/billing/verify"
        }
    }

    var method: Moya.Method {
        switch self {
        case .status: return .get
        case .verify: return .post
        }
    }

    var task: Task {
        switch self {
        case .status:
            return .requestPlain
        case let .verify(transactionId, originalTransactionId):
            return .requestParameters(
                parameters: [
                    "transactionId": transactionId,
                    "originalTransactionId": originalTransactionId
                ],
                encoding: JSONEncoding.default
            )
        }
    }
}
