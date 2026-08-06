import Foundation
import Moya

/// 新接口按业务定义 enum 并实现此协议，即可自动获得统一 baseURL 和 Header。
///
/// **所有实现都必须是 `nonisolated` 的。**
/// 本 target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不写 nonisolated
/// 的话这些 enum 对 `TargetType` 的遵循会被推成主 actor 隔离；而 `SessionManager`
/// 本身是个 actor，从它或别的 actor（如 MultipartUploader 的 PartURLProvider）
/// 发请求就会报「main actor-isolated conformance 不能用在 actor 隔离上下文」。
///
/// 这些类型只是「一次请求长什么样」的纯描述，没有任何可变状态，本就不该绑主线程。
protocol FileGoTarget: TargetType {}

nonisolated extension FileGoTarget {
    var baseURL: URL { BackendConfig.baseURL }
    var headers: [String: String]? {
        ["Accept": "application/json"]
    }
    var validationType: ValidationType { .none }
}
