import UIKit

/// diffable 的条目标识必须是 Sendable，见 MeViewController 里的同类说明。
private nonisolated enum Row: Hashable {
    case overview
    case category(LocalStorageUsage.Category)
    case files
    case folders
    case trashedCount
}

/// 存储空间二级页：总览堆叠条 + 按类型的占用明细 + 条目数。
///
/// 改造前这页吃的是 `GET /me` 下发的配额与明细；现在没有账号了，数据由
/// `LocalStorageUsage.scan` 走一遍 `Documents/` 现算。总览那根条也跟着换了口径：
/// 旧版是「已用 / 配额」的单色进度条，配额只有几 GB，比例看得见；分母换成整机容量后
/// 本 App 那点占用画出来是一条空条。所以整条改成代表本 App 的占用，内部按分类分段——
/// 和系统「设置 → iPhone 储存空间」是同一个读法，条子才一直有信息量。
@MainActor
final class StorageDetailViewController: UIViewController {
    private let environment: AppEnvironment
    private var usage: LocalStorageUsage = .empty

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.meStorageTitle.localizedString()
        view.backgroundColor = AppColor.background
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        applySnapshot()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从回收站清空后返回，占用会变，重新算一次。
        if isMovingToParent == false { reload() }
    }

    // MARK: - 视图

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration.paperInsetGrouped()
        configuration.headerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.backgroundColor = AppColor.background
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let overviewRegistration = UICollectionView.CellRegistration<StorageOverviewCell, Row> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.apply(self.usage)
        }
        let valueRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> {
            [weak self] cell, _, row in
            self?.configure(cell, for: row)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { header, _, indexPath in
            var content: UIListContentConfiguration
            if #available(iOS 18.0, *) {
                content = .header()
            } else {
                content = .groupedHeader()
            }
            content.text = Self.sectionTitle(indexPath.section)
            content.textProperties.color = AppColor.textSecondary
            header.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) {
            collectionView, indexPath, row in
            // 两个 registration 的 cell 类型不同，不能塞进同一个三目里。
            if row == .overview {
                return collectionView.dequeueConfiguredReusableCell(
                    using: overviewRegistration, for: indexPath, item: row)
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: valueRegistration, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        PaperListCellStyle.apply(to: cell)
        var content = UIListContentConfiguration.valueCell()
        content.applyPaperColors()
        cell.accessories = []

        switch row {
        case .overview:
            return
        case .category(let category):
            // 圆点的颜色就是这一类在堆叠条上那一段的颜色。没有它，条子是一排没有图例的色块。
            content.image = UIImage(
                systemName: "circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
            content.imageProperties.tintColor = StorageCategoryStyle.color(for: category)
            content.text = StorageCategoryStyle.title(for: category)
            content.secondaryText = ByteFormatting.storage(usage.bytes(of: category))
            // 回收站里的文件仍然占着手机的空间，这一行要能直接点进去清空。
            if category == .trash { cell.accessories = [PaperListCellStyle.disclosure] }
        case .files:
            content.text = R.Strings.storageCountsFiles.localizedString()
            content.secondaryText = String(usage.files)
        case .folders:
            content.text = R.Strings.storageCountsFolders.localizedString()
            content.secondaryText = String(usage.folders)
        case .trashedCount:
            content.text = R.Strings.storageCountsTrashed.localizedString()
            content.secondaryText = String(usage.trashedCount)
        }

        cell.contentConfiguration = content
    }

    private static func sectionTitle(_ section: Int) -> String? {
        switch section {
        case 0: return R.Strings.storageOverviewTitle.localizedString()
        case 1: return R.Strings.storageDetailTitle.localizedString()
        default: return R.Strings.storageCountsTitle.localizedString()
        }
    }

    // MARK: - 数据

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0, 1, 2])
        snapshot.appendItems([.overview], toSection: 0)

        var details: [Row] = [
            .category(.images), .category(.videos), .category(.audio), .category(.documents)
        ]
        // 没有在途接收时这一行恒为 0，没必要占位。
        if usage.reservedBytes > 0 { details.append(.category(.reserved)) }
        details.append(.category(.trash))
        snapshot.appendItems(details, toSection: 1)

        snapshot.appendItems([.files, .folders, .trashedCount], toSection: 2)

        // 行标识不带关联的数值，内容变了 identifier 也不变——不显式 reconfigure，
        // diffable 会比出「两次一模一样」然后什么都不做，cell 停在扫描完成前的 0 上。
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter(existing.contains)
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reload() {
        // 目录遍历在大收件盘上不是瞬时的，别占主线程。
        let root = environment.drive.root
        Task.detached(priority: .utility) {
            let scanned = LocalStorageUsage.scan(root: root)
            await MainActor.run { [weak self] in
                self?.usage = scanned
                self?.applySnapshot()
            }
        }
    }
}

