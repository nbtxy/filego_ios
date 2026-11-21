import Foundation
import StolnkCore
import StoreKit
import UIKit

/**
 年度会员（自动续期订阅）的 StoreKit 2 集成。

 和服务端的分工照旧：这里只负责「和 StoreKit / Worker 打交道」，**不自己判定权益**。
 是不是会员一律以 Worker 的 `PlanState` 为准——本地 `Transaction` 只能证明 Apple 那边
 有这笔交易，证明不了它属于这台设备。每一笔已验签的交易都交给
 `POST /licenses/apple/subscription`，由 Worker 回查 Apple 后写库，再 `finish()`。

 改写自 `Parked/StoreKitService.swift`：去掉了旧的 `BillingService` / `SessionManager`，
 改走 `StolnkController`（它持有 `APIClient` 和设备会话）。
 */
@MainActor
final class MembershipService {
    static let productID = "com.nbtxy.filego.member.yearly"

    enum PurchaseOutcome {
        case success
        case userCancelled
        /// 等家长批准 / 银行确认。交易稍后会从 `Transaction.updates` 进来。
        case pending
        case failed(String)
    }

    private(set) var product: Product?
    private(set) var isLoadingProduct = false

    private let stolnk: StolnkController
    private var updatesTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(stolnk: StolnkController) {
        self.stolnk = stolnk
        // 首次启动时设备可能还没注册：那时的交易上报不了，留在队列里不 finish。
        // 注册成功后再对一遍账。
        observers.append(NotificationCenter.default.addObserver(
            forName: .stolnkRegistrationDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.stolnk.isRegistered else { return }
                await self.syncCurrentEntitlements()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - 生命周期

    /**
     设备会话起来之后调用：确保监听已开，再拉商品、对一遍现有 entitlements。

     监听器必须**先**启动：`Transaction.updates` 会补投所有没 finish 的交易，包括上次
     因为断网没上报成功的那些。晚启动就是晚补偿。
     */
    func bootstrap() async {
        startObservingTransactions()
        async let loaded: Void = loadProduct()
        async let synced: Void = syncCurrentEntitlements()
        _ = await (loaded, synced)
    }

    /// 付费墙传 `forceRefresh: true`，免得价格在 ASC 调整后仍显示启动时缓存的旧价。
    func loadProduct(forceRefresh: Bool = false) async {
        guard !isLoadingProduct, forceRefresh || product == nil else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
            if product == nil {
                // 最常见的原因：Paid Applications Agreement 没生效，或商品还没过审。
                AppLogger.warning("会员商品为空——检查 Paid Applications Agreement 与商品状态")
            }
        } catch {
            AppLogger.error("加载会员商品失败", error: error)
        }
    }

    // MARK: - 购买

    func purchase() async -> PurchaseOutcome {
        if product == nil { await loadProduct(forceRefresh: true) }
        guard let product else {
            return .failed(R.Strings.memberProductUnavailable.localizedString())
        }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    if case .unverified(_, let error) = verification {
                        AppLogger.error("购买凭证未通过 StoreKit 校验", error: error)
                    }
                    return .failed(R.Strings.proPurchaseFailed.localizedString())
                }
                return await report(transaction)
            case .userCancelled:
                return .userCancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(R.Strings.proPurchaseFailed.localizedString())
            }
        } catch {
            AppLogger.error("购买失败", error: error)
            return .failed(error.localizedDescription)
        }
    }

    /// 「恢复购买」。审核硬要求，不能只靠 `Transaction.updates` 自动恢复。
    func restore() async -> PurchaseOutcome {
        do {
            try await AppStore.sync()
        } catch {
            AppLogger.error("恢复购买失败", error: error)
            return .failed(error.localizedDescription)
        }
        var lastOutcome: PurchaseOutcome?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID else { continue }
            lastOutcome = await report(transaction)
        }
        await stolnk.refreshPlan()
        if stolnk.plan?.isPro == true { return .success }
        if case .failed = lastOutcome { return lastOutcome! }
        return .failed(R.Strings.proRestoreNone.localizedString())
    }

    /// 系统的订阅管理页（取消 / 换档都在那里）。
    func showManageSubscriptions(from presenter: UIViewController) async {
        guard let scene = presenter.view.window?.windowScene else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            AppLogger.warning("打开订阅管理失败：\(error.localizedDescription)")
            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                await UIApplication.shared.open(url)
            }
        }
        await stolnk.refreshPlan()
    }

    // MARK: - 私有

    /// 后台续期、退款、家长批准、启动补投都从这里进来。幂等。
    func startObservingTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = update else { continue }
                _ = await self.report(transaction)
            }
        }
    }

    /// 启动期对账：Apple 端有有效订阅、而 Worker 还不知道的情况（重装、换设备）。
    private func syncCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID else { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            _ = await report(transaction)
        }
    }

    /**
     上报 + 决定要不要 `finish()`。

     **顺序死规矩：先上报成功，再 finish。** 反过来一旦网络失败，交易就从
     `Transaction.updates` 里消失了，用户付了钱却拿不到权益。

     只有永久性失败（Worker 判定交易本身无效的 4xx）才 finish，否则同一笔会被无限重投；
     网络错误、5xx、未注册一律不 finish，留给下次重投。
     */
    private func report(_ transaction: StoreKit.Transaction) async -> PurchaseOutcome {
        guard transaction.productID == Self.productID else {
            // 旧的 lifetime IAP 或别的商品：会员制下 Worker 不再据此授予任何东西。
            await transaction.finish()
            return .failed(R.Strings.proPurchaseFailed.localizedString())
        }
        guard stolnk.isRegistered else {
            AppLogger.info("设备未注册，会员交易暂不上报")
            return .failed(R.Strings.proPurchasePendingSync.localizedString())
        }
        do {
            let state = try await stolnk.verifySubscription(transactionID: transaction.id)
            await transaction.finish()
            // 服务端没报错不等于开通成功——它判定的档位才算数。
            guard state.isPro else {
                AppLogger.warning("交易已核验但服务端仍是免费档（可能已过期或已退款）")
                return .failed(R.Strings.proPurchasePendingSync.localizedString())
            }
            return .success
        } catch let error as APIError where Self.isPermanent(error) {
            await transaction.finish()
            AppLogger.error("会员交易被服务端判定为无效，不再重试 code=\(error.code)")
            return .failed(R.Strings.proPurchaseFailed.localizedString())
        } catch {
            /*
             Xcode 本地 StoreKit 配置（Membership.storekit）造的交易 Apple 服务器不知情，
             Worker 永远核验不了。只在本地联调时出现，finish 掉免得每次启动重投。
             */
            if transaction.environment == .xcode {
                await transaction.finish()
                AppLogger.info("本地 StoreKit 交易，Worker 无法核验：\(error.localizedDescription)")
            } else {
                AppLogger.warning("会员交易上报暂时失败，稍后自动重试：\(error.localizedDescription)")
            }
            return .failed(R.Strings.proPurchasePendingSync.localizedString())
        }
    }

    /**
     只认 Worker 自己说出来的「这笔交易不行」：400/403/409/422 且带着它自己的错误码。
     `http_404` 这类没有错误体的（路由还没上线、网关报错）一律当暂时故障——把一笔真金
     白银的交易 finish 掉的代价远大于多重投几次。
     */
    private static func isPermanent(_ error: APIError) -> Bool {
        [400, 403, 409, 422].contains(error.status) && !error.code.hasPrefix("http_")
    }
}
