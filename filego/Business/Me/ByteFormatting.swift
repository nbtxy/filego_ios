import Foundation

/// 「我的」相关页面共用的字节格式化。
///
/// 服务端的配额是二进制进制的（见 src/lib/plans.ts），这里必须用同一口径，
/// 否则 50 GiB 会显示成 53.69 GB。
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
