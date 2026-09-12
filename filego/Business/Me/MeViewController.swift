import StolnkCore
import UIKit

/// diffable 的条目标识必须是 Sendable。本模块 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 不显式写 `nonisolated` 的话 Hashable conformance 会带上主线程隔离，泛型约束就对不上。
private nonisolated enum Row: Hashable {
    case address
    case plan
    case localStorage
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
/// 本月中转用量、本机占用，以及密钥到底落在安全隔区还是软件里。
@MainActor
final class MeViewController: UIViewController {
    private let environment: AppEnvironment
    private let onNavigate: ((UIViewController) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!

    private var localBytes: Int64 = 0

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
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isMovingToParent == false { reload() }
    }

    @objc private func stateDidChange() { applySnapshot() }

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
            content.secondaryText =
                stolnk.inboxes.first?.url ?? R.Strings.meAddressNone.localizedString()
            cell.accessories = [.disclosureIndicator()]

        case .plan:
            content.text = R.Strings.mePlan.localizedString()
            if let plan = stolnk.plan {
                let tier = plan.isPro
                    ? R.Strings.mePlanPro.localizedString()
                    : R.Strings.mePlanFree.localizedString()
                let relay = R.Strings.meRelayValue.formatted(
                    ByteFormatting.string(Int64(plan.relayUsed)),
                    ByteFormatting.string(Int64(plan.relayLimit))
                )
                content.secondaryText = "\(tier) · \(relay)"
            }
            cell.accessories = []

        case .localStorage:
            content.text = R.Strings.meLocalStorage.localizedString()
            content.secondaryText = ByteFormatting.string(localBytes)
            cell.accessories = []

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
            let bytes = Self.directorySize(of: root)
            await MainActor.run { [weak self] in
                self?.localBytes = bytes
                self?.applySnapshot()
            }
        }
    }

    /// 递归统计占用。包含 `.Trash/`：那些文件确实还在占手机的空间，
    /// 报一个不含它们的数字会和系统「设置」里看到的对不上。
    private nonisolated static func directorySize(of root: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems([.address, .plan, .localStorage, .deviceKey], toSection: 0)
        snapshot.appendSections([1])
        #if DEBUG
        snapshot.appendItems([.debugPanel, .version], toSection: 1)
        #else
        snapshot.appendItems([.version], toSection: 1)
        #endif
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
        case .plan, .localStorage, .deviceKey, .version:
            break
        }
    }
}
