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

    /// 开发期登录。仅当服务端 ALLOW_DEV_LOGIN 为 true 时可用。
    func signInAsDeveloper(handle: String) async throws -> AccountUser? {
        let result: AuthSession = try await session.request(
            AuthAPI.dev(handle: handle),
            as: AuthSession.self
        )
        await session.signIn(with: result)
        return result.user
    }

    func loadProfile() async throws -> AccountProfile {
        try await session.request(AccountAPI.me, as: AccountProfile.self)
    }

    func signOut() async {
        await session.signOut()
    }
}
