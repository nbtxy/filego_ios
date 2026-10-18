import UIKit

/// 全局外观。启动时调一次 `install()`。
///
/// 这里只管那些「每个页面各设一遍太蠢」的东西：导航栏、下拉刷新、进度条。
/// 页面自己的底色与卡片仍由各自的 view controller 设置。
enum AppAppearance {
    static func install() {
        installNavigationBar()
        installControls()
    }

    /// 网页的 `.topbar`：纸色底 + 底部一条 `--line` 发丝线。
    ///
    /// 刻意**不用** `configureWithTransparentBackground()`：透明底在滚动时会让内容
    /// 从标题下穿过去，纸色底上没有毛玻璃衬着，文字会糊在一起。
    private static func installNavigationBar() {
        let standard = UINavigationBarAppearance()
        standard.configureWithOpaqueBackground()
        standard.backgroundColor = AppColor.paper
        // 顶栏浮在内容上：用一道柔和的墨绿渐变投影代替硬发丝线。
        standard.shadowColor = nil
        standard.shadowImage = softShadowImage()
        standard.titleTextAttributes = titleAttributes(
            font: .systemFont(ofSize: 17, weight: .bold),
            em: -0.03
        )
        standard.largeTitleTextAttributes = titleAttributes(
            font: .systemFont(ofSize: 30, weight: .heavy),
            em: -0.05
        )

        // 滚到顶时不要那条线——网页的顶栏与内容之间只有滚动后才需要分界。
        let scrollEdge = standard.copy()
        scrollEdge.shadowColor = .clear
        scrollEdge.shadowImage = nil

        let buttonAppearance = UIBarButtonItemAppearance(style: .plain)
        buttonAppearance.normal.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: AppColor.ink
        ]
        standard.buttonAppearance = buttonAppearance
        standard.doneButtonAppearance = buttonAppearance
        scrollEdge.buttonAppearance = buttonAppearance
        scrollEdge.doneButtonAppearance = buttonAppearance

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = standard
        bar.compactAppearance = standard
        bar.scrollEdgeAppearance = scrollEdge
        bar.compactScrollEdgeAppearance = scrollEdge
        bar.tintColor = AppColor.ink
    }

    private static func installControls() {
        UIRefreshControl.appearance().tintColor = AppColor.muted
        // `.storage-bar`：柠檬绿进度 + paper-2 轨道。
        UIProgressView.appearance().progressTintColor = AppColor.lime
        UIProgressView.appearance().trackTintColor = AppColor.well
        UIActivityIndicatorView.appearance().color = AppColor.muted
    }

    /// 1pt 宽、6pt 高的竖向渐变：墨绿 6% → 透明。导航栏会把它横向拉满。
    private static func softShadowImage() -> UIImage {
        let size = CGSize(width: 1, height: 6)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                AppColor.ink.withAlphaComponent(0.06).cgColor,
                AppColor.ink.withAlphaComponent(0).cgColor
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
            ) else { return }
            context.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: []
            )
        }
    }

    private static func titleAttributes(
        font: UIFont,
        em: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: AppColor.ink,
            .kern: AppTypography.tightKern(for: font, em: em)
        ]
    }
}
