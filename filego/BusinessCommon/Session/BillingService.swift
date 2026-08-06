import Foundation

/// 订阅相关的业务动作。与 `AccountService` 同构：VC / Store 依赖它而不是直接
/// 依赖 SessionManager + API enum。
struct BillingService {
    private let session: SessionManager

    init(session: SessionManager) {
        self.session = session
    }

    /// 只读当前档位，不触发 Apple 往返。
    func loadStatus() async throws -> BillingStatus {
        try await session.request(BillingAPI.status, as: BillingStatus.self)
    }

    /// 上报一笔交易，让服务端回查 Apple 并落库权益。
    @discardableResult
    func verify(
        transactionId: String,
        originalTransactionId: String
    ) async throws -> BillingStatus {
        try await session.request(
            BillingAPI.verify(
                transactionId: transactionId,
                originalTransactionId: originalTransactionId
            ),
            as: BillingStatus.self
        )
    }
}
