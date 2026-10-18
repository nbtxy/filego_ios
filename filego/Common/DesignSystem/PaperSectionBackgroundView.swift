import UIKit

/// 列表段背景：一张凸起的白卡（`AppMaterial`），圆角 20。对齐网页 `.rows` 的形状，
/// 材质是 iOS 独有的轻拟物层。行与行之间的发丝线由 cell 自己画。
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
        AppMaterial.raise(self, radius: AppRadius.card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 套着这张白卡的列表布局。
    ///
    /// - Parameter itemCount: 给定 section 当前的条目数。**空段必须不挂 decoration**——
    ///   否则 0 行的段仍会画出一条扁扁的白色药丸浮在空状态上方，
    ///   而网页在没有内容时根本不渲染 `.rows` 这个容器。
    /// - Parameter topInset: 白卡上沿离列表顶边多远。列表直接顶着导航栏时要留一口气；
    ///   上面已经垫着别的东西（比如面包屑）时就该收小，否则两段留白叠在一起，卡片显得往下掉。
    static func makeListLayout(
        topInset: CGFloat = 16,
        itemCount: @escaping @MainActor (Int) -> Int
    ) -> UICollectionViewCompositionalLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        // 行间发丝线由 cell 自己画，才能贴着白卡内缘而不戳出圆角。
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear

        // 段与导航栏、段与底边之间的留白。
        let sectionInsets = NSDirectionalEdgeInsets(top: topInset, leading: 0, bottom: 16, trailing: 0)

        let layout = UICollectionViewCompositionalLayout { index, environment in
            let section = NSCollectionLayoutSection.list(
                using: configuration, layoutEnvironment: environment
            )
            if itemCount(index) > 0 {
                let decoration = NSCollectionLayoutDecorationItem.background(
                    elementKind: Self.elementKind
                )
                // background decoration 铺的是整个 section，**包括** contentInsets。
                // 上下不跟着内缩的话，留白就落在白卡里面：卡的上沿照样顶着导航栏，
                // 行的下面还多出一截空白。
                decoration.contentInsets = NSDirectionalEdgeInsets(
                    top: sectionInsets.top,
                    leading: Self.horizontalInset,
                    bottom: sectionInsets.bottom,
                    trailing: Self.horizontalInset
                )
                section.decorationItems = [decoration]
            }
            section.contentInsets = sectionInsets
            return section
        }
        layout.register(Self.self, forDecorationViewOfKind: elementKind)
        return layout
    }
}
