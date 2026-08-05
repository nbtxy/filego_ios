import UIKit

final class DriveNodeCell: UICollectionViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let starView = UIImageView(image: UIImage(systemName: "star.fill"))
    private let moreButton = UIButton(type: .system)
    private let textStack = UIStackView()
    private var listConstraints: [NSLayoutConstraint] = []
    private var gridConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        iconView.contentMode = .center
        iconView.tintColor = AppColor.textSecondary
        iconView.backgroundColor = UIColor.secondarySystemBackground
        iconView.layer.cornerRadius = 6
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = AppColor.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.adjustsFontForContentSizeCategory = true

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = AppColor.textSecondary
        detailLabel.adjustsFontForContentSizeCategory = true

        starView.tintColor = .systemYellow
        starView.contentMode = .scaleAspectFit
        starView.setContentHuggingPriority(.required, for: .horizontal)
        starView.translatesAutoresizingMaskIntoConstraints = false

        moreButton.setImage(
            UIImage(
                systemName: "ellipsis",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            ),
            for: .normal
        )
        moreButton.tintColor = AppColor.textSecondary
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = UIStackView(arrangedSubviews: [nameLabel, starView])
        titleStack.axis = .horizontal
        titleStack.spacing = AppSpacing.extraSmall
        titleStack.alignment = .center

        textStack.addArrangedSubview(titleStack)
        textStack.addArrangedSubview(detailLabel)
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(textStack)
        contentView.addSubview(moreButton)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            starView.widthAnchor.constraint(equalToConstant: 13),
            starView.heightAnchor.constraint(equalToConstant: 13),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        listConstraints = [
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: AppSpacing.medium),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ]
        gridConstraints = [
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            moreButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ]
        NSLayoutConstraint.activate(listConstraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        moreButton.menu = nil
    }

    // TODO: [star] 排查用，定位后删除。用来看 configure 设完之后，
    // 到真正布局时 isHidden / alpha 有没有被别人改回去。
    private var debugNodeID = ""
    private var debugWantsStar = false

    /// 供 applySnapshot 完成回调枚举 visibleCells 时读取真实上屏状态。
    var debugStarState: String {
        let id = debugNodeID.isEmpty ? "?" : String(debugNodeID.prefix(6))
        let flag = starView.isHidden == debugWantsStar ? "⚠️" : ""
        return "\(id)want=\(debugWantsStar ? 1 : 0)hidden=\(starView.isHidden ? 1 : 0)"
            + "a=\(starView.alpha)w=\(Int(starView.frame.width))"
            + "c=\(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10000)\(flag)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !debugNodeID.isEmpty else { return }
        let mismatch = starView.isHidden == debugWantsStar
        AppLogger.info(
            "[star] layoutSubviews id=\(debugNodeID) wantStar=\(debugWantsStar)"
            + " isHidden=\(starView.isHidden) alpha=\(starView.alpha)"
            + " frame=\(NSCoder.string(for: starView.frame))"
            + " stackHidden=\(starView.superview?.isHidden ?? false)"
            + (mismatch ? " ⚠️不一致" : "")
        )
    }

    /// `detailOverride` 用于回收站：副标题换成「还有 N 天自动删除」，比文件尺寸更有用。
    func configure(with node: DriveNode, menu: UIMenu, grid: Bool, detailOverride: String? = nil) {
        iconView.image = UIImage(
            systemName: symbol(for: node),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        iconView.tintColor = node.isFolder ? AppColor.accent : AppColor.textSecondary
        nameLabel.text = node.name
        starView.isHidden = !node.starred
        // TODO: [star] 排查用，定位后删除
        debugNodeID = node.id
        debugWantsStar = node.starred
        AppLogger.info(
            "[star] cell.configure id=\(node.id) name=\(node.name) starred=\(node.starred)"
            + " → isHidden=\(starView.isHidden) cell=\(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10000)"
            + " window=\(window != nil)"
        )
        if let detailOverride {
            detailLabel.text = detailOverride
        } else if node.isFolder {
            detailLabel.text = R.Strings.driveFolder.localizedString()
        } else {
            let size = ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)
            let ext = URL(fileURLWithPath: node.name).pathExtension.uppercased()
            detailLabel.text = ext.isEmpty ? size : "\(ext) · \(size)"
        }
        moreButton.menu = menu

        NSLayoutConstraint.deactivate(grid ? listConstraints : gridConstraints)
        NSLayoutConstraint.activate(grid ? gridConstraints : listConstraints)
        contentView.backgroundColor = grid ? UIColor.secondarySystemBackground : .clear
        contentView.layer.cornerRadius = grid ? 12 : 0
        contentView.layer.cornerCurve = .continuous
        nameLabel.numberOfLines = grid ? 2 : 1
    }

    private func symbol(for node: DriveNode) -> String {
        FileKind(node: node).symbolName
    }
}
