import SafariServices
import StoreKit
import UIKit

/// diffable 的条目标识必须是 Sendable，见 MeViewController 里的同类说明。
private nonisolated enum Row: Hashable {
    case hero
    case benefitStorage
    case subscribe
    case manage
    case restore
    case legal
    case unavailable
}

/// 付费墙。
///
/// App Store Review 3.1.2(a) 的硬要求都在这里，删任何一条都会被拒：
///   - 价格必须来自 `Product.displayPrice`（各地区货币由 App Store 换算，不能硬编码）
///   - 必须有「恢复购买」
///   - 必须有可点击的使用条款(EULA) 与隐私政策链接
@MainActor
final class ProUpgradeViewController: UIViewController {
    private let environment: AppEnvironment

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var store: StoreKitService { environment.storeKitService }

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.proTitle.localizedString()
        view.backgroundColor = AppColor.background
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        configureActivityIndicator()
        applySnapshot()
        reload()
    }

    // MARK: - 视图

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration.paperInsetGrouped()
        configuration.headerMode = .supplementary
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

        let heroRegistration = UICollectionView.CellRegistration<ProHeroCell, Row> {
            [weak self] cell, _, _ in
            guard let self else { return }
            // 付费墙的主视觉。网页把「行动号召」这类块统一刷成柠檬绿（`.closing-card`），
            // 这是全站唯一一处整块上点缀色的地方，正好对应这里。
            var background = cell.defaultBackgroundConfiguration()
            background.backgroundColor = AppColor.lime
            background.cornerRadius = AppRadius.card
            background.strokeColor = AppColor.lime
            background.strokeWidth = 1
            cell.backgroundConfiguration = background
            cell.apply(status: self.store.status)
        }
        let legalRegistration = UICollectionView.CellRegistration<ProLegalCell, Row> {
            [weak self] cell, _, _ in
            guard let self else { return }
            PaperListCellStyle.apply(to: cell)
            cell.configure(
                userAgreement: environment.appConfigStore.userAgreementURL,
                privacy: environment.appConfigStore.privacyPolicyURL,
                termsOfUse: environment.appConfigStore.termsOfUseURL
            )
            cell.onOpen = { [weak self] url in self?.openLegal(url) }
        }
        let valueRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> {
            [weak self] cell, _, row in
            self?.configure(cell, for: row)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { header, _, indexPath in
            var content: UIListContentConfiguration
            if #available(iOS 18.0, *) {
                content = .header()
            } else {
                content = .groupedHeader()
            }
            content.text = indexPath.section == 1
                ? R.Strings.proBenefitsTitle.localizedString()
                : nil
            content.textProperties.color = AppColor.textSecondary
            header.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) {
            collectionView, indexPath, row in
            // 三种 registration 的 cell 类型不同，不能塞进同一个三目里。
            switch row {
            case .hero:
                return collectionView.dequeueConfiguredReusableCell(
                    using: heroRegistration, for: indexPath, item: row
                )
            case .legal:
                return collectionView.dequeueConfiguredReusableCell(
                    using: legalRegistration, for: indexPath, item: row
                )
            default:
                return collectionView.dequeueConfiguredReusableCell(
                    using: valueRegistration, for: indexPath, item: row
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration, for: indexPath
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
        PaperListCellStyle.apply(to: cell)
        switch row {
        case .hero, .legal:
            return

        case .benefitStorage:
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.proBenefitStorage.localizedString()
            // 两档容量由服务端下发，端上不写死——改后端常量即可全线生效。
            content.secondaryText = R.Strings.proBenefitStorageValue.formatted(
                ByteFormatting.string(store.status.freeQuotaBytes),
                ByteFormatting.string(store.status.proQuotaBytes)
            )
            cell.contentConfiguration = content
            cell.accessories = []

        case .subscribe:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            // 价格一律取 displayPrice：App Store 会按用户所在地区换算货币，
            // 硬编码 "$0.49" 在非美区就是错的，且会被审核拒。
            if let product = store.proProduct {
                content.text = R.Strings.proCtaSubscribe.formatted(product.displayPrice)
            } else {
                content.text = R.Strings.proCtaSubscribe.formatted("—")
            }
            content.textProperties.color = AppColor.accent
            content.textProperties.font = .systemFont(ofSize: 17, weight: .bold)
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []

        case .manage:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.proCtaManage.localizedString()
            content.textProperties.color = AppColor.accent
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []

        case .restore:
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.proCtaRestore.localizedString()
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []

        case .unavailable:
            // 商品拉不到时必须给个说法，不能白屏。最常见原因是
            // Paid Applications Agreement 还没生效。
            var content = UIListContentConfiguration.cell()
            content.applyPaperColors()
            content.text = R.Strings.proProductsUnavailable.localizedString()
            content.textProperties.color = AppColor.textSecondary
            cell.contentConfiguration = content
            cell.accessories = []
        }
    }

    // MARK: - 数据

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0, 1, 2, 3])
        snapshot.appendItems([.hero], toSection: 0)
        snapshot.appendItems([.benefitStorage], toSection: 1)

        var actions: [Row] = []
        if store.status.isPro {
            actions.append(.manage)
        } else if store.proProduct != nil {
            actions.append(.subscribe)
        } else if !store.isLoadingProducts {
            actions.append(.unavailable)
        }
        actions.append(.restore)
        snapshot.appendItems(actions, toSection: 2)

        snapshot.appendItems([.legal], toSection: 3)
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    private func reload() {
        setBusy(true)
        Task {
            await environment.appConfigStore.bootstrap()
            await store.loadProducts()
            await store.refreshStatus()
            setBusy(false)
            applySnapshot()
        }
    }

    // MARK: - 动作

    private func didSelect(_ row: Row) {
        switch row {
        case .subscribe: buy()
        case .restore: restore()
        case .manage: manageSubscription()
        case .hero, .benefitStorage, .legal, .unavailable: break
        }
    }

    private func buy() {
        guard let product = store.proProduct else { return }
        setBusy(true)
        Task {
            let outcome = await store.purchase(product)
            setBusy(false)
            applySnapshot()
            handle(outcome, successMessage: R.Strings.proPurchaseSuccess.localizedString())
        }
    }

    private func restore() {
        setBusy(true)
        Task {
            let outcome = await store.restorePurchases()
            setBusy(false)
            applySnapshot()
            handle(outcome, successMessage: R.Strings.proPurchaseSuccess.localizedString())
        }
    }

    private func handle(_ outcome: StoreKitService.PurchaseOutcome, successMessage: String) {
        switch outcome {
        case .success:
            HapticManager.notification(.success)
            presentInfo(successMessage)
        case .userCancelled:
            break
        case .pending:
            presentInfo(R.Strings.proPurchasePending.localizedString())
        case let .failed(message):
            presentError(message, title: R.Strings.proPurchaseFailed.localizedString())
        }
    }

    private func manageSubscription() {
        guard let scene = view.window?.windowScene else { return }
        Task {
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                await store.refreshStatus()
                applySnapshot()
            } catch {
                AppLogger.warning("打开订阅管理失败：\(error.localizedDescription)")
            }
        }
    }

    private func openLegal(_ url: URL) {
        present(SFSafariViewController(url: url), animated: true)
    }

    // MARK: - 辅助

    private func setBusy(_ busy: Bool) {
        if busy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        collectionView.isUserInteractionEnabled = busy == false
    }

    private func presentInfo(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }

    private func presentError(_ message: String, title: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }
}

