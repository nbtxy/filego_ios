import Foundation

enum NodeKind: String {
    case folder
    case file
}

/**
 文件树里的一个节点。

 形状与改造前一致，来源换了：以前是后端 `/nodes` 返回的 JSON，现在由
 `LocalDriveStore` 从 `FileManager` 现读。保持同一个类型是刻意的——
 `DriveListViewController`、`DriveNodeCell`、`BreadcrumbBar`、
 `FolderPickerViewController` 加起来一千多行 UI 因此原样可用。

 `id` 是相对 Documents 的相对路径，根目录是空串。用路径当 id 意味着重命名或移动
 之后它就是另一个节点了——这对 diffable data source 正好（那确实是另一行）。
 */
struct DriveNode: Hashable {
    let id: String
    let parentId: String?
    let kind: NodeKind
    let name: String
    let size: Int64
    let updatedAt: Date

    var isFolder: Bool { kind == .folder }
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
