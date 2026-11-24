import StolnkCore
import StoreKit
import UIKit

/**
 「我的 → 会员」，也是全 App 唯一的付费墙。

 App 免费下载，会员有两种买法（`MembershipService`）：
 - 年度自动续期订阅 $1.99/年；
 - 终身买断 $9.99，一次付费，不再续订。

 这一屏要满足 App Store 3.1.2：价格与周期写清楚、写明订阅会自动续期且可随时在
 Apple ID 设置里取消、写明终身版是一次性购买、给出使用条款与隐私政策链接、
 有「恢复购买」。

 是不是会员只看 Worker 的 `PlanState`；购买成功后由它回查 Apple 再说了算。
 */
@MainActor
final class PlanViewController: UIViewController {
    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let yearlyCard = UIStackView()
    private let lifetimeCard = UIStackView()
    private let yearlyPriceLabel = UILabel()
    private let lifetimePriceLabel = UILabel()
    private let yearlyButton = PaperButton.primary()
    private let lifetimeButton = PaperButton.primary()
    private let restoreButton = PaperButton.ghost(title: R.Strings.proRestore.localizedString())
    private let manageButton = PaperButton.secondary(title: R.Strings.proCtaManage.localizedString())
    private let disclosureLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private var isBusy = false

    static let termsURL = URL(string: "https://stolnk.com/terms")!
    static let privacyURL = URL(string: "https://stolnk.com/privacy")!
    static let appleEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 模态弹出（带关闭按钮）。门槛与 402 走这里；「我的」里是 push。
    static func present(from presenter: UIViewController, environment: AppEnvironment) {
        let controller = PlanViewController(environment: environment)
        let navigation = UINavigationController(rootViewController: controller)
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.proTitle.localizedString()
        view.backgroundColor = AppColor.background
        configureView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .stolnkStateDidChange, object: nil)
        render()
        Task {
            await environment.membership.loadProduct(forceRefresh: true)
            await environment.stolnk.refreshPlan()
            render()
        }
    }

    #if DEBUG
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Duo 展开成横屏后可视高度只有 2007pt，两张套餐卡放不下。
        // 宣传截图用这个参数滚到底部，让年度和终身两个价格同时出现在画面里。
        guard ProcessInfo.processInfo.arguments.contains("-screenshot-plan-lower") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let maxY = max(0, self.scrollView.contentSize.height - self.scrollView.bounds.height)
            // 340 而不是滚到底：顶部还能留下权益卡片，两张价格卡同时完整可见。
            self.scrollView.setContentOffset(CGPoint(x: 0, y: min(maxY, 200)), animated: false)
        }
    }
    #endif

    // MARK: - 视图

    private func configureView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = AppSpacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32)
        ])

        let mark = BrandMarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 48),
            mark.heightAnchor.constraint(equalToConstant: 48)
        ])
        let markRow = UIView()
        markRow.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: markRow.centerXAnchor),
            mark.topAnchor.constraint(equalTo: markRow.topAnchor),
            mark.bottomAnchor.constraint(equalTo: markRow.bottomAnchor)
        ])
        stack.addArrangedSubview(markRow)

        let headline = label(R.Strings.proHeadline.localizedString(), font: AppTypography.pageTitle)
        headline.textAlignment = .center
        stack.addArrangedSubview(headline)

        let subtitle = label(R.Strings.proSubheadline.localizedString(), font: AppTypography.body)
        subtitle.textColor = AppColor.textSecondary
        subtitle.textAlignment = .center
        stack.addArrangedSubview(subtitle)

        statusLabel.font = AppTypography.body
        statusLabel.textColor = AppColor.textPrimary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        stack.setCustomSpacing(AppSpacing.large, after: subtitle)
        stack.addArrangedSubview(statusLabel)

        let benefits = UIStackView(arrangedSubviews: [
            benefit(icon: "link", text: R.Strings.proBenefitLinks.localizedString()),
            benefit(icon: "lock.shield", text: R.Strings.proBenefitName.localizedString()),
            benefit(icon: "doc.fill", text: R.Strings.proBenefitFiles.localizedString()),
            benefit(icon: "arrow.up.arrow.down", text: R.Strings.proBenefitRelay.localizedString()),
            benefit(icon: "lock.fill", text: R.Strings.proBenefitPassword.localizedString()),
            benefit(icon: "clock", text: R.Strings.proBenefitExpiry.localizedString())
        ])
        benefits.axis = .vertical
        benefits.spacing = 8
        benefits.isLayoutMarginsRelativeArrangement = true
        benefits.directionalLayoutMargins = .init(top: 14, leading: 16, bottom: 14, trailing: 16)
        AppMaterial.raise(benefits, radius: AppRadius.card)
        stack.setCustomSpacing(AppSpacing.large, after: statusLabel)
        stack.addArrangedSubview(benefits)

        configureYearlyCard()
        configureLifetimeCard()
        stack.setCustomSpacing(AppSpacing.large, after: benefits)
        stack.addArrangedSubview(yearlyCard)
        stack.addArrangedSubview(lifetimeCard)

        activity.hidesWhenStopped = true
        stack.addArrangedSubview(activity)

        manageButton.addAction(UIAction { [weak self] _ in self?.manage() }, for: .touchUpInside)
        stack.addArrangedSubview(manageButton)

        restoreButton.addAction(UIAction { [weak self] _ in self?.restore() }, for: .touchUpInside)
        stack.addArrangedSubview(restoreButton)

        // 3.1.2：自动续期说明必须出现在购买按钮附近；终身版则要讲清它不是订阅。
        disclosureLabel.font = .preferredFont(forTextStyle: .caption1)
        disclosureLabel.adjustsFontForContentSizeCategory = true
        disclosureLabel.textColor = AppColor.textSecondary
        disclosureLabel.numberOfLines = 0
        disclosureLabel.textAlignment = .center
        stack.addArrangedSubview(disclosureLabel)

        let links = UIStackView(arrangedSubviews: [
            link(R.Strings.proTerms.localizedString(), Self.termsURL),
            link(R.Strings.proEula.localizedString(), Self.appleEULAURL),
            link(R.Strings.proPrivacy.localizedString(), Self.privacyURL)
        ])
        links.axis = .horizontal
        links.distribution = .equalCentering
        links.spacing = 8
        stack.addArrangedSubview(links)
    }

    private func configureYearlyCard() {
        yearlyPriceLabel.font = AppTypography.body
        yearlyPriceLabel.textColor = AppColor.textPrimary
        yearlyButton.addAction(
            UIAction { [weak self] _ in self?.subscribeYearly() }, for: .touchUpInside)

        let card = makeCard(
            title: R.Strings.proPlanYearlyTitle.localizedString(),
            badge: nil,
            priceLabel: yearlyPriceLabel,
            note: R.Strings.proPlanYearlyNote.localizedString(),
            button: yearlyButton)
        yearlyCard.axis = .vertical
        yearlyCard.addArrangedSubview(card)
    }

    private func configureLifetimeCard() {
        lifetimePriceLabel.font = AppTypography.body
        lifetimePriceLabel.textColor = AppColor.textPrimary
        lifetimeButton.addAction(
            UIAction { [weak self] _ in self?.subscribeLifetime() }, for: .touchUpInside)

        let card = makeCard(
            title: R.Strings.proPlanLifetimeTitle.localizedString(),
            badge: R.Strings.proPlanLifetimeBadge.localizedString(),
            priceLabel: lifetimePriceLabel,
            note: R.Strings.proPlanLifetimeNote.localizedString(),
            button: lifetimeButton)
        lifetimeCard.axis = .vertical
        lifetimeCard.addArrangedSubview(card)
    }

    private func makeCard(
        title: String, badge: String?, priceLabel: UILabel, note: String, button: UIButton
    ) -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 8
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = .init(top: 14, leading: 16, bottom: 14, trailing: 16)
        AppMaterial.raise(card, radius: AppRadius.card)

        let titleLabel = label(title, font: AppTypography.sectionTitle)
        let header = UIStackView(arrangedSubviews: [titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        if let badge {
            let badgeLabel = UILabel()
            badgeLabel.text = badge
            badgeLabel.font = .preferredFont(forTextStyle: .caption1)
            badgeLabel.textColor = AppColor.ink
            badgeLabel.backgroundColor = AppColor.FileTile.folderBackground
            badgeLabel.layer.cornerRadius = 9
            badgeLabel.layer.masksToBounds = true
            badgeLabel.textAlignment = .center
            badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            badgeLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
            header.addArrangedSubview(badgeLabel)
        }
        header.addArrangedSubview(UIView())
        card.addArrangedSubview(header)
        card.addArrangedSubview(priceLabel)

        let noteLabel = label(note, font: .preferredFont(forTextStyle: .footnote))
        noteLabel.textColor = AppColor.textSecondary
        card.addArrangedSubview(noteLabel)

        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        card.setCustomSpacing(12, after: noteLabel)
        card.addArrangedSubview(button)
        return card
    }

    private func label(_ text: String, font: UIFont) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = AppColor.textPrimary
        label.numberOfLines = 0
        return label
    }

    private func benefit(icon: String, text: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: icon))
        image.tintColor = AppColor.FileTile.folderForeground
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let textLabel = label(text, font: AppTypography.body)
        let row = UIStackView(arrangedSubviews: [image, textLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func link(_ title: String, _ url: URL) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        // 用 AttributedString 而不是 titleTextAttributesTransformer：新 SDK 里
        // AttributeContainer 的下划线属性是 get-only 的 builder，赋值编译不过。
        var attributed = AttributedString(title)
        attributed.font = .preferredFont(forTextStyle: .footnote)
        attributed.underlineStyle = .single
        attributed.foregroundColor = AppColor.ink
        configuration.attributedTitle = attributed
        configuration.baseForegroundColor = AppColor.ink
        configuration.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in UIApplication.shared.open(url) }, for: .touchUpInside)
        return button
    }

    @objc private func stateDidChange() { render() }

    // MARK: - 渲染

    private func render() {
        let plan = environment.stolnk.plan
        let member = plan?.isPro == true
        let forever = member && plan?.memberExpiresAt == nil
        let yearlyPrice = environment.membership.yearlyProduct?.displayPrice
        let lifetimePrice = environment.membership.lifetimeProduct?.displayPrice

        if member {
            if forever {
                statusLabel.text = R.Strings.proStatusLifetime.localizedString()
            } else {
                // 3.1.2 的到期日，加上会员真正买到的那件事：子域名固化。
                let until = plan?.memberExpiryDate.map {
                    R.Strings.proStatusActiveUntil.formatted($0.formatted(date: .long, time: .omitted))
                } ?? R.Strings.proStatusActive.localizedString()
                // 会员也可能是在地址到期后才订阅的：那时还没有名字，先提示设置。
                let locked = plan?.addressActive == false
                    ? R.Strings.nameStatusExpired.localizedString()
                    : R.Strings.nameStatusLocked.localizedString()
                statusLabel.text = "\(until)\n\(locked)"
            }
        } else {
            // 副标题已经解释了可选项，未开通时不再重复一行。
            statusLabel.text = nil
        }
        statusLabel.isHidden = statusLabel.text == nil

        yearlyPriceLabel.text = yearlyPrice.map { R.Strings.proCtaSubscribe.formatted($0) }
            ?? R.Strings.proPlanYearlyFallbackPrice.localizedString()
        lifetimePriceLabel.text = lifetimePrice.map { R.Strings.proPlanLifetimePrice.formatted($0) }
            ?? R.Strings.proPlanLifetimeFallbackPrice.localizedString()

        var yearly = yearlyButton.configuration
        yearly?.title = yearlyPrice.map { R.Strings.proCtaSubscribe.formatted($0) }
            ?? R.Strings.memberSubscribeShort.localizedString()
        yearlyButton.configuration = yearly

        var lifetime = lifetimeButton.configuration
        lifetime?.title = lifetimePrice.map { R.Strings.proPlanLifetimeCta.formatted($0) }
            ?? R.Strings.proPlanLifetimeCtaFallback.localizedString()
        lifetimeButton.configuration = lifetime

        // 已经是会员就不再卖会员；订阅会员仍可升级到终身版。
        yearlyCard.isHidden = member
        lifetimeCard.isHidden = forever
        let buyable = !isBusy && environment.stolnk.isRegistered
        for button in [yearlyButton, lifetimeButton] {
            button.isEnabled = buyable
            button.alpha = buyable ? 1 : 0.5
        }
        manageButton.isHidden = !member
        restoreButton.isEnabled = !isBusy

        var disclosures: [String] = []
        if !member {
            disclosures.append(
                R.Strings.proAutoRenewDisclosure.formatted(yearlyPrice ?? "$1.99"))
        }
        if !forever {
            disclosures.append(
                R.Strings.proLifetimeDisclosure.formatted(lifetimePrice ?? "$9.99"))
        }
        disclosureLabel.text = disclosures.isEmpty ? nil : disclosures.joined(separator: "\n\n")
        disclosureLabel.isHidden = disclosures.isEmpty
    }

    // MARK: - 操作

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        busy ? activity.startAnimating() : activity.stopAnimating()
        render()
    }

    private func subscribeYearly() {
        guard !isBusy else { return }
        setBusy(true)
        Task {
            let outcome = await environment.membership.purchaseYearly()
            setBusy(false)
            handle(outcome)
        }
    }

    private func subscribeLifetime() {
        guard !isBusy else { return }
        setBusy(true)
        Task {
            let outcome = await environment.membership.purchaseLifetime()
            setBusy(false)
            handle(outcome, lifetime: true)
        }
    }

    private func restore() {
        guard !isBusy else { return }
        setBusy(true)
        Task {
            let outcome = await environment.membership.restore()
            setBusy(false)
            handle(outcome, restored: true)
        }
    }

    private func manage() {
        Task { await environment.membership.showManageSubscriptions(from: self) }
    }

    private func handle(
        _ outcome: MembershipService.PurchaseOutcome,
        restored: Bool = false,
        lifetime: Bool = false
    ) {
        switch outcome {
        case .success:
            HapticManager.notification(.success)
            let message = restored
                ? R.Strings.proRestoreSuccess.localizedString()
                : lifetime
                    ? R.Strings.proPurchaseSuccessLifetime.localizedString()
                    : R.Strings.proPurchaseSuccess.localizedString()
            PaperToast.show(message, in: view)
        case .userCancelled:
            break
        case .pending:
            presentMessage(R.Strings.proPurchasePending.localizedString())
        case .failed(let message):
            presentMessage(message, title: R.Strings.proPurchaseFailed.localizedString())
        }
        render()
    }

    private func presentMessage(_ message: String, title: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }
}

extension PlanViewController {
    /**
     402（`upgrade_required`）和本地判定的会员门槛的统一出口。

     不是会员就直接弹会员页；已经是会员还撞上，就是会员自己的上限。
     */
    static func handleUpgradeRequired(on presenter: UIViewController, environment: AppEnvironment) {
        if environment.stolnk.plan?.isPro == true {
            let controller = UIAlertController(
                title: nil, message: R.Strings.proLimitReached.localizedString(),
                preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
            presenter.present(controller, animated: true)
            return
        }
        present(from: presenter, environment: environment)
    }
}
