import Foundation
import StolnkCore
import UIKit

/// The App Store app is a paid download: installing it is the purchase.
///
/// The service-side tier still lives on the Worker, so this only has to tell it
/// once per device. It retries whenever the device registers or the app comes
/// back to the foreground, until the plan reads Pro.
@MainActor
final class AppUnlockService {
    private let stolnk: StolnkController
    private var observers: [NSObjectProtocol] = []
    private var inFlight = false

    init(stolnk: StolnkController) {
        self.stolnk = stolnk
        for name in [Notification.Name.stolnkRegistrationDidChange, UIApplication.willEnterForegroundNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.claimIfNeeded() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func bootstrap() async {
        await claimIfNeeded()
    }

    /// Fire-and-forget: a failure is logged and retried on the next trigger.
    func claimIfNeeded() async {
        guard stolnk.isRegistered, stolnk.plan?.isPro != true else { return }
        _ = try? await claim()
    }

    /// Explicit claim, for the plan screen and the 402 paths, which need the answer.
    @discardableResult
    func claim() async throws -> Bool {
        guard !inFlight else { return stolnk.plan?.isPro == true }
        inFlight = true
        defer { inFlight = false }
        do {
            return try await stolnk.claimAppStoreUnlock().isPro
        } catch {
            AppLogger.warning("付费下载权益暂未同步：\(error.localizedDescription)")
            throw error
        }
    }
}
