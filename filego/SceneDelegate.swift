//
//  SceneDelegate.swift
//  filego
//
//  Created by 赖恩光 on 2026/7/29.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard
            let windowScene = scene as? UIWindowScene,
            let environment = (UIApplication.shared.delegate as? AppDelegate)?.environment
        else { return }

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = AppColor.accent
        let rootViewController = RootViewController(environment: environment)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        self.window = window

        if let url = connectionOptions.urlContexts.first?.url {
            DispatchQueue.main.async {
                rootViewController.handleIncomingFile(url)
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        rootViewController?.handleIncomingFile(url)
    }

    private var rootViewController: RootViewController? {
        window?.rootViewController as? RootViewController
    }
}
