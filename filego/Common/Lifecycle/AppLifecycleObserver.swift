import UIKit

typealias LifecycleObserver = (_ isActive: Bool) -> Void

final class AppLifecycleObserver {
    static let shared = AppLifecycleObserver()

    private var observers: [UUID: LifecycleObserver] = [:]
    private let lock = NSLock()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @discardableResult
    func observe(_ observer: @escaping LifecycleObserver) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = observer }
        return id
    }

    func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }

    @objc private func appDidBecomeActive() {
        AppLogger.debug("Application became active")
        dispatch(isActive: true)
    }

    @objc private func appDidEnterBackground() {
        AppLogger.debug("Application entered background")
        dispatch(isActive: false)
    }

    private func dispatch(isActive: Bool) {
        let callbacks = lock.withLock { Array(observers.values) }
        callbacks.forEach { $0(isActive) }
    }
}
