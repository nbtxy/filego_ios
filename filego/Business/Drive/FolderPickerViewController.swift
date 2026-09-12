import UIKit

@MainActor
final class FolderPickerViewController: UITableViewController {
    private let environment: AppEnvironment
    private let router: Router
    private let folderId: String
    private let folderName: String
    private let excludedNodeId: String?
    private let onPick: (String) -> Void
    private var folders: [DriveNode] = []

    init(
        environment: AppEnvironment,
        router: Router,
        folderId: String,
        folderName: String,
        excludedNodeId: String?,
        onPick: @escaping (String) -> Void
    ) {
        self.environment = environment
        self.router = router
        self.folderId = folderId
        self.folderName = folderName
        self.excludedNodeId = excludedNodeId
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderName
        tableView.backgroundColor = AppColor.background
        tableView.separatorColor = AppColor.paper2
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "folder")
        let moveHereItem = UIBarButtonItem(
            title: R.Strings.driveMoveHere.localizedString(),
            style: .done,
            target: self,
            action: #selector(pickCurrent)
        )
        // 这个页面由一套临时的 UINavigationController 弹出。不要只依赖全局
        // appearance 继承文字色：系统在更新 done item 的 configuration 时可能把
        // title attributes 覆盖掉，结果纸色导航栏上只剩一块空的点击区域。
        // iOS 26 会把 `.done` 渲染成 tint 色的实心胶囊，文字必须用反色；
        // 较早系统仍是透明导航按钮，需要深色文字。
        let foregroundColor: UIColor
        let disabledForegroundColor: UIColor
        if #available(iOS 26.0, *) {
            foregroundColor = AppColor.white
            disabledForegroundColor = AppColor.white.withAlphaComponent(0.5)
        } else {
            foregroundColor = AppColor.ink
            disabledForegroundColor = AppColor.muted
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: foregroundColor
        ]
        moveHereItem.tintColor = AppColor.ink
        moveHereItem.setTitleTextAttributes(titleAttributes, for: .normal)
        moveHereItem.setTitleTextAttributes(titleAttributes, for: .highlighted)
        moveHereItem.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: disabledForegroundColor
        ], for: .disabled)
        navigationItem.rightBarButtonItem = moveHereItem
        loadFolders()
    }

    private func loadFolders() {
        do {
            let nodes = try environment.drive.list(in: folderId, sort: .name, order: .ascending)
            folders = nodes.filter { $0.isFolder && $0.id != excludedNodeId }
            tableView.reloadData()
        } catch {
            showError(error)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        folders.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "folder", for: indexPath)
        PaperListCellStyle.apply(to: cell)
        var content = cell.defaultContentConfiguration()
        content.applyPaperColors()
        content.text = folders[indexPath.row].name
        content.image = UIImage(systemName: "folder.fill")
        // 与列表里的文件夹图标块同色，一眼认得出是同一种东西。
        content.imageProperties.tintColor = AppColor.FileTile.folderForeground
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let folder = folders[indexPath.row]
        router.push(FolderPickerViewController(
            environment: environment,
            router: router,
            folderId: folder.id,
            folderName: folder.name,
            excludedNodeId: excludedNodeId,
            onPick: onPick
        ))
    }

    @objc private func pickCurrent() { onPick(folderId) }

    private func showError(_ error: Error) {
        let alert = UIAlertController(
            title: R.Strings.commonError.localizedString(),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }
}

@MainActor
final class FolderPickerNavigationController: UINavigationController {
    private(set) var retainedRouter: Router!

    static func make(
        environment: AppEnvironment,
        rootId: String,
        excludedNodeId: String?,
        onPick: @escaping (String) -> Void
    ) -> FolderPickerNavigationController {
        let navigation = FolderPickerNavigationController()
        let router = Router(navigationController: navigation)
        navigation.retainedRouter = router
        router.setRoot(FolderPickerViewController(
            environment: environment,
            router: router,
            folderId: rootId,
            folderName: R.Strings.tabFiles.localizedString(),
            excludedNodeId: excludedNodeId,
            onPick: onPick
        ), animated: false)
        return navigation
    }
}
