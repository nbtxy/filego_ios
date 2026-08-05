//
//  AppDelegate.swift
//  filego
//
//  Created by 赖恩光 on 2026/7/29.
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private(set) var environment: AppEnvironment!

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppLogger.info("Application did finish launching")
        // 必须在 AppEnvironment 之前：把历史明文令牌搬进 Keychain，并恢复
        // KeyValueStore 的用户域，否则首屏读到的偏好会落在 default 域里。
        SessionManager.bootstrap()
        environment = AppEnvironment()
        _ = AppLifecycleObserver.shared
        PreviewTemporaryFile.purgeOrphans()
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
