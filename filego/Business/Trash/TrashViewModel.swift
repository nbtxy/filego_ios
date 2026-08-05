import Foundation

@MainActor
final class TrashViewModel {
    private let session: SessionManager

    private(set) var nodes: [DriveNode] = []
    private(set) var isLoading = false

    /// 服务端 `/trash` 的 limit 上限是 200，这里一次拉满：回收站不做分页。
    private static let pageLimit = 200

    init(session: SessionManager) {
        self.session = session
    }

    @discardableResult
    func reload() async throws -> [DriveNode] {
        guard !isLoading else { return nodes }
        isLoading = true
        defer { isLoading = false }
        let page: TrashList = try await session.request(TrashAPI.list(limit: Self.pageLimit))
        nodes = page.nodes
        return nodes
    }

    func restore(_ node: DriveNode) async throws {
        let _: DriveNode = try await session.request(TrashAPI.restore(id: node.id))
        _ = try await reload()
    }

    func deleteForever(_ node: DriveNode) async throws {
        let _: TrashDeletionResult = try await session.request(TrashAPI.deleteForever(id: node.id))
        _ = try await reload()
    }

    func emptyAll() async throws {
        let _: TrashDeletionResult = try await session.request(TrashAPI.emptyAll)
        _ = try await reload()
    }
}
