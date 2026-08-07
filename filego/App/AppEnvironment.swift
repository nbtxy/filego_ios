import Foundation

/// App 级依赖容器。基础服务集中创建，业务模块通过这里获取依赖。
@MainActor
final class AppEnvironment {
    let services: ServiceContainer
    let keyValueStore: KeyValueStore
    let networkProvider: NetworkProvider
    let sessionManager: SessionManager
    let accountService: AccountService
    let billingService: BillingService
    let storeKitService: StoreKitService
    let storageSnapshot: StorageSnapshotStore
    let appConfigStore: AppConfigStore

    convenience init() {
        self.init(
            services: ServiceContainer.shared,
            keyValueStore: KeyValueStore.shared,
            networkProvider: NetworkProvider()
        )
    }

    /// 唯一的真实构造路径。
    ///
    /// 以前这里有两个逐字重复的 initializer，加依赖时改一个漏一个就会在用到另一个的
    /// 地方崩——现在无参那个走 convenience 转发过来，只有这一处需要维护。
    init(
        services: ServiceContainer,
        keyValueStore: KeyValueStore,
        networkProvider: NetworkProvider
    ) {
        let sessionManager = SessionManager(networkProvider: networkProvider)
        let billingService = BillingService(session: sessionManager)

        self.services = services
        self.keyValueStore = keyValueStore
        self.networkProvider = networkProvider
        self.sessionManager = sessionManager
        self.accountService = AccountService(session: sessionManager)
        self.billingService = billingService
        self.storeKitService = StoreKitService(
            billing: billingService,
            session: sessionManager
        )
        self.storageSnapshot = StorageSnapshotStore()
        self.appConfigStore = AppConfigStore(
            networkProvider: networkProvider,
            keyValueStore: keyValueStore
        )

        services.register(networkProvider, as: NetworkProvider.self)
        services.register(sessionManager, as: SessionManager.self)
    }
}
