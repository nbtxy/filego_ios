import Foundation

/**
 字节格式化。两个口径，按被量的东西分——不是手误。

 配额是服务端定下的额度与上限——中转额度、单个文件上限——本来就以 GiB 为单位
 （`limits.ts` 里的 `3 * 1024 ** 3`、`2 * 1024 ** 3`），只有二进制口径才能把它显示回
 整数「3 GB」「2 GB」；换成十进制会变成「3.22 GB」「2.15 GB」，谁也没规定过的数。

 占用量的参照物则是设备本身：系统「文件」App、「设置」里的用量、以及 Drive 列表里
 逐个文件显示的体积（`DriveNodeCell`）都是十进制。侧栏的总计要能和列表里的文件加得
 起来，就必须跟它们同一套——GB 级别上两套差 7%，足够让人觉得数字是错的。
 */
enum ByteFormatting {
    /// 中转额度。二进制，对齐服务端的 GiB 定义。
    static func quota(_ byteCount: Int64) -> String {
        quotaFormatter.string(fromByteCount: byteCount)
    }

    /// 磁盘占用与文件体积。十进制，对齐系统「文件」App。
    static func storage(_ byteCount: Int64) -> String {
        storageFormatter.string(fromByteCount: byteCount)
    }

    private static let quotaFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    private static let storageFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // 带上 .useBytes：空盘走 KB 会显示成「Zero KB」，读起来像出了错。
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter
    }()
}
