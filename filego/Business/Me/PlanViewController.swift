import StolnkCore
import StoreKit
import UIKit

/**
 「我的 → 会员」，也是全 App 唯一的付费墙。

 App 免费下载，会员是 $1.99/年的自动续期订阅（`MembershipService`）。这一屏要满足
 App Store 3.1.2：价格与周期写清楚、写明会自动续期且可随时在 Apple ID 设置里取消、
 给出使用条款与隐私政策链接、有「恢复购买」。

 是不是会员只看 Worker 的 `PlanState`；购买成功后由它回查 Apple 再说了算。
 */
@MainActor
final class PlanViewController: UIViewController {
    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let subscribeButton = PaperButton.primary()
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
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32)
        ])

        let mark = BrandMarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 56),
            mark.heightAnchor.constraint(equalToConstant: 56)
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

        let benefits = UIStackView(arrangedSubviews: [
            benefit(icon: "link", text: R.Strings.proBenefitLinks.localizedString()),
            benefit(icon: "lock.shield", text: R.Strings.proBenefitName.localizedString()),
            benefit(icon: "doc.fill", text: R.Strings.proBenefitFiles.localizedString()),
            benefit(icon: "arrow.up.arrow.down", text: R.Strings.proBenefitRelay.localizedString()),
            benefit(icon: "lock.fill", text: R.Strings.proBenefitPassword.localizedString()),
            benefit(icon: "clock", text: R.Strings.proBenefitExpiry.localizedString())
        ])
        benefits.axis = .vertical
        benefits.spacing = 12
        benefits.isLayoutMarginsRelativeArrangement = true
        benefits.directionalLayoutMargins = .init(top: 18, leading: 18, bottom: 18, trailing: 18)
        AppMaterial.raise(benefits, radius: AppRadius.card)
        stack.setCustomSpacing(AppSpacing.large, after: subtitle)
        stack.addArrangedSubview(benefits)

        statusLabel.font = AppTypography.body
        statusLabel.textColor = AppColor.textPrimary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        stack.setCustomSpacing(AppSpacing.large, after: benefits)
        stack.addArrangedSubview(statusLabel)

        activity.hidesWhenStopped = true
        stack.addArrangedSubview(activity)

        subscribeButton.addAction(UIAction { [weak self] _ in self?.subscribe() }, for: .touchUpInside)
        subscribeButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        stack.addArrangedSubview(subscribeButton)

        manageButton.addAction(UIAction { [weak self] _ in self?.manage() }, for: .touchUpInside)
        stack.addArrangedSubview(manageButton)

        restoreButton.addAction(UIAction { [weak self] _ in self?.restore() }, for: .touchUpInside)
        stack.addArrangedSubview(restoreButton)

        // 3.1.2：自动续期说明必须出现在购买按钮附近。
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
        let product = environment.membership.product
        let price = product?.displayPrice

        if member {
            // 3.1.2 的到期日，加上会员真正买到的那件事：子域名固化。
            let until = plan?.memberExpiryDate.map {
                R.Strings.proStatusActiveUntil.formatted($0.formatted(date: .long, time: .omitted))
            } ?? R.Strings.proStatusActive.localizedString()
            // 会员也可能是在地址到期后才订阅的：那时还没有名字，先提示设置。
            let locked = plan?.addressActive == false
                ? R.Strings.nameStatusExpired.localizedString()
                : R.Strings.nameStatusLocked.localizedString()
            statusLabel.text = "\(until)\n\(locked)"
        } else {
            statusLabel.text = price.map { R.Strings.proPriceLine.formatted($0) }
                ?? (environment.membership.isLoadingProduct
                    ? nil : R.Strings.memberProductUnavailable.localizedString())
        }
        statusLabel.isHidden = statusLabel.text == nil

        var configuration = subscribeButton.configuration
        configuration?.title = price.map { R.Strings.proCtaSubscribe.formatted($0) }
            ?? R.Strings.memberSubscribeShort.localizedString()
        subscribeButton.configuration = configuration
        subscribeButton.isHidden = member
        subscribeButton.isEnabled = !isBusy && environment.stolnk.isRegistered
        subscribeButton.alpha = subscribeButton.isEnabled ? 1 : 0.5
        manageButton.isHidden = !member
        restoreButton.isEnabled = !isBusy
        disclosureLabel.text = R.Strings.proAutoRenewDisclosure.formatted(price ?? "$1.99")
    }

    // MARK: - 操作

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        busy ? activity.startAnimating() : activity.stopAnimating()
        render()
    }

    private func subscribe() {
        guard !isBusy else { return }
        setBusy(true)
        Task {
            let outcome = await environment.membership.purchase()
            setBusy(false)
            handle(outcome)
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

    private func handle(_ outcome: MembershipService.PurchaseOutcome, restored: Bool = false) {
        switch outcome {
        case .success:
            HapticManager.notification(.success)
            PaperToast.show(
                (restored ? R.Strings.proRestoreSuccess : R.Strings.proPurchaseSuccess)
                    .localizedString(),
                in: view)
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
