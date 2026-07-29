import Foundation

/// 支持全局域和用户域的线程安全 UserDefaults 封装。
final class KeyValueStore: @unchecked Sendable {
    static let shared = KeyValueStore()

    private let queue = DispatchQueue(
        label: "com.nbtxy.filego.key-value-store",
        attributes: .concurrent
    )
    private var currentUserID = "default"

    private init() {}

    func setCurrentUser(_ userID: String) {
        queue.sync(flags: .barrier) {
            currentUserID = userID
        }
    }

    func clearCurrentUser() {
        setCurrentUser("default")
    }

    func set<T>(_ value: T?, forKey key: String) {
        queue.sync(flags: .barrier) {
            userDefaults.set(value, forKey: key)
        }
    }

    func value<T>(forKey key: String, as type: T.Type = T.self) -> T? {
        queue.sync {
            userDefaults.object(forKey: key) as? T
        }
    }

    func setCodable<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        set(data, forKey: key)
    }

    func codable<T: Decodable>(forKey key: String, as type: T.Type) throws -> T? {
        guard let data: Data = value(forKey: key) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func removeValue(forKey key: String) {
        set(Optional<Any>.none, forKey: key)
    }

    func setGlobal<T>(_ value: T?, forKey key: String) {
        queue.sync(flags: .barrier) {
            globalDefaults.set(value, forKey: key)
        }
    }

    func globalValue<T>(forKey key: String, as type: T.Type = T.self) -> T? {
        queue.sync {
            globalDefaults.object(forKey: key) as? T
        }
    }

    private var userDefaults: UserDefaults {
        let identifier = currentUserID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "default"
        return UserDefaults(suiteName: "com.nbtxy.filego.user.\(identifier)") ?? .standard
    }

    private var globalDefaults: UserDefaults {
        UserDefaults(suiteName: "com.nbtxy.filego.global") ?? .standard
    }
}
