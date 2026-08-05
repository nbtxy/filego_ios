import UIKit

/// UIKit 根协调器。登录态切换、主导航栈和全局弹窗统一放在这里管理。
///
/// 登录/登出不由触发方自己跳转——`SessionManager` 广播通知，这里换根界面。
/// 好处是任意深处的一次 401（刷新也失败）都能把用户送回登录页，
/// 不用每个调用点都写一遍「失败了要不要跳登录」。
@MainActor
final class RootViewController: UIViewController {
    private let environment: AppEnvironment
    private var current: UIViewController?
    private var pendingIncomingURL: URL?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        observeSessionChanges()
        showCurrentSessionState(animated: false)
    }

    private func observeSessionChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionDidChange),
            name: .fileGoSessionDidSignIn,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionDidChange),
            name: .fileGoSessionDidSignOut,
            object: nil
        )
    }

    @objc private func sessionDidChange() {
        showCurrentSessionState(animated: true)
        processPendingIncomingFileIfPossible()
    }

    private func showCurrentSessionState(animated: Bool) {
        let signedIn = environment.sessionManager.isSignedIn
        // 已经是目标形态就不要重建，避免通知重复触发时闪一下
        switch current {
        case is DrawerContainerViewController where signedIn: return
        case is LoginViewController where !signedIn: return
        default: break
        }

        let next: UIViewController = signedIn
            ? DrawerContainerViewController(environment: environment)
            : LoginViewController(environment: environment)
        transition(to: next, animated: animated)
    }

    /// 系统“打开方式”入口：未登录时暂存，登录完成后自动导入根目录。
    func handleIncomingFile(_ url: URL) {
        pendingIncomingURL = url
        processPendingIncomingFileIfPossible()
    }

    private func processPendingIncomingFileIfPossible() {
        guard environment.sessionManager.isSignedIn,
              let url = pendingIncomingURL,
              let drawer = current as? DrawerContainerViewController else { return }
        if drawer.importExternalFile(at: url) {
            pendingIncomingURL = nil
        } else {
            // 另一个系统面板仍在关闭时保留 URL，稍后再试，不能静默丢掉“打开方式”请求。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.processPendingIncomingFileIfPossible()
            }
        }
    }

    private func transition(to next: UIViewController, animated: Bool) {
        let previous = current
        current = next

        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        next.didMove(toParent: self)

        if next is DrawerContainerViewController {
            DispatchQueue.main.async { [weak self] in
                self?.processPendingIncomingFileIfPossible()
            }
        }

        guard let previous else { return }

        let finish = {
            previous.willMove(toParent: nil)
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        }

        guard animated else {
            finish()
            return
        }

        next.view.alpha = 0
        UIView.animate(withDuration: 0.25) {
            next.view.alpha = 1
            previous.view.alpha = 0
        } completion: { _ in
            finish()
        }
    }
}
