import SafariServices
import UIKit
import WebKit

/// Markdown 文件预览。
///
/// iOS QuickLook 没有 markdown 渲染器（`public.markdown` 只 conform 到 `public.plain-text`），
/// 直接预览会显示纯文本源码。这里用 WKWebView + 内置离线 marked/DOMPurify/highlight.js 渲染，
/// 全程不联网。
final class MarkdownPreviewController: UIViewController {
    private enum RenderMode {
        case rendered
        case raw
    }

    private let file: PreviewTemporaryFile
    private let fileName: String

    private var markdown: String?
    private var renderMode: RenderMode = .rendered
    private var imagePolicy: MarkdownViewerAssets.ImagePolicy = .localOnly

    private var webView: WKWebView?
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    private let fallbackButton = UIButton(type: .system)

    /// 「创建下载链接」。由 `PreviewCoordinator` 注入——这个控制器不认识
    /// `AppEnvironment`，也不该为了一个菜单项去认识它。
    var onCreateShareLink: ((UIViewController) -> Void)?

    init(file: PreviewTemporaryFile, title: String) {
        self.file = file
        self.fileName = title
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        navigationItem.largeTitleDisplayMode = .never
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: MarkdownPreviewController, _) in
            // 亮暗切换由 WebView 的 prefers-color-scheme 自动跟随，不用重载；
            // 但正文字号是渲染时按 Dynamic Type 算死的，字号档位变了需要重新装配页面。
            controller.reloadPage()
        }
        setupStateViews()
        loadDocument()
    }

    // MARK: - 加载

    private func loadDocument() {
        activityIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await Task.detached(priority: .userInitiated) { [file] in
                    try MarkdownSource.load(from: file.url)
                }.value
                self.markdown = source
                self.installWebViewIfNeeded()
                self.reloadPage()
                self.updateMenu()
            } catch {
                self.showFallback(message: error.localizedDescription)
            }
            self.activityIndicator.stopAnimating()
        }
    }

    private func installWebViewIfNeeded() {
        guard webView == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true

        do {
            // 渲染库注入到 defaultClient 隔离世界：与页面 JS 全局隔离，且不受页面 CSP 约束。
            // 这样页面 CSP 才能收到 script-src 'none'——任何逃过 DOMPurify 的 <script> 都无法执行。
            for source in try MarkdownViewerAssets.userScriptSources() {
                configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: source,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true,
                        in: .defaultClient
                    )
                )
            }
        } catch {
            AppLogger.error("Markdown 预览资源缺失", error: error)
            showFallback(message: error.localizedDescription)
            return
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, at: 0)
        // 顶部与左右贴安全区：App 的导航栏是 configureWithTransparentBackground（无毛玻璃），
        // 正文若滚到栏下会直接糊在一起看不清。底部仍贴到 view 底，让内容自然滚过 home indicator。
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.webView = webView
    }

    /// 重新装配整页。切换远程图片开关必须走这里——`img-src` 写死在 CSP meta 里，
    /// 光改 JS 标志位不会让已被拦截的图重新可加载。
    private func reloadPage() {
        guard let webView, markdown != nil else { return }
        do {
            let html = try MarkdownViewerAssets.html(
                imagePolicy: imagePolicy,
                traitCollection: traitCollection
            )
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            AppLogger.error("Markdown 页面装配失败", error: error)
            showFallback(message: error.localizedDescription)
        }
    }

    private func renderContents() {
        guard let webView, let markdown else { return }
        Task { @MainActor in
            do {
                // 关键安全点：markdown 正文作为 argument 交给 WebKit 序列化，
                // 绝不插值进 HTML/JS 字符串——天然免疫引号、反斜杠、换行注入。
                _ = try await webView.callAsyncJavaScript(
                    "return window.MdViewer.render(md, remote);",
                    arguments: [
                        "md": markdown,
                        "remote": imagePolicy == .allowRemote
                    ],
                    in: nil,
                    contentWorld: .defaultClient
                )
                if renderMode == .raw {
                    _ = try await webView.callAsyncJavaScript(
                        "return window.MdViewer.setMode('raw');",
                        arguments: [:],
                        in: nil,
                        contentWorld: .defaultClient
                    )
                }
            } catch {
                AppLogger.error("Markdown 渲染失败", error: error)
                showFallback(message: error.localizedDescription)
            }
        }
    }

    // MARK: - 菜单

    private func updateMenu() {
        guard markdown != nil else {
            navigationItem.rightBarButtonItem = nil
            return
        }

        let modeTitle = renderMode == .rendered
            ? R.Strings.previewMarkdownViewSource.localizedString()
            : R.Strings.previewMarkdownViewRendered.localizedString()
        let toggleMode = UIAction(
            title: modeTitle,
            image: UIImage(systemName: renderMode == .rendered ? "chevron.left.forwardslash.chevron.right" : "doc.richtext")
        ) { [weak self] _ in
            self?.toggleRenderMode()
        }

        let images = UIAction(
            title: R.Strings.previewMarkdownLoadRemoteImages.localizedString(),
            image: UIImage(systemName: "photo"),
            state: imagePolicy == .allowRemote ? .on : .off
        ) { [weak self] _ in
            self?.toggleRemoteImages()
        }

        let share = UIAction(
            title: R.Strings.previewMarkdownOpenWith.localizedString(),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.presentShareSheet()
        }

        var children = [toggleMode, images, share]
        if let onCreateShareLink {
            children.append(UIAction(
                title: R.Strings.previewCreateShareLink.localizedString(),
                image: UIImage(systemName: "link")
            ) { [weak self] _ in
                guard let self else { return }
                onCreateShareLink(self)
            })
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: children)
        )
    }

    private func toggleRenderMode() {
        renderMode = renderMode == .rendered ? .raw : .rendered
        updateMenu()
        guard let webView else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "return window.MdViewer.setMode(mode);",
                arguments: ["mode": renderMode == .raw ? "raw" : "rendered"],
                in: nil,
                contentWorld: .defaultClient
            )
        }
    }

    private func toggleRemoteImages() {
        imagePolicy = imagePolicy == .localOnly ? .allowRemote : .localOnly
        updateMenu()
        reloadPage()
    }

    private func presentShareSheet() {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

    // MARK: - 状态视图

    private func setupStateViews() {
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.font = AppTypography.body
        errorLabel.textColor = AppColor.textSecondary
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)

        fallbackButton.setTitle(R.Strings.previewMarkdownOpenInQuickLook.localizedString(), for: .normal)
        fallbackButton.tintColor = AppColor.accent
        fallbackButton.isHidden = true
        fallbackButton.addTarget(self, action: #selector(openInQuickLook), for: .touchUpInside)
        fallbackButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fallbackButton)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: AppSpacing.large
            ),
            errorLabel.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -AppSpacing.large
            ),

            fallbackButton.topAnchor.constraint(
                equalTo: errorLabel.bottomAnchor,
                constant: AppSpacing.medium
            ),
            fallbackButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    /// 解码失败、文件过大、内置资源缺失时的统一降级出口。
    private func showFallback(message: String) {
        markdown = nil
        webView?.isHidden = true
        errorLabel.text = message
        errorLabel.isHidden = false
        fallbackButton.isHidden = false
        updateMenu()
    }

    @objc private func openInQuickLook() {
        // 复用同一个 PreviewTemporaryFile，临时目录仍由它统一回收。
        navigationController?.pushViewController(FilePreviewController(file: file), animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension MarkdownPreviewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        renderContents()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url

        // 只放行 loadHTMLString 自身那一次加载（baseURL 为 nil 时是 about:blank）。
        if navigationAction.navigationType == .other, url?.scheme == "about" || url == nil {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        guard navigationAction.navigationType == .linkActivated, let url else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            // javascript: / file: / 自定义 scheme 一律拒绝，不给 md 作者任何跳转能力。
            AppLogger.warning("拒绝 markdown 内的非 http(s) 链接：\(url.scheme ?? "nil")")
            return
        }
        confirmOpen(url)
    }

    /// md 来自其他用户上传，链接文案可能与真实地址不符，打开前把完整 URL 摊给用户看。
    private func confirmOpen(_ url: URL) {
        let alert = UIAlertController(
            title: R.Strings.previewMarkdownOpenLinkTitle.localizedString(),
            message: url.absoluteString,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.previewMarkdownOpenLinkConfirm.localizedString(),
            style: .default
        ) { [weak self] _ in
            self?.present(SFSafariViewController(url: url), animated: true)
        })
        present(alert, animated: true)
    }
}
