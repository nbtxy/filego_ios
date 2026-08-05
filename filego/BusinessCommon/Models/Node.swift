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

    /// 回收站保留期。与服务端 Cron（`maintenance.ts`）的 30 天口径保持一致。
    static let trashRetentionDays = 30

    /// 距离自动永久删除还剩几天；已到期返回 0。不在回收站里则为 nil。
    func trashDaysRemaining(now: Date = Date()) -> Int? {
        guard let trashedAt else { return nil }
        let deadline = trashedAt.addingTimeInterval(Double(Self.trashRetentionDays) * 86_400)
        // 向上取整：刚删掉的文件应该显示「还有 30 天」，而不是被截断成 29。
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

struct NodeAncestors: Decodable {
    let nodes: [DriveNode]
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