extension StorageDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .category(.trash) else { return }
        navigationController?.pushViewController(
            TrashViewController(environment: environment), animated: true)
    }
}

/// 分类的文案与配色。堆叠条上的段、明细行的圆点都从这里取，保证一一对应。
@MainActor
enum StorageCategoryStyle {
    static func title(for category: LocalStorageUsage.Category) -> String {
        switch category {
        case .images: return R.Strings.storageCategoryImages.localizedString()
        case .videos: return R.Strings.storageCategoryVideos.localizedString()
        case .audio: return R.Strings.storageCategoryAudio.localizedString()
        case .documents: return R.Strings.storageCategoryDocuments.localizedString()
        case .reserved: return R.Strings.storageCategoryReserved.localizedString()
        case .trash: return R.Strings.storageCategoryTrash.localizedString()
        }
    }

    /// 尽量沿用 `FileIconTile` 给文件图标定的那套色，列表里看到的橙色图片、蓝色视频，
    /// 在这根条上还是同一个颜色。音频单独挑了深绿：它和视频在 FileIconTile 里共用蓝色，
    /// 两段同色挨在一起就看不出是两段了。
    static func color(for category: LocalStorageUsage.Category) -> UIColor {
        switch category {
        case .images: return AppColor.orange
        case .videos: return AppColor.blue
        case .audio: return AppColor.FileTile.folderForeground
        case .documents: return AppColor.purple
        case .reserved: return AppColor.lime
        case .trash: return AppColor.muted
        }
    }
}

/// 总览行：「已使用 X / Y」+ 分类堆叠条 + 「可用 Z」。
private final class StorageOverviewCell: UICollectionViewListCell {
    private let usedLabel = UILabel()
    private let bar = StackedBarView()
    private let availableLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ usage: LocalStorageUsage) {
        usedLabel.text = R.Strings.storageUsed.formatted(
            ByteFormatting.storage(usage.usedBytes),
            ByteFormatting.storage(usage.capacityBytes)
        )
        availableLabel.text = R.Strings.storageAvailable.formatted(
            ByteFormatting.storage(usage.availableBytes)
        )
        bar.apply(
            usage.segments.map {
                (StorageCategoryStyle.color(for: $0.category), Double($0.bytes))
            })
    }

    private func setUpViews() {
        usedLabel.font = AppTypography.body
        usedLabel.textColor = AppColor.textPrimary
        usedLabel.numberOfLines = 0

        availableLabel.font = AppTypography.caption
        availableLabel.textColor = AppColor.textSecondary
        availableLabel.numberOfLines = 0

        // 8pt 的胶囊条，对齐网页 `.storage-bar`；系统进度条默认的 4pt 太细，
        // 分成六段之后每一段都看不出颜色。
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let stack = UIStackView(arrangedSubviews: [usedLabel, bar, availableLabel])
        stack.axis = .vertical
        stack.spacing = AppSpacing.small
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppSpacing.medium),
            stack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: AppSpacing.medium),
            stack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -AppSpacing.medium),
            stack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -AppSpacing.medium)
        ])
    }
}

/// 一根按比例分段着色的胶囊条。
///
/// 段宽用 frame 摆而不是约束：每次刷新都要重建分段，拿 multiplier 约束做等于每次都要
/// 拆装一轮约束，在 cell 复用里很容易剩下上一批没拆干净。
private final class StackedBarView: UIView {
    private var segments: [(color: UIColor, value: Double)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppColor.paper2
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ segments: [(UIColor, Double)]) {
        self.segments = segments.map { (color: $0.0, value: $0.1) }
        subviews.forEach { $0.removeFromSuperview() }
        for segment in self.segments {
            let view = UIView()
            view.backgroundColor = segment.color
            addSubview(view)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2

        let total = segments.reduce(0) { $0 + $1.value }
        // 空盘：留一条空底色，别去除零。
        guard total > 0, bounds.width > 0 else { return }

        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() where index < segments.count {
            // 最后一段吃掉累计取整的余数，条子右端才不会露出一丝底色。
            let isLast = index == segments.count - 1
            let width = isLast
                ? bounds.width - x
                : (bounds.width * CGFloat(segments[index].value / total)).rounded()
            view.frame = CGRect(x: x, y: 0, width: max(0, width), height: bounds.height)
            x += width
        }
    }
}
