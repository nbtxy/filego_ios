import PhotosUI
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
    private let emptyLabel = UILabel()
    private let addFolderButton = UIButton(type: .system)
    private let fileActivityIndicator = UIActivityIndicatorView(style: .medium)
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
            session: environment.sessionManager,
            preferences: environment.keyValueStore
        )
        self.isGrid = environment.keyValueStore.value(forKey: "drive.grid") ?? false
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        openFileTask?.cancel()
        searchTask?.cancel()
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
        reload()
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

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

        emptyLabel.text = R.Strings.driveEmpty.localizedString()
        emptyLabel.font = AppTypography.body
        emptyLabel.textColor = AppColor.textSecondary
        emptyLabel.textAlignment = .center
        collectionView.backgroundView = emptyLabel

        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self,
                  let node = visibleNodes.first(where: { $0.id == id }),
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "node", for: indexPath
                  ) as? DriveNodeCell else { return nil }
            cell.configure(with: node, menu: actions(for: node), grid: isGrid)
            return cell
        }
    }

    private func configureAddFolderButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        )
        configuration.baseBackgroundColor = AppColor.accent
        configuration.baseForegroundColor = .white
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
                    title: R.Strings.driveImportTakePhoto.localizedString(),
                    image: UIImage(systemName: "camera")
                ) { [weak self] _ in self?.openCamera() },
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
        addFolderButton.layer.shadowColor = UIColor.black.cgColor
        addFolderButton.layer.shadowOpacity = 0.18
        addFolderButton.layer.shadowRadius = 8
        addFolderButton.layer.shadowOffset = CGSize(width: 0, height: 4)
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
        fileActivityIndicator.hidesWhenStopped = true
        fileActivityIndicator.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        fileActivityIndicator.layer.cornerRadius = 12
        fileActivityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fileActivityIndicator)
        NSLayoutConstraint.activate([
            fileActivityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fileActivityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            fileActivityIndicator.widthAnchor.constraint(equalToConstant: 52),
            fileActivityIndicator.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func makeLayout() -> UICollectionViewLayout {
        if isGrid {
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(0.5),
                heightDimension: .absolute(132)
            ))
            item.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(132)),
                subitems: [item, item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 6, leading: 10, bottom: 16, trailing: 10)
            return UICollectionViewCompositionalLayout(section: section)
        }
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
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
        // TODO: [star] 排查用，定位后删除
        AppLogger.info(
            "[star] applySnapshot old=\(existing.count) new=\(ids.count)"
            + " reconfigure=\(reconfigured.count) animate=\(isStructuralChange)"
        )
        snapshot.reconfigureItems(reconfigured)
        // TODO: [star] 排查用，定位后删除。动画结束后回读真实上屏状态：
        // visibleCells 的条数、每个 cell 期望值 vs 实际 isHidden，⚠️ 表示对不上。
        dataSource.apply(snapshot, animatingDifferences: isStructuralChange) { [weak self] in
            guard let self else { return }
            let dump = collectionView.visibleCells
                .compactMap { $0 as? DriveNodeCell }
                .map(\.debugStarState)
                .joined(separator: " | ")
            AppLogger.info(
                "[star] afterApply visible=\(collectionView.visibleCells.count) \(dump)"
            )
        }
        emptyLabel.text = searchQuery.isEmpty
            ? R.Strings.driveEmpty.localizedString()
            : R.Strings.driveSearchEmpty.localizedString()
        emptyLabel.isHidden = isSearchLoading || !nodes.isEmpty
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

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showError(NSError(
                domain: "FileGo.Camera",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: R.Strings.driveImportCameraUnavailable.localizedString()]
            ))
            return
        }
        CameraPermissionManager.shared.requestPermission { [weak self] result in
            switch result {
            case .granted: self?.presentCamera()
            case .justDenied: break
            case .previouslyDenied: self?.presentCameraDeniedAlert()
            }
        }
    }

    private func presentCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentCameraDeniedAlert() {
        let alert = UIAlertController(
            title: R.Strings.driveImportCameraDenied.localizedString(),
            message: R.Strings.driveImportCameraDeniedMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportOpenSettings.localizedString(),
            style: .default
        ) { _ in CameraPermissionManager.shared.openSystemSettings() })
        present(alert, animated: true)
    }

    private func importFile(at url: URL) {
        // 本地快速失败：FileUploadService 会先把整个文件跑一遍 SHA-256 才调 /uploads/init，
        // 免费档只有 20 MB，选个大视频要白算一遍完整哈希才被拒。这里先按最近一次
        // 用量快照挡掉明显放不下的。
        //
        // **只用于快速失败，绝不用于放行**——快照可能过期（别的设备刚传了东西、
        // Pro 刚过期），服务端那条原子条件 UPDATE 才是唯一权威。
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           !environment.storageSnapshot.likelyFits(Int64(size)) {
            cleanupTemporaryImport(url)
            showQuotaExceeded()
            return
        }

        let progress = FileImportProgressViewController(fileName: url.lastPathComponent)
        present(progress, animated: true) { [weak self, weak progress] in
            guard let self, let progress else { return }
            Task {
                do {
                    _ = try await FileUploadService.upload(
                        fileURL: url,
                        parentId: self.folderId,
                        session: self.environment.sessionManager
                    ) { [weak progress] fraction in
                        progress?.updateProgress(fraction)
                    }
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

    private func createImportAddress() {
        Task {
            do {
                let result: ImportAddressResult = try await environment.sessionManager.request(
                    NodeAPI.createImportAddress(id: folderId)
                )
                presentImportAddress(result)
            } catch {
                showError(error)
            }
        }
    }

    private func presentImportAddress(_ result: ImportAddressResult) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let message = R.Strings.driveImportAddressMessage.formatted(
            formatter.string(from: result.expiresAt),
            result.importAddress.absoluteString
        )
        let alert = UIAlertController(
            title: R.Strings.driveImportAddress.localizedString(),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportCopyAddress.localizedString(),
            style: .default
        ) { _ in
            UIPasteboard.general.url = result.importAddress
        })
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportShareAddress.localizedString(),
            style: .default
        ) { [weak self] _ in
            self?.shareImportAddress(result.importAddress)
        })
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportResetAddress.localizedString(),
            style: .destructive
        ) { [weak self] _ in
            self?.confirmResetImportAddress()
        })
        alert.addAction(UIAlertAction(
            title: R.Strings.commonOk.localizedString(),
            style: .cancel
        ))
        present(alert, animated: true)
    }

    private func confirmResetImportAddress() {
        let alert = UIAlertController(
            title: R.Strings.driveImportResetConfirmTitle.localizedString(),
            message: R.Strings.driveImportResetConfirmMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportResetAddress.localizedString(),
            style: .destructive
        ) { [weak self] _ in
            self?.resetImportAddress()
        })
        present(alert, animated: true)
    }

    private func resetImportAddress() {
        Task {
            do {
                let result: ImportAddressResult = try await environment.sessionManager.request(
                    NodeAPI.resetImportAddress(id: folderId)
                )
                presentImportAddress(result)
            } catch {
                showError(error)
            }
        }
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

        openFileTask?.cancel()
        fileActivityIndicator.startAnimating()
        collectionView.isUserInteractionEnabled = false
        openFileTask = Task { [weak self] in
            do {
                guard let userID = self?.environment.sessionManager.currentUserID else {
                    throw FileGoAPIError.unauthorized
                }
                let file = try await FileDownloadService.download(node: node, userID: userID)
                guard !Task.isCancelled else {
                    file.discard()
                    return
                }
                self?.router.push(PreviewCoordinator.makeViewController(for: node, file: file))
            } catch is CancellationError {
                // 页面销毁或用户发起了另一次打开，不展示错误。
            } catch {
                self?.showError(error)
            }
            self?.fileActivityIndicator.stopAnimating()
            self?.collectionView.isUserInteractionEnabled = true
        }
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
        // TODO: [star] 排查用，定位后删除。menuStarred 是菜单闭包捕获的旧值，
        // 若它和界面上显示的菜单标题对不上，说明 cell 没被重建。
        AppLogger.info(
            "[star] setStar id=\(node.id) name=\(node.name) menuStarred=\(node.starred) → send starred=\(starred)"
        )
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
        // 配额超限单独处理：所有上传路径的错误都汇到这里，在这一处拦就够了。
        // 给用户一条出路，而不是一句无从下手的「存储空间不足」。
        if case let FileGoAPIError.business(code, _) = error, code == 40301 {
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

    private func showQuotaExceeded() {
        // 两档容量取服务端下发的值，与付费墙同源，不在端上写死。
        let status = environment.storeKitService.status
        let alert = UIAlertController(
            title: R.Strings.quotaExceededTitle.localizedString(),
            message: R.Strings.quotaExceededMessage.formatted(
                ByteFormatting.string(status.freeQuotaBytes),
                ByteFormatting.string(status.proQuotaBytes)
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: R.Strings.quotaExceededUpgrade.localizedString(),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(
                ProUpgradeViewController(environment: self.environment),
                animated: true
            )
        })
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

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard searchQuery.isEmpty else { return }
        Task {
            do {
                if try await viewModel.loadNextPageIfNeeded(near: indexPath.item) { applySnapshot() }
            } catch { showError(error) }
        }
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
