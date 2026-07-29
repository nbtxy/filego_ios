import UIKit

/// 「我的」页：账号信息、容量进度、登出。
/// M0 只做基础展示；M4 再补按类型的容量明细与回收站占用。
final class MeViewController: UIViewController {
    private let environment: AppEnvironment

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let accountLabel = UILabel()
    private let storageTitleLabel = UILabel()
    private let storageProgress = UIProgressView(progressViewStyle: .default)
    private let storageDetailLabel = UILabel()
    private let countsLabel = UILabel()
    private let signOutButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.tabMe.localizedString()
        view.backgroundColor = AppColor.background
        setUpViews()
        #if DEBUG
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "network"),
            style: .plain,
            target: self,
            action: #selector(showHTTPHistory)
        )
        #endif
        reload()
    }

    private func setUpViews() {
        contentStack.axis = .vertical
        contentStack.spacing = AppSpacing.medium
        contentStack.alignment = .fill

        accountLabel.font = AppTypography.title
        accountLabel.textColor = AppColor.textPrimary
        accountLabel.numberOfLines = 0

        storageTitleLabel.font = AppTypography.body
        storageTitleLabel.textColor = AppColor.textPrimary

        storageProgress.progressTintColor = AppColor.accent
        storageProgress.trackTintColor = AppColor.separator

        storageDetailLabel.font = AppTypography.caption
        storageDetailLabel.textColor = AppColor.textSecondary
        storageDetailLabel.numberOfLines = 0

        countsLabel.font = AppTypography.caption
        countsLabel.textColor = AppColor.textSecondary

        signOutButton.setTitle(R.Strings.meSignOut.localizedString(), for: .normal)
        signOutButton.setTitleColor(.systemRed, for: .normal)
        signOutButton.titleLabel?.font = AppTypography.body
        signOutButton.addTarget(self, action: #selector(didTapSignOut), for: .touchUpInside)

        [accountLabel, storageTitleLabel, storageProgress, storageDetailLabel,
         countsLabel, signOutButton].forEach(contentStack.addArrangedSubview)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        view.addSubview(activityIndicator)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: AppSpacing.large),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: AppSpacing.medium),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -AppSpacing.medium),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -AppSpacing.large),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.widthAnchor,
                constant: -AppSpacing.medium * 2
            ),

            activityIndicator.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: guide.centerYAnchor)
        ])
    }

    private func reload() {
        activityIndicator.startAnimating()
        contentStack.isHidden = true
        Task {
            do {
                let profile = try await environment.accountService.loadProfile()
                apply(profile)
            } catch {
                AppLogger.error("加载账号信息失败", error: error)
                accountLabel.text = R.Strings.meLoadFailed.localizedString()
                storageTitleLabel.text = error.localizedDescription
                storageProgress.isHidden = true
                storageDetailLabel.isHidden = true
                countsLabel.isHidden = true
            }
            activityIndicator.stopAnimating()
            contentStack.isHidden = false
        }
    }

    private func apply(_ profile: AccountProfile) {
        accountLabel.text = profile.user.displayName?.nilIfEmpty
            ?? profile.user.email?.nilIfEmpty
            ?? profile.user.id

        let storage = profile.storage
        storageTitleLabel.text = R.Strings.meStorageTitle.localizedString()
        storageProgress.isHidden = false
        storageProgress.progress = Float(storage.committedFraction)

        let used = Self.byteFormatter.string(fromByteCount: storage.usedBytes)
        let quota = Self.byteFormatter.string(fromByteCount: storage.quotaBytes)
        var detail = R.Strings.meStorageDetail.formatted(used, quota)
        if storage.reservedBytes > 0 {
            let reserved = Self.byteFormatter.string(fromByteCount: storage.reservedBytes)
            detail += "\n" + R.Strings.meStorageReserved.formatted(reserved)
        }
        storageDetailLabel.isHidden = false
        storageDetailLabel.text = detail

        countsLabel.isHidden = false
        countsLabel.text = R.Strings.meCounts.formatted(
            profile.counts.files,
            profile.counts.folders,
            profile.counts.trashed
        )
    }

    // MARK: - 动作

    @objc private func didTapSignOut() {
        let alert = UIAlertController(
            title: R.Strings.meSignOutConfirm.localizedString(),
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.meSignOut.localizedString(),
            style: .destructive
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.environment.accountService.signOut()
                // 清态后 RootViewController 会收到通知并切回登录页
            }
        })
        present(alert, animated: true)
    }

    #if DEBUG
    @objc private func showHTTPHistory() {
        navigationController?.pushViewController(HTTPHistoryViewController(), animated: true)
    }
    #endif

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary  // 配额是 10 GiB，用二进制单位口径才对得上
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}
