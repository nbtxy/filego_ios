import UIKit

/// 文件/文件夹的条目。一份 cell 兼两种形态：
///   - 列表：对齐网页 `.row`——38pt 图标块 + 名字/副标题 + 星标 + ⋯，行底一条发丝线；
///   - 宫格：对齐网页 `.card`——白卡里一块缩略图位，下面两行名字与 meta。
final class DriveNodeCell: UICollectionViewCell {
    /// 网页 `.row` 的 `padding: 10px 16px` 里的那个 16。
    private static let rowPadding: CGFloat = 16
    private static let moreButtonHitSize: CGFloat = 44
    /// `ellipsis` 这个 SF Symbol 在 15pt 下的实际字形宽度，用来把点击区的余量折回去。
    private static let moreGlyphWidth: CGFloat = 19

    private let listIcon = FileIconTile(size: .small)
    private let gridIcon = FileIconTile(size: .large)
    private let thumbHolder = UIView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let starView = UIImageView(image: UIImage(systemName: "star.fill"))
    private let moreButton = UIButton(type: .system)
    private let textStack = UIStackView()
    private let separator = UIView()
    private let listHighlightView = UIView()
    private var listConstraints: [NSLayoutConstraint] = []
    private var gridConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        listIcon.translatesAutoresizingMaskIntoConstraints = false

        // 宫格的缩略图位：paper-2 底的圆角块，中间摆文件图标。网页 `.card-thumb`。
        thumbHolder.backgroundColor = AppColor.paper2
        thumbHolder.layer.cornerRadius = AppRadius.tile
        thumbHolder.layer.cornerCurve = .continuous
        thumbHolder.clipsToBounds = true
        thumbHolder.translatesAutoresizingMaskIntoConstraints = false
        gridIcon.translatesAutoresizingMaskIntoConstraints = false
        thumbHolder.addSubview(gridIcon)

        nameLabel.font = AppTypography.rowName
        nameLabel.textColor = AppColor.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.adjustsFontForContentSizeCategory = true

        detailLabel.font = AppTypography.rowMeta
        detailLabel.textColor = AppColor.textSecondary
        detailLabel.adjustsFontForContentSizeCategory = true

        // 宫格卡片是固定高度，超大字号下总有东西放不下。这里定死让步顺序：
        // 文字一步不让，缩略图位随便压——名字和大小是这张卡要说的话，图位只是装饰。
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        starView.tintColor = AppColor.star
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

        // 网页 `.row` 的行间发丝线是 paper-2，比卡片描边的 --line 浅一档。
        separator.backgroundColor = AppColor.paper2
        separator.translatesAutoresizingMaskIntoConstraints = false

        // cell 本身铺满屏幕，列表白卡却左右各内缩 16pt。按下态必须单独画在
        // 白卡的 bounds 内，不能再直接给 contentView 上色。
        listHighlightView.isUserInteractionEnabled = false
        listHighlightView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(listHighlightView)

        let titleStack = UIStackView(arrangedSubviews: [nameLabel, starView])
        titleStack.axis = .horizontal
        titleStack.spacing = AppSpacing.extraSmall
        titleStack.alignment = .center

        textStack.addArrangedSubview(titleStack)
        textStack.addArrangedSubview(detailLabel)
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.alignment = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(listIcon)
        contentView.addSubview(thumbHolder)
        contentView.addSubview(textStack)
        contentView.addSubview(moreButton)
        contentView.addSubview(separator)

