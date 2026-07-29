import Foundation

/// App 级依赖容器。基础服务集中创建，业务模块通过这里获取依赖。
@MainActor
final class AppEnvironment {
    let services: ServiceContainer
    let keyValueStore: KeyValueStore
    let networkProvider: NetworkProvider
    let sessionManager: SessionManager
    let accountService: AccountService

    init() {
        let services = ServiceContainer.shared
        let keyValueStore = KeyValueStore.shared
        let networkProvider = NetworkProvider()
        let sessionManager = SessionManager(networkProvider: networkProvider)

        self.services = services
        self.keyValueStore = keyValueStore
        self.networkProvider = networkProvider
        self.sessionManager = sessionManager
        self.accountService = AccountService(session: sessionManager)

        services.register(networkProvider, as: NetworkProvider.self)
        services.register(sessionManager, as: SessionManager.self)
    }

    init(
        services: ServiceContainer,
        keyValueStore: KeyValueStore,
        networkProvider: NetworkProvider
    ) {
        let sessionManager = SessionManager(networkProvider: networkProvider)

        self.services = services
        self.keyValueStore = keyValueStore
        self.networkProvider = networkProvider
        self.sessionManager = sessionManager
        self.accountService = AccountService(session: sessionManager)

        services.register(networkProvider, as: NetworkProvider.self)
        services.register(sessionManager, as: SessionManager.self)
    }
}
