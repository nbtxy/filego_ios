import AuthenticationServices
import Foundation

struct AppleSignInCredential: Sendable {
    let identityToken: String
    let fullName: String?
}

enum AppleSignInError: LocalizedError {
    case requestInProgress
    case presentationUnavailable
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .requestInProgress:
            return "Apple 登录请求正在进行"
        case .presentationUnavailable:
            return "当前页面暂时无法显示 Apple 登录"
        case .invalidCredential:
            return "未能获取 Apple 登录凭证"
        }
    }
}

/// UIKit 版 Sign in with Apple 适配器。
///
/// 与 qingshu_ios 的 `SignInWithAppleButton` 结果闭包保持同一语义：服务完整持有
/// ASAuthorizationController，直到系统回调后才释放，并一次性返回 identityToken 与姓名。
@MainActor
final class AppleSignInService: NSObject {
    private typealias Continuation = CheckedContinuation<AppleSignInCredential, Error>

    private let anchorProvider: () -> ASPresentationAnchor?
    private var authorizationController: ASAuthorizationController?
    private var continuation: Continuation?
    private var presentationAnchor: ASPresentationAnchor?

    init(anchorProvider: @escaping () -> ASPresentationAnchor?) {
        self.anchorProvider = anchorProvider
        super.init()
    }

    func signIn() async throws -> AppleSignInCredential {
        guard continuation == nil else { throw AppleSignInError.requestInProgress }
        guard let anchor = anchorProvider() else {
            throw AppleSignInError.presentationUnavailable
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        authorizationController = controller
        presentationAnchor = anchor

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<AppleSignInCredential, Error>) {
        let pending = continuation
        continuation = nil
        authorizationController = nil
        presentationAnchor = nil
        pending?.resume(with: result)
    }

    private static func formattedName(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let value = PersonNameComponentsFormatter()
            .string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8),
            !identityToken.isEmpty
        else {
            finish(.failure(AppleSignInError.invalidCredential))
            return
        }
        finish(.success(AppleSignInCredential(
            identityToken: identityToken,
            fullName: Self.formattedName(credential.fullName)
        )))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }
}

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // signIn() 已在发起系统请求前验证并保存 anchor。
        presentationAnchor!
    }
}
