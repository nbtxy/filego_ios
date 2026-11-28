import UIKit

/// 文件/文件夹的条目。一份 cell 兼两种形态：
///   - 列表：对齐网页 `.row`——38pt 图标块 + 名字/副标题 + ⋯，行底一条发丝线；
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
    /// 宫格模式下的那张独立凸起白卡。列表模式隐藏——列表行躺在整段共用的白卡上。
    private let gridCard = MaterialView(surface: .paper, elevation: .card)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    /// 多选态下顶替 `moreButton` 位置的勾选标记。
    private let selectionBadge = UIImageView()
    /// 宫格多选选中时的边框与浅点缀底色。
    private let gridSelectionOverlay = UIView()
    /// 宫格隐藏项的浅紫底色与边框，用于和普通搜索结果区分。
    private let gridHiddenOverlay = UIView()
    private let textStack = UIStackView()
    private let separator = UIView()
    /// 在途占位的进度条。平时隐藏，stack 不给它留位置。
    private let progressView = UIProgressView(progressViewStyle: .bar)
    /// 当前显示的是哪个在途文件。换了文件（或第一次）时进度直接落位，不从旧值动画过去。
    private var incomingFileID: String?
    private let listHighlightView = UIView()
    private var listConstraints: [NSLayoutConstraint] = []
    private var gridConstraints: [NSLayoutConstraint] = []
    private var isCellSelected = false
    private var isSelectionMode = false
    private var isHiddenEntry = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        listIcon.translatesAutoresizingMaskIntoConstraints = false

        // 宫格的缩略图位：paper-2 底的圆角块，中间摆文件图标。网页 `.card-thumb`。
        gridCard.frame = contentView.bounds
        gridCard.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gridCard.cornerRadius = AppRadius.card
        contentView.addSubview(gridCard)

        gridSelectionOverlay.frame = contentView.bounds
        gridSelectionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gridSelectionOverlay.backgroundColor = AppColor.lime2.withAlphaComponent(0.28)
        gridSelectionOverlay.layer.cornerRadius = AppRadius.card
        gridSelectionOverlay.layer.cornerCurve = .continuous
        gridSelectionOverlay.layer.borderWidth = 2
        gridSelectionOverlay.layer.borderColor = AppColor.ink.cgColor
        gridSelectionOverlay.isUserInteractionEnabled = false
        gridSelectionOverlay.isHidden = true
        contentView.addSubview(gridSelectionOverlay)

        gridHiddenOverlay.frame = contentView.bounds
        gridHiddenOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gridHiddenOverlay.backgroundColor = AppColor.FileTile.documentBackground.withAlphaComponent(0.35)
        gridHiddenOverlay.layer.cornerRadius = AppRadius.card
        gridHiddenOverlay.layer.cornerCurve = .continuous
        gridHiddenOverlay.layer.borderWidth = 1.5
        gridHiddenOverlay.layer.borderColor = AppColor.purple.withAlphaComponent(0.4).cgColor
        gridHiddenOverlay.isUserInteractionEnabled = false
        gridHiddenOverlay.isHidden = true
        contentView.addSubview(gridHiddenOverlay)

        // 缩略图位是卡片上压下去的一块凹槽色。
        thumbHolder.backgroundColor = AppColor.well
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

        selectionBadge.contentMode = .scaleAspectFit
        selectionBadge.isUserInteractionEnabled = false
        selectionBadge.isHidden = true
        selectionBadge.translatesAutoresizingMaskIntoConstraints = false

        // 网页 `.row` 的行间发丝线是 paper-2，比卡片描边的 --line 浅一档。
        separator.backgroundColor = AppColor.paper2
        separator.translatesAutoresizingMaskIntoConstraints = false

        // cell 本身铺满屏幕，列表白卡却左右各内缩 16pt。按下态必须单独画在
        // 白卡的 bounds 内，不能再直接给 contentView 上色。
        listHighlightView.isUserInteractionEnabled = false
        listHighlightView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(listHighlightView)

        progressView.progressTintColor = AppColor.accent
        progressView.trackTintColor = AppColor.paper2
        progressView.layer.cornerRadius = 1.5
        progressView.clipsToBounds = true
        progressView.isHidden = true
        progressView.heightAnchor.constraint(equalToConstant: 3).isActive = true

        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(detailLabel)
        textStack.addArrangedSubview(progressView)
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.alignment = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(listIcon)
        contentView.addSubview(thumbHolder)
        contentView.addSubview(textStack)
        contentView.addSubview(moreButton)
        contentView.addSubview(selectionBadge)
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
            moreButton.widthAnchor.constraint(equalToConstant: Self.moreButtonHitSize),
            moreButton.heightAnchor.constraint(equalToConstant: Self.moreButtonHitSize),
            selectionBadge.centerXAnchor.constraint(equalTo: moreButton.centerXAnchor),
            selectionBadge.centerYAnchor.constraint(equalTo: moreButton.centerYAnchor),
            selectionBadge.widthAnchor.constraint(equalToConstant: 24),
            selectionBadge.heightAnchor.constraint(equalToConstant: 24),
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
            // 等式而不是「不大于」：在途占位的进度条要铺满文字列，而不是只有名字那么宽。
            // 标签本身左对齐，普通行看不出区别。
            textStack.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -8),
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
        resetIncoming()
    }

    /// 在途占位留下的样子全部复位。cell 是复用的，普通条目不能继承半透明。
    private func resetIncoming() {
        incomingFileID = nil
        progressView.isHidden = true
        progressView.setProgress(0, animated: false)
        listIcon.alpha = 1
        gridIcon.alpha = 1
        nameLabel.alpha = 1
        moreButton.isHidden = false
        selectionBadge.isHidden = true
        gridSelectionOverlay.isHidden = true
        gridHiddenOverlay.isHidden = true
        detailLabel.attributedText = nil
        isCellSelected = false
        isSelectionMode = false
        isHiddenEntry = false
    }

    /**
     正在路上的文件：半透明的图标和名字，下面一根进度条。

     没有 ⋯ 菜单——文件还不存在，能对它做的事一件也没有。
     */
    func configure(incoming transfer: IncomingTransfer, grid: Bool, isFirst: Bool, isLast: Bool) {
        let placeholder = DriveNode(
            id: transfer.fileID, parentId: nil, kind: .file,
            name: transfer.name, size: Int64(transfer.size), updatedAt: Date())
        listIcon.configure(with: placeholder)
        gridIcon.configure(with: placeholder)
        listIcon.alpha = 0.4
        gridIcon.alpha = 0.4
        nameLabel.text = transfer.name
        nameLabel.alpha = 0.6
        moreButton.menu = nil
        moreButton.isHidden = true

        if transfer.isDirect {
            detailLabel.text = R.Strings.driveIncomingDirect.formatted(
                ByteFormatting.storage(Int64(transfer.downloadedBytes ?? 0)),
                ByteFormatting.storage(Int64(transfer.size)))
        } else if let downloaded = transfer.downloadedBytes {
            detailLabel.text = R.Strings.driveIncomingReceiving.formatted(
                ByteFormatting.storage(Int64(downloaded)),
                ByteFormatting.storage(Int64(transfer.size)))
        } else {
            detailLabel.text = R.Strings.driveIncomingUploading.formatted(
                Int64(transfer.uploadFraction * 100))
        }

        let isSameFile = incomingFileID == transfer.fileID
        incomingFileID = transfer.fileID
        progressView.isHidden = false
        progressView.setProgress(Float(transfer.overall), animated: isSameFile)

        apply(grid: grid, isFirst: isFirst, isLast: isLast)
        selectionBadge.isHidden = true
        gridSelectionOverlay.isHidden = true
        isCellSelected = false
        isSelectionMode = false
        updateHighlightAppearance()
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
        isLast: Bool = false,
        isSelecting: Bool = false,
        isSelected: Bool = false,
        isHiddenItem: Bool = false
    ) {
        resetIncoming()
        isHiddenEntry = isHiddenItem
        listIcon.configure(with: node)
        gridIcon.configure(with: node)
        nameLabel.text = node.name

        let baseDetail: String
        if let detailOverride {
            baseDetail = detailOverride
        } else if node.isFolder {
            baseDetail = R.Strings.driveFolder.localizedString()
        } else {
            let size = ByteFormatting.storage(node.size)
            let ext = URL(fileURLWithPath: node.name).pathExtension.uppercased()
            baseDetail = ext.isEmpty ? size : "\(ext) · \(size)"
        }

        if isHiddenItem {
            detailLabel.attributedText = Self.hiddenDetailText(base: baseDetail)
        } else {
            detailLabel.attributedText = nil
            detailLabel.text = baseDetail
        }
        moreButton.menu = menu

        apply(grid: grid, isFirst: isFirst, isLast: isLast)
        isSelectionMode = isSelecting
        moreButton.isHidden = isSelecting
        selectionBadge.isHidden = !isSelecting
        gridHiddenOverlay.isHidden = !grid || !isHiddenItem || (isSelecting && isSelected)
        updateSelection(isSelected: isSelecting && isSelected)
    }

    private static func hiddenDetailText(base: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        attachment.image = UIImage(systemName: "lock.fill", withConfiguration: symbolConfig)?
            .withTintColor(AppColor.purple, renderingMode: .alwaysOriginal)
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(
            string: " " + R.Strings.driveHiddenTag.localizedString(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: AppColor.purple
            ]
        ))
        result.append(NSAttributedString(
            string: " · " + base,
            attributes: [
                .font: AppTypography.rowMeta,
                .foregroundColor: AppColor.textSecondary
            ]
        ))
        return result
    }

    func updateSelection(isSelected: Bool) {
        isCellSelected = isSelected
        let symbol = isSelected ? "checkmark.circle.fill" : "circle"
        selectionBadge.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        )
        selectionBadge.tintColor = isSelected ? AppColor.ink : AppColor.muted.withAlphaComponent(0.6)
        gridSelectionOverlay.isHidden = isListRow || !isSelected
        updateHighlightAppearance()
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

        // 宫格是一张独立的凸起白卡；列表行躺在整段共用的白卡上，自己不要底色。
        gridCard.isHidden = !grid
        contentView.backgroundColor = .clear

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

    /// 列表态的按下高亮与多选选中底色：按下是极浅的暖白，选中是 `--lime-2`。
    override var isHighlighted: Bool {
        didSet {
            updateHighlightAppearance()
        }
    }

    private func updateHighlightAppearance() {
        guard isListRow else { return }
        if isCellSelected {
            listHighlightView.backgroundColor = AppColor.lime2.withAlphaComponent(0.45)
        } else if isHiddenEntry {
            listHighlightView.backgroundColor = isHighlighted
                ? AppColor.FileTile.documentBackground
                : AppColor.FileTile.documentBackground.withAlphaComponent(0.48)
        } else if isHighlighted {
            listHighlightView.backgroundColor = AppColor.paper2.withAlphaComponent(0.6)
        } else {
            listHighlightView.backgroundColor = .clear
        }
    }
}
