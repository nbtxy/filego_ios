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
        // 不 await：取密钥可能弹系统提示，注册要走网络，任何一个卡住都不该拖住首屏。
        // 界面自己会等 .stolnkStateDidChange。
        Task { await environment.stolnk.start() }
        return true
    }

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
