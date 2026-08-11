import UIKit

/// 读取 `Resources/MarkdownViewer/` 下内置的离线渲染资源，并装配成完整的 HTML 页面。
enum MarkdownViewerAssets {
    enum Failure: Error, LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            R.Strings.previewMarkdownAssetsMissing.localizedString()
        }
    }

    /// 页面里允许加载的图片来源。
    enum ImagePolicy {
        /// 只允许内联 data: 图。md 里的远程图会向第三方暴露读者 IP 与阅读时间，默认不加载。
        case localOnly
        /// 用户在菜单里显式放行后才允许 https 远程图。
        case allowRemote

        var cspImageSources: String {
            switch self {
            case .localOnly: return "data:"
            case .allowRemote: return "data: https:"
            }
        }
    }

    // MARK: - 资源读取

    /// Xcode 16 的 file-system-synchronized group 把资源加进 Resources build phase 时，
    /// 不保证保留 `MarkdownViewer/` 这层子目录。两种落法都试一遍，文件名统一 `mdviewer-`
    /// 前缀以规避扁平化后的重名冲突。
    static func string(named name: String, extension ext: String) throws -> String {
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "MarkdownViewer")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            let resource = "\(name).\(ext)"
            assertionFailure("缺少内置资源 \(resource)，检查是否已加入 target 的 Resources build phase")
            throw Failure.missingResource(resource)
        }
        return contents
    }

    /// 需要注入到隔离世界的三份第三方库 + 一份 bootstrap，按依赖顺序排列。
    static func userScriptSources() throws -> [String] {
        try [
            string(named: "mdviewer-marked.min", extension: "js"),
            string(named: "mdviewer-purify.min", extension: "js"),
            string(named: "mdviewer-highlight.min", extension: "js"),
            string(named: "mdviewer-bootstrap", extension: "js")
        ]
    }

    // MARK: - 页面装配

    /// 把 shell 模板与三份 CSS 拼成完整 HTML。
    ///
    /// 注意这里只装配「壳」，**不含 markdown 正文**——正文通过
    /// `callAsyncJavaScript(arguments:)` 参数化传入，绝不做字符串插值。
    static func html(imagePolicy: ImagePolicy, traitCollection: UITraitCollection) throws -> String {
        let styles = try [
            string(named: "mdviewer-github-markdown", extension: "css"),
            string(named: "mdviewer-highlight", extension: "css"),
            string(named: "mdviewer-app", extension: "css")
        ].joined(separator: "\n")

        let bodyPointSize = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: traitCollection
        ).pointSize

        return try string(named: "mdviewer-shell", extension: "html")
            .replacingOccurrences(of: "__STYLES__", with: styles)
            .replacingOccurrences(of: "__IMG_SRC__", with: imagePolicy.cspImageSources)
            .replacingOccurrences(of: "__ACCENT_LIGHT__", with: accentHex(userInterfaceStyle: .light))
            .replacingOccurrences(of: "__ACCENT_DARK__", with: accentHex(userInterfaceStyle: .dark))
            .replacingOccurrences(of: "__BASE_FONT_PX__", with: String(format: "%.1f", bodyPointSize))
    }

    /// WebView 自身会跟随系统亮暗切换 `prefers-color-scheme`，CSS 主题不需要 Swift 干预；
    /// 唯独链接色要从 `AppColor` 取，所以两种外观各解析一次。
    ///
    /// 取的是 `link` 而不是 `accent`：正文里的链接用墨绿会和普通文字混在一起，
    /// 网页版的 `md-viewer.client.css` 同样把 `--fgColor-accent` 指到了蓝色。
    private static func accentHex(userInterfaceStyle: UIUserInterfaceStyle) -> String {
        let resolved = AppColor.link.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: userInterfaceStyle)
        )
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
