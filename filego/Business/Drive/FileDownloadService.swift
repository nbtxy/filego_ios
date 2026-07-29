import Foundation

enum FileDownloadService {
    enum Failure: Error, LocalizedError {
        case invalidResponse

        var errorDescription: String? { "无法下载此文件" }
    }

    @MainActor
    static func download(node: DriveNode) async throws -> URL {
        guard let token = AuthTokenStorage.token else { throw FileGoAPIError.unauthorized }
        let remoteURL = BackendConfig.baseURL
            .appendingPathComponent("nodes")
            .appendingPathComponent(node.id)
            .appendingPathComponent("download")
        var request = URLRequest(url: remoteURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.mimeType?.lowercased() != "application/json" else {
            throw Failure.invalidResponse
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileGoPreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(node.name)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}
