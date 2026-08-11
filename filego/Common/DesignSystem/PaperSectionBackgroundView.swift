import UIKit

/// 列表段背景。对齐网页 `.rows`：白底、圆角 20、1px `--line` 描边，
/// 行与行之间的发丝线由 cell 自己画。
///
/// 通过 `NSCollectionLayoutDecorationItem` 挂在 section 上，所以它不占用 cell、
/// 也不会被 diffable 的增删动画牵连。
@MainActor
final class PaperSectionBackgroundView: UICollectionReusableView {
    static let elementKind = "PaperSectionBackground"

    /// 白卡相对 section 左右各内缩多少。
    ///
    /// **cell 必须引用这个值来算自己的内边距**，不能各写各的 16——cell 的 contentView
    /// 铺满整个 collection 宽度，它的「16」量的是屏幕边，白卡的「16」量的也是屏幕边，
    /// 两个 16 一撞，行内容就正好压在卡的描边上（这个 bug 真出过一次）。
    static let horizontalInset: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppColor.surface
        layer.cornerRadius = AppRadius.card
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = AppColor.line.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 套着这张白卡的列表布局。
    ///
    /// - Parameter itemCount: 给定 section 当前的条目数。**空段必须不挂 decoration**——
    ///   否则 0 行的段仍会画出一条扁扁的白色药丸浮在空状态上方，
    ///   而网页在没有内容时根本不渲染 `.rows` 这个容器。
    static func makeListLayout(
        itemCount: @escaping @MainActor (Int) -> Int
    ) -> UICollectionViewCompositionalLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        // 行间发丝线由 cell 自己画，才能贴着白卡内缘而不戳出圆角。
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear

        let layout = UICollectionViewCompositionalLayout { index, environment in
            let section = NSCollectionLayoutSection.list(
                using: configuration, layoutEnvironment: environment
            )
            if itemCount(index) > 0 {
                let decoration = NSCollectionLayoutDecorationItem.background(
                    elementKind: Self.elementKind
                )
                decoration.contentInsets = NSDirectionalEdgeInsets(
                    top: 0,
                    leading: Self.horizontalInset,
                    bottom: 0,
                    trailing: Self.horizontalInset
                )
                section.decorationItems = [decoration]
            }
            // 顶上留一口气，否则白卡的上沿会顶在导航栏那条发丝线上。
            section.contentInsets = .init(top: 12, leading: 0, bottom: 16, trailing: 0)
            return section
        }
        layout.register(Self.self, forDecorationViewOfKind: elementKind)
        return layout
    }
}
