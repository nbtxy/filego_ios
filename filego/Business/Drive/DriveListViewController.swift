import PhotosUI
import StolnkCore
import UIKit
import UniformTypeIdentifiers

@MainActor
final class DriveListViewController: UIViewController {
    let folderId: String
    private let folderName: String
    private let rootId: String
    private let environment: AppEnvironment
    private let router: Router
    private let onShowMe: (() -> Void)?
    private let viewModel: DriveListViewModel
    private let breadcrumbBar = BreadcrumbBar()
    private let emptyView = PaperEmptyStateView(title: R.Strings.driveEmpty.localizedString())
    private let addFolderButton = PaperButton.primary()
    /// 左下角、与 `+` 对称的接收文件夹入口。只在根目录显示。
    private let receivedButton = PaperButton.primary()
    private let receivedBadge = UILabel()
    private let fileActivityIndicator = UIActivityIndicatorView(style: .medium)
    private let activityBackdrop = UIView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var openFileTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var isSearching = false
    private var isSearchLoading = false
    private var searchQuery = ""
    private var searchResults: [DriveNode] = []
    private lazy var searchBar: UISearchBar = {
        let searchBar = UISearchBar()
        searchBar.delegate = self
        searchBar.placeholder = R.Strings.driveSearchPlaceholder.localizedString()
        searchBar.searchBarStyle = .minimal
        searchBar.showsCancelButton = true
        // 网页 `.search-wrap .input` 的胶囊形状，做成压进纸里的凹槽。
        // 先清掉系统那层圆角灰底，否则它会盖在凹槽上面。
        searchBar.setSearchFieldBackgroundImage(UIImage(), for: .normal)
        let field = searchBar.searchTextField
        field.textColor = AppColor.textPrimary
        AppMaterial.inset(field, radius: 18)
        return searchBar
    }()
    private var isGrid: Bool {
        didSet { environment.keyValueStore.set(isGrid, forKey: "drive.grid") }
    }
    /// 当前宫格布局是按多宽的窗口算的；窗口尺寸变了要重建（Duo 横竖屏/分屏）。
    private var lastGridWidth: CGFloat = 0

