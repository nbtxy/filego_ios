import StolnkCore
import UIKit

private nonisolated enum Section: Hashable {
    case link
    case status
    case path
    case options
    case danger
}

private nonisolated enum Row: Hashable {
    case address
    case copy
    case share
    case qr
    case state
    case expires
    case downloads
    case password
    case path
    case pathNote
    case pause
    case pauseNote
    case incompleteNote
    case restore
    case revoke
    case delete
}

/**
 一条下载链接的详情与管理。对应 Mac 端 `SharesView` 里的 `ShareDetail`。

 只记 `shareID`，每次渲染都从 `environment.stolnk.shares` 里现查——和
 `InboxDetailViewController` 完全相同的理由：改完路径或暂停之后 `refreshShares()`
 会整个换掉数组，手里存着的那份结构体立刻过期，页面会理直气壮地继续显示一条
 已经失效的链接。查不到就说明它被删了，直接退回列表。
 */
@MainActor
final class ShareDetailViewController: UIViewController {
    private let environment: AppEnvironment
    private let shareID: String

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private let pauseSwitch = UISwitch()

    private var share: ShareSummary? {
        environment.stolnk.shares.first { $0.shareID == shareID }
    }

    /// 这一条是不是正在上传。服务端说 `uploading`、而本地没有对应的上传在跑，
    /// 就是上次被切后台杀掉的残骸。
    private var isUploading: Bool {
        environment.stolnk.shareUpload?.shareID == shareID
    }

    private var isIncomplete: Bool {
        share?.state == "uploading" && !isUploading
    }

    init(environment: AppEnvironment, share: ShareSummary) {
        self.environment = environment
        self.shareID = share.shareID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.shareDetailTitle.localizedString()
        view.backgroundColor = AppColor.background
        pauseSwitch.onTintColor = AppColor.ink
        pauseSwitch.addTarget(self, action: #selector(pauseToggled), for: .valueChanged)
        configureCollectionView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .stolnkStateDidChange, object: nil)
        applySnapshot()
    }

