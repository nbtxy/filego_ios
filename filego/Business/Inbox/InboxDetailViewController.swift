import StolnkCore
import UIKit

private nonisolated enum Section: Hashable {
    case link
    case naming
    case options
    case danger
}

private nonisolated enum Row: Hashable {
    case address
    case copy
    case share
    case qr
    /// 子域名（`ryan`），带上状态文案，改名或到期天数变了才会重绘。
    case name(String)
    case nameNote(String)
    /// 地址已失效时唯一的动作：重新设置子域名。
    case setName
    case senderName
    case sizeLimit
    case password
    case pause
    case pauseNote
    case clear
    case dangerNote
}

/**
 收件设置：这台设备唯一的收件地址 `<name>.stolnk.com`。

 单一收件地址之后没有路径、没有「哪个文件夹」、也没有重置和删除——地址就是名字，
 它永远落在接收文件夹里。这里管的是：复制/分享/二维码、子域名（改名与到期状态）、
 发件人看到的名字、暂停，以及清掉传输记录。入口是接收文件夹导航栏上的地址按钮和
 「我的 → 收件地址」。

 每次渲染都从 `environment.stolnk.inbox` 现查，不存结构体：改名或暂停之后
 `refreshInboxes()` 会整个换掉它。
 */
@MainActor
final class InboxDetailViewController: UIViewController {
    private let environment: AppEnvironment

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private let pauseSwitch = UISwitch()

