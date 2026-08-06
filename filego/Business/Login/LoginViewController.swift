import AuthenticationServices
import UIKit

/// 登录页。Sign in with Apple 是唯一入口。
final class LoginViewController: UIViewController {
    private let environment: AppEnvironment
    private lazy var appleSignInService = AppleSignInService { [weak self] in
        self?.view.window
    }

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let appleButton = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()

    #if DEBUG
    private let debugPanelButton = UIButton(type: .system)
    #endif

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        setUpViews()
    }

    private func setUpViews() {
        let iconView = UIImageView(image: UIImage(systemName: "externaldrive.badge.icloud"))
        iconView.tintColor = AppColor.accent
        iconView.contentMode = .scaleAspectFit

        titleLabel.text = R.Strings.appName.localizedString()
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.textColor = AppColor.textPrimary
        titleLabel.textAlignment = .center

        subtitleLabel.text = R.Strings.loginSubtitle.localizedString()
        subtitleLabel.font = AppTypography.body
        subtitleLabel.textColor = AppColor.textSecondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        appleButton.addTarget(self, action: #selector(didTapAppleSignIn), for: .touchUpInside)
        appleButton.cornerRadius = 10

        errorLabel.font = AppTypography.caption
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        activityIndicator.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [
            iconView, titleLabel, subtitleLabel
        ])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = AppSpacing.medium

        let actionStack = UIStackView(arrangedSubviews: [appleButton])
        actionStack.axis = .vertical
        actionStack.spacing = AppSpacing.medium

        #if DEBUG
        debugPanelButton.setTitle(R.Strings.debugPanelTitle.localizedString(), for: .normal)
        debugPanelButton.titleLabel?.font = AppTypography.caption
        debugPanelButton.addTarget(self, action: #selector(didTapDebugPanel), for: .touchUpInside)
        actionStack.addArrangedSubview(debugPanelButton)
        #endif

        [stack, actionStack, activityIndicator, errorLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor, constant: -60),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: AppSpacing.large),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -AppSpacing.large),

            errorLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: AppSpacing.medium),
            errorLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: AppSpacing.large),
            errorLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -AppSpacing.large),

            activityIndicator.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            activityIndicator.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -AppSpacing.medium),

            appleButton.heightAnchor.constraint(equalToConstant: 50),
            actionStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: AppSpacing.large),
            actionStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -AppSpacing.large),
            actionStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -AppSpacing.large * 2)
        ])
    }

    // MARK: - 动作

    @objc private func didTapAppleSignIn() {
        setBusy(true)
        Task {
            defer { setBusy(false) }
            do {
                let credential = try await appleSignInService.signIn()
                _ = try await environment.accountService.signInWithApple(
                    identityToken: credential.identityToken,
                    fullName: credential.fullName
                )
            } catch let authError as ASAuthorizationError where authError.code == .canceled {
                AppLogger.info("用户取消了 Apple 登录")
            } catch {
                AppLogger.error("Apple 登录失败", error: error)
                showError(Self.readableMessage(for: error))
            }
        }
    }

    #if DEBUG
    @objc private func didTapDebugPanel() {
        let panel = DebugPanelViewController(environment: environment)
        present(UINavigationController(rootViewController: panel), animated: true)
    }
    #endif

    private func setBusy(_ busy: Bool) {
        busy ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
        appleButton.isEnabled = !busy
        #if DEBUG
        debugPanelButton.isEnabled = !busy
        #endif
        if busy { errorLabel.isHidden = true }
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        HapticManager.notification(.error)
    }
}

extension LoginViewController {
    /// 把 ASAuthorizationError 翻译成用户能照着做的话。
    ///
    /// 系统原始文案是「未能完成操作。(com.apple.AuthenticationServices.AuthorizationError 错误 1000。)」，
    /// 对用户等于没说。其中 1000（.unknown）绝大多数情况就是设备没登录 Apple 账户——
    /// 模拟器上尤其常见，必须明确引导到「设置」，否则只能干瞪眼。
    private static func readableMessage(for error: Error) -> String {
        guard let authError = error as? ASAuthorizationError else {
            return error.localizedDescription
        }
        switch authError.code {
        case .unknown:
            return R.Strings.loginErrorNoAppleAccount.localizedString()
        case .notHandled, .notInteractive:
            return R.Strings.loginErrorNotHandled.localizedString()
        case .failed, .invalidResponse:
            return R.Strings.loginErrorFailed.localizedString()
        case .canceled:
            return ""
        default:
            return R.Strings.loginErrorFailed.localizedString()
        }
    }
}
