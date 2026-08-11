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
        // 网页登录页左上角就是这枚品牌标，比一个通用的 SF Symbol 认得出人。
        let iconView = BrandMarkView(side: 62)

        titleLabel.textColor = AppColor.textPrimary
        titleLabel.textAlignment = .center
        titleLabel.setTightText(
            R.Strings.appName.localizedString(),
            font: .systemFont(ofSize: 40, weight: .heavy),
            kernEm: -0.07
        )

        subtitleLabel.text = R.Strings.loginSubtitle.localizedString()
        subtitleLabel.font = AppTypography.body
        subtitleLabel.textColor = AppColor.textSecondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        appleButton.addTarget(self, action: #selector(didTapAppleSignIn), for: .touchUpInside)
        // `.btn-lg`：圆角 15。Apple 按钮本身就是墨黑底白字，与 `.btn-primary` 同气质。
        appleButton.cornerRadius = 15

        errorLabel.font = AppTypography.caption
        errorLabel.textColor = AppColor.danger
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
        debugPanelButton.setTitleColor(AppColor.muted, for: .normal)
        debugPanelButton.addTarget(self, action: #selector(didTapDebugPanel), for: .touchUpInside)
        actionStack.addArrangedSubview(debugPanelButton)
        #endif

        [stack, actionStack, activityIndicator, errorLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // BrandMarkView 自带尺寸约束，这里不再钉宽高。

            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor, constant: -60),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: AppSpacing.large),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -AppSpacing.large),

            errorLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: AppSpacing.medium),
            errorLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: AppSpacing.large),
            errorLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -AppSpacing.large),

            activityIndicator.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            activityIndicator.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -AppSpacing.medium),

            // `.btn-lg`：min-height 54
            appleButton.heightAnchor.constraint(equalToConstant: 54),
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
