import UIKit

enum AppColor {
    /// 与 qingshu_ios `DS.Palette.brandPrimary` 保持一致：#C2410C。
    static let accent = UIColor(named: "AccentColor")
        ?? UIColor(red: 194 / 255, green: 65 / 255, blue: 12 / 255, alpha: 1)
    static let background = UIColor.systemBackground
    static let textPrimary = UIColor.label
    static let textSecondary = UIColor.secondaryLabel
    static let separator = UIColor.separator
}

enum AppSpacing {
    static let extraSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
}

enum AppTypography {
    static let title = UIFont.preferredFont(forTextStyle: .title2)
    static let body = UIFont.preferredFont(forTextStyle: .body)
    static let caption = UIFont.preferredFont(forTextStyle: .caption1)
}
