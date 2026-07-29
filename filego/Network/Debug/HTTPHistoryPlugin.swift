#if DEBUG
import Foundation
import Moya

final class HTTPHistoryPlugin: PluginType {
    private var inflight: [URLRequest: UUID] = [:]
    private let lock = NSLock()

    func willSend(_ request: RequestType, target: TargetType) {
        guard let urlRequest = request.request else { return }
        let id = UUID()
        lock.withLock { inflight[urlRequest] = id }

        _Concurrency.Task { @MainActor in
            let (body, truncated) = HTTPHistoryStore.truncateBody(urlRequest.httpBody)
            HTTPHistoryStore.shared.append(
                .init(
                    id: id,
                    startedAt: Date(),
                    method: urlRequest.httpMethod ?? "GET",
                    url: urlRequest.url,
                    requestHeaders: Self.redact(urlRequest.allHTTPHeaderFields ?? [:]),
                    requestBody: body,
                    requestBodyTruncated: truncated,
                    endedAt: nil,
                    statusCode: nil,
                    responseHeaders: [:],
                    responseBody: nil,
                    responseBodyTruncated: false,
                    errorDescription: nil
                )
            )
        }
    }

    func didReceive(_ result: Result<Response, MoyaError>, target: TargetType) {
        let response = try? result.get()
        let urlRequest = response?.request ?? result.failure?.response?.request
        let moyaResponse = response ?? result.failure?.response
        let id: UUID? = {
            guard let urlRequest else { return nil }
            return lock.withLock { inflight.removeValue(forKey: urlRequest) }
        }()

        guard let id else { return }
        let errorText = result.failure.map(String.init(describing:))

        _Concurrency.Task { @MainActor in
            let (body, truncated) = HTTPHistoryStore.truncateBody(moyaResponse?.data)
            HTTPHistoryStore.shared.update(id: id) { record in
                record.endedAt = Date()
                record.statusCode = moyaResponse?.statusCode
                record.responseHeaders = Self.stringHeaders(
                    moyaResponse?.response?.allHeaderFields ?? [:]
                )
                record.responseBody = body
                record.responseBodyTruncated = truncated
                record.errorDescription = errorText
            }
        }
    }

    private static func redact(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, item in
            result[item.key] = item.key.caseInsensitiveCompare("Authorization") == .orderedSame
                ? "Bearer ••••••"
                : item.value
        }
    }

    private static func stringHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        headers.reduce(into: [:]) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
#endif
