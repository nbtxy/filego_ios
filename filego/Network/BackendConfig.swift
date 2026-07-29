import Foundation

enum BackendConfig {
    private static let storageKey = "filego.debug.api-base-url"

    static let productionBaseURL = URL(string: "https://nbtxy.com/api/v1")!

    static var defaultBaseURL: URL {
        #if DEBUG
        return URL(string: "http://\(BuildLAN.host):8787/api/v1")!
        #else
        return productionBaseURL
        #endif
    }

    static var baseURL: URL {
        guard
            let stored: String = KeyValueStore.shared.globalValue(forKey: storageKey),
            let url = URL(string: stored)
        else {
            return defaultBaseURL
        }
        return url
    }

    static func apply(baseURL rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            throw ValidationError.invalidBaseURL
        }
        KeyValueStore.shared.setGlobal(
            url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            forKey: storageKey
        )
    }

    static func reset() {
        KeyValueStore.shared.setGlobal(Optional<String>.none, forKey: storageKey)
    }

    enum ValidationError: LocalizedError {
        case invalidBaseURL

        var errorDescription: String? {
            "服务器地址无效"
        }
    }
}
