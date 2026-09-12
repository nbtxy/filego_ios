import UIKit

/// UIKit 根协调器。注册态切换、主导航栈和全局弹窗统一放在这里管理。
///
/// 这里换的不再是登录态而是**注册态**：没有账号，设备有没有在服务端注册过才是
/// 唯一的分叉。切换不由触发方自己跳转——`StolnkController` 广播
/// `.stolnkRegistrationDidChange`，这里换根界面。好处和改造前一样：任意深处收到
/// 一个 `unknown_device`（服务端不再认识这台设备）都能把用户送回首次运行，
/// 不用每个调用点都写一遍。
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
        observeRegistrationChanges()
        showCurrentRegistrationState(animated: false)
    }

    private func observeRegistrationChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationDidChange),
            name: .stolnkRegistrationDidChange,
            object: nil
        )
    }

    @objc private func registrationDidChange() {
        showCurrentRegistrationState(animated: true)
        processPendingIncomingFileIfPossible()
    }

    private func showCurrentRegistrationState(animated: Bool) {
        let registered = environment.stolnk.isRegistered
        // 已经是目标形态就不要重建，避免通知重复触发时闪一下
        switch current {
        case is DrawerContainerViewController where registered: return
        case is InboxOnboardingViewController where !registered: return
        default: break
        }

        let next: UIViewController = registered
            ? DrawerContainerViewController(environment: environment)
            : InboxOnboardingViewController(environment: environment)
        transition(to: next, animated: animated)
    }

    /// 系统「打开方式」入口：还没注册时暂存，注册完成后自动导入根目录。
    func handleIncomingFile(_ url: URL) {
        pendingIncomingURL = url
        processPendingIncomingFileIfPossible()
    }

    private func processPendingIncomingFileIfPossible() {
        guard environment.stolnk.isRegistered,
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
