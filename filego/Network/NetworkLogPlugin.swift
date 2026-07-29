import Foundation
import Moya

struct NetworkLogPlugin: PluginType {
    func willSend(_ request: RequestType, target: TargetType) {
        guard let request = request.request else { return }
        AppLogger.info("→ \(request.httpMethod ?? "UNKNOWN") \(request.url?.absoluteString ?? "invalid-url")")
    }

    func didReceive(_ result: Result<Response, MoyaError>, target: TargetType) {
        switch result {
        case let .success(response):
            AppLogger.info("← \(response.statusCode) \(response.request?.url?.absoluteString ?? target.path) [\(response.data.count) bytes]")
        case let .failure(error):
            AppLogger.error("← Request failed: \(target.path)", error: error)
        }
    }
}
