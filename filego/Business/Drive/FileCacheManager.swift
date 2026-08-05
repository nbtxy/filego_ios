import CryptoKit
import Foundation
import GRDB

/// 文件内容磁盘缓存。索引与内容都放在 Library/Caches，不参与备份，允许系统在空间紧张时清理。
/// 以「后端环境 + 用户 + blobId」隔离；blobId 表示内容版本，重命名/移动不会造成重复下载。
actor FileCacheManager {
    static let shared = FileCacheManager()
    static let capacityBytes: Int64 = 1_073_741_824

    struct Statistics: Sendable {
        let bytes: Int64
        let fileCount: Int
    }

    private let rootDirectory: URL
    private let database: DatabaseQueue?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        rootDirectory = caches.appendingPathComponent("FileGoCache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            let queue = try DatabaseQueue(
                path: rootDirectory.appendingPathComponent("index.sqlite").path
            )
            var migrator = DatabaseMigrator()
            migrator.registerMigration("createFileCache") { db in
                try db.create(table: "file_cache", ifNotExists: true) { table in
                    table.column("namespace", .text).notNull()
                    table.column("user_id", .text).notNull()
                    table.column("blob_id", .text).notNull()
                    table.column("node_id", .text).notNull()
                    table.column("relative_path", .text).notNull()
                    table.column("size", .integer).notNull()
                    table.column("last_access", .double).notNull()
                    table.primaryKey(["namespace", "user_id", "blob_id"])
                }
                try db.create(
                    index: "file_cache_lru",
                    on: "file_cache",
                    columns: ["namespace", "user_id", "last_access"],
                    ifNotExists: true
                )
            }
            try migrator.migrate(queue)
            database = queue
        } catch {
            database = nil
            AppLogger.error("初始化文件缓存失败", error: error)
        }
    }

    func isAvailable() -> Bool { database != nil }

    /// 命中缓存时创建一个指向缓存内容的临时硬链接，交给现有预览生命周期管理。
    /// 淘汰缓存只会删缓存目录项，不会影响正在预览的硬链接。
    func materializePreview(
        for node: DriveNode,
        userID: String,
        baseURL: URL
    ) -> URL? {
        guard let database, let blobID = node.blobId else { return nil }
        let namespace = Self.namespace(for: baseURL)
        do {
            guard let row = try database.read({ db in
                try GRDB.Row.fetchOne(
                    db,
                    sql: """
                    SELECT relative_path, size FROM file_cache
                    WHERE namespace = ? AND user_id = ? AND blob_id = ?
                    """,
                    arguments: [namespace, userID, blobID]
                )
            }) else { return nil }

            let relativePath: String = row["relative_path"]
            let storedSize: Int64 = row["size"]
            let source = rootDirectory.appendingPathComponent(relativePath)
            guard storedSize == node.size, Self.fileSize(at: source) == storedSize else {
                try removeEntry(
                    namespace: namespace,
                    userID: userID,
                    blobID: blobID,
                    relativePath: relativePath
                )
                return nil
            }

            try database.write { db in
                try db.execute(
                    sql: """
                    UPDATE file_cache SET node_id = ?, last_access = ?
                    WHERE namespace = ? AND user_id = ? AND blob_id = ?
                    """,
                    arguments: [node.id, Date().timeIntervalSince1970, namespace, userID, blobID]
                )
            }
            return try makePreviewLink(from: source, fileName: node.name)
        } catch {
            AppLogger.error("读取文件缓存失败", error: error)
            return nil
        }
    }

    func storeDownloadedFile(
        at downloadedURL: URL,
        node: DriveNode,
        userID: String,
        baseURL: URL
    ) throws {
        guard let database, let blobID = node.blobId else { return }
        let actualSize = Self.fileSize(at: downloadedURL)
        guard actualSize == node.size else { throw FileDownloadService.Failure.invalidResponse }

        let namespace = Self.namespace(for: baseURL)
        let relativePath = "files/\(Self.digest(namespace))/\(Self.digest(userID))/\(Self.digest(blobID))/content"
        let destination = rootDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: destination)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO file_cache
                    (namespace, user_id, blob_id, node_id, relative_path, size, last_access)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(namespace, user_id, blob_id) DO UPDATE SET
                    node_id = excluded.node_id,
                    relative_path = excluded.relative_path,
                    size = excluded.size,
                    last_access = excluded.last_access
                """,
                arguments: [
                    namespace, userID, blobID, node.id, relativePath,
                    actualSize, Date().timeIntervalSince1970
                ]
            )
        }
        try trim(namespace: namespace, userID: userID)
    }

    func statistics(userID: String, baseURL: URL) -> Statistics {
        guard let database else { return Statistics(bytes: 0, fileCount: 0) }
        let namespace = Self.namespace(for: baseURL)
        do {
            let rows = try database.read { db in
                try GRDB.Row.fetchAll(
                    db,
                    sql: """
                    SELECT blob_id, relative_path, size FROM file_cache
                    WHERE namespace = ? AND user_id = ?
                    """,
                    arguments: [namespace, userID]
                )
            }
            var bytes: Int64 = 0
            var count = 0
            for row in rows {
                let blobID: String = row["blob_id"]
                let relativePath: String = row["relative_path"]
                let size: Int64 = row["size"]
                let url = rootDirectory.appendingPathComponent(relativePath)
                if Self.fileSize(at: url) == size {
                    bytes += size
                    count += 1
                } else {
                    try removeEntry(
                        namespace: namespace,
                        userID: userID,
                        blobID: blobID,
                        relativePath: relativePath
                    )
                }
            }
            return Statistics(bytes: bytes, fileCount: count)
        } catch {
            AppLogger.error("统计文件缓存失败", error: error)
            return Statistics(bytes: 0, fileCount: 0)
        }
    }

    func removeAll(userID: String, baseURL: URL? = nil) {
        guard let database else { return }
        do {
            let namespace = baseURL.map(Self.namespace(for:))
            let rows = try database.read { db in
                if let namespace {
                    return try GRDB.Row.fetchAll(
                        db,
                        sql: "SELECT relative_path FROM file_cache WHERE namespace = ? AND user_id = ?",
                        arguments: [namespace, userID]
                    )
                }
                return try GRDB.Row.fetchAll(
                    db,
                    sql: "SELECT relative_path FROM file_cache WHERE user_id = ?",
                    arguments: [userID]
                )
            }
            for row in rows {
                let relativePath: String = row["relative_path"]
                try? FileManager.default.removeItem(
                    at: rootDirectory.appendingPathComponent(relativePath).deletingLastPathComponent()
                )
            }
            try database.write { db in
                if let namespace {
                    try db.execute(
                        sql: "DELETE FROM file_cache WHERE namespace = ? AND user_id = ?",
                        arguments: [namespace, userID]
                    )
                } else {
                    try db.execute(
                        sql: "DELETE FROM file_cache WHERE user_id = ?",
                        arguments: [userID]
                    )
                }
            }
        } catch {
            AppLogger.error("清理文件缓存失败", error: error)
        }
    }

    static func downloadKey(blobID: String, userID: String, baseURL: URL) -> String {
        "\(namespace(for: baseURL))|\(userID)|\(blobID)"
    }

    private func trim(namespace: String, userID: String) throws {
        guard let database else { return }
        let rows = try database.read { db in
            try GRDB.Row.fetchAll(
                db,
                sql: """
                SELECT blob_id, relative_path, size FROM file_cache
                WHERE namespace = ? AND user_id = ? ORDER BY last_access ASC
                """,
                arguments: [namespace, userID]
            )
        }
        var total: Int64 = 0
        for row in rows {
            let size: Int64 = row["size"]
            total += size
        }
        for row in rows where total > Self.capacityBytes {
            let blobID: String = row["blob_id"]
            let relativePath: String = row["relative_path"]
            let size: Int64 = row["size"]
            try removeEntry(
                namespace: namespace,
                userID: userID,
                blobID: blobID,
                relativePath: relativePath
            )
            total -= size
        }
    }

    private func removeEntry(
        namespace: String,
        userID: String,
        blobID: String,
        relativePath: String
    ) throws {
        try? FileManager.default.removeItem(
            at: rootDirectory.appendingPathComponent(relativePath).deletingLastPathComponent()
        )
        try database?.write { db in
            try db.execute(
                sql: """
                DELETE FROM file_cache
                WHERE namespace = ? AND user_id = ? AND blob_id = ?
                """,
                arguments: [namespace, userID, blobID]
            )
        }
    }

    private func makePreviewLink(from source: URL, fileName: String) throws -> URL {
        let directory = PreviewTemporaryFile.rootDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lastPathComponent = URL(fileURLWithPath: fileName).lastPathComponent
        let safeName = lastPathComponent.isEmpty ? "file" : lastPathComponent
        let destination = directory.appendingPathComponent(safeName)
        do {
            try FileManager.default.linkItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }

    private static func namespace(for baseURL: URL) -> String {
        baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
