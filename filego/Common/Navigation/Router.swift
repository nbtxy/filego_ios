import UIKit

/// UIKit 导航器。业务层只依赖 Router，不直接操作导航栈。
@MainActor
final class Router: NSObject, UINavigationControllerDelegate {
    private(set) weak var navigationController: UINavigationController?
    private(set) var depth = 0

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
        super.init()
        navigationController.delegate = self
        navigationController.interactivePopGestureRecognizer?.delegate = self
    }

    func setRoot(_ viewController: UIViewController, animated: Bool) {
        navigationController?.setViewControllers([viewController], animated: animated)
        depth = 1
    }

    func push(_ viewController: UIViewController, animated: Bool = true) {
        navigationController?.pushViewController(viewController, animated: animated)
    }

    @discardableResult
    func pop(animated: Bool = true) -> UIViewController? {
        navigationController?.popViewController(animated: animated)
    }

    func popToRoot(animated: Bool = true) {
        navigationController?.popToRootViewController(animated: animated)
    }

    func popTo(_ viewController: UIViewController, animated: Bool = true) {
        navigationController?.popToViewController(viewController, animated: animated)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        depth = navigationController.viewControllers.count
    }
}

extension Router: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer == navigationController?.interactivePopGestureRecognizer else {
            return true
        }
        return (navigationController?.viewControllers.count ?? 0) > 1
            && !InteractivePopBlocker.shared.isBlocked
    }
}
