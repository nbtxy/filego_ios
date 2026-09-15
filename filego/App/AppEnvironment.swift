import Foundation
import StolnkCore

/// App 级依赖容器。基础服务集中创建，业务模块通过这里获取依赖。
@MainActor
final class AppEnvironment {
    let services: ServiceContainer
    let keyValueStore: KeyValueStore
    let stolnk: StolnkController
    let drive: LocalDriveStore

    convenience init() {
        self.init(services: ServiceContainer.shared, keyValueStore: KeyValueStore.shared)
    }

    init(services: ServiceContainer, keyValueStore: KeyValueStore) {
        let store = InboxStore()
        self.services = services
        self.keyValueStore = keyValueStore
        self.stolnk = StolnkController(store: store)
        self.drive = LocalDriveStore()

        services.register(stolnk, as: StolnkController.self)
    }
}
