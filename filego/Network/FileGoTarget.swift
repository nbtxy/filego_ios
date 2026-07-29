import Foundation
import Moya

/// 新接口按业务定义 enum 并实现此协议，即可自动获得统一 baseURL 和 Header。
protocol FileGoTarget: TargetType {}

extension FileGoTarget {
    var baseURL: URL { BackendConfig.baseURL }
    var headers: [String: String]? {
        ["Accept": "application/json"]
    }
    var validationType: ValidationType { .none }
}