    @objc private func stateDidChange() {
        guard share != nil else {
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
        guard let share else { return }

        switch row {
        case .address:
            var content = UIListContentConfiguration.subtitleCell()
            content.applyPaperColors()
            content.text = share.filename
            content.textProperties.font = AppTypography.sectionTitle
            content.secondaryText = share.url
            content.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            cell.contentConfiguration = content
            cell.accessories = []

        case .copy:
            cell.contentConfiguration = action(
                R.Strings.shareCopy.localizedString(), icon: "doc.on.doc")
            cell.accessories = []

        case .share:
            cell.contentConfiguration = action(
                R.Strings.inboxShare.localizedString(), icon: "square.and.arrow.up")
            cell.accessories = []

        case .qr:
            cell.contentConfiguration = action(
                R.Strings.shareQr.localizedString(), icon: "qrcode")
            cell.accessories = []

        case .state:
            let state = ShareFormatting.state(of: share, isUploading: isUploading)
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.shareDetailState.localizedString()
            content.secondaryText = state.text
            content.secondaryTextProperties.color = state.isWarning
                ? AppColor.danger
                : AppColor.textSecondary
            cell.contentConfiguration = content
            cell.accessories = []

        case .expires:
            cell.contentConfiguration = value(
                R.Strings.shareDetailExpires.localizedString(), ShareFormatting.expiry(share))
            cell.accessories = []

        case .downloads:
            cell.contentConfiguration = value(
                R.Strings.shareDetailDownloads.localizedString(),
                ShareFormatting.downloads(share))
            cell.accessories = []

        case .password:
            cell.contentConfiguration = value(
                R.Strings.shareDetailPassword.localizedString(), "")
            cell.accessories = [.checkmark()]

        case .path:
            cell.contentConfiguration = value(
                R.Strings.shareDetailPath.localizedString(), share.code)
            cell.accessories = [PaperListCellStyle.disclosure]

        case .pathNote:
            cell.contentConfiguration = note(R.Strings.shareDetailPathHint.localizedString())
            cell.accessories = []

        case .pause:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.shareDetailPause.localizedString()
            cell.contentConfiguration = content
            pauseSwitch.isOn = share.paused
            cell.accessories = [.customView(
                configuration: .init(customView: pauseSwitch, placement: .trailing()))]

        case .pauseNote:
            cell.contentConfiguration = note(R.Strings.shareDetailPauseHint.localizedString())
            cell.accessories = []

        case .incompleteNote:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.shareIncompleteHint.localizedString()
            content.textProperties.color = AppColor.danger
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.contentConfiguration = content
            cell.accessories = []

        case .restore:
            cell.contentConfiguration = action(
                R.Strings.commonRetry.localizedString(), icon: "arrow.triangle.2.circlepath")
            cell.accessories = []

        case .revoke:
            cell.contentConfiguration = action(
                R.Strings.shareRevoke.localizedString(), icon: "xmark.circle", destructive: true)
            cell.accessories = []

        case .delete:
            cell.contentConfiguration = action(
                R.Strings.shareDelete.localizedString(), icon: "trash", destructive: true)
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

    /**
     按状态决定这一页有什么。

     一条**没传完**的链接只给删除：它从来没有生效过，复制、二维码、改路径、暂停
     全都无从谈起，而它确实占着一个额度和一个路径——所以要说清楚，并给一条出路。

     一条**已结束**的（撤回/过期/用完）给「重试」，前提是还找得到当初那个源文件。
     */
    private func applySnapshot() {
        guard dataSource != nil, let share else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

        if isIncomplete {
            snapshot.appendSections([.link, .status, .danger])
            snapshot.appendItems([.address], toSection: .link)
            snapshot.appendItems([.state, .incompleteNote], toSection: .status)
            snapshot.appendItems([.delete], toSection: .danger)
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }

        snapshot.appendSections([.link, .status, .path, .options, .danger])

        // 链接不在生效期内就别给复制和二维码——把一条打不开的地址递到用户手上，
        // 比不给还糟。
        snapshot.appendItems(
            share.isLive ? [.address, .copy, .share, .qr] : [.address], toSection: .link)

        var status: [Row] = [.state, .expires, .downloads]
        if share.hasPassword { status.append(.password) }
        snapshot.appendItems(status, toSection: .status)

        // 路径和暂停只在链接还没结束时可改。`isActive` 比 `isLive` 宽一档，刻意的：
        // 暂停只是停住不是结束，把控制项锁掉会让退出暂停的唯一办法变成销毁它。
        if share.isActive {
            snapshot.appendItems([.path, .pathNote], toSection: .path)
            snapshot.appendItems([.pause, .pauseNote], toSection: .options)
        }

        var danger: [Row] = []
        if !share.isActive, environment.stolnk.shareSource(for: share) != nil {
            danger.append(.restore)
        }
        if share.isActive { danger.append(.revoke) }
        danger.append(.delete)
        snapshot.appendItems(danger, toSection: .danger)

        // 行标识不带内容的那几个（.state/.expires/…）光 apply 一次相同 snapshot
        // diffable 会认为无事发生，cell 停在旧值上。只 reconfigure 本来就在的行——
        // 对正在首次插入的 item 调它会踩 UIKit 断言。
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter(existing.contains)
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - 操作

extension ShareDetailViewController {
    private func copyLink() {
        guard let share else { return }
        UIPasteboard.general.string = share.url
        PaperToast.show(R.Strings.shareCopied.localizedString(), in: view)
        HapticManager.notification(.success)
    }

    private func shareLink(from cell: UICollectionViewCell?) {
        guard let share, let url = URL(string: share.url) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = cell ?? view
            popover.sourceRect = (cell ?? view).bounds
        }
        present(controller, animated: true)
    }

    private func showQRCode() {
        guard let share else { return }
        guard let image = QRCode.image(for: share.url) else {
            return showMessage(
                title: R.Strings.commonError.localizedString(),
                message: R.Strings.inboxQrFailed.localizedString())
        }
        present(InboxQRViewController(image: image, address: share.url), animated: true)
    }

    @objc private func pauseToggled() {
        guard let share else { return }
        let paused = pauseSwitch.isOn
        Task {
            if await environment.stolnk.setSharePaused(share, paused: paused) == false {
                // 服务端没认这次改动，开关得跟着退回去，否则它在撒谎。
                pauseSwitch.setOn(share.paused, animated: true)
                showError(nil)
            }
        }
    }

    private func changePath() {
        guard let share else { return }
        let alert = UIAlertController(
            title: R.Strings.shareFormPath.localizedString(),
            message: R.Strings.shareDetailPathHint.localizedString(),
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            InboxPathField.configure(
                field,
                prefix: self?.environment.stolnk.addressPrefix.map { $0 + "~" },
                text: share.code,
                placeholder: R.Strings.sharePathPlaceholder.localizedString())
        }
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: R.Strings.commonSave.localizedString(), style: .default
        ) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            // 只拿 `problem` 当闸门，不渲染它返回的英文——全 App 一致的做法。
            // 这里也不接受留空：改路径和建链接不同，空字符串不是「随机生成一个」，
            // 而是「什么都没填」。
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty,
                  ShareCodeRules.problem(with: ShareCodeRules.normalise(raw)) == nil else {
                return self.showMessage(
                    title: R.Strings.shareFormPath.localizedString(),
                    message: R.Strings.sharePathInvalid.localizedString())
            }
            Task {
                do { try await self.environment.stolnk.setShareCode(share, code: raw) }
                catch { self.showError(error) }
            }
        })
        present(alert, animated: true)
    }

    /// 重新把字节传上去，地址不变。源文件找不到就不该走到这里——`applySnapshot`
    /// 已经在那种情况下把这一行摘掉了。
    private func restore() {
        guard let share, let source = environment.stolnk.shareSource(for: share) else { return }
        Task {
            do {
                try await environment.stolnk.restoreShare(share, from: source)
                PaperToast.show(R.Strings.shareCopied.localizedString(), in: view)
            } catch {
                showError(error)
            }
        }
    }

    private func confirmRevoke() {
        guard let share else { return }
        confirm(
            title: R.Strings.shareRevokeTitle.localizedString(),
            message: R.Strings.shareRevokeMessage.localizedString(),
            confirmTitle: R.Strings.shareRevoke.localizedString()
        ) { [weak self] in
            guard let self else { return }
            Task {
                if await self.environment.stolnk.revokeShare(share) == false {
                    self.showError(nil)
                }
            }
        }
    }

    private func confirmDelete() {
        guard let share else { return }
        confirm(
            title: R.Strings.shareDeleteTitle.localizedString(),
            // 还生效的链接和已经结束的，删掉的后果不一样：前者会当场断掉一条别人
            // 手里还能用的地址。两句话分开讲。
            message: share.isActive
                ? R.Strings.shareDeleteMessageLive.localizedString()
                : R.Strings.shareDeleteMessageEnded.localizedString(),
            confirmTitle: R.Strings.shareDelete.localizedString()
        ) { [weak self] in
            guard let self else { return }
            Task {
                if await self.environment.stolnk.deleteShare(share) == false {
                    self.showError(nil)
                }
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
            title: confirmTitle, style: .destructive) { _ in action() })
        present(alert, animated: true)
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }

    /// 和创建页同一套映射：402 推付费页，409 单独讲，413 单独讲。服务端的 message
    /// 是写给 Mac 的，只有认不出的 code 才退回去渲染它。
    private func showError(_ error: Error?) {
        if let apiError = error as? APIError {
            if apiError.isUpgradeRequired {
                return present(
                    UINavigationController(rootViewController: ProUpgradeViewController(
                        environment: environment)),
                    animated: true)
            }
            if apiError.code == "code_taken" {
                return showMessage(
                    title: R.Strings.sharePathTakenTitle.localizedString(),
                    message: R.Strings.sharePathTakenMessage.localizedString())
            }
            if apiError.isQuota {
                return showMessage(
                    title: R.Strings.shareQuotaTitle.localizedString(),
                    message: R.Strings.shareQuotaMessage.localizedString())
            }
        }
        showMessage(
            title: R.Strings.commonError.localizedString(),
            message: error?.localizedDescription
                ?? environment.stolnk.lastError
                ?? R.Strings.commonRetry.localizedString())
    }
}

extension ShareDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .copy: copyLink()
        case .share: shareLink(from: collectionView.cellForItem(at: indexPath))
        case .qr: showQRCode()
        case .path: changePath()
        case .restore: restore()
        case .revoke: confirmRevoke()
        case .delete: confirmDelete()
        case .address, .state, .expires, .downloads, .password,
             .pathNote, .pause, .pauseNote, .incompleteNote:
            break
        }
    }

    /// 说明性的行和开关行不该有点击高亮——它们点了不会发生任何事。
    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .address, .state, .expires, .downloads, .password,
             .pathNote, .pause, .pauseNote, .incompleteNote, .none:
            false
        default:
            true
        }
    }
}
