import Foundation

/// 账号相关的业务动作。VC 依赖它而不是直接依赖 SessionManager + API enum。
struct AccountService {
    private let session: SessionManager

    init(session: SessionManager) {
        self.session = session
    }

    /// Sign in with Apple 换取自有令牌。
    func signInWithApple(identityToken: String, fullName: String?) async throws -> AccountUser? {
        let result: AuthSession = try await session.request(
            AuthAPI.apple(identityToken: identityToken, fullName: fullName),
            as: AuthSession.self
        )
        await session.signIn(with: result)
        return result.user
    }

    func loadProfile() async throws -> AccountProfile {
        try await session.request(AccountAPI.me, as: AccountProfile.self)
    }

    /// 改昵称。服务端返回的 user 与 `GET /me` 的 user 子对象同形。
    func updateDisplayName(_ displayName: String) async throws -> AccountUser {
        try await session.request(
            AccountAPI.updateDisplayName(displayName),
            as: AccountUser.self
        )
    }

    /// 注销账号：服务端硬删数据后再清本地登录态，RootViewController 收到通知会切回登录页。
    /// 接口失败时不清态，让用户看到错误并可重试。
    func deleteAccount() async throws {
        try await session.requestEmpty(AccountAPI.delete)
        await session.signOut()
    }

    func signOut() async {
        await session.signOut()
    }
}
