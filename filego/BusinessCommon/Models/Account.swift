import Foundation

/// 与服务端 `/auth/*` 的 data 对齐。
struct AuthSession: Decodable {
    let accessToken: String
    let refreshToken: String
    /// access token 有效秒数，用于提前刷新
    let expiresIn: Int
    /// `/auth/refresh` 只返回令牌，不带 user
    let user: AccountUser?
}

struct AccountUser: Decodable {
    let id: String
    let email: String?
    let displayName: String?
    /// 服务端下发 ISO 8601 字符串，由 `JSONDecoder.fileGo` 解成 Date
    let createdAt: Date?
}

/// 与 `GET /me` 的 data 对齐。
struct AccountProfile: Decodable {
    let user: AccountUser
    let rootNodeId: String
    let storage: StorageUsage
    let counts: ItemCounts
    /// 档位摘要。可选：老服务端不返回这个字段，缺失时按免费档处理。
    let plan: AccountPlan?

    var isPro: Bool { plan?.isPro ?? false }
}

struct ItemCounts: Decodable {
    let files: Int
    let folders: Int
    let trashed: Int
}

/// 存储用量。配额是服务端强制的硬上限，客户端这份只用于展示与上传前的本地预检。
struct StorageUsage: Decodable {
    let quotaBytes: Int64
    let usedBytes: Int64
    /// 在途上传已预留的字节数，见规划 §2.3
    let reservedBytes: Int64
    let availableBytes: Int64
    /// 按类型的占用明细。旧版服务端可能不返回，缺失时按 0 处理。
    let breakdown: Breakdown?

    /// 回收站里的文件仍然占配额（见规划 §2），所以这里要能单独展示、引导用户去清空。
    struct Breakdown: Decodable {
        let images: Int64
        let videos: Int64
        let audio: Int64
        let documents: Int64
        let trash: Int64
    }

    var trashBytes: Int64 { breakdown?.trash ?? 0 }

    /// 进度条用。分母为 0 时返回 0，避免除零。
    var usedFraction: Double {
        guard quotaBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(quotaBytes))
    }

    /// 含在途预留的占用比例，进度条上可以画成一段浅色。
    var committedFraction: Double {
        guard quotaBytes > 0 else { return 0 }
        return min(1, Double(usedBytes + reservedBytes) / Double(quotaBytes))
    }

    /// 本地预检：这个大小还塞得下吗。服务端判定才是权威，这里只为快速失败。
    func canAccommodate(_ byteCount: Int64) -> Bool {
        byteCount <= availableBytes
    }

    static let empty = StorageUsage(
        quotaBytes: 0,
        usedBytes: 0,
        reservedBytes: 0,
        availableBytes: 0,
        breakdown: nil
    )
}
