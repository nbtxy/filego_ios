import Foundation

/// 当前档位。与服务端 `/billing/status`、`/billing/verify` 的 data 对齐。
struct BillingStatus: Decodable {
    let plan: String
    /// 到期时间。宽限期已并入——服务端存的是 max(到期日, 宽限期截止)。
    let expiresAt: Date?
    let autoRenew: Bool
    /// 续费失败但仍在 Apple 给的宽限窗口内。用于设置页提示横幅。
    let inGracePeriod: Bool
    let productId: String?
    let environment: String?
    let storage: BillingStorage
    /// 两档额度常量，由服务端下发。可选：老服务端不返回，此时退到 `Fallback`。
    let tiers: Tiers?

    var isPro: Bool { plan == "pro" }

    struct BillingStorage: Decodable {
        let quotaBytes: Int64
        let usedBytes: Int64
        let reservedBytes: Int64
    }

    struct Tiers: Decodable {
        let freeBytes: Int64
        let proBytes: Int64
    }

    /// 仅在「还没拉到 /billing/status」或对接老服务端时兜底。
    ///
    /// 这两个数字**不是**权威——权威在服务端 src/lib/plans.ts，改那里就够了。
    /// 放在这里只是为了让首帧不至于显示 0 B。真实值一到就被覆盖。
    private enum Fallback {
        static let free: Int64 = 20 * 1024 * 1024
        static let pro: Int64 = 10 * 1024 * 1024 * 1024
    }

    var freeQuotaBytes: Int64 { tiers?.freeBytes ?? Fallback.free }
    var proQuotaBytes: Int64 { tiers?.proBytes ?? Fallback.pro }

    static let free = BillingStatus(
        plan: "free",
        expiresAt: nil,
        autoRenew: false,
        inGracePeriod: false,
        productId: nil,
        environment: nil,
        storage: BillingStorage(quotaBytes: 0, usedBytes: 0, reservedBytes: 0),
        tiers: nil
    )
}

/// `GET /me` 里的档位摘要。
///
/// 整个字段是**可选**的：老版本服务端不返回它，新旧两端要能互相解码。
struct AccountPlan: Decodable {
    let name: String
    let expiresAt: Date?

    var isPro: Bool { name == "pro" }
}
