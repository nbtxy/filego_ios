import Foundation

final class ThreadSafeMap<Key: Hashable, Value>: @unchecked Sendable {
    private var storage: [Key: Value] = [:]
    private let queue = DispatchQueue(
        label: "com.nbtxy.filego.thread-safe-map",
        attributes: .concurrent
    )

    func value(for key: Key) -> Value? {
        queue.sync { storage[key] }
    }

    func value(for key: Key, default makeValue: () -> Value) -> Value {
        queue.sync(flags: .barrier) {
            if let value = storage[key] { return value }
            let value = makeValue()
            storage[key] = value
            return value
        }
    }

    func set(_ value: Value, for key: Key) {
        queue.sync(flags: .barrier) {
            storage[key] = value
        }
    }

    func removeValue(for key: Key) {
        _ = queue.sync(flags: .barrier) {
            storage.removeValue(forKey: key)
        }
    }

    func removeAll() {
        queue.sync(flags: .barrier) {
            storage.removeAll()
        }
    }

    var values: [Key: Value] {
        queue.sync { storage }
    }
}
