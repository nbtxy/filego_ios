import UIKit

/// 设计 token。
///
/// 逐字对齐网页版的 `src/web/app.client.css` 的 `:root`——两端是同一个产品，
/// 改动任何一个值都要两边一起改，否则从网页点进 App 会看出两种气质。
///
/// **刻意【不做深色模式】**：网页那套是固定的纸色底，App 跟着锁浅色
/// （见 `AppInfo.plist` 的 `UIUserInterfaceStyle` 与 `SceneDelegate`）。
/// 所以这里全部是写死的浅色字面量，没有 dynamic provider——真要做深色时，
/// 改动点集中在这一个文件里。
enum AppColor {
    // MARK: 网页 token 原样搬运

    /// `--paper`：页面底色。
    static let paper = UIColor(hex: 0xF5F2E9)
    /// `--paper-2`：进度条轨道、缩略图位、行分隔这类「比底色再深一层」。
    static let paper2 = UIColor(hex: 0xEBE7DC)
    /// `--ink`：正文与主按钮底色。
    static let ink = UIColor(hex: 0x14201B)
    /// `--muted`：次要文字。
    static let muted = UIColor(hex: 0x667069)
    /// `--line`：1px 描边与发丝线。
    static let line = UIColor(hex: 0xD8D5CB)
    /// `--lime`：点缀色。进度条、徽章、深色底上的图标。
    static let lime = UIColor(hex: 0xB9F44C)
    /// `--lime-2`：浅一档的点缀，用于选中态底色与文件夹图标底。
    static let lime2 = UIColor(hex: 0xDDFF9C)
    /// `--purple`：文档类文件图标。
    static let purple = UIColor(hex: 0x7657E8)
    /// `--orange`：图片类文件图标；容量告警。
    static let orange = UIColor(hex: 0xFF8359)
    /// `--blue`：音视频类文件图标；markdown 链接色。
    static let blue = UIColor(hex: 0x3D7DD8)
    /// `--danger`：破坏性操作。**不要用 `.systemRed`**，那个偏亮，和纸色底不搭。
    static let danger = UIColor(hex: 0xC8462F)
    static let white = UIColor.white
    /// `.star.on`：点亮的星标。
    static let star = UIColor(hex: 0xE5A300)

    // MARK: 语义别名
    //
    // 这几个名字全项目有 60+ 处引用，只换值不换名。

    static let background = paper
    /// 卡片、行容器的底色。
    static let surface = white
    static let textPrimary = ink
    static let textSecondary = muted
    static let separator = line
    /// 全局 tint。网页的主色就是 ink（`.btn-primary` 是墨绿底白字），
    /// 柠檬绿只做点缀，不能当 tint——它在白底上对比度不够。
    static let accent = ink
    /// 链接色。与网页 `md-viewer.client.css` 的 `--fgColor-accent` 同源。
    static let link = blue

    // MARK: 文件图标分类色
    //
    // 与网页 `app.client.js` 的 `fileClass()` + `.file-icon` 各变体一一对应。

    enum FileTile {
        /// `.file-icon`（默认）：文档与其他。
        static let documentBackground = UIColor(hex: 0xEEEAFE)
        static let documentForeground = AppColor.purple
        /// `.file-icon.photo`
        static let photoBackground = UIColor(hex: 0xFFF0EA)
        static let photoForeground = AppColor.orange
        /// `.file-icon.media`
        static let mediaBackground = UIColor(hex: 0xE7F1FF)
        static let mediaForeground = AppColor.blue
        /// `.file-icon.folder`
        static let folderBackground = AppColor.lime2
        static let folderForeground = UIColor(hex: 0x4D6B1C)
    }
}

enum AppSpacing {
    static let extraSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
}

/// 圆角。网页只有这么几档，不要就地临时写数字。
enum AppRadius {
    /// `.btn` / `.input` / `.nav-item`
    static let control: CGFloat = 12
    /// `.card-thumb` / `.picker`
    static let tile: CGFloat = 14
    /// `--radius`：卡片与行容器。
    static let card: CGFloat = 20
    /// `.modal`
    static let sheet: CGFloat = 26
    /// `border-radius: 999px`
    static let capsule: CGFloat = 999

    /// 文件图标块：46pt 用 13，38pt 用 11（`.file-icon` / `.file-icon.sm`）。
    static let fileTile: CGFloat = 13
    static let fileTileSmall: CGFloat = 11
}

/// 阴影。网页只有两档，都是墨绿的低透明度长投影，不是黑色。
enum AppShadow {
    /// `--shadow-sm`：`0 8px 22px rgba(20,32,27,.08)`
    static func small(_ view: UIView) {
        apply(to: view, offsetY: 8, radius: 22, opacity: 0.08)
    }

