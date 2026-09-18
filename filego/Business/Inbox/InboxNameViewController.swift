import StolnkCore
import UIKit

/**
 改名字——`ryan.stolnk.com` 里 `ryan` 那一段。

 对应 Mac 端设置里的 Name 区（`SettingsView`）。名字属于**设备**而不属于某一条
 地址，所以入口在「我的地址」列表的顶上，而不是某条 inbox 的详情里；详情里那个
 「重命名」改的是发件人看到的 `display_name`，和这里没有关系。

 单独一屏而不是弹一个输入框：换路径那种 alert 装不下实时的重名提示，而这一步
 又恰好是全 App 唯一一个不可撤销、且会当场弄断已经发出去的链接的操作——它值得
 一屏的篇幅把后果说清楚，也值得在点下去之前再确认一次。
 */
@MainActor
final class InboxNameViewController: UIViewController {
    private let environment: AppEnvironment

    private let currentLabel = UILabel()
    private let nameField = UITextField()
    private let suffixLabel = UILabel()
    private let statusLabel = UILabel()
    private let saveButton = PaperButton.primary()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var probe: NameAvailabilityProbe!
    private var status: NameStatus = .unchanged
    private var isBusy = false
    /// 名字后面那截后缀。换服务器会改掉它，见 `stateDidChange()`。
    private var suffix = ""

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.nameChangeTitle.localizedString()
        view.backgroundColor = AppColor.background
        suffix = environment.stolnk.nameSuffix
        buildProbe()
        buildLayout()
        // 预填当前名字，所以进来第一眼就是 `.unchanged`：按钮是灰的，且绝不会把
        // 用户自己的名字说成「已被占用」。
        nameField.text = environment.stolnk.name
        probe.evaluate(nameField.text ?? "")
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .stolnkStateDidChange, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        probe.cancel()
    }

    private func buildProbe() {
        probe = NameAvailabilityProbe(
            currentName: environment.stolnk.name,
            check: { [environment] candidate in
                await environment.stolnk.isNameAvailable(candidate)
            },
            update: { [weak self] status, _ in
                self?.render(status)
            }
        )
    }

    // MARK: - 布局

    private func buildLayout() {
        currentLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        currentLabel.textColor = AppColor.ink
        currentLabel.numberOfLines = 0
        currentLabel.lineBreakMode = .byCharWrapping

        let currentCaption = UILabel()
        currentCaption.text = R.Strings.nameChangeCurrent.localizedString()
        currentCaption.font = .preferredFont(forTextStyle: .footnote)
        currentCaption.textColor = AppColor.textSecondary

        nameField.placeholder = R.Strings.onboardingNamePlaceholder.localizedString()
        nameField.autocapitalizationType = .none
        nameField.autocorrectionType = .no
        nameField.spellCheckingType = .no
        nameField.textContentType = .username
        nameField.returnKeyType = .done
        nameField.borderStyle = .roundedRect
        nameField.textColor = AppColor.ink
        nameField.clearButtonMode = .whileEditing
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        nameField.delegate = self

        suffixLabel.text = suffix
        suffixLabel.font = .preferredFont(forTextStyle: .body)
        suffixLabel.textColor = AppColor.textSecondary
        suffixLabel.setContentHuggingPriority(.required, for: .horizontal)
        suffixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let addressRow = UIStackView(arrangedSubviews: [nameField, suffixLabel])
        addressRow.axis = .horizontal
        addressRow.spacing = 6
        addressRow.alignment = .center

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = AppColor.textSecondary
        statusLabel.numberOfLines = 0

        saveButton.configuration?.title = R.Strings.nameChangeAction.localizedString()
        saveButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)

        // 常挂着，不等出错才说：旧链接会当场断掉这件事，用户必须在动手之前就看见。
        let warning = UILabel()
        warning.text = R.Strings.nameChangeWarning.localizedString()
        warning.font = .preferredFont(forTextStyle: .footnote)
        warning.textColor = AppColor.textSecondary
        warning.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [
            currentCaption, currentLabel, addressRow, statusLabel, saveButton, warning,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(4, after: currentCaption)
        stack.setCustomSpacing(28, after: currentLabel)
        stack.setCustomSpacing(6, after: addressRow)
        stack.setCustomSpacing(24, after: saveButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            saveButton.heightAnchor.constraint(equalToConstant: 48),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
        ])

        renderCurrent()
    }

    /**
     换服务器之后把这一屏对齐到新服务端。

     后缀是这屏唯一显示出来的服务器信息，不跟着换的话，用户会照着 `.stolnk.com`
     的字样去改一个其实发往 localhost 的名字。改名本身也会走到这里——那时要把
     `currentName` 重新对齐，否则「和现在一样」这个判断会一直卡在旧名字上。
     */
    @objc private func stateDidChange() {
        let currentSuffix = environment.stolnk.nameSuffix
        let currentName = environment.stolnk.name
        guard currentSuffix != suffix || currentName != probe.currentName else { return }
        suffix = currentSuffix
        suffixLabel.text = currentSuffix
        probe.currentName = currentName
        renderCurrent()
        probe.evaluate(nameField.text ?? "")
    }

    private func renderCurrent() {
        currentLabel.text = environment.stolnk.name.map { $0 + suffix } ?? "—"
    }

    // MARK: - 名字可用性

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
        case .unchanged:
            statusLabel.text = R.Strings.nameChangeUnchanged.localizedString()
            statusLabel.textColor = AppColor.textSecondary
        // 空的时候没什么可说；问不出来就什么都不说——绝不要把「问不出来」渲染成
        // 「已被占用」。
        case .empty, .unknown:
            statusLabel.text = nil
        }
        updateState()
    }

    private func updateState() {
        saveButton.isEnabled = !isBusy && !status.blocksSubmission
        saveButton.alpha = saveButton.isEnabled ? 1 : 0.4
    }

    // MARK: - 提交

    @objc private func confirm() {
        guard !status.blocksSubmission, !isBusy else { return }
        let candidate = NameRules.normalise(nameField.text ?? "")
        guard !candidate.isEmpty else { return }
        nameField.resignFirstResponder()

        let alert = UIAlertController(
            title: R.Strings.nameChangeConfirmTitle.formatted(candidate + suffix),
            message: R.Strings.nameChangeConfirmMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(), style: .cancel))
        alert.addAction(UIAlertAction(
            title: R.Strings.nameChangeConfirmAction.localizedString(), style: .destructive
        ) { [weak self] _ in
            self?.submit(candidate)
        })
        present(alert, animated: true)
    }

    private func submit(_ candidate: String) {
        setBusy(true)
        Task {
            do {
                try await environment.stolnk.rename(to: candidate)
                setBusy(false)
                HapticManager.notification(.success)
                // 提示挂在导航控制器上：这一屏马上就走了，挂在自己身上会跟着一起消失。
                let host = navigationController?.view
                navigationController?.popViewController(animated: true)
                if let host {
                    PaperToast.show(R.Strings.nameChangeDone.localizedString(), in: host)
                }
            } catch {
                setBusy(false)
                // 不出栈：名字被占了是最常见的失败，用户就在这一屏接着改。
                let alert = UIAlertController(
                    title: R.Strings.nameChangeFailed.localizedString(),
                    message: environment.stolnk.lastError
                        ?? error.localizedDescription,
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(
                    title: R.Strings.commonOk.localizedString(), style: .cancel))
                present(alert, animated: true)
                // 服务端刚给过一个判决，把它反映到输入框上。
                probe.evaluate(nameField.text ?? "")
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        nameField.isEnabled = !busy
        updateState()
    }
}

extension InboxNameViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        if !status.blocksSubmission { confirm() }
        return true
    }
}
