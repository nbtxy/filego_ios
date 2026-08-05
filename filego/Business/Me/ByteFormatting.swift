import Foundation

/// 「我的」相关页面共用的字节格式化。
///
/// 配额是 10 GiB，必须用二进制单位口径才和服务端的数字对得上。
enum ByteFormatting {
    static func string(_ byteCount: Int64) -> String {
        formatter.string(fromByteCount: byteCount)
    }

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}
