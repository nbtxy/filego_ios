import Foundation
import StoreKit

/// StoreKit 2 集成：加载商品、购买、恢复购买、把交易上报给服务端核验。
///
/// 与服务端的分工：本类只负责「和 StoreKit / 后端打交道」，**不自己判定权益**。
/// 是不是 Pro 一律以服务端 `/billing/status` 为准——本地 `Transaction` 只能证明
/// 「Apple 那边有这笔交易」，证明不了「这笔交易属于当前 FileGo 账号」。
@MainActor
final class StoreKitService {
    enum ProductID {
        /// 付费档 Pro。历次改名都刻意没有新建商品（价格权益都没变），换商品号会让
        /// 存量订阅者一续期就失去会员。与服务端 src/lib/plans.ts 的 PRO_PRODUCT_ID 一致。
        static let proMonthly = "com.nbtxy.filego.pro.monthly"
        static let all: [String] = [proMonthly]

        /// 档位 → 商品号。free 没有商品。
        static func of(_ plan: PlanName) -> String? {
            switch plan {
            case .free: return nil
            case .pro: return proMonthly
            }
        }
    }

    enum PurchaseOutcome {
        case success
        case userCancelled
        /// 等家长批准 / 银行确认。交易稍后会从 `Transaction.updates` 进来。
        case pending
        case failed(String)
    }

    private(set) var products: [Product] = []
    private(set) var isLoadingProducts = false

    /// 最近一次已知的服务端档位。购买 / 恢复后刷新，供「我的」页与付费墙展示。
    private(set) var status: BillingStatus = .free

    private let billing: BillingService
    private let session: SessionManager
    private var updatesTask: Task<Void, Never>?

    init(billing: BillingService, session: SessionManager) {
        self.billing = billing
        self.session = session
    }

    /// 某一档对应的 StoreKit 商品。没拉到（或该档无商品）返回 nil。
    func product(for plan: PlanName) -> Product? {
        guard let id = ProductID.of(plan) else { return nil }
        return products.first { $0.id == id }
    }

    // MARK: - 生命周期

    /// App 启动 / 登录后调用：启监听器 + 拉商品 + 用现有 entitlements 校准一次。
    ///
    /// 监听器要**先**启动：`Transaction.updates` 会补投所有未 finish 的交易，
    /// 包括上次因为断网没能上报成功的那些。晚启动就等于晚补偿。
    func bootstrap() async {
        startObservingTransactions()
        async let productsLoaded: Void = loadProducts()
        async let synced: Void = syncCurrentEntitlements()
        _ = await (productsLoaded, synced)
        await refreshStatus()
    }

    /// 登出时必须调用。
    ///
    /// 不调的话 `Transaction.updates` 任务会跨账号泄漏——A 退出、B 登录的窗口里，
    /// A 的 Apple 事件会带着 B 的令牌上报，把 A 的订阅绑到 B 头上。
    /// `products` 也要清：它是 A 当时按 A 的地区拉的，币种可能与新账号不一致。
    func shutdown() {
        updatesTask?.cancel()
        updatesTask = nil
        products = []
        status = .free
    }