extension ProUpgradeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        didSelect(row)
    }
}

// MARK: - Cells

/// 顶部卡：标题 + 一句话 + 当前状态（含宽限期警示）。
private final class ProHeroCell: UICollectionViewListCell {
    private let iconView = UIImageView(image: UIImage(systemName: "crown.fill"))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(status: BillingStatus) {
        titleLabel.text = R.Strings.proHeadline.formatted(
            ByteFormatting.string(status.proQuotaBytes)
        )
        subtitleLabel.text = R.Strings.proSubheadline.formatted(
            ByteFormatting.string(status.freeQuotaBytes)
        )

        let expiry = status.expiresAt.map(Self.dateFormatter.string(from:))
        switch (status.isPro, status.inGracePeriod, status.autoRenew) {
        case (true, true, _):
            // 续费失败但还在宽限窗口内——这是唯一需要用户立刻行动的状态，标红。
            statusLabel.text = expiry.map { R.Strings.proStatusGrace.formatted($0) }
            statusLabel.textColor = AppColor.danger
            statusLabel.font = .systemFont(ofSize: 12, weight: .bold)
        case (true, false, false):
            statusLabel.text = expiry.map { R.Strings.proStatusExpiring.formatted($0) }
            statusLabel.textColor = AppColor.ink.withAlphaComponent(0.72)
        case (true, false, true):
            statusLabel.text = expiry.map { R.Strings.proStatusActive.formatted($0) }
            statusLabel.textColor = AppColor.ink.withAlphaComponent(0.72)
        case (false, _, _):
            statusLabel.text = nil
        }
        statusLabel.isHidden = statusLabel.text == nil
    }

