import UIKit

/// diffable 的条目标识必须是 Sendable，见 MeViewController 里的同类说明。
private nonisolated enum Row: Hashable {
    case overview
    case images
    case videos
    case audio
    case documents
    case reserved
    case trash
    case files
    case folders
    case trashedCount
}

/// 存储空间二级页：总览进度 + 按类型的占用明细 + 条目数。
@MainActor
final class StorageDetailViewController: UIViewController {
    private let environment: AppEnvironment
    private var profile: AccountProfile

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!

    init(environment: AppEnvironment, profile: AccountProfile) {
        self.environment = environment
        self.profile = profile
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从回收站清空后返回，占用会变，重新拉一次。
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
            cell.apply(self.profile.storage)
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
                    using: overviewRegistration,
                    for: indexPath,
                    item: row
                )
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: valueRegistration,
                for: indexPath,
                item: row
            )
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        PaperListCellStyle.apply(to: cell)
        var content = UIListContentConfiguration.valueCell()
        content.applyPaperColors()
        let storage = profile.storage
        let breakdown = storage.breakdown

        switch row {
        case .overview:
            return
        case .images:
            content.text = R.Strings.storageCategoryImages.localizedString()
            content.secondaryText = ByteFormatting.string(breakdown?.images ?? 0)
        case .videos:
            content.text = R.Strings.storageCategoryVideos.localizedString()
            content.secondaryText = ByteFormatting.string(breakdown?.videos ?? 0)
        case .audio:
            content.text = R.Strings.storageCategoryAudio.localizedString()
            content.secondaryText = ByteFormatting.string(breakdown?.audio ?? 0)
        case .documents:
            content.text = R.Strings.storageCategoryDocuments.localizedString()
            content.secondaryText = ByteFormatting.string(breakdown?.documents ?? 0)
        case .reserved:
            content.text = R.Strings.storageCategoryReserved.localizedString()
            content.secondaryText = ByteFormatting.string(storage.reservedBytes)
        case .trash:
            content.text = R.Strings.storageCategoryTrash.localizedString()
            content.secondaryText = ByteFormatting.string(storage.trashBytes)
        case .files:
            content.text = R.Strings.storageCountsFiles.localizedString()
            content.secondaryText = String(profile.counts.files)
        case .folders:
            content.text = R.Strings.storageCountsFolders.localizedString()
            content.secondaryText = String(profile.counts.folders)
        case .trashedCount:
            content.text = R.Strings.storageCountsTrashed.localizedString()
            content.secondaryText = String(profile.counts.trashed)
        }

        cell.contentConfiguration = content
        // 回收站里的文件仍然占配额（见规划 §2），这一行要能直接点进去清空。
        cell.accessories = row == .trash ? [PaperListCellStyle.disclosure] : []
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
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0, 1, 2])
        snapshot.appendItems([.overview], toSection: 0)

        var details: [Row] = [.images, .videos, .audio, .documents]
        // 没有在途上传时这一行恒为 0，没必要占位。
        if profile.storage.reservedBytes > 0 { details.append(.reserved) }
        details.append(.trash)
        snapshot.appendItems(details, toSection: 1)

        snapshot.appendItems([.files, .folders, .trashedCount], toSection: 2)
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    private func reload() {
        Task {
            do {
                profile = try await environment.accountService.loadProfile()
                applySnapshot()
            } catch {
                // 明细页刷新失败时保留上一次的数据，不打断浏览。
                AppLogger.warning("刷新存储明细失败：\(error.localizedDescription)")
            }
        }
    }
}

extension StorageDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .trash else { return }
        navigationController?.pushViewController(
            TrashViewController(environment: environment),
            animated: true
        )
    }
}

/// 总览行：进度条 + 「已使用 X / Y」+ 「可用 Z」。
private final class StorageOverviewCell: UICollectionViewListCell {
    private let progress = UIProgressView(progressViewStyle: .default)
    private let usedLabel = UILabel()
    private let availableLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ storage: StorageUsage) {
        let fraction = Float(storage.committedFraction)
        progress.progress = fraction
        // 网页 `.storage-bar i.full`：用到九成就从柠檬绿转橙，颜色本身就是提醒。
        progress.progressTintColor = fraction >= 0.9 ? AppColor.orange : AppColor.lime
        usedLabel.text = R.Strings.storageUsed.formatted(
            ByteFormatting.string(storage.usedBytes),
            ByteFormatting.string(storage.quotaBytes)
        )
        availableLabel.text = R.Strings.storageAvailable.formatted(
            ByteFormatting.string(storage.availableBytes)
        )
    }

    private func setUpViews() {
        progress.progressTintColor = AppColor.lime
        progress.trackTintColor = AppColor.paper2
        // 8pt 的胶囊条，与网页 `.storage-bar` 一致；系统默认的 4pt 太细，
        // 柠檬绿在那个厚度上几乎看不出来。
        progress.layer.cornerRadius = 4
        progress.clipsToBounds = true
        progress.transform = CGAffineTransform(scaleX: 1, y: 2)

        usedLabel.font = AppTypography.body
        usedLabel.textColor = AppColor.textPrimary
        usedLabel.numberOfLines = 0

        availableLabel.font = AppTypography.caption
        availableLabel.textColor = AppColor.textSecondary
        availableLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [usedLabel, progress, availableLabel])
        stack.axis = .vertical
        stack.spacing = AppSpacing.small
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppSpacing.medium),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: AppSpacing.medium),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -AppSpacing.medium),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -AppSpacing.medium)
        ])
    }
}
