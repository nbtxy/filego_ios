import UIKit

/// diffable 的条目标识必须是 Sendable。本模块 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 不显式写 `nonisolated` 的话 Hashable conformance 会带上主线程隔离，泛型约束就对不上。
private nonisolated enum Row: Hashable {
    case account
    case storage
    case trash
    case signOut
    case failure
}

/// 「我的」页：只放入口，不铺细节。
///
/// 账号与存储空间各自是一个入口，具体信息在二级页展开——一级页不再直接暴露邮箱。
@MainActor
final class MeViewController: UIViewController {
    private let environment: AppEnvironment

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var profile: AccountProfile?
    private var loadErrorMessage: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.tabMe.localizedString()
        // 分组列表要有灰底才衬得出白色卡片，这里不用 AppColor.background。
        view.backgroundColor = .systemGroupedBackground
        configureCollectionView()
        configureActivityIndicator()
        #if DEBUG
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "network"),
            style: .plain,
            target: self,
            action: #selector(showHTTPHistory)
        )
        #endif
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 二级页改了名字、清了回收站再返回，这里的入口摘要都要跟着变。
        if isMovingToParent == false { reload() }
    }

    // MARK: - 视图

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = .clear
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.backgroundColor = .systemGroupedBackground
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
        switch row {
        case .account:
            var content = UIListContentConfiguration.valueCell()
            content.text = R.Strings.meAccount.localizedString()
            content.secondaryText = profile?.user.displayName?.nilIfEmpty ?? "—"
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .storage:
            var content = UIListContentConfiguration.valueCell()
            content.text = R.Strings.meStorageTitle.localizedString()
            if let storage = profile?.storage {
                content.secondaryText = R.Strings.meStorageValue.formatted(
                    ByteFormatting.string(storage.usedBytes),
                    ByteFormatting.string(storage.quotaBytes)
                )
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .trash:
            var content = UIListContentConfiguration.valueCell()
            content.text = R.Strings.trashTitle.localizedString()
            if let trashed = profile?.counts.trashed, trashed > 0 {
                content.secondaryText = String(trashed)
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .signOut:
            var content = UIListContentConfiguration.cell()
            content.text = R.Strings.meSignOut.localizedString()
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []

        case .failure:
            var content = UIListContentConfiguration.cell()
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
            do {
                profile = try await environment.accountService.loadProfile()
                loadErrorMessage = nil
            } catch {
                AppLogger.error("加载账号信息失败", error: error)
                profile = nil
                loadErrorMessage = error.localizedDescription
            }
            activityIndicator.stopAnimating()
            applySnapshot()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        if profile == nil {
            // 拉取失败时只留错误提示和退出登录，避免点进空白的二级页。
            snapshot.appendSections([0, 1])
            snapshot.appendItems([.failure], toSection: 0)
            snapshot.appendItems([.signOut], toSection: 1)
        } else {
            snapshot.appendSections([0, 1, 2])
            snapshot.appendItems([.account, .storage], toSection: 0)
            snapshot.appendItems([.trash], toSection: 1)
            snapshot.appendItems([.signOut], toSection: 2)
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    // MARK: - 动作

    private func didSelect(_ row: Row) {
        switch row {
        case .account:
            guard let profile else { return }
            navigationController?.pushViewController(
                AccountDetailViewController(environment: environment, profile: profile),
                animated: true
            )
        case .storage:
            guard let profile else { return }
            navigationController?.pushViewController(
                StorageDetailViewController(environment: environment, profile: profile),
                animated: true
            )
        case .trash:
            navigationController?.pushViewController(
                TrashViewController(environment: environment),
                animated: true
            )
        case .signOut:
            confirmSignOut()
        case .failure:
            reload()
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

    #if DEBUG
    @objc private func showHTTPHistory() {
        navigationController?.pushViewController(HTTPHistoryViewController(), animated: true)
    }
    #endif
}

extension MeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        didSelect(row)
    }
}
