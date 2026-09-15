import Foundation

@MainActor
final class DriveListViewModel {
    private let drive: LocalDriveStore
    private let preferences: KeyValueStore
    let folderId: String

    private(set) var nodes: [DriveNode] = []
    private(set) var ancestors: [DriveNode] = []
    private(set) var isLoading = false

    var sort: NodeSort {
        didSet { preferences.set(sort.rawValue, forKey: "drive.sort") }
    }
    var order: SortOrder {
        didSet { preferences.set(order.rawValue, forKey: "drive.order") }
    }

    init(folderId: String, drive: LocalDriveStore, preferences: KeyValueStore) {
        self.folderId = folderId
        self.drive = drive
        self.preferences = preferences
        sort = NodeSort(rawValue: preferences.value(forKey: "drive.sort") ?? "") ?? .name
        order = SortOrder(rawValue: preferences.value(forKey: "drive.order") ?? "") ?? .ascending
    }

    /**
     读取当前目录。

     改造前这里是两个网络请求（列表 + 祖先链）加一个游标。现在是两次文件系统读，
     所以没有分页了——`loadNextPageIfNeeded` 随之消失，目录一次读完。
     */
    @discardableResult
    func reload() async throws -> [DriveNode] {
        guard !isLoading else { return nodes }
        isLoading = true
        defer { isLoading = false }
        nodes = try drive.list(in: folderId, sort: sort, order: order)
        ancestors = drive.ancestors(of: folderId)
        return nodes
    }

    func searchRecursively(query: String) async throws -> [DriveNode] {
        drive.search(under: folderId, query: query)
    }

    func createFolder(name: String) async throws {
        try drive.createFolder(in: folderId, name: name)
        _ = try await reload()
    }

    func rename(_ node: DriveNode, to name: String) async throws {
        try drive.rename(node, to: name)
        _ = try await reload()
    }

    func move(_ node: DriveNode, to parentId: String) async throws {
        try drive.move(node, to: parentId)
        _ = try await reload()
    }

    /// 移入 `Documents/.Trash/`，仍在设备上。见 `LocalDriveStore.moveToTrash`。
    func moveToTrash(_ node: DriveNode) async throws {
        try drive.moveToTrash(node)
        _ = try await reload()
    }

    func copy(_ node: DriveNode, to parentId: String) async throws {
        try drive.copy(node, to: parentId)
        _ = try await reload()
    }

    /// 本地文件的 URL，给预览用。改造前这里要先下载。
    func fileURL(for node: DriveNode) -> URL {
        drive.url(for: node.id)
    }

    @discardableResult
    func importFile(at url: URL) async throws -> DriveNode {
        let node = try drive.importFile(at: url, into: folderId)
        _ = try await reload()
        return node
    }
}
