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
    private let addFolderButton = UIButton(type: .system)
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
        // 网页 `.search-wrap .input`：白底胶囊 + `--line` 描边。
        let field = searchBar.searchTextField
        field.backgroundColor = AppColor.surface
        field.textColor = AppColor.textPrimary
        field.layer.cornerRadius = 18
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1
        field.layer.borderColor = AppColor.line.cgColor
        field.clipsToBounds = true
        return searchBar
    }()
    private var isGrid: Bool {
        didSet { environment.keyValueStore.set(isGrid, forKey: "drive.grid") }
    }

    private var visibleNodes: [DriveNode] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.nodes }
        return searchResults
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

    deinit {
        openFileTask?.cancel()
        searchTask?.cancel()
        // 基于 block 的观察者以 token 为键，`removeObserver(self)` 摘不掉它。
        if let landedObserver { NotificationCenter.default.removeObserver(landedObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderName
        view.backgroundColor = AppColor.background
        configureNavigation()
        configureCollectionView()
        configureBreadcrumbs()
        configureAddFolderButton()
        configureFileActivityIndicator()
        observeContentSizeCategory()
        observeLandedFiles()
        reload()
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
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
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
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: folderId == rootId ? 0 : 36
            ),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        collectionView.backgroundView = emptyView

        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self,
                  let node = visibleNodes.first(where: { $0.id == id }),
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "node", for: indexPath
                  ) as? DriveNodeCell else { return nil }
            cell.configure(
                with: node,
                menu: actions(for: node),
                grid: isGrid,
                isFirst: id == visibleNodes.first?.id,
                isLast: id == visibleNodes.last?.id
            )
            return cell
        }
    }

    private func configureAddFolderButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        )
        // 与网页 `.seg button.active` / `.nav-item.active` 同一套：墨绿底 + 柠檬绿图形。
        configuration.baseBackgroundColor = AppColor.ink
        configuration.baseForegroundColor = AppColor.lime
        configuration.cornerStyle = .capsule
        addFolderButton.configuration = configuration
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
                    title: R.Strings.driveImportAddress.localizedString(),
                    image: UIImage(systemName: "link.badge.plus")
                ) { [weak self] _ in self?.createImportAddress() }
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
        AppShadow.raisedButton(addFolderButton)
        addFolderButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addFolderButton)

        NSLayoutConstraint.activate([
            addFolderButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            addFolderButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            addFolderButton.widthAnchor.constraint(equalToConstant: 56),
            addFolderButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    private func configureFileActivityIndicator() {
        // 白卡 + `--line` 描边 + `--shadow-sm`，与列表里的卡片同一套质感。
        activityBackdrop.backgroundColor = AppColor.surface
        activityBackdrop.layer.cornerRadius = AppRadius.tile
        activityBackdrop.layer.cornerCurve = .continuous
        activityBackdrop.layer.borderWidth = 1
        activityBackdrop.layer.borderColor = AppColor.line.cgColor
        activityBackdrop.isHidden = true
        activityBackdrop.translatesAutoresizingMaskIntoConstraints = false
        AppShadow.small(activityBackdrop)

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
            let height = gridItemHeight
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(0.5),
                heightDimension: .absolute(height)
            ))
            // 网页 `.grid` 的 gap 是 14，两侧各摊一半。
            item.contentInsets = .init(top: 7, leading: 7, bottom: 7, trailing: 7)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                subitems: [item, item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 7, leading: 9, bottom: 16, trailing: 9)
            return UICollectionViewCompositionalLayout(section: section)
        }

        // 网页 `.rows`：整段套一张白卡。
        return PaperSectionBackgroundView.makeListLayout { [weak self] _ in
            self?.visibleNodes.count ?? 0
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections(["main"])
        let nodes = visibleNodes
        let ids = nodes.map(\.id)
        snapshot.appendItems(ids)
        // id 不变但内容变了（加星、重命名）时 diff 为空，需显式 reconfigure 才会重建 cell。
        let previousIDs = dataSource.snapshot().itemIdentifiers
        let existing = Set(previousIDs)
        let reconfigured = ids.filter(existing.contains)
        // 纯内容更新（加星、重命名）时不能开动画：apply 的交叉淡入会在 cell 上留下一张旧内容的
        // 快照，即使 starView 已经 isHidden，旧快照里的星号仍然盖在上面，直到 cell 被重建
        // （切换列表/宫格触发 reloadData）才消失。只有增删移这类结构变化才需要动画。
        let isStructuralChange = previousIDs != ids
        snapshot.reconfigureItems(reconfigured)
        dataSource.apply(snapshot, animatingDifferences: isStructuralChange)
        // 空/非空之间切换时（搜索无结果、清空目录）要重算 section，
        // 否则那张白卡会以 0 行的高度留在原地，成为一条扁药丸。
        if previousIDs.isEmpty != ids.isEmpty {
            collectionView.collectionViewLayout.invalidateLayout()
        }

        emptyView.update(
            glyph: searchQuery.isEmpty ? "▱" : "⌕",
            title: searchQuery.isEmpty
                ? R.Strings.driveEmpty.localizedString()
                : R.Strings.driveSearchEmpty.localizedString()
        )
        emptyView.isHidden = isSearchLoading || !nodes.isEmpty
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
        addFolderButton.isHidden = false
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
                    progress.dismiss(animated: true) { [weak self] in self?.reload() }
                } catch {
                    self.cleanupTemporaryImport(url)
                    progress.dismiss(animated: true) { [weak self] in self?.showError(error) }
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

    /**
     这个文件夹的收件地址。

     改造前是向自家后端要一条有效期一天的明文上传链接；现在是这台设备名下、绑定到
     本文件夹的那个 Stolnk inbox —— `ryan-phone.stolnk.com/<slug>`，不过期，内容
     端到端加密，只有本机 Secure Enclave 里的密钥能解开。

     没有绑定就说明这个文件夹还不是收件目标。真正的 inbox 管理（新建、改路径、
     Reset、暂停、删除）在 InboxList，这里只负责把已有的那条地址交出去。
     */
    private func createImportAddress() {
        guard let inbox = boundInbox() else {
            showNoInboxForThisFolder()
            return
        }
        presentImportAddress(inbox)
    }

    /// 找到落地目录正是本文件夹的那个 inbox。
    private func boundInbox() -> InboxSummary? {
        let here = environment.drive.url(for: folderId).standardizedFileURL
        return environment.stolnk.inboxes.first { inbox in
            environment.stolnk.folder(for: inbox.inboxID)?.standardizedFileURL == here
        }
    }

    private func showNoInboxForThisFolder() {
        let alert = UIAlertController(
            title: R.Strings.driveImportAddress.localizedString(),
            message: R.Strings.inboxNotBoundMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .cancel))
        present(alert, animated: true)
    }

    private func presentImportAddress(_ inbox: InboxSummary) {
        let alert = UIAlertController(
            title: R.Strings.driveImportAddress.localizedString(),
            message: inbox.url,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportCopyAddress.localizedString(),
            style: .default
        ) { _ in
            UIPasteboard.general.string = inbox.url
        })
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportShareAddress.localizedString(),
            style: .default
        ) { [weak self] _ in
            guard let url = URL(string: inbox.url) else { return }
            self?.shareImportAddress(url)
        })
        alert.addAction(UIAlertAction(
            title: R.Strings.commonOk.localizedString(),
            style: .cancel
        ))
        present(alert, animated: true)
    }

    private func shareImportAddress(_ address: URL) {
        let controller = UIActivityViewController(activityItems: [address], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = addFolderButton
            popover.sourceRect = addFolderButton.bounds
        }
        present(controller, animated: true)
    }

    private func open(_ node: DriveNode) {
        if node.isFolder {
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
        router.push(PreviewCoordinator.makeViewController(for: node, file: file))
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
        let star = UIAction(
            title: node.starred ? R.Strings.driveUnstar.localizedString() : R.Strings.driveStar.localizedString(),
            image: UIImage(systemName: node.starred ? "star.slash" : "star")
        ) { [weak self] _ in self?.setStar(node, starred: !node.starred) }
        let rename = UIAction(
            title: R.Strings.driveRename.localizedString(), image: UIImage(systemName: "pencil")
        ) { [weak self] _ in self?.rename(node) }
        let move = UIAction(
            title: R.Strings.driveMove.localizedString(), image: UIImage(systemName: "folder")
        ) { [weak self] _ in self?.pickFolder(for: node, copy: false) }
        var children = [star, rename, move]
        if !node.isFolder {
            children.append(UIAction(
                title: R.Strings.driveCopy.localizedString(), image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in self?.pickFolder(for: node, copy: true) })
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

    private func moveToTrash(_ node: DriveNode) {
        Task {
            do { try await viewModel.moveToTrash(node); applySnapshot() }
            catch { showError(error) }
        }
    }

    private func setStar(_ node: DriveNode, starred: Bool) {
        Task {
            do { try await viewModel.setStarred(node, starred: starred); applySnapshot() }
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
        if let apiError = error as? APIError, apiError.isQuota || apiError.isUpgradeRequired {
            showQuotaExceeded()
            return
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
     中转额度用完了。

     iOS 端目前没有购买入口（IAP 是 M3），所以这里只陈述现状，不引导升级——
     App Store 3.1.1 不允许在 app 内引导站外购买，而站内购买还没做。额度用尽
     只暂停新的上传，已经在路上的文件和手机上已有的文件都不受影响。
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
