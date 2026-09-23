import StolnkCore
import UIKit

/**
 回收站。

 内容不在文件树里（`Documents/.Trash/`），所以这里不是 `DriveListViewController` 的一个
 目录参数能覆盖的：没有面包屑、没有下钻、没有新建，文件夹也点不进去——它已经不在树上了。
 复用的是行的样子（`DriveNodeCell`）和那张白卡，不是那套导航。

 副标题换成「还有 N 天自动删除」：在这个页面上，一个文件还剩多久比它有多大重要得多。
 */
@MainActor
final class TrashViewController: UIViewController {
    private let environment: AppEnvironment
    private let noticeLabel = UILabel()
    private let emptyView = PaperEmptyStateView(
        symbol: "trash", title: R.Strings.trashEmpty.localizedString())
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var emptyAllButton: UIBarButtonItem!
    private var items: [TrashItem] = []

    init(environment: AppEnvironment) {
        self.environment = environment
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isMovingToParent == false { reload() }
    }

    // MARK: - 视图

    private func configureNavigation() {
        // 空的时候置灰而不是撤掉：按钮的位置是稳定的，用户第二次进来不用重新找。
        // 不染红——`AppAppearance` 给导航栏按钮标题定死了墨色，`tintColor` 压不过去；
        // 真正危险的那一下在确认框里，那里是红的。
        emptyAllButton = UIBarButtonItem(
            title: R.Strings.trashEmptyAll.localizedString(),
            style: .plain,
            target: self,
            action: #selector(confirmEmptyAll)
        )
        emptyAllButton.isEnabled = false
        navigationItem.rightBarButtonItem = emptyAllButton
    }

    /// 空着也留在屏幕上：这句话讲的是回收站的规则，不是「当前有东西」的状态。
    private func configureNotice() {
        noticeLabel.font = AppTypography.metaSmall
        noticeLabel.textColor = AppColor.textSecondary
        noticeLabel.numberOfLines = 0
        noticeLabel.text = R.Strings.trashNotice.formatted(
            Int64(LocalDriveStore.trashRetentionDays))
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            noticeLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: AppSpacing.small),
            noticeLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: AppSpacing.medium),
            noticeLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -AppSpacing.medium)
        ])
    }

    private func configureCollectionView() {
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: PaperSectionBackgroundView.makeListLayout { [weak self] _ in
                self?.items.count ?? 0
            }
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
                equalTo: noticeLabel.bottomAnchor, constant: AppSpacing.small),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        emptyView.isHidden = true
        collectionView.backgroundView = emptyView

        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self,
                  let item = items.first(where: { $0.storageName == id }),
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "node", for: indexPath
                  ) as? DriveNodeCell else { return nil }
            cell.configure(
                with: item.displayNode,
                menu: actions(for: item),
                grid: false,
                detailOverride: Self.detail(for: item),
                isFirst: id == items.first?.storageName,
                isLast: id == items.last?.storageName
            )
            return cell
        }
    }

    /**
     「还有 N 天自动删除」。

     最后一天说「即将自动删除」，不说「还有 1 天」——那听着像还能拖一拖。
     这里的阈值是 `<= 1`，而不是服务端版本那种 `== 0`：那边过期项会一直躺在
     `GET /trash` 的结果里直到服务端扫到，这边 `reload()` 第一件事就是
     `purgeExpiredTrash()`，0 天的项目根本活不到渲染，`== 0` 等于让这句文案永不出现。
     */
    private static func detail(for item: TrashItem) -> String {
        let days = LocalDriveStore.trashDaysLeft(since: item.trashedAt)
        return days <= 1
            ? R.Strings.trashExpiringSoon.localizedString()
            : R.Strings.trashDaysLeft.formatted(days)
    }

    // MARK: - 数据

    /// 每次进来先清一遍过期的，用户看到的列表和 `trash.notice` 的承诺才对得上。
    private func reload() {
        environment.drive.purgeExpiredTrash()
        items = environment.drive.trashItems()
        applySnapshot()
        collectionView.refreshControl?.endRefreshing()
    }

    @objc private func refresh() { reload() }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections(["main"])
        let ids = items.map(\.storageName)
        snapshot.appendItems(ids)
        let previousIDs = dataSource.snapshot().itemIdentifiers
        // 剩余天数天天在变，而 id 是存储文件名、跨天不变，diff 比出来是空的。
        // 见 DriveListViewController.applySnapshot。
        let existing = Set(previousIDs)
        snapshot.reconfigureItems(ids.filter(existing.contains))
        dataSource.apply(snapshot, animatingDifferences: previousIDs != ids)
        if previousIDs.isEmpty != ids.isEmpty {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        emptyView.isHidden = !items.isEmpty
        emptyAllButton.isEnabled = !items.isEmpty
    }

    // MARK: - 操作

    private func actions(for item: TrashItem) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: R.Strings.trashRestore.localizedString(),
                image: UIImage(systemName: "arrow.uturn.backward")
            ) { [weak self] _ in self?.restore(item) },
            // `trash` 已经是文件列表那边「移到回收站」的图标，同一个符号不该既表示
            // 扔进来又表示彻底删掉。
            UIAction(
                title: R.Strings.trashDeleteForever.localizedString(),
                image: UIImage(systemName: "trash.slash"),
                attributes: .destructive
            ) { [weak self] _ in self?.confirmDeleteForever(item) }
        ])
    }

    private func restore(_ item: TrashItem) {
        do {
            try environment.drive.restoreFromTrash(item)
            // 文件列表在导航栈里排在这个页面后面，退回去不会自己重读。它已经在听这条
            // 通知了（收件落地也走这条），还原同样是「树里多了东西」，借过来用。
            NotificationCenter.default.post(name: .stolnkDidLandFiles, object: nil)
            reload()
        } catch {
            showError(error)
        }
    }

    private func confirmDeleteForever(_ item: TrashItem) {
        confirmDestructive(
            title: R.Strings.trashDeleteConfirm.formatted(item.name),
            actionTitle: R.Strings.trashDeleteForever.localizedString()
        ) { [weak self] in
            guard let self else { return }
            do {
                try environment.drive.deleteFromTrash(item)
                reload()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func confirmEmptyAll() {
        confirmDestructive(
            title: R.Strings.trashEmptyAllConfirm.localizedString(),
            actionTitle: R.Strings.trashEmptyAll.localizedString()
        ) { [weak self] in
            guard let self else { return }
            do {
                try environment.drive.emptyTrash()
                reload()
            } catch {
                showError(error)
            }
        }
    }

    /// 移入回收站不问，从回收站真删要问——这一步之后就没有下一次机会了。
    private func confirmDestructive(
        title: String,
        actionTitle: String,
        completion: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(), style: .cancel))
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
    /// 回收站里的东西点不开：文件夹已经不在树上，文件预览也没有意义——
    /// 要看内容先还原。操作都在行尾那个 ⋯ 里。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}
