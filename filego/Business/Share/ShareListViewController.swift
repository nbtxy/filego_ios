import StolnkCore
import UIKit

private nonisolated enum Section: Hashable {
    case shares
    case note
}

private nonisolated enum Row: Hashable {
    /// 带上整条 summary，否则改完路径、暂停或撤回之后这一行不会重绘：diffable 只认
    /// item 本身的相等性，一个只带 id 的行在前后是同一个 item。和 `InboxListViewController`
    /// 里 `.name(String)` 同一个理由。
    case share(ShareSummary)
    case note
    case empty
}

/**
 这台设备发出去的下载链接。对应 Mac 端 `SharesView` 的一级列表。

 是 `InboxListViewController` 的出向孪生：那边是别人发给你，这边是你发给别人。
 创建入口不在这里——一条链接背后总得有个文件，所以建链接在「文件」里（长按菜单
 和预览页），这一页只管已经存在的那些。和 `StolnkController.createInbox` 注释里
 「没有文件夹的时候根本无话可说」是同一个论证。

 底部固定一条说明：这些链接不是端到端加密的。`docs/wire-format.md` 要求创建页
 披露这件事，而一个月后回来看列表的人未必记得当初那一屏，所以这里也挂着。
 */
@MainActor
final class ShareListViewController: UIViewController {
    private let environment: AppEnvironment
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.shareListTitle.localizedString()
        view.backgroundColor = AppColor.background
        configureCollectionView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applySnapshot),
            name: .stolnkStateDidChange, object: nil)
        applySnapshot()
        Task { await environment.stolnk.refreshShares() }
    }

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
        dataSource = UICollectionViewDiffableDataSource<Section, Row>(
            collectionView: collectionView
        ) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: row)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        PaperListCellStyle.apply(to: cell)
        switch row {
        case .share(let share):
            var content = UIListContentConfiguration.subtitleCell()
            content.applyPaperColors()
            content.text = share.filename
            content.textProperties.font = AppTypography.rowName
            let uploading = environment.stolnk.shareUpload?.shareID == share.shareID
            let state = ShareFormatting.state(of: share, isUploading: uploading)
            content.secondaryText = "\(state.text) · \(ByteFormatting.storage(Int64(share.size)))"
            content.secondaryTextProperties.font = AppTypography.rowMeta
            // 只有需要用户动手的状态才染成警示色——一条正常生效的链接不该看起来像出了事。
            content.secondaryTextProperties.color = state.isWarning
                ? AppColor.danger
                : AppColor.textSecondary
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]

        case .note:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.shareListNote.localizedString()
            content.textProperties.color = AppColor.textSecondary
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.contentConfiguration = content
            cell.accessories = []

        case .empty:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.shareListEmpty.localizedString()
            content.textProperties.color = AppColor.textSecondary
            cell.contentConfiguration = content
            cell.accessories = []
        }
    }

    @objc private func applySnapshot() {
        guard dataSource != nil else { return }
        let shares = environment.stolnk.shares
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.shares, .note])
        snapshot.appendItems(
            shares.isEmpty ? [.empty] : shares.map(Row.share), toSection: .shares)
        snapshot.appendItems([.note], toSection: .note)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension ShareListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .share(let share) = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(
            ShareDetailViewController(environment: environment, share: share), animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        if case .share = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    /// 长按直接给「复制链接」。和收件地址那边一样的理由：复制是这个页面上最高频的
    /// 动作，不该每次都要先进详情。
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .share(let share) = dataSource.itemIdentifier(for: indexPath),
              share.isLive else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(
                title: R.Strings.shareCopy.localizedString(),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = share.url
                PaperToast.show(R.Strings.shareCopied.localizedString(), in: self.view)
                HapticManager.notification(.success)
            }])
        }
    }
}
