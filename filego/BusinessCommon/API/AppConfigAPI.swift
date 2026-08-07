import Alamofire
import Foundation
import Moya

/// 无需登录的 App 启动配置。
enum AppConfigAPI {
    case config
}

nonisolated extension AppConfigAPI: FileGoTarget {
    var path: String { "/app/config" }
    var method: Moya.Method { .get }
    var task: Task { .requestPlain }
}