    /// `--shadow`：`0 30px 80px rgba(20,32,27,.12)`
    static func large(_ view: UIView) {
        apply(to: view, offsetY: 30, radius: 80, opacity: 0.12)
    }

    /// `.btn-primary`：`0 10px 24px rgba(20,32,27,.16)`
    static func raisedButton(_ view: UIView) {
        apply(to: view, offsetY: 10, radius: 24, opacity: 0.16)
    }

    private static func apply(to view: UIView, offsetY: CGFloat, radius: CGFloat, opacity: Float) {
        view.layer.shadowColor = AppColor.ink.cgColor
        view.layer.shadowOffset = CGSize(width: 0, height: offsetY)
        view.layer.shadowRadius = radius / 2  // CSS 的 blur 半径约等于 2 倍 shadowRadius
        view.layer.shadowOpacity = opacity
    }
}

/// 字体。
///
/// 网页用的是 `font-weight: 650~790` 这类可变字重，UIKit 只能取到最近的一档：
/// 650~700 → `.semibold`，760~780 → `.bold`，790 及以上 → `.heavy`。
///
/// 标题的 `letter-spacing: -.03em ~ -.07em` 在 UIKit 没有直接对应的 `UIFont` 属性，
/// 要靠 `NSAttributedString` 的 `kern`，见 `UILabel.setTightText(_:font:kern:)`。
enum AppTypography {
    // 既有名字，保持不变（全项目在用）。
    static let title = UIFont.preferredFont(forTextStyle: .title2)
    static let body = UIFont.preferredFont(forTextStyle: .body)
    static let caption = UIFont.preferredFont(forTextStyle: .caption1)

    /// `.content-head h1`：30px / 780 / -.05em
    static let pageTitle = scaled(30, .heavy, relativeTo: .largeTitle)
    /// `.panel h2`：19px / 750 / -.03em
    static let sectionTitle = scaled(19, .bold, relativeTo: .title3)
    /// `.modal h2`：23px / -.04em
    static let modalTitle = scaled(23, .bold, relativeTo: .title2)
    /// `.empty h3`：20px / -.03em
    static let emptyTitle = scaled(20, .bold, relativeTo: .title3)
    /// `.row-name` / `.card-name`：13px / 700
    static let rowName = scaled(13, .bold, relativeTo: .subheadline)
    /// `.row-sub` / `.card-meta`：11px
    static let rowMeta = scaled(11, .regular, relativeTo: .caption2)
    /// `.row-cell` / `.storage-head`：12px
    static let metaSmall = scaled(12, .regular, relativeTo: .caption1)
    /// `.btn`：14px / 680
    static let button = scaled(14, .semibold, relativeTo: .subheadline)
    /// `.badge`：11px / 750
    static let badge = scaled(11, .bold, relativeTo: .caption2)
    /// `.crumbs button`：13px / 700
    static let crumb = scaled(13, .bold, relativeTo: .subheadline)
    /// `.mono`：等宽，用于用户 ID、导入地址这类要逐字核对的内容。
    static let mono = UIFontMetrics(forTextStyle: .footnote).scaledFont(
        for: .monospacedSystemFont(ofSize: 13, weight: .regular)
    )

    /// 标题类字距。网页是相对字号的 em，这里按 pointSize 折算。
    static func tightKern(for font: UIFont, em: CGFloat = -0.04) -> CGFloat {
        font.pointSize * em
    }

    private static func scaled(
        _ size: CGFloat,
        _ weight: UIFont.Weight,
        relativeTo style: UIFont.TextStyle
    ) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: size, weight: weight)
        )
    }
}

extension UILabel {
    /// 带负字距地设置文案。纯 `text` 没法表达 `letter-spacing`，只能走富文本。
    ///
    /// 注意每次改文案都要重新调用——`attributedText` 一旦被赋值，后面再设 `text`
    /// 会把 kern 丢掉。
    func setTightText(_ value: String?, font: UIFont, kernEm: CGFloat = -0.04) {
        guard let value else {
            attributedText = nil
            text = nil
            return
        }
        self.font = font
        attributedText = NSAttributedString(
            string: value,
            attributes: [
                .font: font,
                .kern: AppTypography.tightKern(for: font, em: kernEm),
                .foregroundColor: textColor ?? AppColor.textPrimary
            ]
        )
    }
}

extension UIColor {
    /// `UIColor(hex: 0xF5F2E9)`——设计 token 在 CSS 里就是十六进制，
    /// 拆成 0~1 的三个小数只会让两边对不上眼。
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
