import UIKit

/// 空状态。对齐网页 `.empty`：一块 96×96 的 paper-2 圆角图形位（内放 SF Symbol）
/// + 紧字距标题（+ 可选副文案）。
///
/// 用作 `collectionView.backgroundView`，所以要能随时改文案而不重建。
@MainActor
final class PaperEmptyStateView: UIView {
    private let art = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    init(symbol: String = "folder", title: String, body: String? = nil) {
        super.init(frame: .zero)

        let artContainer = UIView()
        artContainer.backgroundColor = AppColor.paper2
        artContainer.layer.cornerRadius = 28
        artContainer.layer.cornerCurve = .continuous
        artContainer.translatesAutoresizingMaskIntoConstraints = false

        art.contentMode = .scaleAspectFit
        art.tintColor = AppColor.muted
        setSymbol(symbol)
        art.translatesAutoresizingMaskIntoConstraints = false
        artContainer.addSubview(art)

        titleLabel.textColor = AppColor.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.setTightText(title, font: AppTypography.emptyTitle, kernEm: -0.03)

        bodyLabel.font = AppTypography.body
        bodyLabel.textColor = AppColor.muted
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        bodyLabel.text = body
        bodyLabel.isHidden = body == nil

        let stack = UIStackView(arrangedSubviews: [artContainer, titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = AppSpacing.small
        stack.setCustomSpacing(20, after: artContainer)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            artContainer.widthAnchor.constraint(equalToConstant: 96),
            artContainer.heightAnchor.constraint(equalToConstant: 96),
            art.centerXAnchor.constraint(equalTo: artContainer.centerXAnchor),
            art.centerYAnchor.constraint(equalTo: artContainer.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: AppSpacing.large),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -AppSpacing.large)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 搜索无结果与目录为空共用一个实例，只换文案。
    func update(symbol: String? = nil, title: String, body: String? = nil) {
        if let symbol { setSymbol(symbol) }
        titleLabel.setTightText(title, font: AppTypography.emptyTitle, kernEm: -0.03)
        bodyLabel.text = body
        bodyLabel.isHidden = body == nil
    }

    private func setSymbol(_ name: String) {
        art.image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        )
    }
}
