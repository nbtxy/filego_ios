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
