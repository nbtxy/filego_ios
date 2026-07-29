#if DEBUG
import Foundation

extension Notification.Name {
    static let httpHistoryDidChange = Notification.Name("filego.http-history.did-change")
}

@MainActor
final class HTTPHistoryStore {
    static let shared = HTTPHistoryStore()
    static let bodyCap = 256 * 1024

    struct Record: Identifiable {
        let id: UUID
        let startedAt: Date
        let method: String
        let url: URL?
        let requestHeaders: [String: String]
        let requestBody: Data?
        let requestBodyTruncated: Bool
        var endedAt: Date?
        var statusCode: Int?
        var responseHeaders: [String: String]
        var responseBody: Data?
        var responseBodyTruncated: Bool
        var errorDescription: String?

        var duration: TimeInterval? {
            endedAt.map { $0.timeIntervalSince(startedAt) }
        }

        var path: String {
            url?.path ?? url?.absoluteString ?? "—"
        }
    }

    private(set) var records: [Record] = []
    private let capacity = 200

    private init() {}

    func append(_ record: Record) {
        records.insert(record, at: 0)
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
        notifyChange()
    }

    func update(id: UUID, mutate: (inout Record) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        notifyChange()
    }

    func record(id: UUID) -> Record? {
        records.first { $0.id == id }
    }

    func clear() {
        records.removeAll()
        notifyChange()
    }

    static func truncateBody(_ data: Data?) -> (Data?, Bool) {
        guard let data else { return (nil, false) }
        guard data.count > bodyCap else { return (data, false) }
        return (Data(data.prefix(bodyCap)), true)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .httpHistoryDidChange, object: self)
    }
}
#endif
