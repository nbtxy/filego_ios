import UIKit

/// 共享剪贴板页面：对应 `{name}.stolnk.com/clip`，通过 WebSocket 与网页端实时双向同步文本。
@MainActor
final class ClipboardViewController: UIViewController {
    private let environment: AppEnvironment
    private let clientID = UUID().uuidString

    private let addressCard = UIView()
    private let addressLabel = UILabel()
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let copyAddressButton = UIButton(type: .system)
    private let qrButton = UIButton(type: .system)
    private let shareAddressButton = UIButton(type: .system)

    private let editorCard = UIView()
    private let editorWell = UIView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let countLabel = UILabel()

    private let clearButton = PaperButton.secondary()
    private let copyButton = PaperButton.primary()

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var keepaliveTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var currentVersion = 0
    private var isApplyingRemote = false
    private var isActive = false
    private var foregroundObserver: (any NSObjectProtocol)?
    private var stateObserver: (any NSObjectProtocol)?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.clipTitle.localizedString()
        view.backgroundColor = AppColor.background
        navigationItem.largeTitleDisplayMode = .never
        buildLayout()
        updateAddress()
        updateStatus(connected: false, reconnecting: false)
        updateControls()
        observeLifecycle()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isActive = true
        updateAddress()
        connectSocket()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            isActive = false
            disconnectSocket()
        }
    }

    // MARK: - 布局

    private func buildLayout() {
        AppMaterial.raise(addressCard, radius: AppRadius.card)
        addressCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addressCard)

        addressLabel.font = AppTypography.mono
        addressLabel.textColor = AppColor.textPrimary
        addressLabel.lineBreakMode = .byTruncatingMiddle
        addressLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = AppTypography.rowMeta
        statusLabel.textColor = AppColor.textSecondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(copyAddressButton, symbol: "doc.on.doc", label: R.Strings.driveImportCopyAddress.localizedString()) { [weak self] in
            self?.copyAddress()
        }
        configureIconButton(qrButton, symbol: "qrcode", label: R.Strings.inboxQr.localizedString()) { [weak self] in
            self?.showQRCode()
        }
        configureIconButton(shareAddressButton, symbol: "square.and.arrow.up", label: R.Strings.driveImportShareAddress.localizedString()) { [weak self] in
            self?.shareAddress()
        }

        let iconStack = UIStackView(arrangedSubviews: [copyAddressButton, qrButton, shareAddressButton])
        iconStack.axis = .horizontal
        iconStack.spacing = 4
        iconStack.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusLabel])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 6
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        addressCard.addSubview(addressLabel)
        addressCard.addSubview(statusRow)
        addressCard.addSubview(iconStack)

        AppMaterial.raise(editorCard, radius: AppRadius.card)
        editorCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorCard)

        AppMaterial.inset(editorWell, radius: AppRadius.control)
        editorWell.translatesAutoresizingMaskIntoConstraints = false
        editorCard.addSubview(editorWell)

        textView.delegate = self
        textView.font = AppTypography.body
        textView.textColor = AppColor.textPrimary
        textView.tintColor = AppColor.accent
        textView.backgroundColor = .clear
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.translatesAutoresizingMaskIntoConstraints = false

        let accessory = UIToolbar()
        accessory.sizeToFit()
        accessory.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                title: R.Strings.commonDone.localizedString(),
                style: .done,
                target: self,
                action: #selector(dismissKeyboard)
            )
        ]
        textView.inputAccessoryView = accessory

        placeholderLabel.text = R.Strings.clipPlaceholder.localizedString()
        placeholderLabel.font = AppTypography.body
        placeholderLabel.textColor = AppColor.textSecondary
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = AppTypography.metaSmall
        countLabel.textColor = AppColor.textSecondary
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        editorWell.addSubview(textView)
        editorWell.addSubview(placeholderLabel)
        editorCard.addSubview(countLabel)

        var clearConfig = clearButton.configuration ?? .plain()
        clearConfig.title = R.Strings.clipClear.localizedString()
        clearConfig.image = UIImage(systemName: "trash")
        clearConfig.imagePadding = 6
        clearButton.configuration = clearConfig
        clearButton.addAction(UIAction { [weak self] _ in self?.clearText() }, for: .touchUpInside)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        var copyConfig = copyButton.configuration ?? .plain()
        copyConfig.title = R.Strings.clipCopy.localizedString()
        copyConfig.image = UIImage(systemName: "doc.on.doc")
        copyConfig.imagePadding = 6
        copyConfig.baseForegroundColor = AppColor.white
        copyButton.configuration = copyConfig
        copyButton.addAction(UIAction { [weak self] _ in self?.copyContent() }, for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = UIStackView(arrangedSubviews: [clearButton, copyButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonRow)

        let tapOutside = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapOutside.cancelsTouchesInView = false
        addressCard.addGestureRecognizer(tapOutside)

        NSLayoutConstraint.activate([
            addressCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            addressCard.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            addressCard.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            addressLabel.topAnchor.constraint(equalTo: addressCard.topAnchor, constant: 14),
            addressLabel.leadingAnchor.constraint(equalTo: addressCard.leadingAnchor, constant: 16),
            addressLabel.trailingAnchor.constraint(lessThanOrEqualTo: iconStack.leadingAnchor, constant: -8),

            statusRow.topAnchor.constraint(equalTo: addressLabel.bottomAnchor, constant: 6),
            statusRow.leadingAnchor.constraint(equalTo: addressLabel.leadingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: addressCard.bottomAnchor, constant: -14),

            iconStack.centerYAnchor.constraint(equalTo: addressCard.centerYAnchor),
            iconStack.trailingAnchor.constraint(equalTo: addressCard.trailingAnchor, constant: -10),

            editorCard.topAnchor.constraint(equalTo: addressCard.bottomAnchor, constant: 14),
            editorCard.leadingAnchor.constraint(equalTo: addressCard.leadingAnchor),
            editorCard.trailingAnchor.constraint(equalTo: addressCard.trailingAnchor),
            editorCard.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -16),

            editorWell.topAnchor.constraint(equalTo: editorCard.topAnchor, constant: 14),
            editorWell.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 14),
            editorWell.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: -14),
            editorWell.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -10),

            textView.topAnchor.constraint(equalTo: editorWell.topAnchor),
            textView.leadingAnchor.constraint(equalTo: editorWell.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: editorWell.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: editorWell.bottomAnchor),

            placeholderLabel.topAnchor.constraint(equalTo: editorWell.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: editorWell.leadingAnchor, constant: 15),
            placeholderLabel.trailingAnchor.constraint(equalTo: editorWell.trailingAnchor, constant: -15),

            countLabel.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 16),
            countLabel.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: addressCard.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: addressCard.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -14),
            buttonRow.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func configureIconButton(
        _ button: UIButton,
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        )
        config.baseForegroundColor = AppColor.ink
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        button.configuration = config
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    // MARK: - 状态与交互

    private func updateAddress() {
        let url = environment.stolnk.clipURL
        addressLabel.text = url ?? R.Strings.receivedAddressUnavailable.localizedString()
        let hasURL = url != nil
        copyAddressButton.isEnabled = hasURL
        qrButton.isEnabled = hasURL
        shareAddressButton.isEnabled = hasURL
    }

    private func updateStatus(connected: Bool, reconnecting: Bool) {
        if connected {
            statusDot.backgroundColor = AppColor.FileTile.folderForeground
            statusLabel.text = R.Strings.clipStatusConnected.localizedString()
            statusLabel.textColor = AppColor.FileTile.folderForeground
        } else {
            statusDot.backgroundColor = AppColor.orange
            statusLabel.text = (reconnecting
                ? R.Strings.clipStatusReconnecting
                : R.Strings.clipStatusConnecting).localizedString()
            statusLabel.textColor = AppColor.textSecondary
        }
    }

    private func updateControls() {
        let text = textView.text ?? ""
        placeholderLabel.isHidden = !text.isEmpty
        clearButton.isEnabled = !text.isEmpty
        copyButton.isEnabled = !text.isEmpty
        countLabel.text = R.Strings.clipCharCount.formatted(Int64(text.count))
    }

    private func observeLifecycle() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.reconnectNow()
            }
        }
        stateObserver = NotificationCenter.default.addObserver(
            forName: .stolnkStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAddress() }
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func copyAddress() {
        guard let url = environment.stolnk.clipURL else { return }
        UIPasteboard.general.string = url
        HapticManager.notification(.success)
        PaperToast.show(R.Strings.inboxCopied.localizedString(), in: view)
    }

    private func showQRCode() {
        guard let address = environment.stolnk.clipURL,
              let image = QRCode.image(for: address) else { return }
        present(InboxQRViewController(image: image, address: address), animated: true)
    }

    private func shareAddress() {
        guard let address = environment.stolnk.clipURL, let url = URL(string: address) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = shareAddressButton
        controller.popoverPresentationController?.sourceRect = shareAddressButton.bounds
        present(controller, animated: true)
    }

    private func copyContent() {
        let text = textView.text ?? ""
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        HapticManager.notification(.success)
        PaperToast.show(R.Strings.clipCopied.localizedString(), in: view)
    }

    private func clearText() {
        debounceTask?.cancel()
        textView.text = ""
        updateControls()
        HapticManager.selection()
        sendClipUpdate("")
    }

    // MARK: - WebSocket 实时同步

    private func connectSocket() {
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectSocket(keepActive: true)
        updateStatus(connected: false, reconnecting: reconnectAttempt > 0)

        Task { [weak self] in
            guard let self, self.isActive else { return }
            guard let url = await self.environment.stolnk.clipWebSocketURL() else {
                self.scheduleReconnect()
                return
            }
            guard self.isActive else { return }
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: url)
            self.urlSession = session
            self.webSocketTask = task
            task.resume()
            self.startKeepalive()
            self.receiveNext(on: task)
        }
    }

    private func reconnectNow() {
        reconnectAttempt = 0
        connectSocket()
    }

    private func disconnectSocket(keepActive: Bool = false) {
        if !keepActive {
            reconnectTask?.cancel()
            reconnectTask = nil
            debounceTask?.cancel()
            debounceTask = nil
        }
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let task = self.webSocketTask else { return }
                task.send(.string("ping")) { [weak self] error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in self?.scheduleReconnect() }
                }
            }
        }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.reconnectAttempt = 0
                    self.updateStatus(connected: true, reconnecting: false)
                    if case .string(let text) = message {
                        self.handleIncoming(text)
                    }
                    self.receiveNext(on: task)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleIncoming(_ raw: String) {
        guard raw != "pong",
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "clip.state", let text = json["text"] as? String {
            let version = (json["version"] as? NSNumber)?.intValue ?? 0
            let senderClient = json["client"] as? String
            if senderClient == clientID {
                currentVersion = max(currentVersion, version)
                return
            }
            if version >= currentVersion {
                currentVersion = version
                if textView.text != text {
                    isApplyingRemote = true
                    textView.text = text
                    isApplyingRemote = false
                    updateControls()
                }
            }
        } else if type == "clip.ack", let version = (json["version"] as? NSNumber)?.intValue {
            currentVersion = max(currentVersion, version)
        } else if type == "clip.error", (json["error"] as? String) == "too_large" {
            PaperToast.show(R.Strings.clipTooLarge.localizedString(), in: view, isError: true)
        }
    }

    private func scheduleSendUpdate(_ text: String) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.sendClipUpdate(text)
        }
    }

    private func sendClipUpdate(_ text: String) {
        let payload: [String: Any] = [
            "type": "clip.update",
            "text": text,
            "client": clientID
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let raw = String(data: data, encoding: .utf8),
              let task = webSocketTask else { return }
        task.send(.string(raw)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.scheduleReconnect() }
        }
    }

    private func scheduleReconnect() {
        guard isActive else { return }
        disconnectSocket(keepActive: true)
        updateStatus(connected: false, reconnecting: true)
        let delay = min(pow(2.0, Double(reconnectAttempt)), 15.0)
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connectSocket()
        }
    }
}

extension ClipboardViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingRemote else { return }
        updateControls()
        scheduleSendUpdate(textView.text ?? "")
    }
}
