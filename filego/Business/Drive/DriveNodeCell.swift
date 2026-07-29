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

    func configure(with node: DriveNode, menu: UIMenu, grid: Bool) {
        iconView.image = UIImage(
            systemName: symbol(for: node),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        iconView.tintColor = node.isFolder ? AppColor.accent : AppColor.textSecondary
        nameLabel.text = node.name
        starView.isHidden = !node.starred
        if node.isFolder {
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
        guard !node.isFolder else { return "folder.fill" }
        switch URL(fileURLWithPath: node.name).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp3", "m4a", "wav", "aac", "flac": return "music.note"
        case "mp4", "mov", "m4v", "avi", "mkv": return "film"
        case "pdf": return "doc.richtext"
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }
}
