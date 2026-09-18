import StolnkCore
import UIKit

private nonisolated enum Section: Hashable {
    case name
    case inboxes
    case note
}

private nonisolated enum Row: Hashable {
    /// 带上显示出来的地址，否则改完名字这一行不会重绘：diffable 只认 item 本身的
    /// 相等性，一个没有关联值的 `.name` 在改名前后是同一个 item。
    case name(String)
    case inbox(InboxSummary)
    case note
    case empty
}

/**
 这台设备的收件地址。

 对应 Mac 端 `InboxLinksView` 的一级列表。每个 inbox 显示地址、落地目录和暂停状态，
 点进去是 `InboxDetailViewController`——改路径、换落地目录、暂停、重置、删除都在那里。
 这里只负责挑一条出来。

 顶上单独一段是设备的名字——`ryan.stolnk.com` 里 `ryan` 那一截。它属于设备而不属于
 任何一条地址，下面每一行的开头都是它，所以它在这里统领全页，而不是塞进某一条的详情。
 点进去是 `InboxNameViewController`。

 长按仍然直接给「复制链接」：复制是这个页面上最高频的动作，改成详情页之后多一跳，
 留个快捷方式把老的肌肉记忆接住。

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
        case .name(let address):
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.inboxListName.localizedString()
            // 名字连着后缀一起显示：单看 `ryan` 看不出它是个域名。
            content.secondaryText = address
            content.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: 14, weight: .regular)
            cell.contentConfiguration = content
            cell.accessories = [PaperListCellStyle.disclosure]

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
            cell.accessories = [PaperListCellStyle.disclosure]

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
        // 还没注册就没有名字可改，整段不出现。
        if let name = environment.stolnk.name {
            snapshot.appendSections([.name])
            snapshot.appendItems(
                [.name(name + environment.stolnk.nameSuffix)], toSection: .name)
        }
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
        if case .name(_)? = dataSource.itemIdentifier(for: indexPath) {
            navigationController?.pushViewController(
                InboxNameViewController(environment: environment), animated: true)
            return
        }
        guard case .inbox(let inbox)? = dataSource.itemIdentifier(for: indexPath) else { return }
        // 暂停中的地址不再在这里拦一道弹窗：详情页里就有开关，拦截只是多一步。
        navigationController?.pushViewController(
            InboxDetailViewController(environment: environment, inbox: inbox), animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .inbox(let inbox)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: R.Strings.inboxCopy.localizedString(),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    guard let self else { return }
                    UIPasteboard.general.string = inbox.url
                    PaperToast.show(R.Strings.inboxCopied.localizedString(), in: self.view)
                    HapticManager.notification(.success)
                }
            ])
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .name(_), .inbox(_): return true
        default: return false
        }
    }
}
