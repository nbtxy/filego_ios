import Foundation

enum NodeKind: String, Decodable {
    case folder
    case file
}

struct DriveNode: Decodable, Hashable {
    let id: String
    let parentId: String?
    let kind: NodeKind
    let name: String
    let blobId: String?
    let size: Int64
    let starred: Bool
    let createdAt: Date
    let updatedAt: Date
    let viewedAt: Date?
    let trashedAt: Date?

    var isFolder: Bool { kind == .folder }

    /// config 尚未返回时的随包兜底；真正展示值由 AppConfigStore 传入。
    static let fallbackTrashRetentionDays = 30

    /// 距离自动永久删除还剩几天；已到期返回 0。不在回收站里则为 nil。
    func trashDaysRemaining(
        retentionDays: Int = Self.fallbackTrashRetentionDays,
        now: Date = Date()
    ) -> Int? {
        guard let trashedAt else { return nil }
        let deadline = trashedAt.addingTimeInterval(Double(retentionDays) * 86_400)
        // 向上取整：刚删掉的文件应该显示完整保留期，而不是被截断少一天。
        let days = (deadline.timeIntervalSince(now) / 86_400).rounded(.up)
        return max(0, Int(days))
    }
}

/// `GET /trash` 的 data。
struct TrashList: Decodable {
    let nodes: [DriveNode]
}

/// 永久删除 / 清空回收站的 data。
struct TrashDeletionResult: Decodable {
    let deletedNodes: Int
    let releasedBytes: Int64
}

struct NodeListPage: Decodable {
    let parentId: String
    let nodes: [DriveNode]
    let nextCursor: String?
}

struct NodeSearchResult: Decodable {
    let nodes: [DriveNode]
}

struct NodeAncestors: Decodable {
    let nodes: [DriveNode]
}

struct NodeTemporaryLink: Decodable {
    let url: URL
}

struct ImportAddressResult: Decodable {
    let importAddress: URL
    let expiresAt: Date
    let folder: DriveNode
    let maxFileSize: Int64
}

enum NodeSort: String, CaseIterable {
    case name
    case updated
    case size
}

enum SortOrder: String {
    case ascending = "asc"
    case descending = "desc"
}