    private var visibleNodes: [DriveNode] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.nodes }
        return searchResults
    }

    /// 占位的 item id 前缀。节点 id 是相对路径，永远不以 `/` 开头，所以撞不上。
    private static let incomingPrefix = "/incoming/"

    /// 本文件夹里正在路上的文件。搜索态不显示：搜的是已经在盘上的东西。
    private var visibleIncoming: [IncomingTransfer] {
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return environment.stolnk.incoming(in: environment.drive.url(for: folderId))
    }

    /// 占位在前、节点在后，和 `applySnapshot` 里的顺序一致。
    private var visibleItemIDs: [String] {
        visibleIncoming.map { Self.incomingPrefix + $0.fileID } + visibleNodes.map(\.id)
    }

    init(
        environment: AppEnvironment,
        router: Router,
        folderId: String,
        folderName: String,
        rootId: String,
        onShowMe: (() -> Void)? = nil
    ) {
        self.environment = environment
        self.router = router
        self.folderId = folderId
        self.folderName = folderName
        self.rootId = rootId
        self.onShowMe = onShowMe
        self.viewModel = DriveListViewModel(
            folderId: folderId,
            drive: environment.drive,
            preferences: environment.keyValueStore
        )
        self.isGrid = environment.keyValueStore.value(forKey: "drive.grid") ?? false
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var landedObserver: (any NSObjectProtocol)?
    private var incomingObserver: (any NSObjectProtocol)?
    private var stateObserver: (any NSObjectProtocol)?
    private var expiredObserver: (any NSObjectProtocol)?

    private var isRoot: Bool { folderId == rootId }
    private var isReceivedFolder: Bool { LocalDriveStore.isReceived(folderId) }

    /// 进过接收文件夹之后落地的文件数。角标的另一半（在途的那一半来自 `incoming(in:)`）。
    private static let unseenKey = "drive.received.unseen"

    deinit {
        openFileTask?.cancel()
        searchTask?.cancel()
        // 基于 block 的观察者以 token 为键，`removeObserver(self)` 摘不掉它。
        if let landedObserver { NotificationCenter.default.removeObserver(landedObserver) }
        if let incomingObserver { NotificationCenter.default.removeObserver(incomingObserver) }
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        if let expiredObserver { NotificationCenter.default.removeObserver(expiredObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderName
        view.backgroundColor = AppColor.background
        configureNavigation()
        configureCollectionView()
        configureBreadcrumbs()
        configureAddFolderButton()
        configureReceivedButton()
        configureFileActivityIndicator()
        observeContentSizeCategory()
        observeLandedFiles()
        observeAddress()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isReceivedFolder {
            // 看过了：清掉首页角标里「已落地未查看」的那一半。
            environment.keyValueStore.set(0, forKey: Self.unseenKey)
        }
        updateReceivedBadge()
    }

    /**
     文件是自己落进来的，不是用户放进来的。

     收件盘和普通文件浏览器的区别就在这里：内容会在没人操作的时候变。不监听的话，
     用户盯着一个写着「这个文件夹是空的」的屏幕，而文件其实已经在磁盘上了——
     直到他下拉刷新或者切个目录才看得到。
     */
    private func observeLandedFiles() {
        landedObserver = NotificationCenter.default.addObserver(
            forName: .stolnkDidLandFiles,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isRoot { self.countUnseen(note) }
                self.reload()
                self.updateReceivedBadge()
            }
        }
        /*
         占位的增删和进度。有占位消失时重读磁盘：它多半是刚落地了，真文件要在同一次
         apply 里顶上它的位置，否则中间会空一下。只是进度变了就不碰磁盘。
         */
        incomingObserver = NotificationCenter.default.addObserver(
            forName: .stolnkIncomingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let shown = Set(self.dataSource.snapshot().itemIdentifiers
                    .filter { $0.hasPrefix(Self.incomingPrefix) })
                let now = Set(self.visibleIncoming.map { Self.incomingPrefix + $0.fileID })
                if shown.isSubset(of: now) { self.applySnapshot() } else { self.reload() }
                self.updateReceivedBadge()
            }
        }
    }

    /// 只有根目录那一份计数：每个页面都数一遍会重复累加。
    private func countUnseen(_ note: Notification) {
        guard let files = note.userInfo?["files"] as? [LandedFile] else { return }
        let received = environment.drive.url(for: LocalDriveStore.receivedID).standardizedFileURL.path
        let count = files.filter { $0.fileURL.standardizedFileURL.path.hasPrefix(received + "/") }.count
        guard count > 0, navigationController?.topViewController.map({
            ($0 as? DriveListViewController)?.isReceivedFolder != true
        }) ?? true else { return }
        let previous: Int = environment.keyValueStore.value(forKey: Self.unseenKey) ?? 0
        environment.keyValueStore.set(previous + count, forKey: Self.unseenKey)
    }

    /**
     地址变了（改名、到期失效、暂停）时重画导航栏里的地址按钮；根目录还要把
     「地址已到期」告诉用户一次——旧地址当场失效，发出去的链接都断了。
     */
    private func observeAddress() {
        stateObserver = NotificationCenter.default.addObserver(
            forName: .stolnkStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isReceivedFolder, !self.isSearching else { return }
                self.configureNavigation()
            }
        }
        guard isRoot else { return }
        expiredObserver = NotificationCenter.default.addObserver(
            forName: .stolnkAddressDidExpire, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let alert = UIAlertController(
                    title: R.Strings.nameStatusExpired.localizedString(),
                    message: R.Strings.nameStatusExpiredDetail.localizedString(),
                    preferredStyle: .alert)
                // 原名已经释放，想继续接收只能重新设置子域名。
                alert.addAction(UIAlertAction(
                    title: R.Strings.nameSetNew.localizedString(), style: .default
                ) { [weak self] _ in
                    guard let self else { return }
                    self.router.push(InboxNameViewController(environment: self.environment))
                })
                alert.addAction(UIAlertAction(
                    title: R.Strings.commonOk.localizedString(), style: .cancel))
                (self.presentedViewController ?? self).present(alert, animated: true)
            }
        }
    }

    /// 窗口宽度变了（旋转、Duo 折叠/分屏）：宫格的列数需要重排。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isGrid, collectionView != nil else { return }
        let width = view.bounds.width
        guard abs(width - lastGridWidth) > 1 else { return }
        lastGridWidth = width
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
    }

    /// 宫格卡的高度是算出来的常量，字号变了要重算一次，否则名字会被裁掉。
    private func observeContentSizeCategory() {
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (self: Self, _: UITraitCollection) in
            guard self.isGrid else { return }
            self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: false)
        }
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        // 导航栏外观统一由 AppAppearance 提供（纸色底 + 滚动后一条 --line 发丝线）。
        // 这里刻意不再逐页覆盖：之前的 transparent 让内容直接从标题下穿过去，
        // 纸色底又没有毛玻璃衬着，滚动时文字会糊成一团。

        if isSearching {
            navigationItem.hidesBackButton = true
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItems = nil
            navigationItem.titleView = searchBar
            return
        }

        navigationItem.hidesBackButton = false
        navigationItem.titleView = nil
        if folderId == rootId {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "person.crop.circle"),
                style: .plain,
                target: self,
                action: #selector(showMe)
            )
            navigationItem.leftBarButtonItem?.accessibilityLabel = R.Strings.tabMe.localizedString()
        }
        let displayOptionsButton = UIBarButtonItem(
            title: nil,
            image: UIImage(systemName: "slider.horizontal.3"),
            primaryAction: nil,
            menu: displayOptionsMenu()
        )
        displayOptionsButton.accessibilityLabel = R.Strings.driveDisplayOptions.localizedString()
        let searchButton = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            style: .plain,
            target: self,
            action: #selector(showSearch)
        )
        searchButton.accessibilityLabel = R.Strings.driveSearch.localizedString()
        navigationItem.rightBarButtonItems = [displayOptionsButton, searchButton]
        if isReceivedFolder {
            let addressButton = UIBarButtonItem(
                title: nil,
                image: UIImage(systemName: environment.stolnk.inbox?.paused == true
                    ? "pause.circle" : "qrcode"),
                primaryAction: nil,
                menu: addressMenu()
            )
            addressButton.accessibilityLabel = R.Strings.receivedAddress.localizedString()
            navigationItem.rightBarButtonItems?.append(addressButton)
        }
    }

    /**
     接收文件夹导航栏上的「地址」菜单：标题就是 `<name>.stolnk.com`，下面是复制、分享、
     二维码，最后一项进收件设置（暂停、发件人看到的名字、子域名）。
     */
    private func addressMenu() -> UIMenu {
        let stolnk = environment.stolnk
        guard let inbox = stolnk.inbox else {
            return UIMenu(title: R.Strings.receivedAddressUnavailable.localizedString(), children: [
                UIAction(
                    title: R.Strings.receivedSettings.localizedString(),
                    image: UIImage(systemName: "gearshape")
                ) { [weak self] _ in self?.openReceiveSettings() }
            ])
        }
        var title = inbox.url
        if inbox.paused { title += "\n" + R.Strings.receivedPaused.localizedString() }
        return UIMenu(title: title, children: [
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: R.Strings.driveImportCopyAddress.localizedString(),
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in
                    guard let self else { return }
                    UIPasteboard.general.string = inbox.url
                    PaperToast.show(R.Strings.inboxCopied.localizedString(), in: self.view)
                    HapticManager.notification(.success)
                },
                UIAction(
                    title: R.Strings.driveImportShareAddress.localizedString(),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in
                    guard let url = URL(string: inbox.url) else { return }
                    self?.shareImportAddress(url)
                },
                UIAction(
                    title: R.Strings.inboxQr.localizedString(),
                    image: UIImage(systemName: "qrcode")
                ) { [weak self] _ in self?.showAddressQRCode(inbox) }
            ]),
            UIAction(
                title: R.Strings.receivedSettings.localizedString(),
                image: UIImage(systemName: "gearshape")
            ) { [weak self] _ in self?.openReceiveSettings() }
        ])
    }

    private func showAddressQRCode(_ inbox: InboxSummary) {
        guard let image = QRCode.image(for: inbox.url) else { return }
        present(InboxQRViewController(image: image, address: inbox.url), animated: true)
    }

    private func openReceiveSettings() {
        router.push(InboxDetailViewController(environment: environment))
    }

    private func displayOptionsMenu() -> UIMenu {
        let viewActions = [
            UIAction(
                title: R.Strings.driveViewList.localizedString(),
                image: UIImage(systemName: "list.bullet"),
                state: isGrid ? .off : .on
            ) { [weak self] _ in self?.changeLayout(isGrid: false) },
            UIAction(
                title: R.Strings.driveViewGrid.localizedString(),
                image: UIImage(systemName: "square.grid.2x2"),
                state: isGrid ? .on : .off
            ) { [weak self] _ in self?.changeLayout(isGrid: true) }
        ]

        let choices: [(NodeSort, String)] = [
            (.name, R.Strings.driveSortName.localizedString()),
            (.updated, R.Strings.driveSortDate.localizedString()),
            (.size, R.Strings.driveSortSize.localizedString())
        ]
        let sortActions = choices.map { sort, title in
            UIAction(title: title, state: viewModel.sort == sort ? .on : .off) { [weak self] _ in
                self?.changeSort(sort)
            }
        }

        let orderActions = [
            UIAction(
                title: R.Strings.driveOrderAscending.localizedString(),
                image: UIImage(systemName: "arrow.up"),
                state: viewModel.order == .ascending ? .on : .off
            ) { [weak self] _ in self?.changeOrder(.ascending) },
            UIAction(
                title: R.Strings.driveOrderDescending.localizedString(),
                image: UIImage(systemName: "arrow.down"),
                state: viewModel.order == .descending ? .on : .off
            ) { [weak self] _ in self?.changeOrder(.descending) }
        ]

        return UIMenu(children: [
            UIMenu(
                title: R.Strings.driveView.localizedString(),
                options: .displayInline,
                children: viewActions
            ),
            UIMenu(
                title: R.Strings.driveSort.localizedString(),
                options: .displayInline,
                children: sortActions
            ),
            UIMenu(
                title: R.Strings.driveOrder.localizedString(),
                options: .displayInline,
                children: orderActions
            )
        ])
    }

    private func configureBreadcrumbs() {
        breadcrumbBar.isHidden = folderId == rootId
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbBar.onSelect = { [weak self] node in self?.openBreadcrumb(node) }
        view.addSubview(breadcrumbBar)
        NSLayoutConstraint.activate([
            breadcrumbBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            breadcrumbBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            breadcrumbBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            breadcrumbBar.heightAnchor.constraint(equalToConstant: folderId == rootId ? 0 : 36)
        ])
    }

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = AppColor.background
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset.bottom = 88
        collectionView.verticalScrollIndicatorInsets.bottom = 88
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(DriveNodeCell.self, forCellWithReuseIdentifier: "node")
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            // 左右跟着安全区，而不是整个 view。Duo 折叠时状态栏在右侧，横屏时
            // 也可能有侧边安全区；贴着 view 会让每行最右边的「更多」按钮钻到状态栏
            // 或刘海底下，既看不见也不好点。
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: folderId == rootId ? 0 : 36
            ),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        collectionView.backgroundView = emptyView
        lastGridWidth = view.bounds.width

        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self else { return nil }
            let ids = visibleItemIDs
            if id.hasPrefix(Self.incomingPrefix) {
                let fileID = String(id.dropFirst(Self.incomingPrefix.count))
                guard let transfer = visibleIncoming.first(where: { $0.fileID == fileID }),
                      let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: "node", for: indexPath
                      ) as? DriveNodeCell else { return nil }
                cell.configure(
                    incoming: transfer,
                    grid: isGrid,
                    isFirst: id == ids.first,
                    isLast: id == ids.last
                )
                return cell
            }
            guard let node = visibleNodes.first(where: { $0.id == id }),
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "node", for: indexPath
                  ) as? DriveNodeCell else { return nil }
            cell.configure(
                with: node,
                menu: actions(for: node),
                grid: isGrid,
                isFirst: id == ids.first,
                isLast: id == ids.last
            )
            return cell
        }
    }

    private func configureAddFolderButton() {
        var configuration = addFolderButton.configuration ?? .plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        )
        // 与网页 `.seg button.active` / `.nav-item.active` 同一套：墨绿底 + 柠檬绿图形，
        // 底是 `PaperButton.primary` 那张凸起的墨绿渐变。
        configuration.baseForegroundColor = AppColor.lime
        addFolderButton.configuration = configuration
        addFolderButton.cornerRadius = AppRadius.capsule
        addFolderButton.accessibilityLabel = R.Strings.driveAdd.localizedString()
        addFolderButton.menu = UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: R.Strings.driveNewFolder.localizedString(),
                    image: UIImage(systemName: "folder.badge.plus")
                ) { [weak self] _ in self?.addFolder() }
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: R.Strings.driveImportPhoto.localizedString(),
                    image: UIImage(systemName: "photo")
                ) { [weak self] _ in self?.openPhotos() },
                UIAction(
                    title: R.Strings.driveImportFile.localizedString(),
                    image: UIImage(systemName: "doc")
                ) { [weak self] _ in self?.openFileImporter() }
            ])
        ])
        addFolderButton.showsMenuAsPrimaryAction = true
        // 接收文件夹只收对方发来的文件，没有“新建/导入”这件事，右下角的 + 不出现。
        addFolderButton.isHidden = isReceivedFolder
        addFolderButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addFolderButton)

        NSLayoutConstraint.activate([
            addFolderButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            addFolderButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            addFolderButton.widthAnchor.constraint(equalToConstant: 56),
            addFolderButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    /**
     左下角的接收文件夹入口，和右下角的 `+` 镜像：同一个 `PaperButton.primary()`、同样
     56×56 的胶囊、同样离安全区 20。只在根目录出现；搜索时和 `+` 一起收起。
     */
    private func configureReceivedButton() {
        var configuration = receivedButton.configuration ?? .plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(
            systemName: "tray.and.arrow.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        )
        configuration.baseForegroundColor = AppColor.lime
        receivedButton.configuration = configuration
        receivedButton.cornerRadius = AppRadius.capsule
        receivedButton.accessibilityLabel = R.Strings.driveReceivedTitle.localizedString()
        receivedButton.addAction(UIAction { [weak self] _ in self?.openReceived() }, for: .touchUpInside)
        receivedButton.translatesAutoresizingMaskIntoConstraints = false
        receivedButton.isHidden = !isRoot
        view.addSubview(receivedButton)

        receivedBadge.font = .systemFont(ofSize: 12, weight: .bold)
        receivedBadge.textColor = AppColor.white
        receivedBadge.backgroundColor = AppColor.danger
        receivedBadge.textAlignment = .center
        receivedBadge.layer.cornerRadius = 10
        receivedBadge.layer.masksToBounds = true
        receivedBadge.isHidden = true
        receivedBadge.isUserInteractionEnabled = false
        receivedBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(receivedBadge)

        NSLayoutConstraint.activate([
            receivedButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            receivedButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            receivedButton.widthAnchor.constraint(equalToConstant: 56),
            receivedButton.heightAnchor.constraint(equalToConstant: 56),
            receivedBadge.centerXAnchor.constraint(equalTo: receivedButton.trailingAnchor, constant: -6),
            receivedBadge.centerYAnchor.constraint(equalTo: receivedButton.topAnchor, constant: 6),
            receivedBadge.heightAnchor.constraint(equalToConstant: 20),
            receivedBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    /// 在途的 + 落地后还没看过的。
    private func updateReceivedBadge() {
        guard isRoot else { return }
        let inFlight = environment.stolnk.incoming(
            in: environment.drive.url(for: LocalDriveStore.receivedID)).count
        let unseen: Int = environment.keyValueStore.value(forKey: Self.unseenKey) ?? 0
        let total = inFlight + unseen
        receivedBadge.text = total > 99 ? "99+" : " \(total) "
        receivedBadge.isHidden = total == 0 || receivedButton.isHidden
        receivedButton.accessibilityValue = total > 0 ? String(total) : nil
    }

    private func openReceived() {
        router.push(DriveListViewController(
            environment: environment,
            router: router,
            folderId: LocalDriveStore.receivedID,
            folderName: R.Strings.driveReceivedTitle.localizedString(),
            rootId: rootId,
            onShowMe: onShowMe
        ))
    }

    private func configureFileActivityIndicator() {
        // 凸起白卡，浮在内容上，与 Toast 同一档高度。
        AppMaterial.raise(activityBackdrop, radius: AppRadius.tile, elevation: .floating)
        activityBackdrop.isHidden = true
        activityBackdrop.translatesAutoresizingMaskIntoConstraints = false

        fileActivityIndicator.hidesWhenStopped = true
        fileActivityIndicator.color = AppColor.muted
        fileActivityIndicator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(activityBackdrop)
        activityBackdrop.addSubview(fileActivityIndicator)
        NSLayoutConstraint.activate([
            activityBackdrop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityBackdrop.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            activityBackdrop.widthAnchor.constraint(equalToConstant: 52),
            activityBackdrop.heightAnchor.constraint(equalToConstant: 52),
            fileActivityIndicator.centerXAnchor.constraint(equalTo: activityBackdrop.centerXAnchor),
            fileActivityIndicator.centerYAnchor.constraint(equalTo: activityBackdrop.centerYAnchor)
        ])
    }

    /// 打开文件时的转圈。卡片跟着指示器一起显隐，否则会留一张空白卡在屏幕中间。
    private func setFileActivity(_ running: Bool) {
        activityBackdrop.isHidden = !running
        running ? fileActivityIndicator.startAnimating() : fileActivityIndicator.stopAnimating()
    }

    /// 网格卡的高度。网页 `.card` 是 14 内边距 + 104 的缩略图位 + 两行名字 + meta。
    ///
    /// 跟着字号一起长：卡片是固定高度，不放大的话超大字号下名字会被从中间裁掉。
    /// 封顶 1.8 倍，否则辅助功能字号下一屏放不下一张卡。
    private var gridItemHeight: CGFloat {
        let scaled = UIFontMetrics(forTextStyle: .subheadline).scaledValue(
            for: 188, compatibleWith: traitCollection
        )
        return min(scaled, 188 * 1.8)
    }

    private func makeLayout() -> UICollectionViewLayout {
        if isGrid {
            // 普通 iPhone 两列；Duo 横屏/宽窗口三列，卡片才不会被拉得太宽。
            let columns = view.bounds.width >= 620 ? 3 : 2
            let height = gridItemHeight
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                heightDimension: .absolute(height)
            ))
            // 网页 `.grid` 的 gap 是 14，两侧各摊一半。
            item.contentInsets = .init(top: 7, leading: 7, bottom: 7, trailing: 7)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                subitems: Array(repeating: item, count: columns)
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 7, leading: 9, bottom: 16, trailing: 9)
            return UICollectionViewCompositionalLayout(section: section)
        }

        // 网页 `.rows`：整段套一张白卡。子文件夹上面已经有一条面包屑隔开导航栏，只留一点缝。
        return PaperSectionBackgroundView.makeListLayout(
            topInset: folderId == rootId ? 16 : 4
        ) { [weak self] _ in
            self?.visibleItemIDs.count ?? 0
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections(["main"])
        let ids = visibleItemIDs
        snapshot.appendItems(ids)
        // id 不变但内容变了（改名后大小/时间刷新等）时 diff 为空，需显式 reconfigure 才会重建 cell。
        let previousIDs = dataSource.snapshot().itemIdentifiers
        let existing = Set(previousIDs)
        let reconfigured = ids.filter(existing.contains)
        // 纯内容更新时不能开动画：apply 的交叉淡入会在 cell 上留下一张旧内容的快照，盖在新
        // 内容上面，直到 cell 被重建（切换列表/宫格触发 reloadData）才消失。
        // 只有增删移这类结构变化才需要动画。
        let isStructuralChange = previousIDs != ids
        snapshot.reconfigureItems(reconfigured)
        dataSource.apply(snapshot, animatingDifferences: isStructuralChange)
        // 空/非空之间切换时（搜索无结果、清空目录）要重算 section，
        // 否则那张白卡会以 0 行的高度留在原地，成为一条扁药丸。
        if previousIDs.isEmpty != ids.isEmpty {
            collectionView.collectionViewLayout.invalidateLayout()
        }

        emptyView.update(
            symbol: searchQuery.isEmpty ? "folder" : "magnifyingglass",
            title: searchQuery.isEmpty
                ? R.Strings.driveEmpty.localizedString()
                : R.Strings.driveSearchEmpty.localizedString()
        )
        emptyView.isHidden = isSearchLoading || !ids.isEmpty
        breadcrumbBar.configure(nodes: viewModel.ancestors)
    }

    private func reload() {
        Task {
            do {
                _ = try await viewModel.reload()
                applySnapshot()
            } catch {
                showError(error)
            }
            collectionView.refreshControl?.endRefreshing()
        }
    }

    @objc private func refresh() { reload() }

    @objc private func showMe() {
        if let onShowMe {
            onShowMe()
        } else {
            router.push(MeViewController(environment: environment))
        }
    }

    @objc private func showSearch() {
        isSearching = true
        addFolderButton.isHidden = true
        receivedButton.isHidden = true
        receivedBadge.isHidden = true
        configureNavigation()
        DispatchQueue.main.async { [weak self] in
            self?.searchBar.becomeFirstResponder()
        }
    }

    private func dismissSearch() {
        searchTask?.cancel()
        searchBar.resignFirstResponder()
        searchBar.text = nil
        searchQuery = ""
        searchResults = []
        isSearchLoading = false
        isSearching = false
        addFolderButton.isHidden = isReceivedFolder
        receivedButton.isHidden = !isRoot
        updateReceivedBadge()
        configureNavigation()
        applySnapshot()
    }

    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = query
        searchResults = []
        guard !query.isEmpty else {
            isSearchLoading = false
            applySnapshot()
            return
        }

        isSearchLoading = true
        applySnapshot()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                let nodes = try await viewModel.searchRecursively(query: query)
                guard !Task.isCancelled, searchQuery == query else { return }
                searchResults = nodes
                isSearchLoading = false
                applySnapshot()
            } catch is CancellationError {
                // 用户仍在输入或已退出搜索，无需展示错误。
            } catch {
                guard let self, searchQuery == query else { return }
                isSearchLoading = false
                applySnapshot()
                showError(error)
            }
        }
    }

    private func changeLayout(isGrid: Bool) {
        guard self.isGrid != isGrid else { return }
        self.isGrid = isGrid
        collectionView.setCollectionViewLayout(makeLayout(), animated: true)
        configureNavigation()
        collectionView.reloadData()
    }

    private func changeSort(_ sort: NodeSort) {
        viewModel.sort = sort
        configureNavigation()
        reload()
    }

    private func changeOrder(_ order: SortOrder) {
        guard viewModel.order != order else { return }
        viewModel.order = order
        configureNavigation()
        reload()
    }

    private func openFileImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    private func openPhotos() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    /**
     把系统「打开方式」或「文件」App 交来的文件拷进当前目录。

     改造前这里是一次上传：先跑完整个文件的 SHA-256，再 `/uploads/init`，再分片。
     现在收件盘就在本机，导入只是一次 `copyItem` —— 配额预检、上传进度、中途失败
     要清理临时文件这一整套都不再存在。进度条留着，是因为大文件的拷贝在手机上
     仍然要几秒。
     */
    private func importFile(at url: URL) {
        let progress = FileImportProgressViewController(fileName: url.lastPathComponent)
        present(progress, animated: true) { [weak self, weak progress] in
            guard let self, let progress else { return }
            Task {
                do {
                    _ = try await self.viewModel.importFile(at: url)
                    self.cleanupTemporaryImport(url)
                    progress.dismiss(animated: true) { [self] in self.reload() }
                } catch {
                    self.cleanupTemporaryImport(url)
                    progress.dismiss(animated: true) { [self] in self.showError(error) }
                }
            }
        }
    }

    func importExternalFile(at url: URL) -> Bool {
        guard presentedViewController == nil else { return false }
        importFile(at: url)
        return true
    }

    nonisolated private static func writeTemporaryImport(
        data: Data,
        extension fileExtension: String
    ) throws -> URL {
        let ext = fileExtension.isEmpty ? "bin" : fileExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filego-import-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated private static func copyTemporaryImport(
        from source: URL,
        extension fileExtension: String
    ) throws -> URL {
        let ext = fileExtension.isEmpty ? "bin" : fileExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("filego-import-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func cleanupTemporaryImport(_ url: URL) {
        guard url.lastPathComponent.hasPrefix("filego-import-") || url.path.contains("/Inbox/") else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func addFolder() {
        prompt(title: R.Strings.driveNewFolder.localizedString(), value: nil) { [weak self] name in
            guard let self else { return }
            Task {
                do {
                    try await self.viewModel.createFolder(name: name)
                    self.applySnapshot()
                } catch { self.showError(error) }
            }
        }
    }

    private func shareImportAddress(_ address: URL) {
        let controller = UIActivityViewController(activityItems: [address], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.last
        }
        present(controller, animated: true)
    }

    private func open(_ node: DriveNode) {
        if node.isFolder {
            if LocalDriveStore.isReceived(node.id) { return openReceived() }
            router.push(DriveListViewController(
                environment: environment,
                router: router,
                folderId: node.id,
                folderName: node.name,
                rootId: rootId,
                onShowMe: onShowMe
            ))
            return
        }

        // 改造前这里要先把文件从服务端下下来（带缓存、带去重、带取消）。现在文件
        // 就在本机，直接把原件借给预览器——`borrowing` 而不是 `init`，因为后者的
        // deinit 会删掉父目录，而这里的父目录是用户的收件文件夹。
        let file = PreviewTemporaryFile.borrowing(viewModel.fileURL(for: node))
        router.push(PreviewCoordinator.makeViewController(
            for: node, file: file, environment: environment))
    }

    private func openBreadcrumb(_ node: DriveNode) {
        guard node.id != folderId else { return }
        if let existing = router.navigationController?.viewControllers
            .compactMap({ $0 as? DriveListViewController })
            .first(where: { $0.folderId == node.id }) {
            router.popTo(existing)
        }
    }

    private func actions(for node: DriveNode) -> UIMenu {
        // 接收文件夹只在搜索结果里露面。它绑着唯一的收件地址，改名、移动、删除都不给。
        if LocalDriveStore.isReceived(node.id) {
            return UIMenu(children: [UIAction(
                title: R.Strings.driveReceivedTitle.localizedString(),
                image: UIImage(systemName: "tray.and.arrow.down")
            ) { [weak self] _ in self?.openReceived() }])
        }
        let rename = UIAction(
            title: R.Strings.driveRename.localizedString(), image: UIImage(systemName: "pencil")
        ) { [weak self] _ in self?.rename(node) }
        let move = UIAction(
            title: R.Strings.driveMove.localizedString(), image: UIImage(systemName: "folder")
        ) { [weak self] _ in self?.pickFolder(for: node, copy: false) }
        var children = [rename, move]
        if !node.isFolder {
            children.append(UIAction(
                title: R.Strings.driveCopy.localizedString(), image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in self?.pickFolder(for: node, copy: true) })
            // 只给文件，不给文件夹：一条下载链接背后是一个文件，服务端也只收一个。
            children.append(UIAction(
                title: R.Strings.shareCreate.localizedString(), image: UIImage(systemName: "link")
            ) { [weak self] _ in self?.createShareLink(for: node) })
        }
        // 移入回收站是可还原的，不做二次确认。
        let trash = UIAction(
            title: R.Strings.driveTrash.localizedString(),
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in self?.moveToTrash(node) }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: children),
            UIMenu(options: .displayInline, children: [trash])
        ])
    }

    /// 把这个文件变成一条公开的下载链接。校验和表单都在 `ShareLauncher` 里——
    /// 预览页那个入口要做的检查一模一样，两处各写一份就是它们开始走样的起点。
    private func createShareLink(for node: DriveNode) {
        ShareLauncher.start(
            from: self,
            environment: environment,
            file: viewModel.fileURL(for: node),
            filename: node.name,
            size: node.size)
    }

    private func moveToTrash(_ node: DriveNode) {
        Task {
            do { try await viewModel.moveToTrash(node); applySnapshot() }
            catch { showError(error) }
        }
    }

    private func rename(_ node: DriveNode) {
        prompt(title: R.Strings.driveRename.localizedString(), value: node.name) { [weak self] name in
            guard let self else { return }
            Task {
                do { try await self.viewModel.rename(node, to: name); self.applySnapshot() }
                catch { self.showError(error) }
            }
        }
    }

    private func pickFolder(for node: DriveNode, copy: Bool) {
        let picker = FolderPickerNavigationController.make(
            environment: environment,
            rootId: rootId,
            excludedNodeId: copy ? nil : node.id
        ) { [weak self] targetId in
            guard let self else { return }
            dismiss(animated: true)
            Task {
                do {
                    if copy { try await self.viewModel.copy(node, to: targetId) }
                    else { try await self.viewModel.move(node, to: targetId) }
                    self.applySnapshot()
                } catch { self.showError(error) }
            }
        }
        present(picker, animated: true)
    }

    private func prompt(title: String, value: String?, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = value }
        alert.addAction(UIAlertAction(title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default) { _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            completion(name)
        })
        present(alert, animated: true)
    }

    private func showError(_ error: Error) {
        // 服务端的 message 写死了 "This Mac…"，一律按 code 映射自己的文案，
        // 不要直接渲染它（见计划 §J）。
        if let apiError = error as? APIError {
            // 402 是会员门槛：弹会员页，而不是把它说成「额度用完」。
            if apiError.isUpgradeRequired {
                return PlanViewController.handleUpgradeRequired(
                    on: self, environment: environment)
            }
            if apiError.isQuota {
                showQuotaExceeded()
                return
            }
        }
        let alert = UIAlertController(
            title: R.Strings.commonError.localizedString(),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }

    private func presentToast(_ message: String) {
        PaperToast.show(message, in: view)
    }

    /**
     额度或会员门槛撞上了。服务端的 402 与配额错误走同一个出口：不是会员就弹会员页
     （App 内 StoreKit 订阅，符合 3.1.1），是会员则只说明已到当前方案上限。
     */
    private func showQuotaExceeded() {
        let alert = UIAlertController(
            title: R.Strings.quotaExceededTitle.localizedString(),
            message: R.Strings.quotaExceededMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .cancel))
        present(alert, animated: true)
    }

}

