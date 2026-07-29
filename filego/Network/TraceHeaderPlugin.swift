import Foundation
import Moya

struct TraceHeaderPlugin: PluginType {
    private static let deviceIDKey = "filego.device-id"

    func prepare(_ request: URLRequest, target: TargetType) -> URLRequest {
        var request = request
        request.setValue(Self.deviceID, forHTTPHeaderField: "X-Device-Id")
        if let traceID = TraceContext.current {
            request.setValue(traceID, forHTTPHeaderField: "X-Trace-Id")
        }
        return request
    }

    private static var deviceID: String {
        if let value: String = KeyValueStore.shared.globalValue(forKey: deviceIDKey) {
            return value
        }
        let value = UUID().uuidString
        KeyValueStore.shared.setGlobal(value, forKey: deviceIDKey)
        return value
    }
}
