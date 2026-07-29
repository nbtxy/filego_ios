import Foundation

/// 类型安全的轻量服务注册器，迁移自 qingshu_ios 的 ServiceManager。
final class ServiceContainer: @unchecked Sendable {
    static let shared = ServiceContainer()

    private var services: [ObjectIdentifier: Any] = [:]
    private let lock = NSLock()

    private init() {}

    func register<Service>(_ service: Service, as type: Service.Type = Service.self) {
        lock.withLock {
            services[ObjectIdentifier(type)] = service
        }
    }

    func resolve<Service>(_ type: Service.Type = Service.self) -> Service? {
        lock.withLock {
            services[ObjectIdentifier(type)] as? Service
        }
    }

    func remove<Service>(_ type: Service.Type) {
        _ = lock.withLock {
            services.removeValue(forKey: ObjectIdentifier(type))
        }
    }
}
