import SafariServices
import UIKit
import WebKit

/// HTML 文件预览。
///
/// QuickLook 预览 HTML 走的是系统的静态沙箱：JavaScript 被禁用、远程资源被拦，
/// 带交互的页面（图表、折叠、表单、单页应用）打开后只剩一个骨架。
/// 这里改用 WKWebView 真实渲染，网络访问则由我们自己的内容拦截规则收口。
final class HtmlPreviewController: UIViewController {
    /// 页面允许触达的资源范围。
    private enum ResourcePolicy {
        /// 只允许 file:／页面自带的 data:、blob:。HTML 是他人上传的不可信内容，
        /// 默认不给任何外联能力——远程请求会暴露读者 IP，也可能被当作回传信道。
        case localOnly
        /// 用户在菜单里显式放行后才允许联网。
        case allowRemote
    }

    private enum Failure: Error, LocalizedError {
        /// 拦截规则编译不出来就没法保证「默认不联网」，此时宁可不渲染也不裸奔。
        case contentBlockerUnavailable

        var errorDescription: String? {
            R.Strings.previewHtmlBlockerUnavailable.localizedString()
        }
    }

    private let file: PreviewTemporaryFile

    private var resourcePolicy: ResourcePolicy = .localOnly
    private var blockRemoteRules: WKContentRuleList?
    /// 文档没声明编码、需要我们代为指定时，连同内容一起留着——`load(data:…)` 要用。
    private var encodingOverride: (data: Data, encoding: String)?

    private var webView: WKWebView?
    /// 自己留一份引用：`webView.configuration` 返回的是配置副本，
    /// 不要绕道那里去装卸拦截规则。
    private let userContentController = WKUserContentController()
    /// 页面成功渲染过一次之后，就不再因为后续导航失败把内容换成错误页。
    private var hasRenderedOnce = false
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    private let fallbackButton = UIButton(type: .system)

    /// 「创建下载链接」。由 `PreviewCoordinator` 注入——这个控制器不认识
    /// `AppEnvironment`，也不该为了一个菜单项去认识它。
    var onCreateShareLink: ((UIViewController) -> Void)?

    init(file: PreviewTemporaryFile, title: String) {
        self.file = file
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        navigationItem.largeTitleDisplayMode = .never
        configureNavigationBar()
        setupStateViews()
        loadDocument()
    }

    /// 页面滚到顶时导航栏全透明（跟 Drive 列表一致）；一旦开始滚动就交回系统默认外观，
    /// 让它自己上背景——HTML 的底色和排版我们控制不了，全程透明会让标题和正文糊在一起。
    private func configureNavigationBar() {
        let atEdge = UINavigationBarAppearance()
        atEdge.configureWithTransparentBackground()
        navigationItem.scrollEdgeAppearance = atEdge
        navigationItem.standardAppearance = nil
    }

    // MARK: - 加载

