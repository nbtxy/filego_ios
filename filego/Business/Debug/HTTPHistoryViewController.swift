#if DEBUG
import UIKit

final class HTTPHistoryViewController: UITableViewController {
    private var records: [HTTPHistoryStore.Record] = []
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.debugHttpTitle.localizedString()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "HTTPRecord")
        tableView.rowHeight = 72
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "清空",
            style: .plain,
            target: self,
            action: #selector(clearHistory)
        )
        observer = NotificationCenter.default.addObserver(
            forName: .httpHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadData() }
        }
        reloadData()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HTTPRecord", for: indexPath)
        let record = records[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = "\(record.method)  \(record.statusCode.map(String.init) ?? "…")"
        content.textProperties.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        let duration = record.duration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "进行中"
        content.secondaryText = "\(record.path)\n\(duration)"
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            HTTPHistoryDetailViewController(recordID: records[indexPath.row].id),
            animated: true
        )
    }

    @objc private func clearHistory() {
        HTTPHistoryStore.shared.clear()
    }

    private func reloadData() {
        records = HTTPHistoryStore.shared.records
        tableView.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = !records.isEmpty
        if records.isEmpty {
            let label = UILabel()
            label.text = R.Strings.debugHttpEmpty.localizedString()
            label.textColor = AppColor.textSecondary
            label.textAlignment = .center
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }
}
#endif