        NSLayoutConstraint.activate([
            listHighlightView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PaperSectionBackgroundView.horizontalInset
            ),
            listHighlightView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PaperSectionBackgroundView.horizontalInset
            ),
            listHighlightView.topAnchor.constraint(equalTo: contentView.topAnchor),
            listHighlightView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            starView.widthAnchor.constraint(equalToConstant: 13),
            starView.heightAnchor.constraint(equalToConstant: 13),
            moreButton.widthAnchor.constraint(equalToConstant: Self.moreButtonHitSize),
            moreButton.heightAnchor.constraint(equalToConstant: Self.moreButtonHitSize),
            gridIcon.centerXAnchor.constraint(equalTo: thumbHolder.centerXAnchor),
            gridIcon.centerYAnchor.constraint(equalTo: thumbHolder.centerYAnchor)
        ])

        // contentView 铺满整个 collection 宽度，而白卡只占中间那块。所以行内元素
        // 要退到「卡的内缩 + 行自己的内边距」之外，才是网页 `.row` 那 16px padding
        // 的等价物；只写一个 16 的话，图标会正好压在卡的描边上。
        let rowInset = PaperSectionBackgroundView.horizontalInset + Self.rowPadding
        // ⋯ 的点击区是 44，里面的字形只有约 19，两侧各空 12.5。要让**字形**的右沿
        // 落在卡内缘 16 处，按钮本身就得再往外挪回这段空白。
        let moreOverhang = (Self.moreButtonHitSize - Self.moreGlyphWidth) / 2

        listConstraints = [
            listIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: rowInset),
            listIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: listIcon.trailingAnchor, constant: 14),
            // 上下给的是「不小于」，配合下面的最小行高把文字居中放。写成必须的
            // 等式会在行被撑到 58 时把 stack 拉长，名字和副标题之间凭空多出一段。
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            moreButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -(rowInset - moreOverhang)
            ),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            // 网页 `.row` 的 border-bottom 铺满整个 border box，所以发丝线要横贯
            // 整张卡——正好落在卡的左右沿上，而不是再往里缩一段。
            separator.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PaperSectionBackgroundView.horizontalInset
            ),
            separator.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PaperSectionBackgroundView.horizontalInset
            ),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            // 网页 `.row` 是 38 的图标加上下各 10，至少 58 高。行高交给文字撑的话
            // 只有 52，图标上下各剩 7，挤。
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ]
        // 缩略图位可压缩，见上面对让步顺序的说明。
        let thumbHeight = thumbHolder.heightAnchor.constraint(equalToConstant: 104)
        thumbHeight.priority = .defaultLow
        gridConstraints = [
            // `.card`：14 内边距，缩略图位 104 高。
            thumbHolder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            thumbHolder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            thumbHolder.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            thumbHeight,
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: thumbHolder.bottomAnchor, constant: 12),
            textStack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor, constant: -12
            ),
            // ⋯ 浮在卡片右上角（网页把星标放在这个位置）。
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            moreButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2)
        ]
        NSLayoutConstraint.activate(listConstraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        moreButton.menu = nil
    }

    /// - Parameters:
    ///   - detailOverride: 回收站用——副标题换成「还有 N 天自动删除」，比文件尺寸更有用。
    ///   - isFirst/isLast: 控制按下态在白卡首尾处的圆角，以及最后一行的发丝线
    ///     （网页 `.row:last-child { border-bottom: 0 }`）。
    func configure(
        with node: DriveNode,
        menu: UIMenu,
        grid: Bool,
        detailOverride: String? = nil,
        isFirst: Bool = false,
        isLast: Bool = false
    ) {
        listIcon.configure(with: node)
        gridIcon.configure(with: node)
        nameLabel.text = node.name
        starView.isHidden = !node.starred

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

        apply(grid: grid, isFirst: isFirst, isLast: isLast)
    }

    private func apply(grid: Bool, isFirst: Bool, isLast: Bool) {
        NSLayoutConstraint.deactivate(grid ? listConstraints : gridConstraints)
        NSLayoutConstraint.activate(grid ? gridConstraints : listConstraints)

        listIcon.isHidden = grid
        thumbHolder.isHidden = !grid
        separator.isHidden = grid || isLast
        listHighlightView.isHidden = grid
        isListRow = !grid
        nameLabel.numberOfLines = grid ? 2 : 1
        nameLabel.lineBreakMode = grid ? .byTruncatingTail : .byTruncatingMiddle

        // 宫格是一张独立的白卡；列表行躺在整段共用的白卡上，自己不要底色。
        contentView.backgroundColor = grid ? AppColor.surface : .clear
        contentView.layer.cornerRadius = grid ? AppRadius.card : 0
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = grid ? 1 : 0
        contentView.layer.borderColor = AppColor.line.cgColor

        listHighlightView.layer.cornerRadius = AppRadius.card
        listHighlightView.layer.cornerCurve = .continuous
        switch (isFirst, isLast) {
        case (true, true):
            listHighlightView.layer.maskedCorners = [
                .layerMinXMinYCorner, .layerMaxXMinYCorner,
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner
            ]
        case (true, false):
            listHighlightView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case (false, true):
            listHighlightView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case (false, false):
            listHighlightView.layer.maskedCorners = []
        }
    }

    /// 高亮态要按形态分别处理，不能拿 separator 的显隐来推断——段内最后一行也没有它。
    private var isListRow = true

    /// 列表态的按下高亮：网页 `.row:hover` 是一层极浅的暖白。
    override var isHighlighted: Bool {
        didSet {
            guard isListRow else { return }
            listHighlightView.backgroundColor = isHighlighted
                ? AppColor.paper2.withAlphaComponent(0.6)
                : .clear
        }
    }
}
