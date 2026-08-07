import Foundation

@MainActor
final class DriveListViewModel {
    private let session: SessionManager
    private let preferences: KeyValueStore
    let folderId: String

    private(set) var nodes: [DriveNode] = []
    private(set) var ancestors: [DriveNode] = []
    private(set) var isLoading = false
    private var nextCursor: String?
    private var hasLoaded = false

    var sort: NodeSort {
        didSet { preferences.set(sort.rawValue, forKey: "drive.sort") }
    }
    var order: SortOrder {
        didSet { preferences.set(order.rawValue, forKey: "drive.order") }
    }

    init(folderId: String, session: SessionManager, preferences: KeyValueStore) {
        self.folderId = folderId
        self.session = session
        self.preferences = preferences
        sort = NodeSort(rawValue: preferences.value(forKey: "drive.sort") ?? "") ?? .name
        order = SortOrder(rawValue: preferences.value(forKey: "drive.order") ?? "") ?? .ascending
    }

    @discardableResult
    func reload() async throws -> [DriveNode] {
        guard !isLoading else {
            // TODO: [star] 排查用，定位后删除。命中这里说明本次 reload 被跳过、返回的是旧数据。
            AppLogger.warning("[star] reload 被 isLoading 跳过，返回旧数据（count=\(nodes.count)）")
            return nodes
        }
        isLoading = true
        defer { isLoading = false }
        let loadedPage: NodeListPage = try await session.request(
            NodeAPI.list(parentId: folderId, sort: sort, order: order, cursor: nil)
        )
        let loadedTrail: NodeAncestors = try await session.request(NodeAPI.ancestors(id: folderId))
        nodes = loadedPage.nodes
        nextCursor = loadedPage.nextCursor
        ancestors = loadedTrail.nodes
        hasLoaded = true
        return nodes
    }

    func loadNextPageIfNeeded(near index: Int) async throws -> Bool {
        guard hasLoaded, !isLoading, index >= nodes.count - 5, let cursor = nextCursor else {
            return false
        }
        isLoading = true
        defer { isLoading = false }
        let page: NodeListPage = try await session.request(
            NodeAPI.list(parentId: folderId, sort: sort, order: order, cursor: cursor)
        )
        nodes.append(contentsOf: page.nodes)
        nextCursor = page.nextCursor
        return true
    }

    func searchRecursively(query: String) async throws -> [DriveNode] {
        let result: NodeSearchResult = try await session.request(
            NodeAPI.search(parentId: folderId, query: query)
        )
        return result.nodes
    }

    func createFolder(name: String) async throws {
        let _: DriveNode = try await session.request(
            NodeAPI.createFolder(parentId: folderId, name: name)
        )
        _ = try await reload()
    }

    func rename(_ node: DriveNode, to name: String) async throws {
        let _: DriveNode = try await session.request(
            NodeAPI.update(id: node.id, name: name, parentId: nil, starred: nil)
        )
        _ = try await reload()
    }

    func setStarred(_ node: DriveNode, starred: Bool) async throws {
        let updated: DriveNode = try await session.request(
            NodeAPI.update(id: node.id, name: nil, parentId: nil, starred: starred)
        )
        // TODO: [star] 排查用，定位后删除。这里只打印，不使用返回值，保持原有行为。
        AppLogger.info("[star] PATCH resp id=\(updated.id) starred=\(updated.starred)")
        _ = try await reload()
        let after = nodes.first(where: { $0.id == node.id })
        AppLogger.info(
            "[star] after reload id=\(node.id) starred=\(after.map { String($0.starred) } ?? "缺失")"
        )
    }

    func move(_ node: DriveNode, to parentId: String) async throws {
        let _: DriveNode = try await session.request(
            NodeAPI.update(id: node.id, name: nil, parentId: parentId, starred: nil)
        )
        _ = try await reload()
    }

    /// 移入回收站。可在回收站还原，30 天后由服务端 Cron 永久删除。
    func moveToTrash(_ node: DriveNode) async throws {
        let _: DriveNode = try await session.request(NodeAPI.trash(id: node.id))
        _ = try await reload()
    }

    func copy(_ node: DriveNode, to parentId: String) async throws {
        let _: DriveNode = try await session.request(NodeAPI.copy(id: node.id, parentId: parentId))
        _ = try await reload()
    }

    func temporaryLink(for node: DriveNode) async throws -> URL {
        let result: NodeTemporaryLink = try await session.request(NodeAPI.temporaryLink(id: node.id))
        return result.url
    }
}
