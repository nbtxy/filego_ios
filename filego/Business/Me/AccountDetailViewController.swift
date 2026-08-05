import UIKit

/// diffable 的条目标识必须是 Sendable，见 MeViewController 里的同类说明。
private nonisolated enum Row: Hashable {
    case name
    case email
    case createdAt
    case delete
}

/// 账号二级页：名字（可改）、邮箱、注册时间，以及注销账号。
@MainActor
final class AccountDetailViewController: UIViewController {
    private let environment: AppEnvironment
    private var user: AccountUser

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    init(environment: AppEnvironment, profile: AccountProfile) {
        self.environment = environment
        self.user = profile.user
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.accountTitle.localizedString()
        // 分组列表要有灰底才衬得出白色卡片，这里不用 AppColor.background。
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        configureActivityIndicator()
        applySnapshot()
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
        case .name:
            var content = UIListContentConfiguration.valueCell()
            content.text = R.Strings.accountName.localizedString()
            content.secondaryText = user.displayName?.nilIfEmpty ?? "—"
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .email:
            var content = UIListContentConfiguration.valueCell()
            content.text = R.Strings.accountEmail.localizedString()
            content.secondaryText = user.email?.nilIfEmpty ?? "—"
            cell.contentConfiguration = content
            cell.accessories = []

        case .createdAt:
            var content = UIListContentConfiguration.valueCell()
            content.text = R.Strings.accountCreatedAt.localizedString()
            content.secondaryText = user.createdAt.map(Self.dateFormatter.string(from:)) ?? "—"
            cell.contentConfiguration = content
            cell.accessories = []

        case .delete:
            var content = UIListContentConfiguration.cell()
            content.text = R.Strings.accountDelete.localizedString()
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([.name, .email, .createdAt], toSection: 0)
        snapshot.appendItems([.delete], toSection: 1)
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    // MARK: - 改名

    private func promptRename() {
        let alert = UIAlertController(
            title: R.Strings.accountNameEdit.localizedString(),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] textField in
            textField.text = self?.user.displayName
            textField.placeholder = R.Strings.accountNamePlaceholder.localizedString()
            textField.clearButtonMode = .whileEditing
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        let save = UIAlertAction(
            title: R.Strings.commonSave.localizedString(),
            style: .default
        ) { [weak self, weak alert] _ in
            let input = alert?.textFields?.first?.text ?? ""
            self?.submitRename(input.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        alert.addAction(save)
        present(alert, animated: true)
    }

    private func submitRename(_ displayName: String) {
        guard displayName.isEmpty == false else { return }
        setBusy(true)
        Task {
            do {
                user = try await environment.accountService.updateDisplayName(displayName)
                setBusy(false)
                applySnapshot()
            } catch {
                AppLogger.error("修改名字失败", error: error)
                setBusy(false)
                presentError(error.localizedDescription)
            }
        }
    }

    // MARK: - 注销

    /// 一次确认就够，但文案要把后果说清：删了不可恢复。
    private func confirmDelete() {
        let alert = UIAlertController(
            title: R.Strings.accountDeleteConfirmTitle.localizedString(),
            message: R.Strings.accountDeleteConfirmMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.accountDeleteConfirmAction.localizedString(),
            style: .destructive
        ) { [weak self] _ in
            self?.deleteAccount()
        })
        present(alert, animated: true)
    }

    private func deleteAccount() {
        setBusy(true)
        Task {
            do {
                try await environment.accountService.deleteAccount()
                // 成功后不做导航：清态通知会让 RootViewController 切回登录页。
            } catch {
                AppLogger.error("注销账号失败", error: error)
                setBusy(false)
                presentError(
                    error.localizedDescription,
                    title: R.Strings.accountDeleteFailed.localizedString()
                )
            }
        }
    }

    // MARK: - 辅助

    private func setBusy(_ busy: Bool) {
        if busy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        view.isUserInteractionEnabled = busy == false
        navigationItem.hidesBackButton = busy
    }

    private func presentError(_ message: String, title: String? = nil) {
        let alert = UIAlertController(
            title: title ?? R.Strings.commonError.localizedString(),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

extension AccountDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .name: promptRename()
        case .delete: confirmDelete()
        case .email, .createdAt, nil: break
        }
    }
}