extension DriveListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let node = visibleNodes.first(where: { $0.id == id }) else { return }
        open(node)
    }

}

extension DriveListViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        scheduleSearch(for: searchText)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        dismissSearch()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

extension DriveListViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        controller.dismiss(animated: true) { [weak self] in self?.importFile(at: url) }
    }
}

extension DriveListViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider else {
            picker.dismiss(animated: true)
            return
        }
        let typeIdentifier = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "bin"
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self, weak picker] sourceURL, error in
            let copied = Result<URL, Error> {
                guard let sourceURL else {
                    throw error ?? CocoaError(.fileReadUnknown)
                }
                // PHPicker 的临时 URL 只保证在本回调返回前有效，必须在这里同步复制。
                return try Self.copyTemporaryImport(from: sourceURL, extension: fileExtension)
            }
            Task { @MainActor [weak self, weak picker] in
                guard let self, let picker else { return }
                picker.dismiss(animated: true) {
                    switch copied {
                    case .success(let url): self.importFile(at: url)
                    case .failure(let error): self.showError(error)
                    }
                }
            }
        }
    }
}

extension DriveListViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        if let mediaURL = info[.mediaURL] as? URL {
            do {
                let url = try Self.copyTemporaryImport(from: mediaURL, extension: mediaURL.pathExtension)
                picker.dismiss(animated: true) { [weak self] in self?.importFile(at: url) }
            } catch {
                picker.dismiss(animated: true) { [weak self] in self?.showError(error) }
            }
            return
        }
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.9) else {
            picker.dismiss(animated: true)
            return
        }
        do {
            let url = try Self.writeTemporaryImport(data: data, extension: "jpg")
            picker.dismiss(animated: true) { [weak self] in self?.importFile(at: url) }
        } catch {
            picker.dismiss(animated: true) { [weak self] in self?.showError(error) }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}
