import StolnkCore
import UIKit

private nonisolated enum Section: Hashable {
    case link
    case naming
    case folder
    case options
    case danger
}

private nonisolated enum Row: Hashable {
    case address
    case copy
    case share
    case qr
    case senderName
    case path
    case pathNote
    case folder
    case sizeLimit
    case password
    case pause
    case pauseNote
    case reset
    case clear
    case delete
    case dangerNote
}

/**
 一条收件地址的详情与管理。对应 Mac 端 `InboxLinksView` 的右半边。

 只记 `inboxID`，每次渲染都从 `environment.stolnk.inboxes` 里现查那条 `InboxSummary`。
 存下结构体是不行的：改完路径后 `refreshInboxes()` 会整个换掉数组，手里那份立刻过期，
 页面会理直气壮地继续显示一条已经失效的地址。查不到就说明它被删了（可能是在这台设备上，
 也可能是别处），直接退回列表。
 */
@MainActor
final class InboxDetailViewController: UIViewController {
    private let environment: AppEnvironment
    private let inboxID: String

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private let pauseSwitch = UISwitch()

    /// 当前这条地址。删掉之后为 nil。
    private var inbox: InboxSummary? {
        environment.stolnk.inboxes.first { $0.inboxID == inboxID }
    }

    init(environment: AppEnvironment, inbox: InboxSummary) {
        self.environment = environment
        self.inboxID = inbox.inboxID
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
    }

    /// 地址没了就没什么可管理的了。退回列表，那里会显示空状态。
    @objc private func stateDidChange() {
        guard inbox != nil else {
            navigationController?.popViewController(animated: true)
            return
        }
        applySnapshot()
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
        dataSource = UICollectionViewDiffableDataSource<Section, Row>(
            collectionView: collectionView
        ) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: row)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        PaperListCellStyle.apply(to: cell)
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

        case .senderName:
            cell.contentConfiguration = value(
                R.Strings.inboxDetailSenderName.localizedString(), inbox.displayName)
            cell.accessories = [PaperListCellStyle.disclosure]

        case .path:
            cell.contentConfiguration = value(
                R.Strings.inboxDetailPath.localizedString(), inbox.slug)
            cell.accessories = [PaperListCellStyle.disclosure]

        case .pathNote:
            cell.contentConfiguration = note(R.Strings.inboxDetailPathHint.localizedString())
            cell.accessories = []

        case .folder:
            // PRD 12.5 —— 落地目录够不到时接收会被暂停，而不是把文件放到别处去，
            // 所以「未绑定」得用警示色说出来，不能和普通副标题一个样。
            let folder = environment.stolnk.folder(for: inboxID)
                .flatMap { environment.drive.id(for: $0) }
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.inboxDetailLandsIn.localizedString()
            content.secondaryText = folder.map { $0.nilIfEmpty ?? R.Strings.tabFiles.localizedString() }
                ?? R.Strings.inboxFolderUnset.localizedString()
            content.secondaryTextProperties.color = folder == nil
                ? AppColor.danger
                : AppColor.textSecondary
            cell.contentConfiguration = content
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

        case .reset:
            cell.contentConfiguration = action(
                R.Strings.inboxReset.localizedString(), icon: "arrow.triangle.2.circlepath")
            cell.accessories = []

        case .clear:
            cell.contentConfiguration = action(
                R.Strings.inboxClear.localizedString(), icon: "clock.arrow.circlepath")
            cell.accessories = []

