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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: AppSpacing.medium),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -AppSpacing.medium),
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
                let separator = UIImageView(image: UIImage(systemName: "chevron.right"))
                separator.tintColor = AppColor.textSecondary
                stack.addArrangedSubview(separator)
            }
            let button = UIButton(type: .system)
            button.setTitle(node.name, for: .normal)
            button.titleLabel?.font = AppTypography.caption
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
