import StolnkCore
import UIKit

/**
 首次运行：取一个名字。

 PRD 7.1 —— 注册是一屏一次调用。名字不是随机地址的升级版，它**就是**身份，所以和
 公钥一起上行；重名以 409 失败且什么都不创建，换个名字重试因此是干净的。

 这一屏只确定名字，**不产生路径**：注册成功后服务端会建好这台设备唯一的根 inbox，
 文件夹固定是 `Documents/Received`。非会员的自选名字 7 天后会失效、原名字释放，所以
 创建按钮下方把这条规则说清楚。
 */
@MainActor
final class InboxOnboardingViewController: UIViewController {
    private let environment: AppEnvironment

    private let nameField = PaperTextField()
    private let suffixLabel = UILabel()
    private let statusLabel = UILabel()
    private let createButton = PaperButton.primary(
        title: R.Strings.onboardingCreate.localizedString())
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// 内容比一屏高时（横屏、Duo 的宽屏、超大字号）要能滚动，不能把顶部裁掉。
    private let scrollView = UIScrollView()

    private var probe: NameAvailabilityProbe!
    private var status: NameStatus = .empty
    /// 名字后面那截后缀。换服务器会改掉它，见 `stateDidChange()`。
    private var suffix = ""

    #if DEBUG
    private let debugButton = UIButton(type: .system)
    #endif

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        suffix = environment.stolnk.nameSuffix
        buildProbe()
        buildLayout()
        updateState()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .stolnkStateDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    /// 横屏或 Duo 的矮窗口里键盘会盖住名字输入框，给滚动区让出键盘的高度。
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        scrollView.contentInset.bottom = overlap
        scrollView.verticalScrollIndicatorInsets.bottom = overlap
    }

    /**
     换服务器之后把这一屏对齐到新服务端。

     后缀是这屏唯一显示出来的服务器信息，不跟着换的话，用户会照着
     `.stolnk.com` 的字样去注册一个其实发往 localhost 的名字。顺带重查一次
     重名：刚才那个「可用」是旧服务端的答案，对新服务端不作数。
     */
    @objc private func stateDidChange() {
        let current = environment.stolnk.nameSuffix
        guard current != suffix else { return }
        suffix = current
        suffixLabel.text = current
        nameChanged()
    }

    private func buildLayout() {
        // 56 是这枚标在首屏的实际边长，交给它自己去定，而不是外面钉一个高度
        // 约束去拉——那正是它被摊成一条黑杠的起点。
        let mark = BrandMarkView(side: 56)

        let title = UILabel()
        title.text = R.Strings.onboardingTitle.localizedString()
        title.font = .preferredFont(forTextStyle: .title1)
        title.textColor = AppColor.ink
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = R.Strings.onboardingSubtitle.localizedString()
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = AppColor.textSecondary
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        nameField.placeholder = R.Strings.onboardingNamePlaceholder.localizedString()
        nameField.autocapitalizationType = .none
        nameField.autocorrectionType = .no
        nameField.spellCheckingType = .no
        nameField.textContentType = .username
        nameField.returnKeyType = .done
        nameField.textColor = AppColor.ink
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        nameField.delegate = self

        suffixLabel.text = suffix
        suffixLabel.font = .preferredFont(forTextStyle: .body)
        suffixLabel.textColor = AppColor.textSecondary
        suffixLabel.setContentHuggingPriority(.required, for: .horizontal)

        let addressRow = UIStackView(arrangedSubviews: [nameField, suffixLabel])
        addressRow.axis = .horizontal
        addressRow.spacing = 6
        addressRow.alignment = .center

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = AppColor.textSecondary
        statusLabel.numberOfLines = 0

        createButton.addTarget(self, action: #selector(create), for: .touchUpInside)

        let note = UILabel()
        note.text = R.Strings.inboxSeparateIdentity.localizedString()
        note.font = .preferredFont(forTextStyle: .caption1)
        note.textColor = AppColor.textSecondary
        note.numberOfLines = 0
        note.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [
            mark, title, subtitle, addressRow, statusLabel, createButton, note,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(28, after: subtitle)
        stack.setCustomSpacing(6, after: addressRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.alwaysBounceVertical = false
        scrollView.keyboardDismissMode = .interactive
        // 已经钉在 safe area 上了，再让系统自动加一次安全区就是双倍留白。
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        content.addSubview(stack)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(spinner)

        #if DEBUG
        // 调试面板在「我的」里，而「我的」要注册完才进得去——正好把开发机上最需要
        // 它的时刻挡在外面：注册**之前**才是要切服务器的时候。所以这里也放一个。
        debugButton.setImage(
            UIImage(
                systemName: "ladybug",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            ),
            for: .normal
        )
        debugButton.tintColor = AppColor.textSecondary
        debugButton.accessibilityLabel = R.Strings.debugPanelTitle.localizedString()
        debugButton.addTarget(self, action: #selector(showDebugPanel), for: .touchUpInside)
        debugButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debugButton)
        #endif

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            // 内容不满一屏时把内容撑满，`centerY` 才有东西可居中；超出一屏时由
            // 内容自身的高度撑开，滚动交给 scrollView。
            content.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            createButton.heightAnchor.constraint(equalToConstant: 48),
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
            spinner.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])

        #if DEBUG
        NSLayoutConstraint.activate([
            debugButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            debugButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            debugButton.widthAnchor.constraint(equalToConstant: 44),
            debugButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        #endif
    }

    #if DEBUG
    /// 这一屏没有导航栏，所以面板只能模态推上来，自带一个关闭按钮。
    @objc private func showDebugPanel() {
        let panel = DebugPanelViewController(environment: environment)
        panel.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        present(UINavigationController(rootViewController: panel), animated: true)
    }
    #endif

    // MARK: - 名字可用性

    /// 这一屏还没有名字可言，所以 `currentName` 是 nil——`.unchanged` 在这里不会出现。
    private func buildProbe() {
        probe = NameAvailabilityProbe(
            check: { [environment] candidate in
                await environment.stolnk.isNameAvailable(candidate)
            },
            update: { [weak self] status, _ in
                self?.render(status)
            }
        )
    }

    @objc private func nameChanged() {
        probe.evaluate(nameField.text ?? "")
    }

    private func render(_ status: NameStatus) {
        self.status = status
        switch status {
        case .checking:
            statusLabel.text = R.Strings.onboardingChecking.localizedString()
            statusLabel.textColor = AppColor.textSecondary
        case .available:
            statusLabel.text = R.Strings.onboardingAvailable.localizedString()
            statusLabel.textColor = AppColor.ink
        case .taken:
            statusLabel.text = R.Strings.onboardingTaken.localizedString()
            statusLabel.textColor = AppColor.danger
        case .invalid:
            statusLabel.text = R.Strings.onboardingInvalid.localizedString()
            statusLabel.textColor = AppColor.textSecondary
        // 问不到就什么都不说——绝不要把「问不出来」渲染成「已被占用」。
        case .empty, .unchanged, .unknown:
            statusLabel.text = nil
        }
        updateState()
    }

    private func updateState() {
        // 禁用态的对比度交给 PaperButton 的 configurationUpdateHandler；
        // 整颗按钮再乘 0.4 会把深色材质和白字一起压没。
        createButton.isEnabled = !status.blocksSubmission
        createButton.alpha = 1
    }

    // MARK: - 注册

    @objc private func create() {
        let candidate = NameRules.normalise(nameField.text ?? "")
        guard !candidate.isEmpty else { return }
        nameField.resignFirstResponder()
        setBusy(true)
        Task {
            let ok = await environment.stolnk.register(name: candidate)
            setBusy(false)
            if !ok {
                let message = environment.stolnk.lastError
                    ?? R.Strings.onboardingFailed.localizedString()
                let alert = UIAlertController(
                    title: R.Strings.onboardingFailed.localizedString(),
                    message: message,
                    preferredStyle: .alert)
                alert.addAction(
                    UIAlertAction(title: R.Strings.commonOk.localizedString(), style: .cancel))
                present(alert, animated: true)
            }
            // 成功不用自己跳转：RootViewController 听 .stolnkRegistrationDidChange 换根。
        }
    }

    private func setBusy(_ busy: Bool) {
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        nameField.isEnabled = !busy
        createButton.isEnabled = !busy && !status.blocksSubmission
        createButton.alpha = 1
    }
}

extension InboxOnboardingViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        if !status.blocksSubmission { create() }
        return true
    }
}
