import StolnkCore
import UIKit

/**
 把一个本地文件变成一条公开的下载链接。对应 Mac 端的 `NewShareView`。

 模态而不是 push：它是一件带「取消」的差事，而且上传全程必须留在屏幕上——
 `StolnkCore` 用的是 `URLSession.shared`，不是 background session，App 一进后台
 传输就断，链接会卡在 `uploading` 再也好不了（详见 `submit()` 上的注释）。

 「share」在本 App 里已经指系统分享面板了，这里说的是下载链接，见 `ShareFormatting`
 开头的说明。
 */
@MainActor
final class NewShareViewController: UIViewController {
    private let environment: AppEnvironment
    private let file: URL
    private let filename: String
    private let size: Int64
    private let onCreated: (ShareHandle) -> Void

    private let scrollView = UIScrollView()
    private let ttlControl = UISegmentedControl(
        items: ShareTTL.presets.map { ShareTTL.label($0) })
    private let downloadsControl = UISegmentedControl(
        items: ShareDownloads.presets.map { ShareDownloads.label($0) })
    private let passwordField = UITextField()
    private let passwordProButton = PaperButton.secondary()
    private let pathField = UITextField()
    private let pathStatusLabel = UILabel()
    private let guessableWarning = UILabel()
    private let downloadCountWarning = UILabel()
    private let largeFileWarning = UILabel()
    private let createButton = PaperButton.primary()

    private let progressStack = UIStackView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()

    private var probe: NameAvailabilityProbe!
    private var pathStatus: NameStatus = .empty
    private var isBusy = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var isPro: Bool { environment.stolnk.plan?.isPro == true }

    /// 超过这个大小就提醒一句「别切走」。没有精确依据，纯粹是「大到值得说一声」。
    private static let largeFileThreshold: Int64 = 200 * 1024 * 1024

    init(
        environment: AppEnvironment,
        file: URL,
        filename: String,
        size: Int64,
        onCreated: @escaping (ShareHandle) -> Void
    ) {
        self.environment = environment
        self.file = file
        self.filename = filename
        self.size = size
        self.onCreated = onCreated
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.shareFormTitle.localizedString()
        view.backgroundColor = AppColor.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: R.Strings.commonCancel.localizedString(), style: .plain,
            target: self, action: #selector(cancel))
        buildProbe()
        buildLayout()
        renderPath(.empty)
        updateWarnings()
    }

    /**
     路径的可用性探针。

     规则传的是 `ShareCodeRules` 而不是默认的 `NameRules`：链接路径是单段、3–32 位，
     和设备名不是一回事。`problem` 只当闸门用——它返回的是未翻译的英文。
     */
    private func buildProbe() {
        probe = NameAvailabilityProbe(
            normalise: ShareCodeRules.normalise,
            problem: { ShareCodeRules.problem(with: $0) },
            check: { [environment] candidate in
                await environment.stolnk.isShareCodeAvailable(candidate)
            },
            update: { [weak self] status, candidate in
                self?.renderPath(status, candidate: candidate)
            }
        )
    }

    // MARK: - 布局

