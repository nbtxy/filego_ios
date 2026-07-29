#if DEBUG
import UIKit

final class HTTPHistoryDetailViewController: UIViewController {
    private let recordID: UUID
    private let textView = UITextView()

    init(recordID: UUID) {
        self.recordID = recordID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "请求详情"
        view.backgroundColor = AppColor.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyCURL)
        )

        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = AppColor.background
        textView.textContainerInset = UIEdgeInsets(
            top: AppSpacing.medium,
            left: AppSpacing.medium,
            bottom: AppSpacing.large,
            right: AppSpacing.medium
        )
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        textView.text = record.map(render) ?? "记录已被清空"
    }

    @objc private func copyCURL() {
        guard let record else { return }
        UIPasteboard.general.string = curl(for: record)
        HapticManager.notification(.success)
    }

    private var record: HTTPHistoryStore.Record? {
        HTTPHistoryStore.shared.record(id: recordID)
    }

    private func render(_ record: HTTPHistoryStore.Record) -> String {
        """
        OVERVIEW
        \(record.method) \(record.url?.absoluteString ?? "—")
        Status: \(record.statusCode.map(String.init) ?? "—")
        Duration: \(record.duration.map { String(format: "%.3f s", $0) } ?? "—")

        REQUEST HEADERS
        \(renderHeaders(record.requestHeaders))

        REQUEST BODY\(record.requestBodyTruncated ? " (truncated)" : "")
        \(renderBody(record.requestBody))

        RESPONSE HEADERS
        \(renderHeaders(record.responseHeaders))

        RESPONSE BODY\(record.responseBodyTruncated ? " (truncated)" : "")
        \(renderBody(record.responseBody))

        ERROR
        \(record.errorDescription ?? "—")
        """
    }

    private func renderHeaders(_ headers: [String: String]) -> String {
        guard !headers.isEmpty else { return "—" }
        return headers.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private func renderBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "—" }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: object,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8)
            ?? data.prefix(512).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func curl(for record: HTTPHistoryStore.Record) -> String {
        var parts = ["curl -X \(record.method)"]
        for (key, value) in record.requestHeaders.sorted(by: { $0.key < $1.key }) {
            parts.append("-H '\(key): \(value)'")
        }
        if let data = record.requestBody, let body = String(data: data, encoding: .utf8) {
            parts.append("--data '\(body.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        parts.append("'\(record.url?.absoluteString ?? "")'")
        return parts.joined(separator: " \\\n  ")
    }
}
#endif
