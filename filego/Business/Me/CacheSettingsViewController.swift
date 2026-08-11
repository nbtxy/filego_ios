import UIKit

@MainActor
final class CacheSettingsViewController: UITableViewController {
    private let environment: AppEnvironment
    private var statistics = FileCacheManager.Statistics(bytes: 0, fileCount: 0)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.cacheTitle.localizedString()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = AppColor.background
        tableView.separatorColor = AppColor.paper2
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CacheRow")
        activityIndicator.hidesWhenStopped = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: activityIndicator)
        reloadStatistics()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? R.Strings.cacheHint.localizedString() : nil
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CacheRow", for: indexPath)
        PaperListCellStyle.apply(to: cell)
        if indexPath.section == 0 {
            var content = UIListContentConfiguration.valueCell()
            content.applyPaperColors()
            content.text = R.Strings.cacheUsage.localizedString()
            content.secondaryText = R.Strings.cacheUsageValue.formatted(
                ByteFormatting.string(statistics.bytes), statistics.fileCount
            )
            cell.contentConfiguration = content
            cell.selectionStyle = .none
        } else {
            var content = UIListContentConfiguration.cell()
            content.text = R.Strings.cacheClear.localizedString()
            content.textProperties.color = AppColor.danger
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.selectionStyle = statistics.fileCount == 0 ? .none : .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, statistics.fileCount > 0 else { return }
        let alert = UIAlertController(
            title: R.Strings.cacheClearConfirm.localizedString(),
            message: R.Strings.cacheClearConfirmMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.cacheClear.localizedString(),
            style: .destructive
        ) { [weak self] _ in self?.clearCache() })
        present(alert, animated: true)
    }

    private func reloadStatistics() {
        guard let userID = environment.sessionManager.currentUserID else { return }
        activityIndicator.startAnimating()
        Task {
            statistics = await FileCacheManager.shared.statistics(
                userID: userID,
                baseURL: BackendConfig.baseURL
            )
            activityIndicator.stopAnimating()
            tableView.reloadData()
        }
    }

    private func clearCache() {
        guard let userID = environment.sessionManager.currentUserID else { return }
        activityIndicator.startAnimating()
        Task {
            await FileCacheManager.shared.removeAll(
                userID: userID,
                baseURL: BackendConfig.baseURL
            )
            statistics = .init(bytes: 0, fileCount: 0)
            activityIndicator.stopAnimating()
            tableView.reloadData()
        }
    }
}