    /// 加载 StoreKit 商品。付费墙传 `forceRefresh: true`，避免价格在 App Store Connect
    /// 调整后仍展示 App 启动时缓存的旧 `displayPrice`；购买确认框由系统实时展示价格，
    /// 两处不一致会直接影响用户信任。
    func loadProducts(forceRefresh: Bool = false) async {
        guard isLoadingProducts == false else { return }
        guard forceRefresh || products.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await Product.products(for: ProductID.all)
            if products.isEmpty {
                // 最常见的原因是 Paid Applications Agreement 没生效，
                // 其次是商品还没过审 / 当前地区不售卖。付费墙要据此给出提示而不是白屏。
                AppLogger.warning("内购商品为空——检查 Paid Applications Agreement 与商品状态")
            }
        } catch {
            AppLogger.error("加载内购商品失败", error: error)
        }
    }

    /// 拉一次服务端档位。失败静默：档位展示是 nice-to-have，不该阻塞主流程。
    func refreshStatus() async {
        do {
            status = try await billing.loadStatus()
        } catch {
            AppLogger.warning("刷新订阅状态失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 购买

    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase(options: appAccountTokenOption())
            switch result {
            case let .success(verification):
                guard case let .verified(transaction) = verification else {
                    if case let .unverified(_, error) = verification {
                        AppLogger.error("购买凭证未通过 StoreKit 校验", error: error)
                    }
                    return .failed(R.Strings.proPurchaseFailed.localizedString())
                }
                return await report(transaction)

            case .userCancelled:
                return .userCancelled

            case .pending:
                // 家长批准 / 银行确认。批准后会从 Transaction.updates 进来。
                return .pending

            @unknown default:
                return .failed(R.Strings.proPurchaseFailed.localizedString())
            }
        } catch {
            AppLogger.error("购买失败", error: error)
            return .failed(error.localizedDescription)
        }
    }

    /// 设置页「恢复购买」。Apple 审核硬要求项，不能只靠 `Transaction.updates` 自动恢复。
    ///
    /// 与 bootstrap 的静默同步不同，这里是用户主动触发，所以业务错要吐出去——
    /// 「该订阅已绑定到其他账号」必须让用户看到，否则只会得到一句莫名其妙的
    /// 「没找到可恢复的购买」。
    func restorePurchases() async -> PurchaseOutcome {
        do {
            try await AppStore.sync()
        } catch {
            AppLogger.error("恢复购买失败", error: error)
            return .failed(error.localizedDescription)
        }

        var lastBusinessError: String?
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            do {
                try await upload(transaction)
            } catch let FileGoAPIError.business(_, message) {
                // 保留最后一条业务错，给用户一个有意义的解释而不是「没找到可恢复的购买」。
                lastBusinessError = message.isEmpty ? nil : message
            } catch {
                // 瞬时错静默：Transaction.updates 会重投。
                AppLogger.warning("恢复购买上报暂时失败：\(error.localizedDescription)")
            }
        }

        await refreshStatus()
        if status.isPaid { return .success }
        return .failed(lastBusinessError ?? R.Strings.proRestoreNone.localizedString())
    }

    // MARK: - 私有

    /// 启动期补投、后台续期、退款、家长批准等都会从这里进来。
    private func startObservingTransactions() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                guard case let .verified(transaction) = update else { continue }
                _ = await self.report(transaction)
            }
        }
    }

    /// 把当前所有未过期订阅同步给服务端，启动期校准用。
    ///
    /// 典型场景：用户注销后用新账号登录，服务端是 free 但 Apple 端仍有有效订阅。
    /// 这里的业务错只记日志不弹 UI——bootstrap 是后台行为，用户没有主动意图，
    /// 弹错只会让人困惑。需要用户感知时走 `restorePurchases`。
    private func syncCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            // 沙盒（偶尔生产也会）会在 currentEntitlements 里漏过已过期的旧交易，
            // 上报只会被服务端拒掉，先滤掉。
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            do {
                try await upload(transaction)
            } catch {
                AppLogger.warning("启动期同步订阅失败：\(error.localizedDescription)")
            }
        }
    }

    /// 服务端业务码。与 filego/src/lib/envelope.ts 的 ErrorCode 对齐。
    private enum BusinessCode {
        /// 交易本身无效：未知商品、bundleId 不符、已绑定到其他账号。
        /// 这是**唯一**永久性的失败——重投多少次结果都一样。
        static let transactionInvalid = 40002
    }

    /// 上报 + 按结果决定要不要 `finish()`。
    ///
    /// **finish 决策 —— 错了会真的让用户付了钱拿不到东西：**
    ///
    /// 只有 `40002` 是永久性失败（交易本身无效），必须 finish，否则每次启动
    /// `Transaction.updates` 都会重投同一笔，无限循环。
    ///
    /// 其余一律**不** finish，留在队列里等下次重投。这里必须按业务码精确判断，
    /// 不能笼统地"凡 business 错就 finish"——服务端的 50000（密钥没配好）、
    /// 50001（Apple 暂时不可达）都会走 `FileGoAPIError.business` 这个分支，
    /// 而它们都是运维一改配置就好的临时故障。把这类交易 finish 掉，
    /// 用户的购买就永久丢失且无从恢复。
    private func report(_ transaction: StoreKit.Transaction) async -> PurchaseOutcome {
        do {
            let reported = try await upload(transaction)
            await transaction.finish()
            await refreshStatus()
            // 服务端没报错不等于开通成功——它判定的档位才算数。正常情况下
            // /billing/verify 已经把免费档的判定拒成业务错了，这里是双保险，
            // 顺带覆盖 devGrant 那条路径。宁可说“稍后同步”也不能谎报成功。
            guard reported == nil || reported?.isPaid == true || status.isPaid else {
                AppLogger.warning("交易已核验但服务端仍是免费档，按待同步处理")
                return .failed(R.Strings.proPurchasePendingSync.localizedString())
            }
            return .success
        } catch let FileGoAPIError.business(code, message) where code == BusinessCode.transactionInvalid {
            await transaction.finish()
            AppLogger.error("交易被服务端判定为无效，不再重试 code=\(code) message=\(message)")
            return .failed(message.isEmpty ? R.Strings.proPurchaseFailed.localizedString() : message)
        } catch let FileGoAPIError.business(code, message) {
            // 服务端故障（50000 / 50001 等）。不 finish，留给 Transaction.updates 重投。
            AppLogger.error("服务端暂时无法处理这笔交易，稍后自动重试 code=\(code) message=\(message)")
            return .failed(R.Strings.proPurchasePendingSync.localizedString())
        } catch {
            // 网络错误同理，不 finish。
            AppLogger.warning("交易上报暂时失败，稍后自动重试：\(error.localizedDescription)")
            return .failed(R.Strings.proPurchasePendingSync.localizedString())
        }
    }

    /// **顺序死规矩：先上报成功，再 finish。**
    /// 反过来一旦网络失败，交易就从 `Transaction.updates` 里消失了，
    /// 用户付了钱却永远拿不到权益，且没有任何自动补偿路径。
    ///
    /// 返回服务端判定后的档位，供调用方确认是不是真的开通了。
    /// RELEASE 构建下的本地 StoreKit 交易拿不到档位，返回 nil。
    @discardableResult
    private func upload(_ transaction: StoreKit.Transaction) async throws -> BillingStatus? {
        // Xcode 本地 StoreKit 配置文件造的交易完全发生在本机，Apple 服务器不知情，
        // 交易号也只是 0、1 这种小整数（真实的是 15-16 位）。上报过去只会被
        // App Store Server API 以 4000006 Invalid transaction id 拒掉。
        // 这里直接短路，本地联调改走 dev-grant。
        if transaction.environment == .xcode {
            AppLogger.info("本地 StoreKit 交易，跳过服务端核验")
            #if DEBUG
            return try await billing.devGrant()
            #else
            return nil
            #endif
        }
        return try await billing.verify(
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID)
        )
    }

    /// 把当前 FileGo user id 透传给 Apple 作为 `appAccountToken`。
    ///
    /// Apple 会在 JWS 和所有后续续费 / 退款通知里原样带回，服务端落到
    /// `subscriptions.app_account_token`。用途是客服反查「这份订阅当初是哪个账号买的」。
    /// FileGo 的 user id 本身就是 UUID（服务端 crypto.randomUUID()），必然解析成功；
    /// 万一不是就跳过，购买照常进行，只是少了这个反查锚点。
    private func appAccountTokenOption() -> Set<Product.PurchaseOption> {
        guard let userId = session.currentUserID, let uuid = UUID(uuidString: userId) else {
            AppLogger.warning("appAccountToken 跳过：user id 不是 UUID")
            return []
        }
        return [.appAccountToken(uuid)]
    }
}