    private func loadDocument() {
        activityIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            do {
                self.blockRemoteRules = try await Self.compileBlockRemoteRules()
                self.encodingOverride = await Task.detached(priority: .userInitiated) { [file] in
                    Self.encodingOverride(forFileAt: file.url)
                }.value
                self.installWebViewIfNeeded()
                self.reloadPage()
                self.updateMenu()
            } catch {
                AppLogger.error("HTML 预览拦截规则不可用", error: error)
                self.activityIndicator.stopAnimating()
                self.showFallback(message: error.localizedDescription)
            }
        }
    }

    private func installWebViewIfNeeded() {
        guard webView == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 他人上传的页面不该在设备上留下 cookie / localStorage，用完即弃。
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, at: 0)
        // 四边全部贴满 view，让页面能滚到透明导航栏底下。
        // 内容不会一上来就被导航栏盖住：`contentInsetAdjustmentBehavior = .always`
        // 会把安全区转成 scrollView 的 contentInset，起始位置仍在栏下方。
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // 显式指认驱动导航栏 edge 外观的 scrollView。WKWebView 的 scrollView 埋得深，
        // 不指认的话 UIKit 未必认得出来，栏就会一直停在 scrollEdge 那套全透明外观上。
        setContentScrollView(webView.scrollView, for: .top)
        self.webView = webView
    }

    private func reloadPage() {
        guard let webView else { return }

        userContentController.removeAllContentRuleLists()
        if resourcePolicy == .localOnly, let blockRemoteRules {
            userContentController.add(blockRemoteRules)
        }

        hasRenderedOnce = false
        webView.isHidden = false
        errorLabel.isHidden = true
        fallbackButton.isHidden = true
        activityIndicator.startAnimating()
        // 读权限只开到 UUID 临时目录这一层。该目录由 FileDownloadService／FileCacheManager
        // 每次预览新建，里面只有当前这一个文件，页面 JS 用 file:// 也翻不到别人的缓存。
        let directory = file.url.deletingLastPathComponent()
        if let encodingOverride {
            webView.load(
                encodingOverride.data,
                mimeType: "text/html",
                characterEncodingName: encodingOverride.encoding,
                baseURL: directory
            )
        } else {
            webView.loadFileURL(file.url, allowingReadAccessTo: directory)
        }
    }

    // MARK: - 编码

    /// WKWebView 遇到没声明编码的 file:// HTML 会退回 Latin-1，UTF-8 中文直接变乱码。
    /// QuickLook 会自己猜，所以这是换成 WebView 之后才会有的回归，得自己补上。
    ///
    /// 只在文档确实没声明时才接手：按 HTML 规范，API 传入的编码优先级高于 `<meta charset>`，
    /// 对已经声明了 GBK 的文件乱指定 UTF-8 反而会把本来正常的页面搞坏。
    private nonisolated static func encodingOverride(forFileAt url: URL) -> (data: Data, encoding: String)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        // BOM 的优先级最高，WebKit 自己认得，不用我们管。
        let head = Array(data.prefix(3))
        for bom in [[0xEF, 0xBB, 0xBF] as [UInt8], [0xFF, 0xFE], [0xFE, 0xFF]]
        where head.starts(with: bom) {
            return nil
        }

        // 规范只要求解析器在前 1024 字节里嗅探声明，这里跟着同一个范围找就够。
        // 用 Latin-1 解是因为它对任意字节都不会失败，只是拿来做 ASCII 关键字匹配。
        if let prefix = String(data: data.prefix(1024), encoding: .isoLatin1),
           prefix.lowercased().contains("charset") {
            return nil
        }

        if String(data: data, encoding: .utf8) != nil { return (data, "utf-8") }
        // 走到这里说明不是 UTF-8。中文用户手里非 UTF-8 的网页基本都是 GBK 系，
        // GB18030 是 GBK／GB2312 的超集，比继续退回 Latin-1 靠谱得多。
        return (data, "gb18030")
    }

    // MARK: - 内容拦截规则

    private static let blockRemoteRulesIdentifier = "FileGoHtmlPreviewBlockRemote"

    /// 先把所有请求拦掉，再按 scheme 逐条放行本地来源。
    ///
    /// 拆成四条独立的 `ignore-previous-rules` 而不是写成一条正则分支，是为了不依赖
    /// WebKit URL 过滤器对分组／交替的支持程度——规则表编译失败会直接导致整页不渲染。
    private static func compileBlockRemoteRules() async throws -> WKContentRuleList {
        let source = """
        [
          { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
          { "trigger": { "url-filter": "^file:" }, "action": { "type": "ignore-previous-rules" } },
          { "trigger": { "url-filter": "^data:" }, "action": { "type": "ignore-previous-rules" } },
          { "trigger": { "url-filter": "^blob:" }, "action": { "type": "ignore-previous-rules" } },
          { "trigger": { "url-filter": "^about:" }, "action": { "type": "ignore-previous-rules" } }
        ]
        """
        guard let store = WKContentRuleListStore.default() else {
            throw Failure.contentBlockerUnavailable
        }
        guard let list = try await store.compileContentRuleList(
            forIdentifier: blockRemoteRulesIdentifier,
            encodedContentRuleList: source
        ) else {
            throw Failure.contentBlockerUnavailable
        }
        return list
    }

    // MARK: - 菜单

    private func updateMenu() {
        guard webView != nil else {
            navigationItem.rightBarButtonItem = nil
            return
        }

        let remote = UIAction(
            title: R.Strings.previewHtmlLoadRemoteContent.localizedString(),
            image: UIImage(systemName: "network"),
            state: resourcePolicy == .allowRemote ? .on : .off
        ) { [weak self] _ in
            self?.toggleRemoteContent()
        }

        let quickLook = UIAction(
            title: R.Strings.previewHtmlOpenInQuickLook.localizedString(),
            image: UIImage(systemName: "eye")
        ) { [weak self] _ in
            self?.openInQuickLook()
        }

        let share = UIAction(
            title: R.Strings.previewHtmlOpenWith.localizedString(),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.presentShareSheet()
        }

        var children = [remote, quickLook, share]
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

    /// 拦截规则是装在 WebView 上的，改完必须整页重载——已经被挡掉的资源不会自己重试。
    private func toggleRemoteContent() {
        resourcePolicy = resourcePolicy == .localOnly ? .allowRemote : .localOnly
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

        fallbackButton.setTitle(R.Strings.previewHtmlOpenInQuickLook.localizedString(), for: .normal)
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

    /// 规则编译失败、页面加载失败时的统一降级出口。
    private func showFallback(message: String) {
        webView?.isHidden = true
        errorLabel.text = message
        errorLabel.isHidden = false
        fallbackButton.isHidden = false
    }

    @objc private func openInQuickLook() {
        // 复用同一个 PreviewTemporaryFile，临时目录仍由它统一回收。
        navigationController?.pushViewController(FilePreviewController(file: file), animated: true)
    }

    // MARK: - 外链

    /// HTML 来自其他用户上传，锚文本可能与真实地址不符，打开前把完整 URL 摊给用户看。
    private func confirmOpen(_ url: URL) {
        let alert = UIAlertController(
            title: R.Strings.previewHtmlOpenLinkTitle.localizedString(),
            message: url.absoluteString,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.previewHtmlOpenLinkConfirm.localizedString(),
            style: .default
        ) { [weak self] _ in
            self?.present(SFSafariViewController(url: url), animated: true)
        })
        present(alert, animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension HtmlPreviewController: WKNavigationDelegate {
    /// 主文档允许停留的 file:// 路径。
    ///
    /// `loadFileURL` 报的是文件本身，页内锚点跳转（#section）path 不变也落在这里；
    /// 走编码兜底的 `load(data:…)` 则以 baseURL——也就是那个 UUID 目录——作为文档 URL，
    /// 所以两者都要认。目录里只有当前这一个文件，放行它不会多暴露任何东西。
    private var allowedMainFramePaths: Set<String> {
        var paths = [file.url.standardizedFileURL.path]
        if encodingOverride != nil {
            paths.append(file.url.deletingLastPathComponent().standardizedFileURL.path)
        }
        return Set(paths)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasRenderedOnce = true
        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        activityIndicator.stopAnimating()

        // 我们在 decidePolicyFor 里 cancel 掉的外链会以「策略中断」的形式报到这里，不是错误。
        // 102 是 WebKit 的 FrameLoadInterruptedByPolicyChange，现代 WKError 枚举里没有导出，
        // 只能按 domain + code 认。
        let nsError = error as NSError
        let isCancellation = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        if isCancellation { return }

        AppLogger.error("HTML 预览加载失败", error: error)
        // 页面已经渲染出来了就别再整页换成错误提示——失败的多半是页面自己发起的次级导航。
        guard !hasRenderedOnce else { return }
        showFallback(message: error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false

        // 主文档只允许停在我们自己装载的那份内容上，想把整页换成别的文档一律不行。
        if isMainFrame, url.isFileURL, allowedMainFramePaths.contains(url.standardizedFileURL.path) {
            decisionHandler(.allow)
            return
        }

        // 子框架：srcdoc / data: / blob: 是页面自带内容，放行；
        // 远程 iframe 只在用户放行联网后才允许（localOnly 时拦截规则也会挡住）。
        if !isMainFrame {
            if scheme == "about" || scheme == "data" || scheme == "blob" {
                decisionHandler(.allow)
                return
            }
            if resourcePolicy == .allowRemote, scheme == "http" || scheme == "https" {
                decisionHandler(.allow)
                return
            }
        }

        decisionHandler(.cancel)

        guard navigationAction.navigationType == .linkActivated else {
            AppLogger.warning("拦截 HTML 预览的导航：\(scheme)")
            return
        }
        guard scheme == "http" || scheme == "https" else {
            // javascript: / file: / 自定义 scheme 一律拒绝，不给页面作者任何跳转能力。
            AppLogger.warning("拒绝 HTML 预览内的非 http(s) 链接：\(scheme)")
            return
        }
        confirmOpen(url)
    }
}

// MARK: - WKUIDelegate

/// 不实现这些回调的话，页面里的 `alert` / `confirm` / `prompt` 与 `target="_blank"`
/// 会静默失效——这正是「打开后功能不全」最常见的一类表现。
extension HtmlPreviewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // 不开新 WebView，按外链走确认流程。
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            confirmOpen(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: R.Strings.commonOk.localizedString(),
            style: .default
        ) { _ in completionHandler() })
        presentPanel(alert, whenUnavailable: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(
            title: R.Strings.commonOk.localizedString(),
            style: .default
        ) { _ in completionHandler(true) })
        presentPanel(alert) { completionHandler(false) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(
            title: R.Strings.commonOk.localizedString(),
            style: .default
        ) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        presentPanel(alert) { completionHandler(nil) }
    }

    /// WebKit 要求每个面板的 completion 必须且只能回调一次，否则该 frame 的 JS 会永久卡死。
    /// 控制器已离屏或正在展示别的弹窗时不弹，直接兜底回调。
    private func presentPanel(_ alert: UIAlertController, whenUnavailable: @escaping () -> Void) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else {
            whenUnavailable()
            return
        }
        present(alert, animated: true)
    }
}
