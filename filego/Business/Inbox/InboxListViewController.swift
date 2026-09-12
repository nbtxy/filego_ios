import StolnkCore
import UIKit

private nonisolated enum Section: Hashable {
    case inboxes
    case note
}

private nonisolated enum Row: Hashable {
    case inbox(InboxSummary)
    case note
    case empty
}

/**
 这台设备的收件地址。

 对应 Mac 端 `InboxLinksView` 的一级列表。每个 inbox 显示地址、落地目录和暂停状态；
 点一下复制链接。新建 / 改路径 / Reset / 删除这些改动性操作还没接上——它们要配一套
 确认流程，属于 inbox 管理那一步。

 列表底部固定一条说明：手机是独立身份。没有多接收者信封（服务端的
 `files.wrapped_key` 只包给一把 `pubkey_kex`），所以发往 Mac 地址的文件到不了这里。
 这是最容易产生错误预期的地方，宁可一直挂着。
 */
@MainActor
final class InboxListViewController: UIViewController {
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
        title = R.Strings.inboxListTitle.localizedString()
        view.backgroundColor = AppColor.background
        configureCollectionView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applySnapshot),
            name: .stolnkStateDidChange, object: nil)
        applySnapshot()
        Task { await environment.stolnk.refreshInboxes() }
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
        case .inbox(let inbox):
            var content = UIListContentConfiguration.subtitleCell()
            content.applyPaperColors()
            content.text = inbox.url
            let folder = environment.stolnk.folder(for: inbox.inboxID)
                .flatMap { environment.drive.id(for: $0) }
            let where_ = folder?.nilIfEmpty
                ?? R.Strings.tabFiles.localizedString()
            let bound = folder == nil
                ? R.Strings.inboxFolderUnset.localizedString()
                : R.Strings.inboxFolder.formatted(where_)
            content.secondaryText = inbox.paused
                ? "\(R.Strings.inboxPaused.localizedString()) · \(bound)"
                : bound
            content.secondaryTextProperties.color = AppColor.textSecondary
            cell.contentConfiguration = content
            cell.accessories = []

        case .note:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.inboxSeparateIdentity.localizedString()
            content.textProperties.color = AppColor.textSecondary
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.contentConfiguration = content
            cell.accessories = []

        case .empty:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.inboxEmpty.localizedString()
            content.textProperties.color = AppColor.textSecondary
            cell.contentConfiguration = content
            cell.accessories = []
        }
    }

    @objc private func applySnapshot() {
        guard dataSource != nil else { return }
        let inboxes = environment.stolnk.inboxes
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.inboxes])
        snapshot.appendItems(
            inboxes.isEmpty ? [.empty] : inboxes.map { Row.inbox($0) }, toSection: .inboxes)
        snapshot.appendSections([.note])
        snapshot.appendItems([.note], toSection: .note)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension InboxListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .inbox(let inbox)? = dataSource.itemIdentifier(for: indexPath) else { return }
        // 暂停中的 inbox，第一件该做的事是恢复它，而不是复制一条收不到东西的链接。
        if inbox.paused {
            offerResume(inbox)
            return
        }
        UIPasteboard.general.string = inbox.url
        PaperToast.show(R.Strings.inboxCopied.localizedString(), in: view)
        HapticManager.notification(.success)
    }

    private func offerResume(_ inbox: InboxSummary) {
        let alert = UIAlertController(
            title: R.Strings.inboxPaused.localizedString(),
            message: R.Strings.inboxPausedMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: R.Strings.inboxResume.localizedString(), style: .default
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                if await self.environment.stolnk.resume(inbox) {
                    PaperToast.show(R.Strings.inboxResumed.localizedString(), in: self.view)
                    HapticManager.notification(.success)
                }
            }
        })
        present(alert, animated: true)
    }
}