    private func setUpViews() {
        // 柠檬绿底上一律用墨绿字，白字在这个亮度上读不清。
        iconView.tintColor = AppColor.ink
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = AppTypography.sectionTitle
        titleLabel.textColor = AppColor.ink
        titleLabel.numberOfLines = 0

        subtitleLabel.font = AppTypography.body
        subtitleLabel.textColor = AppColor.ink.withAlphaComponent(0.72)
        subtitleLabel.numberOfLines = 0

        statusLabel.font = AppTypography.caption
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel, statusLabel])
        stack.axis = .vertical
        stack.spacing = AppSpacing.small
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.heightAnchor.constraint(equalToConstant: 32),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppSpacing.medium),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: AppSpacing.medium),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -AppSpacing.medium),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -AppSpacing.medium)
        ])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// 法务页脚：自动续期说明 + 用户协议 / 隐私政策 / Apple 使用条款。
/// 后两项中的 Apple EULA 与隐私政策入口是 App Store Review 3.1.2(a) 硬要求。
private final class ProLegalCell: UICollectionViewListCell {
    var onOpen: ((URL) -> Void)?

    private let noticeLabel = UILabel()
    private let userAgreementButton = UIButton(type: .system)
    private let termsButton = UIButton(type: .system)
    private let privacyButton = UIButton(type: .system)

    private var userAgreementURL: URL?
    private var termsOfUseURL: URL?
    private var privacyURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(userAgreement: URL, privacy: URL, termsOfUse: URL) {
        userAgreementURL = userAgreement
        privacyURL = privacy
        termsOfUseURL = termsOfUse
    }

    private func setUpViews() {
        noticeLabel.font = AppTypography.caption
        noticeLabel.textColor = AppColor.textSecondary
        noticeLabel.numberOfLines = 0
        noticeLabel.text = R.Strings.proLegal.localizedString()

        userAgreementButton.setTitle(R.Strings.proUserAgreement.localizedString(), for: .normal)
        userAgreementButton.titleLabel?.font = AppTypography.caption
        userAgreementButton.setTitleColor(AppColor.link, for: .normal)
        userAgreementButton.addTarget(
            self,
            action: #selector(openUserAgreement),
            for: .touchUpInside
        )

        termsButton.setTitle(R.Strings.proTerms.localizedString(), for: .normal)
        termsButton.titleLabel?.font = AppTypography.caption
        termsButton.setTitleColor(AppColor.link, for: .normal)
        termsButton.addTarget(self, action: #selector(openTerms), for: .touchUpInside)

        privacyButton.setTitle(R.Strings.proPrivacy.localizedString(), for: .normal)
        privacyButton.titleLabel?.font = AppTypography.caption
        privacyButton.setTitleColor(AppColor.link, for: .normal)
        privacyButton.addTarget(self, action: #selector(openPrivacy), for: .touchUpInside)

        let links = UIStackView(arrangedSubviews: [
            userAgreementButton,
            privacyButton,
            termsButton,
            UIView()
        ])
        links.axis = .horizontal
        links.spacing = AppSpacing.medium

        let stack = UIStackView(arrangedSubviews: [noticeLabel, links])
        stack.axis = .vertical
        stack.spacing = AppSpacing.small
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppSpacing.medium),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: AppSpacing.medium),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -AppSpacing.medium),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -AppSpacing.medium)
        ])
    }

    @objc private func openUserAgreement() {
        if let userAgreementURL { onOpen?(userAgreementURL) }
    }

    @objc private func openTerms() {
        if let termsOfUseURL { onOpen?(termsOfUseURL) }
    }

    @objc private func openPrivacy() {
        if let privacyURL { onOpen?(privacyURL) }
    }
}
