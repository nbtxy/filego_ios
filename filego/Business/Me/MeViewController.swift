import StolnkCore
import UIKit

/// diffable 的条目标识必须是 Sendable。本模块 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 不显式写 `nonisolated` 的话 Hashable conformance 会带上主线程隔离，泛型约束就对不上。
private nonisolated enum Row: Hashable {
    case address
    case plan
    case storage
    case trash
    case deviceKey
    #if DEBUG
    case debugPanel
    #endif
    case version
}

/// 「我的」页：只放入口，不铺细节。
///
/// 改造后这里没有账号——身份就是 Secure Enclave 里那两把密钥，所以没有登录、
/// 没有登出、没有邮箱。取而代之的一级信息是：这台设备的收件地址、当前档位与
/// 本月中转用量、本机存储空间，以及密钥到底落在安全隔区还是软件里。
@MainActor
final class MeViewController: UIViewController {
    private let environment: AppEnvironment
    private let onNavigate: ((UIViewController) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!

    private var usage: LocalStorageUsage = .empty

    init(
        environment: AppEnvironment,
        onNavigate: ((UIViewController) -> Void)? = nil
    ) {
        self.environment = environment
        self.onNavigate = onNavigate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        configureCollectionView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .stolnkStateDidChange, object: nil)
        // 落地文件改变的是磁盘上的字节，不只是屏幕上的字。所以走 reload() 重算，
        // 而不是像 stateDidChange 那样只重画。
        NotificationCenter.default.addObserver(
            self, selector: #selector(filesDidLand),
            name: .stolnkDidLandFiles, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isMovingToParent == false { reload() }
    }

    @objc private func stateDidChange() { applySnapshot() }

    @objc private func filesDidLand() { reload() }

    /// 抽屉调这个重算本机占用快照。见 `DrawerContainerViewController.setOpen`。
    func refresh() { reload() }

    // MARK: - 视图

    private func configureCollectionView() {
        let configuration = UICollectionLayoutListConfiguration.paperInsetGrouped()
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

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> {
            [weak self] cell, _, row in
            self?.configure(cell, for: row)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) {
            collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: row)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        PaperListCellStyle.apply(to: cell)
        var content = UIListContentConfiguration.valueCell()
        content.applyPaperColors()
        let stolnk = environment.stolnk

        switch row {
        case .address:
            content.image = UIImage(systemName: "link")
            content.imageProperties.tintColor = AppColor.FileTile.folderForeground
            content.text = R.Strings.meAddress.localizedString()
            // 名字是 onboarding 就定下的身份，`ryan.stolnk.com` 从那一刻起一直成立；
            // inbox 是之后给某个文件夹取的路径，没建过不代表没有地址。拿 inbox 的有无
            // 去渲染这一行，会在刚注册完的设备上把「已有地址」说成「未设置」。
            content.secondaryText = stolnk.name.map { $0 + stolnk.nameSuffix }
                ?? R.Strings.meAddressNone.localizedString()
            cell.accessories = [.disclosureIndicator()]

        case .plan:
            content.image = UIImage(systemName: "sparkles")
            content.text = R.Strings.mePlan.localizedString()
            if let plan = stolnk.plan {
                let tier = plan.isPro
                    ? R.Strings.mePlanPro.localizedString()
                    : R.Strings.mePlanFree.localizedString()
                let relay = R.Strings.meRelayValue.formatted(
                    ByteFormatting.quota(Int64(plan.relayUsed)),
                    ByteFormatting.quota(Int64(plan.relayLimit))
                )
                content.secondaryText = "\(tier) · \(relay)"
            }
            cell.accessories = [.disclosureIndicator()]

        case .storage:
            content.image = UIImage(systemName: "internaldrive")
            content.imageProperties.tintColor = AppColor.FileTile.mediaForeground
            content.text = R.Strings.meStorageTitle.localizedString()
            let used = ByteFormatting.storage(usage.usedBytes)
            // 容量要等那次遍历回来才有。还没有的时候只说占用，别写成「180 MB / 0 字节」。
            content.secondaryText = usage.capacityBytes > 0
                ? R.Strings.meStorageValue.formatted(
                    used, ByteFormatting.storage(usage.capacityBytes))
                : used
            cell.accessories = [PaperListCellStyle.disclosure]

        case .trash:
            content.image = UIImage(systemName: "trash")
            content.text = R.Strings.trashTitle.localizedString()
            // 报数量不报体积：体积在存储明细页有专门一行（`storage.category.trash`），
            // 这里再说一遍没有增量信息。空的时候什么都不写——「0 项」是噪音。
            content.secondaryText = usage.trashedCount > 0
                ? String(usage.trashedCount) : nil
            cell.accessories = [.disclosureIndicator()]

        case .deviceKey:
            content.text = R.Strings.meDeviceKey.localizedString()
            content.secondaryText = stolnk.isEnclaveBacked
                ? R.Strings.meDeviceKeyEnclave.localizedString()
                : R.Strings.meDeviceKeySoftware.localizedString()
            cell.accessories = []

        #if DEBUG
        case .debugPanel:
            content.image = UIImage(systemName: "ladybug")
            content.text = R.Strings.debugPanelTitle.localizedString()
            content.secondaryText = stolnk.origin.host
            cell.accessories = [.disclosureIndicator()]
        #endif

        case .version:
            content.text = R.Strings.meVersion.localizedString()
            content.secondaryText =
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            cell.accessories = []
        }
        cell.contentConfiguration = content
    }

    // MARK: - 数据

    private func reload() {
        applySnapshot()
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

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems([.address, .plan, .storage, .trash, .deviceKey], toSection: 0)
        snapshot.appendSections([1])
        #if DEBUG
        snapshot.appendItems([.debugPanel, .version], toSection: 1)
        #else
        snapshot.appendItems([.version], toSection: 1)
        #endif
        // 行标识没有关联值，内容变了 identifier 也不变。不显式 reconfigure，diffable
        // 会比出「两次一模一样」然后什么都不做，cell 停在第一次建立时读到的值上——
        // 本机占用因此永远是那个还没算完的 0。
        //
        // 只挑本来就在的行：对正在首次插入的 item 调 reconfigureItems 会踩 UIKit 的
        // 断言，而 DEBUG 比 Release 多一行，不能写死。
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter(existing.contains)
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func navigate(_ viewController: UIViewController) {
        if let onNavigate {
            onNavigate(viewController)
        } else {
            navigationController?.pushViewController(viewController, animated: true)
        }
    }
}

extension MeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .address:
            navigate(InboxListViewController(environment: environment))
        #if DEBUG
        case .debugPanel:
            navigate(DebugPanelViewController(environment: environment))
        #endif
        case .plan:
            navigate(ProUpgradeViewController(environment: environment))
        case .storage:
            navigate(StorageDetailViewController(environment: environment))
        case .trash:
            navigate(TrashViewController(environment: environment))
        case .deviceKey, .version:
            break
        }
    }
}
