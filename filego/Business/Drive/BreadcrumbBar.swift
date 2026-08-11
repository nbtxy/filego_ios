import UIKit

@MainActor
final class BreadcrumbBar: UIScrollView {
    var onSelect: ((DriveNode) -> Void)?
    private let stack = UIStackView()
    private var nodes: [DriveNode] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = AppSpacing.extraSmall
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // 与下面那张白卡对齐：网页里面包屑和 `.rows` 同在 `.content` 里，左沿是同一条。
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: contentLayoutGuide.leadingAnchor,
                constant: PaperSectionBackgroundView.horizontalInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: contentLayoutGuide.trailingAnchor,
                constant: -PaperSectionBackgroundView.horizontalInset
            ),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(nodes: [DriveNode]) {
        self.nodes = nodes
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, node) in nodes.enumerated() {
            if index > 0 {
                // 网页 `.crumbs .sep` 用的是一个 `--line` 色的斜杠，不是 chevron。
                let separator = UILabel()
                separator.text = "/"
                separator.font = AppTypography.crumb
                separator.textColor = AppColor.line
                stack.addArrangedSubview(separator)
            }
            // 用 plain configuration 并把内边距清零：系统按钮默认自带一圈 padding，
            // 不清掉的话首级文字会比白卡的左沿再往左探出一截，两条边就对不齐了。
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            configuration.title = node.name
            configuration.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    attributes.font = AppTypography.crumb
                    return attributes
                }
            // 末级是「当前位置」，用正文色；上级是可点的次要项。
            // 配色走 configuration 而不是 setTitleColor——后者在有 configuration 时不生效。
            let isLast = index == nodes.count - 1
            configuration.baseForegroundColor = isLast
                ? AppColor.textPrimary
                : AppColor.textSecondary
            let button = UIButton(configuration: configuration)
            button.tag = index
            button.addTarget(self, action: #selector(selected(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        layoutIfNeeded()
        if contentSize.width > bounds.width {
            setContentOffset(CGPoint(x: contentSize.width - bounds.width, y: 0), animated: false)
        }
    }

    @objc private func selected(_ sender: UIButton) {
        guard nodes.indices.contains(sender.tag) else { return }
        onSelect?(nodes[sender.tag])
    }
}
