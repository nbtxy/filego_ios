import Foundation

/// 档位。与服务端 `src/lib/plans.ts` 的 `PlanName` 一一对应。
///
/// 商品号是 `...pro.monthly`——历次改名都没有新建商品，见服务端 plans.ts 的
/// PRODUCTS 注释。所以**不能**从档名推商品号，反过来也不行，一律走
/// `StoreKitService.ProductID`。
///
/// 用 `String` 的 rawValue 而不是让服务端下发数字：服务端将来加档位时，老客户端
/// 解到未知字符串会落进 `unknown`（见下面的 init），按免费档渲染，不会崩。这同样
/// 覆盖了反向情况——服务端下线了 `work`，装着老版本的客户端也不会因此解码失败。
nonisolated enum PlanName: String, Decodable, Sendable, CaseIterable {
    case free
    case pro

    /// 未知档名一律当免费档。fail closed：把一个不认识的档当成最高档渲染，
    /// 用户会看到自己没买过的权益。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlanName(rawValue: raw) ?? .free
    }

    var isPaid: Bool { self != .free }
}

/// 服务端下发的单档权益。`/billing/status` 与 `/app/config` 的 `tiers` 同源。
nonisolated struct PlanTier: Decodable, Sendable {
    let name: PlanName
    let quotaBytes: Int64
    /// 能同时持有多少条导入地址。nil = 不限。
    let importAddresses: Int?
    /// 这一档可选的导入地址有效期。老服务端不下发时为 nil。
    let linkTtlChoices: [Int]?
    /// 公开导入地址的单文件直传上限。nil = 没有直传权益。
    let directImportMaxBytes: Int64?
    let productId: String?

    /// 区分“老服务端没下发字段”和“新服务端明确下发 null”。前者允许使用端上兜底，
    /// 后者必须尊重服务端已经关闭直传权益的决定。
    private let includesDirectImportMaxBytes: Bool

    private enum CodingKeys: String, CodingKey {
        case name, quotaBytes, importAddresses, linkTtlChoices, directImportMaxBytes, productId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(PlanName.self, forKey: .name)
        quotaBytes = try container.decode(Int64.self, forKey: .quotaBytes)
        importAddresses = try container.decodeIfPresent(Int.self, forKey: .importAddresses)
        linkTtlChoices = try container.decodeIfPresent([Int].self, forKey: .linkTtlChoices)
        directImportMaxBytes = try container.decodeIfPresent(Int64.self, forKey: .directImportMaxBytes)
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
        includesDirectImportMaxBytes = container.contains(.directImportMaxBytes)
    }

    func resolvedDirectImportMaxBytes(fallback: Int64?) -> Int64? {
        includesDirectImportMaxBytes ? directImportMaxBytes : fallback
    }
}

/// 当前档位。与服务端 `/billing/status`、`/billing/verify` 的 data 对齐。
struct BillingStatus: Decodable {
    /// 服务端已经把过期的付费档折算成 `.free`，端上不需要再比一次到期时间。
    let plan: PlanName
    /// 到期时间。宽限期已并入——服务端存的是 max(到期日, 宽限期截止)。
    let expiresAt: Date?
    let autoRenew: Bool
    /// 续费失败但仍在 Apple 给的宽限窗口内。用于设置页提示横幅。
    let inGracePeriod: Bool
    let productId: String?
    let environment: String?
    let storage: BillingStorage
    /// 档位权益表，由服务端下发。可选：还没拉到时退到 `Fallback`。
    let tiers: [PlanTier]?
    let links: Links?

    var isPaid: Bool { plan.isPaid }

    struct BillingStorage: Decodable {
        let quotaBytes: Int64
        let usedBytes: Int64
        let reservedBytes: Int64
    }

    struct Links: Decodable {
        let importTtlChoices: [Int]
        let importDefaultTtlSeconds: Int
        /// 「永不过期」那一档的秒数。它在 choices 里只是个特别大的数，必须靠这个
        /// 字段换文案，别把 36500 天印出来。服务端 policies.ts 解释了为什么用哨兵。
        let importNeverTtlSeconds: Int?
        /// 当前档位能持有几条导入地址。nil = 不限。
        let importAddressLimit: Int?
    }

    /// 仅在「还没拉到 /billing/status」或对接老服务端时兜底。
    ///
    /// 这几个数字**不是**权威——权威在服务端 src/lib/plans.ts 的 PLANS，改那里就够了。
    /// 放在这里只是为了让首帧不至于显示 0 B。真实值一到就被覆盖。
    private enum Fallback {
        static let free: Int64 = 200 * 1024 * 1024
        static let pro: Int64 = 50 * 1024 * 1024 * 1024
        static let proDirectImport: Int64 = 5 * 1024 * 1024 * 1024

        static func quota(for plan: PlanName) -> Int64 {
            switch plan {
            case .free: return free
            case .pro: return pro
            }
        }
    }

    /// 某一档的容量。优先用服务端下发的，拉不到才用兜底常量。
    func quotaBytes(for plan: PlanName) -> Int64 {
        tiers?.first { $0.name == plan }?.quotaBytes ?? Fallback.quota(for: plan)
    }

    /// 某一档的导入地址数上限。nil = 不限或未知。
    func importAddresses(for plan: PlanName) -> Int? {
        tiers?.first { $0.name == plan }?.importAddresses
    }

    /// 某一档的公开导入地址单文件直传上限。Pro 对接老服务端时使用 5 GB 兜底。
    func directImportMaxBytes(for plan: PlanName) -> Int64? {
        if let tier = tiers?.first(where: { $0.name == plan }) {
            return tier.resolvedDirectImportMaxBytes(
                fallback: plan == .pro ? Fallback.proDirectImport : nil
            )
        }
        return plan == .pro ? Fallback.proDirectImport : nil
    }

    /// 付费墙要展示的付费档，按容量升序。服务端没下发时退回写死的顺序。
    var purchasableTiers: [PlanName] {
        guard let tiers else { return [.pro] }
        return tiers
            .filter { $0.name.isPaid }
            .sorted { $0.quotaBytes < $1.quotaBytes }
            .map(\.name)
    }

    var freeQuotaBytes: Int64 { quotaBytes(for: .free) }

    static let free = BillingStatus(
        plan: .free,
        expiresAt: nil,
        autoRenew: false,
        inGracePeriod: false,
        productId: nil,
        environment: nil,
        storage: BillingStorage(quotaBytes: 0, usedBytes: 0, reservedBytes: 0),
        tiers: nil,
        links: nil
    )
}

/// `GET /me` 里的档位摘要。
///
/// 整个字段是**可选**的：老版本服务端不返回它，新旧两端要能互相解码。
struct AccountPlan: Decodable {
    let name: PlanName
    let expiresAt: Date?

    var isPaid: Bool { name.isPaid }
}
