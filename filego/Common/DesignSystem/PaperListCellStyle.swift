import UIKit

/// `insetGrouped` 列表的行样式。
///
/// collection view 的列表（配合 `PaperInsetGroupedLayout`）：行自己**透明**，白卡由整段
/// 共用的凸起 decoration 来画，行只在按下/选中时铺一层 paper-2。
///
/// table view 的列表没法挂 decoration，退回扁平白卡 + 发丝描边。
///
/// 都基于 `defaultBackgroundConfiguration()` 改，而不是从零构造——那份默认配置里带着
/// 「按段首尾自动圆角」和高亮/选中态的处理，自己写一份必然漏掉其中之一。
@MainActor
enum PaperListCellStyle {
    /// 系统默认的 disclosure 是 tertiaryLabel 的冷灰，压在纸色底上发蓝。
    static let disclosure = UICellAccessory.disclosureIndicator(
        options: .init(tintColor: AppColor.muted)
    )

    static func apply(to cell: UICollectionViewListCell) {
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
            background.backgroundColor = state.isHighlighted || state.isSelected
                ? AppColor.paper2.withAlphaComponent(0.8)
                : .clear
            background.cornerRadius = AppRadius.card
            cell.backgroundConfiguration = background
        }
        cell.setNeedsUpdateConfiguration()
    }

    static func apply(to cell: UITableViewCell) {
        var background = cell.defaultBackgroundConfiguration()
        background.backgroundColor = AppColor.surface
        background.cornerRadius = AppRadius.card
        background.strokeColor = AppColor.line.withAlphaComponent(0.7)
        background.strokeWidth = 0.5
        cell.backgroundConfiguration = background
    }
}

extension UIListContentConfiguration {
    /// 把系统默认的 label / secondaryLabel 换成 token 色。
    ///
    /// 锁浅色后 `.label` 是纯黑 `#000`，压在纸色底上比 `--ink` 硬得多，逐处替换。
    mutating func applyPaperColors() {
        textProperties.color = AppColor.textPrimary
        secondaryTextProperties.color = AppColor.textSecondary
    }
}

extension UICollectionLayoutListConfiguration {
    /// `insetGrouped` 列表的公共设置：透明底（底色交给 view）+ token 分隔线。
    static func paperInsetGrouped() -> UICollectionLayoutListConfiguration {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = .clear
        configuration.separatorConfiguration.color = AppColor.paper2
        return configuration
    }
}
