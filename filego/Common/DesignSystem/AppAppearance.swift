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
        standard.shadowColor = AppColor.line
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
        UIProgressView.appearance().trackTintColor = AppColor.paper2
        UIActivityIndicatorView.appearance().color = AppColor.muted
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
