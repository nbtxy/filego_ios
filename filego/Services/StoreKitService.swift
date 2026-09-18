import Foundation
import StoreKit
import StolnkCore

extension Notification.Name {
    static let stolnkStoreKitDidChange = Notification.Name("stolnk.storekit-did-change")
}

/// StoreKit 2 lifecycle for the one-time Pro unlock.
///
/// A verified local transaction proves that Apple delivered a purchase to this
/// device. Service entitlement is still decided by the Worker after it looks up
/// the transaction at Apple; this keeps quota enforcement out of a patchable
/// client binary.
@MainActor
final class StoreKitService {
    static let productID = "com.nbtxy.filego.pro.lifetime"

    enum Outcome {
        case success
        case cancelled
        case pending
        case failed(String)
    }

    private(set) var product: Product?
    private(set) var isLoading = false
    private(set) var lastError: String?

    private let stolnk: StolnkController
    private var updatesTask: Task<Void, Never>?
    private var registrationObserver: NSObjectProtocol?

    init(stolnk: StolnkController) {
        self.stolnk = stolnk
        registrationObserver = NotificationCenter.default.addObserver(
            forName: .stolnkRegistrationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.syncLatestPurchase() }
        }
    }

    deinit {
        updatesTask?.cancel()
        if let registrationObserver { NotificationCenter.default.removeObserver(registrationObserver) }
    }

    func bootstrap() async {
        observeTransactions()
        async let load: Void = loadProduct()
        async let sync: Void = syncLatestPurchase()
        _ = await (load, sync)
    }

    func loadProduct(force: Bool = false) async {
        guard !isLoading, force || product == nil else { return }
        isLoading = true
        lastError = nil
        notify()
        defer {
            isLoading = false
            notify()
        }
        do {
            product = try await Product.products(for: [Self.productID]).first
            if product == nil { lastError = R.Strings.proProductsUnavailable.localizedString() }
        } catch {
            AppLogger.error("加载买断商品失败", error: error)
            lastError = error.localizedDescription
        }
    }

    func purchase() async -> Outcome {
        guard let product else {
            return .failed(lastError ?? R.Strings.proProductsUnavailable.localizedString())
        }
        do {
            switch try await product.purchase() {
            case let .success(result):
                guard case let .verified(transaction) = result else {
                    return .failed(R.Strings.proPurchaseFailed.localizedString())
                }
                return await report(transaction)
            case .userCancelled:
                return .cancelled
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

    func restore() async -> Outcome {
        do {
            try await AppStore.sync()
        } catch {
            AppLogger.error("恢复购买失败", error: error)
            return .failed(error.localizedDescription)
        }
        guard let result = await Transaction.latest(for: Self.productID),
              case let .verified(transaction) = result,
              transaction.revocationDate == nil else {
            return .failed(R.Strings.proRestoreNone.localizedString())
        }
        return await report(transaction)
    }

    private func observeTransactions() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, case let .verified(transaction) = result,
                      transaction.productID == Self.productID else { continue }
                _ = await self.report(transaction)
            }
        }
    }

    /// Revalidates even a revoked latest transaction so the server can apply a
    /// refund downgrade the next time the app opens.
    private func syncLatestPurchase() async {
        guard stolnk.isRegistered,
              let result = await Transaction.latest(for: Self.productID),
              case let .verified(transaction) = result else { return }
        _ = await report(transaction)
    }

    private func report(_ transaction: Transaction) async -> Outcome {
        guard transaction.productID == Self.productID else {
            return .failed(R.Strings.proPurchaseFailed.localizedString())
        }
        do {
            let plan = try await stolnk.verifyApplePurchase(transactionID: transaction.id)
            await transaction.finish()
            notify()
            return plan.isPro
                ? .success
                : .failed(R.Strings.proPurchaseFailed.localizedString())
        } catch {
            // Do not finish: StoreKit will redeliver it through Transaction.updates
            // after a transient Worker or network failure.
            AppLogger.warning("买断交易暂未同步：\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .stolnkStoreKitDidChange, object: self)
    }
}
