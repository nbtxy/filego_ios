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

    /**
     专属接收文件夹的 id（`Documents/Received`）。

     这台设备唯一的收件地址 `<name>.stolnk.com` 收到的文件都落在这里。它不出现在根目录
     的网格里——入口是 Drive 首页左下角那个按钮——也不能被改名、移动或删除：
     `StolnkController` 的绑定以它的路径为准，挪走了下一个文件就没处落。磁盘上的名字
     固定为英文，显示名走本地化（`drive.received.title`）。
     */
    static let receivedID = "Received"

    static func isReceived(_ id: String) -> Bool { id == receivedID }

    /**
     `Documents/Inbox/` 是 iOS 给 App 投递「用 Stolnk 打开」文件的系统目录。
     它归系统管，App 删除整个文件夹会被拒绝，也不该出现在用户的文件树里。
     里面的文件在 `handleIncomingFile` 导入后被删掉，只留下这个空目录。
     */
    static let systemInboxID = "Inbox"

    static func isSystemInbox(_ id: String) -> Bool {
        id.caseInsensitiveCompare(systemInboxID) == .orderedSame
    }

    let root: URL
    private let fm = FileManager.default

    /// 收件过程中的 `.part` 文件由 `FileLanding` 以点开头命名，落地前对用户不可见。
    /// 这里统一跳过点开头的条目，顺带也把回收站挡在外面。
    private func isHidden(_ name: String) -> Bool { name.hasPrefix(".") }

    /**
     回收站目录名。

     **不能叫 `.Trash`。** 开着 `UIFileSharingEnabled` 时，iOS「文件」App 会把
     App 的 Documents 当成“我的 iPhone”下的一个目录，并在里面用 `.Trash` 存
     “最近删除”。真机上这个目录由系统管理，App 往里写会得到
     “没有权限访问 .Trash”，连删普通文件夹都会失败。所以用自己的隐藏目录。
     */
    private nonisolated static let trashFolder = ".StolnkTrash"
    /// 旧版本用过的名字；升级时尽量整体搬走。
    private nonisolated static let legacyTrashFolder = ".Trash"

    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: self.root.appendingPathComponent(Self.receivedID, isDirectory: true),
            withIntermediateDirectories: true)
        migrateLegacyTrash()
    }

    /**
     旧版本的回收站是 `Documents/.Trash`。如果它还是 App 自己的目录，整体改名成
     `.StolnkTrash`（索引文件跟着走）；如果已经被系统接管、搬不动，就留着不动，
     新回收站从空开始——继续用旧目录才是那个无权限错误的来源。
     */
    private func migrateLegacyTrash() {
        let legacy = root.appendingPathComponent(Self.legacyTrashFolder, isDirectory: true)
        let current = trashURL
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: current.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: current)
        } catch {
            AppLogger.warning("旧回收站 .Trash 无法迁移（可能已由系统管理）：\(error.localizedDescription)")
            // 建一个空的新回收站，免得每次启动都去撞同一个权限错误。
            try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        }
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
            // 接收文件夹只从左下角入口进；系统投递的 Inbox 不归用户管，都不显示。
            .filter { !Self.isReceived($0.id) && !Self.isSystemInbox($0.id) }
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
            if let node = makeNode(at: url), !Self.isSystemInbox(node.id) {
                found.append(node)
            }
        }
        return found
    }

    // MARK: - 写

    @discardableResult
    func createFolder(in parentID: String, name: String) throws -> DriveNode {
        let safe = Self.avoidingSystemInbox(FileNameSanitizer.sanitize(name))
        let parent = url(for: parentID)
        let unique = FileNameSanitizer.uniqueName(for: safe, in: parent)
        let target = parent.appendingPathComponent(unique, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        return makeNode(at: target) ?? node(at: id(for: target) ?? "")!
    }

    /// 接收文件夹与系统投递目录都不是用户能改的：它们的路径有外部含义。
    private func refuseIfProtected(_ node: DriveNode) throws {
        if Self.isReceived(node.id) || Self.isSystemInbox(node.id) {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// `Inbox` 这个名字留给 iOS 的系统投递目录，用户建同名文件夹会被改名。
    private static func avoidingSystemInbox(_ name: String) -> String {
        isSystemInbox(name) ? "\(name) 2" : name
    }

    func rename(_ node: DriveNode, to name: String) throws {
        try refuseIfProtected(node)
        let source = url(for: node.id)
        let parent = source.deletingLastPathComponent()
        let safe = Self.avoidingSystemInbox(FileNameSanitizer.sanitize(name))
        guard safe != node.name else { return }
        let unique = FileNameSanitizer.uniqueName(for: safe, in: parent)
        try fm.moveItem(at: source, to: parent.appendingPathComponent(unique))
    }

    func move(_ node: DriveNode, to parentID: String) throws {
        try refuseIfProtected(node)
        let source = url(for: node.id)
        let destination = url(for: parentID)
        let unique = FileNameSanitizer.uniqueName(for: node.name, in: destination)
        try fm.moveItem(at: source, to: destination.appendingPathComponent(unique))
    }

    // MARK: - 压缩与解压

    nonisolated static func canExtract(fileName: String) -> Bool {
        ArchiveService.canExtract(fileName: fileName)
    }

    @discardableResult
    func compress(
        _ nodes: [DriveNode],
        in folderID: String,
        defaultArchiveName: String
    ) async throws -> DriveNode {
        guard !nodes.isEmpty else { throw ArchiveService.ArchiveError.emptySelection }
        for node in nodes { try refuseIfProtected(node) }

        let destinationDir = url(for: folderID)
        let rawBaseName: String
        if nodes.count == 1, let single = nodes.first {
            if single.isFolder {
                rawBaseName = single.name
            } else {
                let stripped = (single.name as NSString).deletingPathExtension
                rawBaseName = stripped.isEmpty ? single.name : stripped
            }
        } else {
            rawBaseName = defaultArchiveName
        }
        let safeZipName = FileNameSanitizer.sanitize(rawBaseName) + ".zip"
        let uniqueZipName = FileNameSanitizer.uniqueName(for: safeZipName, in: destinationDir)
        let targetZipURL = destinationDir.appendingPathComponent(uniqueZipName)
        let sourceURLs = nodes.map { url(for: $0.id) }

        try await Task.detached(priority: .userInitiated) {
            try ArchiveService.compress(sources: sourceURLs, to: targetZipURL)
        }.value

        guard let created = makeNode(at: targetZipURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return created
    }

    @discardableResult
    func extract(_ node: DriveNode) async throws -> DriveNode {
        try refuseIfProtected(node)
        let archiveURL = url(for: node.id)
        let parentID = node.parentId ?? Self.rootID
        let destinationDir = url(for: parentID)
        let folderBaseName = FileNameSanitizer.sanitize(
            ArchiveService.baseName(forArchive: node.name)
        )

        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("stolnk-extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingDir) }

        try await Task.detached(priority: .userInitiated) {
            try ArchiveService.extract(archiveAt: archiveURL, into: stagingDir)
        }.value

        let topEntries = try fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).filter {
            let name = $0.lastPathComponent
            return name != "__MACOSX" && name != ".DS_Store" && !name.hasPrefix("._")
        }

        guard !topEntries.isEmpty else {
            AppLogger.warning("解压后未产出任何文件：\(node.name)（\(node.size) B）")
            throw ArchiveService.ArchiveError.emptyArchive
        }

        let landedURL: URL
        if topEntries.count == 1, let only = topEntries.first {
            let safeName = Self.avoidingSystemInbox(
                FileNameSanitizer.sanitize(only.lastPathComponent)
            )
            let uniqueName = FileNameSanitizer.uniqueName(for: safeName, in: destinationDir)
            landedURL = destinationDir.appendingPathComponent(uniqueName)
            try fm.moveItem(at: only, to: landedURL)
        } else {
            let safeFolder = Self.avoidingSystemInbox(
                folderBaseName.isEmpty ? "Archive" : folderBaseName
            )
            let uniqueFolder = FileNameSanitizer.uniqueName(for: safeFolder, in: destinationDir)
            landedURL = destinationDir.appendingPathComponent(uniqueFolder, isDirectory: true)
            try fm.createDirectory(at: landedURL, withIntermediateDirectories: false)
            for item in topEntries {
                let safeItem = FileNameSanitizer.sanitize(item.lastPathComponent)
                let uniqueItem = FileNameSanitizer.uniqueName(for: safeItem, in: landedURL)
                try fm.moveItem(at: item, to: landedURL.appendingPathComponent(uniqueItem))
            }
        }

        guard let created = makeNode(at: landedURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return created
    }

    /**
     移入回收站。

     真删是不可逆的，而这条路径连着的是别人发来的文件——误触的代价太高。移到
     `Documents/.StolnkTrash/`：点开头，所以不出现在树里，也不出现在「文件」App 里，
     但东西还在。

     移动本身不记录任何东西：`moveItem` 保留的是文件原来的修改时间，不是入站时间，
     原路径更是直接丢掉。「还有 N 天」和「还原」两件事都要这两个信息，所以同时往
     索引里写一条。见 `reconcileTrashIndex`。
     */
    func moveToTrash(_ node: DriveNode) throws {
        try refuseIfProtected(node)
        try fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let unique = FileNameSanitizer.uniqueName(for: node.name, in: trashURL)
        try fm.moveItem(at: url(for: node.id), to: trashURL.appendingPathComponent(unique))
        var index = readTrashIndex()
        index[unique] = TrashIndexEntry(
            name: node.name,
            originParentID: node.parentId ?? Self.rootID,
            isFolder: node.isFolder,
            trashedAt: Date()
        )
        writeTrashIndex(index)
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

    // MARK: - 回收站

    /**
     保留期。

     和系统「文件」App、iCloud、Finder 废纸篓一致，用户对这个数字有现成的预期。
     `trash.notice` 里的天数由这里填，改一处就够。
     */
    static let trashRetentionDays = 30

    private static let trashIndexFile = ".index.json"

    /// 索引里一条。`storageName` 是 key，不进 value。
    private struct TrashIndexEntry: Codable {
        var name: String
        var originParentID: String
        var isFolder: Bool
        var trashedAt: Date
    }

    private var trashURL: URL {
        root.appendingPathComponent(Self.trashFolder, isDirectory: true)
    }

    /// 回收站内容，新删的在前——用户找的多半是刚误删的那个。
    func trashItems() -> [TrashItem] {
        reconcileTrashIndex()
            .map { name, entry in
                TrashItem(
                    storageName: name,
                    name: entry.name,
                    originParentID: entry.originParentID,
                    kind: entry.isFolder ? .folder : .file,
                    size: Self.size(of: trashURL.appendingPathComponent(name)),
                    trashedAt: entry.trashedAt
                )
            }
            .sorted { $0.trashedAt > $1.trashedAt }
    }

    /**
     还原。

     原目录可能在这期间被删了或改了名。重建它会凭空造出一个用户已经不认识的文件夹，
     所以回落到根目录：东西一定找得到，比「还原成功但不知道去了哪」好。返回值是真正
     的落点，回落时它和 `originParentID` 不相等——目前还没有文案把这件事告诉用户。
     */
    @discardableResult
    func restoreFromTrash(_ item: TrashItem) throws -> String {
        var parentID = item.originParentID
        var parent = url(for: parentID)
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: parent.path, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            parentID = Self.rootID
            parent = root
        }
        let unique = FileNameSanitizer.uniqueName(for: item.name, in: parent)
        try fm.moveItem(
            at: trashURL.appendingPathComponent(item.storageName),
            to: parent.appendingPathComponent(unique)
        )
        var index = readTrashIndex()
        index.removeValue(forKey: item.storageName)
        writeTrashIndex(index)
        return parentID
    }

    func deleteFromTrash(_ item: TrashItem) throws {
        try fm.removeItem(at: trashURL.appendingPathComponent(item.storageName))
        var index = readTrashIndex()
        index.removeValue(forKey: item.storageName)
        writeTrashIndex(index)
    }

    /// 清空。索引整份丢掉，不逐条删——反正对账时磁盘说了算。
    func emptyTrash() throws {
        for name in trashContents() {
            try fm.removeItem(at: trashURL.appendingPathComponent(name))
        }
        writeTrashIndex([:])
    }

    /**
     删掉过了保留期的项，返回删了几个。

     iOS 上没有能指望的后台定时器，所以这是惰性清理：app 启动时和进回收站页面时各扫
     一次。长期不开 app 的话文件会多占一阵子空间，和 `trash.notice` 承诺的「N 天后」
     有出入——系统「文件」App 同样如此，没有更好的办法。
     */
    @discardableResult
    func purgeExpiredTrash(now: Date = Date()) -> Int {
        var index = reconcileTrashIndex()
        var removed = 0
        for (name, entry) in index where Self.trashDaysLeft(since: entry.trashedAt, now: now) <= 0 {
            do {
                try fm.removeItem(at: trashURL.appendingPathComponent(name))
                index.removeValue(forKey: name)
                removed += 1
            } catch {
                AppLogger.error("清理过期回收站项目失败：\(name)", error: error)
            }
        }
        if removed > 0 {
            writeTrashIndex(index)
            AppLogger.info("回收站清理了 \(removed) 项过期内容")
        }
        return removed
    }

    /**
     还剩几天。

     向上取整，且非零即至少 1：刚删的当天显示「还有 30 天」，最后一天显示「还有 1 天」，
     返回 0 就是该删了。要是向下取整，东西还在列表里却写着「还有 0 天」。
     */
    static func trashDaysLeft(since trashedAt: Date, now: Date = Date()) -> Int {
        let deadline = trashedAt.addingTimeInterval(TimeInterval(trashRetentionDays) * 86_400)
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return max(1, Int((remaining / 86_400).rounded(.up)))
    }

    /**
     项数与占用。

     「我的」页要在后台线程上算，所以不碰实例状态，也不读索引——数量按磁盘上的条目数，
     和列表看到的一致。
     */
    nonisolated static func trashUsage(at root: URL) -> (count: Int, bytes: Int64) {
        let trash = root.appendingPathComponent(trashFolder, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        let bytes = names.reduce(into: Int64(0)) { total, name in
            total += size(of: trash.appendingPathComponent(name))
        }
        return (names.count, bytes)
    }

    /**
     索引和磁盘对账，磁盘说了算。

     索引是后加的，回收站里可能已经躺着旧版本丢进去的文件；开着
     `UIFileSharingEnabled`，用户也可能从别处动过目录。条目对不上文件就丢掉，文件没有
     条目就按它自己的修改时间补一条——原位置无从得知，还原只能回落到根目录。
     */
    private func reconcileTrashIndex() -> [String: TrashIndexEntry] {
        var index = readTrashIndex()
        let names = Set(trashContents())
        var changed = false

        for name in index.keys where !names.contains(name) {
            index.removeValue(forKey: name)
            changed = true
        }
        for name in names where index[name] == nil {
            let url = trashURL.appendingPathComponent(name)
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey])
            index[name] = TrashIndexEntry(
                name: name,
                originParentID: Self.rootID,
                isFolder: values?.isDirectory ?? false,
                trashedAt: values?.contentModificationDate ?? Date()
            )
            changed = true
        }

        if changed { writeTrashIndex(index) }
        return index
    }

    /// 回收站目录下的条目名。索引文件自己是点开头的，顺带被挡掉。
    private func trashContents() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: trashURL.path)) ?? [])
            .filter { !isHidden($0) }
    }

    private func readTrashIndex() -> [String: TrashIndexEntry] {
        let url = trashURL.appendingPathComponent(Self.trashIndexFile)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: TrashIndexEntry].self, from: data)
        } catch {
            // 索引坏了不是绝症：对账会按磁盘重建一份，代价只是丢掉原位置和入站时间。
            AppLogger.error("回收站索引读取失败，按磁盘重建", error: error)
            return [:]
        }
    }

    private func writeTrashIndex(_ index: [String: TrashIndexEntry]) {
        let url = trashURL.appendingPathComponent(Self.trashIndexFile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
            try encoder.encode(index).write(to: url, options: .atomic)
        } catch {
            AppLogger.error("回收站索引写入失败", error: error)
        }
    }

    /// 文件夹要递归求和：`fileSize` 对目录只会给出目录项自己的大小。
    private nonisolated static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            let childValues = try? child.resourceValues(forKeys: Set(keys))
            guard childValues?.isRegularFile == true else { continue }
            total += Int64(childValues?.fileSize ?? 0)
        }
        return total
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
            name: Self.isReceived(id)
                ? R.Strings.driveReceivedTitle.localizedString()
                : url.lastPathComponent,
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
