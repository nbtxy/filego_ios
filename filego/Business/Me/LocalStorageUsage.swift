import Foundation

/**
 本机占用的一次快照。

 改造前这份数据来自 `GET /me`，分母是服务端下发的配额；现在没有账号也没有配额了，
 分母换成设备磁盘容量，数字全部由一次本地目录遍历得出。

 `nonisolated`：本 target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
 不写的话这个类型连同 `scan` 都会绑上主线程，`Task.detached` 里就用不了了。
 */
nonisolated struct LocalStorageUsage {
    /// 设备总容量。
    var capacityBytes: Int64 = 0
    /// 设备可用容量。取 importantUsage 口径——它是系统真正愿意腾出来给用户数据的数，
    /// 和「设置」里显示的可用空间对得上。
    var availableBytes: Int64 = 0
    /// 本 App 在 `Documents/` 下的总占用。等于下面各分类之和。
    var usedBytes: Int64 = 0

    var imageBytes: Int64 = 0
    var videoBytes: Int64 = 0
    var audioBytes: Int64 = 0
    var documentBytes: Int64 = 0
    /// 在途接收的 `.part`，还没落地成可见文件，但已经占着磁盘。
    var reservedBytes: Int64 = 0
    var trashBytes: Int64 = 0

    var files = 0
    var folders = 0
    var trashedCount = 0

    static let empty = LocalStorageUsage()

    /// 分类。明细行、图例圆点、堆叠条上的分段共用这一个枚举——三处对不上就白画了。
    enum Category: CaseIterable {
        case images, videos, audio, documents, reserved, trash
    }

    func bytes(of category: Category) -> Int64 {
        switch category {
        case .images: return imageBytes
        case .videos: return videoBytes
        case .audio: return audioBytes
        case .documents: return documentBytes
        case .reserved: return reservedBytes
        case .trash: return trashBytes
        }
    }

    /// 堆叠条用。按渲染顺序给出非零的分段。
    var segments: [(category: Category, bytes: Int64)] {
        Category.allCases.map { ($0, bytes(of: $0)) }.filter { $0.1 > 0 }
    }

    /**
     走一遍 `Documents/`。

     `.Trash/` 不在这里展开：回收站的口径已经由
     `LocalDriveStore.trashUsage(at:)` 定下（只数顶层条目、跳过 `.index.json`），
     两处各走一遍必然对不上。这里直接用它的结果。
     */
    static func scan(root: URL) -> LocalStorageUsage {
        var usage = LocalStorageUsage()

        let volume = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ])
        usage.capacityBytes = Int64(volume?.volumeTotalCapacity ?? 0)
        usage.availableBytes = volume?.volumeAvailableCapacityForImportantUsage ?? 0

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        if let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys)
        {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                let hidden = name.hasPrefix(".")

                if values?.isDirectory == true {
                    // 点开头的目录（`.Trash/` 在内）对用户不可见，也不该计进文件夹数。
                    if hidden { walker.skipDescendants() } else { usage.folders += 1 }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                let size = Int64(values?.fileSize ?? 0)

                if hidden {
                    // 落地中的 `.stolnk-<fileID>.part`，见 StolnkCore 的 Receiver。
                    if name.hasSuffix(".part") { usage.reservedBytes += size }
                    continue
                }

                usage.files += 1
                switch FileKind(fileName: name) {
                case .image: usage.imageBytes += size
                case .video: usage.videoBytes += size
                case .audio: usage.audioBytes += size
                default: usage.documentBytes += size
                }
            }
        }

        let trash = LocalDriveStore.trashUsage(at: root)
        usage.trashedCount = trash.count
        usage.trashBytes = trash.bytes

        usage.usedBytes =
            usage.imageBytes + usage.videoBytes + usage.audioBytes
            + usage.documentBytes + usage.reservedBytes + usage.trashBytes
        return usage
    }
}
