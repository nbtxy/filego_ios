import Foundation
import Moya

extension Notification.Name {
    static let fileGoSessionDidSignIn = Notification.Name("filego.session.did-sign-in")
    static let fileGoSessionDidSignOut = Notification.Name("filego.session.did-sign-out")
}

/// 登录态与认证请求的唯一入口。
///
/// 做成 actor 是为了「刷新只发一次」：access token 过期时，界面上多个并发请求会同时
/// 拿到 401，如果各自去刷新，先返回的那个会让后面的 refresh token 全部失效
/// （服务端 refresh 是轮换的、一次性的），用户会被直接踢下线。
/// 这里用 actor 串行化 + 复用同一个 refreshTask，保证一轮 401 只换一次令牌。
actor SessionManager {
    /// Moya 也导出了一个叫 `Task` 的类型（`TargetType.task` 用的那个枚举），
    /// 在 import Moya 的文件里它会遮蔽 Swift 并发的 `Task`。这里显式取并发那个。
    private typealias ConcurrencyTask<Success> = _Concurrency.Task<Success, Error>

    private let networkProvider: NetworkProvider
    private var refreshTask: ConcurrencyTask<Void>?

    private static let userIDKey = "filego.auth.user-id"

    init(networkProvider: NetworkProvider) {
        self.networkProvider = networkProvider
    }

    // MARK: - 登录态

    @MainActor var isSignedIn: Bool {
        AuthTokenStorage.isLoggedIn
    }

    @MainActor var currentUserID: String? {
        KeyValueStore.shared.globalValue(forKey: Self.userIDKey)
    }

    /// App 启动时调一次：处理全新安装、迁移历史明文令牌，并恢复 KeyValueStore 的用户域。
    @MainActor static func bootstrap() {
        // 顺序不能换：迁移会写 migrationFlagKey，跑在前面会让全新安装看起来像老用户升级。
        AuthTokenStorage.clearOnFreshInstallIfNeeded()
        AuthTokenStorage.migrateFromUserDefaultsIfNeeded()
        if let userID: String = KeyValueStore.shared.globalValue(forKey: userIDKey) {
            KeyValueStore.shared.setCurrentUser(userID)
        }
    }

    func signIn(with session: AuthSession) async {
        await MainActor.run {
            AuthTokenStorage.token = session.accessToken
            AuthTokenStorage.refreshToken = session.refreshToken

            if let userID = session.user?.id {
                KeyValueStore.shared.setGlobal(userID, forKey: Self.userIDKey)
                // 切到该用户的偏好域，排序方式、视图模式等按账号隔离
                KeyValueStore.shared.setCurrentUser(userID)
            }
            AppLogger.info("登录成功 userID=\(session.user?.id ?? "-")")
        }
        await postNotification(.fileGoSessionDidSignIn)
    }

    /// 主动登出。先尽力通知服务端作废 refresh token，本地清理无论如何都会执行。
    func signOut() async {
        let refreshToken = await MainActor.run { AuthTokenStorage.refreshToken }
        if let refreshToken {
            do {
                let logoutTask = ConcurrencyTask<Void> { @MainActor [networkProvider] in
                    try await networkProvider.requestEmpty(AuthAPI.logout(refreshToken: refreshToken))
                }
                try await logoutTask.value
            } catch {
                // 网络不通也要让用户能退出去，服务端那份 30 天后自然过期
                await MainActor.run {
                    AppLogger.warning("登出接口失败，仅做本地清理：\(error.localizedDescription)")
                }
            }
        }
        await clearLocalSession()
    }

    /// 后端环境切换时只清本地会话。不能向新地址发送旧环境的 refresh token。
    func invalidateLocalSession() async {
        await clearLocalSession()
    }

    // MARK: - 认证请求

    /// 带 401 自动刷新重放的请求。业务层统一走这里，不要直接用 NetworkProvider。
    func request<Target: TargetType, Payload: Decodable>(
        _ target: Target,
        as payloadType: Payload.Type = Payload.self
    ) async throws -> Payload {
        do {
            return try await networkProvider.request(target, as: payloadType)
        } catch FileGoAPIError.unauthorized {
            try await refreshOnce()
            // 只重放一次。第二次还 401 说明不是「令牌过期」而是别的问题，
            // 继续重试只会打转，直接把错误抛给业务层。
            return try await networkProvider.request(target, as: payloadType)
        }
    }

    func requestEmpty<Target: TargetType>(_ target: Target) async throws {
        do {
            try await networkProvider.requestEmpty(target)
        } catch FileGoAPIError.unauthorized {
            try await refreshOnce()
            try await networkProvider.requestEmpty(target)
        }
    }

    // MARK: - 刷新

    /// 并发调用只会真正刷新一次，其余复用同一个 Task 的结果。
    private func refreshOnce() async throws {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }

        let task = ConcurrencyTask<Void> { [networkProvider] in
            guard let refreshToken = await MainActor.run(body: { AuthTokenStorage.refreshToken }) else {
                throw FileGoAPIError.unauthorized
            }
            // 刷新本身直接走 networkProvider，不能走 self.request，否则 401 会递归
            let requestTask = ConcurrencyTask<AuthSession> { @MainActor in
                try await networkProvider.request(
                    AuthAPI.refresh(refreshToken: refreshToken),
                    as: AuthSession.self
                )
            }
            let session = try await requestTask.value
            await MainActor.run {
                AuthTokenStorage.token = session.accessToken
                AuthTokenStorage.refreshToken = session.refreshToken
                AppLogger.info("令牌已刷新")
            }
        }
        refreshTask = task

        do {
            try await task.value
            refreshTask = nil
        } catch FileGoAPIError.unauthorized {
            refreshTask = nil
            // 只有服务端明确 401 才说明 refresh token 已失效。
            await MainActor.run {
                AppLogger.warning("刷新令牌被服务端拒绝，清理登录态")
            }
            await clearLocalSession()
            throw FileGoAPIError.unauthorized
        } catch {
            refreshTask = nil
            // 断网、5xx、解码异常都属于瞬时失败，保留 refresh token，下次请求可重试。
            await MainActor.run {
                AppLogger.warning("刷新令牌暂时失败，保留登录态：\(error.localizedDescription)")
            }
            throw error
        }
    }

    private func clearLocalSession() async {
        let userID = await MainActor.run {
            KeyValueStore.shared.globalValue(forKey: Self.userIDKey) as String?
        }
        await MainActor.run {
            AuthTokenStorage.clear()
            KeyValueStore.shared.setGlobal(Optional<String>.none, forKey: Self.userIDKey)
            KeyValueStore.shared.clearCurrentUser()
        }
        await postNotification(.fileGoSessionDidSignOut)
        // 先切回登录页，再清理磁盘，避免大缓存让用户感觉“退出登录”卡住。
        if let userID {
            await FileCacheManager.shared.removeAll(userID: userID)
        }
    }

    private func postNotification(_ name: Notification.Name) async {
        await MainActor.run {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}
