import StolnkCore
import UIKit

/// 登录后的单一导航栈：首页展示文件，“我的”从首页左上角进入。
@MainActor
final class MainNavigationController: UINavigationController {
    private let environment: AppEnvironment
    private var retainedRouter: Router?
    var onOpenDrawer: (() -> Void)?

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
        // 没有账号，也就没有按用户分根这回事：树只有一棵，根是 Documents。
        let rootId = LocalDriveStore.rootID
        router.setRoot(DriveListViewController(
            environment: environment,
            router: router,
            folderId: rootId,
            folderName: R.Strings.tabFiles.localizedString(),
            rootId: rootId,
            onShowMe: { [weak self] in self?.onOpenDrawer?() }
        ), animated: false)

        #if DEBUG
        // App Store 宣传截图的自动导航入口。只在 Debug 构建里存在，用启动参数
        // 指定要停在哪一屏，省掉模拟器里手工点按的步骤：
        //   xcrun simctl launch … -screenshot html
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.openScreenshotScreenIfRequested()
        }
        #endif
    }

    #if DEBUG
    private func openScreenshotScreenIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screenshot"),
              arguments.indices.contains(index + 1),
              let router = retainedRouter else { return }

        switch arguments[index + 1] {
        case "html":
            openScreenshotPreview("ai-report.html")
        case "markdown":
            openScreenshotPreview("meeting-notes.md")
        case "plan":
            router.push(PlanViewController(environment: environment), animated: false)
        case "inbox":
            router.push(InboxDetailViewController(environment: environment), animated: false)
        case "received":
            router.push(DriveListViewController(
                environment: environment,
                router: router,
                folderId: LocalDriveStore.receivedID,
                folderName: R.Strings.driveReceivedTitle.localizedString(),
                rootId: LocalDriveStore.rootID), animated: false)
        case "qr":
            guard let inbox = environment.stolnk.inbox,
                  let image = QRCode.image(for: inbox.url) else { return }
            present(InboxQRViewController(image: image, address: inbox.url), animated: false)
        default:
            break
        }
    }

    private func openScreenshotPreview(_ name: String) {
        guard let node = environment.drive.node(at: name), !node.isFolder,
              let router = retainedRouter else { return }
        let file = PreviewTemporaryFile.borrowing(environment.drive.url(for: name))
        router.push(
            PreviewCoordinator.makeViewController(
                for: node, file: file, environment: environment),
            animated: false)
    }
    #endif

    func importExternalFile(at url: URL) -> Bool {
        loadViewIfNeeded()
        popToRootViewController(animated: false)
        guard let drive = viewControllers.first as? DriveListViewController else { return false }
        return drive.importExternalFile(at: url)
    }

}
