import Foundation

// 这一整个文件都是纯数据，没有一样东西属于主线程。工程开了
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不写 `nonisolated` 它们就会被推断成
// 主线程隔离的类型，于是 `FileKind`（它是 nonisolated）读一下 `node.isFolder` 都要报
// 跨隔离域访问。顺带让它们自动满足 `Sendable`——diffable 的 item 类型本来就该是。

nonisolated enum NodeKind: String {
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
nonisolated struct DriveNode: Hashable {
    let id: String
    let parentId: String?
    let kind: NodeKind
    let name: String
    let size: Int64
    let updatedAt: Date

    var isFolder: Bool { kind == .folder }
}

nonisolated enum NodeSort: String, CaseIterable {
    case name
    case updated
    case size
}

nonisolated enum SortOrder: String {
    case ascending = "asc"
    case descending = "desc"
}

/**
 回收站里的一项。

 刻意不是 `DriveNode`：树里的节点靠相对路径定身份，而回收站里的东西已经脱离了树，
 它的原位置是还原时才用的历史信息，不是当前位置。多出来的两个字段（入站时间、
 原父目录）文件系统本身不记，来自 `.Trash/.index.json`。
 */
nonisolated struct TrashItem: Hashable {
    /// `.Trash/` 下的实际文件名。重名会被去重，所以未必等于 `name`。
    let storageName: String
    /// 删除时的显示名，也是还原后的名字。
    let name: String
    /// 原来所在的文件夹 id。那个文件夹如果已经没了，还原会回落到根目录。
    let originParentID: String
    let kind: NodeKind
    let size: Int64
    let trashedAt: Date

    var isFolder: Bool { kind == .folder }

    /// 列表复用 `DriveNodeCell`，它要一个 `DriveNode`。id 用存储名：回收站里唯一，
    /// 而 `name` 可能和另一项撞上（两个不同目录下的同名文件先后被删）。
    var displayNode: DriveNode {
        DriveNode(
            id: storageName, parentId: nil, kind: kind,
            name: name, size: size, updatedAt: trashedAt
        )
    }
}
