import StoreKit
import StolnkCore
import UIKit

/// A compact paywall for the non-consumable Pro unlock. The localized price is
/// always StoreKit's `displayPrice`; no currency amount is embedded in the app.
@MainActor
final class ProUpgradeViewController: UIViewController {
    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let buyButton = PaperButton.primary()
    private let restoreButton = PaperButton.secondary(title: R.Strings.proCtaRestore.localizedString())
    private let activity = UIActivityIndicatorView(style: .medium)

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.proTitle.localizedString()
        view.backgroundColor = AppColor.background
        configureView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateDidChange),
            name: .stolnkStoreKitDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateDidChange),
            name: .stolnkStateDidChange,
            object: nil
        )
        render()
        Task {
            await environment.storeKit.loadProduct(force: true)
            await environment.stolnk.refreshPlan()
            render()
        }
    }

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
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 32),
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
            benefit(icon: "link", text: R.Strings.proBenefitInboxes.localizedString()),
            benefit(icon: "doc.fill", text: R.Strings.proBenefitFiles.localizedString()),
            benefit(icon: "arrow.up.arrow.down", text: R.Strings.proBenefitRelay.localizedString()),
            benefit(icon: "lock.fill", text: R.Strings.proBenefitPassword.localizedString())
        ])
        benefits.axis = .vertical
        benefits.spacing = 12
        benefits.isLayoutMarginsRelativeArrangement = true
        benefits.directionalLayoutMargins = .init(top: 18, leading: 18, bottom: 18, trailing: 18)
        benefits.backgroundColor = AppColor.surface
        benefits.layer.cornerRadius = AppRadius.card
        benefits.layer.cornerCurve = .continuous
        benefits.layer.borderColor = AppColor.line.cgColor
        benefits.layer.borderWidth = 1
        stack.setCustomSpacing(AppSpacing.large, after: subtitle)
        stack.addArrangedSubview(benefits)

        statusLabel.font = AppTypography.body
        statusLabel.textColor = AppColor.textSecondary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        stack.addArrangedSubview(statusLabel)

        activity.hidesWhenStopped = true
        stack.addArrangedSubview(activity)

        buyButton.addAction(UIAction { [weak self] _ in self?.buy() }, for: .touchUpInside)
        restoreButton.addAction(UIAction { [weak self] _ in self?.restore() }, for: .touchUpInside)
        stack.addArrangedSubview(buyButton)
        stack.addArrangedSubview(restoreButton)

        let legal = label(R.Strings.proLegal.localizedString(), font: AppTypography.caption)
        legal.textColor = AppColor.textSecondary
        legal.textAlignment = .center
        stack.addArrangedSubview(legal)
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

    @objc private func stateDidChange() { render() }

    private func render() {
        let purchased = environment.stolnk.plan?.isPro == true
        if purchased {
            statusLabel.text = R.Strings.proLifetimeActive.localizedString()
            buyButton.configuration?.title = R.Strings.proLifetimeOwned.localizedString()
            buyButton.isEnabled = false
            restoreButton.isHidden = true
        } else {
            statusLabel.text = environment.storeKit.lastError
            let price = environment.storeKit.product?.displayPrice ?? "—"
            buyButton.configuration?.title = R.Strings.proCtaBuy.formatted(price)
            buyButton.isEnabled = environment.storeKit.product != nil && !environment.storeKit.isLoading
            restoreButton.isHidden = false
        }
        environment.storeKit.isLoading ? activity.startAnimating() : activity.stopAnimating()
    }

    private func setBusy(_ busy: Bool) {
        busy ? activity.startAnimating() : activity.stopAnimating()
        buyButton.isEnabled = !busy && environment.storeKit.product != nil
        restoreButton.isEnabled = !busy
    }

    private func buy() {
        setBusy(true)
        Task {
            let outcome = await environment.storeKit.purchase()
            setBusy(false)
            handle(outcome)
            render()
        }
    }

    private func restore() {
        setBusy(true)
        Task {
            let outcome = await environment.storeKit.restore()
            setBusy(false)
            handle(outcome)
            render()
        }
    }

    private func handle(_ outcome: StoreKitService.Outcome) {
        switch outcome {
        case .success:
            HapticManager.notification(.success)
            PaperToast.show(R.Strings.proPurchaseSuccess.localizedString(), in: view)
        case .cancelled:
            break
        case .pending:
            presentMessage(R.Strings.proPurchasePending.localizedString())
        case let .failed(message):
            presentMessage(message, title: R.Strings.proPurchaseFailed.localizedString())
        }
    }

    private func presentMessage(_ message: String, title: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }
}
