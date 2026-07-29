import UIKit

/// 登录后的单一导航栈：首页展示文件，“我的”从首页左上角进入。
@MainActor
final class MainNavigationController: UINavigationController {
    private let environment: AppEnvironment
    private var retainedRouter: Router?

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
        navigationBar.prefersLargeTitles = true

        let router = Router(navigationController: self)
        retainedRouter = router
        let userId = environment.sessionManager.currentUserID ?? ""
        let rootId = "root_\(userId)"
        router.setRoot(DriveListViewController(
            environment: environment,
            router: router,
            folderId: rootId,
            folderName: R.Strings.tabFiles.localizedString(),
            rootId: rootId
        ), animated: false)
    }

    func importExternalFile(at url: URL) -> Bool {
        loadViewIfNeeded()
        popToRootViewController(animated: false)
        guard let drive = viewControllers.first as? DriveListViewController else { return false }
        return drive.importExternalFile(at: url)
    }
}
