import UIKit

/// `insetGrouped` 列表的白卡样式。对齐网页 `.panel`：白底、圆角 20、1px `--line` 描边。
///
/// 基于 `defaultBackgroundConfiguration()` 改，而不是从零构造——那份默认配置里带着
/// 「按段首尾自动圆角」和高亮/选中态的处理，自己写一份必然漏掉其中之一。
@MainActor
enum PaperListCellStyle {
    /// 系统默认的 disclosure 是 tertiaryLabel 的冷灰，压在纸色底上发蓝。
    static let disclosure = UICellAccessory.disclosureIndicator(
        options: .init(tintColor: AppColor.muted)
    )

    static func apply(to cell: UICollectionViewListCell) {
        var background = cell.defaultBackgroundConfiguration()
        background.backgroundColor = AppColor.surface
        background.cornerRadius = AppRadius.card
        background.strokeColor = AppColor.line
        background.strokeWidth = 1
        cell.backgroundConfiguration = background
    }

    static func apply(to cell: UITableViewCell) {
        var background = cell.defaultBackgroundConfiguration()
        background.backgroundColor = AppColor.surface
        background.cornerRadius = AppRadius.card
        background.strokeColor = AppColor.line
        background.strokeWidth = 1
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
