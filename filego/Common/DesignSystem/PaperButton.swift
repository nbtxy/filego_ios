import UIKit

/// 对齐网页 `.btn` 系列的按钮。
///
/// 用 `UIButton.Configuration` 而不是自己画：这样 Dynamic Type、高亮态、禁用态
/// 都还是系统那一套，只有配色和圆角是我们的。
@MainActor
enum PaperButton {
    /// `.btn-primary`：墨绿底白字，带一层长投影。
    static func primary(title: String? = nil, image: UIImage? = nil) -> UIButton {
        let button = make(title: title, image: image)
        var configuration = button.configuration ?? .plain()
        configuration.background.backgroundColor = AppColor.ink
        configuration.background.strokeColor = AppColor.ink
        configuration.baseForegroundColor = AppColor.white
        button.configuration = configuration
        AppShadow.raisedButton(button)
        return button
    }

    /// `.btn`：白底 + `--line` 描边。
    static func secondary(title: String? = nil, image: UIImage? = nil) -> UIButton {
        let button = make(title: title, image: image)
        var configuration = button.configuration ?? .plain()
        configuration.background.backgroundColor = AppColor.white
        configuration.background.strokeColor = AppColor.line
        configuration.baseForegroundColor = AppColor.ink
        button.configuration = configuration
        return button
    }

    /// `.btn-ghost`：无底无框。
    static func ghost(title: String? = nil, image: UIImage? = nil) -> UIButton {
        let button = make(title: title, image: image)
        var configuration = button.configuration ?? .plain()
        configuration.background.backgroundColor = .clear
        configuration.background.strokeColor = .clear
        configuration.baseForegroundColor = AppColor.ink
        button.configuration = configuration
        return button
    }

    /// `.btn-danger`：白底描边，但文字是 `--danger`。
    static func danger(title: String? = nil, image: UIImage? = nil) -> UIButton {
        let button = secondary(title: title, image: image)
        button.configuration?.baseForegroundColor = AppColor.danger
        return button
    }

    private static func make(title: String?, image: UIImage?) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = image
        configuration.imagePadding = AppSpacing.small
        // `.btn`：padding 9px 16px
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 9, leading: 16, bottom: 9, trailing: 16
        )
        configuration.background.cornerRadius = AppRadius.control
        configuration.background.strokeWidth = 1
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = AppTypography.button
            return attributes
        }

        let button = UIButton(configuration: configuration)
        button.layer.cornerCurve = .continuous
        return button
    }
}
