import StolnkCore
import UIKit

/**
 首次运行：取一个名字，拿到收件地址。

 PRD 7.1 —— 注册是一屏一次调用。名字不是随机地址的升级版，它**就是**身份，所以和
 公钥一起上行；重名以 409 失败且什么都不创建，换个名字重试因此是干净的。

 落地目录固定为收件盘根目录。Mac 上这里要选一个磁盘上的文件夹，iOS 没有那个概念
 ——树就在 App 容器里，用户后面可以在树里建子文件夹再把 inbox 挪过去。
 */
@MainActor
final class InboxOnboardingViewController: UIViewController {
    private let environment: AppEnvironment

    private let nameField = UITextField()
    private let suffixLabel = UILabel()
    private let statusLabel = UILabel()
    private let createButton = PaperButton.primary()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var probe: Task<Void, Never>?
    private var isAvailable = false

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        buildLayout()
        updateState()
    }

    private func buildLayout() {
        let mark = BrandMarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false

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
        nameField.borderStyle = .roundedRect
        nameField.textColor = AppColor.ink
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        nameField.delegate = self

        suffixLabel.text = environment.stolnk.nameSuffix
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

        createButton.configuration?.title = R.Strings.onboardingCreate.localizedString()
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
        view.addSubview(stack)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            mark.heightAnchor.constraint(equalToConstant: 56),
            createButton.heightAnchor.constraint(equalToConstant: 48),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
        ])
    }

    // MARK: - 名字可用性

    @objc private func nameChanged() {
        probe?.cancel()
        isAvailable = false
        let raw = nameField.text ?? ""
        let candidate = NameRules.normalise(raw)

        if candidate.isEmpty {
            statusLabel.text = nil
            updateState()
            return
        }
        if NameRules.problem(with: candidate) != nil {
            statusLabel.text = R.Strings.onboardingInvalid.localizedString()
            statusLabel.textColor = AppColor.textSecondary
            updateState()
            return
        }

        statusLabel.text = R.Strings.onboardingChecking.localizedString()
        statusLabel.textColor = AppColor.textSecondary
        updateState()

        // 防抖：每敲一个字母打一次服务端，既费又会让结果乱序回来。
        probe = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            let answer = await self.environment.stolnk.isNameAvailable(candidate)
            guard !Task.isCancelled else { return }
            // 问不到就什么都不说——绝不要把「问不出来」渲染成「已被占用」。
            guard let answer else {
                self.statusLabel.text = nil
                self.updateState()
                return
            }
            self.isAvailable = answer
            self.statusLabel.text = answer
                ? R.Strings.onboardingAvailable.localizedString()
                : R.Strings.onboardingTaken.localizedString()
            self.statusLabel.textColor = answer ? AppColor.ink : AppColor.danger
            self.updateState()
        }
    }

    private func updateState() {
        createButton.isEnabled = isAvailable
        createButton.alpha = isAvailable ? 1 : 0.4
    }

    // MARK: - 注册

    @objc private func create() {
        let candidate = NameRules.normalise(nameField.text ?? "")
        guard !candidate.isEmpty else { return }
        nameField.resignFirstResponder()
        setBusy(true)
        Task {
            let ok = await environment.stolnk.register(
                name: candidate,
                slug: PathRules.normalise("inbox"),
                folder: environment.drive.root
            )
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
        createButton.isEnabled = !busy && isAvailable
        createButton.alpha = createButton.isEnabled ? 1 : 0.4
    }
}

extension InboxOnboardingViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        if isAvailable { create() }
        return true
    }
}