    private func buildLayout() {
        let fileLabel = UILabel()
        fileLabel.text = filename
        fileLabel.font = AppTypography.sectionTitle
        fileLabel.textColor = AppColor.ink
        fileLabel.numberOfLines = 2
        fileLabel.lineBreakMode = .byTruncatingMiddle

        let sizeLabel = UILabel()
        sizeLabel.text = ByteFormatting.storage(size)
        sizeLabel.font = .preferredFont(forTextStyle: .footnote)
        sizeLabel.textColor = AppColor.textSecondary

        ttlControl.selectedSegmentIndex = ShareTTL.presets.firstIndex(of: 24) ?? 0
        ttlControl.addTarget(self, action: #selector(ttlChanged), for: .valueChanged)
        applyTierToTTL()

        downloadsControl.selectedSegmentIndex = 0
        downloadsControl.addTarget(self, action: #selector(downloadsChanged), for: .valueChanged)

        passwordField.placeholder = R.Strings.sharePasswordPlaceholder.localizedString()
        passwordField.isSecureTextEntry = true
        passwordField.borderStyle = .roundedRect
        passwordField.textColor = AppColor.ink
        passwordField.autocapitalizationType = .none
        passwordField.autocorrectionType = .no
        passwordField.textContentType = .oneTimeCode

        // 免费版给的是一个能点的按钮，不是一个灰掉的密文输入框：后者在 iOS 上是很差的
        // 可供性——看得见、点得动、打不进去，用户只会以为键盘坏了。
        passwordProButton.configuration?.title = R.Strings.sharePasswordProOnly.localizedString()
        passwordProButton.addTarget(self, action: #selector(showUpgrade), for: .touchUpInside)

        InboxPathField.configure(
            pathField,
            prefix: environment.stolnk.addressPrefix.map { $0 + "~" },
            text: nil,
            placeholder: R.Strings.sharePathPlaceholder.localizedString())
        pathField.borderStyle = .roundedRect
        pathField.textColor = AppColor.ink
        pathField.addTarget(self, action: #selector(pathChanged), for: .editingChanged)

        pathStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        pathStatusLabel.numberOfLines = 0

        for warning in [guessableWarning, downloadCountWarning, largeFileWarning] {
            warning.font = .preferredFont(forTextStyle: .footnote)
            warning.textColor = AppColor.danger
            warning.numberOfLines = 0
        }
        guessableWarning.text = R.Strings.shareWarningGuessable.localizedString()
        downloadCountWarning.text = R.Strings.shareWarningDownloadCount.localizedString()
        largeFileWarning.text = R.Strings.shareSizeLargeWarning.localizedString()
        largeFileWarning.isHidden = size < Self.largeFileThreshold

        // 无条件挂着，不是可选文案：`docs/wire-format.md` 明确要求创建页披露
        // 「外发链接不是端到端加密的」，而且永远不能把它说成端到端加密。
        let plaintextWarning = UILabel()
        plaintextWarning.text = R.Strings.shareWarningPlaintext.localizedString()
        plaintextWarning.font = .preferredFont(forTextStyle: .footnote)
        plaintextWarning.textColor = AppColor.danger
        plaintextWarning.numberOfLines = 0

        createButton.configuration?.title = R.Strings.shareFormCreate.localizedString()
        createButton.addTarget(self, action: #selector(submit), for: .touchUpInside)

        progressView.progressTintColor = AppColor.ink
        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.textColor = AppColor.textSecondary
        progressLabel.numberOfLines = 0
        progressLabel.text = R.Strings.shareUploadKeepOpen.localizedString()
        progressStack.axis = .vertical
        progressStack.spacing = AppSpacing.small
        progressStack.addArrangedSubview(progressView)
        progressStack.addArrangedSubview(progressLabel)
        progressStack.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            fileLabel,
            sizeLabel,
            caption(R.Strings.shareFormExpires.localizedString()),
            ttlControl,
            caption(R.Strings.shareFormDownloads.localizedString()),
            downloadsControl,
            downloadCountWarning,
            caption(R.Strings.shareFormPassword.localizedString()),
            isPro ? passwordField : passwordProButton,
            caption(R.Strings.shareFormPath.localizedString()),
            pathField,
            pathStatusLabel,
            guessableWarning,
            plaintextWarning,
            largeFileWarning,
            createButton,
            progressStack,
        ])
        stack.axis = .vertical
        stack.spacing = AppSpacing.medium
        stack.setCustomSpacing(AppSpacing.extraSmall, after: fileLabel)
        stack.setCustomSpacing(AppSpacing.extraSmall, after: pathField)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.addSubview(stack)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -28),

            createButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = AppColor.textSecondary
        return label
    }

    /// 免费档只能选 24 小时以内。禁用而不是隐藏：看得见才知道升级能换来什么。
    private func applyTierToTTL() {
        for (index, hours) in ShareTTL.presets.enumerated() {
            ttlControl.setTitle(ShareTTL.label(hours, isPro: isPro), forSegmentAt: index)
            ttlControl.setEnabled(isPro || !ShareTTL.requiresPro(hours), forSegmentAt: index)
        }
    }

    // MARK: - 选项

    private var selectedTTL: Double { ShareTTL.presets[ttlControl.selectedSegmentIndex] }

    private var selectedMaxDownloads: Int? {
        ShareDownloads.presets[downloadsControl.selectedSegmentIndex]
    }

    @objc private func ttlChanged() { updateWarnings() }

    @objc private func downloadsChanged() { updateWarnings() }

    @objc private func pathChanged() {
        probe.evaluate(pathField.text ?? "")
        updateWarnings()
    }

    private func updateWarnings() {
        // 自己取的路径才是能被猜到的路径；留空是服务端随机生成的 16 位，没什么可猜。
        guessableWarning.isHidden = (pathField.text ?? "").isEmpty
        downloadCountWarning.isHidden = selectedMaxDownloads == nil
    }

    @objc private func showUpgrade() {
        present(
            UINavigationController(rootViewController: ProUpgradeViewController(
                environment: environment)),
            animated: true)
    }

    // MARK: - 路径可用性

    private func renderPath(_ status: NameStatus, candidate: String = "") {
        pathStatus = status
        switch status {
        case .available:
            pathStatusLabel.text = R.Strings.sharePathAvailable.formatted(candidate)
            pathStatusLabel.textColor = AppColor.ink
        case .taken:
            pathStatusLabel.text = R.Strings.sharePathTaken.localizedString()
            pathStatusLabel.textColor = AppColor.danger
        case .invalid:
            // 渲染 catalog 里的中英文，不是 `ShareCodeRules.problem` 的英文原文。
            pathStatusLabel.text = R.Strings.sharePathInvalid.localizedString()
            pathStatusLabel.textColor = AppColor.textSecondary
        case .unknown:
            pathStatusLabel.text = R.Strings.sharePathUnknown.localizedString()
            pathStatusLabel.textColor = AppColor.textSecondary
        case .checking:
            pathStatusLabel.text = R.Strings.onboardingChecking.localizedString()
            pathStatusLabel.textColor = AppColor.textSecondary
        // 留空是合法的，也没什么可说的。`unchanged` 在这里不会出现——没有「当前路径」。
        case .empty, .unchanged:
            pathStatusLabel.text = nil
        }
        updateCreateButton()
    }

    /**
     能不能按下「创建链接」。

     刻意不问 `status.blocksSubmission`：那个属性把 `.empty` 算作拦截，对设备名是对的，
     对这里是反的——留空恰恰是合法的，意味着「服务端给我随机生成一个」。Mac 端的
     `NewShareView` 出于同样的理由也绕开了它。
     */
    private func updateCreateButton() {
        let blocked = pathStatus == .taken || pathStatus == .invalid || pathStatus == .checking
        createButton.isEnabled = !isBusy && !blocked
        createButton.alpha = createButton.isEnabled ? 1 : 0.4
    }

    // MARK: - 提交

    @objc private func cancel() { dismiss(animated: true) }

    /**
     创建并上传。

     上传期间这一屏锁死：`isModalInPresentation` 挡掉下滑关闭，取消按钮也撤掉。理由
     不是洁癖——`StolnkCore` 用的是 `URLSession.shared`，App 一挂起传输就断，而 part
     上传用的是 `ShareHandle.token`，那个令牌本地没有持久化，所以断了就再也接不上：
     服务端会留下一行永远停在 `uploading` 的记录，占着额度和路径。免费档只有一个额度，
     那就是把用户锁在门外。

     `beginBackgroundTask` 换来大约 30 秒宽限，小文件短暂切走还能落地；再长就不是这
     一层能解决的了，得换成真正的 background session（见计划里的后续项）。
     */
    @objc private func submit() {
        guard !isBusy else { return }
        pathField.resignFirstResponder()
        passwordField.resignFirstResponder()
        setBusy(true)

        let password = isPro ? passwordField.text?.nilIfEmpty : nil
        let code = pathField.text?.nilIfEmpty
        let ttl = selectedTTL
        let maxDownloads = selectedMaxDownloads

        Task {
            beginBackgroundTask()
            defer { endBackgroundTask() }
            do {
                let handle = try await environment.stolnk.createShare(
                    file: file, ttlHours: ttl, maxDownloads: maxDownloads,
                    password: password, code: code)
                let completion = onCreated
                dismiss(animated: true) { completion(handle) }
            } catch {
                setBusy(false)
                showError(error)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        isModalInPresentation = busy
        navigationItem.leftBarButtonItem?.isEnabled = !busy
        UIApplication.shared.isIdleTimerDisabled = busy
        progressStack.isHidden = !busy
        createButton.isHidden = busy
        for control in [ttlControl, downloadsControl] { control.isEnabled = !busy }
        pathField.isEnabled = !busy
        passwordField.isEnabled = !busy
        if busy {
            progressView.setProgress(0, animated: false)
            NotificationCenter.default.addObserver(
                self, selector: #selector(stateDidChange),
                name: .stolnkStateDidChange, object: nil)
        } else {
            NotificationCenter.default.removeObserver(self, name: .stolnkStateDidChange, object: nil)
        }
        updateCreateButton()
    }

    @objc private func stateDidChange() {
        guard let upload = environment.stolnk.shareUpload else { return }
        progressView.setProgress(Float(upload.fraction), animated: true)
    }

    private func beginBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "stolnk.share-upload") {
            [weak self] in self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /**
     报错。

     402 不弹 alert 而是直接推付费页：它有三种成因（时长超档、密码要 Pro、条数用完），
     三者的答案是同一个，把它写成一句话只会比付费页本身更含糊。409 和 413 则必须分开
     讲——一个是「换个路径」，一个是「撤回一条再传」，建议完全不同。
     */
    private func showError(_ error: Error) {
        guard let apiError = error as? APIError else {
            return showMessage(
                title: R.Strings.commonError.localizedString(),
                message: error.localizedDescription)
        }
        if apiError.isUpgradeRequired { return showUpgrade() }
        if apiError.code == "code_taken" {
            // 不关页面：路径撞车是最常见的失败，用户就在这一屏接着改。
            probe.evaluate(pathField.text ?? "")
            return showMessage(
                title: R.Strings.sharePathTakenTitle.localizedString(),
                message: R.Strings.sharePathTakenMessage.localizedString())
        }
        if apiError.isQuota {
            return showMessage(
                title: R.Strings.shareQuotaTitle.localizedString(),
                message: R.Strings.shareQuotaMessage.localizedString())
        }
        showMessage(
            title: R.Strings.commonError.localizedString(),
            message: environment.stolnk.lastError
                ?? apiError.localizedDescription)
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .default))
        present(alert, animated: true)
    }
}
