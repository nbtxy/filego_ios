import StolnkCore
import UIKit

/// 「我的 → 套餐」。App 是付费下载，这里没有购买：只展示已包含的权益，
/// 万一本设备还没在 Worker 上开通（比如首次启动时断网），给一个重新同步的按钮。
@MainActor
final class PlanViewController: UIViewController {
    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let syncButton = PaperButton.primary(title: R.Strings.proSync.localizedString())
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
            name: .stolnkStateDidChange,
            object: nil
        )
        render()
        Task {
            await environment.stolnk.refreshPlan()
            await environment.appUnlock.claimIfNeeded()
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
        AppMaterial.raise(benefits, radius: AppRadius.card)
        stack.setCustomSpacing(AppSpacing.large, after: subtitle)
        stack.addArrangedSubview(benefits)

        statusLabel.font = AppTypography.body
        statusLabel.textColor = AppColor.textSecondary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        stack.addArrangedSubview(statusLabel)

        activity.hidesWhenStopped = true
        stack.addArrangedSubview(activity)

        syncButton.addAction(UIAction { [weak self] _ in self?.sync() }, for: .touchUpInside)
        stack.addArrangedSubview(syncButton)
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
        let active = environment.stolnk.plan?.isPro == true
        statusLabel.text = active
            ? R.Strings.proIncludedActive.localizedString()
            : R.Strings.proIncludedPending.localizedString()
        syncButton.isHidden = active
    }

    private func sync() {
        activity.startAnimating()
        syncButton.isEnabled = false
        Task {
            defer {
                activity.stopAnimating()
                syncButton.isEnabled = true
                render()
            }
            do {
                if try await environment.appUnlock.claim() {
                    HapticManager.notification(.success)
                }
            } catch {
                presentMessage(error.localizedDescription, title: R.Strings.proSyncFailed.localizedString())
            }
        }
    }

    private func presentMessage(_ message: String, title: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }
}

extension PlanViewController {
    /**
     402（`upgrade_required`）和本地判定的 Pro 门槛的统一出口。

     付费下载下没有付费墙可推：还不是 Pro 多半是首次认领没成功，先补一次认领，成了就请用户
     重试；认领失败才打开套餐页让用户自己重新同步。已经是 Pro 还撞上，就是 Pro 自己的上限。
     */
    static func handleUpgradeRequired(on presenter: UIViewController, environment: AppEnvironment) {
        func alert(_ title: String?, _ message: String) {
            let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
            presenter.present(controller, animated: true)
        }
        if environment.stolnk.plan?.isPro == true {
            return alert(nil, R.Strings.proLimitReached.localizedString())
        }
        Task { @MainActor in
            if (try? await environment.appUnlock.claim()) == true {
                alert(nil, R.Strings.proSyncRetry.localizedString())
            } else {
                presenter.present(
                    UINavigationController(rootViewController: PlanViewController(environment: environment)),
                    animated: true)
            }
        }
    }
}
