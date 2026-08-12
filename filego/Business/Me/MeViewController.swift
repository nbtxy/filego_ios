import UIKit

/// diffable 的条目标识必须是 Sendable。本模块 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 不显式写 `nonisolated` 的话 Hashable conformance 会带上主线程隔离，泛型约束就对不上。
private nonisolated enum Row: Hashable {
    case pro
    case account
    case storage
    case cache
    case trash
    #if DEBUG
    case debugPanel
    #endif
    case signOut
    case failure
}

/// 「我的」页：只放入口，不铺细节。
///
/// 账号与存储空间各自是一个入口，具体信息在二级页展开——一级页不再直接暴露邮箱。
@MainActor
final class MeViewController: UIViewController {
    private let environment: AppEnvironment
    private let onNavigate: ((UIViewController) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var profile: AccountProfile?
    private var cacheStatistics = FileCacheManager.Statistics(bytes: 0, fileCount: 0)
    private var loadErrorMessage: String?

    init(
        environment: AppEnvironment,
        onNavigate: ((UIViewController) -> Void)? = nil
    ) {
        self.environment = environment
        self.onNavigate = onNavigate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        configureCollectionView()
        configureActivityIndicator()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 二级页改了名字、清了回收站再返回，这里的入口摘要都要跟着变。
        if isMovingToParent == false { reload() }
    }

    // MARK: - 视图

    private func configureCollectionView() {
        let configuration = UICollectionLayoutListConfiguration.paperInsetGrouped()
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.backgroundColor = AppColor.background
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> {
            [weak self] cell, _, row in
            self?.configure(cell, for: row)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) {
            collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: row
            )
        }
    }

    private func configureActivityIndicator() {
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        PaperListCellStyle.apply(to: cell)
        switch row {
        case .pro:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            // 付费档是这页唯一的「升级」出口，用点缀色的柠檬绿冠冕最扎眼。
            content.image = UIImage(systemName: "crown.fill")
            content.imageProperties.tintColor = AppColor.FileTile.folderForeground
            let plan = profile?.plan
            if plan?.isPaid == true {
                content.text = R.Strings.proEntryActive.localizedString()
                content.secondaryText = plan?.expiresAt.map {
                    R.Strings.proEntryExpires.formatted(Self.dateFormatter.string(from: $0))
                }
            } else {
                content.text = R.Strings.proEntryUpgrade.localizedString()
                content.secondaryText = R.Strings.proEntryFree.localizedString()
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .account:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.meAccount.localizedString()
            content.secondaryText = profile?.user.displayName?.nilIfEmpty ?? "—"
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .storage:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.meStorageTitle.localizedString()
            if let storage = profile?.storage {
                content.secondaryText = R.Strings.meStorageValue.formatted(
                    ByteFormatting.string(storage.usedBytes),
                    ByteFormatting.string(storage.quotaBytes)
                )
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .cache:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.cacheTitle.localizedString()
            content.secondaryText = ByteFormatting.string(cacheStatistics.bytes)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .trash:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.trashTitle.localizedString()
            if let trashed = profile?.counts.trashed, trashed > 0 {
                content.secondaryText = String(trashed)
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        #if DEBUG
        case .debugPanel:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.image = UIImage(systemName: "ladybug")
            content.text = R.Strings.debugPanelTitle.localizedString()
            content.secondaryText = BackendConfig.baseURL.host ?? BackendConfig.baseURL.absoluteString
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        #endif

        case .signOut:
            var content = UIListContentConfiguration.cell()
            content.text = R.Strings.meSignOut.localizedString()
            content.textProperties.color = AppColor.danger
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []

        case .failure:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.meLoadFailed.localizedString()
            content.secondaryText = loadErrorMessage
            content.secondaryTextProperties.color = AppColor.textSecondary
            cell.contentConfiguration = content
            cell.accessories = []
        }
    }

    // MARK: - 数据

    private func reload() {
        activityIndicator.startAnimating()
        Task {
            async let loadedCacheStatistics = loadCacheStatistics()
            do {
                profile = try await environment.accountService.loadProfile()
                loadErrorMessage = nil
            } catch {
                AppLogger.error("加载账号信息失败", error: error)
                profile = nil
                loadErrorMessage = error.localizedDescription
            }
            cacheStatistics = await loadedCacheStatistics
            // 上传前的本地预检要用最新的用量快照，见 StorageSnapshotStore。
            environment.storageSnapshot.update(profile?.storage)
            activityIndicator.stopAnimating()
            applySnapshot()
        }
    }

    private func loadCacheStatistics() async -> FileCacheManager.Statistics {
        guard let userID = environment.sessionManager.currentUserID else {
            return .init(bytes: 0, fileCount: 0)
        }
        return await FileCacheManager.shared.statistics(
            userID: userID,
            baseURL: BackendConfig.baseURL
        )
    }

    /// 抽屉每次打开时刷新摘要，覆盖二级页修改账号或清空回收站后的变化。
    func refresh() {
        guard isViewLoaded else { return }
        reload()
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        if profile == nil {
            // 拉取失败时只留错误提示和退出登录，避免点进空白的二级页。
            snapshot.appendSections([0])
            snapshot.appendItems([.failure], toSection: 0)
        } else {
            // 会员入口独占第一节：insetGrouped 下自然渲染成顶部单独一张卡。
            snapshot.appendSections([0, 1, 2])
            snapshot.appendItems([.pro], toSection: 0)
            snapshot.appendItems([.account, .storage, .cache], toSection: 1)
            snapshot.appendItems([.trash], toSection: 2)
        }
        #if DEBUG
        let debugSection = snapshot.sectionIdentifiers.count
        snapshot.appendSections([debugSection])
        snapshot.appendItems([.debugPanel], toSection: debugSection)
        #endif
        let signOutSection = snapshot.sectionIdentifiers.count
        snapshot.appendSections([signOutSection])
        snapshot.appendItems([.signOut], toSection: signOutSection)
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    // MARK: - 动作

    private func didSelect(_ row: Row) {
        switch row {
        case .pro:
            navigate(ProUpgradeViewController(environment: environment))
        case .account:
            guard let profile else { return }
            navigate(
                AccountDetailViewController(environment: environment, profile: profile)
            )
        case .storage:
            guard let profile else { return }
            navigate(
                StorageDetailViewController(environment: environment, profile: profile)
            )
        case .cache:
            navigate(CacheSettingsViewController(environment: environment))
        case .trash:
            navigate(TrashViewController(environment: environment))
        #if DEBUG
        case .debugPanel:
            navigate(DebugPanelViewController(environment: environment))
        #endif
        case .signOut:
            confirmSignOut()
        case .failure:
            reload()
        }
    }

    private func navigate(_ viewController: UIViewController) {
        if let onNavigate {
            onNavigate(viewController)
        } else {
            navigationController?.pushViewController(viewController, animated: true)
        }
    }

    private func confirmSignOut() {
        let alert = UIAlertController(
            title: R.Strings.meSignOutConfirm.localizedString(),
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.meSignOut.localizedString(),
            style: .destructive
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.environment.accountService.signOut()
                // 清态后 RootViewController 会收到通知并切回登录页
            }
        })
        present(alert, animated: true)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

extension MeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        didSelect(row)
    }
}