    /// 这台设备唯一的地址。还没拉到（刚注册、离线）时为 nil。
    private var inbox: InboxSummary? { environment.stolnk.inbox }

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.inboxDetailTitle.localizedString()
        view.backgroundColor = AppColor.background
        pauseSwitch.onTintColor = AppColor.ink
        pauseSwitch.addTarget(self, action: #selector(pauseToggled), for: .valueChanged)
        configureCollectionView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .stolnkStateDidChange, object: nil)
        applySnapshot()
        Task {
            await environment.stolnk.refreshInboxes()
            await environment.stolnk.refreshPlan()
        }
    }

    @objc private func stateDidChange() { applySnapshot() }

    // MARK: - 视图

    private func configureCollectionView() {
        let configuration = UICollectionLayoutListConfiguration.paperInsetGrouped()
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: PaperInsetGroupedLayout.make(configuration)
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
        // 子域名状态与「设置子域名」在没有地址时也要显示，所以先处理这三行。
        switch row {
        case .name(let status):
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.nameStatusRow.localizedString()
            content.secondaryText = status
            cell.contentConfiguration = content
            cell.accessories = [PaperListCellStyle.disclosure]
            return
        case .nameNote(let text):
            cell.contentConfiguration = note(text)
            cell.accessories = []
            return
        case .setName:
            cell.contentConfiguration = action(
                R.Strings.nameSetNew.localizedString(), icon: "at")
            cell.accessories = []
            return
        default:
            break
        }
        guard let inbox else { return }

        switch row {
        case .address:
            var content = UIListContentConfiguration.subtitleCell()
            content.applyPaperColors()
            content.text = inbox.displayName
            content.textProperties.font = AppTypography.sectionTitle
            content.secondaryText = inbox.url
            content.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            cell.contentConfiguration = content
            cell.accessories = []

        case .copy:
            cell.contentConfiguration = action(
                R.Strings.inboxCopy.localizedString(), icon: "doc.on.doc")
            cell.accessories = []

        case .share:
            cell.contentConfiguration = action(
                R.Strings.inboxShare.localizedString(), icon: "square.and.arrow.up")
            cell.accessories = []

        case .qr:
            cell.contentConfiguration = action(
                R.Strings.inboxQr.localizedString(), icon: "qrcode")
            cell.accessories = []

        // 这三行在上面已经处理过；这里只为让第二个 switch 保持穷尽。
        case .name, .nameNote, .setName:
            break

        case .senderName:
            cell.contentConfiguration = value(
                R.Strings.inboxDetailSenderName.localizedString(), inbox.displayName)
            cell.accessories = [PaperListCellStyle.disclosure]

        case .sizeLimit:
            // 服务端按 GiB 定的（`limits.ts` 里 `2 * 1024 ** 3`），和中转额度同一类，
            // 所以走 `quota` 而不是 `storage`——十进制会把它显示成「2.15 GB」。
            cell.contentConfiguration = value(
                R.Strings.inboxDetailSizeLimit.localizedString(),
                ByteFormatting.quota(Int64(inbox.sizeLimit)))
            cell.accessories = []

        case .password:
            cell.contentConfiguration = value(
                R.Strings.inboxDetailPassword.localizedString(), "")
            cell.accessories = [.checkmark()]

        case .pause:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.inboxDetailPause.localizedString()
            cell.contentConfiguration = content
            pauseSwitch.isOn = inbox.paused
            cell.accessories = [.customView(
                configuration: .init(customView: pauseSwitch, placement: .trailing()))]

        case .pauseNote:
            cell.contentConfiguration = note(R.Strings.inboxDetailPauseHint.localizedString())
            cell.accessories = []

        case .clear:
            cell.contentConfiguration = action(
                R.Strings.inboxClear.localizedString(), icon: "clock.arrow.circlepath")
            cell.accessories = []

        case .dangerNote:
            cell.contentConfiguration = note(R.Strings.inboxDetailDangerHint.localizedString())
            cell.accessories = []
        }
    }

    // MARK: - Cell 配置的三种形状

    private func action(
        _ title: String, icon: String, destructive: Bool = false
    ) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.applyPaperColors()
        content.text = title
        content.image = UIImage(systemName: icon)
        let tint = destructive ? AppColor.danger : AppColor.textPrimary
        content.textProperties.color = tint
        content.imageProperties.tintColor = tint
        return content
    }

    private func value(_ title: String, _ detail: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.valueCell()
        content.applyPaperColors()
        content.text = title
        content.secondaryText = detail
        return content
    }

    private func note(_ text: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.applyPaperColors()
        content.text = text
        content.textProperties.color = AppColor.textSecondary
        content.textProperties.font = .preferredFont(forTextStyle: .footnote)
        return content
    }

    // MARK: - 数据

    private func applySnapshot() {
        guard dataSource != nil else { return }
        let status = NameStatusText.make(environment: environment)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        if let inbox {
            snapshot.appendSections([.link, .naming, .options, .danger])
            snapshot.appendItems([.address, .copy, .share, .qr], toSection: .link)
            snapshot.appendItems(
                [.name(status.short), .nameNote(status.detail), .senderName], toSection: .naming)
            snapshot.appendItems(
                inbox.hasPassword
                    ? [.sizeLimit, .password, .pause, .pauseNote]
                    : [.sizeLimit, .pause, .pauseNote],
                toSection: .options)
            snapshot.appendItems([.clear, .dangerNote], toSection: .danger)
        } else {
            // 没有可用地址：只说明状态并给出「设置子域名」。
            snapshot.appendSections([.naming])
            snapshot.appendItems(
                [.name(status.short), .nameNote(status.detail), .setName], toSection: .naming)
        }

        // 和 `MeViewController` 同样的理由：行标识不带内容，光 apply 一次相同的 snapshot
        // diffable 会认定无事发生，cell 停在旧值上。只 reconfigure 本来就在的行——
        // 对正在首次插入的 item 调它会踩 UIKit 断言。
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter(existing.contains)
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - 操作

extension InboxDetailViewController {
    @objc private func pauseToggled() {
        guard let inbox else { return }
        let paused = pauseSwitch.isOn
        Task {
            if await environment.stolnk.setPaused(inbox, paused: paused) == false {
                // 服务端没认这次改动，开关得跟着退回去，否则它在撒谎。
                pauseSwitch.setOn(inbox.paused, animated: true)
                showError(nil)
            }
        }
    }

    private func copyAddress() {
        guard let inbox else { return }
        UIPasteboard.general.string = inbox.url
        PaperToast.show(R.Strings.inboxCopied.localizedString(), in: view)
        HapticManager.notification(.success)
    }

    private func shareAddress(from cell: UICollectionViewCell?) {
        guard let inbox, let url = URL(string: inbox.url) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = cell ?? view
            popover.sourceRect = (cell ?? view).bounds
        }
        present(controller, animated: true)
    }

    private func showQRCode() {
        guard let inbox else { return }
        guard let image = QRCode.image(for: inbox.url) else {
            showMessage(
                title: R.Strings.commonError.localizedString(),
                message: R.Strings.inboxQrFailed.localizedString())
            return
        }
        present(
            InboxQRViewController(image: image, address: inbox.url),
            animated: true)
    }

    private func renameSenderName() {
        guard let inbox else { return }
        let alert = UIAlertController(
            title: R.Strings.inboxRenameTitle.localizedString(),
            message: R.Strings.inboxDetailSenderNameHint.formatted(inbox.displayName),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = inbox.displayName
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: R.Strings.commonSave.localizedString(), style: .default
        ) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            // 只拿 `problem` 当闸门，不渲染它返回的英文——和建地址那边一样的做法。
            guard DisplayNameRules.problem(with: raw) == nil else {
                self.showMessage(
                    title: R.Strings.inboxRenameTitle.localizedString(),
                    message: R.Strings.inboxRenameInvalid.localizedString())
                return
            }
            Task {
                do { try await self.environment.stolnk.setDisplayName(inbox, to: raw) }
                catch { self.showError(error) }
            }
        })
        present(alert, animated: true)
    }

    private func confirmClear() {
        guard let inbox else { return }
        confirm(
            title: R.Strings.inboxClearTitle.formatted(inbox.displayName),
            message: R.Strings.inboxClearMessage.localizedString(),
            confirmTitle: R.Strings.inboxClearConfirm.localizedString()
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let cleared = try await self.environment.stolnk.clearTransfers(inbox)
                    // 条数是这个操作唯一看得见的结果——iOS 上没有历史页能让变化自己显形。
                    PaperToast.show(
                        R.Strings.inboxClearDone.formatted(cleared), in: self.view)
                    HapticManager.notification(.success)
                } catch { self.showError(error) }
            }
        }
    }

    // MARK: - 弹窗

    private func confirm(
        title: String, message: String, confirmTitle: String, action: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: confirmTitle, style: .destructive
        ) { _ in action() })
        present(alert, animated: true)
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }

    /**
     报错。

     服务端的 message 是写给 Mac 的（「This Mac…」），一律按 code 映射自己的文案，
     只有认不出的 code 才退回渲染它——和 `DriveListViewController.showError` 同一条规矩。
     */
    private func showError(_ error: Error?) {
        if let apiError = error as? APIError {
            // 设密码是会员功能，402 应该把人带到会员页。
            if apiError.isUpgradeRequired {
                return PlanViewController.handleUpgradeRequired(
                    on: self, environment: environment)
            }
            if apiError.isQuota {
                showMessage(
                    title: R.Strings.quotaExceededTitle.localizedString(),
                    message: R.Strings.quotaExceededMessage.localizedString())
                return
            }
        }
        showMessage(
            title: R.Strings.commonError.localizedString(),
            message: error?.localizedDescription
                ?? environment.stolnk.lastError
                ?? R.Strings.commonRetry.localizedString())
    }
}

extension InboxDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .copy: copyAddress()
        case .share: shareAddress(from: collectionView.cellForItem(at: indexPath))
        case .qr: showQRCode()
        case .senderName: renameSenderName()
        case .name, .setName: navigationController?.pushViewController(
            InboxNameViewController(environment: environment), animated: true)
        case .clear: confirmClear()
        case .address, .nameNote, .sizeLimit, .password, .pause, .pauseNote, .dangerNote:
            break
        }
    }

    /// 说明性的行和开关行不该有点击高亮——它们点了不会发生任何事。
    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .address, .nameNote, .sizeLimit, .password, .pause, .pauseNote, .dangerNote:
            return false
        default:
            return true
        }
    }
}
