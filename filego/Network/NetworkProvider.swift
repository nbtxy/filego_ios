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
            throw decodingFailure(error, response: response)
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
        // 必须先判状态码，再碰 Payload。服务端的业务错误是 HTTP 200 + statusCode!=0，
        // 且 data 装的是【错误详情】而不是 Payload（配额快照、缺失的分片号、期望/实际
        // 字节数…）。直接解 APIEnvelope<Payload> 会在 data 上抛 DecodingError，把
        // 「存储空间不足」这类真正有用的提示统统盖成「服务器响应格式无效」。
        let status: EmptyEnvelope
        do {
            status = try JSONDecoder.fileGo.decode(EmptyEnvelope.self, from: response.data)
        } catch {
            throw decodingFailure(error, response: response)
        }
        guard status.statusCode == 0 else {
            throw FileGoAPIError.business(
                code: status.statusCode,
                message: status.message ?? ""
            )
        }
        let envelope: APIEnvelope<Payload>
        do {
            envelope = try JSONDecoder.fileGo.decode(APIEnvelope<Payload>.self, from: response.data)
        } catch {
            throw decodingFailure(error, response: response)
        }
        guard let payload = envelope.data else {
            throw FileGoAPIError.business(code: envelope.statusCode, message: "响应数据为空")
        }
        return payload
    }

    /// 解码失败在 Release 上只剩一句「格式无效」，不在这里把状态码和响应体
    /// 记进日志就彻底断线索了。DEBUG 下 `debugDetail` 还会一并进弹窗。
    private func decodingFailure(_ error: Error, response: Response) -> FileGoAPIError {
        let failure = FileGoAPIError.decoding(error, body: response.data)
        AppLogger.error("响应解码失败 status=\(response.statusCode) | \(failure.debugDetail)")
        return failure
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
