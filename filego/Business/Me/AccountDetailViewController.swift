import UIKit

/// diffable 的条目标识必须是 Sendable，见 MeViewController 里的同类说明。
private nonisolated enum Row: Hashable {
    case name
    case email
    case userId
    case createdAt
    case delete
}

/// 账号二级页：名字（可改）、邮箱、用户 ID（可复制）、注册时间，以及注销账号。
@MainActor
final class AccountDetailViewController: UIViewController {
    private let environment: AppEnvironment
    private var user: AccountUser

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private weak var toast: UIView?

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

        case .userId:
            // ID 比一行 valueCell 的右侧空间长得多，用 subtitle 让它整行铺开。
            var content = UIListContentConfiguration.subtitleCell()
            content.text = R.Strings.accountUserId.localizedString()
            content.secondaryText = user.id
            content.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
            content.secondaryTextProperties.color = AppColor.textSecondary
            content.secondaryTextProperties.numberOfLines = 1
            content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            cell.contentConfiguration = content
            // 点一下就复制，右边这个图标是唯一的可复制提示。
            let icon = UIImageView(image: UIImage(systemName: "doc.on.doc"))
            icon.tintColor = AppColor.textSecondary
            cell.accessories = [
                .customView(configuration: .init(
                    customView: icon,
                    placement: .trailing(displayed: .always)
                ))
            ]

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
        snapshot.appendItems([.name, .email, .userId, .createdAt], toSection: 0)
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

    // MARK: - 复制用户 ID

    private func copyUserID() {
        UIPasteboard.general.string = user.id
        HapticManager.notification(.success)
        presentToast(R.Strings.accountUserIdCopied.localizedString())
    }

    /// 复制这种一次性反馈不值得弹 alert，浮一条自己消失的提示就够。
    private func presentToast(_ message: String) {
        toast?.removeFromSuperview()

        let container = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        container.layer.cornerRadius = AppSpacing.medium
        container.clipsToBounds = true
        container.alpha = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        // 提示只是路过，别挡住底下的点击。
        container.isUserInteractionEnabled = false

        let label = UILabel()
        label.text = message
        label.font = AppTypography.caption
        label.textColor = AppColor.textPrimary
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.contentView.addSubview(label)

        view.addSubview(container)
        toast = container
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: AppSpacing.small),
            label.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -AppSpacing.small),
            label.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: AppSpacing.medium),
            label.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -AppSpacing.medium),
            container.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            container.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -AppSpacing.large
            ),
            container.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: AppSpacing.large
            )
        ])

        UIView.animate(withDuration: 0.2) { container.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 1.6) {
            container.alpha = 0
        } completion: { [weak self] _ in
            container.removeFromSuperview()
            if self?.toast === container { self?.toast = nil }
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
        case .userId: copyUserID()
        case .delete: confirmDelete()
        case .email, .createdAt, nil: break
        }
    }
}
