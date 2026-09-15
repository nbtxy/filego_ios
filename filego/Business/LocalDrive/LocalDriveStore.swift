import Foundation
import StolnkCore

/**
 本地文件树。收件盘的存储层，取代了改造前那套 `/nodes` 远端调用。

 根目录是 `Documents/`，和 `InboxStore` 在 iOS 上的落地根同一个位置——收到的文件
 必须出现在用户浏览的这棵树里，两个根不一致就会出现「收到了但找不到」。配合
 `UIFileSharingEnabled`，同一棵树在系统「文件」App 里也可见。

 节点 id 是相对 `Documents/` 的相对路径，根是空串。
 */
@MainActor
final class LocalDriveStore {
    static let rootID = ""

    let root: URL
    private let fm = FileManager.default

    /// 收件过程中的 `.part` 文件由 `FileLanding` 以点开头命名，落地前对用户不可见。
    /// 这里统一跳过点开头的条目，顺带也把 `.Trash/` 挡在外面。
    private func isHidden(_ name: String) -> Bool { name.hasPrefix(".") }

    private static let trashFolder = ".Trash"

    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: - 路径

    func url(for id: String) -> URL {
        id.isEmpty ? root : root.appendingPathComponent(id)
    }

    /// 反过来：一个 URL 对应的节点 id。不在树内返回 nil。
    func id(for url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }

    // MARK: - 读

    func node(at id: String) -> DriveNode? {
        guard !id.isEmpty else {
            return DriveNode(
                id: Self.rootID, parentId: nil, kind: .folder,
                name: R.Strings.tabFiles.localizedString(), size: 0,
                updatedAt: Date())
        }
        let url = self.url(for: id)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return makeNode(at: url)
    }

    func list(in folderID: String, sort: NodeSort, order: SortOrder) throws -> [DriveNode] {
        let directory = url(for: folderID)
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let nodes = entries
            .filter { !isHidden($0.lastPathComponent) }
            .compactMap { makeNode(at: $0) }
        return sorted(nodes, by: sort, order: order)
    }

    /// 面包屑。从根到该目录（含自身）。
    func ancestors(of folderID: String) -> [DriveNode] {
        var trail: [DriveNode] = []
        var current = folderID
        while !current.isEmpty {
            if let node = node(at: current) { trail.insert(node, at: 0) }
            let parent = (current as NSString).deletingLastPathComponent
            current = parent == "." ? "" : parent
        }
        if let rootNode = node(at: Self.rootID) { trail.insert(rootNode, at: 0) }
        return trail
    }

    /// 递归搜索。本地树没有分页，直接走完——手机上的收件盘规模不值得为它做游标。
    func search(under folderID: String, query: String) -> [DriveNode] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var found: [DriveNode] = []
        let base = url(for: folderID)
        guard
            let walker = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        for case let url as URL in walker {
            guard !isHidden(url.lastPathComponent) else { continue }
            guard url.lastPathComponent.lowercased().contains(needle) else { continue }
            if let node = makeNode(at: url) { found.append(node) }
        }
        return found
    }

    // MARK: - 写

    @discardableResult
    func createFolder(in parentID: String, name: String) throws -> DriveNode {
        let safe = FileNameSanitizer.sanitize(name)
        let parent = url(for: parentID)
        let unique = FileNameSanitizer.uniqueName(for: safe, in: parent)
        let target = parent.appendingPathComponent(unique, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        return makeNode(at: target) ?? node(at: id(for: target) ?? "")!
    }

    func rename(_ node: DriveNode, to name: String) throws {
        let source = url(for: node.id)
        let parent = source.deletingLastPathComponent()
        let safe = FileNameSanitizer.sanitize(name)
        guard safe != node.name else { return }
        let unique = FileNameSanitizer.uniqueName(for: safe, in: parent)
        try fm.moveItem(at: source, to: parent.appendingPathComponent(unique))
    }

    func move(_ node: DriveNode, to parentID: String) throws {
        let source = url(for: node.id)
        let destination = url(for: parentID)
        let unique = FileNameSanitizer.uniqueName(for: node.name, in: destination)
        try fm.moveItem(at: source, to: destination.appendingPathComponent(unique))
    }

    func copy(_ node: DriveNode, to parentID: String) throws {
        let source = url(for: node.id)
        let destination = url(for: parentID)
        let unique = FileNameSanitizer.uniqueName(for: node.name, in: destination)
        try fm.copyItem(at: source, to: destination.appendingPathComponent(unique))
    }

    /**
     移入回收站。

     真删是不可逆的，而这条路径连着的是别人发来的文件——误触的代价太高。移到
     `Documents/.Trash/`：点开头，所以不出现在树里，也不出现在「文件」App 里，
     但东西还在。回收站界面在改造中被拆掉了，等它回来时这里不用改。
     */
    func moveToTrash(_ node: DriveNode) throws {
        let trash = root.appendingPathComponent(Self.trashFolder, isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let unique = FileNameSanitizer.uniqueName(for: node.name, in: trash)
        try fm.moveItem(at: url(for: node.id), to: trash.appendingPathComponent(unique))
    }

    /// 系统「打开方式」送进来的文件：拷进树里，原文件不动。
    @discardableResult
    func importFile(at source: URL, into parentID: String) throws -> DriveNode {
        let destination = url(for: parentID)
        let safe = FileNameSanitizer.sanitize(source.lastPathComponent)
        let unique = FileNameSanitizer.uniqueName(for: safe, in: destination)
        let target = destination.appendingPathComponent(unique)

        // Files/iCloud 交来的 URL 多半在沙盒外，要先取用权限再拷。
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try fm.copyItem(at: source, to: target)
        return makeNode(at: target)!
    }

    // MARK: - 内部

    private func makeNode(at url: URL) -> DriveNode? {
        guard let id = id(for: url), !id.isEmpty else { return nil }
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        let isFolder = values?.isDirectory ?? false
        let parent = (id as NSString).deletingLastPathComponent
        return DriveNode(
            id: id,
            parentId: parent == "." ? "" : parent,
            kind: isFolder ? .folder : .file,
            name: url.lastPathComponent,
            size: Int64(values?.fileSize ?? 0),
            updatedAt: values?.contentModificationDate ?? Date()
        )
    }

    /// 文件夹恒在文件之前，和改造前服务端的排序一致。
    private func sorted(_ nodes: [DriveNode], by sort: NodeSort, order: SortOrder)
        -> [DriveNode]
    {
        let ascending = order == .ascending
        return nodes.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let result: Bool
            switch sort {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .updated:
                result = a.updatedAt < b.updatedAt
            case .size:
                result = a.size < b.size
            }
            return ascending ? result : !result
        }
    }
}
