import Foundation
import Moya

final class BearerPlugin: PluginType {
    private let tokenProvider: () -> String?

    init(tokenProvider: @escaping () -> String? = { AuthTokenStorage.token }) {
        self.tokenProvider = tokenProvider
    }

    func prepare(_ request: URLRequest, target: TargetType) -> URLRequest {
        guard let token = tokenProvider(), !token.isEmpty else { return request }
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
