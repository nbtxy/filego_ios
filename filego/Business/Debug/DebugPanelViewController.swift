#if DEBUG
import UIKit

@MainActor
final class DebugPanelViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        case current
        case production
        case local
        case custom
        case httpHistory
        case reset
    }

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.debugPanelTitle.localizedString()
        tableView.backgroundColor = AppColor.background
        tableView.separatorColor = AppColor.paper2
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DebugPanelRow")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return 3
        default: return 2
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return R.Strings.debugPanelCurrent.localizedString()
        case 1: return R.Strings.debugPanelServer.localizedString()
        default: return R.Strings.debugPanelTools.localizedString()
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DebugPanelRow", for: indexPath)
        PaperListCellStyle.apply(to: cell)
        let row = row(at: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.selectionStyle = .default

        switch row {
        case .current:
            content.text = BackendConfig.baseURL.absoluteString
            content.textProperties.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            content.secondaryText = BackendConfig.baseURL == BackendConfig.defaultBaseURL
                ? R.Strings.debugPanelDefault.localizedString()
                : R.Strings.debugPanelOverride.localizedString()
            cell.selectionStyle = .none
        case .production:
            content.text = R.Strings.debugPanelProduction.localizedString()
            content.secondaryText = BackendConfig.productionBaseURL.absoluteString
            cell.accessoryType = BackendConfig.baseURL == BackendConfig.productionBaseURL ? .checkmark : .none
        case .local:
            content.text = R.Strings.debugPanelLocal.localizedString()
            content.secondaryText = BackendConfig.defaultBaseURL.absoluteString
            cell.accessoryType = BackendConfig.baseURL == BackendConfig.defaultBaseURL ? .checkmark : .none
        case .custom:
            content.text = R.Strings.debugPanelCustom.localizedString()
            content.image = UIImage(systemName: "link")
            cell.accessoryType = .disclosureIndicator
        case .httpHistory:
            content.text = R.Strings.debugHttpTitle.localizedString()
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            cell.accessoryType = .disclosureIndicator
        case .reset:
            content.text = R.Strings.debugPanelReset.localizedString()
            content.image = UIImage(systemName: "arrow.counterclockwise")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch row(at: indexPath) {
        case .current:
            break
        case .production:
            apply(BackendConfig.productionBaseURL.absoluteString)
        case .local:
            apply(BackendConfig.defaultBaseURL.absoluteString)
        case .custom:
            showCustomAddressAlert()
        case .httpHistory:
            navigationController?.pushViewController(HTTPHistoryViewController(), animated: true)
        case .reset:
            BackendConfig.reset()
            tableView.reloadData()
            invalidateSession()
        }
    }

    private func row(at indexPath: IndexPath) -> Row {
        switch (indexPath.section, indexPath.row) {
        case (0, _): return .current
        case (1, 0): return .production
        case (1, 1): return .local
        case (1, _): return .custom
        case (2, 0): return .httpHistory
        default: return .reset
        }
    }

    private func showCustomAddressAlert() {
        let alert = UIAlertController(
            title: R.Strings.debugPanelCustom.localizedString(),
            message: R.Strings.debugPanelSwitchHint.localizedString(),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = BackendConfig.baseURL.absoluteString
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.debugPanelApply.localizedString(),
            style: .default
        ) { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text else { return }
            self?.apply(value)
        })
        present(alert, animated: true)
    }

    private func apply(_ value: String) {
        do {
            try BackendConfig.apply(baseURL: value)
            tableView.reloadData()
            invalidateSession()
        } catch {
            let alert = UIAlertController(
                title: R.Strings.debugPanelInvalid.localizedString(),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func invalidateSession() {
        Task {
            await environment.sessionManager.invalidateLocalSession()
            await environment.appConfigStore.refresh()
        }
    }
}
#endif