        case .delete:
            cell.contentConfiguration = action(
                R.Strings.inboxDelete.localizedString(), icon: "trash", destructive: true)
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
        guard dataSource != nil, let inbox else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.link, .naming, .folder, .options, .danger])
        snapshot.appendItems([.address, .copy, .share, .qr], toSection: .link)
        snapshot.appendItems([.senderName, .path, .pathNote], toSection: .naming)
        snapshot.appendItems([.folder], toSection: .folder)
        snapshot.appendItems(
            inbox.hasPassword
                ? [.sizeLimit, .password, .pause, .pauseNote]
                : [.sizeLimit, .pause, .pauseNote],
            toSection: .options)
        snapshot.appendItems([.reset, .clear, .delete, .dangerNote], toSection: .danger)

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

    private func changePath() {
        guard let inbox else { return }
        let alert = UIAlertController(
            title: R.Strings.inboxPathTitle.localizedString(),
            message: R.Strings.inboxPathMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            InboxPathField.configure(
                field,
                prefix: self?.environment.stolnk.addressPrefix,
                text: inbox.slug
            )
        }
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: R.Strings.inboxPathSave.localizedString(), style: .default
        ) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            guard PathRules.problem(with: raw) == nil else {
                self.showMessage(
                    title: R.Strings.inboxPathTitle.localizedString(),
                    message: R.Strings.driveImportPathInvalid.localizedString())
                return
            }
            Task {
                do { try await self.environment.stolnk.setSlug(inbox, slug: raw) }
                catch { self.showError(error) }
            }
        })
        present(alert, animated: true)
    }

    /// 换落地目录。纯本地操作——绑定是这台手机自己的账本，服务端不知道也不需要知道。
    private func changeFolder() {
        let picker = FolderPickerNavigationController.make(
            environment: environment,
            rootId: LocalDriveStore.rootID,
            excludedNodeId: nil,
            confirmTitle: R.Strings.inboxFolderPick.localizedString()
        ) { [weak self] targetId in
            guard let self else { return }
            dismiss(animated: true)
            environment.stolnk.bind(
                inboxID: inboxID, to: environment.drive.url(for: targetId))
            applySnapshot()
            PaperToast.show(R.Strings.inboxFolderChanged.localizedString(), in: view)
            HapticManager.notification(.success)
        }
        present(picker, animated: true)
    }

    private func confirmReset() {
        guard let inbox else { return }
        confirm(
            title: R.Strings.inboxResetTitle.localizedString(),
            message: R.Strings.inboxResetMessage.localizedString(),
            confirmTitle: R.Strings.inboxResetConfirm.localizedString()
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.environment.stolnk.resetInbox(inbox)
                    PaperToast.show(R.Strings.inboxResetDone.localizedString(), in: self.view)
                    HapticManager.notification(.success)
                } catch { self.showError(error) }
            }
        }
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

    private func confirmDelete() {
        guard let inbox else { return }
        confirm(
            title: R.Strings.inboxDeleteTitle.formatted(inbox.displayName),
            message: R.Strings.inboxDeleteMessage.localizedString(),
            confirmTitle: R.Strings.inboxDeleteConfirm.localizedString()
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.environment.stolnk.deleteInbox(inbox)
                    HapticManager.notification(.success)
                    // 退回列表由 `stateDidChange` 负责：refreshInboxes 之后这条地址
                    // 就查不到了，那里统一处理，不用在这里再 pop 一次。
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
            if apiError.isQuota || apiError.isUpgradeRequired {
                showMessage(
                    title: R.Strings.quotaExceededTitle.localizedString(),
                    message: R.Strings.quotaExceededMessage.localizedString())
                return
            }
            // 换路径撞车是这个页面最容易碰到的 400，单独讲清楚。
            if apiError.status == 400 {
                showMessage(
                    title: R.Strings.commonError.localizedString(),
                    message: R.Strings.driveImportPathRefused.localizedString())
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
        case .path: changePath()
        case .folder: changeFolder()
        case .reset: confirmReset()
        case .clear: confirmClear()
        case .delete: confirmDelete()
        case .address, .pathNote, .sizeLimit, .password, .pause, .pauseNote, .dangerNote:
            break
        }
    }

    /// 说明性的行和开关行不该有点击高亮——它们点了不会发生任何事。
    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .address, .pathNote, .sizeLimit, .password, .pause, .pauseNote, .dangerNote:
            return false
        default:
            return true
        }
    }
}
