import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private(set) var environment: AppEnvironment!

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppLogger.info("Application did finish launching")
        // 要早于任何界面创建：UIAppearance 只对之后创建的视图生效。
        AppAppearance.install()
        environment = AppEnvironment()
        _ = AppLifecycleObserver.shared
        PreviewTemporaryFile.purgeOrphans()
        // 回收站是惰性清理的：iOS 上没有能指望的后台定时器，启动是唯一
        // 保证会到的时机。见 `LocalDriveStore.purgeExpiredTrash`。
        environment.drive.purgeExpiredTrash()
        // 不 await：取密钥可能弹系统提示，注册要走网络，任何一个卡住都不该拖住首屏。
        // 界面自己会等 .stolnkStateDidChange。
        //
        // 会员监听先开：`Transaction.updates` 会补投上次没上报成功的交易。对账
        // （currentEntitlements）要等设备会话起来，否则 api 还是 nil、上报必然失败。
        Task {
            environment.membership.startObservingTransactions()
            await environment.stolnk.start()
            #if DEBUG
            // 宣传截图用：跳过手工输入名字，直接对本地服务注册一个临时设备。
            // 只在 Debug 构建和显式参数下发生，发布包里没有这段代码。
            if let name = screenshotRegistrationName() {
                _ = await environment.stolnk.register(name: name)
            }
            #endif
            await environment.membership.bootstrap()
        }
        return true
    }

    #if DEBUG
    /// `-screenshot-register maya` — used by the App Store screenshot script.
    private func screenshotRegistrationName() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screenshot-register"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    #endif

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
