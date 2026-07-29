import Foundation
import Moya

extension MoyaProvider {
    func request(_ target: Target) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            request(target) { result in
                continuation.resume(with: result)
            }
        }
    }
}

/// App 统一 Moya Provider。鉴权、Trace、日志及 Debug HTTP 历史都在这里装配。
final class NetworkProvider: @unchecked Sendable {
    private let plugins: [PluginType]

    init(
        tokenProvider: @escaping () -> String? = { AuthTokenStorage.token }
    ) {
        var plugins: [PluginType] = [
            TraceHeaderPlugin(),
            BearerPlugin(tokenProvider: tokenProvider),
            NetworkLogPlugin()
        ]
        #if DEBUG
        plugins.insert(HTTPHistoryPlugin(), at: 0)
        #endif
        self.plugins = plugins
    }

    func provider<Target: TargetType>(for type: Target.Type = Target.self) -> MoyaProvider<Target> {
        MoyaProvider<Target>(plugins: plugins)
    }

    func request<Target: TargetType, Payload: Decodable>(
        _ target: Target,
        as payloadType: Payload.Type = Payload.self
    ) async throws -> Payload {
        let response = try await provider(for: Target.self).request(target)
        return try decodeEnvelope(response, as: payloadType)
    }

    func requestEmpty<Target: TargetType>(_ target: Target) async throws {
        let response = try await provider(for: Target.self).request(target)
        try validateHTTP(response)
        let envelope: EmptyEnvelope
        do {
            envelope = try JSONDecoder.fileGo.decode(EmptyEnvelope.self, from: response.data)
        } catch {
            throw FileGoAPIError.decoding(error)
        }
        guard envelope.statusCode == 0 else {
            throw FileGoAPIError.business(
                code: envelope.statusCode,
                message: envelope.message ?? ""
            )
        }
    }

    private func decodeEnvelope<Payload: Decodable>(
        _ response: Response,
        as type: Payload.Type
    ) throws -> Payload {
        try validateHTTP(response)
        let envelope: APIEnvelope<Payload>
        do {
            envelope = try JSONDecoder.fileGo.decode(APIEnvelope<Payload>.self, from: response.data)
        } catch {
            throw FileGoAPIError.decoding(error)
        }
        guard envelope.statusCode == 0 else {
            throw FileGoAPIError.business(
                code: envelope.statusCode,
                message: envelope.message ?? ""
            )
        }
        guard let payload = envelope.data else {
            throw FileGoAPIError.business(code: envelope.statusCode, message: "响应数据为空")
        }
        return payload
    }

    private func validateHTTP(_ response: Response) throws {
        if response.statusCode == 401 {
            throw FileGoAPIError.unauthorized
        }
        guard (200...299).contains(response.statusCode) else {
            if let envelope = try? JSONDecoder.fileGo.decode(EmptyEnvelope.self, from: response.data),
               envelope.statusCode != 0 {
                throw FileGoAPIError.business(
                    code: envelope.statusCode,
                    message: envelope.message ?? ""
                )
            }
            throw FileGoAPIError.http(status: response.statusCode)
        }
    }
}

extension JSONDecoder {
    static let fileGo: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
