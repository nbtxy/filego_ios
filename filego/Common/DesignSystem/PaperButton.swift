import UIKit

/// 对齐网页 `.btn` 系列的按钮，外加 iOS 独有的轻拟物材质（`MaterialButton`）。
///
/// 用 `UIButton.Configuration` 而不是自己画：这样 Dynamic Type、高亮态、禁用态
/// 都还是系统那一套，只有配色和圆角是我们的。
@MainActor
enum PaperButton {
    /// `.btn-primary`：墨绿渐变的凸起按钮，白字。
    static func primary(title: String? = nil, image: UIImage? = nil) -> MaterialButton {
        make(title: title, image: image, surface: .ink, foreground: AppColor.white)
    }

    /// `.btn`：白色凸起面，墨绿字。
    static func secondary(title: String? = nil, image: UIImage? = nil) -> MaterialButton {
        make(title: title, image: image, surface: .paper, foreground: AppColor.ink)
    }

    /// `.btn-ghost`：无底无框，也就没有材质。
    static func ghost(title: String? = nil, image: UIImage? = nil) -> MaterialButton {
        make(title: title, image: image, surface: nil, foreground: AppColor.ink)
    }

    /// `.btn-danger`：白色凸起面，但文字是 `--danger`。
    static func danger(title: String? = nil, image: UIImage? = nil) -> MaterialButton {
        make(title: title, image: image, surface: .paper, foreground: AppColor.danger)
    }

    private static func make(
        title: String?,
        image: UIImage?,
        surface: MaterialView.Surface?,
        foreground: UIColor
    ) -> MaterialButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = image
        configuration.imagePadding = AppSpacing.small
        // `.btn`：padding 9px 16px
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 9, leading: 16, bottom: 9, trailing: 16
        )
        // 底色与描边都交给垫在下面的 `MaterialView`，这里必须是透明的，
        // 否则系统那层扁平底会盖在渐变上面。
        configuration.background.backgroundColor = .clear
        configuration.background.strokeColor = .clear
        configuration.baseForegroundColor = foreground
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = AppTypography.button
            return attributes
        }

        let button = MaterialButton(surface: surface)
        button.configuration = configuration
        return button
    }
}
