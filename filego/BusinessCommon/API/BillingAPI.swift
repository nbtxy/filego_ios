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
    /// 仅本地联调：直接开通 Pro，不碰 Apple。
    /// 服务端由 ALLOW_DEV_BILLING 把关，未开启时返回 40401 当作接口不存在。
    case devGrant(days: Int)
}

nonisolated extension BillingAPI: FileGoTarget {
    var path: String {
        switch self {
        case .status: return "/billing/status"
        case .verify: return "/billing/verify"
        case .devGrant: return "/billing/dev-grant"
        }
    }

    var method: Moya.Method {
        switch self {
        case .status: return .get
        case .verify, .devGrant: return .post
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
        case let .devGrant(days):
            return .requestParameters(
                parameters: ["days": days],
                encoding: JSONEncoding.default
            )
        }
    }
}
