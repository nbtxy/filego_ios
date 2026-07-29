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
        guard !isLoading else { return nodes }
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
        let _: DriveNode = try await session.request(
            NodeAPI.update(id: node.id, name: nil, parentId: nil, starred: starred)
        )
        _ = try await reload()
    }

    func move(_ node: DriveNode, to parentId: String) async throws {
        let _: DriveNode = try await session.request(
            NodeAPI.update(id: node.id, name: nil, parentId: parentId, starred: nil)
        )
        _ = try await reload()
    }

    func copy(_ node: DriveNode, to parentId: String) async throws {
        let _: DriveNode = try await session.request(NodeAPI.copy(id: node.id, parentId: parentId))
        _ = try await reload()
    }
}
