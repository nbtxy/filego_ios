import UIKit

/// 回收站。列表只含「回收根」，被回收文件夹里的子项由服务端隐藏。
/// 这里的项目不能预览（服务端会拒绝回收站里的下载），点按不做事，操作都在 ⋯ 菜单里。
@MainActor
final class TrashViewController: UIViewController {
    private let viewModel: TrashViewModel
    private let trashRetentionDays: Int

    private let noticeLabel = UILabel()
    private let emptyLabel = UILabel()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var emptyAllButton: UIBarButtonItem!

    init(environment: AppEnvironment) {
        self.viewModel = TrashViewModel(session: environment.sessionManager)
        self.trashRetentionDays = environment.appConfigStore.trashRetentionDays
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.trashTitle.localizedString()
        view.backgroundColor = AppColor.background
        navigationItem.largeTitleDisplayMode = .never
        configureNavigation()
        configureNotice()
        configureCollectionView()
        reload()
    }

    private func configureNavigation() {
        emptyAllButton = UIBarButtonItem(
            title: R.Strings.trashEmptyAll.localizedString(),
            style: .plain,
            target: self,
            action: #selector(confirmEmptyAll)
        )
        emptyAllButton.tintColor = .systemRed
        emptyAllButton.isEnabled = false
        navigationItem.rightBarButtonItem = emptyAllButton
    }

    private func configureNotice() {
        noticeLabel.text = R.Strings.trashNotice.formatted(trashRetentionDays)
        noticeLabel.font = AppTypography.caption
        noticeLabel.textColor = AppColor.textSecondary
        noticeLabel.numberOfLines = 0
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            noticeLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: AppSpacing.small
            ),
            noticeLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: AppSpacing.medium
            ),
            noticeLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -AppSpacing.medium
            )
        ])
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.backgroundColor = AppColor.background
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(DriveNodeCell.self, forCellWithReuseIdentifier: "node")
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(
                equalTo: noticeLabel.bottomAnchor,
                constant: AppSpacing.small
            ),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        emptyLabel.text = R.Strings.trashEmpty.localizedString()
        emptyLabel.font = AppTypography.body
        emptyLabel.textColor = AppColor.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        collectionView.backgroundView = emptyLabel

        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self,
                  let node = viewModel.nodes.first(where: { $0.id == id }),
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "node", for: indexPath
                  ) as? DriveNodeCell else { return nil }
            cell.configure(
                with: node,
                menu: actions(for: node),
                grid: false,
                detailOverride: Self.remainingText(
                    for: node,
                    retentionDays: trashRetentionDays
                )
            )
            return cell
        }
    }

    /// 「还有 N 天自动删除」。当天到期只说「即将自动删除」，避免出现「还有 0 天」。
    private static func remainingText(for node: DriveNode, retentionDays: Int) -> String {
        guard let days = node.trashDaysRemaining(retentionDays: retentionDays), days > 0 else {
            return R.Strings.trashExpiringSoon.localizedString()
        }
        return R.Strings.trashDaysLeft.formatted(days)
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections(["main"])
        snapshot.appendItems(viewModel.nodes.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: true)
        emptyLabel.isHidden = !viewModel.nodes.isEmpty
        emptyAllButton.isEnabled = !viewModel.nodes.isEmpty
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

    // MARK: - 动作

    private func actions(for node: DriveNode) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: R.Strings.trashRestore.localizedString(),
                image: UIImage(systemName: "arrow.uturn.backward")
            ) { [weak self] _ in self?.restore(node) },
            UIAction(
                title: R.Strings.trashDeleteForever.localizedString(),
                image: UIImage(systemName: "trash.slash"),
                attributes: .destructive
            ) { [weak self] _ in self?.confirmDeleteForever(node) }
        ])
    }

    private func restore(_ node: DriveNode) {
        Task {
            do { try await viewModel.restore(node); applySnapshot() }
            catch { showError(error) }
        }
    }

    private func confirmDeleteForever(_ node: DriveNode) {
        confirmDestructive(
            title: R.Strings.trashDeleteConfirm.formatted(node.name),
            actionTitle: R.Strings.trashDeleteForever.localizedString()
        ) { [weak self] in
            guard let self else { return }
            Task {
                do { try await self.viewModel.deleteForever(node); self.applySnapshot() }
                catch { self.showError(error) }
            }
        }
    }

    @objc private func confirmEmptyAll() {
        confirmDestructive(
            title: R.Strings.trashEmptyAllConfirm.localizedString(),
            actionTitle: R.Strings.trashEmptyAll.localizedString()
        ) { [weak self] in
            guard let self else { return }
            Task {
                do { try await self.viewModel.emptyAll(); self.applySnapshot() }
                catch { self.showError(error) }
            }
        }
    }

    private func confirmDestructive(
        title: String,
        actionTitle: String,
        completion: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in completion() })
        present(alert, animated: true)
    }

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

extension TrashViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // 回收站里的项目不能预览，只做取消选中。
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}
